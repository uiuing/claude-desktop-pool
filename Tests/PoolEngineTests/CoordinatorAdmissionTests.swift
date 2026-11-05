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
}
