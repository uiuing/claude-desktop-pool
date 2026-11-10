import Foundation
import XCTest
import PoolCore
import PoolRuntime
@testable import PoolEngine

final class OfficialSessionTests: XCTestCase {
    private let object = JSONValue.object(["type": .string("object")])

    func testTurnIsReadFromTheTranscriptAndLaunchedInInteractiveMode() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        let session = harness.session()
        var r = request("Hello")
        r.system = .string("x-anthropic-billing-header: cc_version=2.1.316; cc_entrypoint=cli;You help with a synthetic project.")
        let result = Task { try await collectEvents(try await session.events(for: r)) }
        try await waitFor { harness.sentCount == 1 }
        XCTAssertEqual(harness.typed, told("Hello"), "No envelope and no instructions are typed")
        try harness.answer("Hello there", usage: ["input_tokens": 14, "output_tokens": 3, "cache_read_input_tokens": 9000, "cache_creation_input_tokens": 0])
        try harness.turnEnded()
        let events = try await result.value
        XCTAssertEqual(events, [.text("Hello there"), .usage(.init(inputTokens: 14, outputTokens: 3, cacheReadInputTokens: 9000, cacheCreationInputTokens: 0)),
                                .finished(.endTurn)])
        let plan = try XCTUnwrap(harness.plan), arguments = plan.arguments
        func value(_ flag: String) -> String? { arguments.firstIndex(of: flag).map { arguments[$0 + 1] } }
        XCTAssertEqual(value("--session-id"), plan.sessionID.uuidString.lowercased())
        XCTAssertEqual(value("--model"), "sonnet")
        XCTAssertEqual(value("--tools"), "")
        XCTAssertEqual(value("--setting-sources"), "")
        XCTAssertEqual(value("--permission-mode"), "default")
        XCTAssertEqual(value("--allowedTools"), "mcp__pool")
        XCTAssertTrue(arguments.contains("--strict-mcp-config"))
        XCTAssertTrue(arguments.contains("--no-chrome"))
        for absent in ["--restricted", "--system-prompt-file", "-p", "--dangerously-skip-permissions", "--resume", "--bare"] {
            XCTAssertFalse(arguments.contains(absent), absent)
        }
        let appended = try XCTUnwrap(value("--append-system-prompt-file"))
        XCTAssertEqual(try String(contentsOfFile: appended, encoding: .utf8), "You help with a synthetic project.")
        let settings = try EngineSpool.read(URL(fileURLWithPath: try XCTUnwrap(value("--settings"))))
        XCTAssertEqual(settings["disableDeepLinkRegistration"]?.stringValue, "disable")
        XCTAssertNotNil(settings["statusLine"])
        for (key, expected) in ["ENABLE_CLAUDEAI_MCP_SERVERS": "0", "DISABLE_AUTO_COMPACT": "1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
                                "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1", "CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS": "1",
                                "CLAUDE_CODE_PROMPT_CACHE_TTL": "5m",
                                // a call past two minutes still waits for Desktop's result (11-10: runs ended
                                // their turn at 120 s and held the late result until Desktop gave up)
                                "CLAUDE_CODE_MCP_AUTO_BACKGROUND_MS": "0"] {
            XCTAssertEqual(plan.environment[key], expected, key)
        }
        for key in ["CLAUDE_CODE_SKIP_PROMPT_HISTORY", "ANTHROPIC_API_KEY", "CLAUDECODE"] {
            XCTAssertNil(plan.environment[key], key)
        }
        let transcript = try harness.transcriptURL
        let closed = await session.close()
        XCTAssertTrue(closed)
        XCTAssertEqual(harness.exitCount, 1)
        XCTAssertTrue(harness.allInputs.suffix(6).elementsEqual(["/", "e", "x", "i", "t", "\r"]), "/exit is typed a character at a time, then Return")
        XCTAssertFalse(FileManager.default.fileExists(atPath: transcript.path), "The run's session file goes with it")
    }

    /// The cache lasts as Claude Code's own on a subscription: an hour for a main conversation, five
    /// minutes for a subagent's turns and one-off asks such as the auto mode classifier.
    func testCacheTermFollowsClaudeCodesOwn() {
        let tool = BridgeTool(name: "Read", inputSchema: object)
        let main = request("Read the synthetic note.", tools: [tool])
        XCTAssertEqual(OfficialSession.cacheTerm(main), "1h")
        var subagent = main; subagent.subagent = true
        XCTAssertEqual(OfficialSession.cacheTerm(subagent), "5m")
        // the classifier's shape: no tools, the transcript in user messages, no earlier reply
        var classifier = request("synthetic transcript")
        classifier.messages.append(.init(role: "user", content: .string("synthetic action to classify")))
        XCTAssertEqual(OfficialSession.cacheTerm(classifier), "5m")
        var answered = request("Hello")
        answered.messages += [.init(role: "assistant", content: .string("Hi")), .init(role: "user", content: .string("Go on"))]
        XCTAssertEqual(OfficialSession.cacheTerm(answered), "1h", "A conversation without tools that goes on is a main conversation")
    }

    func testATurnWithoutUsageFinishesWithZeroUsageAndMessagesAreSummed() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        let session = harness.session()
        let first = Task { try await collectEvents(try await session.events(for: self.request("Reply"))) }
        try await waitFor { harness.sentCount == 1 }
        try harness.answer("Reply")
        try harness.turnEnded()
        let firstEvents = try await first.value
        XCTAssertEqual(firstEvents, [.text("Reply"), .usage(.init(inputTokens: 0, outputTokens: 0)), .finished(.endTurn)])
        let second = Task { try await collectEvents(try await session.events(for: self.request("Again"))) }
        try await waitFor { harness.sentCount == 2 }
        try harness.answer("One", message: "msg_a", usage: ["input_tokens": 10, "output_tokens": 1])
        try harness.answer(" two", message: "msg_a", usage: ["input_tokens": 10, "output_tokens": 4])
        try harness.answer(" three", message: "msg_b", usage: ["input_tokens": 5, "output_tokens": 2])
        try harness.turnEnded()
        let events = try await second.value
        XCTAssertEqual(events.joinedText, "One two three")
        XCTAssertTrue(events.contains(.usage(.init(inputTokens: 15, outputTokens: 6))))
        _ = await session.close()
    }

    func testHooksAreHintsAndMissingOrDifferentFieldsNeverFailATurn() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        let session = harness.session()
        let reply = Task { try await collectEvents(try await session.events(for: self.request("Hints"))) }
        try await waitFor { harness.sentCount == 1 }
        for fields: [String: JSONValue] in [["event": .string("Stop")], ["event": .string("Stop"), "background_tasks": .string("1")],
                                            ["event": .string("MessageDisplay"), "index": .string("x")], ["event": .string("UserPromptSubmit")],
                                            ["event": .string("SomethingNew"), "prompt_id": .number(3)], ["no_event": .bool(true)]] {
            try harness.emit(fields)
        }
        try harness.row(["type": .string("progress"), "data": .object([:])])
        try harness.row(["type": .string("attachment")])
        try harness.answer("Still answered")
        try harness.turnEnded()
        let events = try await reply.value
        XCTAssertEqual(events.joinedText, "Still answered")
        _ = await session.close()
    }

    func testTypedTextIsMadePasteableAndAnEmptyMessageIsADot() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        let session = harness.session()
        let opening = Task { try await collectEvents(try await session.events(for: self.request("Hello"))) }
        try await waitFor { harness.sentCount == 1 }
        try harness.answer("Hi"); try harness.turnEnded()
        _ = try await opening.value
        // later turns of the live session are typed as they are (renderClaudeTurn)
        for (number, (text, expected)) in [("/exit", "\n/exit"), ("line one\r\nline two\u{1b}[31m red\u{7f}\u{1b}[201~", "line one\nline two[31m red[201~"),
                                           ("   ", "."), ("! ls", "\n! ls")].enumerated() {
            let reply = Task { try await collectEvents(try await session.events(for: self.request(text))) }
            try await waitFor { harness.sentCount == number + 2 }
            XCTAssertEqual(harness.typed, expected)
            try harness.answer("Received"); try harness.turnEnded()
            _ = try await reply.value
        }
        _ = await session.close()
    }

    func testReturnIsPressedAloneAndAgainWhileTheTranscriptHasNotTakenTheMessage() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        harness.ignoreNextEnters(1)
        let session = harness.session(returnTimeout: 0.2)
        let long = String(repeating: "wrapped words across the terminal width ", count: 12)
        let reply = Task { try await collectEvents(try await session.events(for: self.request(long))) }
        try await waitFor { harness.sentCount == 1 }
        XCTAssertFalse(harness.allInputs.contains { $0.contains("\u{1b}[201~") && $0.hasSuffix("\r") }, "Return must not travel with the paste")
        XCTAssertEqual(harness.allInputs.filter { $0 == "\r" }.count, 2)
        XCTAssertEqual(harness.typed, told(long))
        try harness.answer("Done"); try harness.turnEnded()
        _ = try await reply.value
        _ = await session.close()
    }

    func testAPasteThatNeverShowsStillGetsReturn() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        harness.acknowledgeText = false
        let session = harness.session(imageTimeout: 0.2)
        let reply = Task { try await collectEvents(try await session.events(for: self.request("Unseen paste"))) }
        try await waitFor { harness.sentCount == 1 }
        XCTAssertEqual(harness.typed, told("Unseen paste"))
        try harness.answer("Taken"); try harness.turnEnded()
        let events = try await reply.value
        XCTAssertEqual(events.joinedText, "Taken")
        _ = await session.close()
    }

    func testAMessageTheTranscriptNeverTakesFailsAfterFourReturns() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        harness.ignoreNextEnters(10)
        let session = harness.session(returnTimeout: 0.05)
        do { _ = try await collectEvents(try await session.events(for: request("Ignored"))); XCTFail("An untaken message was accepted") }
        catch { XCTAssertEqual(error as? BridgeFailure, .compatibility) }
        XCTAssertEqual(harness.allInputs.filter { $0 == "\r" }.count, 4)
        harness.exited()
        _ = await session.close()
    }

    func testClientReportedErrorsAreClassified() async throws {
        let cases: [(Int?, String, BridgeFailure)] = [
            (nil, "Prompt is too long", .clientReported(status: 0, message: "Prompt is too long")),
            (429, "You've hit your limit · resets 7pm", .rateLimited(nil)),
            (nil, "Claude usage limit reached", .rateLimited(nil)),
            (401, "Please run /login", .accountUnavailable(.signedOut)),
            (529, "Overloaded", .clientReported(status: 529, message: "Overloaded")),
            (400, "Third-party apps now draw from your extra usage", .clientReported(status: 400, message: "Third-party apps now draw from your extra usage"))]
        for (status, text, expected) in cases {
            let harness = try SessionHarness(); defer { harness.clean() }
            let session = harness.session(), recorder = SessionObservations()
            let observing = Task { for await event in await session.observations() { await recorder.add(event) } }
            defer { observing.cancel() }
            let reply = Task { try await collectEvents(try await session.events(for: self.request("Ask"))) }
            try await waitFor { harness.sentCount == 1 }
            // A refusal whose info names no window says nothing of which limit
            let info: JSONValue? = status == 429 ? .object(["status": .string("rejected")]) : nil
            try harness.apiError(status: status, text: text, info: info)
            try harness.turnEnded()
            do { _ = try await reply.value; XCTFail("An API error row finished a turn: \(text)") }
            catch { XCTAssertEqual(error as? BridgeFailure, expected, text) }
            let quotas = await recorder.quotas
            XCTAssertTrue(quotas.isEmpty)
            harness.exited()
            _ = await session.close()
        }
    }

    /// Claude Code writes Claude's refusal as an error row of its own, with no status: the refusal's
    /// stop, or a request its safety checks blocked. It is told as a refusal, an answer the client keeps,
    /// never as a 502 it would ask again (to the next account) and again.
    func testARefusalRowIsARefusalNotAnErrorToAskAgain() async throws {
        let rows: [(stop: String?, apiError: String?)] = [("refusal", nil), (nil, "safety_monitor_blocked"), (nil, "dlp_request_denied")]
        for (stop, apiError) in rows {
            let harness = try SessionHarness(); defer { harness.clean() }
            let session = harness.session()
            let reply = Task { try await collectEvents(try await session.events(for: self.request("Ask"))) }
            try await waitFor { harness.sentCount == 1 }
            try harness.apiError(status: nil, text: "Claude Code is unable to respond to this request.", stop: stop, apiError: apiError)
            try harness.turnEnded()
            let events = try await reply.value
            XCTAssertTrue(events.contains(.finished(.refusal)), "\(stop ?? apiError ?? "-"): \(events)")
            harness.exited()
            _ = await session.close()
        }
    }

    func testAKnownExhaustedWindowMakesALimitRowAQuotaLimit() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        let session = harness.session()
        let reply = Task { try await collectEvents(try await session.events(for: self.request("Ask"))) }
        try await waitFor { harness.sentCount == 1 }
        try harness.apiError(status: 429, text: "You've hit your limit", info: .object([
            "status": .string("rejected"), "unifiedWindows": .object(["five_hour": .object(["utilization": .number(1), "resetsAt": .number(2_000_000_000)])])]))
        do { _ = try await reply.value; XCTFail("Limit accepted") }
        catch {
            guard case .quotaLimited(let windows)? = error as? BridgeFailure else { return XCTFail("\(error)") }
            XCTAssertEqual(windows.map(\.id), ["five_hour"])
        }
        harness.exited()
        _ = await session.close()
    }

    func testAPermissionDialogHintFailsTheReplyAtOnce() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        let session = harness.session()
        let reply = Task { try await collectEvents(try await session.events(for: self.request("Needs a decision"))) }
        try await waitFor { harness.sentCount == 1 }
        let started = Date()
        try harness.emit(["event": .string("Notification"), "notification_type": .string("permission_prompt")])
        do { _ = try await reply.value; XCTFail("A dialog left the reply waiting") }
        catch { XCTAssertEqual(error as? BridgeFailure, .permissionRequired) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        harness.exited()
        _ = await session.close()
    }

    func testFirstRunScreensAreAnsweredBeforeTheMessageIsTyped() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        harness.firstRun = true
        let session = harness.session()
        let reply = Task { try await collectEvents(try await session.events(for: self.request("Hello"))) }
        try await waitFor { harness.sentCount == 1 }
        XCTAssertEqual(harness.typed, told("Hello"))
        try harness.answer("Hi"); try harness.turnEnded()
        let events = try await reply.value
        XCTAssertEqual(events.last, .finished(.endTurn))
        _ = await session.close()
    }

    func testToolsThatAreNeverListedEndTheOneReadyWait() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        harness.acknowledgeInitialTools = false
        let session = harness.session(readyTimeout: 0.3)
        do { _ = try await collectEvents(try await session.events(for: request("Wait", tools: [.init(name: "read", inputSchema: object)]))); XCTFail("Unlisted tools accepted") }
        catch { XCTAssertEqual(error as? BridgeFailure, .compatibility) }
        XCTAssertEqual(harness.sentCount, 0)
        XCTAssertFalse(harness.allInputs.contains { $0.contains("\u{1b}[200~") })
        harness.exited()
        _ = await session.close()
    }

    func testParallelToolsReturnExactResultsAndTheTurnGoesOn() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        let session = harness.session()
        let tools = [BridgeTool(name: "read", inputSchema: object), BridgeTool(name: "screenshot", inputSchema: object)]
        let firstRequest = request("Inspect", tools: tools)
        let first = Task { try await collectEvents(try await session.events(for: firstRequest)) }
        try await waitFor { harness.sentCount == 1 }
        // the helper hands calls over under Claude Code's own tool-use ids, which its message has
        let a = "toolu_01a", b = "toolu_01b"
        try harness.tool(a, alias: "read"); try harness.tool(b, alias: "screenshot")
        try harness.toolUseRow([(a, "read"), (b, "screenshot")], usage: ["input_tokens": 20, "output_tokens": 10])
        let events = try await first.value
        XCTAssertEqual(events.compactMap { if case .toolUse(let call) = $0 { call.id } else { nil } }, [a, b])
        XCTAssertTrue(events.contains(.usage(.init(inputTokens: 20, outputTokens: 10))))
        XCTAssertEqual(events.last, .finished(.toolUse))
        let image = Data([137, 80, 78, 71]).base64EncodedString()
        let results = JSONValue.array([
            .object(["type": .string("tool_result"), "tool_use_id": .string(a), "content": .string("file text")]),
            .object(["type": .string("tool_result"), "tool_use_id": .string(b), "content": .array([
                .object(["type": .string("image"), "source": .object(["type": .string("base64"), "media_type": .string("image/png"), "data": .string(image)])])])])])
        var next = firstRequest; next.messages.append(BridgeMessage(role: "user", content: results))
        let second = Task { try await collectEvents(try await session.events(for: next)) }
        let resultURL = try XCTUnwrap(harness.plan).runDirectory.appendingPathComponent("results/\(b).json")
        try await waitFor { FileManager.default.fileExists(atPath: resultURL.path) }
        XCTAssertEqual(try EngineSpool.read(resultURL)["content"]?.arrayValue?.first?["data"]?.stringValue, image)
        XCTAssertEqual(harness.sentCount, 1, "Tool continuation uses the parked process, not a new paste")
        try harness.answer("Finished", usage: ["input_tokens": 30, "output_tokens": 2])
        try harness.turnEnded()
        let secondEvents = try await second.value
        XCTAssertEqual(secondEvents.joinedText, "Finished")
        XCTAssertTrue(secondEvents.contains(.usage(.init(inputTokens: 30, outputTokens: 2))))
        _ = await session.close()
    }

    func testChangedToolsWaitForTheRelistAtMostTheirWaitThenGoOn() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        let session = harness.session(toolTimeout: 0.4)
        var r = request("Tools", tools: [.init(name: "search", inputSchema: object)])
        let first = Task { try await collectEvents(try await session.events(for: r)) }
        try await waitFor { harness.sentCount == 1 }
        let callID = UUID().uuidString
        try harness.tool(callID, alias: "search")
        _ = try await first.value
        r.messages.append(.init(role: "user", content: .array([.object(["type": .string("tool_result"), "tool_use_id": .string(callID), "content": .string("Found")])])))
        r.tools = [.init(name: "search", inputSchema: object), .init(name: "discovered", inputSchema: object)]
        let started = Date()
        let second = Task { try await collectEvents(try await session.events(for: r)) }
        let result = try XCTUnwrap(harness.plan).runDirectory.appendingPathComponent("results/\(callID).json")
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(FileManager.default.fileExists(atPath: result.path), "Results wait for the re-list")
        try await waitFor { FileManager.default.fileExists(atPath: result.path) }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.35, "An unlisted change is delivered once the wait is over")
        XCTAssertEqual(try harness.catalog()["tools"]?.arrayValue?.map { $0["name"]?.stringValue }, ["search", "discovered"])
        // the message that made the call, written once it was answered, is not told again
        try harness.toolUseRow([(callID, "search")])
        try harness.answer("Done"); try harness.turnEnded()
        let events = try await second.value
        XCTAssertEqual(events.joinedText, "Done")
        _ = await session.close()
    }

    func testDeferredToolCatalogKeepsAliasesAndReleasesResultsOnTheExactReceipt() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        let session = harness.session(toolTimeout: 3)
        let unusual = "desktop.search/long/name"
        var r = request("Find tools", tools: [BridgeTool(name: unusual, inputSchema: object), BridgeTool(name: "read", inputSchema: object)])
        let first = Task { try await collectEvents(try await session.events(for: r)) }
        try await waitFor { harness.sentCount == 1 }
        let alias = try XCTUnwrap(harness.catalog()["tools"]?.arrayValue?.first?["name"]?.stringValue)
        let a = UUID().uuidString
        try harness.tool(a, alias: alias)
        _ = try await first.value
        r.messages.append(.init(role: "user", content: .array([.object(["type": .string("tool_result"), "tool_use_id": .string(a), "content": .string("Completed")])])))
        r.tools = [BridgeTool(name: "new_action", inputSchema: object), BridgeTool(name: unusual, inputSchema: object)]
        let next = r
        let second = Task { try await collectEvents(try await session.events(for: next)) }
        let results = try XCTUnwrap(harness.plan).runDirectory.appendingPathComponent("results")
        try await waitFor { (try? harness.catalog()["tools"]?.arrayValue?.count) == 2 && (try? harness.catalog()["tools"]?.arrayValue?.first?["name"]?.stringValue) == "new_action" }
        XCTAssertEqual(try harness.catalog()["tools"]?.arrayValue?.map { $0["name"]?.stringValue }, ["new_action", alias])
        try harness.acknowledgeCatalog(revision: UUID().uuidString)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: results.path).isEmpty)
        try harness.acknowledgeCatalog()
        try await waitFor { (try? FileManager.default.contentsOfDirectory(atPath: results.path).count) == 1 }
        let c = UUID().uuidString
        try harness.tool(c, alias: alias)
        let events = try await second.value
        XCTAssertTrue(events.contains(.toolUse(.init(id: c, name: unusual, input: .object([:])))))
        harness.exitAfterInterrupts = 1
        _ = await session.requestExit()
    }

    func testCancellationKeepsTheOwnedTerminalAndDoesNotClaimSuccess() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        let session = harness.session()
        let reply = Task { try await collectEvents(try await session.events(for: self.request("Wait"))) }
        try await waitFor { harness.sentCount == 1 }
        await session.cancel()
        do { _ = try await reply.value; XCTFail("Cancelled response completed") }
        catch { XCTAssertEqual(error as? BridgeFailure, .cancelled) }
        XCTAssertEqual(harness.interruptCount, 1)
        try await session.sendInput(Data("explicit input".utf8))
        let closed = await session.close()
        XCTAssertFalse(closed, "An interrupt is not evidence that the official session is idle")
        harness.exited()
        try await waitFor { await session.close() }
    }

    func testMultipleImagesArePastedAsOwnedPathsWithOneReturn() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        let session = harness.session()
        let first = try sessionFixtureImage(red: 255), second = try sessionFixtureImage(red: 0)
        let r = BridgeRequest(model: "claude-sonnet", messages: [.init(role: "user", content: .array([
            .object(["type": .string("text"), "text": .string("Before")]), first,
            .object(["type": .string("text"), "text": .string("Between")]), second,
            .object(["type": .string("text"), "text": .string("After")])]))])
        let reply = Task { try await collectEvents(try await session.events(for: r)) }
        try await waitFor { harness.sentCount == 1 }
        XCTAssertEqual(harness.enterCount, 1)
        XCTAssertEqual(harness.imageBytes, [try ImagePayload(block: first).data, try ImagePayload(block: second).data])
        XCTAssertTrue(harness.imagePaths.allSatisfy { $0.contains("fixture space") && $0.contains("/work/image-") })
        XCTAssertEqual(harness.typed, "Human: Before\n\n\n\nBetween\n\n\n\nAfter\n\n")
        try harness.answer("Images received"); try harness.turnEnded()
        _ = try await reply.value
        XCTAssertTrue(harness.imagePaths.allSatisfy { !FileManager.default.fileExists(atPath: $0) }, "Taken images are removed")
        _ = await session.close()
    }

    /// Five long tool results with a screenshot each, as a replayed turn is typed: the client
    /// numbers pasted texts and images together, and the fifth image's "[Image #10]" falls on the
    /// input's wrap, drawn as "[Image #" and "   10]" on two rows.
    func testAnImageMarkSplitByTheInputsWrapIsStillSeen() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        harness.drawDraftLikeClient = true
        let session = harness.session(imageTimeout: 1)
        let result = (1...60).map { "line \($0) of a long tool result" }.joined(separator: "\n")
        var content: [JSONValue] = []
        for red: UInt8 in [255, 200, 150, 100, 50] {
            content.append(.object(["type": .string("text"), "text": .string(result)]))
            content.append(try sessionFixtureImage(red: red))
        }
        content.append(.object(["type": .string("text"), "text": .string("What changed?")]))
        let r = BridgeRequest(model: "claude-sonnet", messages: [.init(role: "user", content: .array(content))])
        let reply = Task { try await collectEvents(try await session.events(for: r)) }
        try await waitFor { harness.sentCount == 1 }
        XCTAssertEqual(harness.enterCount, 1)
        XCTAssertEqual(harness.imageBytes.count, 5)
        try harness.answer("Five screenshots"); try harness.turnEnded()
        _ = try await reply.value
        _ = await session.close()
    }

    /// A conversation moved to another account types everything since its session's last turn as one
    /// message: many screenshots between long texts. On so long an input the client redraws only the
    /// cells that changed, so an image's mark reaches the output with letters it shares with the mark
    /// before left out ("[Imag #27]"). The screen still shows it whole, and the image counts as shown.
    func testAnImageMarkDrawnOnlyWhereItChangedIsStillSeen() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        harness.drawDraftLikeClient = true; harness.drawDraftAsDifferences = true
        let session = harness.session(imageTimeout: 1)
        let result = (1...8).map { "line \($0) of a tool result" }.joined(separator: "\n")
        var content: [JSONValue] = []
        for index in 0..<13 {
            content.append(.object(["type": .string("text"), "text": .string(result)]))
            content.append(try sessionFixtureImage(red: UInt8(250 - index * 15)))
        }
        content.append(.object(["type": .string("text"), "text": .string("What changed?")]))
        let r = BridgeRequest(model: "claude-sonnet", messages: [.init(role: "user", content: .array(content))])
        let reply = Task { try await collectEvents(try await session.events(for: r)) }
        try await waitFor { harness.sentCount == 1 }
        XCTAssertEqual(harness.imageBytes.count, 13)
        try harness.answer("Thirteen screenshots"); try harness.turnEnded()
        _ = try await reply.value
        _ = await session.close()
    }

    func testAnImageThatIsNeverShownIsNeverSentAndOnlyTheOwnedDraftIsCleared() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        harness.acknowledgeImages = false
        let session = harness.session(imageTimeout: 0.15)
        let r = BridgeRequest(model: "claude-sonnet", messages: [.init(role: "user", content: .array([try sessionFixtureImage(red: 255)]))])
        do { _ = try await collectEvents(try await session.events(for: r)); XCTFail("Missing attachment acknowledgment accepted") }
        catch { XCTAssertEqual(error as? BridgeFailure, .compatibility) }
        XCTAssertEqual(harness.enterCount, 0)
        let closed = await session.close()
        XCTAssertTrue(closed)
        XCTAssertEqual(harness.interruptCount, 1)
        XCTAssertEqual(harness.exitCount, 1)
        XCTAssertEqual(harness.enterCount, 0)
    }

    func testManualInputDuringAnImageDraftIsNeverAutomaticallyCleared() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        harness.acknowledgeImages = false
        let session = harness.session(imageTimeout: 1)
        let r = BridgeRequest(model: "claude-sonnet", messages: [.init(role: "user", content: .array([try sessionFixtureImage(red: 255)]))])
        let reply = Task { try await collectEvents(try await session.events(for: r)) }
        try await waitFor { harness.imagePaths.count == 1 }
        try await session.sendInput(Data("manual draft".utf8))
        do { _ = try await reply.value; XCTFail("Manual takeover was ignored") } catch {}
        let closed = await session.close()
        XCTAssertFalse(closed)
        XCTAssertEqual(harness.interruptCount, 0)
        XCTAssertEqual(harness.exitCount, 0)
        harness.exitAfterInterrupts = 1
        let explicit = await session.requestExit()
        XCTAssertTrue(explicit)
        XCTAssertEqual(harness.enterCount, 0)
    }

    func testExplicitExitAfterCancellationUsesOnlyNormalInterruptKeys() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        harness.exitAfterInterrupts = 2
        let session = harness.session()
        let reply = Task { try await collectEvents(try await session.events(for: self.request("Running"))) }
        try await waitFor { harness.sentCount == 1 }
        await session.cancel()
        do { _ = try await reply.value } catch {}
        let closed = await session.requestExit()
        XCTAssertTrue(closed)
        XCTAssertEqual(harness.interruptCount, 2)
        XCTAssertEqual(harness.exitCount, 0, "No slash command may be appended to an uncertain draft")
    }

    func testAResultLeftUnderTheClientsToolIdIsCleanedUp() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        let session = harness.session()
        let reply = Task { try await collectEvents(try await session.events(for: self.request("Running"))) }
        try await waitFor { harness.sentCount == 1 }
        let run = try XCTUnwrap(harness.plan).runDirectory
        // As a refused call leaves it when the run ends before the helper takes it.
        try harness.workspace.write(Data("{}".utf8), to: run.appendingPathComponent("results/toolu_01AbCdEf.json"))
        await session.cancel()
        do { _ = try await reply.value } catch {}
        harness.exited()
        let closed = await session.requestExit()
        XCTAssertTrue(closed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.path))
    }

    func testAFolderThatCannotBeRemovedDoesNotKeepAnEndedRunOpen() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        let session = harness.session(), recorder = SessionObservations()
        let observing = Task { for await observation in await session.observations() { await recorder.add(observation) } }
        defer { observing.cancel() }
        let reply = Task { try await collectEvents(try await session.events(for: self.request("Running"))) }
        try await waitFor { harness.sentCount == 1 }
        let run = try XCTUnwrap(harness.plan).runDirectory
        let unknown = run.appendingPathComponent("work/notes.txt")
        try harness.workspace.write(Data("keep".utf8), to: unknown)
        await session.cancel()
        do { _ = try await reply.value } catch {}
        harness.exited()
        // The client is gone: quitting goes on, and the file it does not recognize stays.
        let closed = await session.requestExit()
        XCTAssertTrue(closed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unknown.path))
    }

    func testAKeyThatFindsTheChildGoneStillEndsTheExit() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        harness.exitAfterInterrupts = 2; harness.exitEventLags = true
        let session = harness.session()
        let reply = Task { try await collectEvents(try await session.events(for: self.request("Running"))) }
        try await waitFor { harness.sentCount == 1 }
        await session.cancel()
        do { _ = try await reply.value } catch {}
        // The client ended on the second Ctrl-C; the third finds it gone. That is its exit, not a refusal to quit.
        let closed = await session.requestExit()
        XCTAssertTrue(closed)
    }

    /// A turn holding what cannot be typed (here an image Claude Code cannot paste; any block of any kind
    /// alike) goes in the run's session as one user message, as it came, and only "[continue]" is typed.
    func testATurnThatCannotBeTypedGoesInTheSessionAsItCame() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        let session = harness.session()
        var source = try XCTUnwrap(try sessionFixtureImage(red: 255)["source"]?.objectValue); source["media_type"] = .string("image/jpeg")
        let document = JSONValue.object(["type": .string("document"), "source": .object(["type": .string("text"),
            "media_type": .string("text/plain"), "data": .string("Synthetic note.")])])
        let content: [JSONValue] = [.object(["type": .string("text"), "text": .string("Read these.")]),
                                    .object(["type": .string("image"), "source": .object(source)]), document]
        let r = BridgeRequest(model: "claude-sonnet", messages: [.init(role: "user", content: .array(content))])
        let reply = Task { try await collectEvents(try await session.events(for: r)) }
        try await waitFor { harness.sentCount == 1 }
        let plan = try XCTUnwrap(harness.plan)
        XCTAssertTrue(plan.arguments.contains("--resume"))
        XCTAssertEqual(harness.typed, OfficialSession.continueWord)
        let saved = try XCTUnwrap(harness.resumedTranscript)
        let rows = saved.split(separator: 10).compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0)) }
        let told = try XCTUnwrap(rows.last?["message"]?["content"]?.arrayValue)
        XCTAssertEqual(told.first?["type"], .string("text"))
        XCTAssertEqual(Array(told.dropFirst()), Array(content.dropFirst()), "Each block goes as it came")
        try harness.answer("Done.", usage: ["input_tokens": 3, "output_tokens": 1])
        try harness.turnEnded()
        _ = try await reply.value
    }

    func testQuotaAndModelComeFromTheStatusLineAfterModelActivity() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        let session = harness.session(), recorder = SessionObservations()
        let observing = Task { for await event in await session.observations() { await recorder.add(event) } }
        defer { observing.cancel() }
        let reply = Task { try await collectEvents(try await session.events(for: self.request("Report"))) }
        try await waitFor { harness.sentCount == 1 }
        let windows: JSONValue = .object(["seven_day": .object(["used_percentage": .number(25), "resets_at": .number(2_000_000_000)]),
                                          "five_hour": .null, "monthly": .object(["applicable": .bool(false)])])
        try harness.emit(["event": .string("statusLine"), "rate_limits": windows])
        try await Task.sleep(nanoseconds: 120_000_000)
        let early = await recorder.quotas
        XCTAssertTrue(early.isEmpty, "A startup redraw is not a reading after model activity")
        try harness.answer("Report")
        try await Task.sleep(nanoseconds: 120_000_000)
        for id in ["claude-sonnet-5-5[1m]", "claude-sonnet-5-5", "claude-opus-5-5"] {
            try harness.emit(["event": .string("statusLine"), "rate_limits": windows,
                              "model": .object(["id": .string(id), "display_name": .string("Sonnet 5.5 (1M context)")])])
        }
        try harness.turnEnded()
        _ = try await reply.value
        try await waitFor { await recorder.quotas.count >= 3 }
        let all = await recorder.quotas, models = await recorder.models
        XCTAssertEqual(all.first { $0.id == "seven_day" }?.usedPercent, 25)
        XCTAssertEqual(all.first { $0.id == "five_hour" }?.state, .unknown)
        XCTAssertEqual(all.first { $0.id == "monthly" }?.state, .notApplicable)
        XCTAssertEqual(models.map(\.id), ["claude-sonnet-5-5"])
        _ = await session.close()
    }

    /// Client 2.1.319 sends `rate_limits.limits[]`: kind, group, percent, ISO resets_at, scope, severity.
    func testStatusLineLimitsArrayIsReadByKindNotByWords() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        let session = harness.session(), recorder = SessionObservations()
        let observing = Task { for await event in await session.observations() { await recorder.add(event) } }
        defer { observing.cancel() }
        let reply = Task { try await collectEvents(try await session.events(for: self.request("Report"))) }
        try await waitFor { harness.sentCount == 1 }
        try harness.answer("Report")
        try await Task.sleep(nanoseconds: 120_000_000)
        func row(_ kind: String, _ percent: Double, _ resets: JSONValue, scope: JSONValue? = nil) -> JSONValue {
            var fields: [String: JSONValue] = ["kind": .string(kind), "group": .string("g"), "percent": .number(percent),
                                               "resets_at": resets, "severity": .string("info")]
            if let scope { fields["scope"] = scope }
            return .object(fields)
        }
        func model(_ name: String) -> JSONValue { .object(["model": .object(["display_name": .string(name)])]) }
        let limits: JSONValue = .object(["limits": .array([
            row("session", 12, .string("2033-05-18T03:33:20Z")),
            row("weekly_all", 30, .string("2033-05-20T03:33:20.500Z")),
            row("weekly_scoped", 100, .string("2033-05-20T03:33:20Z"), scope: model("Fable 5.1")),
            row("weekly_scoped", 40, .null, scope: model("Opus and Sonnet")),
            row("weekly_scoped", 55, .string("2033-05-20T03:33:20Z"), scope: .object(["surface": .object(["display_name": .string("Cowork")])])),
            row("monthly_credit", 70, .null)])])
        try harness.emit(["event": .string("statusLine"), "rate_limits": limits])
        try harness.turnEnded()
        _ = try await reply.value
        try await waitFor { await recorder.quotas.count >= 6 }
        let all = await recorder.quotas
        func window(_ id: String) -> QuotaWindow? { all.first { $0.id == id } }
        XCTAssertEqual(window("five_hour")?.scope, .all)
        XCTAssertEqual(window("five_hour")?.usedPercent, 12)
        XCTAssertEqual(window("five_hour")?.resetsAt, Date(timeIntervalSince1970: 2_000_000_000))
        XCTAssertEqual(window("seven_day")?.scope, .all)
        XCTAssertEqual(window("seven_day_overage_included")?.scope, .models(["fable"]))
        XCTAssertEqual(window("seven_day_overage_included")?.usedPercent, 100)
        XCTAssertEqual(window("seven_day_opus_and_sonnet")?.scope, .other)
        XCTAssertNil(window("seven_day_opus_and_sonnet")?.resetsAt)
        XCTAssertEqual(window("surface_cowork")?.scope, .other)
        XCTAssertEqual(window("limit_monthly_credit_g")?.scope, .other)
        _ = await session.close()
    }

    /// A refusal's rate-limit info as the client records it: the Fable limit is the overage-included window.
    func testRefusalInfoForTheOverageIncludedWindowIsScopedToItsModels() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let info: JSONValue = .object(["status": .string("rejected"), "rateLimitType": .string("seven_day_overage_included"),
                                       "resetsAt": .number(1_800_086_400)])
        let windows = ClientErrorWords.windows(info, at: now)
        XCTAssertEqual(windows.map(\.id), ["seven_day_overage_included"])
        XCTAssertEqual(windows.first?.scope, .models(["fable"]))
        XCTAssertEqual(windows.first?.usedPercent, 100)
        let unified: JSONValue = .object(["status": .string("allowed"), "unifiedWindows": .object([
            "seven_day_cowork": .object(["utilization": .number(1), "resetsAt": .number(1_800_086_400)]),
            "overage": .object(["utilization": .number(1), "resetsAt": .number(1_800_086_400)]),
            "seven_day_fable": .object(["utilization": .number(0.5), "resetsAt": .number(1_800_086_400)])])])
        let mixed = ClientErrorWords.windows(unified, at: now)
        XCTAssertEqual(mixed.map(\.id), ["overage", "seven_day_cowork", "seven_day_overage_included"])
        XCTAssertEqual(mixed.map(\.scope), [.other, .other, .models(["fable"])])
        let account = PoolAccount(email: "user@example.com", state: .ready, windows: mixed)
        XCTAssertEqual(account.effectiveState(at: now), .ready)
        XCTAssertFalse(PoolRouting.candidates([account], model: "claude-opus-5", now: now).isEmpty)
    }

    func testSessionEndHookDoesNotReleaseTheChildOrRunBeforeActualExit() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        let session = harness.session(), recorder = SessionObservations()
        let observing = Task { for await observation in await session.observations() { await recorder.add(observation) } }
        defer { observing.cancel() }
        let reply = Task { try await collectEvents(try await session.events(for: self.request("Hello"))) }
        try await waitFor { harness.sentCount == 1 }
        try harness.answer("Hello"); try harness.turnEnded()
        _ = try await reply.value
        let run = try XCTUnwrap(harness.plan).runDirectory
        try harness.emit(["event": .string("SessionEnd")])
        try await waitFor { await recorder.attentionCount > 0 }
        let closedBeforeExit = await session.close()
        XCTAssertFalse(closedBeforeExit)
        XCTAssertEqual(harness.exitCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: run.path))
        harness.exited()
        try await waitFor { await recorder.endedCount == 1 }
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.path))
        let closedAfterExit = await session.close()
        XCTAssertTrue(closedAfterExit)
    }

    func testSameAccountKeepsItsWorkingFolderWithDistinctRunSpools() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        for number in 1...2 {
            let session = harness.session()
            let reply = Task { try await collectEvents(try await session.events(for: self.request("Hello"))) }
            try await waitFor { harness.sentCount == number }
            try harness.answer("Hello"); try harness.turnEnded()
            _ = try await reply.value
            _ = await session.close()
        }
        let plans = harness.plans
        XCTAssertEqual(plans[0].directory, plans[1].directory)
        XCTAssertEqual(plans[0].directory, try harness.workspace.workDirectory(harness.account.id))
        XCTAssertNotEqual(plans[0].runDirectory, plans[1].runDirectory)
    }

    /// A new run's first message, as renderClaudePrompt tells a conversation of one.
    func told(_ text: String) -> String { "Human: " + text + "\n\n" }

    func request(_ text: String, tools: [BridgeTool]? = nil) -> BridgeRequest {
        BridgeRequest(model: "claude-sonnet", messages: [.init(role: "user", content: .string(text))], tools: tools)
    }

    /// A run that reads nothing looks less often, up to a cap, and something read brings the pace
    /// straight back: dozens of runs waiting on their client cost the Mac little.
    func testQuietLooksEaseOffAndComeBackAtOnce() {
        var quiet = 0
        let streaming: UInt64 = 10_000_000
        let waits = (0..<6).map { _ in OfficialSession.easedLook(streaming, quiet: &quiet, heard: false) }
        XCTAssertEqual(waits, [20_000_000, 40_000_000, 80_000_000, 160_000_000, 160_000_000, 160_000_000])
        XCTAssertEqual(OfficialSession.easedLook(streaming, quiet: &quiet, heard: true), streaming)
        XCTAssertEqual(quiet, 0)
        // a resting run already looks less often than the cap: it keeps its own pace
        XCTAssertEqual(OfficialSession.easedLook(OfficialSession.restingLook, quiet: &quiet, heard: false), OfficialSession.restingLook)
    }
}
