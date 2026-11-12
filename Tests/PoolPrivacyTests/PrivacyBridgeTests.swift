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

    /// A block of any kind the person sent keeps its encoded bytes as they are (`"type": "base64"` beside
    /// its `data`) while words in it, a text source's data too, are masked like any words.
    func testEncodedBytesPassAndWordsAreMaskedInBlocksOfAnyKind() async throws {
        let backend = PrivacyBackendFixture(), bridge = PrivacyBridge(backend: backend, detector: FixtureDetector(words: ["Synthetic Person": .person]))
        let bytes = Data("Synthetic Person %PDF fixture".utf8).base64EncodedString()
        let encoded = JSONValue.object(["type": .string("fixture_file"), "source": .object(["type": .string("base64"),
            "media_type": .string("application/x-fixture"), "data": .string(bytes)]), "title": .string("Synthetic Person's file")])
        let written = JSONValue.object(["type": .string("fixture_file"), "source": .object(["type": .string("text"),
            "media_type": .string("text/plain"), "data": .string("Written by Synthetic Person.")])])
        var request = textRequest("Read these.")
        request.messages[0].content = .array([.object(["type": .string("text"), "text": .string("Read these.")]), encoded, written])
        let task = Task { try await collectPrivacy(try await bridge.events(for: request, conversationID: "desktop")) }
        try await privacyEventually { await backend.requests.count == 1 }
        let first = await backend.requests[0]
        let sent = try XCTUnwrap(first.messages[0].content.arrayValue)
        XCTAssertEqual(sent[1]["source"]?["data"], .string(bytes), "Encoded bytes are not text")
        XCTAssertEqual(sent[1]["source"]?["media_type"], .string("application/x-fixture"))
        XCTAssertFalse(sent[1]["title"]?.stringValue?.contains("Synthetic Person") ?? true)
        XCTAssertFalse(sent[2]["source"]?["data"]?.stringValue?.contains("Synthetic Person") ?? true, "A text source's words are masked")
        await backend.finish(0, [.text("Read."), .finished(.endTurn)])
        _ = try await task.value
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

extension PrivacyBridgeTests {
    /// After a restart a conversation's history goes masked as it went, even where the model would now
    /// find more than it had read in time, so the pool can go on from its session; the call it was
    /// waiting on is answered in the same context, under the same conversation id.
    func testRestartKeepsHistoryMaskedAsItWentAndCallsOnTheirContext() async throws {
        let detector = FixtureDetector(words: ["Synthetic Person": .person])
        let first = PrivacyBackendFixture()
        // The model has no time: the first turn goes with the rules alone.
        let before = PrivacyBridge(backend: first, detector: detector, wait: .zero)
        let tools = [BridgeTool(name: "lookup", inputSchema: .object(["type": .string("object")]))]
        var request = BridgeRequest(model: "claude-sonnet", messages: [.init(role: "user", content: .string(
            "Synthetic Person keeps notes in /Users/synthetic-owner/notes"))], tools: tools)
        let alias = "session-restart#shape"
        let opening = Task { try await collectPrivacy(try await before.events(for: request, conversationID: alias)) }
        try await privacyEventually { await first.requests.count == 1 }
        let sent = await first.requests[0], identity = await first.identities[0]
        let home = try privacyNamed(sent.messages[0].content.stringValue!)
        let call = BridgeToolCall(id: "toolu_restart_call", name: "lookup", input: .object(["path": .string("/Users/\(home)/notes")]))
        await first.finish(0, [.toolUse(call), .finished(.toolUse)])
        let events = try await opening.value
        let saved = await before.savedContexts()
        let data = try XCTUnwrap(saved)
        let kept = String(decoding: try XCTUnwrap((data as NSData).decompressed(using: .lzfse) as Data), as: UTF8.self)
        for original in ["synthetic-owner", "Synthetic Person", "notes"] { XCTAssertFalse(kept.contains(original), "No value or word is kept: \(original)") }

        let second = PrivacyBackendFixture()
        let after = PrivacyBridge(backend: second, detector: detector)
        await after.restoreContexts(data)
        request.messages += [.init(role: "assistant", content: privacyAssistant(events)), .init(role: "user", content: .array([.object([
            "type": .string("tool_result"), "tool_use_id": .string(call.id), "content": .string("Found for Synthetic Person")])]))]
        let next = Task { try await collectPrivacy(try await after.events(for: request, conversationID: alias)) }
        try await privacyEventually { await second.requests.count == 1 }
        let resent = await second.requests[0], resentIdentity = await second.identities[0]
        XCTAssertEqual(resentIdentity, identity, "The pool sees the same conversation")
        XCTAssertEqual(resent.messages[0], sent.messages[0], "History goes as it went before the restart")
        XCTAssertEqual(resent.messages[1].content.arrayValue?[0]["input"]?["path"], .string("/Users/\(home)/notes"))
        XCTAssertFalse(resent.messages[2].content.arrayValue![0]["content"]!.stringValue!.contains("Synthetic Person"),
                       "New text is read by the model")
        await second.finish(0, [.text("Done"), .finished(.endTurn)])
        _ = try await next.value
    }

    func testSavedContextsLeaveOutConversationsPastTheirTime() async throws {
        let backend = PrivacyBackendFixture(), bridge = PrivacyBridge(backend: backend, detector: FixtureDetector())
        let reply = Task { try await collectPrivacy(try await bridge.events(for: self.textRequest("Notes in /Users/synthetic-owner/a"), conversationID: "old#shape")) }
        try await privacyEventually { await backend.requests.count == 1 }
        await backend.finish(0, [.text("Done"), .finished(.endTurn)]); _ = try await reply.value
        let later = Date().addingTimeInterval(PrivacyBridge.keptFor + 60)
        let none = await bridge.savedContexts(now: later)
        XCTAssertNil(none)
        let saved = await bridge.savedContexts()
        let data = try XCTUnwrap(saved)
        let restored = PrivacyBridge(backend: PrivacyBackendFixture(), detector: FixtureDetector())
        await restored.restoreContexts(data, now: later)
        await restored.restoreContexts(Data("not saved contexts".utf8))
    }
}

private func privacyNamed(_ text: String) throws -> String {
    let start = try XCTUnwrap(text.range(of: "/Users/")), rest = text[start.upperBound...]
    let name = String(rest.prefix { $0 != "/" })
    XCTAssertTrue(name.hasPrefix("user-"), "The home folder's owner is masked")
    return name
}

extension PrivacyBridgeTests {
    /// This Mac's account name is masked wherever it stands as a word, as the same stand-in as its home
    /// folder: in a listing's owner column and in a folder named after a path; never inside a longer word.
    func testMachineUserIsMaskedWhereverItStandsAsAWord() async throws {
        let backend = PrivacyBackendFixture()
        let bridge = PrivacyBridge(backend: backend, detector: FixtureDetector(), wait: .seconds(5), machineUsers: ["synthowner"])
        let text = "cd /Users/synthowner/app\n-rw-r--r--  1 synthowner  staff  12 notes\n~/.claude/projects/-Users-synthowner-app/\nsynthowners stay"
        let reply = Task { try await collectPrivacy(try await bridge.events(for: self.textRequest(text), conversationID: "machine#shape")) }
        try await privacyEventually { await backend.requests.count == 1 }
        let sent = await backend.requests[0].messages[0].content.stringValue!
        XCTAssertFalse(sent.contains("synthowner "), sent)
        XCTAssertFalse(sent.contains("-synthowner-"), sent)
        XCTAssertTrue(sent.contains("synthowners stay"), "Not inside a longer word")
        let standIn = try privacyNamed(sent)
        XCTAssertTrue(sent.contains("1 \(standIn)  staff"))
        XCTAssertTrue(sent.contains("-Users-\(standIn)-app"))
        await backend.finish(0, [.text("Listed for \(standIn)"), .finished(.endTurn)])
        let told = try await reply.value.privacyText
        XCTAssertEqual(told, "Listed for synthowner")
    }

    /// Claude Code keeps a pasted image under a folder named after the project's path, so the account
    /// name in it is masked between hyphens. The model's call to read it must reach the client with the
    /// real name, or the client is told the file does not exist.
    func testAStandInBetweenHyphensInAToolCallComesBackAsTheName() async throws {
        let name = "synthowner", backend = PrivacyBackendFixture()
        let bridge = PrivacyBridge(backend: backend, detector: FixtureDetector(), wait: .seconds(5), machineUsers: [name])
        let path = "/private/tmp/claude-501/-Users-" + name + "-Documents-app/7f3c/images/3.png"
        let reply = Task { try await collectPrivacy(try await bridge.events(for: self.textRequest("[Image: source: \(path)]"), conversationID: "machine#slug")) }
        try await privacyEventually { await backend.requests.count == 1 }
        let sent = await backend.requests[0].messages[0].content.stringValue!
        XCTAssertFalse(sent.contains("-\(name)-"), sent)
        let slug = try XCTUnwrap(sent.range(of: "-Users-")), after = sent[slug.upperBound...]
        let standIn = String(after[..<(try XCTUnwrap(after.range(of: "-Documents-"))).lowerBound])
        XCTAssertTrue(standIn.hasPrefix("user-"), "The folder's owner is masked")
        let masked = path.replacingOccurrences(of: "-\(name)-", with: "-\(standIn)-")
        XCTAssertTrue(sent.contains(masked), sent)
        let call = BridgeToolCall(id: "toolu_slug", name: "Read", input: .object(["file_path": .string(masked)]))
        // split inside the stand-in, as a stream may cut it
        let cut = masked.range(of: standIn)!.upperBound
        await backend.finish(0, [.text("Opening " + String(masked[..<cut])), .text(String(masked[cut...]) + "."), .toolUse(call), .finished(.toolUse)])
        let events = try await reply.value
        XCTAssertEqual(events.privacyText, "Opening \(path).")
        let told = try XCTUnwrap(events.compactMap { if case .toolUse(let call) = $0 { return call }; return nil }.first)
        XCTAssertEqual(told.input["file_path"]?.stringValue, path)
    }

    /// Thinking is put back as the words are, on its own: a stand-in the stream cut across two
    /// thinking fragments is never shown cut, nor carried into the answer's words; the signature
    /// passes as it came.
    func testThinkingIsRestoredApartFromTheWordsAndNeverShownCut() async throws {
        let backend = PrivacyBackendFixture(), bridge = PrivacyBridge(backend: backend, detector: FixtureDetector())
        let address = "synthetic.user@gmail.com"
        let reply = Task { try await collectPrivacy(try await bridge.events(for: self.textRequest("Contact " + address), conversationID: "request:thinking")) }
        try await privacyEventually { await backend.requests.count == 1 }
        let placeholder = try privacyToken(await backend.requests[0].messages[0].content.stringValue!)
        await backend.finish(0, [.thinking("Write to " + String(placeholder.prefix(5))), .thinking(String(placeholder.dropFirst(5)) + " now"),
                                 .thinkingSignature("c2lnLXN5bnRoZXRpYw=="), .text("Mailing " + placeholder), .finished(.endTurn)])
        let events = try await reply.value
        let thought = events.compactMap { if case .thinking(let text) = $0 { return text }; return nil }
        XCTAssertEqual(thought.joined(), "Write to \(address) now")
        XCTAssertFalse(thought.contains { $0.contains("{{") && !$0.contains("}}") }, "No fragment shows a stand-in cut")
        XCTAssertTrue(thought.allSatisfy { !$0.contains(placeholder) })
        XCTAssertEqual(events.privacyText, "Mailing \(address)")
        let signature = try XCTUnwrap(events.firstIndex(of: .thinkingSignature("c2lnLXN5bnRoZXRpYw==")))
        let firstText = try XCTUnwrap(events.firstIndex { if case .text = $0 { return true }; return false })
        XCTAssertLessThan(signature, firstText)
        XCTAssertTrue(events[signature...].allSatisfy { if case .thinking = $0 { return false }; return true }, "All thinking is told before its signature")
    }

    func testOnlyAccountNamesWorthMaskingAreTakenAsMachineUsers() {
        XCTAssertTrue(PrivacyRules.machineUser("synthowner"))
        XCTAssertTrue(PrivacyRules.machineUser("abc"))
        for name in ["ab", "root", "admin", "shared", "Guest", "test", "名字", "two words"] { XCTAssertFalse(PrivacyRules.machineUser(name), name) }
    }
}

extension PrivacyBridgeTests {
    /// A number masked by its field's kind goes as it went after a restart, and a history changed
    /// meanwhile is masked afresh rather than taken for what went.
    func testRestartKeepsMaskedNumbersAndMasksAChangedHistoryAfresh() async throws {
        let first = PrivacyBackendFixture(), before = PrivacyBridge(backend: first, detector: FixtureDetector(), wait: .seconds(5))
        let call = JSONValue.object(["type": .string("tool_use"), "id": .string("toolu_number"), "name": .string("dial"),
                                     "input": .object(["phone": .number(13_800_138_000)])])
        var request = BridgeRequest(model: "claude-sonnet", messages: [
            .init(role: "user", content: .string("Call the office, notes in /Users/synthetic-owner/a")),
            .init(role: "assistant", content: .array([call])),
            .init(role: "user", content: .array([.object(["type": .string("tool_result"), "tool_use_id": .string("toolu_number"), "content": .string("ok")])]))])
        let alias = "session-number#shape"
        let opening = Task { try await collectPrivacy(try await before.events(for: request, conversationID: alias)) }
        try await privacyEventually { await first.requests.count == 1 }
        let sent = await first.requests[0]
        XCTAssertNotEqual(sent.messages[1].content.arrayValue?[0]["input"]?["phone"], .number(13_800_138_000))
        await first.finish(0, [.text("Called"), .finished(.endTurn)])
        let events = try await opening.value
        let saved = await before.savedContexts()
        let data = try XCTUnwrap(saved)
        let kept = String(decoding: try XCTUnwrap((data as NSData).decompressed(using: .lzfse) as Data), as: UTF8.self)
        XCTAssertFalse(kept.contains("13800138000"), "The number masked is not kept")

        request.messages += [.init(role: "assistant", content: privacyAssistant(events)), .init(role: "user", content: .string("Again"))]
        let second = PrivacyBackendFixture(), after = PrivacyBridge(backend: second, detector: FixtureDetector())
        await after.restoreContexts(data)
        let next = Task { try await collectPrivacy(try await after.events(for: request, conversationID: alias)) }
        try await privacyEventually { await second.requests.count == 1 }
        let resent = await second.requests[0]
        XCTAssertEqual(Array(resent.messages.prefix(3)), sent.messages, "History goes as it went")
        await second.finish(0, [.text("Called again"), .finished(.endTurn)])
        _ = try await next.value

        var changed = request
        changed.messages[0] = .init(role: "user", content: .string("Call the office, notes in /Users/synthetic-owner/b"))
        let third = PrivacyBackendFixture(), again = PrivacyBridge(backend: third, detector: FixtureDetector())
        await again.restoreContexts(data)
        let other = Task { try await collectPrivacy(try await again.events(for: changed, conversationID: alias)) }
        try await privacyEventually { await third.requests.count == 1 }
        let fresh = await third.requests[0].messages[0].content.stringValue!
        XCTAssertFalse(fresh.contains("synthetic-owner"), "Masked afresh")
        XCTAssertTrue(fresh.hasSuffix("/b"))
        await third.finish(0, [.text("Done"), .finished(.endTurn)])
        _ = try await other.value
    }
}

extension PrivacyBridgeTests {
    /// Parallel tasks of one conversation share its id, each in a context of its own: a task's tool
    /// result goes back to the context that made its call, though the id last served the other task, so
    /// its history is not masked afresh and the pool keeps its run.
    func testParallelTasksOfOneConversationEachKeepTheirContext() async throws {
        let backend = PrivacyBackendFixture(), bridge = PrivacyBridge(backend: backend, detector: FixtureDetector(), wait: .seconds(5))
        let tools = [BridgeTool(name: "lookup", inputSchema: .object(["type": .string("object")]))]
        let alias = "session-parallel#shape"
        let taskA = textRequest("Task A: read /Users/synthetic-owner/a", tools: tools), taskB = textRequest("Task B: read /Users/synthetic-owner/b", tools: tools)
        let a = Task { try await collectPrivacy(try await bridge.events(for: taskA, conversationID: alias)) }
        try await privacyEventually { await backend.requests.count == 1 }
        // A is still answering: B gets a context of its own.
        let b = Task { try await collectPrivacy(try await bridge.events(for: taskB, conversationID: alias)) }
        try await privacyEventually { await backend.requests.count == 2 }
        let identities = await backend.identities
        XCTAssertNotEqual(identities[0], identities[1])
        let callA = BridgeToolCall(id: "toolu_task_a", name: "lookup", input: .object([:]))
        let callB = BridgeToolCall(id: "toolu_task_b", name: "lookup", input: .object([:]))
        await backend.finish(1, [.toolUse(callB), .finished(.toolUse)])
        await backend.finish(0, [.toolUse(callA), .finished(.toolUse)])
        let eventsA = try await a.value, eventsB = try await b.value
        func answered(_ request: BridgeRequest, _ events: [BridgeEvent], _ call: BridgeToolCall) -> BridgeRequest {
            var next = request
            next.messages += [.init(role: "assistant", content: privacyAssistant(events)), .init(role: "user", content: .array([.object([
                "type": .string("tool_result"), "tool_use_id": .string(call.id), "content": .string("ok")])]))]
            return next
        }
        // B was served last under the id; A's result still goes to A's context, and B's to B's.
        let nextA = Task { try await collectPrivacy(try await bridge.events(for: answered(taskA, eventsA, callA), conversationID: alias)) }
        try await privacyEventually { await backend.requests.count == 3 }
        let nextB = Task { try await collectPrivacy(try await bridge.events(for: answered(taskB, eventsB, callB), conversationID: alias)) }
        try await privacyEventually { await backend.requests.count == 4 }
        let after = await backend.identities, sent = await backend.requests
        XCTAssertEqual(after[2], identities[0], "A's result goes to A's context")
        XCTAssertEqual(after[3], identities[1], "B's result goes to B's context")
        XCTAssertEqual(sent[2].messages[0], sent[0].messages[0], "A's history goes as it went")
        XCTAssertEqual(sent[3].messages[0], sent[1].messages[0], "B's history goes as it went")
        await backend.finish(2, [.text("A done"), .finished(.endTurn)])
        await backend.finish(3, [.text("B done"), .finished(.endTurn)])
        _ = try await nextA.value; _ = try await nextB.value
    }
}

extension PrivacyBridgeTests {
    /// A new task of a conversation whose context is answering has no history to share with it: it gets
    /// a context of its own at once, without waiting for the other.
    func testNewTaskBesideABusyContextDoesNotWait() async throws {
        let backend = PrivacyBackendFixture(), bridge = PrivacyBridge(backend: backend, detector: FixtureDetector(), wait: .seconds(5))
        let alias = "session-single#shape"
        let a = Task { try await collectPrivacy(try await bridge.events(for: textRequest("Task A: open https://a.example.com"), conversationID: alias)) }
        try await privacyEventually { await backend.requests.count == 1 }
        let began = ContinuousClock.now
        let b = Task { try await collectPrivacy(try await bridge.events(for: textRequest("Task B: open https://b.example.com"), conversationID: alias)) }
        try await privacyEventually { await backend.requests.count == 2 }
        XCTAssertLessThan(ContinuousClock.now - began, .milliseconds(700), "No wait for the busy context")
        let identities = await backend.identities
        XCTAssertNotEqual(identities[0], identities[1])
        await backend.finish(0, [.text("A done"), .finished(.endTurn)])
        await backend.finish(1, [.text("B done"), .finished(.endTurn)])
        _ = try await a.value; _ = try await b.value
    }

    /// A conversation's turn whose context is answering waits for it: woken when it ends, it goes on
    /// in that context; when it does not end in time, it gets a context of its own.
    func testTurnWaitsForItsBusyContextThenTakesItOrANewOne() async throws {
        for ends in [true, false] {
            let backend = PrivacyBackendFixture(), bridge = PrivacyBridge(backend: backend, detector: FixtureDetector(), wait: .seconds(5))
            let alias = "session-wait-\(ends)#shape"
            let opening = textRequest("Read https://docs.example.com")
            let first = Task { try await collectPrivacy(try await bridge.events(for: opening, conversationID: alias)) }
            try await privacyEventually { await backend.requests.count == 1 }
            await backend.finish(0, [.text("Read it"), .finished(.endTurn)])
            let reply = try await first.value
            func turn(_ text: String) -> BridgeRequest {
                var next = opening
                next.messages += [.init(role: "assistant", content: privacyAssistant(reply)), .init(role: "user", content: .string(text))]
                return next
            }
            let busy = Task { try await collectPrivacy(try await bridge.events(for: turn("Go on"), conversationID: alias)) }
            try await privacyEventually { await backend.requests.count == 2 }
            let began = ContinuousClock.now
            let waiting = Task { try await collectPrivacy(try await bridge.events(for: turn("Also check"), conversationID: alias)) }
            try await Task.sleep(for: .milliseconds(200))
            let held = await backend.requests.count
            XCTAssertEqual(held, 2, "The turn waits for the busy context")
            if ends {
                let ended = ContinuousClock.now
                await backend.finish(1, [.text("Gone on"), .finished(.endTurn)])
                try await privacyEventually { await backend.requests.count == 3 }
                XCTAssertLessThan(ContinuousClock.now - ended, .milliseconds(500), "Woken when the context's request ends")
            } else {
                try await privacyEventually { await backend.requests.count == 3 }
                XCTAssertGreaterThanOrEqual(ContinuousClock.now - began, .milliseconds(1400), "Waited its time")
            }
            let identities = await backend.identities
            if ends { XCTAssertEqual(identities[2], identities[0], "Goes on in the context it waited for") }
            else { XCTAssertNotEqual(identities[2], identities[0], "A context of its own after the wait") }
            if !ends { await backend.finish(1, [.text("Gone on"), .finished(.endTurn)]) }
            await backend.finish(2, [.text("Checked"), .finished(.endTurn)])
            _ = try await busy.value; _ = try await waiting.value
        }
    }
}

extension PrivacyBridgeTests {
    /// Two tasks of one conversation served in turn by its context, each with its own words at the same
    /// place: after a restart each task's history goes as it went, not only the one saved last.
    func testRestartKeepsEveryTasksTextAtAPlace() async throws {
        let first = PrivacyBackendFixture(), before = PrivacyBridge(backend: first, detector: FixtureDetector(), wait: .seconds(5))
        let alias = "session-tasks#shape"
        let taskA = textRequest("Task A: read /Users/synthetic-owner/a"), taskB = textRequest("Task B: list /Users/synthetic-owner/b")
        var events: [[BridgeEvent]] = []
        for (index, request) in [taskA, taskB].enumerated() {
            let reply = Task { try await collectPrivacy(try await before.events(for: request, conversationID: alias)) }
            try await privacyEventually { await first.requests.count == index + 1 }
            await first.finish(index, [.text("Done \(index)"), .finished(.endTurn)])
            events.append(try await reply.value)
        }
        let identities = await first.identities, sent = await first.requests
        XCTAssertEqual(identities[0], identities[1], "One context served both tasks")
        let saved = await before.savedContexts()
        let data = try XCTUnwrap(saved)

        let second = PrivacyBackendFixture(), after = PrivacyBridge(backend: second, detector: FixtureDetector())
        await after.restoreContexts(data)
        for (index, request) in [taskA, taskB].enumerated() {
            var next = request
            next.messages += [.init(role: "assistant", content: privacyAssistant(events[index])), .init(role: "user", content: .string("Go on"))]
            let reply = Task { try await collectPrivacy(try await after.events(for: next, conversationID: alias)) }
            try await privacyEventually { await second.requests.count == index + 1 }
            let resent = await second.requests[index]
            XCTAssertEqual(resent.messages[0], sent[index].messages[0], "Task \(index)'s history goes as it went")
            await second.finish(index, [.text("Again"), .finished(.endTurn)])
            _ = try await reply.value
        }
    }
}
