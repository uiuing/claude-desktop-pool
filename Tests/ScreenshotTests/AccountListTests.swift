import XCTest
import PoolCore
@testable import ClaudePool

@MainActor
final class AccountListTests: XCTestCase {
    func testDefaultOrderAndExpiryWithUndatedAccountsAndTies() {
        let model = PoolAppModel.showcaseModel()
        let ranked = model.rankedAccounts
        XCTAssertEqual(model.listedAccounts, ranked)

        let expired = model.snapshot.accounts[6]
        let soon = model.snapshot.accounts[1]
        let later = model.snapshot.accounts[4]
        model.snapshot.accounts[0].expiresAt = later.expiresAt
        let tied = model.rankedAccounts.filter { $0.expiresAt == later.expiresAt }.map(\.id)
        let undated = ranked.filter { $0.expiresAt == nil && $0.id != model.snapshot.accounts[0].id }.map(\.id)

        model.accountListOrder = .expirySoonest
        XCTAssertEqual(model.listedAccounts.map(\.id), [expired.id, soon.id] + tied + undated)
        model.accountListOrder = .expiryLatest
        XCTAssertEqual(model.listedAccounts.map(\.id), tied + [soon.id, expired.id] + undated)
        model.accountListFilters.expiry = .expired
        XCTAssertEqual(model.listedAccounts.map(\.id), [expired.id])
        model.accountListFilters.expiry = .unset
        XCTAssertEqual(model.listedAccounts.map(\.id), undated)
    }

    func testQuotaOrdersUseTheSelectedWindowAndRespectRefusalsAndResets() {
        let model = PoolAppModel.demoModel()
        let now = model.now
        let future = now.addingTimeInterval(900)
        let weekReset = now.addingTimeInterval(86_400)
        let observed = now.addingTimeInterval(-1000)
        let refused = PoolAccount(email: "refused@example.com", state: .limited, windows: [
            .init(id: "five_hour", usedPercent: 90, observedAt: observed, resetsAt: future),
            .init(id: "seven_day", usedPercent: 10, observedAt: observed, resetsAt: weekReset)
        ], cooldownUntil: future)
        let renewed = PoolAccount(email: "renewed@example.com", state: .ready, windows: [
            .init(id: "five_hour", usedPercent: 100, observedAt: observed, resetsAt: now),
            .init(id: "seven_day", usedPercent: 80, observedAt: observed, resetsAt: weekReset)
        ])
        let unread = PoolAccount(email: "unread@example.com", state: .ready, windows: [
            .init(id: "five_hour", observedAt: observed),
            .init(id: "seven_day", observedAt: observed, state: .notApplicable)
        ])
        model.snapshot.accounts = [unread, refused, renewed]
        for (order, expected): (AccountListOrder, [UUID]) in [
            (.sessionMost, [renewed.id, refused.id, unread.id]),
            (.sessionLeast, [refused.id, renewed.id, unread.id]),
            (.weekMost, [refused.id, renewed.id, unread.id]),
            (.weekLeast, [renewed.id, refused.id, unread.id])
        ] {
            model.accountListOrder = order
            XCTAssertEqual(model.listedAccounts.map(\.id), expected, order.rawValue)
        }
        XCTAssertTrue(model.accountListPlanOptions.contains(.plan(nil)))
    }

    func testSearchRespectsEmailMasking() {
        let model = PoolAppModel.showcaseModel()
        model.preferences.maskEmail = true
        model.accountListFilters.search = "blake"
        XCTAssertTrue(model.listedAccounts.isEmpty)
        model.accountListFilters.search = model.displayEmail("blake@example.org")
        XCTAssertEqual(model.listedAccounts.map(\.email), ["blake@example.org"])
    }
}
