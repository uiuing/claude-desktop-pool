import Foundation
import XCTest
import PoolCore
import PoolRuntime
@testable import PoolEngine

/// The client's usage-credits screens (2.1.319), as the client words them.
final class UsageCreditsTests: XCTestCase {
    private let object = JSONValue.object(["type": .string("object")])
    private let fable = PoolModel.defaults[3]

    private let choice = """
    ⏺ Working on it

    ────────────────────────────────────────────────
     You've used your included Fable usage for this week. Continuing on Fable 5.1 uses usage credits, purchased separately from your plan.

     ❯ 1. Continue with Fable 5.1
       2. Set up usage credits on claude.ai
       3. No, keep my current model
    """
    private let box = "\n────────────────────────────────────────\n❯ \n────────────────────────────────────────\n"

    private func request(_ text: String) -> BridgeRequest {
        BridgeRequest(model: "claude-fable", messages: [BridgeMessage(role: "user", content: .string(text))], tools: [])
    }

    private func assertFableLimit(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard case .quotaLimited(let windows)? = error as? BridgeFailure else { return XCTFail("\(error)", file: file, line: line) }
        XCTAssertEqual(windows.map(\.id), ["seven_day_overage_included"], file: file, line: line)
        XCTAssertEqual(windows.first?.usedPercent, 100, file: file, line: line)
        XCTAssertEqual(windows.first?.scope, .models(["fable"]), file: file, line: line)
    }

    private func assertOnlyEscape(_ harness: SessionHarness, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(harness.allInputs.contains("\u{1b}"), file: file, line: line)
        XCTAssertFalse(harness.allInputs.suffix(from: harness.allInputs.lastIndex(of: "\u{1b}")!).contains { $0.contains("\r") || $0 == "1" || $0 == "\n" },
                       "nothing but Esc answers the screen", file: file, line: line)
    }

    func testAChoiceDuringTheReplyIsClosedWithEscAndEndsAsAFableLimit() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        harness.model = fable
        let session = harness.session()
        let reply = Task { try await collectEvents(try await session.events(for: self.request("Hello"))) }
        try await waitFor { harness.sentCount == 1 }
        let enters = harness.enterCount
        harness.draw(choice)
        do { _ = try await reply.value; XCTFail("A usage-credits choice was left open") } catch { assertFableLimit(error) }
        XCTAssertEqual(harness.enterCount, enters)
        assertOnlyEscape(harness)
        harness.exited(); _ = await session.close()
    }

    func testAChoiceWhenTheInputBoxIsAwaitedIsClosedTheSameWay() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        harness.model = fable
        harness.acknowledgeInitialTools = false
        harness.startScreen = choice
        let session = harness.session()
        do { _ = try await collectEvents(try await session.events(for: request("Hello"))); XCTFail("A usage-credits choice was left open") }
        catch { assertFableLimit(error) }
        XCTAssertEqual(harness.sentCount, 0)
        XCTAssertEqual(harness.enterCount, 0)
        XCTAssertFalse(harness.allInputs.contains { $0.contains("\r") })
        XCTAssertTrue(harness.allInputs.contains("\u{1b}"))
        harness.exited(); _ = await session.close()
    }

    func testRequiresUsageCreditsInTheFooterEndsTheReplyButTheSameWordsInTheBodyDoNot() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        harness.model = fable
        let session = harness.session(timeout: 5)
        let reply = Task { try await collectEvents(try await session.events(for: self.request("Hello"))) }
        try await waitFor { harness.sentCount == 1 }
        // a reply that discusses the sentences: body only, nothing in the footer
        harness.draw("⏺ The client says: Fable 5 requires usage credits. You've reached your Fable limit.\n  Fable 5.1 is now using usage credits instead of your plan limits.\n  ❯ Continue with Fable is a menu row it would draw." + box + "  ? for shortcuts")
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(harness.allInputs.contains("\u{1b}"))
        try harness.answer("Done.", stop: "end_turn"); try harness.turnEnded()
        let events = try await reply.value
        XCTAssertEqual(events.last, .finished(.endTurn))
        harness.exited(); _ = await session.close()
    }

    func testAFooterNoticeThatTheModelRequiresUsageCreditsEndsTheReply() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        harness.model = fable
        let session = harness.session()
        let reply = Task { try await collectEvents(try await session.events(for: self.request("Hello"))) }
        try await waitFor { harness.sentCount == 1 }
        harness.draw("⏺ Working" + box + "  Fable 5.1 requires usage credits. Run /model to switch.")
        do { _ = try await reply.value; XCTFail("A required-credits notice was ignored") } catch { assertFableLimit(error) }
        XCTAssertTrue(harness.allInputs.contains("\u{1b}"))
        harness.exited(); _ = await session.close()
    }

    func testAReplyAlreadyUsingUsageCreditsGoesOnAndHoldsTheWindow() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        harness.model = fable
        let observations = SessionObservations()
        let session = harness.session()
        let observing = Task { for await event in await session.observations() { await observations.add(event) } }
        defer { observing.cancel() }
        let reply = Task { try await collectEvents(try await session.events(for: self.request("Hello"))) }
        try await waitFor { harness.sentCount == 1 }
        harness.draw("⏺ Working" + box + "  Fable 5.1 is now using usage credits instead of your plan limits")
        try await waitFor { await observations.quotas.contains { $0.id == "seven_day_overage_included" } }
        let window = await observations.quotas.first { $0.id == "seven_day_overage_included" }
        XCTAssertEqual(window?.scope, .models(["fable"]))
        XCTAssertNotNil(window?.refusedUntil)
        XCTAssertFalse(harness.allInputs.contains("\u{1b}"))
        try harness.answer("Still here.", stop: "end_turn"); try harness.turnEnded()
        let events = try await reply.value
        XCTAssertEqual(events.last, .finished(.endTurn))
        harness.exited(); _ = await session.close()
    }

    func testTheScreensAreToldByTheirOwnShapeOnly() {
        XCTAssertEqual(UsageCreditsScreen.look(at: choice), .choice(family: "fable"))
        // a draft that starts like an option is not a list
        XCTAssertNil(UsageCreditsScreen.look(at: "❯ Continue with Fable please" + box))
        // another family's header names its family
        XCTAssertEqual(UsageCreditsScreen.look(at: "x\n────────────────────────────────────────\nOpus 5.5 runs on usage credits — you have $5.00 in credits.\n❯ Yes, re-enable and continue\n  No, keep my current model"), .choice(family: "opus"))
        XCTAssertEqual(UsageCreditsScreen.look(at: "x" + box + "Fable 5.2 requires usage credits"), .required(family: "fable"))
        XCTAssertNil(UsageCreditsScreen.look(at: "Fable 5 requires usage credits" + box))
    }

    func testAUserMessageAndAReplyListAreNotAChoiceBox() async throws {
        // the client's real picture: the user's line starts with "> ", the reply has a numbered list
        let body = "> Continue with the plan\n\n⏺ Here are the next steps:\n  1. Fix the parser\n  2. Continue with tests\n  3. Set up usage credits on claude.ai\n"
        XCTAssertNil(UsageCreditsScreen.look(at: body + box + "  ? for shortcuts"))
        XCTAssertNil(UsageCreditsScreen.look(at: "> Continue with Fable 5.1\n> No, keep my current model\n" + body + box))
        // ">" is no selection mark inside the dialog area either
        XCTAssertNil(UsageCreditsScreen.look(at: "x\n────────────────────────────────────────\n> 1. Continue with Fable 5.1\n  2. No, keep my current model"))
        let harness = try SessionHarness(); defer { harness.clean() }
        harness.model = fable
        let session = harness.session()
        let reply = Task { try await collectEvents(try await session.events(for: self.request("Continue with the plan"))) }
        try await waitFor { harness.sentCount == 1 }
        harness.draw(body + box + "  ? for shortcuts")
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(harness.allInputs.contains("\u{1b}"), "The reply was interrupted by its own words")
        try harness.answer("Done.", stop: "end_turn"); try harness.turnEnded()
        let events = try await reply.value
        XCTAssertEqual(events.last, .finished(.endTurn))
        harness.exited(); _ = await session.close()
    }

    func testTheRealChoiceBoxStillCountsBelowTheTextOfTheConversation() {
        let screen = "> Continue with the plan\n\n⏺ 2. Continue with tests\n" + choice
        XCTAssertEqual(UsageCreditsScreen.look(at: screen), .choice(family: "fable"))
    }
}
