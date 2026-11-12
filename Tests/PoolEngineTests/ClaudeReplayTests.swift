import Foundation
import XCTest
import PoolCore
import PoolRuntime
@testable import PoolEngine

/// The saved-session replay, prompt rendering and transcript rows, pinned to the shapes
/// Claude Code produces.
final class ClaudeReplayTests: XCTestCase {
    private let object = JSONValue.object(["type": .string("object")])
    private func text(_ value: String) -> JSONValue { .object(["type": .string("text"), "text": .string(value)]) }

    func testAConversationWithAReplyGoesInASavedSessionAndOnlyItsLastTurnIsTyped() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        let session = harness.session()
        let image = try sessionFixtureImage(red: 255)
        let r = BridgeRequest(model: "claude-sonnet", messages: [
            .init(role: "user", content: .array([image, text("what is it")])),
            .init(role: "assistant", content: .array([.object(["type": .string("thinking"), "thinking": .string("hm"), "signature": .string("x")]), text("a red square")])),
            .init(role: "user", content: .string("and its size?"))],
            system: .string("rules for the synthetic project"), tools: [BridgeTool(name: "read", inputSchema: object)])
        let reply = Task { try await collectEvents(try await session.events(for: r)) }
        try await waitFor { harness.sentCount == 1 }
        XCTAssertEqual(harness.typed, "and its size?", "The run is typed the last turn alone")
        XCTAssertTrue(harness.imagePaths.isEmpty, "History images live in the transcript, never pasted")
        let plan = try XCTUnwrap(harness.plan)
        let resume = try XCTUnwrap(plan.arguments.firstIndex(of: "--resume"))
        let sid = plan.arguments[resume + 1]
        XCTAssertEqual(sid, plan.sessionID.uuidString.lowercased(), "The worker id names the session")
        XCTAssertFalse(plan.arguments.contains("--session-id"))
        XCTAssertTrue(plan.arguments.contains("--append-system-prompt-file"))
        let saved = try XCTUnwrap(harness.resumedTranscript)
        let lines = String(decoding: saved, as: UTF8.self).split(separator: "\n").map { try! JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.map { $0["type"]?.stringValue }, ["user", "assistant"])
        XCTAssertEqual(lines[0]["parentUuid"], .null)
        XCTAssertEqual(lines[1]["parentUuid"], lines[0]["uuid"])
        XCTAssertEqual(lines.map { $0["sessionId"]?.stringValue }, [sid, sid])
        XCTAssertEqual(lines.map { $0["cwd"]?.stringValue }, [plan.directory.path, plan.directory.path])
        XCTAssertEqual(lines.map { $0["isSidechain"] }, [.bool(false), .bool(false)])
        XCTAssertEqual(lines.map { $0["userType"]?.stringValue }, ["external", "external"])
        for line in lines {
            XCTAssertEqual(Set(line.objectValue?.keys.map { $0 } ?? []),
                           ["parentUuid", "isSidechain", "userType", "cwd", "sessionId", "type", "message", "uuid", "timestamp"])
        }
        let user = String(decoding: try XCTUnwrap(lines[0]["message"]).encoded(), as: UTF8.self)
        XCTAssertEqual(lines[0]["message"]?["content"]?.arrayValue?.filter { $0["type"]?.stringValue == "image" }, [image],
                       "The history's image is an image block in the user line")
        XCTAssertTrue(user.contains("what is it"))
        for absent in ["rules for the synthetic project", "cache_control", "x-anthropic-billing-header", "and its size?"] {
            XCTAssertFalse(user.contains(absent), absent)
        }
        XCTAssertEqual(lines[1]["message"]?["content"], .array([text("a red square")]))
        XCTAssertEqual(lines[1]["message"]?["usage"], .object(["input_tokens": .number(0), "output_tokens": .number(0)]))
        XCTAssertEqual(lines[1]["message"]?["stop_reason"]?.stringValue, "end_turn")
        // where the client looks: the real path's project folder
        let config = try harness.workspace.accountDirectory(harness.account.id)
        let realFolder = config.appendingPathComponent("projects").appendingPathComponent(ClaudeReplay.projectName(ClaudeReplay.realPath(plan.directory.path)))
        XCTAssertEqual(try harness.transcriptURL.deletingLastPathComponent().standardizedFileURL, realFolder.standardizedFileURL)
        try harness.answer("It is one pixel.", usage: ["input_tokens": 9, "output_tokens": 4])
        try harness.turnEnded()
        let events = try await reply.value
        XCTAssertEqual(events.joinedText, "It is one pixel.", "Rows written before the start are not read as this turn")
        let transcript = try harness.transcriptURL
        _ = await session.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: transcript.path))
    }

    func testOnlyAConversationWithAWordedReplyIsResumed() async throws {
        let cases: [[BridgeMessage]] = [
            [.init(role: "user", content: .string("only one"))],
            [.init(role: "user", content: .string("Inspect")),
             .init(role: "assistant", content: .array([.object(["type": .string("tool_use"), "id": .string("c1"), "name": .string("read"), "input": .object([:])])])),
             .init(role: "user", content: .string("go on"))],
            [.init(role: "user", content: .string("b1")), .init(role: "assistant", content: .string("  ")), .init(role: "user", content: .string("b2"))]]
        for messages in cases {
            let harness = try SessionHarness(); defer { harness.clean() }
            let session = harness.session()
            let reply = Task { try await collectEvents(try await session.events(for: BridgeRequest(model: "claude-sonnet", messages: messages,
                                                                                                   tools: [BridgeTool(name: "read", inputSchema: self.object)]))) }
            try await waitFor { harness.sentCount == 1 }
            XCTAssertFalse(try XCTUnwrap(harness.plan).arguments.contains("--resume"))
            XCTAssertTrue(harness.typed.contains("Human: "))
            try harness.answer("ok"); try harness.turnEnded()
            _ = try await reply.value
            _ = await session.close()
        }
    }

    func testAResumedStartTheClientRefusesIsTriedOnceMoreToldWhole() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        harness.exitOnResume = true
        let session = harness.session()
        let r = BridgeRequest(model: "claude-sonnet", messages: [
            .init(role: "user", content: .string("what is it")), .init(role: "assistant", content: .string("a square")),
            .init(role: "user", content: .string("and its size?"))])
        let reply = Task { try await collectEvents(try await session.events(for: r)) }
        try await waitFor { harness.sentCount == 1 }
        let plans = harness.plans
        XCTAssertEqual(plans.count, 2)
        XCTAssertTrue(plans[0].arguments.contains("--resume"))
        XCTAssertFalse(plans[1].arguments.contains("--resume"))
        XCTAssertEqual(plans[1].arguments[try XCTUnwrap(plans[1].arguments.firstIndex(of: "--session-id")) + 1], harness.sessionKey)
        for part in ["<conversation_history>", "Human: what is it", "Assistant: a square", "The turn to answer now:", "Human: and its size?", "</current_turn>"] {
            XCTAssertTrue(harness.typed.contains(part), part)
        }
        try harness.answer("Small."); try harness.turnEnded()
        let events = try await reply.value
        XCTAssertEqual(events.joinedText, "Small.")
        _ = await session.close()
    }

    func testCompletedToolHistoryIsTypedWithItsCallsAndResults() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        let session = harness.session()
        let r = BridgeRequest(model: "claude-sonnet", messages: [
            .init(role: "user", content: .string("Earlier")), .init(role: "assistant", content: .string("Done before")),
            .init(role: "user", content: .string("Inspect")),
            .init(role: "assistant", content: .array([.object(["type": .string("tool_use"), "id": .string("completed"), "name": .string("read"), "input": .object(["path": .string("a")])])])),
            .init(role: "user", content: .array([.object(["type": .string("tool_result"), "tool_use_id": .string("completed"), "content": .string("Already executed")])]))],
            tools: [BridgeTool(name: "read", inputSchema: object)])
        do { _ = try await session.events(for: r); XCTFail("A fresh tool result was accepted") }
        catch { XCTAssertEqual(error as? BridgeFailure, .invalidRequest("This tool result has no live Claude session.")) }
        XCTAssertNil(harness.plan)
        let reply = Task { try await collectEvents(try await session.events(replaying: VerifiedToolReplay(request: r))) }
        try await waitFor { harness.sentCount == 1 }
        XCTAssertTrue(try XCTUnwrap(harness.plan).arguments.contains("--resume"))
        XCTAssertEqual(harness.typed, "Human: Inspect\n\nAssistant: \n[tool call mcp__pool__read id=completed args={\"path\":\"a\"}]\n\n" +
                       "Human: \n[tool result id=completed]\nAlready executed\n\n" + ClaudePrompt.pastCallsNote)
        for old in ["Conversation context supplied by the client", "Completed tool call", "Recorded result", "Message from the connected client"] {
            XCTAssertFalse(harness.typed.contains(old), old)
        }
        try harness.answer("Continued after tool"); try harness.turnEnded()
        _ = try await reply.value
        _ = await session.close()
    }

    func testHistoryImagesHaveNoPasteLimit() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        let session = harness.session()
        let images = try (0..<20).map { try sessionFixtureImage(red: UInt8($0 * 10)) }
        let r = BridgeRequest(model: "claude-sonnet", messages: [
            .init(role: "user", content: .array(images + [text("all of these")])), .init(role: "assistant", content: .string("twenty squares")),
            .init(role: "user", content: .string("which is red?"))])
        let reply = Task { try await collectEvents(try await session.events(for: r)) }
        try await waitFor { harness.sentCount == 1 }
        XCTAssertTrue(harness.imagePaths.isEmpty)
        let saved = try XCTUnwrap(harness.resumedTranscript)
        let first = try JSONDecoder().decode(JSONValue.self, from: Data(String(decoding: saved, as: UTF8.self).split(separator: "\n")[0].utf8))
        XCTAssertEqual(first["message"]?["content"]?.arrayValue?.filter { $0["type"]?.stringValue == "image" }.count, 20)
        try harness.answer("The first."); try harness.turnEnded()
        _ = try await reply.value
        _ = await session.close()
    }

    // MARK: Units

    /// A session cut before a call is a copy of its rows before the answer that made it, under the
    /// copy's own session id; the saved session stays whole. Rows modelled on Claude Code's transcript.
    func testASessionIsCopiedUpToTheAnswerThatMadeACall() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fork-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config"), work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let from = UUID().uuidString.lowercased(), to = UUID().uuidString.lowercased()
        func row(_ type: String, _ message: String, side: Bool = false) -> String {
            #"{"parentUuid":null,"isSidechain":\#(side),"type":"\#(type)","sessionId":"\#(from)","message":\#(message)}"#
        }
        let rows = [
            row("user", #"{"role":"user","content":"Read the synthetic notes."}"#),
            row("assistant", #"{"id":"msg_side","role":"assistant","content":[{"type":"tool_use","id":"toolu_fixture_02","name":"mcp__pool__Read","input":{}}]}"#, side: true),
            row("assistant", #"{"id":"msg_one","role":"assistant","content":[{"type":"tool_use","id":"toolu_fixture_01","name":"mcp__pool__Read","input":{"n":1.0}}]}"#),
            row("user", #"{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_fixture_01","content":"One."}]}"#),
            #"{"type":"api-request","sessionId":"\#(from)"}"#,
            row("assistant", #"{"id":"msg_two","role":"assistant","content":[{"type":"thinking","thinking":"","signature":"c2ln"}]}"#),
            row("assistant", #"{"id":"msg_two","role":"assistant","content":[{"type":"tool_use","id":"toolu_fixture_02","name":"mcp__pool__Read","input":{}}]}"#),
            row("user", #"{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_fixture_02","content":"Two."}]}"#),
            row("assistant", #"{"id":"msg_three","role":"assistant","content":[{"type":"text","text":"Two notes."}]}"#)]
        let saved = Data((rows.joined(separator: "\n") + "\n").utf8)
        _ = try ClaudeReplay.write(saved, config: config, work: work, session: from)

        XCTAssertTrue(ClaudeReplay.fork(config: config, work: work, from: from, to: to, before: ["toolu_fixture_02"]))
        let folder = try XCTUnwrap(ClaudeReplay.projectDirectories(config: config, work: work).last)
        let copy = try String(contentsOf: folder.appendingPathComponent(to + ".jsonl"), encoding: .utf8)
        XCTAssertEqual(copy, rows[..<5].joined(separator: "\n").replacingOccurrences(of: from, with: to) + "\n",
                       "Every row before the answer's first, byte for byte, naming the copy")
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(from + ".jsonl")), saved, "The saved session stays whole")
        XCTAssertFalse(ClaudeReplay.fork(config: config, work: work, from: from, to: UUID().uuidString.lowercased(), before: ["toolu_fixture_09"]))
        XCTAssertFalse(ClaudeReplay.fork(config: config, work: work, from: from, to: to, before: ["toolu_fixture_02"]),
                       "A copy is never written over")
    }

    /// A session is copied up to where its last turn began, and only there: between an answer that
    /// calls nothing and a message that brings no result.
    func testASessionIsCopiedUpToWhereItsLastTurnBegan() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fork-turn-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config"), work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let from = UUID().uuidString.lowercased()
        func row(_ type: String, _ message: String, side: Bool = false) -> String {
            #"{"parentUuid":null,"isSidechain":\#(side),"type":"\#(type)","sessionId":"\#(from)","message":\#(message)}"#
        }
        // Claude Code's rows for a turn with a call, its end, and a turn typed after it
        let rows = [
            row("user", #"{"role":"user","content":"Read the synthetic notes."}"#),
            row("assistant", #"{"id":"msg_one","role":"assistant","content":[{"type":"thinking","thinking":"","signature":"c2ln"}]}"#),
            row("assistant", #"{"id":"msg_one","role":"assistant","content":[{"type":"tool_use","id":"toolu_fixture_01","name":"mcp__pool__Read","input":{}}]}"#),
            row("user", #"{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_fixture_01","content":"One."}]}"#),
            #"{"type":"api-request","sessionId":"\#(from)"}"#,
            row("assistant", #"{"id":"msg_two","role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"One note."}]}"#),
            #"{"type":"system","subtype":"turn_duration","sessionId":"\#(from)"}"#,
            row("assistant", #"{"id":"msg_side","role":"assistant","content":[{"type":"tool_use","id":"toolu_fixture_09","name":"mcp__pool__Read","input":{}}]}"#, side: true),
            #"{"type":"api-request","sessionId":"\#(from)"}"#,
            row("user", #"{"role":"user","content":"Synthetic: suggest the next message."}"#),
            row("assistant", #"{"id":"msg_three","role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"Which is longest?"}]}"#)]
        let saved = Data((rows.joined(separator: "\n") + "\n").utf8)
        _ = try ClaudeReplay.write(saved, config: config, work: work, session: from)
        XCTAssertEqual(ClaudeReplay.length(config: config, work: work, session: from), saved.count)
        XCTAssertNil(ClaudeReplay.length(config: config, work: work, session: UUID().uuidString.lowercased()))
        func bytes(_ count: Int) -> Int { (rows[..<count].joined(separator: "\n") + "\n").utf8.count }
        func fork(_ bytes: Int) -> String? {
            let to = UUID().uuidString.lowercased()
            guard ClaudeReplay.fork(config: config, work: work, from: from, to: to, upTo: bytes) else { return nil }
            let folder = ClaudeReplay.projectDirectories(config: config, work: work).last!
            return (try? String(contentsOf: folder.appendingPathComponent(to + ".jsonl"), encoding: .utf8))?.replacingOccurrences(of: to, with: from)
        }

        // where the typed turn began: after the turn's end, a side task's row and the next request's own rows either side
        for count in [7, 8, 9] {
            XCTAssertEqual(fork(bytes(count)), rows[..<count].joined(separator: "\n") + "\n", "Every row before the turn, byte for byte, naming the copy")
        }
        XCTAssertEqual(fork(bytes(6)), rows[..<6].joined(separator: "\n") + "\n", "The turn's end row may come after the length was taken")
        XCTAssertNil(fork(bytes(5)), "Before the reply was written: the answer is not all there")
        XCTAssertNil(fork(bytes(3)), "After an answer that made a call")
        XCTAssertNil(fork(bytes(4)), "After a call's result")
        XCTAssertNil(fork(bytes(2)), "Between an answer's own rows")
        XCTAssertNil(fork(bytes(1)), "After the person's message")
        XCTAssertNil(fork(bytes(7) - 3), "Inside a row")
        XCTAssertNil(fork(0)); XCTAssertNil(fork(saved.count + 1))
        XCTAssertNil(fork(saved.count), "Nothing after it: the turn's own message is not there, so nothing says a turn began here")
        XCTAssertEqual(ClaudeReplay.forkRefusal(config: config, work: work, from: from, to: UUID().uuidString.lowercased(), upTo: saved.count), "nothing_after")
        XCTAssertEqual(try Data(contentsOf: ClaudeReplay.projectDirectories(config: config, work: work).last!.appendingPathComponent(from + ".jsonl")),
                       saved, "The saved session stays whole")
        // an answer cut off, and the client's own error row, are not where a turn of the conversation ends
        for (name, last) in [("cut off", row("assistant", #"{"id":"msg_cut","role":"assistant","stop_reason":null,"content":[{"type":"text","text":"One no"}]}"#)),
                             ("the client's error", #"{"type":"assistant","isApiErrorMessage":true,"sessionId":"\#(from)","message":{"id":"x","model":"<synthetic>","stop_reason":"stop_sequence","content":[{"type":"text","text":"API Error"}]}}"#)] {
            let other = UUID().uuidString.lowercased()
            let stopped = [rows[0].replacingOccurrences(of: from, with: other), last.replacingOccurrences(of: from, with: other)]
            let data = Data((stopped.joined(separator: "\n") + "\n").utf8)
            _ = try ClaudeReplay.write(data, config: config, work: work, session: other)
            XCTAssertEqual(ClaudeReplay.forkRefusal(config: config, work: work, from: other, to: UUID().uuidString.lowercased(), upTo: data.count),
                           "after_unfinished", name)
        }
        XCTAssertEqual(ClaudeReplay.forkRefusal(config: config, work: work, from: from, to: UUID().uuidString.lowercased(), upTo: bytes(3)), "after_call")
        XCTAssertEqual(ClaudeReplay.forkRefusal(config: config, work: work, from: from, to: UUID().uuidString.lowercased(), upTo: bytes(5)), "after_message")
        XCTAssertEqual(ClaudeReplay.forkRefusal(config: config, work: work, from: from, to: UUID().uuidString.lowercased(), upTo: bytes(7) - 3), "inside_row")
        let taken = UUID().uuidString.lowercased()
        XCTAssertTrue(ClaudeReplay.fork(config: config, work: work, from: from, to: taken, upTo: bytes(7)))
        XCTAssertFalse(ClaudeReplay.fork(config: config, work: work, from: from, to: taken, upTo: bytes(7)), "A copy is never written over")

        // a session whose run has ended is cut where it is: its id and the folder Claude Code keeps beside it stay
        let folder = try XCTUnwrap(ClaudeReplay.projectDirectories(config: config, work: work).last)
        let beside = folder.appendingPathComponent(from).appendingPathComponent("tool-results")
        try FileManager.default.createDirectory(at: beside, withIntermediateDirectories: true)
        try Data("synthetic".utf8).write(to: beside.appendingPathComponent("result.txt"))
        let file = folder.appendingPathComponent(from + ".jsonl")
        XCTAssertEqual(ClaudeReplay.cutRefusal(config: config, work: work, session: from, upTo: bytes(3)), "after_call")
        XCTAssertEqual(try Data(contentsOf: file), saved, "A cut refused leaves the session whole")
        XCTAssertNil(ClaudeReplay.cutRefusal(config: config, work: work, session: from, upTo: bytes(7)))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), rows[..<7].joined(separator: "\n") + "\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: beside.appendingPathComponent("result.txt").path))
        XCTAssertEqual(ClaudeReplay.cutRefusal(config: config, work: work, session: from, upTo: bytes(7)), "nothing_after", "Cut once")
        XCTAssertEqual(ClaudeReplay.cutRefusal(config: config, work: work, session: UUID().uuidString.lowercased(), upTo: 10), "unread")
    }

    func testTranscriptRowsAreClassified() {
        func row(_ json: String) -> ClaudeTranscript.Row? { ClaudeTranscript.row(Data(json.utf8)) }
        XCTAssertEqual(row(#"{"type":"user","message":{"role":"user","content":"hi"}}"#), .accepted)
        XCTAssertEqual(row(#"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}"#), .accepted)
        XCTAssertNil(row(#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"x"}]}}"#))
        XCTAssertNil(row(#"{"type":"user","isMeta":true,"message":{"role":"user","content":"caveat"}}"#))
        XCTAssertNil(row(#"{"type":"user","isSidechain":true,"message":{"role":"user","content":"agent"}}"#))
        XCTAssertEqual(row(#"{"type":"queue-operation","operation":"enqueue","content":"later"}"#), .accepted)
        // a queued message handed on, with the next tool results or as a turn of its own
        XCTAssertEqual(row(#"{"type":"queue-operation","operation":"remove","timestamp":"2026-11-10T04:22:31.102Z","sessionId":"00000000-0000-4000-8000-000000000001"}"#), .queueHandedOn)
        XCTAssertEqual(row(#"{"type":"queue-operation","operation":"dequeue"}"#), .queueHandedOn)
        XCTAssertNil(row(#"{"type":"queue-operation","operation":"popAll"}"#))
        XCTAssertEqual(row(#"{"type":"system","subtype":"turn_duration","durationMs":5}"#), .turnEnded)
        XCTAssertNil(row(#"{"type":"system","subtype":"api_error"}"#))
        XCTAssertNil(row(#"{"type":"file-history-snapshot"}"#))
        XCTAssertNil(row("not json"))
        XCTAssertEqual(row(#"{"type":"assistant","requestId":"req_1","message":{"id":"msg_1","model":"claude-haiku","role":"assistant","content":[{"type":"text","text":"echo: hi"}]}}"#),
                       .assistant(message: "msg_1", blocks: [.text("echo: hi")], usage: nil, stop: nil))
        XCTAssertEqual(row(#"{"type":"assistant","uuid":"row-1","message":{"id":"m","model":"claude-opus-5-5","content":[{"type":"tool_use","id":"toolu_1","name":"mcp__pool__Read","input":{}}],"usage":{"input_tokens":3,"output_tokens":2,"cache_read_input_tokens":7}}}"#),
                       .assistant(message: "m", blocks: [.toolUse(id: "toolu_1", name: "mcp__pool__Read", input: .object([:]))],
                                  usage: BridgeUsage(inputTokens: 3, outputTokens: 2, cacheReadInputTokens: 7), stop: nil))
        XCTAssertEqual(row(#"{"type":"assistant","isApiErrorMessage":true,"apiErrorStatus":429,"apiErrorParams":{"rate_limit_info":{"status":"rejected"}},"message":{"id":"x","model":"<synthetic>","content":[{"type":"text","text":"You've hit your limit"}]}}"#),
                       .apiError(status: 429, text: "You've hit your limit", rateLimits: .object(["status": .string("rejected")])))
        XCTAssertEqual(row(#"{"type":"assistant","isApiErrorMessage":true,"message":{"id":"x","model":"<synthetic>","content":[{"type":"text","text":"Prompt is too long"}]}}"#),
                       .apiError(status: nil, text: "Prompt is too long", rateLimits: nil))
        XCTAssertNil(row(#"{"type":"assistant","message":{"id":"x","model":"<synthetic>","content":[{"type":"text","text":"No response requested."}]}}"#))
    }

    func testErrorWordsFollowTheQuotaAndTooLongChecks() {
        XCTAssertTrue(ClientErrorWords.tooLong(status: 400, "Prompt is too long"))
        XCTAssertFalse(ClientErrorWords.quotaSaid("Prompt is too long"))
        XCTAssertFalse(ClientErrorWords.quotaSaid("context_length_exceeded"))
        XCTAssertTrue(ClientErrorWords.quotaSaid("Claude AI usage limit reached|1760000000"))
        XCTAssertTrue(ClientErrorWords.quotaSaid("Too many requests"))
        XCTAssertFalse(ClientErrorWords.tooLong(status: 429, "Prompt is too long"))
        XCTAssertFalse(ClientErrorWords.tooLong(status: 400, "max_tokens is too long for this model"))
        XCTAssertFalse(ClientErrorWords.quotaSaid("Connection reset"))
        // Chinese words, kept as escapes in the source (余额不足, 内容太长)
        XCTAssertTrue(ClientErrorWords.quotaSaid(String(decoding: [0xE4, 0xBD, 0x99, 0xE9, 0xA2, 0x9D, 0xE4, 0xB8, 0x8D, 0xE8, 0xB6, 0xB3], as: UTF8.self)))
        XCTAssertTrue(ClientErrorWords.tooLong(status: 400, String(decoding: [0xE5, 0x86, 0x85, 0xE5, 0xAE, 0xB9, 0xE5, 0xA4, 0xAA, 0xE9, 0x95, 0xBF], as: UTF8.self)))
    }

    func testProjectNamesAndHistoryEndFollowClaudeCode() throws {
        XCTAssertEqual(ClaudeReplay.projectName("/private/var/folders/x y/Claude Pool.work_1"), "-private-var-folders-x-y-Claude-Pool-work-1")
        XCTAssertEqual(ClaudeReplay.projectName("/Users/名前/a"), "-Users----a")
        let call = JSONValue.array([.object(["type": .string("tool_use"), "id": .string("c"), "name": .string("t"), "input": .object([:])])])
        func end(_ roles: [(String, JSONValue)]) throws -> Int {
            ClaudePrompt.historyEnd(try ClaudePrompt.messages(roles.map { BridgeMessage(role: $0.0, content: $0.1) }))
        }
        XCTAssertEqual(try end([("user", .string("a"))]), 0)
        XCTAssertEqual(try end([("user", .string("a")), ("assistant", .string("b"))]), 0)
        XCTAssertEqual(try end([("user", .string("a")), ("assistant", .string("b")), ("user", .string("c"))]), 2)
        XCTAssertEqual(try end([("user", .string("a")), ("assistant", .string("b")), ("user", .string("c")), ("assistant", call),
                                ("user", .array([.object(["type": .string("tool_result"), "tool_use_id": .string("c"), "content": .string("r")])]))]), 2)
        XCTAssertEqual(try end([("user", .string("a")), ("assistant", call), ("user", .string("c"))]), 0)
    }

    func testPasteableTextKeepsTheInputFromRunningCommands() {
        XCTAssertEqual(OfficialSession.pasteable("/exit", busy: false), "\n/exit")
        XCTAssertEqual(OfficialSession.pasteable("  # note", busy: false), "\n# note")
        XCTAssertEqual(OfficialSession.pasteable("& job", busy: true), "[user message]\n& job")
        XCTAssertEqual(OfficialSession.pasteable("plain / text", busy: false), "plain / text")
        XCTAssertEqual(OfficialSession.pasteable("a\r\nb\u{1b}[201~", busy: false), "a\nb[201~")
        XCTAssertEqual(ClaudePrompt.withoutBillingHeader("x-anthropic-billing-header: cc_version=2.1.316; cc_entrypoint=cli; cch=abc;You are X."), "You are X.")
    }

    func testFirstRunScreensAreToldApartFromTheInputBox() {
        XCTAssertTrue(FirstRunScreens.isShowing("Do you trust the files in this folder?\n❯ Yes, I trust this folder"))
        XCTAssertTrue(FirstRunScreens.isShowing("Choose the text style that looks best with your terminal\n❯ 1. Dark mode"))
        XCTAssertTrue(FirstRunScreens.isShowing("Select login method:\n❯ 1. Claude account"))
        XCTAssertFalse(FirstRunScreens.isShowing("╭───╮\n❯ \n╰───╯"))
    }
}
