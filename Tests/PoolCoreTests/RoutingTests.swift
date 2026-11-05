import XCTest
@testable import PoolCore

final class RoutingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func window(_ id: String, _ used: Double?, age: TimeInterval = 0,
                        state: QuotaWindowState = .reported, modelFamily: String? = nil) -> QuotaWindow {
        .init(id: id, usedPercent: used, observedAt: now.addingTimeInterval(-age),
              resetsAt: now.addingTimeInterval(3600), state: state, modelFamily: modelFamily)
    }
    private func account(_ email: String = "a•••@gmail.com", plan: String? = "Pro", session: Double? = nil,
                         week: Double? = nil, age: TimeInterval = 0) -> PoolAccount {
        var windows: [QuotaWindow] = []
        if let session { windows.append(window("five_hour", session, age: age)) }
        if let week { windows.append(window("seven_day", week, age: age)) }
        return .init(email: email, plan: plan, state: .ready, windows: windows, createdAt: now)
    }

    /// A real pool (11-05): accounts whose week was used up had their 5-hour limit renewed hours ago, and
    /// counted as full they lifted the plan's 5-hour figure to about half while nothing could be used.
    func testASessionLimitUnderASpentWeekCountsAsNothingLeft() {
        let later = now.addingTimeInterval(3600)
        let spent = PoolAccount(email: "spent@example.invalid", plan: "Pro", state: .limited, windows: [
            .init(id: "five_hour", usedPercent: 0, observedAt: now, resetsAt: now.addingTimeInterval(-60)),
            .init(id: "seven_day", usedPercent: 100, observedAt: now, resetsAt: now.addingTimeInterval(86400))])
        let low = PoolAccount(email: "low@example.invalid", plan: "Pro", state: .ready, windows: [
            .init(id: "five_hour", usedPercent: 90, observedAt: now, resetsAt: now.addingTimeInterval(7200)),
            .init(id: "seven_day", usedPercent: 50, observedAt: now, resetsAt: now.addingTimeInterval(86400))])
        let summary = QuotaPoolSummary.evaluate([spent, low], model: PoolRouting.anyModel, now: later)
        let session = summary.groups.first { $0.windowID == "five_hour" }
        XCTAssertEqual(session?.knownCount, 2, "The spent account still counts")
        XCTAssertEqual(session?.averageRemainingPercent, 5)
        XCTAssertEqual(summary.groups.first { $0.windowID == "seven_day" }?.averageRemainingPercent, 25)
    }

    func testComplementaryExhaustedWindowsDoNotMakeAnAvailablePool() {
        let a = account(session: 0, week: 100)
        let b = account("b•••@gmail.com", session: 100, week: 0)
        XCTAssertTrue(PoolRouting.candidates([a, b], model: "claude-sonnet", now: now).isEmpty)
        let summary = QuotaPoolSummary.evaluate([a, b], model: "claude-sonnet", now: now)
        // Both count. The week left under a spent 5-hour limit is real; 5 hours under a spent week are not.
        XCTAssertEqual(summary.groups.map(\.remainingUnits), [0, 1])
        XCTAssertEqual(summary.groups.map(\.usableNowUnits), [0, 0])
        XCTAssertEqual(summary.usableAccounts, 0)
    }

    func testUltraCanBeAssessedFromReportedWeeklyWindowWithoutInventingSessionLimit() {
        let ultra = account(plan: "Ultra", week: 30)
        XCTAssertEqual(PoolRouting.assessment(ultra, model: "claude-opus", now: now), .init(state: .available, headroom: 70))
        XCTAssertEqual(QuotaPoolSummary.evaluate([ultra], model: "claude-opus", now: now).groups.map(\.windowID), ["seven_day"])
        XCTAssertFalse(ultra.windows.contains { $0.id == "five_hour" })
    }

    func testUltraPlanNameDoesNotEraseReportedTemporarySessionLimit() {
        let ultra = account(plan: "Ultra", session: 100, week: 20)
        XCTAssertEqual(PoolRouting.assessment(ultra, model: "claude-sonnet", now: now).state, .exhausted)
        XCTAssertTrue(PoolRouting.candidates([ultra], model: "claude-sonnet", now: now).isEmpty)
    }

    func testMissingUnknownAndExplicitNotApplicableAreDistinct() {
        var a = account()
        XCTAssertEqual(PoolRouting.assessment(a, model: "sonnet", now: now).state, .unknown)
        XCTAssertTrue(QuotaPoolSummary.evaluate([a], model: "sonnet", now: now).groups.isEmpty)
        a.windows = [window("five_hour", nil)]
        XCTAssertEqual(a.windows[0].state, .unknown)
        XCTAssertEqual(PoolRouting.assessment(a, model: "sonnet", now: now).state, .unknown)
        a.windows = [window("five_hour", nil, state: .notApplicable)]
        XCTAssertEqual(PoolRouting.assessment(a, model: "sonnet", now: now).state, .notApplicable)
        let group = QuotaPoolSummary.evaluate([a], model: "sonnet", now: now).groups[0]
        XCTAssertEqual(group.notApplicableCount, 1)
        XCTAssertNil(group.remainingUnits)
        XCTAssertNil(group.averageRemainingPercent)
    }

    func testNoOfficialEmailMeansNoRoutingIdentity() {
        let pending = PoolAccount(state: .ready, windows: [window("seven_day", 0)])
        XCTAssertTrue(PoolRouting.candidates([pending], model: "sonnet", now: now).isEmpty)
    }

    func testExistingConversationStaysOnUsableAccount() {
        let a = account(session: 70, week: 70)
        let b = account("b•••@gmail.com", session: 10, week: 10)
        XCTAssertEqual(PoolRouting.candidates([a, b], model: "sonnet", preferred: a.id, now: now).first?.id, a.id)
        XCTAssertNil(PoolRouting.handoff([a, b], model: "sonnet", currentID: a.id, now: now))
    }

    func testHeadroomAndOrderedStrategiesSelectDifferentNewAccounts() {
        let a = account(session: 80, week: 70)
        let b = account("b•••@gmail.com", session: 10, week: 10)
        XCTAssertEqual(PoolRouting.candidates([a, b], model: "sonnet", now: now).first?.id, b.id)
        XCTAssertEqual(PoolRouting.candidates([a, b], model: "sonnet", now: now, policy: .init(strategy: .ordered)).first?.id, a.id)
        XCTAssertEqual(PoolRouting.candidates([a, b], model: "sonnet", now: now,
            policy: .init(strategy: .ordered, accountOrder: [b.id, a.id])).first?.id, b.id)
    }

    func testUnknownHeadroomRanksBehindMeasuredHeadroomWithoutBecomingZeroQuota() {
        let unknown = account()
        let known = account("b•••@gmail.com", week: 90)
        XCTAssertEqual(PoolRouting.candidates([unknown, known], model: "sonnet", now: now).map(\.id), [known.id, unknown.id])
        XCTAssertNil(PoolRouting.assessment(unknown, model: "sonnet", now: now).headroom)
    }

    func testStaleExhaustionDoesNotReopenBeforeReset() {
        let a = account(session: 100, week: 20, age: 3600)
        XCTAssertTrue(PoolRouting.candidates([a], model: "sonnet", now: now).isEmpty)
        XCTAssertEqual(a.windows.first?.remaining(at: now), 0)
        XCTAssertFalse(a.windows[0].isFresh(at: now))
    }

    func testDynamicModelWindowsOnlyRestrictTheirModels() {
        var a = account(plan: "Ultra", week: 20)
        a.windows.append(window("seven_day_fable", 100))
        XCTAssertTrue(PoolRouting.candidates([a], model: "claude-fable-5", now: now).isEmpty)
        XCTAssertEqual(PoolRouting.assessment(a, model: "sonnet", now: now).headroom, 80)
        a.windows.append(window("vendor_window", 100, modelFamily: "sonnet"))
        XCTAssertTrue(PoolRouting.candidates([a], model: "sonnet", now: now).isEmpty)
        XCTAssertEqual(PoolRouting.assessment(a, model: "opus", now: now).headroom, 80)
    }

    func testUnknownAdditionalWindowIsNotIgnoredAsUnlimited() {
        var a = account(week: 20)
        a.windows.append(window("monthly_capacity", nil))
        XCTAssertEqual(PoolRouting.assessment(a, model: "opus", now: now).state, .unknown)
        a.windows[1] = window("monthly_capacity", 100)
        XCTAssertTrue(PoolRouting.candidates([a], model: "opus", now: now).isEmpty)
    }

    func testProactiveHandoffRequiresConfirmedCycleHeadroomAndBetterBackup() {
        let current = account(week: 90)
        let healthy = account("b•••@gmail.com", week: 20)
        let result = PoolRouting.handoff([current, healthy], model: "sonnet", currentID: current.id, now: now)
        XCTAssertEqual(result?.account.id, healthy.id)
        XCTAssertEqual(result?.reason, .lowQuota)
        let justAbove = account(week: 89.99)
        XCTAssertNil(PoolRouting.handoff([justAbove, healthy], model: "sonnet", currentID: justAbove.id, now: now))
        var unread = account(week: 95)
        unread.windows[0] = window("seven_day", nil)
        XCTAssertNil(PoolRouting.handoff([unread, healthy], model: "sonnet", currentID: unread.id, now: now))
    }

    func testOrderedHandoffSkipsUnknownAndLowBackupsForProactiveRotation() {
        let current = account(week: 95)
        let unknown = account("b•••@gmail.com")
        let low = account("c•••@gmail.com", week: 92)
        let healthy = account("d•••@gmail.com", week: 50)
        let policy = RoutingPolicy(strategy: .ordered, accountOrder: [unknown.id, low.id, healthy.id, current.id])
        XCTAssertEqual(PoolRouting.handoff([current, unknown, low, healthy], model: "sonnet", currentID: current.id, policy: policy, now: now)?.account.id, healthy.id)
        XCTAssertNil(PoolRouting.handoff([current, unknown, low], model: "sonnet", currentID: current.id, policy: policy, now: now))
    }

    func testExhaustedHandoffUsesFallbackWithoutInventingItsUnknownQuota() {
        let exhausted = account(week: 100)
        let unknown = account("b•••@gmail.com")
        let result = PoolRouting.handoff([exhausted, unknown], model: "sonnet", currentID: exhausted.id, now: now)
        XCTAssertEqual(result?.reason, .quotaExhausted)
        XCTAssertEqual(result?.account.id, unknown.id)
        XCTAssertNil(result?.account.windows.first)
    }

    func testAggregatesOnlyComparablePlansAndKeepsPartialTotalsExplicit() {
        let a = account(week: 20), b = account("b•••@gmail.com", week: 50), unknown = account("c•••@gmail.com")
        let ultra = account("d•••@gmail.com", plan: "Ultra", week: 10)
        let summary = QuotaPoolSummary.evaluate([a, b, unknown, ultra], model: "sonnet", now: now)
        let pro = summary.groups.first { $0.plan == "Pro" }!
        XCTAssertEqual(pro.remainingUnits, 1.3)
        XCTAssertEqual(pro.knownCount, 2)
        XCTAssertEqual(pro.unknownCount, 1)
        // The known accounts' average; the unread one is counted apart until it is read.
        XCTAssertEqual(pro.averageRemainingPercent!, 65, accuracy: 0.0001)
        XCTAssertFalse(pro.isComplete)
        XCTAssertEqual(summary.groups.count, 2)
        XCTAssertEqual(summary.unknownAccounts, 1)
        XCTAssertEqual(summary.usableAccounts, 3)
    }

    func testGenericSeatLabelsAreNotAssumedToHaveEqualCapacity() {
        let a = account(plan: "Team", week: 20), b = account("b•••@gmail.com", plan: "Team", week: 50)
        let summary = QuotaPoolSummary.evaluate([a, b], model: "sonnet", now: now)
        XCTAssertEqual(summary.groups.count, 2)
        XCTAssertTrue(summary.groups.allSatisfy { $0.accountIDs.count == 1 })
    }

    func testDisabledDuplicateDoesNotIncreasePoolQuota() {
        let active = account(week: 50)
        var duplicate = account(week: 50)
        duplicate.state = .disabled
        let summary = QuotaPoolSummary.evaluate([active, duplicate], model: "sonnet", now: now)
        XCTAssertEqual(summary.totalAccounts, 1)
        XCTAssertEqual(summary.groups[0].remainingUnits, 0.5)
        XCTAssertEqual(summary.groups[0].accountIDs, [active.id])
    }

    func testCompleteComparableGroupHasAnAverageAndRecordedEquivalentWindows() {
        let a = account(plan: "Ultra", week: 20), b = account("b•••@gmail.com", plan: "Ultra", week: 60)
        let group = QuotaPoolSummary.evaluate([a, b], model: "sonnet", now: now).groups[0]
        XCTAssertEqual(group.remainingUnits!, 1.2, accuracy: 0.00001)
        XCTAssertEqual(group.averageRemainingPercent!, 60, accuracy: 0.00001)
        XCTAssertTrue(group.isComplete)
    }

    func testPolicyRoundTripAndReserveValidation() throws {
        let policy = RoutingPolicy(strategy: .ordered, accountOrder: [UUID()], reservePercent: 25)
        XCTAssertEqual(try JSONDecoder().decode(RoutingPolicy.self, from: JSONEncoder().encode(policy)), policy)
        for invalid in [-1.0, 25.1] {
            let data = try JSONEncoder().encode(RoutingPolicy(reservePercent: invalid))
            XCTAssertThrowsError(try JSONDecoder().decode(RoutingPolicy.self, from: data))
        }
        XCTAssertEqual(try JSONDecoder().decode(RoutingPolicy.self, from: Data("{\"strategy\":\"ordered\",\"accountOrder\":[]}".utf8)).reservePercent, 10)
    }

    func testPersistedOfficialEmailReplacesCustomAccountNames() throws {
        let original = account()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(PoolAccount.self, from: data)
        XCTAssertEqual(decoded.email, original.email)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("\"name\""))
        let record = RouteDecision(accountID: original.id, model: "sonnet", reason: .lowQuota, strategy: .mostHeadroom)
        let trace = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        XCTAssertFalse(trace.contains("email"))
        XCTAssertFalse(trace.contains(original.email!))
    }

    func testDuplicateIdentityUsesOfficialEmailAndKnownOrganizationScope() {
        var a = account("A•••@gmail.com"), b = account("a•••@gmail.com")
        XCTAssertTrue(a.hasSameIdentity(as: b))
        a.identityFingerprint = String(repeating: "a", count: 64)
        XCTAssertTrue(a.hasSameIdentity(as: b))
        b.identityFingerprint = String(repeating: "b", count: 64)
        XCTAssertFalse(a.hasSameIdentity(as: b))
        b.identityFingerprint = a.identityFingerprint
        XCTAssertTrue(a.hasSameIdentity(as: b))
        b.email = nil
        XCTAssertFalse(a.hasSameIdentity(as: b))
    }

    func testRecoveryWaitsForEveryExhaustedWindowThenChoosesEarliestRecoverableAccount() {
        var a = account(session: 100, week: 100), b = account("b•••@gmail.com", plan: "Ultra", week: 100)
        a.windows[0].resetsAt = now.addingTimeInterval(60)
        a.windows[1].resetsAt = now.addingTimeInterval(7200)
        b.windows[0].resetsAt = now.addingTimeInterval(3600)
        XCTAssertEqual(QuotaRecovery.account(a, model: "sonnet", now: now), .scheduled(now.addingTimeInterval(7200)))
        XCTAssertEqual(QuotaRecovery.pool([a, b], model: "sonnet", now: now).nextRecoveryAt, now.addingTimeInterval(3600))
    }

    func testUnknownBlockerPreventsAConfidentRecoveryTime() {
        var a = account(week: 100)
        a.windows.append(window("monthly_capacity", nil))
        XCTAssertEqual(QuotaRecovery.account(a, model: "sonnet", now: now), .unknown)
        XCTAssertNil(QuotaRecovery.pool([a], model: "sonnet", now: now).nextRecoveryAt)
        a.windows.removeLast()
        a.windows[0].resetsAt = nil
        XCTAssertEqual(QuotaRecovery.account(a, model: "sonnet", now: now), .unknown)
    }

    func testAPassedResetRenewsTheLimitUntilItIsReadAgain() {
        var a = account(plan: "Ultra", week: 100)
        a.state = .limited; a.cooldownUntil = now
        a.windows[0].observedAt = now.addingTimeInterval(-3600); a.windows[0].resetsAt = now
        // Claude restores a limit at its reset: the account is back by itself, before any new reading.
        XCTAssertEqual(a.windows[0].remaining(at: now), 100)
        XCTAssertFalse(a.windows[0].isExhausted(at: now))
        XCTAssertEqual(a.windows[0].recordedRemaining(at: now), 0, "The last reading itself is kept")
        XCTAssertEqual(a.effectiveState(at: now), .ready)
        XCTAssertEqual(a.standing(at: now), .usable)
        XCTAssertEqual(QuotaRecovery.account(a, model: "sonnet", now: now), .available)
        XCTAssertEqual(PoolRouting.candidates([a], model: "sonnet", now: now).map(\.id), [a.id])
        XCTAssertEqual(QuotaPoolSummary.evaluate([a], model: "sonnet", now: now).groups[0].averageRemainingPercent, 100)
        // A second before, it was still held.
        let before = now.addingTimeInterval(-1)
        XCTAssertEqual(a.effectiveState(at: before), .limited)
        XCTAssertEqual(a.standing(at: before), .weekUsed)
        XCTAssertEqual(QuotaRecovery.account(a, model: "sonnet", now: before), .scheduled(now))
    }

    func testInactiveCycleReadingsRetainTheirExactOfficialTimestampUntilReset() {
        let recorded = now.addingTimeInterval(-7200)
        let reset = now.addingTimeInterval(7200)
        let reading = QuotaWindow(id: "seven_day", usedPercent: 35, observedAt: recorded, resetsAt: reset)
        let a = PoolAccount(email: "a•••@gmail.com", plan: "Ultra", state: .ready, windows: [reading])
        XCTAssertFalse(reading.isFresh(at: now))
        XCTAssertEqual(PoolRouting.assessment(a, model: "sonnet", now: now), .init(state: .available, headroom: 65))
        XCTAssertEqual(a.windows[0].observedAt, recorded)
        XCTAssertEqual(a.windows[0].resetsAt, reset)
        XCTAssertEqual(QuotaPoolSummary.evaluate([a], model: "sonnet", now: now).groups[0].remainingUnits, 0.65)
        XCTAssertEqual(reading.remaining(at: reset), 100, "At its reset the limit is full again")
        XCTAssertEqual(reading.recordedRemaining(at: reset), 65)
        XCTAssertEqual(QuotaRecovery.account(a, model: "sonnet", now: reset), .available)
    }

    func testAnUnusedSessionIsFullAndTheWeekStillDecides() {
        let recorded = now.addingTimeInterval(-7200)
        let session = QuotaWindow(id: "five_hour", usedPercent: 0, observedAt: recorded)
        var a = PoolAccount(email: "a•••@gmail.com", plan: "Pro", state: .ready,
                            windows: [session, window("seven_day", 25, age: 7200)])
        // No session is running: one starts with the next request, with all of it there.
        XCTAssertTrue(session.waitsForFirstUse(at: now))
        XCTAssertEqual(session.remaining(at: now), 100)
        XCTAssertEqual(PoolRouting.assessment(a, model: "sonnet", now: now).headroom, 75)
        a.windows[1].usedPercent = 100
        XCTAssertEqual(PoolRouting.assessment(a, model: "sonnet", now: now).state, .exhausted)
        XCTAssertEqual(a.standing(at: now), .weekUsed)
        // A running session has a reset time; zero use within it is not waiting for first use.
        let running = QuotaWindow(id: "five_hour", usedPercent: 0, observedAt: now, resetsAt: now.addingTimeInterval(3600))
        XCTAssertFalse(running.waitsForFirstUse(at: now))
    }

    func testACycleEndsWithinItsSpanEvenWithoutAStatedReset() {
        let session = QuotaWindow(id: "five_hour", usedPercent: 100, observedAt: now.addingTimeInterval(-5 * 3600 + 1))
        XCTAssertTrue(session.isExhausted(at: now))
        XCTAssertFalse(session.isExhausted(at: now.addingTimeInterval(1)), "At the latest a full cycle after the reading, it is back")
        XCTAssertEqual(session.remaining(at: now.addingTimeInterval(1)), 100)
        let a = PoolAccount(email: "a•••@gmail.com", plan: "Pro", state: .ready, windows: [session])
        XCTAssertEqual(QuotaRecovery.account(a, model: "sonnet", now: now), .unknown, "Without a stated reset no time is shown")
    }

    func testEveryAccountCountsAndOnlyThoseInRotationAreReadByThemselves() {
        let a = account(session: 20, week: 40)
        var weekUsed = account("b•••@gmail.com", session: 0, week: 100)
        weekUsed.state = .limited
        var held = account("c•••@gmail.com", session: 0, week: 0)
        held.state = .suspended
        let summary = QuotaPoolSummary.evaluate([a, weekUsed, held], model: PoolRouting.anyModel, now: now)
        let week = summary.groups.first { $0.windowID == "seven_day" }!
        XCTAssertEqual(week.averageRemainingPercent!, 160.0 / 3, accuracy: 0.001, "Used-up and held accounts count too")
        XCTAssertEqual(week.accountIDs.count, 3)
        XCTAssertEqual(weekUsed.standing(at: now), .weekUsed)
        XCTAssertEqual(held.standing(at: now), .unavailable)
        XCTAssertTrue(a.isInRotation(at: now))
        XCTAssertFalse(weekUsed.isInRotation(at: now), "A used-up week is not read until its reset")
        XCTAssertFalse(held.isInRotation(at: now), "An unusable account is not read until it is fixed")
        XCTAssertTrue(PoolRouting.candidates([held], model: "sonnet", now: now).isEmpty, "A held account is not used until it is checked again")
        // At the weekly reset the account is back in rotation by itself.
        let later = now.addingTimeInterval(3601)
        XCTAssertEqual(weekUsed.standing(at: later), .usable)
        XCTAssertTrue(weekUsed.isInRotation(at: later))
    }

    func testAccountsRankUsableFirstThenUnreadThenSoonestBackThenUnusable() {
        let low = account("{{EMAIL_tzwtqgad}}", session: 80, week: 10)
        let high = account("{{EMAIL_whlbyowf}}", session: 10, week: 10)
        let unread = account("{{EMAIL_yyfzvrc5}}")
        var soon = account("{{EMAIL_pvn5usjf}}", session: 100, week: 10)
        soon.windows[0].resetsAt = now.addingTimeInterval(600)
        let later = account("{{EMAIL_wk11vsss}}", session: 100, week: 10)
        let weekUsed = account("{{EMAIL_cfwurx73}}", session: 0, week: 100)
        var signedOut = account("{{EMAIL_bzbaq7ca}}", session: 0, week: 0)
        signedOut.state = .signedOut
        let ranked = AccountOrdering.ranked([signedOut, weekUsed, later, soon, unread, low, high], now: now)
        XCTAssertEqual(ranked.compactMap(\.email), ["{{EMAIL_whlbyowf}}", "{{EMAIL_tzwtqgad}}", "{{EMAIL_yyfzvrc5}}", "{{EMAIL_pvn5usjf}}",
                                                    "{{EMAIL_wk11vsss}}", "{{EMAIL_cfwurx73}}", "{{EMAIL_bzbaq7ca}}"])
    }

    func testExplicitNotApplicableIsRetainedWithoutInventingASessionReset() {
        let absence = QuotaWindow(id: "five_hour", observedAt: now.addingTimeInterval(-86400), state: .notApplicable)
        let a = PoolAccount(email: "a•••@gmail.com", plan: "Ultra", state: .ready,
                            windows: [absence, window("seven_day", 25, age: 86400)])
        XCTAssertTrue(absence.isNotApplicable(at: now))
        XCTAssertNil(absence.resetsAt)
        XCTAssertEqual(PoolRouting.assessment(a, model: "sonnet", now: now).headroom, 75)
        XCTAssertEqual(QuotaPoolSummary.evaluate([a], model: "sonnet", now: now).groups.first { $0.windowID == "five_hour" }?.notApplicableCount, 1)
    }

    func testRefreshDefaultsAndPersistedIntervalsRoundTrip() throws {
        let defaults = QuotaRefreshPreferences()
        XCTAssertEqual(defaults.quietInterval, 300)
        XCTAssertEqual(defaults.interactiveInterval, 120)
        XCTAssertEqual(defaults.burstInterval, 10)
        XCTAssertTrue(defaults.confirmAfterReset)
        let oldPreferences = Data("{\"port\":18473,\"language\":\"en\"}".utf8)
        XCTAssertEqual(try JSONDecoder().decode(PoolPreferences.self, from: oldPreferences).quotaRefresh, defaults)
        let configured = QuotaRefreshPreferences(quietInterval: 600, interactiveInterval: 240, generatingInterval: 180, concurrentInterval: 150, burstInterval: 120,
                                                confirmAfterReset: false)
        let preferences = PoolPreferences(quotaRefresh: configured)
        XCTAssertEqual(try JSONDecoder().decode(PoolPreferences.self, from: JSONEncoder().encode(preferences)), preferences)
        for invalid in [QuotaRefreshPreferences(burstInterval: 9), .init(quietInterval: 601), .init(burstInterval: 21), .init(quietInterval: 90)] {
            XCTAssertFalse(invalid.isValid)
            XCTAssertThrowsError(try JSONDecoder().decode(QuotaRefreshPreferences.self, from: JSONEncoder().encode(invalid)))
        }
    }

    func testSignedInFreeAccountHasIdentityButCannotServeSubscriptionRequests() {
        let free = PoolAccount(email: "a•••@gmail.com", plan: "Free", state: .subscriptionRequired)
        XCTAssertNotNil(free.email)
        XCTAssertEqual(free.plan, "Free")
        XCTAssertTrue(PoolRouting.candidates([free], model: "sonnet", now: now).isEmpty)
        XCTAssertEqual(QuotaRecovery.account(free, model: "sonnet", now: now), .unavailable)
    }

    func testModelSpecificRecoveryAndCooldownKeepTheirOwnBottlenecks() {
        var a = account(plan: "Ultra", week: 40)
        a.windows.append(window("seven_day_fable", 100))
        XCTAssertEqual(QuotaRecovery.account(a, model: "sonnet", now: now), .available)
        XCTAssertEqual(QuotaRecovery.account(a, model: "fable", now: now), .scheduled(now.addingTimeInterval(3600)))
        a.cooldownUntil = now.addingTimeInterval(7200)
        XCTAssertEqual(QuotaRecovery.account(a, model: "fable", now: now), .scheduled(now.addingTimeInterval(7200)))
    }

    func testInvalidObservationsRemainUnknownAndElapsedOnesRenew() {
        for used in [-1.0, 101, .infinity, .nan] { XCTAssertNil(window("five_hour", used).remaining(at: now)) }
        XCTAssertEqual(QuotaWindow(id: "five_hour", usedPercent: 20, observedAt: now, resetsAt: now).remaining(at: now), 100)
        XCTAssertNil(QuotaWindow(id: "five_hour", usedPercent: 20, observedAt: now.addingTimeInterval(1)).remaining(at: now))
    }
}
