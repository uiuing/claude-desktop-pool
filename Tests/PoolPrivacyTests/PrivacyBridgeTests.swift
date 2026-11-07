import Foundation
import XCTest
import PoolCore
@testable import PoolPrivacy

final class PrivacyBridgeTests: XCTestCase {
    func testRequestsMaskAllTextBoundariesAndKeepProtocolSchemaAndImageBytes() async throws {
        let backend = PrivacyBackendFixture(), detector = FixtureDetector(words: ["Synthetic Person": .person])
        let bridge = PrivacyBridge(backend: backend, detector: detector)
        let image = JSONValue.object(["type": .string("image"), "source": .object(["type": .string("base64"),
            "media_type": .string("image/png"), "data": .string(Data("synthetic image bytes sk-ant-not-a-real-secret".utf8).base64EncodedString())])])
        let schema = JSONValue.object(["type": .string("object"), "properties": .object([
            "user_id": .object(["type": .string("string"), "description": .string("Contact synthetic.user@gmail.com")]),
            "mode": .object(["enum": .array([.string("open"), .string("closed")])])]), "required": .array([.string("user_id")])])
        let request = BridgeRequest(model: "claude-sonnet", messages: [.init(role: "user", content: .array([
            .object(["type": .string("text"), "text": .string("Synthetic Person uses password=fixture-password")]), image]))],
            system: .string("Use synthetic.user@gmail.com"), tools: [.init(name: "send_mail", description: "Synthetic Person", inputSchema: schema)],
            metadata: .object(["user_id": .string("protocol-account-id")]))
        let reply = Task { try await collectPrivacy(try await bridge.events(for: request, conversationID: "request:one")) }
        try await privacyEventually { await backend.requests.count == 1 }
        let masked = await backend.requests[0]
        XCTAssertFalse(masked.system!.stringValue!.contains("synthetic.user@gmail.com"))
        XCTAssertFalse(masked.messages[0].content.arrayValue![0]["text"]!.stringValue!.contains("fixture-password"))
        XCTAssertFalse(masked.tools![0].description!.contains("Synthetic Person"))
        XCTAssertEqual(masked.messages[0].content.arrayValue![1], image)
        XCTAssertEqual(masked.tools![0].name, "send_mail")
        XCTAssertEqual(masked.tools![0].inputSchema["required"], schema["required"])
        XCTAssertEqual(masked.tools![0].inputSchema["properties"]?["mode"], schema["properties"]?["mode"])
        XCTAssertFalse(masked.tools![0].inputSchema["properties"]!["user_id"]!["description"]!.stringValue!.contains("synthetic.user@gmail.com"))
        XCTAssertEqual(masked.metadata, request.metadata)
        await backend.finish(0, [.text("Done"), .finished(.endTurn)])
        _ = try await reply.value
    }

    func testToolRoundTripRestoresArgumentsThenRemasksResultsAndResumedHistory() async throws {
        let backend = PrivacyBackendFixture(), bridge = PrivacyBridge(backend: backend, detector: FixtureDetector())
        let address = "synthetic.user@gmail.com"
        let tools = [BridgeTool(name: "send_mail", inputSchema: .object(["type": .string("object")]))]
        let firstRequest = textRequest("Contact " + address, tools: tools)
        let first = Task { try await collectPrivacy(try await bridge.events(for: firstRequest, conversationID: "request:first")) }
        try await privacyEventually { await backend.requests.count == 1 }
        let maskedFirst = await backend.requests[0]
        let placeholder = try privacyToken(maskedFirst.messages[0].content.stringValue!)
        let call = BridgeToolCall(id: "toolu_protocol_id", name: "send_mail", input: .object([
            "to": .string(placeholder), "name": .string(placeholder), "type": .string(placeholder), "data": .string(placeholder),
            "url": .string("mailto:" + placeholder), "user_id": .string(placeholder)]))
        await backend.finish(0, [.text("Contact " + String(placeholder.prefix(9))), .text(String(placeholder.dropFirst(9))), .toolUse(call), .finished(.toolUse)])
        let firstEvents = try await first.value
        let restoredCall = try XCTUnwrap(firstEvents.compactMap { if case .toolUse(let call) = $0 { return call }; return nil }.first)
        XCTAssertEqual(restoredCall.id, call.id)
        for key in ["to", "name", "type", "data", "user_id"] { XCTAssertEqual(restoredCall.input[key], .string(address)) }
        XCTAssertEqual(restoredCall.input["url"], .string("mailto:" + address))
        var secondRequest = firstRequest
        secondRequest.messages += [.init(role: "assistant", content: privacyAssistant(firstEvents)),
            .init(role: "user", content: .array([.object(["type": .string("tool_result"), "tool_use_id": .string(call.id), "content": .string("Delivered to " + address)])]))]
        let second = Task { try await collectPrivacy(try await bridge.events(for: secondRequest, conversationID: "request:second")) }
        try await privacyEventually { await backend.requests.count == 2 }
        let sent = await backend.requests[1], identities = await backend.identities
        XCTAssertEqual(identities[0], identities[1])
        XCTAssertEqual(sent.messages[0], maskedFirst.messages[0])
        XCTAssertEqual(sent.messages[1].content.arrayValue![0]["text"], .string("Contact " + placeholder))
        XCTAssertEqual(sent.messages[1].content.arrayValue![1]["id"], .string(call.id))
        XCTAssertEqual(sent.messages[1].content.arrayValue![1]["input"]?["to"], .string(placeholder))
        XCTAssertEqual(sent.messages[2].content.arrayValue![0]["tool_use_id"], .string(call.id))
        XCTAssertEqual(sent.messages[2].content.arrayValue![0]["content"], .string("Delivered to " + placeholder))
        await backend.finish(1, [.text("Sent to " + placeholder), .finished(.endTurn)])
        let secondEvents = try await second.value
        var thirdRequest = secondRequest
        thirdRequest.messages += [.init(role: "assistant", content: privacyAssistant(secondEvents)), .init(role: "user", content: .string("Thanks"))]
        let third = Task { try await collectPrivacy(try await bridge.events(for: thirdRequest, conversationID: "request:third")) }
        try await privacyEventually { await backend.requests.count == 3 }
        let thirdID = await backend.identities[2]
        XCTAssertEqual(thirdID, identities[0])
        await backend.finish(2, [.text("Welcome"), .finished(.endTurn)])
        _ = try await third.value
        let stats = await bridge.statistics()
        XCTAssertEqual(stats.protectedRequests, 3)
        XCTAssertGreaterThan(stats.maskedOccurrences, 3)
        XCTAssertGreaterThan(stats.restoredOccurrences, 6)
    }

    func testDifferentContextsAndPerRequestAllowlistCannotRestoreUnsentValues() async throws {
        let backend = PrivacyBackendFixture(), bridge = PrivacyBridge(backend: backend, detector: FixtureDetector())
        let request = textRequest("synthetic.user@gmail.com")
        let a = Task { try await collectPrivacy(try await bridge.events(for: request, conversationID: "a")) }
        try await privacyEventually { await backend.requests.count == 1 }
        let firstToken = try privacyToken(await backend.requests[0].messages[0].content.stringValue!)
        await backend.finish(0, [.text("Done"), .finished(.endTurn)]); _ = try await a.value
        let otherAddress = "other.fixture@gmail.com"
        let b = Task { try await collectPrivacy(try await bridge.events(for: textRequest(otherAddress), conversationID: "b")) }
        try await privacyEventually { await backend.requests.count == 2 }
        let secondToken = try privacyToken(await backend.requests[1].messages[0].content.stringValue!)
        // Stand-ins are numbered in each conversation, so the same one comes up in both; each conversation
        // puts back only its own value, never the other's.
        XCTAssertEqual(firstToken, secondToken)
        await backend.finish(1, [.text(firstToken), .finished(.endTurn)])
        let other = try await b.value.compactMap { if case .text(let t) = $0 { return t }; return nil }.joined()
        XCTAssertEqual(other, otherAddress)
        XCTAssertNotEqual(other, request.messages[0].content.stringValue!)
        let c = Task { try await collectPrivacy(try await bridge.events(for: textRequest("Unrelated"), conversationID: "a")) }
        try await privacyEventually { await backend.requests.count == 3 }
        await backend.finish(2, [.toolUse(.init(id: "new-call", name: "tool", input: .object(["value": .string(firstToken)]))), .finished(.toolUse)])
        let call = try await c.value.compactMap { if case .toolUse(let call) = $0 { return call }; return nil }.first
        XCTAssertEqual(call?.input["value"], .string(firstToken), "A value this request did not send is not put back")
    }

    /// A model that fails finds nothing and
    /// the rules mask alone; the request is not held. The failure is told and logged once, and the model
    /// is not asked again until it has rested (`heldBack`, `retryAfter`).
    func testFailingModelLeavesTheRulesAloneWithoutHoldingTheRequest() async throws {
        let backend = PrivacyBackendFixture(), detector = FixtureDetector(words: ["Synthetic Person": .person])
        let updates = ModelUpdates()
        let bridge = PrivacyBridge(backend: backend, detector: detector, wait: .seconds(30), retryAfter: { _ in .seconds(600) },
                                   onUpdate: { updates.add($0) })
        await detector.configure(failure: .modelFailed)
        let text = "Synthetic Person set password=fixture-secret"
        let began = ContinuousClock.now
        let first = Task { try await collectPrivacy(try await bridge.events(for: textRequest(text), conversationID: "failing")) }
        try await privacyEventually { await backend.requests.count == 1 }
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(10), "A failed model does not keep a request for the whole wait")
        let firstRequests = await backend.requests
        let sent = try XCTUnwrap(firstRequests[0].messages[0].content.stringValue)
        XCTAssertFalse(sent.contains("fixture-secret"), "The rules still mask what they find")
        XCTAssertTrue(sent.hasPrefix("Synthetic Person"), "What only the model finds goes as written while it is broken")
        await backend.finish(0, [.text("Done"), .finished(.endTurn)]); _ = try await first.value
        XCTAssertEqual(updates.models, [.modelFailed])

        // Resting after the failure: the next request does not ask it, and goes at once.
        let asked = await detector.inspected.values.reduce(0, +)
        let second = Task { try await collectPrivacy(try await bridge.events(for: textRequest("Synthetic Person again"), conversationID: "failing-2")) }
        try await privacyEventually { await backend.requests.count == 2 }
        await backend.finish(1, [.text("Done"), .finished(.endTurn)]); _ = try await second.value
        let askedAgain = await detector.inspected.values.reduce(0, +)
        XCTAssertEqual(askedAgain, asked)
        XCTAssertEqual(updates.models, [.modelFailed], "Told once a streak")
        let stats = await bridge.statistics()
        XCTAssertEqual(stats.protectedRequests, 2)
        XCTAssertTrue(updates.blocked.isEmpty, "No request was refused")
    }

    func testModelThatRecoversIsAskedAgainAndToldReading() async throws {
        let backend = PrivacyBackendFixture(), detector = FixtureDetector(words: ["Synthetic Person": .person])
        let updates = ModelUpdates()
        let bridge = PrivacyBridge(backend: backend, detector: detector, wait: .seconds(5), retryAfter: { _ in .milliseconds(50) },
                                   onUpdate: { updates.add($0) })
        await detector.configure(invalid: true)
        let first = Task { try await collectPrivacy(try await bridge.events(for: textRequest("\u{1f680} Synthetic Person"), conversationID: "invalid")) }
        try await privacyEventually { await backend.requests.count == 1 }
        let unread = await backend.requests[0].messages[0].content.stringValue
        XCTAssertEqual(unread, "\u{1f680} Synthetic Person",
                       "An invalid answer is no answer: the rules alone, which find nothing here")
        await backend.finish(0, [.text("Done"), .finished(.endTurn)]); _ = try await first.value
        XCTAssertEqual(updates.models, [.invalidDetection])
        await detector.configure()
        try await Task.sleep(for: .milliseconds(80))
        let second = Task { try await collectPrivacy(try await bridge.events(for: textRequest("Ask Synthetic Person"), conversationID: "recovered")) }
        try await privacyEventually { await backend.requests.count == 2 }
        let read = await backend.requests[1].messages[0].content.stringValue
        XCTAssertFalse(try XCTUnwrap(read).contains("Synthetic Person"))
        await backend.finish(1, [.text("Done"), .finished(.endTurn)]); _ = try await second.value
        XCTAssertEqual(updates.models, [.invalidDetection, nil])
    }

    /// A slow model: the request goes after the wait with the rules for what the model had not read
    /// (a partial reading). The model reads on; the conversation's earlier text goes again byte for byte
    /// as it went, a value the model found in it since is masked in new text
    /// (`learnLate`), and a request that masks the same text afresh finds the reading at once.
    func testSlowModelPastTheWaitSendsRulesThenLaterRequestsFindItsReading() async throws {
        let backend = PrivacyBackendFixture(), detector = FixtureDetector(words: ["Synthetic Person": .person])
        // The model takes far longer than the wait, so a slow test machine cannot blur the two.
        await detector.configure(delay: 2_500_000_000)
        let bridge = PrivacyBridge(backend: backend, detector: detector, wait: .milliseconds(60))
        let opening = textRequest("Ask Synthetic Person about password=fixture-secret")
        let began = ContinuousClock.now
        let first = Task { try await collectPrivacy(try await bridge.events(for: opening, conversationID: "slow")) }
        try await privacyEventually { await backend.requests.count == 1 }
        XCTAssertLessThan(ContinuousClock.now - began, .milliseconds(2_000), "The request did not wait for the model past its wait")
        let firstSent = await backend.requests[0]
        let sentText = try XCTUnwrap(firstSent.messages[0].content.stringValue)
        XCTAssertTrue(sentText.hasPrefix("Ask Synthetic Person about password="), "Unread by the model: what only it finds goes as written")
        XCTAssertFalse(sentText.contains("fixture-secret"), "The rules mask what they find within the wait")
        await backend.finish(0, [.text("Asked."), .finished(.endTurn)])
        let firstEvents = try await first.value

        // The model reads on after the request went.
        try await privacyEventually { await detector.inspected.keys.contains { $0.contains("Synthetic Person") } }
        try await privacyEventually { await detector.finished > 0 }
        try await Task.sleep(for: .milliseconds(100))
        var next = opening
        next.messages += [.init(role: "assistant", content: privacyAssistant(firstEvents)), .init(role: "user", content: .string("Thank Synthetic Person"))]
        let second = Task { try await collectPrivacy(try await bridge.events(for: next, conversationID: "slow")) }
        try await privacyEventually { await backend.requests.count == 2 }
        let secondSent = await backend.requests[1]
        XCTAssertEqual(secondSent.messages[0], firstSent.messages[0], "Sent history goes again byte for byte")
        // Keys sorted: JSONEncoder does not keep a dictionary's order from one encoding to the next.
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(secondSent.messages[0]), try encoder.encode(firstSent.messages[0]))
        XCTAssertFalse(try XCTUnwrap(secondSent.messages[2].content.stringValue).contains("Synthetic Person"),
                       "What the model found since in the earlier text is known for new text")
        await backend.finish(1, [.text("Done"), .finished(.endTurn)]); _ = try await second.value

        // Another conversation masking the same text afresh finds the reading kept, without waiting.
        let asked = await detector.inspected.values.reduce(0, +)
        let third = Task { try await collectPrivacy(try await bridge.events(for: opening, conversationID: "slow-other")) }
        try await privacyEventually { await backend.requests.count == 3 }
        let thirdRequests = await backend.requests
        let thirdText = try XCTUnwrap(thirdRequests[2].messages[0].content.stringValue)
        XCTAssertFalse(thirdText.contains("Synthetic Person"))
        XCTAssertFalse(thirdText.contains("fixture-secret"))
        let askedAfter = await detector.inspected.values.reduce(0, +)
        XCTAssertEqual(askedAfter, asked, "The kept reading was used, not read again")
        await backend.finish(2, [.text("Done"), .finished(.endTurn)]); _ = try await third.value
    }

    /// A conversation forked in Desktop (11-07) arrives under a new client session with the history it
    /// was forked from. Masked afresh, it lost its conversation and went to another account, so the
    /// prompt cache its parent wrote was not read. It is matched by its first exchange as written.
    func testAForkUnderANewClientSessionStaysInTheConversationItWasForkedFrom() async throws {
        let backend = PrivacyBackendFixture(), detector = FixtureDetector(words: ["Synthetic Person": .person])
        let bridge = PrivacyBridge(backend: backend, detector: detector)
        func text(_ value: String, cached: Bool = false) -> JSONValue {
            var block: [String: JSONValue] = ["type": .string("text"), "text": .string(value)]
            if cached { block["cache_control"] = .object(["type": .string("ephemeral")]) }
            return .array([.object(block)])
        }
        func turn(_ request: BridgeRequest, _ alias: String, _ reply: String) async throws -> [BridgeEvent] {
            let index = await backend.requests.count
            let task = Task { try await collectPrivacy(try await bridge.events(for: request, conversationID: alias)) }
            try await privacyEventually { await backend.requests.count == index + 1 }
            await backend.finish(index, [.text(reply), .finished(.endTurn)])
            return try await task.value
        }
        // Claude Code marks the newest message for the cache; the mark moves on with each turn.
        var parent = BridgeRequest(model: "claude-opus", messages: [.init(role: "user", content: text("Plan for Synthetic Person", cached: true))])
        let first = try await turn(parent, "parent-session#shape", "Step one")
        parent.messages[0].content = text("Plan for Synthetic Person")
        parent.messages += [.init(role: "assistant", content: privacyAssistant(first)), .init(role: "user", content: text("Go on", cached: true))]
        _ = try await turn(parent, "parent-session#shape", "Step two")
        // Forked from the first reply, not the latest: the fork's history is no context's whole history.
        let fork = BridgeRequest(model: "claude-opus", messages: Array(parent.messages.prefix(2)) + [.init(role: "user", content: text("Try another way", cached: true))])
        _ = try await turn(fork, "fork-session#shape", "Another way")
        let other = BridgeRequest(model: "claude-opus", messages: [.init(role: "user", content: text("Something else")),
            .init(role: "assistant", content: text("Sure")), .init(role: "user", content: text("Go on"))])
        _ = try await turn(other, "other-session#shape", "Done")
        let identities = await backend.identities.map { try? XCTUnwrap($0) }
        func tag(_ id: String??) -> String? { (id ?? nil)?.split(separator: "@").last.map(String.init) }
        XCTAssertEqual(identities[0], identities[1], "The parent's turns share one context")
        XCTAssertNotEqual(identities[2], identities[0], "The fork has a context of its own")
        XCTAssertEqual(tag(identities[2]), tag(identities[0]), "and is in the conversation it was forked from")
        XCTAssertNotEqual(tag(identities[3]), tag(identities[0]), "A conversation that opened otherwise is its own")
    }

    func testManualTextIsMaskedOnlyInsideMatchingActiveRestorationScope() async throws {
        let backend = PrivacyBackendFixture(), bridge = PrivacyBridge(backend: backend, detector: FixtureDetector())
        let response = Task { try await collectPrivacy(try await bridge.events(for: textRequest("Wait"), conversationID: "manual")) }
        try await privacyEventually { await backend.requests.count == 1 }
        let identities = await backend.identities
        let backendID = try XCTUnwrap(identities[0])
        let masked = try await bridge.maskManualInput("password=manual-fixture-secret", conversationID: backendID)
        XCTAssertFalse(masked.contains("manual-fixture-secret"))
        let token = try privacyToken(masked)
        await backend.finish(0, [.text(token), .finished(.endTurn)])
        let events = try await response.value
        XCTAssertEqual(events.privacyText, "manual-fixture-secret")
        do { _ = try await bridge.maskManualInput("private input", conversationID: backendID); XCTFail("Idle manual input accepted") }
        catch { XCTAssertTrue(error is BridgeFailure) }
    }

    func testPreviewIsSeparateAndConcurrentActivityReturnsToZero() async throws {
        let backend = PrivacyBackendFixture(), detector = FixtureDetector(), updates = PrivacyUpdatesFixture()
        let bridge = PrivacyBridge(backend: backend, detector: detector, onUpdate: { updates.add($0) })
        let preview = try await PrivacyBridge.preview("synthetic.user@gmail.com", detector: detector)
        XCTAssertEqual(preview.maskedOccurrences, 1)
        XCTAssertFalse(preview.maskedText.contains("synthetic.user@gmail.com"))
        let before = await bridge.statistics()
        XCTAssertEqual(before, PrivacyStatistics())
        await detector.configure(delay: 30_000_000)
        let a = Task { try await collectPrivacy(try await bridge.events(for: textRequest("synthetic.user@gmail.com"), conversationID: "a")) }
        let b = Task { try await collectPrivacy(try await bridge.events(for: textRequest("another.synthetic@gmail.com"), conversationID: "b")) }
        try await privacyEventually { await backend.requests.count == 2 }
        await backend.finish(0, [.text("Done"), .finished(.endTurn)]); await backend.finish(1, [.text("Done"), .finished(.endTurn)])
        _ = try await a.value; _ = try await b.value
        XCTAssertTrue(updates.active.contains(2))
        XCTAssertEqual(updates.active.last, 0)
        // The preview held nothing of the bridge's: each conversation numbers its own stand-ins from 1.
        let sent = await backend.requests
        XCTAssertTrue(sent.allSatisfy { $0.messages[0].content.stringValue?.contains("{{EMAIL_1}}") == true })
    }

    func testCancellationDuringMaskingNeverForwardsRequest() async throws {
        let backend = PrivacyBackendFixture(), detector = FixtureDetector()
        await detector.configure(delay: 50_000_000)
        let bridge = PrivacyBridge(backend: backend, detector: detector)
        let response = Task { try await collectPrivacy(try await bridge.events(for: textRequest("Secret fixture"), conversationID: "cancel")) }
        try await Task.sleep(nanoseconds: 10_000_000)
        await bridge.cancel(conversationID: "cancel")
        do { _ = try await response.value; XCTFail("Cancelled masking forwarded") }
        catch { XCTAssertEqual(error as? BridgeFailure, .cancelled) }
        let count = await backend.requests.count
        XCTAssertEqual(count, 0)
    }

    func testSchemaValuesAndNumericArgumentsAreProtectedWithoutChangingTypes() async throws {
        let backend = PrivacyBackendFixture(), bridge = PrivacyBridge(backend: backend, detector: FixtureDetector())
        let original = 123_456_789.0
        let schema = JSONValue.object(["type": .string("object"), "properties": .object([
            "account_number": .object(["type": .string("integer"), "default": .number(original), "enum": .array([.number(original)]),
                "examples": .array([.number(original)]), "minimum": .number(100_000_000), "maximum": .number(999_999_999)]),
            "email": .object(["type": .string("string"), "default": .string("synthetic.user@gmail.com"),
                "enum": .array([.string("synthetic.user@gmail.com")]), "examples": .array([.string("synthetic.user@gmail.com")])])]),
            "required": .array([.string("account_number")])])
        let request = textRequest("Use the selected account", tools: [.init(name: "lookup", inputSchema: schema)])
        let response = Task { try await collectPrivacy(try await bridge.events(for: request, conversationID: "number")) }
        try await privacyEventually { await backend.requests.count == 1 }
        let masked = await backend.requests[0]
        let property = try XCTUnwrap(masked.tools![0].inputSchema["properties"]?["account_number"])
        let standin = try XCTUnwrap(property["default"]?.doubleValue)
        XCTAssertNotEqual(standin, original)
        XCTAssertTrue((100_000_000...999_999_999).contains(standin))
        XCTAssertEqual(property["type"], .string("integer"))
        XCTAssertEqual(property["enum"], .array([.number(standin)]))
        XCTAssertEqual(property["examples"], .array([.number(standin)]))
        XCTAssertEqual(property["minimum"], .number(100_000_000))
        XCTAssertEqual(masked.tools![0].inputSchema["required"], schema["required"])
        XCTAssertFalse(String(decoding: try masked.tools![0].inputSchema.encoded(), as: UTF8.self).contains("synthetic.user@gmail.com"))
        let numberText = PrivacyConversation.numberText(standin)
        await backend.finish(0, [.text("Account " + String(numberText.prefix(4))), .text(String(numberText.dropFirst(4)) + "."),
            .toolUse(.init(id: "numeric-call", name: "lookup", input: .object(["account_number": .number(standin), "page": .number(3)]))), .finished(.toolUse)])
        let events = try await response.value
        XCTAssertEqual(events.privacyText, "Account 123456789.")
        let call = try XCTUnwrap(events.compactMap { if case .toolUse(let call) = $0 { return call }; return nil }.first)
        XCTAssertEqual(call.input["account_number"], .number(original))
        XCTAssertEqual(call.input["page"], .number(3))
        var next = request
        next.messages += [.init(role: "assistant", content: privacyAssistant(events)),
            .init(role: "user", content: .array([.object(["type": .string("tool_result"), "tool_use_id": .string(call.id), "content": .string("Account 123456789 is available")])]))]
        let continuation = Task { try await collectPrivacy(try await bridge.events(for: next, conversationID: "number")) }
        try await privacyEventually { await backend.requests.count == 2 }
        let nextMasked = await backend.requests[1]
        XCTAssertEqual(nextMasked.messages[1].content.arrayValue![0]["text"], .string("Account " + numberText + "."))
        XCTAssertEqual(nextMasked.messages[1].content.arrayValue![1]["input"]?["account_number"], .number(standin))
        XCTAssertFalse(nextMasked.messages[2].content.arrayValue![0]["content"]!.stringValue!.contains("123456789"))
        await backend.finish(1, [.text(numberText), .finished(.endTurn)])
        let continued = try await continuation.value
        XCTAssertEqual(continued.privacyText, "123456789")
    }

    func testNewKnownValueMasksNewOccurrenceButKeepsAlreadySentHistory() async throws {
        let backend = PrivacyBackendFixture(), bridge = PrivacyBridge(backend: backend, detector: FixtureDetector())
        let original = textRequest("rileymorgan")
        let first = Task { try await collectPrivacy(try await bridge.events(for: original, conversationID: "known")) }
        try await privacyEventually { await backend.requests.count == 1 }
        await backend.finish(0, [.toolUse(.init(id: "lookup-name", name: "lookup", input: .object([:]))), .finished(.toolUse)])
        let events = try await first.value
        var next = original
        next.messages += [.init(role: "assistant", content: privacyAssistant(events)), .init(role: "user", content: .array([
            .object(["type": .string("tool_result"), "tool_use_id": .string("lookup-name"), "content": .array([
                .object(["type": .string("text"), "text": .string("rileymorgan")]),
                .object(["type": .string("text"), "text": .string("username: rileymorgan")])])])]))]
        let second = Task { try await collectPrivacy(try await bridge.events(for: next, conversationID: "known")) }
        try await privacyEventually { await backend.requests.count == 2 }
        let sent = await backend.requests[1]
        XCTAssertEqual(sent.messages[0].content, .string("rileymorgan"), "An already-sent prefix remains stable")
        let content = try XCTUnwrap(sent.messages[2].content.arrayValue![0]["content"]?.arrayValue)
        XCTAssertFalse(content[0]["text"]!.stringValue!.contains("rileymorgan"), "A new occurrence must use newly learned privacy evidence")
        XCTAssertFalse(content[1]["text"]!.stringValue!.contains("rileymorgan"))
        await backend.finish(1, [.text("Done"), .finished(.endTurn)]); _ = try await second.value
    }

    func testTwoPassPreparationInspectsEachTextOnceAndSentHistoryIsNotReadAgain() async throws {
        let backend = PrivacyBackendFixture(), detector = FixtureDetector()
        let bridge = PrivacyBridge(backend: backend, detector: detector)
        var request = textRequest("Repeated fixture text")
        request.system = .string("Repeated fixture text")
        for index in 0..<2 {
            let response = Task { try await collectPrivacy(try await bridge.events(for: request, conversationID: "memo")) }
            try await privacyEventually { await backend.requests.count == index + 1 }
            await backend.finish(index, [.text("Done"), .finished(.endTurn)])
            _ = try await response.value
        }
        let inspected = await detector.inspected
        XCTAssertEqual(inspected, ["Repeated fixture text": 1], "One text read once; the request is not held on a readiness probe")
    }

    func testModelCannotSplitUTF16SurrogatePair() async throws {
        struct SplitDetector: PrivacyEntityDetector {
            func detect(in text: String) async throws -> [PrivacySpan] {
                text.isEmpty ? [] : [.init(start: 1, end: 2, category: .person)]
            }
        }
        let backend = PrivacyBackendFixture(), updates = ModelUpdates()
        let bridge = PrivacyBridge(backend: backend, detector: SplitDetector(), onUpdate: { updates.add($0) })
        let response = Task { try await collectPrivacy(try await bridge.events(for: textRequest("\u{1f680} Test"), conversationID: "unicode")) }
        try await privacyEventually { await backend.requests.count == 1 }
        let sent = await backend.requests[0].messages[0].content.stringValue
        XCTAssertEqual(sent, "\u{1f680} Test", "The split span is not taken: the rules alone, which find nothing")
        XCTAssertEqual(updates.models, [.invalidDetection])
        do { _ = try await PrivacyBridge.preview("\u{1f680} Test", detector: SplitDetector()); XCTFail("A preview took a split surrogate") }
        catch { XCTAssertEqual(error as? PrivacyFailure, .invalidDetection) }
        await backend.finish(0, [.text("Done"), .finished(.endTurn)]); _ = try await response.value
    }

    func testRequestStateClosesOnTransportFailureAndStreamCancellationCancelsBackend() async throws {
        let backend = PrivacyBackendFixture(), updates = PrivacyUpdatesFixture()
        let bridge = PrivacyBridge(backend: backend, detector: FixtureDetector(), onUpdate: { updates.add($0) })
        let first = Task { try await collectPrivacy(try await bridge.events(for: textRequest("Wait"), conversationID: "request:failure")) }
        try await privacyEventually { await backend.requests.count == 1 }
        await backend.fail(0)
        do { _ = try await first.value; XCTFail("Transport failure succeeded") }
        catch { XCTAssertEqual(error as? BridgeFailure, .transport) }
        XCTAssertEqual(updates.requestStates.map(\.1), [true, false])
        let firstID = try XCTUnwrap(updates.requestStates.first?.0)
        let enabled = await bridge.canAcceptManualInput(conversationID: firstID)
        XCTAssertFalse(enabled)
        let second = Task { try await collectPrivacy(try await bridge.events(for: textRequest("Wait again"), conversationID: "request:cancel-stream")) }
        try await privacyEventually { await backend.requests.count == 2 }
        second.cancel()
        if let output = try? await second.value { XCTAssertFalse(output.contains(.finished(.endTurn))) }
        try await privacyEventually { await backend.cancelled.count > 0 }
        try await privacyEventually { updates.requestStates.map(\.1) == [true, false, true, false] }
    }

    func testUICancellationClosesManualScopeBeforeAwaitingBackend() async throws {
        let backend = PrivacyBackendFixture(), updates = PrivacyUpdatesFixture()
        let bridge = PrivacyBridge(backend: backend, detector: FixtureDetector(), onUpdate: { updates.add($0) })
        let response = Task { try await collectPrivacy(try await bridge.events(for: textRequest("Wait"), conversationID: "ui-cancel")) }
        try await privacyEventually { await backend.requests.count == 1 }
        let identities = await backend.identities, id = try XCTUnwrap(identities[0])
        await backend.holdCancellation()
        let cancellation = Task { await bridge.cancelSession(conversationID: id) }
        try await privacyEventually { await backend.cancelled.count == 1 }
        let enabled = await bridge.canAcceptManualInput(conversationID: id)
        XCTAssertFalse(enabled)
        XCTAssertEqual(updates.requestStates.last?.1, false)
        do { _ = try await bridge.maskManualInput("private text", conversationID: id); XCTFail("Cancellation retained an input scope") }
        catch { XCTAssertTrue(error is BridgeFailure) }
        await backend.releaseCancellation()
        let cancelled = await cancellation.value
        XCTAssertTrue(cancelled)
        do { _ = try await response.value; XCTFail("UI cancellation completed normally") }
        catch { XCTAssertEqual(error as? BridgeFailure, .cancelled) }
        let calls = await backend.cancelled
        XCTAssertEqual(calls.count, 1, "A stream termination must not send a second interrupt")
    }

    func testFailedPreparationDoesNotFreezeUnsentTextOrNumbers() async throws {
        try await assertUnsentPreparationIsRetried(.maskFailure)
    }
    func testCancelledPreparationDoesNotFreezeUnsentTextOrNumbers() async throws {
        try await assertUnsentPreparationIsRetried(.maskCancellation)
    }
    func testBackendFailureBeforeFirstEventDoesNotFreezeTextOrNumbers() async throws {
        try await assertUnsentPreparationIsRetried(.backendFailure)
    }
    func testBackendCancellationBeforeFirstEventDoesNotFreezeTextOrNumbers() async throws {
        try await assertUnsentPreparationIsRetried(.backendCancellation)
    }

    private enum InterruptedPreparation { case maskFailure, maskCancellation, backendFailure, backendCancellation }
    private func assertUnsentPreparationIsRetried(_ mode: InterruptedPreparation) async throws {
        let backend = PrivacyBackendFixture(), detector = PreparationDetectorFixture()
        let bridge = PrivacyBridge(backend: backend, detector: detector)
        let number = 12_345_678.0
        let base = BridgeRequest(model: "claude-sonnet", messages: [.init(role: "user", content: .string("Ready"))], system: .string("rileymorgan"),
            tools: [.init(name: "first", inputSchema: .object(["type": .string("object"), "properties": .object([
                "value": .object(["type": .string("integer"), "default": .number(number)])])]))])
        var interrupted = base
        if mode == .maskFailure {
            // A model failure no longer stops a request (the rules mask alone), nor does placeholder-shaped
            // text; a text too large to mask does.
            interrupted.tools?.append(.init(name: "last", description: String(repeating: "a", count: 8 * 1024 * 1024 + 1), inputSchema: .object([:])))
        } else if mode == .maskCancellation {
            interrupted.tools?.append(.init(name: "last", description: "stop preprocessing", inputSchema: .object([:])))
            await detector.arm(fail: false)
        }
        let first = Task { try await collectPrivacy(try await bridge.events(for: interrupted, conversationID: "retry")) }
        if mode == .maskCancellation {
            try await privacyEventually { await detector.isWaiting }
            await bridge.cancel(conversationID: "retry")
            await detector.resume()
        } else if mode == .backendFailure || mode == .backendCancellation {
            try await privacyEventually { await backend.requests.count == 1 }
            if mode == .backendFailure { await backend.fail(0) }
            else { await bridge.cancel(conversationID: "retry") }
        }
        do { _ = try await first.value; XCTFail("Interrupted request succeeded") }
        catch { XCTAssertTrue(error is BridgeFailure) }
        await detector.resume()
        let beforeLearning = await backend.requests.count
        let learning = BridgeRequest(model: "claude-sonnet", messages: [.init(role: "user", content: .string("Continue"))], system: .string("username: rileymorgan"),
            tools: [.init(name: "account", inputSchema: .object(["type": .string("object"), "properties": .object([
                "account_number": .object(["type": .string("integer"), "default": .number(number)])])]))])
        let learn = Task { try await collectPrivacy(try await bridge.events(for: learning, conversationID: "retry")) }
        try await privacyEventually { await backend.requests.count == beforeLearning + 1 }
        await backend.finish(beforeLearning, [.text("Learned"), .finished(.endTurn)])
        _ = try await learn.value
        let retry = Task { try await collectPrivacy(try await bridge.events(for: base, conversationID: "retry")) }
        try await privacyEventually { await backend.requests.count == beforeLearning + 2 }
        let sent = await backend.requests[beforeLearning + 1]
        XCTAssertNotEqual(sent.system, .string("rileymorgan"), "A never-sent occurrence must use newly known protection")
        XCTAssertNotEqual(sent.tools![0].inputSchema["properties"]?["value"]?["default"], .number(number), "An unsent numeric draft must not become a frozen history entry")
        await backend.finish(beforeLearning + 1, [.text("Done"), .finished(.endTurn)])
        _ = try await retry.value
    }

    func testReusedTerminalRejectsManualTextDuringHTTPPreparation() async throws {
        let backend = PrivacyBackendFixture(), detector = PreparationDetectorFixture(), updates = PrivacyUpdatesFixture()
        let bridge = PrivacyBridge(backend: backend, detector: detector, onUpdate: { updates.add($0) })
        let initial = Task { try await collectPrivacy(try await bridge.events(for: textRequest("Hello"), conversationID: "manual-prepare")) }
        try await privacyEventually { await backend.requests.count == 1 }
        let identities = await backend.identities, id = try XCTUnwrap(identities[0])
        await backend.finish(0, [.text("Hello"), .finished(.endTurn)]); _ = try await initial.value
        await detector.arm(fail: false)
        let next = Task { try await collectPrivacy(try await bridge.events(for: textRequest("stop preprocessing"), conversationID: "manual-prepare")) }
        try await privacyEventually { await detector.isWaiting }
        let preparing = await bridge.canAcceptManualInput(conversationID: id)
        XCTAssertFalse(preparing)
        XCTAssertEqual(updates.requestStates.last?.1, false)
        if !preparing {
            do { _ = try await bridge.maskManualInput("private text", conversationID: id); XCTFail("Manual text accepted during preprocessing") }
            catch { XCTAssertTrue(error is BridgeFailure) }
        }
        await detector.resume()
        try await privacyEventually { await backend.requests.count == 2 }
        let accepted = await bridge.canAcceptManualInput(conversationID: id)
        XCTAssertTrue(accepted)
        await backend.finish(1, [.text("Ready"), .finished(.endTurn)]); _ = try await next.value
    }

    func testEachProtectedRequestIsReviewedAsReceivedAndAsSentOnlyForWhatIsNew() async throws {
        let backend = PrivacyBackendFixture(), updates = ReviewUpdates()
        let bridge = PrivacyBridge(backend: backend, detector: FixtureDetector(), onUpdate: { updates.add($0) })
        let address = "review@fixture-mail.net"
        let first = textRequest("Write to " + address + " today")
        let reply = Task { try await collectPrivacy(try await bridge.events(for: first, conversationID: "request:review-one")) }
        try await privacyEventually { await backend.requests.count == 1 }
        let placeholder = try privacyToken(await backend.requests[0].messages[0].content.stringValue!)
        await backend.finish(0, [.text("Sent to " + placeholder), .finished(.endTurn)])
        let events = try await reply.value
        try await privacyEventually { updates.restored.values.contains(1) }
        var reviews = updates.reviews
        XCTAssertEqual(reviews.count, 1)
        XCTAssertEqual(reviews[0].fields.map(\.location), ["messages/0/content/text"])
        XCTAssertEqual(reviews[0].fields[0].segments, [.text("Write to "), .replaced(original: address, placeholder: placeholder, category: .email), .text(" today")])
        XCTAssertEqual(reviews[0].categories, [.email: 1])
        XCTAssertEqual(updates.restored[reviews[0].id], 1)

        // The next turn sends the first again unchanged; only its new message is reviewed.
        var second = first
        second.messages += [.init(role: "assistant", content: privacyAssistant(events)), .init(role: "user", content: .string("Copy " + address))]
        let next = Task { try await collectPrivacy(try await bridge.events(for: second, conversationID: "request:review-two")) }
        try await privacyEventually { await backend.requests.count == 2 }
        await backend.finish(1, [.text("Done"), .finished(.endTurn)])
        _ = try await next.value
        reviews = updates.reviews
        XCTAssertEqual(reviews.count, 2)
        XCTAssertEqual(reviews[1].fields.map(\.location), ["messages/2/content/text"])
        XCTAssertEqual(reviews[1].fields[0].segments, [.text("Copy "), .replaced(original: address, placeholder: placeholder, category: .email)])
    }

    func testReviewKeepsOnlyTheContextAroundEachReplacement() {
        let long = String(repeating: "a", count: 5000), middle = String(repeating: "b", count: 5000)
        let field = PrivacyReviewField(location: "messages/0/content/text", segments: [
            .text(long), .replaced(original: "x", placeholder: "{{EMAIL_1}}", category: .email),
            .text(middle), .replaced(original: "y", placeholder: "{{EMAIL_2}}", category: .email), .text(long)])
        let texts = field.segments.compactMap { if case .text(let text) = $0 { return text }; return nil }
        XCTAssertEqual(texts.map(\.count), [PrivacyReviewField.context + 1, 2 * PrivacyReviewField.context + 3, PrivacyReviewField.context + 1])
        XCTAssertTrue(texts[0].hasPrefix("…")); XCTAssertTrue(texts[2].hasSuffix("…"))
        XCTAssertEqual(field.replacedCount, 2)
        let short = PrivacyReviewField(location: "system/text", segments: [.text("Use "), .replaced(original: "x", placeholder: "p", category: .email)])
        XCTAssertEqual(short.segments, [.text("Use "), .replaced(original: "x", placeholder: "p", category: .email)])
    }

    func testToolResultWhoseContextIsGoneIsMaskedAfreshNotRefused() async throws {
        let backend = PrivacyBackendFixture(), bridge = PrivacyBridge(backend: backend, detector: FixtureDetector(words: ["Synthetic Person": .person]))
        let tools = [BridgeTool(name: "Read", inputSchema: .object(["type": .string("object")]))]
        let firstRequest = textRequest("Ask Synthetic Person about the notes.", tools: tools)
        let first = Task { try await collectPrivacy(try await bridge.events(for: firstRequest, conversationID: "desktop")) }
        try await privacyEventually { await backend.requests.count == 1 }
        let call = BridgeToolCall(id: "toolu_fixture_gone", name: "Read", input: .object(["file_path": .string("/fixture/notes.txt")]))
        await backend.finish(0, [.toolUse(call), .finished(.toolUse)])
        let firstEvents = try await first.value
        // The protected conversation is gone (forgotten, evicted) while the client ran its tool.
        await bridge.forget(conversationID: "desktop")
        var next = firstRequest
        next.messages += [.init(role: "assistant", content: privacyAssistant(firstEvents)),
                          .init(role: "user", content: .array([.object(["type": .string("tool_result"), "tool_use_id": .string(call.id),
                                                                        "content": .string("Synthetic Person wrote three items.")])]))]
        let second = Task { try await collectPrivacy(try await bridge.events(for: next, conversationID: "desktop")) }
        try await privacyEventually { await backend.requests.count == 2 }
        let sent = await backend.requests[1], identities = await backend.identities
        XCTAssertNotEqual(identities[0], identities[1], "A new protected context, so the pool tells the whole conversation anew.")
        XCTAssertEqual(sent.messages.count, 3)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(sent), as: UTF8.self).contains("Synthetic Person"))
        await backend.finish(1, [.text("Done."), .finished(.endTurn)])
        let events = try await second.value
        XCTAssertEqual(events.last, .finished(.endTurn))
    }

    /// Claude Code's ToolSearch answers with `tool_reference` blocks inside its tool result; they are
    /// walked like any other block (protocol fields kept), never refused.
    func testToolSearchReferencesPassThroughAndOtherBlocksAreMasked() async throws {
        let backend = PrivacyBackendFixture(), bridge = PrivacyBridge(backend: backend, detector: FixtureDetector(words: ["Synthetic Person": .person]))
        let tools = [BridgeTool(name: "ToolSearch", inputSchema: .object(["type": .string("object")]))]
        var request = textRequest("Find the notes tool.", tools: tools)
        request.messages += [
            .init(role: "assistant", content: .array([.object(["type": .string("tool_use"), "id": .string("toolu_fixture_search"),
                                                               "name": .string("ToolSearch"), "input": .object(["query": .string("notes")])])])),
            .init(role: "user", content: .array([.object([
                "type": .string("tool_result"), "tool_use_id": .string("toolu_fixture_search"),
                "content": .array([.object(["type": .string("tool_reference"), "tool_name": .string("mcp__fixture__read_notes")]),
                                   .object(["type": .string("fixture_note"), "note": .string("Synthetic Person keeps them.")])])])]))
        ]
        let task = Task { try await collectPrivacy(try await bridge.events(for: request, conversationID: "desktop")) }
        try await privacyEventually { await backend.requests.count == 1 }
        let sent = await backend.requests[0]
        let parts = sent.messages.last?.content.arrayValue?.first?["content"]?.arrayValue
        XCTAssertEqual(parts?.first, .object(["type": .string("tool_reference"), "tool_name": .string("mcp__fixture__read_notes")]))
        XCTAssertEqual(parts?.last?["type"], .string("fixture_note"))
        XCTAssertFalse(parts?.last?["note"]?.stringValue?.contains("Synthetic Person") ?? true)
        await backend.finish(0, [.text("Found it."), .finished(.endTurn)])
        let events = try await task.value
        XCTAssertEqual(events.last, .finished(.endTurn))
    }

    func testLongTextIsReadInOverlappingPiecesInsteadOfRefused() async throws {
        let detector = FixtureDetector(words: ["Synthetic Person": .person])
        // Wait for every piece: this is about reading a long text in pieces, not about the wait.
        let backend = PrivacyBackendFixture(), bridge = PrivacyBridge(backend: backend, detector: detector, wait: .seconds(60))
        let filler = String(repeating: "synthetic log line with nothing private\n", count: 20_000)
        let text = filler + "Signed by Synthetic Person.\n" + filler
        XCTAssertGreaterThan(text.utf8.count, 1024 * 1024)
        let task = Task { try await collectPrivacy(try await bridge.events(for: textRequest(text), conversationID: "long")) }
        // Over a megabyte through every rule, twice, in a debug build: seconds, not the usual 3 s wait.
        let began = Date()
        while await backend.requests.isEmpty {
            if Date().timeIntervalSince(began) > 60 { _ = try await task.value; return XCTFail("The long request was never sent.") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let sent = await backend.requests[0].messages[0].content.stringValue ?? ""
        XCTAssertFalse(sent.contains("Synthetic Person"))
        XCTAssertTrue(sent.contains("{{PERSON_"))
        XCTAssertEqual(sent.utf8.count - text.utf8.count, try privacyToken(sent).utf8.count - "Synthetic Person".utf8.count)
        let longest = await detector.inspected.keys.map(\.utf8.count).max() ?? 0
        XCTAssertLessThanOrEqual(longest, 12 * 1024)
        await backend.finish(0, [.text("Read."), .finished(.endTurn)])
        _ = try await task.value
    }

    func testPiecesOverlapAndCoverTheWholeText() {
        let text = Array((String(repeating: "word ", count: 9_000) + String(repeating: "\u{4e2d}", count: 6_000)).utf8)
        let pieces = TextPieces.cut(text)
        XCTAssertEqual(pieces.first?.lowerBound, 0); XCTAssertEqual(pieces.last?.upperBound, text.count)
        for (previous, next) in zip(pieces, pieces.dropFirst()) {
            XCTAssertLessThan(next.lowerBound, previous.upperBound, "Each piece reads some of the one before again.")
            XCTAssertGreaterThan(next.lowerBound, previous.lowerBound)
        }
        for piece in pieces {
            XCTAssertLessThanOrEqual(piece.count, TextPieces.size)
            XCTAssertNotNil(String(validatingUTF8: text[piece].map { CChar(bitPattern: $0) } + [0]), "Pieces start and end at a character.")
        }
    }

    /// A real full log (11-07): each prepared request kept the conversation whole twice, as received and
    /// as sent, 955 KB a request. It keeps what the review shows and what was found, not the conversation.
    func testTheFullLogKeepsEachReplacementAndWhatWasFoundNotTheConversation() async throws {
        let lock = NSLock()
        nonisolated(unsafe) var lines: [Data] = []
        DevRecord.install { entry in if entry.channel == .privacy { lock.withLock { lines.append(entry.line) } } }
        defer { DevRecord.install(nil) }
        let backend = PrivacyBackendFixture(), bridge = PrivacyBridge(backend: backend, detector: FixtureDetector(words: ["Synthetic Person": .person]))
        let reply = Task { try await collectPrivacy(try await bridge.events(for: textRequest("Write to Synthetic Person"), conversationID: "request:recorded")) }
        try await privacyEventually { await backend.requests.count == 1 }
        let sent = await backend.requests[0].messages[0].content.stringValue!
        let placeholder = try privacyToken(sent)
        await backend.finish(0, [.text("Hello " + placeholder), .finished(.endTurn)])
        _ = try await reply.value
        let records = lock.withLock { lines }.compactMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        let prepared = try XCTUnwrap(records.first { $0["kind"] == .string("privacy.prepared") })
        XCTAssertNil(prepared["data"]?["received"]); XCTAssertNil(prepared["data"]?["sent"])
        let replaced = prepared["data"]?["review"]?.arrayValue?.first?["segments"]?.arrayValue?.first { $0["original"] != nil }
        XCTAssertEqual(replaced?["original"], .string("Synthetic Person"))
        XCTAssertEqual(replaced?["placeholder"], .string(placeholder))
        XCTAssertTrue(sent.contains(placeholder))
        let text = try XCTUnwrap(prepared["data"]?["model_texts"]?.arrayValue?.first)
        XCTAssertNil(text["text"], "A text the model read is kept by its length and what was found in it")
        XCTAssertEqual(text["chars"], .number(25))
        XCTAssertEqual(text["model"]?.arrayValue?.first?["category"], .string("PERSON"))
        XCTAssertEqual(text["model"]?.arrayValue?.first?["text"], .string("Synthetic Person"))
        let restored = try XCTUnwrap(records.first { $0["kind"] == .string("privacy.reply_text") })
        XCTAssertEqual(restored["data"]?["from_model"], .string("Hello " + placeholder))
        XCTAssertEqual(restored["data"]?["to_client"], .string("Hello Synthetic Person"))
        let finished = try XCTUnwrap(records.first { $0["kind"] == .string("privacy.reply_finished") })
        XCTAssertEqual(finished["data"]?["unrestored_placeholders"], .array([]))
        XCTAssertEqual(Set(records.compactMap { $0["review"]?.stringValue }).count, 1)
    }

    /// Off, a request reaches the pool as Desktop sent it, under Desktop's id, and its cancel does too;
    /// on again, the next request of the same conversation is redacted.
    func testTurnedOffPassesRequestsUnchangedAndOnAgainRedactsTheNext() async throws {
        let backend = PrivacyBackendFixture(), bridge = PrivacyBridge(backend: backend, detector: FixtureDetector(words: ["Synthetic Person": .person]))
        await bridge.setEnabled(false)
        let first = textRequest("Synthetic Person uses password=fixture-password")
        let plain = Task { try await collectPrivacy(try await bridge.events(for: first, conversationID: "conversation:desktop")) }
        try await privacyEventually { await backend.requests.count == 1 }
        let sent = await backend.requests[0], identities = await backend.identities
        XCTAssertEqual(sent, first)
        XCTAssertEqual(identities[0], "conversation:desktop")
        await bridge.cancel(conversationID: "conversation:desktop")
        let cancelled = await backend.cancelled
        XCTAssertEqual(cancelled, ["conversation:desktop"])
        _ = try? await plain.value
        let before = await bridge.statistics()
        XCTAssertEqual(before.protectedRequests, 0)

        await bridge.setEnabled(true)
        var second = first
        second.messages += [.init(role: "assistant", content: .string("Noted")), .init(role: "user", content: .string("Again, Synthetic Person"))]
        let masked = Task { try await collectPrivacy(try await bridge.events(for: second, conversationID: "conversation:desktop")) }
        try await privacyEventually { await backend.requests.count == 2 }
        let redacted = await backend.requests[1], secondID = await backend.identities[1]
        XCTAssertFalse(redacted.messages[0].content.stringValue!.contains("Synthetic Person"))
        XCTAssertFalse(redacted.messages[2].content.stringValue!.contains("Synthetic Person"))
        XCTAssertNotEqual(secondID, "conversation:desktop")
        await backend.finish(1, [.text("Done"), .finished(.endTurn)])
        _ = try await masked.value
        let after = await bridge.statistics()
        XCTAssertEqual(after.protectedRequests, 1)
    }

    private func textRequest(_ text: String, tools: [BridgeTool]? = nil) -> BridgeRequest {
        .init(model: "claude-sonnet", messages: [.init(role: "user", content: .string(text))], tools: tools)
    }
}

private final class ModelUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private var storedModels: [PrivacyFailure?] = []
    private var storedBlocked: [PrivacyFailure] = []
    func add(_ update: PrivacyUpdate) {
        lock.lock(); defer { lock.unlock() }
        switch update {
        case .model(let failure): storedModels.append(failure)
        case .blocked(let failure): storedBlocked.append(failure)
        default: break
        }
    }
    var models: [PrivacyFailure?] { lock.lock(); defer { lock.unlock() }; return storedModels }
    var blocked: [PrivacyFailure] { lock.lock(); defer { lock.unlock() }; return storedBlocked }
}

private final class ReviewUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private var storedReviews: [PrivacyReview] = []
    private var storedRestored: [UUID: Int] = [:]
    func add(_ update: PrivacyUpdate) {
        lock.lock(); defer { lock.unlock() }
        switch update {
        case .reviewed(let review): storedReviews.append(review)
        case .restored(let id, let count): storedRestored[id] = count
        default: break
        }
    }
    var reviews: [PrivacyReview] { lock.lock(); defer { lock.unlock() }; return storedReviews }
    var restored: [UUID: Int] { lock.lock(); defer { lock.unlock() }; return storedRestored }
}

private actor PrivacyBackendFixture: BridgeBackend {
    var requests: [BridgeRequest] = []
    var identities: [String?] = []
    var cancelled: [String] = []
    private var continuations: [AsyncThrowingStream<BridgeEvent, Error>.Continuation] = []
    private var holdCancel = false
    private var cancellationWaiters: [CheckedContinuation<Void, Never>] = []
    func events(for request: BridgeRequest, conversationID: String?) -> AsyncThrowingStream<BridgeEvent, Error> {
        requests.append(request); identities.append(conversationID)
        return AsyncThrowingStream { continuations.append($0) }
    }
    func cancel(conversationID: String) async {
        cancelled.append(conversationID)
        if holdCancel { await withCheckedContinuation { cancellationWaiters.append($0) } }
        for (index, id) in identities.enumerated() where id == conversationID { continuations[index].finish(throwing: BridgeFailure.cancelled) }
    }
    func holdCancellation() { holdCancel = true }
    func releaseCancellation() {
        holdCancel = false
        for continuation in cancellationWaiters { continuation.resume() }
        cancellationWaiters = []
    }
    func finish(_ index: Int, _ events: [BridgeEvent]) {
        for event in events { continuations[index].yield(event) }
        continuations[index].finish()
    }
    func fail(_ index: Int) { continuations[index].finish(throwing: BridgeFailure.transport) }
}
private actor PreparationDetectorFixture: PrivacyEntityDetector {
    private var armed = false
    private var fail = false
    private var waiter: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { waiter != nil }
    func arm(fail: Bool) { armed = true; self.fail = fail }
    func resume() { armed = false; waiter?.resume(); waiter = nil }
    func detect(in text: String) async throws -> [PrivacySpan] {
        if armed && text.contains("stop preprocessing") {
            if fail { throw PrivacyFailure.modelFailed }
            await withCheckedContinuation { waiter = $0 }
        }
        return []
    }
}
private final class PrivacyUpdatesFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    private var requests: [(String, Bool)] = []
    var active: [Int] { lock.withLock { values } }
    var requestStates: [(String, Bool)] { lock.withLock { requests } }
    func add(_ update: PrivacyUpdate) {
        if case .processing(let count) = update { lock.withLock { values.append(count) } }
        if case .requestState(let id, let active) = update { lock.withLock { requests.append((id, active)) } }
    }
}
private func privacyEventually(_ predicate: () async -> Bool) async throws {
    let end = Date().addingTimeInterval(30)
    while !(await predicate()) {
        if Date() > end { throw BridgeFailure.transport }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}
private func privacyToken(_ text: String) throws -> String {
    let start = try XCTUnwrap(text.range(of: "{{")), end = try XCTUnwrap(text.range(of: "}}", range: start.lowerBound..<text.endIndex))
    return String(text[start.lowerBound..<end.upperBound])
}
private func collectPrivacy(_ stream: AsyncThrowingStream<BridgeEvent, Error>) async throws -> [BridgeEvent] {
    var events: [BridgeEvent] = []
    for try await event in stream { events.append(event) }
    return events
}
private extension Array where Element == BridgeEvent {
    var privacyText: String { compactMap { if case .text(let text) = $0 { return text }; return nil }.joined() }
}
private func privacyAssistant(_ events: [BridgeEvent]) -> JSONValue {
    var content: [JSONValue] = [], text = ""
    for event in events {
        switch event {
        case .text(let part): text += part
        case .toolUse(let call):
            if !text.isEmpty { content.append(.object(["type": .string("text"), "text": .string(text)])); text = "" }
            content.append(.object(["type": .string("tool_use"), "id": .string(call.id), "name": .string(call.name), "input": call.input]))
        default: break
        }
    }
    if !text.isEmpty { content.append(.object(["type": .string("text"), "text": .string(text)])) }
    return .array(content)
}
