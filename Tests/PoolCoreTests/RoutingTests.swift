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

    /// A real pool (11-06): the account with 3 conversations and the lowest of its two figures
    /// highest kept taking new ones, while one with 94% of its week and 57% of its 5-hour limit waited.
    func testNewConversationsWeighBothLimitsTheirResetsAndLoad() {
        func pool(_ email: String, session: Double, sessionReset: TimeInterval, week: Double, weekReset: TimeInterval) -> PoolAccount {
            .init(email: email, plan: "Pro", state: .ready, windows: [
                .init(id: "five_hour", usedPercent: 100 - session, observedAt: now, resetsAt: now.addingTimeInterval(sessionReset)),
                .init(id: "seven_day", usedPercent: 100 - week, observedAt: now, resetsAt: now.addingTimeInterval(weekReset))], createdAt: now)
        }
        let busy = pool("u@example.com", session: 60, sessionReset: 4800, week: 65, weekReset: 6 * 86400)
        let roomy = pool("m@example.com", session: 57, sessionReset: 10_000, week: 94, weekReset: 7 * 86400)
        let fresh = pool("g@example.com", session: 100, sessionReset: 3000, week: 58, weekReset: 2 * 86400)
        let ranked = PoolRouting.candidates([busy, roomy, fresh], model: "sonnet", now: now, load: [busy.id: 3]).map(\.email)
        XCTAssertEqual(ranked.last, "u@example.com", "Three conversations already on it weigh against it")
        XCTAssertNotEqual(ranked.first, "u@example.com")
        // The week does not override the 5-hour limit: an almost spent 5-hour limit is not chosen
        // over a full one just for a larger week.
        let spentSession = pool("w@example.com", session: 15, sessionReset: 4 * 3600, week: 95, weekReset: 6 * 86400)
        let fullSession = pool("s@example.com", session: 100, sessionReset: 3600, week: 60, weekReset: 6 * 86400)
        XCTAssertEqual(PoolRouting.candidates([spentSession, fullSession], model: "sonnet", now: now).first?.email, "s@example.com")
    }

    /// Pool's own: a warm prompt cache is one more weight. It turns a near tie toward the account
    /// that holds the request's instructions and tools, never one that clearly has less left.
    func testAWarmCacheTurnsANearTieButNotAClearlyRoomierAccount() {
        let warm = account("warm@example.com", session: 50, week: 50)
        let close = account("close@example.com", session: 48, week: 48)
        let roomy = account("roomy@example.com", session: 20, week: 20)
        XCTAssertEqual(PoolRouting.candidates([warm, close], model: "sonnet", now: now).first?.id, close.id)
        let points = PoolRouting.warmBonus(tokens: 25_000)
        XCTAssertEqual(points, 5)
        XCTAssertEqual(PoolRouting.candidates([warm, close], model: "sonnet", now: now, bonus: [warm.id: points]).first?.id, warm.id)
        XCTAssertEqual(PoolRouting.candidates([warm, roomy], model: "sonnet", now: now, bonus: [warm.id: points]).first?.id, roomy.id)
        XCTAssertEqual(PoolRouting.warmBonus(tokens: 2_000), 0.4, accuracy: 0.001, "A small prefix is worth little")
        XCTAssertEqual(PoolRouting.warmBonus(tokens: 400_000), PoolRouting.warmMost)
    }

    func testAFullFiveHoursDoesNotHideAWeekThatIsNearlyGone() {
        func pool(_ email: String, session: Double, sessionReset: TimeInterval, week: Double, weekReset: TimeInterval) -> PoolAccount {
            .init(email: email, plan: "Pro", state: .ready, windows: [
                .init(id: "five_hour", usedPercent: 100 - session, observedAt: now, resetsAt: now.addingTimeInterval(sessionReset)),
                .init(id: "seven_day", usedPercent: 100 - week, observedAt: now, resetsAt: now.addingTimeInterval(weekReset))], createdAt: now)
        }
        // As the menu showed them: four accounts with full 5 hours and 2–5% of the week left, and one
        // with a conversation, 11% of its 5 hours (renewing within the hour) and 80% of its week.
        let nearlyGone = [
            pool("a@example.com", session: 100, sessionReset: 4 * 3600, week: 5, weekReset: 5 * 86400),
            pool("b@example.com", session: 100, sessionReset: 3 * 3600, week: 3, weekReset: 3 * 86400),
            pool("c@example.com", session: 100, sessionReset: 4 * 3600, week: 3, weekReset: 3 * 86400),
            pool("d@example.com", session: 100, sessionReset: 4 * 3600, week: 2, weekReset: 4 * 86400)]
        let working = pool("e@example.com", session: 11, sessionReset: 3600, week: 80, weekReset: 6 * 86400)
        let ranked = PoolRouting.candidates(nearlyGone + [working], model: "sonnet", now: now, load: [working.id: 1])
        XCTAssertEqual(ranked.first?.email, "e@example.com")
        XCTAssertEqual(ranked.dropFirst().map(\.email), ["a@example.com", "b@example.com", "c@example.com", "d@example.com"])
        // Above the cap the week does not decide: a full 5 hours with 60% of the week still beats 15% with 95%.
        let healthy = pool("f@example.com", session: 100, sessionReset: 3600, week: 30, weekReset: 6 * 86400)
        let spent = pool("g@example.com", session: 15, sessionReset: 4 * 3600, week: 95, weekReset: 6 * 86400)
        XCTAssertEqual(PoolRouting.candidates([spent, healthy], model: "sonnet", now: now).first?.email, "f@example.com")
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

    /// Claude refused the account at its 5-hour limit while its usage panel still showed some left:
    /// that limit has none until its reset, the week is untouched, and after the reset it is read again.
    func testALimitClaudeRefusedAtHasNoneLeftUntilItsReset() {
        let reset = now.addingTimeInterval(3600)
        var a = account(session: 81, week: 50)
        a.windows[0].resetsAt = reset; a.windows[1].resetsAt = now.addingTimeInterval(86400 * 3)
        XCTAssertFalse(a.isRefused(a.windows[0], at: now))
        a.state = .limited; a.cooldownUntil = reset
        XCTAssertTrue(a.isRefused(a.windows[0], at: now))
        XCTAssertFalse(a.isRefused(a.windows[1], at: now), "Only the limit it was refused at")
        XCTAssertEqual(a.standing(at: now), .limited)
        XCTAssertFalse(a.isRefused(a.windows[0], at: reset), "Not past its reset")
        a.windows[0].usedPercent = 100
        XCTAssertFalse(a.isRefused(a.windows[0], at: now), "A used-up reading already says so")
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

    /// A real pool (11-07): 100/50 with its week resetting in 20 hours ranked below 86/96, 100/61 and
    /// 100/54 whose weeks had days to go. Half a week that comes back tomorrow is spent first.
    func testAWeekResettingTomorrowIsSpentBeforeWeeksWithDaysToGo() {
        func pool(_ email: String, _ session: Double, _ week: Double, weekResetIn: TimeInterval) -> PoolAccount {
            .init(email: email, plan: "Max", state: .ready, windows: [
                .init(id: "five_hour", usedPercent: 100 - session, observedAt: now, resetsAt: now.addingTimeInterval(4.8 * 3600)),
                .init(id: "seven_day", usedPercent: 100 - week, observedAt: now, resetsAt: now.addingTimeInterval(weekResetIn)),
            ], createdAt: now)
        }
        let fresh = pool("a•••@gmail.com", 86, 96, weekResetIn: 7 * 86400 - 3600)
        let tomorrow = pool("b•••@gmail.com", 100, 50, weekResetIn: 20 * 3600)
        let midWeek = pool("c•••@gmail.com", 100, 61, weekResetIn: 5.7 * 86400)
        let earlier = pool("busy@example.com", 100, 54, weekResetIn: 4.4 * 86400)
        let accounts = [fresh, midWeek, earlier, tomorrow]
        XCTAssertEqual(AccountOrdering.ranked(accounts, now: now).first?.id, tomorrow.id, "Even with no conversation on the fresh week")
        XCTAssertEqual(AccountOrdering.ranked(accounts, now: now, load: [fresh.id: 1]).first?.id, tomorrow.id)
        // The week's used share counts as back only near its reset; a week with days to go is read as it is.
        XCTAssertEqual(AccountOrdering.ranked([earlier, midWeek], now: now).first?.id, midWeek.id)
    }

    /// A real pool (11-06): a conversation's new run started while the run it replaced wound down, so
    /// its account counted two conversations for five minutes and sank below accounts with far less week.
    func testAConversationCountsOnceWhileItsRunsOverlap() {
        let busy = account("busy@example.com", session: 54, week: 12)
        let spentWeek = account("spent-week@example.com", session: 0, week: 95)
        let replaced = PoolSession(accountID: busy.id, name: "a", model: "opus", state: .idle, conversation: "9b783dc39a06f580")
        let current = PoolSession(accountID: busy.id, name: "b", model: "opus", state: .running, conversation: "9b783dc39a06f580")
        let title = PoolSession(accountID: busy.id, name: "c", model: "haiku", state: .running, conversation: "9b783dc39a06f580", isOneOff: true)
        let ended = PoolSession(accountID: spentWeek.id, name: "d", model: "opus", state: .ended, conversation: "2510c47caead5add")
        let unnamed = PoolSession(accountID: spentWeek.id, name: "e", model: "opus", state: .running)
        let load = PoolRouting.conversationLoad([replaced, current, title, ended, unnamed])
        XCTAssertEqual(load[busy.id], 1, "Two live runs of one conversation are one conversation; a one-off ask is none")
        XCTAssertEqual(load[spentWeek.id], 1, "An ended run does not count; a run with no conversation counts alone")
        let ranked = AccountOrdering.ranked([spentWeek, busy], now: now, load: [busy.id: 1])
        XCTAssertEqual(ranked.first?.id, busy.id, "46/88 with one conversation leads 100/5")
    }

    /// A real pool (11-06): 100/3, 100/2 and 100/3 within half a point of each other were taken as equal
    /// and kept their saved order, so 2% of the week sat between two accounts with 3%.
    func testCloseScoresStillOrderByScore() {
        let first = account("first@example.com", session: 0, week: 97)
        let least = account("least@example.com", session: 0, week: 98)
        let second = account("second@example.com", session: 0, week: 97)
        let ranked = AccountOrdering.ranked([first, least, second], now: now)
        XCTAssertEqual(ranked.map(\.id), [first.id, second.id, least.id])
        XCTAssertEqual(PoolRouting.candidates([least, first], model: PoolRouting.anyModel, now: now).first?.id, first.id)
    }

    func testUsableAccountsListInTheOrderRoutingGivesNewConversations() {
        // Remaining 54/94 with a conversation, 52/64, 97/51 with a conversation, 100/41: the smaller
        // figure alone ranks them in that order, while routing weighs both limits and each conversation.
        let busyHigh = account("busy-high@example.com", session: 46, week: 6)
        let middle = account("middle@example.com", session: 48, week: 36)
        let busyFresh = account("busy-fresh@example.com", session: 3, week: 49)
        let fresh = account("fresh@example.com", session: 0, week: 59)
        let accounts = [busyHigh, middle, busyFresh, fresh]
        let load = [busyHigh.id: 1, busyFresh.id: 1]
        let routed = PoolRouting.candidates(accounts, model: PoolRouting.anyModel, now: now, load: load)
        let ranked = AccountOrdering.ranked(accounts, now: now, load: load)
        XCTAssertEqual(ranked.map(\.id), routed.map(\.id), "The list shows usable accounts in routing order")
        XCTAssertEqual(ranked.first?.id, routed.first?.id, "The first account listed is where a new conversation goes")
        let bySmallerFigure = accounts.sorted {
            (PoolRouting.assessment($0, model: PoolRouting.anyModel, now: now).headroom ?? -1) >
                (PoolRouting.assessment($1, model: PoolRouting.anyModel, now: now).headroom ?? -1)
        }
        XCTAssertNotEqual(ranked.map(\.id), bySmallerFigure.map(\.id), "These accounts are ordered differently by the smaller figure alone")
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
