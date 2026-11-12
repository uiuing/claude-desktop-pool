import Foundation
import XCTest
import PoolCore
@testable import PoolEngine

final class CoordinatorAdmissionTests: XCTestCase {
    func testCheckSaysWhetherATurnWouldBeTakenWithoutStartingOne() async throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let ready = PoolAccount(email: "admission@example.invalid", plan: "Pro", state: .ready)
        let pool = PoolCoordinator(accounts: [ready], now: { date }, factory: { _, _ in
            XCTFail("A check never starts a session"); throw BridgeFailure.transport
        })
        try await pool.checkAdmission(model: "claude-haiku")

        // Every account at its limit: the check says so, and when the first is back.
        let reset = date.addingTimeInterval(1800)
        await pool.updateAccounts([PoolAccount(email: "admission@example.invalid", plan: "Pro", state: .ready, windows: [
            QuotaWindow(id: "five_hour", usedPercent: 100, observedAt: date, resetsAt: reset)])])
        do { try await pool.checkAdmission(model: "claude-haiku"); XCTFail("A pool at its limit was admitted") }
        catch { XCTAssertEqual(error as? BridgeFailure, .rateLimited(reset)) }

        await pool.updateAccounts([PoolAccount(email: "admission@example.invalid", state: .signedOut)])
        do { try await pool.checkAdmission(model: "claude-haiku"); XCTFail("A pool without a usable account was admitted") }
        catch { XCTAssertEqual(error as? BridgeFailure, .unavailable) }
        let sessions = await pool.sessions()
        XCTAssertTrue(sessions.isEmpty)
    }

    /// A request that finds every account at its limit is told the pool's limit and when the first
    /// account is back, the earliest of them, not a moment's "no account" the client asks again on at once.
    func testARequestIsToldThePoolsLimitAndItsEarliestReset() async throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        func limited(_ name: String, back: TimeInterval) -> PoolAccount {
            PoolAccount(email: name + "@example.com", plan: "Pro", state: .ready, windows: [
                QuotaWindow(id: "five_hour", usedPercent: 100, observedAt: date, resetsAt: date.addingTimeInterval(back)),
                QuotaWindow(id: "seven_day", usedPercent: 40, observedAt: date, resetsAt: date.addingTimeInterval(4 * 86_400))])
        }
        let pool = PoolCoordinator(accounts: [limited("late", back: 9000), limited("soon", back: 1200), limited("later", back: 16_000)],
                                   now: { date }, factory: { _, _ in XCTFail("No session starts on a limited account"); throw BridgeFailure.transport })
        let request = BridgeRequest(model: "claude-haiku", messages: [.init(role: "user", content: .string("Hello"))])
        do {
            for try await _ in try await pool.events(for: request, conversationID: "fixture-limit") {}
            XCTFail("A pool at its limit answered")
        } catch { XCTAssertEqual(error as? BridgeFailure, .poolLimited(date.addingTimeInterval(1200))) }

        // No account that could serve at all is still "no account", not a limit.
        await pool.updateAccounts([PoolAccount(email: "admission@example.invalid", state: .signedOut)])
        do {
            for try await _ in try await pool.events(for: request, conversationID: "fixture-none") {}
            XCTFail("A pool without accounts answered")
        } catch { XCTAssertEqual(error as? BridgeFailure, .unavailable) }
    }
}
