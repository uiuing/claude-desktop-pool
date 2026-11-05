import XCTest
@testable import PoolCore

final class AccountScopeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testQueuedQuotaFromPreviousPlanCannotRefillClearedWindowsEvenWithNewerTimestamp() {
        let original = account()
        let scope = AccountScope(original)
        let delayed = QuotaWindow(id: "five_hour", usedPercent: 80, observedAt: now.addingTimeInterval(60),
                                  resetsAt: now.addingTimeInterval(3_600))
        let queuedObservation: (inout [PoolAccount]) -> Bool = { accounts in
            scope.applyObservation(to: &accounts) { $0.windows = [delayed]; $0.state = .limited }
        }
        var current = [original]
        current[0].plan = "Ultra"
        current[0].windows = []
        current[0].cooldownUntil = nil

        XCTAssertFalse(queuedObservation(&current))
        XCTAssertEqual(current[0].plan, "Ultra")
        XCTAssertEqual(current[0].state, .ready)
        XCTAssertTrue(current[0].windows.isEmpty)
        XCTAssertNil(current[0].cooldownUntil)
    }

    func testQueuedAuthenticationFailureCannotAffectDifferentEmailOrOrganization() {
        let original = account()
        let scope = AccountScope(original)
        var changedEmail = original; changedEmail.email = "b•••@gmail.com"
        var changedOrganization = original; changedOrganization.identityFingerprint = "fixture-scope-b"
        for replacement in [changedEmail, changedOrganization] {
            var current = [replacement]
            XCTAssertFalse(scope.applyObservation(to: &current) { $0.state = .signedOut })
            XCTAssertEqual(current, [replacement])
        }
    }

    func testSameScopeObservationUsesNormalizedEmailAndCurrentAccountValue() {
        let original = account()
        let scope = AccountScope(original)
        var current = [original]
        current[0].email = "A•••@GMAIL.COM"
        current[0].state = .limited
        let measured = QuotaWindow(id: "seven_day", usedPercent: 20, observedAt: now,
                                   resetsAt: now.addingTimeInterval(86_400))

        XCTAssertTrue(scope.applyObservation(to: &current) { $0.windows = [measured]; $0.state = .ready })
        XCTAssertEqual(current[0].email, "A•••@GMAIL.COM")
        XCTAssertEqual(current[0].windows, [measured])
        XCTAssertEqual(current[0].state, .ready)
    }

    func testQueuedWorkerCannotReenableQuiescedSignedOutOrUnsubscribedAccount() {
        let original = account()
        let scope = AccountScope(original)
        for state: AccountState in [.disabled, .signedOut, .subscriptionRequired] {
            var current = [original]; current[0].state = state
            XCTAssertFalse(scope.applyObservation(to: &current) { $0.state = .ready })
            XCTAssertEqual(current[0].state, state)
        }
    }

    func testRemovedAccountCannotBeRecreatedByDelayedObservation() {
        let scope = AccountScope(account())
        var current: [PoolAccount] = []
        XCTAssertFalse(scope.applyObservation(to: &current) { $0.state = .limited })
        XCTAssertTrue(current.isEmpty)
    }

    private func account() -> PoolAccount {
        .init(id: UUID(uuidString: "0a1b2c3d-1111-4aaa-8bbb-000000000001")!, email: "a•••@gmail.com",
              identityFingerprint: "fixture-scope-a", plan: "Pro", state: .ready, createdAt: now)
    }
}
