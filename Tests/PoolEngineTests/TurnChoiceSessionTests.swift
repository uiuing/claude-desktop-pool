import Foundation
import XCTest
import PoolCore
import PoolRuntime
@testable import PoolEngine

/// A session told the client's tool choice, a structured answer, web search and a shelved session, as
/// the bridge tells its interactive mode. All text is synthetic.
final class TurnChoiceSessionTests: XCTestCase {
    private let object = JSONValue.object(["type": .string("object")])
    private var tools: [BridgeTool] { [BridgeTool(name: "read", inputSchema: object), BridgeTool(name: "screenshot", inputSchema: object)] }

    /// tool_choice none: every tool is still offered (the prompt cache keys on them), and a call is
    /// answered here so Claude Code goes on in words (allowedTools).
    func testToolChoiceNoneAnswersCallsInTheSession() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        let session = harness.session()
        var ask = request("Title this conversation.", tools: tools); ask.toolChoice = "none"
        let log = EventLog.recording(try await session.events(for: ask))
        try await waitFor { harness.sentCount == 1 }
        XCTAssertEqual(try names(harness.catalog()), ["read", "screenshot"])
        try harness.tool("toolu_none", alias: "read")
        try await waitFor { FileManager.default.fileExists(atPath: (try? harness.resultURL("toolu_none").path) ?? "") }
        let result = try EngineSpool.read(harness.resultURL("toolu_none"))
        XCTAssertEqual(result["isError"], .bool(true))
        XCTAssertEqual(result["content"]?.arrayValue?.first?["text"]?.stringValue, TurnChoice.noToolsAnswer)
        try harness.answer("Synthetic title")
        try harness.turnEnded()
        try await waitFor { await log.ended }
        let events = await log.events
        XCTAssertEqual(events.first, .text("Synthetic title"))
        XCTAssertEqual(events.last, .finished(.endTurn))
        _ = await session.close()
    }

    /// Each mirrored tool declares Claude Code's highest result ceiling and the run's MCP output limit
    /// is lifted, so a long result of the client's tool reaches the model whole, not as a 2 KB preview
    /// of a file saved in the account's directory (11-14: a 69 KB file read came back as a preview).
    func testEveryToolKeepsTheClientsResultWhole() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        let session = harness.session()
        _ = EventLog.recording(try await session.events(for: request("Read the long synthetic file.", tools: tools)))
        try await waitFor { harness.sentCount == 1 }
        let listed = try XCTUnwrap(harness.catalog()["tools"]?.arrayValue)
        XCTAssertEqual(listed.count, 2)
        for tool in listed {
            XCTAssertEqual(tool["_meta"]?["anthropic/maxResultSizeChars"], .number(500_000), "Claude Code's own per-tool ceiling")
        }
        XCTAssertEqual(try XCTUnwrap(harness.plan).environment["MAX_MCP_OUTPUT_TOKENS"], "1000000")
        _ = await session.cancel()
        _ = await session.requestExit()
    }

    /// A named tool choice offers that tool alone and asks for its call in the instructions.
    func testANamedToolChoiceOffersThatToolAndAsksForIt() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        let session = harness.session()
        var ask = request("Take a screenshot.", tools: tools); ask.toolChoice = "name:screenshot"
        _ = EventLog.recording(try await session.events(for: ask))
        try await waitFor { harness.sentCount == 1 }
        XCTAssertEqual(try names(harness.catalog()), ["screenshot"])
        let plan = try XCTUnwrap(harness.plan)
        let index = try XCTUnwrap(plan.arguments.firstIndex(of: "--append-system-prompt-file"))
        let instructions = try String(contentsOf: URL(fileURLWithPath: plan.arguments[index + 1]), encoding: .utf8)
        XCTAssertTrue(instructions.hasSuffix("You must call the mcp__pool__screenshot tool."))
        _ = await session.cancel()
        _ = await session.requestExit()
    }

    /// A structured answer goes through the answer tool: a call that does not fit is told why, one that
    /// fits is the answer, and the turn's words are left out (claude_tui_schema.go).
    func testAStructuredAnswerIsItsAnswerToolsCall() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        let session = harness.session()
        var ask = request("Name this.", tools: tools)
        ask.answerSchema = .object(["$schema": .string("https://json-schema.org/draft/2020-12/schema"), "type": .string("object"),
                                    "properties": .object(["title": .object(["type": .string("string")])]), "required": .array([.string("title")])])
        let log = EventLog.recording(try await session.events(for: ask))
        try await waitFor { harness.sentCount == 1 }
        let catalog = try harness.catalog()
        XCTAssertEqual(try names(catalog), ["read", "screenshot", TurnChoice.answerToolName])
        let answerTool = catalog["tools"]?.arrayValue?.last
        XCTAssertNil(answerTool?["inputSchema"]?["$schema"], "Claude Code is given the schema without its root $schema")
        try harness.tool("toolu_wrong", alias: TurnChoice.answerToolName, input: .object(["name": .string("x")]))
        try await waitFor { FileManager.default.fileExists(atPath: (try? harness.resultURL("toolu_wrong").path) ?? "") }
        XCTAssertEqual(try EngineSpool.read(harness.resultURL("toolu_wrong"))["isError"], .bool(true))
        try harness.tool("toolu_right", alias: TurnChoice.answerToolName, input: .object(["title": .string("Synthetic fix")]))
        try await waitFor { FileManager.default.fileExists(atPath: (try? harness.resultURL("toolu_right").path) ?? "") }
        XCTAssertEqual(try EngineSpool.read(harness.resultURL("toolu_right"))["content"]?.arrayValue?.first?["text"]?.stringValue,
                       TurnChoice.answerReceived)
        try harness.answer("Here is the answer.")
        try harness.turnEnded()
        try await waitFor { await log.ended }
        let events = await log.events
        XCTAssertEqual(events.compactMap { if case .text(let t) = $0 { return t }; return nil }, [#"{"title":"Synthetic fix"}"#])
        XCTAssertFalse(events.contains { if case .toolUse = $0 { return true }; return false }, "The answer tool is the bridge's own")
        _ = await session.close()
    }

    /// A turn that ended without its answer tool is asked for it once (answerAsk).
    func testATurnWithoutItsAnswerIsAskedOnce() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        let session = harness.session()
        var ask = request("Name this.")
        ask.answerSchema = .object(["type": .string("object")])
        let log = EventLog.recording(try await session.events(for: ask))
        try await waitFor { harness.sentCount == 1 }
        try harness.answer("Words instead.")
        try harness.turnEnded()
        try await waitFor { harness.sentCount == 2 }
        XCTAssertTrue(harness.typed.contains("Give your final answer now by calling the mcp__pool__StructuredOutput tool"))
        try harness.tool("toolu_late", alias: TurnChoice.answerToolName, input: .object(["title": .string("Late")]))
        try await waitFor { FileManager.default.fileExists(atPath: (try? harness.resultURL("toolu_late").path) ?? "") }
        try harness.turnEnded()
        try await waitFor { await log.ended }
        let text = await log.text
        XCTAssertEqual(text, #"{"title":"Late"}"#)
        _ = await session.close()
    }

    /// The client's web search is Claude Code's own WebSearch, allowed for the run (claudeCLIArgs web).
    func testWebSearchIsTheSessionsOwn() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        let session = harness.session()
        var ask = request("Search the synthetic web."); ask.webSearch = true
        _ = EventLog.recording(try await session.events(for: ask))
        try await waitFor { harness.sentCount == 1 }
        let arguments = try XCTUnwrap(harness.plan).arguments
        let tools = try XCTUnwrap(arguments.firstIndex(of: "--tools"))
        XCTAssertEqual(arguments[tools + 1], "WebSearch")
        let allowed = try XCTUnwrap(arguments.firstIndex(of: "--allowedTools"))
        XCTAssertEqual(Array(arguments[(allowed + 1)...(allowed + 2)]), ["mcp__pool", "WebSearch"])
        _ = await session.cancel()
        _ = await session.requestExit()
    }

    /// An idle run ends with its session kept, and a new run resumes it, told only the
    /// turn since the conversation's last reply.
    func testAShelvedSessionIsResumedByTheNextTurn() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        let first = harness.session()
        let opening = request("Summarise the synthetic notes.")
        let log = EventLog.recording(try await first.events(for: opening))
        try await waitFor { harness.sentCount == 1 }
        try harness.answer("Three items.")
        try harness.turnEnded()
        try await waitFor { await log.ended }
        let transcript = try harness.transcriptURL
        let saved = try await XCTUnwrapAsync(await first.shelve())
        XCTAssertEqual(saved.session, transcript.deletingPathExtension().lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcript.path), "The shelved session outlives its run")

        let second = harness.session()
        let resumed = await second.resume(from: saved)
        XCTAssertTrue(resumed)
        var next = opening
        next.messages += [.init(role: "assistant", content: .string("Three items.")), .init(role: "user", content: .string("Which is longest?"))]
        _ = EventLog.recording(try await second.events(for: next))
        try await waitFor { harness.sentCount == 2 }
        let arguments = try XCTUnwrap(harness.plan).arguments
        XCTAssertEqual(Array(arguments.prefix(2)), ["--resume", saved.session])
        XCTAssertTrue(harness.typed.contains("Which is longest?"))
        XCTAssertFalse(harness.typed.contains("Summarise the synthetic notes."), "Only the turn since the last reply is typed")
        _ = await second.cancel()
        _ = await second.requestExit()
        saved.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: transcript.path))
    }

    /// A first turn, then the client's own ask after its reply, in one run: the request that ask
    /// replaces, the session's transcript as it was when the ask began, and where it is.
    private func sessionWithAClientsOwnTurn(_ harness: SessionHarness) async throws
        -> (first: OfficialSession, opening: BridgeRequest, before: Data, transcript: URL) {
        let first = harness.session()
        let opening = request("Summarise the synthetic notes.")
        let log = EventLog.recording(try await first.events(for: opening))
        try await waitFor { harness.sentCount == 1 }
        try harness.answer("Three items.", stop: "end_turn")
        try harness.turnEnded()
        try await waitFor { await log.ended }
        let unknown = await first.liveSession()
        XCTAssertNil(try XCTUnwrap(unknown).turn, "A first turn has nothing before it to go on from")
        let transcript = try harness.transcriptURL
        let before = try Data(contentsOf: transcript)
        var side = opening
        side.messages += [.init(role: "assistant", content: .string("Three items.")),
                          .init(role: "user", content: .string("Synthetic: suggest the next message."))]
        let sideLog = EventLog.recording(try await first.events(for: side))
        try await waitFor { harness.sentCount == 2 }
        try harness.answer("Which is longest?", stop: "end_turn")
        try harness.turnEnded()
        try await waitFor { await sideLog.ended }
        let at = try await XCTUnwrapAsync(await first.liveSession())
        XCTAssertEqual(at.turn, .init(held: 2, bytes: before.count), "The run knows where its last turn began")
        XCTAssertGreaterThan(try Data(contentsOf: transcript).count, before.count)
        return (first, opening, before, transcript)
    }
    private func real(_ opening: BridgeRequest) -> BridgeRequest {
        var next = opening
        next.messages += [.init(role: "assistant", content: .string("Three items.")), .init(role: "user", content: .string("Which is longest?"))]
        return next
    }

    /// A run that has ended leaves its session cut where its last turn began, under its own id, and
    /// the run that resumes it is typed only the turn that replaces that one.
    func testAnEndedRunsSessionIsCutWhereItsLastTurnBeganAndResumed() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        let (first, opening, before, transcript) = try await sessionWithAClientsOwnTurn(harness)
        let saved = try await XCTUnwrapAsync(await first.shelveEnding())
        XCTAssertEqual(saved.turn, .init(held: 2, bytes: before.count))
        let cut = try XCTUnwrap(saved.beforeTurn())
        XCTAssertEqual(cut.held, 2); XCTAssertEqual(cut.cutAt, before.count); XCTAssertFalse(cut.cutCopies)

        let second = harness.session()
        let resumed = await second.resume(from: cut)
        XCTAssertTrue(resumed)
        _ = EventLog.recording(try await second.events(for: real(opening)))
        try await waitFor { harness.sentCount == 3 }
        let arguments = try XCTUnwrap(harness.plan).arguments
        XCTAssertEqual(Array(arguments.prefix(2)), ["--resume", saved.session], "The session itself, under its own id")
        XCTAssertEqual(try Data(contentsOf: transcript), before, "cut to what it was when the turn began")
        XCTAssertTrue(harness.typed.contains("Which is longest?"))
        XCTAssertFalse(harness.typed.contains("Summarise the synthetic notes."), "Only the turn since the reply is typed")
        XCTAssertFalse(harness.typed.contains("suggest the next message"))
        let own = await second.liveSession()
        XCTAssertNil(own, "A reply is open")
        _ = await second.cancel()
        _ = await second.requestExit()
    }

    /// While another run still has the session, the run that goes on from before its last turn takes
    /// a copy cut there, under its own id, and the session stays whole.
    func testASessionARunStillHasIsCopiedUpToWhereItsLastTurnBegan() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        let (first, opening, before, transcript) = try await sessionWithAClientsOwnTurn(harness)
        let saved = try await XCTUnwrapAsync(await first.shelveEnding())
        let whole = try Data(contentsOf: transcript)
        let copy = try XCTUnwrap(ShelvedSession(session: saved.session, accountID: saved.accountID, turn: saved.turn, discard: {}).beforeTurn(keeping: true))
        XCTAssertTrue(copy.cutCopies)

        let second = harness.session()
        let resumed = await second.resume(from: copy)
        XCTAssertTrue(resumed)
        _ = EventLog.recording(try await second.events(for: real(opening)))
        try await waitFor { harness.sentCount == 3 }
        let arguments = try XCTUnwrap(harness.plan).arguments
        XCTAssertEqual(Array(arguments.prefix(2)), ["--resume", harness.sessionKey], "The run's own copy, under its own id")
        XCTAssertNotEqual(harness.sessionKey, saved.session)
        XCTAssertEqual(harness.resumedTranscript, before, "The session as it was when the turn began")
        XCTAssertEqual(try Data(contentsOf: transcript), whole, "The session it was copied from stays whole")
        XCTAssertTrue(harness.typed.contains("Which is longest?"))
        XCTAssertFalse(harness.typed.contains("suggest the next message"))
        _ = await second.cancel()
        _ = await second.requestExit()
        saved.discard()
    }

    private func request(_ text: String, tools: [BridgeTool]? = nil) -> BridgeRequest {
        BridgeRequest(model: "claude-sonnet", messages: [.init(role: "user", content: .string(text))], tools: tools)
    }
    private func names(_ catalog: JSONValue) throws -> [String] {
        try XCTUnwrap(catalog["tools"]?.arrayValue).compactMap { $0["name"]?.stringValue }
    }
}

private func XCTUnwrapAsync<T>(_ value: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let unwrapped = try await value()
    return try XCTUnwrap(unwrapped, file: file, line: line)
}
