import Foundation
import Darwin
import XCTest
import PoolCore
import PoolRuntime
@testable import PoolEngine

/// A reply told as the tap streams it, and its calls in the model's order, shaped as the real
/// stream is. All text is synthetic; nothing runs Claude Code.
final class ClaudeStreamTests: XCTestCase {
    private let object = JSONValue.object(["type": .string("object")])
    private var tools: [BridgeTool] { [BridgeTool(name: "read", inputSchema: object), BridgeTool(name: "screenshot", inputSchema: object)] }

    // MARK: Streaming

    /// A streamed reply is told as its stream goes, before the transcript has its message, whose
    /// rows then say nothing; the turn ends at its end (TestTapStreamsBeforeWhole).
    func testDeltasStreamBeforeTheTranscriptRowAndTheMessageIsToldOnce() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        let session = harness.session()
        let log = EventLog.recording(try await session.events(for: request("Hello")))
        try await waitFor { harness.sentCount == 1 }
        let plan = try XCTUnwrap(harness.plan)
        let output = try XCTUnwrap(plan.environment[OfficialCLI.tapVariable])
        let folder = URL(fileURLWithPath: output).deletingLastPathComponent()
        let script = folder.appendingPathComponent(ClaudeTap.scriptName)
        XCTAssertEqual(plan.environment["BUN_OPTIONS"], "--preload " + script.path)
        XCTAssertTrue(folder.path.hasPrefix(harness.tapRoot.path), "A run folder with a space in its path has its tap in a private folder")
        XCTAssertEqual(try String(contentsOf: script, encoding: .utf8), ClaudeTap.script)
        XCTAssertEqual(try permissions(folder), 0o700)
        XCTAssertEqual(try permissions(script), 0o600)
        XCTAssertEqual(try permissions(URL(fileURLWithPath: output)), 0o600)

        try harness.tap(#"{"tap":"on"}"#, #"{"s":1,"open":true}"#)
        try harness.stream(1, Self.start("msg_1"), Self.textStart(0), Self.text(0, "Hel"))
        try await waitFor { await log.text == "Hel" }
        try harness.stream(1, Self.text(0, "lo"))
        try await waitFor { await log.text == "Hello" }
        let ended = await log.ended
        XCTAssertFalse(ended, "The reply is told before its transcript row")
        try harness.stream(1, Self.blockStop(0), Self.delta("end_turn", out: 7), Self.messageStop)
        try harness.tap(#"{"s":1,"end":"done"}"#)
        try harness.answer("Hello", message: "msg_1", usage: ["input_tokens": 3, "output_tokens": 7])
        try harness.turnEnded()
        try await waitFor { await log.ended }
        let events = await log.events
        XCTAssertEqual(events, [.usage(.init(inputTokens: 3, outputTokens: 1)), .text("Hel"), .text("lo"), .usage(.init(inputTokens: 3, outputTokens: 7)), .finished(.endTurn)])
        _ = await session.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "The tap goes with its run")
    }

    /// Another run on this account was refused at its 5-hour limit. A reply that has had nothing of a
    /// message streamed and stays quiet ends with that refusal, so it moves to another account; one
    /// that has begun streaming is answering and goes on however long it is quiet (a real tool call's
    /// input streamed nothing for 107 s, 11-10, and the reply then finished).
    func testAnotherRunsLimitEndsOnlyAReplyThatHasNotBegun() async throws {
        let limit = BridgeFailure.quotaLimited([.init(id: "five_hour", usedPercent: 100, observedAt: Date(), resetsAt: Date().addingTimeInterval(3600))])
        do {
            let harness = try SessionHarness(); defer { harness.clean() }
            let session = harness.session()
            let log = EventLog.recording(try await session.events(for: request("Hello")))
            try await waitFor { harness.sentCount == 1 }
            try harness.tap(#"{"tap":"on"}"#)
            await session.accountLimited(limit, until: Date().addingTimeInterval(3600))
            try await waitFor { await log.ended }
            let failure = await log.failure as? BridgeFailure
            XCTAssertEqual(failure, limit, "A reply not yet begun moves on")
            harness.exited(); _ = await session.close()
        }
        do {
            let harness = try SessionHarness(); defer { harness.clean() }
            let session = harness.session()
            let log = EventLog.recording(try await session.events(for: request("Hello")))
            try await waitFor { harness.sentCount == 1 }
            try harness.tap(#"{"tap":"on"}"#, #"{"s":1,"open":true}"#)
            try harness.stream(1, Self.start("msg_1"), Self.textStart(0), Self.text(0, "Reading"))
            try await waitFor { await log.text == "Reading" }
            await session.accountLimited(limit, until: Date().addingTimeInterval(3600))
            try await Task.sleep(nanoseconds: 800_000_000)
            let ended = await log.ended
            XCTAssertFalse(ended, "A reply that has begun streaming is not ended for another run's limit")
            try harness.stream(1, Self.blockStop(0), Self.delta("end_turn", out: 7), Self.messageStop)
            try harness.tap(#"{"s":1,"end":"done"}"#)
            try harness.answer("Reading", message: "msg_1", usage: ["input_tokens": 3, "output_tokens": 7])
            try harness.turnEnded()
            try await waitFor { await log.ended }
            let events = await log.events, failure = await log.failure
            XCTAssertNil(failure)
            XCTAssertEqual(events.last, .finished(.endTurn))
            _ = await session.close()
        }
    }

    /// A message the transcript has before its stream begins waits for it while a stream is open,
    /// and is told once, from the stream (TestTapMessageWaitsForItsStream).
    func testATranscriptMessageWaitsForItsStream() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        let session = harness.session(tapWait: 2)
        let log = EventLog.recording(try await session.events(for: request("Hi")))
        try await waitFor { harness.sentCount == 1 }
        try harness.tap(#"{"tap":"on"}"#, #"{"s":1,"open":true}"#)
        try harness.answer("hi", message: "msg_1")
        try await Task.sleep(nanoseconds: 150_000_000)
        try harness.stream(1, Self.start("msg_1"), Self.textStart(0), Self.text(0, "hi"), Self.blockStop(0),
                           Self.delta("end_turn", out: 2), Self.messageStop)
        try harness.tap(#"{"s":1,"end":"done"}"#)
        try harness.turnEnded()
        try await waitFor { await log.ended }
        let text = await log.text
        XCTAssertEqual(text, "hi")
        _ = await session.close()
    }

    /// A client that does not load the tap, or says it could not, or a message no stream is open
    /// for, is told whole at once; one whose stream does not begin within the wait is told whole,
    /// and its stream, come late, says nothing (TestTapNotLoaded, TestTapMessageWithoutStream).
    func testWithNoTapLoadedOrNoStreamMessagesAreToldWhole() async throws {
        for first in [nil, #"{"tap":"none"}"#, #"{"tap":"on"}"#] {
            let harness = try SessionHarness(); defer { harness.clean() }
            let session = harness.session(tapWait: 10)
            let log = EventLog.recording(try await session.events(for: request("Hi")))
            try await waitFor { harness.sentCount == 1 }
            if let first { try harness.tap(first) }
            // a stream open for the client that does not load the tap says nothing of it
            if first != #"{"tap":"on"}"# { try harness.tap(#"{"s":1,"open":true}"#) }
            let started = Date()
            try harness.answer("whole", message: "msg_1")
            try await waitFor { await log.text == "whole" }
            XCTAssertLessThan(Date().timeIntervalSince(started), 5, "\(first ?? "no tap"): a message waited for a stream")
            try harness.turnEnded()
            try await waitFor { await log.ended }
            let events = await log.events
            XCTAssertEqual(events.last, .finished(.endTurn))
            _ = await session.close()
        }

        let harness = try SessionHarness(); defer { harness.clean() }
        let session = harness.session(tapWait: 0.3)
        let log = EventLog.recording(try await session.events(for: request("Hi")))
        try await waitFor { harness.sentCount == 1 }
        try harness.tap(#"{"tap":"on"}"#, #"{"s":1,"open":true}"#)
        let started = Date()
        try harness.answer("whole", message: "msg_2")
        try await waitFor { await log.text == "whole" }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.25, "A message whose stream is open waits for it")
        try harness.stream(1, Self.start("msg_2"), Self.textStart(0), Self.text(0, "late"), Self.blockStop(0),
                           Self.delta("end_turn", out: 2), Self.messageStop)
        try harness.tap(#"{"s":1,"end":"done"}"#)
        try harness.turnEnded()
        try await waitFor { await log.ended }
        let text = await log.text
        XCTAssertEqual(text, "whole", "A message told whole is not told again by its late stream")
        _ = await session.close()
    }

    /// A stream cut short after it showed words fails the reply: they can't be taken back. One cut
    /// before it showed anything is an attempt Claude Code asks again after, and the reply goes on
    /// in the attempt that answers (claude_subscription.go:3259-3269, 3864-3876).
    func testAStreamCutShortFailsOnlyAfterItShowedWords() async throws {
        do {
            let harness = try SessionHarness(); defer { harness.clean() }
            let session = harness.session()
            let log = EventLog.recording(try await session.events(for: request("Hi")))
            try await waitFor { harness.sentCount == 1 }
            try harness.tap(#"{"tap":"on"}"#, #"{"s":1,"open":true}"#)
            try harness.stream(1, Self.start("msg_1"), Self.textStart(0), Self.text(0, "par"))
            try harness.tap(#"{"s":1,"end":"cut"}"#)
            try await waitFor { await log.ended }
            let failure = await log.failure as? BridgeFailure
            guard case .clientReported(502, _)? = failure else { return XCTFail("\(String(describing: failure))") }
            harness.exited()
            _ = await session.close()
        }
        let harness = try SessionHarness(); defer { harness.clean() }
        let session = harness.session()
        let log = EventLog.recording(try await session.events(for: request("Hi")))
        try await waitFor { harness.sentCount == 1 }
        try harness.tap(#"{"tap":"on"}"#, #"{"s":1,"open":true}"#)
        try harness.stream(1, Self.start("msg_1"), Self.textStart(0))
        try harness.tap(#"{"s":1,"end":"cut"}"#, #"{"s":2,"open":true}"#)
        try harness.stream(2, Self.start("msg_2"), Self.textStart(0), Self.text(0, "answer"), Self.blockStop(0),
                           Self.delta("end_turn", out: 4), Self.messageStop)
        try harness.tap(#"{"s":2,"end":"done"}"#)
        try harness.answer("answer", message: "msg_2")
        try harness.turnEnded()
        try await waitFor { await log.ended }
        let events = await log.events, failure = await log.failure
        XCTAssertNil(failure)
        XCTAssertEqual(events.joinedText, "answer")
        XCTAssertEqual(events.last, .finished(.endTurn))
        _ = await session.close()
    }

    // MARK: Calls

    /// A message's words go before its calls, and all of its calls in one reply, under Claude
    /// Code's tool-use ids; a call Claude Code makes as its block streams is told once.
    /// Results come back together; each goes to its call as Claude Code makes it, held for one
    /// not made yet.
    func testStreamedWordsGoBeforeCallsAllCallsInOneReplyAndResultsWaitForTheirCall() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        let session = harness.session()
        let first = request("Inspect", tools: tools)
        let log = EventLog.recording(try await session.events(for: first))
        try await waitFor { harness.sentCount == 1 }
        try harness.tap(#"{"tap":"on"}"#, #"{"s":1,"open":true}"#)
        try harness.stream(1, Self.start("msg_c"), Self.textStart(0), Self.text(0, "Looking"), Self.blockStop(0),
                           Self.toolStart(1, "toolu_a", "read"), Self.toolInput(1, #"{\"path\":"#), Self.toolInput(1, #"\"a\"}"#))
        try harness.tool("toolu_a", alias: "read", input: .object(["path": .string("a")]))
        try harness.stream(1, Self.blockStop(1), Self.toolStart(2, "toolu_b", "screenshot"), Self.toolInput(2, #"{\"size\":2}"#),
                           Self.blockStop(2), Self.delta("tool_use", out: 12), Self.messageStop)
        try harness.tap(#"{"s":1,"end":"done"}"#)
        try await waitFor { await log.ended }
        let events = await log.events
        XCTAssertEqual(events, [.usage(.init(inputTokens: 3, outputTokens: 1)), .text("Looking"),
                                .toolUse(.init(id: "toolu_a", name: "read", input: .object(["path": .string("a")]))),
                                .toolUse(.init(id: "toolu_b", name: "screenshot", input: .object(["size": .number(2)]))),
                                .usage(.init(inputTokens: 3, outputTokens: 12)), .finished(.toolUse)])

        var next = first
        next.messages.append(.init(role: "assistant", content: .array([])))
        next.messages.append(.init(role: "user", content: .array([
            .object(["type": .string("tool_result"), "tool_use_id": .string("toolu_a"), "content": .string("A")]),
            .object(["type": .string("tool_result"), "tool_use_id": .string("toolu_b"), "content": .string("B")])])))
        let second = EventLog.recording(try await session.events(for: next))
        try await waitFor { FileManager.default.fileExists(atPath: try! harness.resultURL("toolu_a").path) }
        XCTAssertEqual(try EngineSpool.read(harness.resultURL("toolu_a"))["content"]?.arrayValue?.first?["text"]?.stringValue, "A")
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try harness.resultURL("toolu_b").path), "A result waits for its call")
        try harness.tool("toolu_b", alias: "screenshot", input: .object(["size": .number(2)]))
        try await waitFor { FileManager.default.fileExists(atPath: try! harness.resultURL("toolu_b").path) }
        XCTAssertEqual(try EngineSpool.read(harness.resultURL("toolu_b"))["content"]?.arrayValue?.first?["text"]?.stringValue, "B")
        // the streamed message's rows come late and say nothing
        try harness.answer("Looking", message: "msg_c")
        try harness.toolUseRow([("toolu_a", "read"), ("toolu_b", "screenshot")], message: "msg_c")
        try harness.tap(#"{"s":2,"open":true}"#)
        try harness.stream(2, Self.start("msg_d"), Self.textStart(0), Self.text(0, "Done"), Self.blockStop(0),
                           Self.delta("end_turn", out: 2), Self.messageStop)
        try harness.tap(#"{"s":2,"end":"done"}"#)
        try harness.turnEnded()
        try await waitFor { await second.ended }
        let secondEvents = await second.events
        XCTAssertEqual(secondEvents, [.usage(.init(inputTokens: 3, outputTokens: 1)), .text("Done"), .usage(.init(inputTokens: 3, outputTokens: 2)), .finished(.endTurn)])
        _ = await session.close()
    }

    /// Thinking streams first, its signature closing its block, then the words and the call, in
    /// the order the stream had them; a redacted_thinking block is not told.
    func testThinkingIsToldInOrderBeforeWordsAndCallsAndRedactedThinkingIsNot() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        let session = harness.session()
        let log = EventLog.recording(try await session.events(for: request("Inspect", tools: tools)))
        try await waitFor { harness.sentCount == 1 }
        try harness.tap(#"{"tap":"on"}"#, #"{"s":1,"open":true}"#)
        try harness.stream(1, Self.start("msg_t"), Self.thinkingStart(0), Self.thinking(0, "Weighing"), Self.thinking(0, " the file"))
        try await waitFor { await log.events.contains(.thinking(" the file")) }
        try harness.stream(1, Self.signature(0, "c2lnLXN5bnRoZXRpYw=="), Self.blockStop(0),
                           Self.redactedStart(1), Self.blockStop(1),
                           Self.textStart(2), Self.text(2, "Reading"), Self.blockStop(2),
                           Self.toolStart(3, "toolu_t", "read"), Self.toolInput(3, #"{\"path\":\"a\"}"#), Self.blockStop(3),
                           Self.delta("tool_use", out: 40), Self.messageStop)
        try harness.tap(#"{"s":1,"end":"done"}"#)
        try await waitFor { await log.ended }
        let events = await log.events
        XCTAssertEqual(events, [.usage(.init(inputTokens: 3, outputTokens: 1)), .thinking("Weighing"), .thinking(" the file"),
                                .thinkingSignature("c2lnLXN5bnRoZXRpYw=="), .text("Reading"),
                                .toolUse(.init(id: "toolu_t", name: "read", input: .object(["path": .string("a")]))),
                                .usage(.init(inputTokens: 3, outputTokens: 40)), .finished(.toolUse)])
        _ = await session.close()
    }

    /// Without the tap, a call the helper hands over waits for its message, read 118 to 162 ms
    /// after it (callFirst): the message's words then go before the call, as the model wrote them.
    func testWithoutTheTapAMessagesWordsGoBeforeItsCallThatCameFirst() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        let session = harness.session(callFirst: 0.5)
        let log = EventLog.recording(try await session.events(for: request("Read", tools: tools)))
        try await waitFor { harness.sentCount == 1 }
        try harness.tool("toolu_a", alias: "read", input: .object(["p": .number(1)]))
        try await Task.sleep(nanoseconds: 140_000_000)
        try harness.answer("Reading", message: "msg_r")
        try harness.toolUseRow([("toolu_a", "read")], message: "msg_r", input: .object(["p": .number(1)]), usage: ["input_tokens": 5, "output_tokens": 9])
        try await waitFor { await log.ended }
        let events = await log.events
        XCTAssertEqual(events, [.text("Reading"), .toolUse(.init(id: "toolu_a", name: "read", input: .object(["p": .number(1)]))),
                                .usage(.init(inputTokens: 5, outputTokens: 9)), .finished(.toolUse)])
        try harness.turnEnded()
        harness.exited()
        _ = await session.close()
    }

    /// Claude Code may write the message calling a client's tool only once the call is answered:
    /// the call tells the client itself, and the message written later is left out, its usage
    /// counted in the next reply (TestClaudeTUICallBeforeItsMessage).
    func testAMessageWrittenAfterItsCallIsAnsweredIsLeftOut() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        let session = harness.session(callFirst: 0.2)
        let first = request("Read", tools: tools)
        let started = Date()
        let log = EventLog.recording(try await session.events(for: first))
        try await waitFor { harness.sentCount == 1 }
        try harness.tool("toolu_a", alias: "read", input: .object(["p": .number(1)]))
        try await waitFor { await log.ended }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.2)
        let events = await log.events
        XCTAssertEqual(events, [.toolUse(.init(id: "toolu_a", name: "read", input: .object(["p": .number(1)]))),
                                .usage(.init(inputTokens: 0, outputTokens: 0)), .finished(.toolUse)])
        let second = EventLog.recording(try await session.events(for: results(first, ["toolu_a"])))
        try await waitFor { FileManager.default.fileExists(atPath: try! harness.resultURL("toolu_a").path) }
        try harness.answer("I'll read", message: "msg_late", usage: ["input_tokens": 3, "output_tokens": 40])
        try harness.toolUseRow([("toolu_a", "read")], message: "msg_late", input: .object(["p": .number(1)]),
                               usage: ["input_tokens": 3, "output_tokens": 40])
        try harness.answer("done", message: "msg_ans", usage: ["input_tokens": 3, "output_tokens": 7])
        try harness.turnEnded()
        try await waitFor { await second.ended }
        let secondEvents = await second.events
        XCTAssertEqual(secondEvents, [.text("done"), .usage(.init(inputTokens: 6, outputTokens: 47)), .finished(.endTurn)])
        _ = await session.close()
    }

    /// Calls Claude Code makes side by side before their message are one reply; a call of a
    /// message left out is told as soon as it is made (TestClaudeTUIParallelCallsBeforeTheirMessage).
    func testCallsMadeBeforeTheirMessageGoTogetherAndALeftOutMessagesCallIsToldWhenMade() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        let session = harness.session(callFirst: 0.3)
        let first = request("Both", tools: tools)
        let log = EventLog.recording(try await session.events(for: first))
        try await waitFor { harness.sentCount == 1 }
        try harness.tool("toolu_a", alias: "read"); try harness.tool("toolu_b", alias: "screenshot")
        try await waitFor { await log.ended }
        let calls = await log.calls
        XCTAssertEqual(calls.map(\.id), ["toolu_a", "toolu_b"])
        let second = EventLog.recording(try await session.events(for: results(first, ["toolu_a", "toolu_b"])))
        try await waitFor { FileManager.default.fileExists(atPath: try! harness.resultURL("toolu_b").path) }
        try harness.toolUseRow([("toolu_a", "read"), ("toolu_b", "screenshot")], message: "msg_late", usage: ["input_tokens": 3, "output_tokens": 40])
        try harness.answer("done", message: "msg_ans", usage: ["input_tokens": 3, "output_tokens": 7])
        try harness.turnEnded()
        try await waitFor { await second.ended }
        let text = await second.text, secondEvents = await second.events
        XCTAssertEqual(text, "done")
        XCTAssertTrue(secondEvents.contains(.usage(.init(inputTokens: 6, outputTokens: 47))))
        _ = await session.close()

        // one at a time, the message written between them
        let other = try SessionHarness(); defer { other.clean() }
        let sequential = other.session(callFirst: 0.3)
        let ask = request("One by one", tools: tools)
        let one = EventLog.recording(try await sequential.events(for: ask))
        try await waitFor { other.sentCount == 1 }
        try other.tool("toolu_a", alias: "read")
        try await waitFor { await one.ended }
        var next = results(ask, ["toolu_a"])
        let two = EventLog.recording(try await sequential.events(for: next))
        try await waitFor { FileManager.default.fileExists(atPath: try! other.resultURL("toolu_a").path) }
        try other.toolUseRow([("toolu_a", "read"), ("toolu_b", "read")], message: "msg_late", input: .object(["p": .number(2)]),
                             usage: ["input_tokens": 3, "output_tokens": 40])
        try await Task.sleep(nanoseconds: 100_000_000)
        let made = Date()
        try other.tool("toolu_b", alias: "read", input: nil)
        try await waitFor { await two.ended }
        XCTAssertLessThan(Date().timeIntervalSince(made), 0.25, "A left-out message's call does not wait for a message to come")
        let twoEvents = await two.events
        XCTAssertEqual(twoEvents, [.toolUse(.init(id: "toolu_b", name: "read", input: .object(["p": .number(2)]))),
                                   .usage(.init(inputTokens: 3, outputTokens: 40)), .finished(.toolUse)])
        next = results(next, ["toolu_b"])
        let three = EventLog.recording(try await sequential.events(for: next))
        try await waitFor { FileManager.default.fileExists(atPath: try! other.resultURL("toolu_b").path) }
        try other.answer("done", message: "msg_ans", usage: ["input_tokens": 3, "output_tokens": 7])
        try other.turnEnded()
        try await waitFor { await three.ended }
        let threeEvents = await three.events
        XCTAssertEqual(threeEvents, [.text("done"), .usage(.init(inputTokens: 3, outputTokens: 7)), .finished(.endTurn)])
        _ = await sequential.close()
    }

    /// A message's second call may come before its input is written, with no arguments: held, it
    /// is told whole by the message written after it (TestClaudeTUICallWithNoInputYetWaitsForItsMessage).
    func testACallWithNoInputYetWaitsForItsMessage() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        let session = harness.session(callFirst: 0.15)
        let first = request("Read", tools: tools)
        let log = EventLog.recording(try await session.events(for: first))
        try await waitFor { harness.sentCount == 1 }
        try harness.tool("toolu_a", alias: "read")
        try await waitFor { await log.ended }
        let second = EventLog.recording(try await session.events(for: results(first, ["toolu_a"])))
        try await waitFor { FileManager.default.fileExists(atPath: try! harness.resultURL("toolu_a").path) }
        try harness.tool("toolu_b", alias: "read", input: nil)
        try await Task.sleep(nanoseconds: 450_000_000)
        let early = await second.events
        XCTAssertTrue(early.isEmpty, "A call with no input is never told as it came")
        try harness.toolUseRow([("toolu_a", "read"), ("toolu_b", "read")], message: "msg_late", input: .object(["p": .number(2)]))
        try await waitFor { await second.ended }
        let calls = await second.calls
        XCTAssertEqual(calls, [.init(id: "toolu_b", name: "read", input: .object(["p": .number(2)]))])
        try harness.turnEnded()
        harness.exited()
        _ = await session.close()
    }

    // MARK: The tap's reader

    func testTapReadsItsLines() throws {
        let root = try Self.ownedFolder(); defer { try? FileManager.default.removeItem(at: root) }
        var tap = try XCTUnwrap(ClaudeTap.make(run: root, temporary: root))
        XCTAssertEqual(tap.environment["BUN_OPTIONS"], "--preload " + root.appendingPathComponent(ClaudeTap.scriptName).path)
        XCTAssertEqual(tap.environment[OfficialCLI.tapVariable], root.appendingPathComponent(ClaudeTap.outputName).path)
        func write(_ lines: String...) throws {
            let handle = try XCTUnwrap(FileHandle(forWritingAtPath: tap.output.path)); defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: Data(lines.map { $0 + "\n" }.joined().utf8))
        }
        func types(_ events: [JSONValue]) -> [String] { events.compactMap { $0["type"]?.stringValue } }
        XCTAssertFalse(tap.on)
        try write(#"{"tap":"on"}"#, #"{"s":1,"open":true}"#)
        XCTAssertEqual(tap.read(), [])
        XCTAssertTrue(tap.on && tap.going(bare: true))
        XCTAssertTrue(tap.waits(for: "msg_1"))
        // a stream cut short ends with a message_stop and nothing after its end says more
        try write(#"{"s":1,"e":\#(Self.start("msg_1"))}"#, #"{"s":1,"e":\#(Self.text(0, "a"))}"#, #"{"s":1,"end":"cut"}"#,
                  #"{"s":1,"e":\#(Self.text(0, "b"))}"#)
        XCTAssertEqual(types(tap.read()), ["message_start", "content_block_delta", "message_stop"])
        XCTAssertFalse(tap.waits(for: "msg_1"), "A message whose stream began waits no more")
        XCTAssertFalse(tap.going(bare: false))
        // a message told whole: its stream says nothing; a line comes in pieces
        tap.drop("msg_2")
        try write(#"{"s":2,"open":true}"#, #"{"s":2,"e":\#(Self.start("msg_2"))}"#, #"{"s":2,"end":"done"}"#)
        XCTAssertEqual(tap.read(), [])
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: tap.output.path))
        try handle.seekToEnd(); try handle.write(contentsOf: Data(#"{"s":3,"open":true}"#.utf8)); try handle.close()
        XCTAssertEqual(tap.read(), [])
        XCTAssertFalse(tap.going(bare: true))
        try write("", #"{"s":3,"e":\#(Self.start("msg_3"))}"#)
        XCTAssertEqual(types(tap.read()), ["message_start"])
        XCTAssertEqual(types(tap.endAll()), ["message_stop"], "A stream still going at the turn's end ends there")
        tap.compact()
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: tap.output.path)[.size] as? Int, 0)
        tap.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: tap.scriptURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tap.output.path))
    }

    func testATapNeedsAPathBunOptionsCanCarry() throws {
        let root = try Self.ownedFolder(); defer { try? FileManager.default.removeItem(at: root) }
        let spaced = root.appendingPathComponent("a b")
        try FileManager.default.createDirectory(at: spaced, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        XCTAssertNil(ClaudeTap.make(run: spaced, temporary: spaced))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: spaced.path).isEmpty, "A tap not made leaves nothing")
        XCTAssertNil(OfficialCLI.tapEnvironment(preload: "/a b/tap.js", output: "/a/out"))
        XCTAssertNil(OfficialCLI.tapEnvironment(preload: "tap.js", output: "/a/out"))
        let made = try XCTUnwrap(ClaudeTap.make(run: spaced, temporary: root))
        XCTAssertEqual(made.folder.deletingLastPathComponent().standardizedFileURL.path, root.standardizedFileURL.path)
        XCTAssertTrue(made.folder.lastPathComponent.hasPrefix(ClaudeTap.folderPrefix))
        XCTAssertEqual(try permissions(made.folder), 0o700)
        // a folder a run left a day ago is swept; one a live run has is never, however old
        let left = root.appendingPathComponent(ClaudeTap.folderPrefix + "leftover")
        try FileManager.default.createDirectory(at: left, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data().write(to: left.appendingPathComponent(ClaudeTap.outputName))
        let dayAgo = Date().addingTimeInterval(-90_000)
        for folder in [left, made.folder] { try FileManager.default.setAttributes([.modificationDate: dayAgo], ofItemAtPath: folder.path) }
        let another = try XCTUnwrap(ClaudeTap.make(run: spaced, temporary: root))
        XCTAssertFalse(FileManager.default.fileExists(atPath: left.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: made.output.path))
        made.remove(); another.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: made.folder.path))
    }

    /// The script, run with a stand-in for Bun's FetchSession: it copies the main turn's stream,
    /// leaves Claude Code's own copy whole, skips other requests and pings, and takes itself out
    /// of what the client hands on. Skipped where this computer has no Node.
    func testTheTapScriptCopiesOnlyTheMainTurnsStream() throws {
        guard let node = ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"].first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("No Node on this computer to run the tap script with.")
        }
        let root = try Self.ownedFolder(); defer { try? FileManager.default.removeItem(at: root) }
        let tap = try XCTUnwrap(ClaudeTap.make(run: root, temporary: root))
        let runner = root.appendingPathComponent("runner.js")
        try Data(#"""
        const body = 'event: message_start\ndata: {"type":"message_start","message":{"id":"msg_1"}}\n\n' +
          'event: ping\ndata: {"type":"ping"}\n\n' +
          'data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}}\r\n\r\n' +
          'data: {"type":"message_stop"}\n\n';
        class Real {
          async fetch(input, init) { return new Response(body, { headers: { "content-type": "text/event-stream" } }); }
        }
        globalThis.Bun = { FetchSession: Real };
        require(process.argv[2]);
        (async () => {
          const session = new Bun.FetchSession();
          const main = await session.fetch("https://api.anthropic.com/v1/messages?beta=true", { headers: { "x-claude-code-request-class": "main" } });
          // read as Claude Code's SDK reads a stream: through the response's body
          const reader = main.body.getReader(), decoder = new TextDecoder();
          let theirs = "";
          for (;;) {
            const { done, value } = await reader.read();
            if (done) break;
            theirs += decoder.decode(value, { stream: true });
          }
          const other = await session.fetch("https://api.anthropic.com/v1/messages", { headers: { "x-claude-code-request-class": "background" } });
          await other.text();
          await new Promise((r) => setTimeout(r, 100));
          process.stdout.write(JSON.stringify({ whole: theirs === body, tap: process.env.CLAUDE_POOL_TAP ?? null, bun: process.env.BUN_OPTIONS ?? null }));
        })();
        """#.utf8).write(to: runner)
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [runner.path, tap.scriptURL.path]
        var environment = tap.environment
        environment["BUN_OPTIONS"] = "--smol " + (environment["BUN_OPTIONS"] ?? "")
        environment["PATH"] = "/usr/bin:/bin"
        process.environment = environment
        process.currentDirectoryURL = root
        process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let said = try JSONDecoder().decode(JSONValue.self, from: output.fileHandleForReading.readDataToEndOfFile())
        XCTAssertEqual(said["whole"], .bool(true), "Claude Code reads its own copy of the stream whole")
        XCTAssertEqual(said["tap"], .null, "The tap's file is not handed on")
        XCTAssertEqual(said["bun"], .string("--smol"), "Only the tap's own preload is taken out")
        let lines = try String(contentsOf: tap.output, encoding: .utf8).split(separator: "\n").map {
            try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
        }
        XCTAssertEqual(lines.first, .object(["tap": .string("on")]))
        XCTAssertEqual(lines.compactMap { $0["e"]?["type"]?.stringValue }, ["message_start", "content_block_delta", "message_stop"])
        XCTAssertEqual(lines.last, .object(["s": .number(1), "end": .string("done")]))
        XCTAssertEqual(lines.filter { $0["open"] != nil }.count, 1, "Only the main turn's request is copied")
    }

    /// A run let go while it waits on its call ends with the client's interrupt and keeps its session; the
    /// run that resumes it is told the call and its result, not the conversation before them.
    func testASessionLetGoOnItsCallsIsResumedWithTheirResults() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        harness.exitAfterInterrupts = 1
        let first = harness.session()
        let opening = request("Summarise the synthetic notes.", tools: tools)
        let log = EventLog.recording(try await first.events(for: opening))
        try await waitFor { harness.sentCount == 1 }
        try harness.tap(#"{"tap":"on"}"#, #"{"s":1,"open":true}"#)
        try harness.stream(1, Self.start("msg_shelf"), Self.toolStart(0, "toolu_shelf", "read"), Self.toolInput(0, #"{\"path\":\"notes\"}"#),
                           Self.blockStop(0), Self.delta("tool_use", out: 7), Self.messageStop)
        try harness.tool("toolu_shelf", alias: "read", input: .object(["path": .string("notes")]))
        try harness.tap(#"{"s":1,"end":"done"}"#)
        try await waitFor { await log.ended }
        try harness.toolUseRow([("toolu_shelf", "read")], message: "msg_shelf")
        let transcript = try harness.transcriptURL
        let shelved = await first.shelveCalls()
        let saved = try XCTUnwrap(shelved)
        XCTAssertGreaterThanOrEqual(harness.interruptCount, 1, "The run is let go with the client's own interrupt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcript.path), "The session outlives its run")

        let second = harness.session()
        let resumed = await second.resume(from: saved.holding(1))
        XCTAssertTrue(resumed)
        var next = opening
        next.messages.append(.init(role: "assistant", content: .array([.object(["type": .string("tool_use"), "id": .string("toolu_shelf"),
                                                                                "name": .string("read"), "input": .object(["path": .string("notes")])])])))
        next.messages.append(.init(role: "user", content: .array([.object(["type": .string("tool_result"), "tool_use_id": .string("toolu_shelf"),
                                                                           "content": .string("Synthetic notes: three items.")])])))
        _ = EventLog.recording(try await second.events(replaying: VerifiedToolReplay(request: next)))
        try await waitFor { harness.sentCount == 2 }
        let arguments = try XCTUnwrap(harness.plan).arguments
        XCTAssertEqual(Array(arguments.prefix(2)), ["--resume", saved.session])
        XCTAssertTrue(harness.typed.contains("Synthetic notes: three items."))
        XCTAssertFalse(harness.typed.contains("Summarise the synthetic notes."), "The conversation before the call is the session's")
        _ = await second.cancel()
        _ = await second.requestExit()
        saved.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: transcript.path))
    }

    // MARK: Fixtures

    private func request(_ text: String, tools: [BridgeTool]? = nil) -> BridgeRequest {
        BridgeRequest(model: "claude-sonnet", messages: [.init(role: "user", content: .string(text))], tools: tools)
    }
    /// The request after `previous` with the client's results for `ids`.
    private func results(_ previous: BridgeRequest, _ ids: [String]) -> BridgeRequest {
        var next = previous
        next.messages.append(.init(role: "assistant", content: .array([])))
        next.messages.append(.init(role: "user", content: .array(ids.map {
            .object(["type": .string("tool_result"), "tool_use_id": .string($0), "content": .string("result of " + $0)])
        })))
        return next
    }
    private func permissions(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }
    private static func ownedFolder() throws -> URL {
        let folder = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/engine-taps/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return folder
    }

    // Anthropic stream events, as the tap writes them (tap_test.go tapReply).
    static func start(_ id: String) -> String {
        #"{"type":"message_start","message":{"id":"\#(id)","model":"claude-sonnet-5-5","usage":{"input_tokens":3,"output_tokens":1}}}"#
    }
    static func textStart(_ index: Int) -> String { #"{"type":"content_block_start","index":\#(index),"content_block":{"type":"text","text":""}}"# }
    static func text(_ index: Int, _ text: String) -> String {
        #"{"type":"content_block_delta","index":\#(index),"delta":{"type":"text_delta","text":"\#(text)"}}"#
    }
    static func thinkingStart(_ index: Int) -> String {
        #"{"type":"content_block_start","index":\#(index),"content_block":{"type":"thinking","thinking":"","signature":""}}"#
    }
    static func thinking(_ index: Int, _ text: String) -> String {
        #"{"type":"content_block_delta","index":\#(index),"delta":{"type":"thinking_delta","thinking":"\#(text)"}}"#
    }
    static func signature(_ index: Int, _ signature: String) -> String {
        #"{"type":"content_block_delta","index":\#(index),"delta":{"type":"signature_delta","signature":"\#(signature)"}}"#
    }
    static func redactedStart(_ index: Int) -> String {
        #"{"type":"content_block_start","index":\#(index),"content_block":{"type":"redacted_thinking","data":"ZW5jcnlwdGVkLXN5bnRoZXRpYw=="}}"#
    }
    static func toolStart(_ index: Int, _ id: String, _ alias: String) -> String {
        #"{"type":"content_block_start","index":\#(index),"content_block":{"type":"tool_use","id":"\#(id)","name":"mcp__pool__\#(alias)","input":{}}}"#
    }
    /// `json` as it goes in a JSON string: its quotes escaped.
    static func toolInput(_ index: Int, _ json: String) -> String {
        #"{"type":"content_block_delta","index":\#(index),"delta":{"type":"input_json_delta","partial_json":"\#(json)"}}"#
    }
    static func blockStop(_ index: Int) -> String { #"{"type":"content_block_stop","index":\#(index)}"# }
    static func delta(_ reason: String, out: Int) -> String {
        #"{"type":"message_delta","delta":{"stop_reason":"\#(reason)"},"usage":{"output_tokens":\#(out)}}"#
    }
    static let messageStop = #"{"type":"message_stop"}"#
}
