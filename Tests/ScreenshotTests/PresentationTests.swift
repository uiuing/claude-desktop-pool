import XCTest
import PoolCore
@testable import ClaudePool

@MainActor
final class PresentationTests: XCTestCase {
    func testUnknownQuotaIsNotZeroAndAReadingHoldsForItsCycle() {
        let model = PoolAppModel.demoModel()
        var account = model.snapshot.accounts[0]
        account.windows = []
        XCTAssertEqual(model.quotaText(account, window: "five_hour"), "—")
        XCTAssertEqual(model.resetText(account, window: "five_hour"), "Not reported yet")
        // Without a stated reset a reading holds for its cycle, and the limit is full once a cycle has passed.
        account.windows = [.init(id: "five_hour", usedPercent: 35, observedAt: model.now.addingTimeInterval(-601))]
        XCTAssertEqual(model.quotaText(account, window: "five_hour"), "65%")
        account.windows[0].observedAt = model.now.addingTimeInterval(-5 * 3600)
        XCTAssertEqual(model.quotaText(account, window: "five_hour"), "100%")
        account.windows[0].observedAt = model.now
        account.windows[0].usedPercent = 100
        XCTAssertEqual(model.quotaText(account, window: "five_hour"), "0%")
    }

    func testPoolReadinessHonorsAccountLimits() {
        let model = PoolAppModel.demoModel()
        XCTAssertEqual(model.readyAccounts.count, 3)
        XCTAssertEqual(model.snapshot.accounts.count, 4)
        XCTAssertEqual(model.activeSessions.count, 2)
        // Readiness is never filtered by one model, and the next account is one not already in use.
        XCTAssertEqual(model.nextAccount?.id, model.snapshot.accounts[3].id)
        XCTAssertEqual(model.menuBarPlan?.id, "plan:Max 5x")
        // The 5-hour limit over the weekly one: what the plan's accounts have left on average. One
        // account's 5-hour limit came back at its reset and counts as full.
        XCTAssertEqual(model.menuBarFigures, MenuBarFigures(session: 79, week: 70))
        model.perform(.menuBarPlan("plan:Pro"))
        XCTAssertEqual(model.menuBarPlan?.id, "plan:Pro")
        XCTAssertEqual(model.menuBarFigures, MenuBarFigures(session: 0, week: 39), "A plan at its 5-hour limit shows none left there, and its week")
    }

    func testWeeklyExhaustionIsExplainedAndCountedUntilReset() {
        let model = PoolAppModel.demoModel()
        let index = 3
        model.snapshot.accounts[index].windows[1].usedPercent = 100
        let account = model.snapshot.accounts[index]
        XCTAssertFalse(model.readyAccounts.contains { $0.id == account.id })
        XCTAssertEqual(account.standing(at: model.now), .weekUsed)
        XCTAssertTrue(model.accountStatus(account).hasPrefix("Week used up"), model.accountStatus(account))
        XCTAssertEqual(model.menuBarFigures, MenuBarFigures(session: 29, week: 39), "The account whose week is used up still counts, with none of its week left and so none of its 5 hours")
        let plan = model.menuBarPlan!
        XCTAssertEqual(plan.limitedCount, 1)
        XCTAssertEqual(plan.usableCount + plan.limitedCount + plan.unreadCount + plan.unavailableCount, plan.accountIDs.count,
                       "The breakdown adds up to every account in the plan")
        XCTAssertEqual(model.rankedAccounts.last?.id, account.id, "It sinks below every account that can still be used")
        model.referenceDate = model.now.addingTimeInterval(172801)
        XCTAssertEqual(account.standing(at: model.now), .usable, "At its weekly reset it is back by itself")
    }

    func testANewReadingShowsAtOnceBetweenClockTicks() {
        // The menu's clock moves once a minute, so a reading usually arrives between its ticks.
        let reading = { (used: Double, at: Date) in
            PoolAccount(id: UUID(uuidString: "0a1b2c3d-1111-4aaa-8bbb-000000000009")!, plan: "Max 5x", state: .ready, windows: [
                .init(id: "five_hour", usedPercent: used, observedAt: at, resetsAt: at.addingTimeInterval(3600))])
        }
        let other = PoolAccount(plan: "Max 5x", state: .ready, windows: [
            .init(id: "five_hour", usedPercent: 60, observedAt: .distantPast.addingTimeInterval(1), resetsAt: .distantFuture)])
        let model = PoolAppModel()
        model.snapshot.accounts = [reading(20, Date().addingTimeInterval(-60)), other]
        XCTAssertEqual(model.remaining(model.snapshot.accounts[0], window: "five_hour"), 80)
        Thread.sleep(forTimeInterval: 0.01)
        model.snapshot.accounts[0] = reading(30, Date())
        XCTAssertEqual(model.remaining(model.snapshot.accounts[0], window: "five_hour"), 70, "It goes straight to the new value")
        XCTAssertEqual(model.quotaSummary.groups.first?.knownCount, 2, "The refreshed account stays in the plan's average")
        XCTAssertEqual(model.quotaSummary.groups.first?.averageRemainingPercent, 55)
    }

    func testProductionActionsDoNotPretendToSucceedWithoutAService() {
        let model = PoolAppModel()
        model.perform(.installRuntime)
        model.perform(.connectDesktop)
        XCTAssertFalse(model.snapshot.executableReady)
        XCTAssertEqual(model.snapshot.desktop, .disconnected)
        XCTAssertEqual(model.snapshot.mode, .stopped)
        var actions: [UIAction] = []
        model.onAction = { actions.append($0) }
        model.perform(.addAccount)
        model.perform(.sendTerminalInput("yes"))
        model.perform(.sendTerminalKey("\r"))
        XCTAssertEqual(actions, [.addAccount, .sendTerminalInput("yes"), .sendTerminalKey("\r")])
        XCTAssertTrue(model.snapshot.accounts.isEmpty)
    }

    func testUnknownQuotaIsNotCountedAsConfirmedReady() {
        let model = PoolAppModel.demoModel()
        model.snapshot.accounts[0].windows[0].state = .unknown
        XCTAssertEqual(model.confirmedReadyCount, 2)
        XCTAssertEqual(model.readyAccounts.count, 3)
    }

    func testExhaustionDoesNotRestartOnboarding() {
        let model = PoolAppModel.demoModel()
        for index in model.snapshot.accounts.indices {
            model.snapshot.accounts[index].state = .limited
            model.snapshot.accounts[index].cooldownUntil = model.now.addingTimeInterval(3600)
        }
        XCTAssertTrue(model.setupComplete)
        XCTAssertTrue(model.readyAccounts.isEmpty)
        XCTAssertNil(model.nextAccount)
        XCTAssertTrue(model.newConversationText.hasPrefix("No account for new conversations"))
    }

    func testLanguageChangesKeepIndexedArguments() {
        let model = PoolAppModel.demoModel(language: "zh-Hans")
        XCTAssertNotEqual(model.t("Accounts"), "Accounts")
        XCTAssertTrue(model.t("Remove {0}?", "Studio").contains("Studio"))
        XCTAssertFalse(model.t("Remove {0}?", "Studio").contains("{0}"))
        model.perform(.language("en"))
        XCTAssertEqual(model.t("Accounts"), "Accounts")
    }

    func testInterruptedDemoSessionRemainsOpenUntilExitIsRequested() {
        let model = PoolAppModel.demoModel()
        let id = model.snapshot.sessions[0].id
        model.perform(.cancelSession(id))
        XCTAssertEqual(model.snapshot.sessions[0].state, .attention)
        model.perform(.requestSessionExit(id))
        XCTAssertEqual(model.snapshot.sessions[0].state, .ended)
        XCTAssertNil(model.terminal)
    }

    func testWeeklyOnlyAccountDoesNotGetInventedSessionQuota() {
        let model = PoolAppModel.demoModel()
        let account = model.snapshot.accounts[0]
        XCTAssertEqual(account.plan, "Ultra")
        XCTAssertEqual(model.displayedWindows(account).map(\.id), ["seven_day"])
        XCTAssertFalse(model.quotaSummary.groups.contains { $0.plan == "Ultra" && $0.windowID == "five_hour" })
        XCTAssertEqual(model.accountName(account.id), account.email)
    }

    func testNotApplicableAndUnknownQuotaRemainDistinct() {
        let model = PoolAppModel.demoModel()
        var account = model.snapshot.accounts[0]
        account.windows = [.init(id: "five_hour", observedAt: model.now, state: .notApplicable)]
        XCTAssertEqual(model.quotaText(account, window: "five_hour"), "Not applicable")
        XCTAssertTrue(model.displayedWindows(account).isEmpty)
        account.windows[0].state = .unknown
        XCTAssertEqual(model.quotaText(account, window: "five_hour"), "—")
        XCTAssertEqual(model.displayedWindows(account).count, 1)
    }

    func testUpdateFailureDoesNotInvalidateExistingInstallation() {
        let model = PoolAppModel.demoModel()
        model.runtime.phase = .failed
        XCTAssertTrue(model.setupComplete)
        XCTAssertTrue(model.snapshot.executableReady)
        XCTAssertFalse(model.runtime.busy)
    }

    func testComparableTotalsAverageTheAccountsAlreadyRead() throws {
        let model = PoolAppModel.demoModel()
        let complete = try XCTUnwrap(model.quotaSummary.groups.first { $0.plan == "Max 5x" && $0.windowID == "five_hour" })
        XCTAssertEqual(model.poolQuotaText(complete), "79%")
        model.snapshot.accounts[1].windows[0].state = .unknown
        let partial = try XCTUnwrap(model.quotaSummary.groups.first { $0.plan == "Max 5x" && $0.windowID == "five_hour" })
        XCTAssertEqual(model.poolQuotaText(partial), "100%", "The unread account is counted apart until it is read")
        XCTAssertEqual(partial.knownCount, 1)
        XCTAssertEqual(partial.unknownCount, 1)
        XCTAssertNotNil(partial.remainingUnits)
    }

    func testResetLabelsAreCompactButPreciseTimeIsRetained() {
        let model = PoolAppModel.demoModel()
        let today = model.now.addingTimeInterval(3600)
        let tomorrow = model.now.addingTimeInterval(86400)
        XCTAssertEqual(model.clockTime(today), "15:00")
        XCTAssertEqual(model.clockTime(tomorrow.addingTimeInterval(3600)), "Tomorrow 15:00")
        XCTAssertTrue(model.exactTime(today).contains("2026-11-04 15:00:00"))
    }

    /// Wednesday 4 November 2026, 14:00 in Taipei, in the demo, a week starting on Monday.
    func testClockTimeSaysTheDayAsAPersonWould() {
        let model = PoolAppModel.demoModel()
        let hour = model.now.addingTimeInterval(3600), day: TimeInterval = 86400
        XCTAssertEqual(model.clockTime(hour.addingTimeInterval(-day)), "Yesterday 15:00")
        XCTAssertEqual(model.clockTime(hour.addingTimeInterval(2 * day)), "Fri 15:00")
        XCTAssertEqual(model.clockTime(hour.addingTimeInterval(-2 * day)), "Mon 15:00")
        XCTAssertEqual(model.clockTime(hour.addingTimeInterval(5 * day)), "Nov 9 at 15:00", "Next week carries its date")
        XCTAssertEqual(model.clockTime(hour.addingTimeInterval(60 * day)), "Jan 3, 2027 at 15:00")

        let chinese = PoolAppModel.demoModel(language: "zh-Hans")
        XCTAssertEqual(chinese.clockTime(hour.addingTimeInterval(day)), "明天 15:00")
        XCTAssertEqual(chinese.clockTime(hour.addingTimeInterval(-day)), "昨天 15:00")
        XCTAssertEqual(chinese.clockTime(hour.addingTimeInterval(2 * day)), "周五 15:00")
        XCTAssertEqual(chinese.clockTime(hour.addingTimeInterval(5 * day)), "11月9日 15:00")
        XCTAssertEqual(chinese.clockTime(hour.addingTimeInterval(60 * day)), "2027年1月3日 15:00")
    }

    func testAReadingHoldsUntilItsResetAndThenTheLimitIsFull() {
        let model = PoolAppModel.demoModel()
        var account = model.snapshot.accounts[0]
        account.windows[0].observedAt = model.now.addingTimeInterval(-3600)
        XCTAssertEqual(model.quotaText(account, window: "seven_day"), "64%")
        XCTAssertTrue(model.resetText(account, window: "seven_day").hasPrefix("Resets"))
        account.windows[0].resetsAt = model.now.addingTimeInterval(-1)
        XCTAssertEqual(model.quotaText(account, window: "seven_day"), "100%")
        XCTAssertEqual(model.resetText(account, window: "seven_day"), "Renewed · full again")
    }

    func testRefreshDefaultsAndFreeEligibility() {
        let model = PoolAppModel.demoModel()
        XCTAssertEqual(model.preferences.quotaRefresh.burstInterval, 10)
        XCTAssertEqual(model.preferences.quotaRefresh.concurrentInterval, 20)
        XCTAssertEqual(model.preferences.quotaRefresh.generatingInterval, 45)
        XCTAssertEqual(model.preferences.quotaRefresh.interactiveInterval, 120)
        XCTAssertEqual(model.preferences.quotaRefresh.quietInterval, 300)
        model.snapshot.accounts[0].state = .subscriptionRequired
        model.snapshot.accounts[0].plan = "Free"
        model.snapshot.accounts[0].windows = []
        XCTAssertFalse(model.readyAccounts.contains { $0.id == model.snapshot.accounts[0].id })
        XCTAssertEqual(model.stateTitle(.subscriptionRequired), "Subscription required")
        var preferences = model.preferences.quotaRefresh
        preferences.quietInterval = 240
        model.perform(.quotaRefreshPreferences(preferences))
        XCTAssertEqual(model.preferences.quotaRefresh.quietInterval, 240)
    }

    func testMenuClockMovesOnAtTheNextLimitRenewalOrCooldownEnd() {
        let model = PoolAppModel.demoModel()
        let date = model.now
        // The limited account's cooldown and the 5-hour resets come back two hours on.
        XCTAssertEqual(model.nextQuotaBoundary(after: date), date.addingTimeInterval(7200))
        XCTAssertEqual(model.nextQuotaBoundary(after: date.addingTimeInterval(7200)), date.addingTimeInterval(172800))
        XCTAssertNil(model.nextQuotaBoundary(after: date.addingTimeInterval(172800)))
    }

    func testConversationsNotRunsDecideHowAccountsAreShown() {
        let model = PoolAppModel.demoModel()
        let (first, second, title) = (model.snapshot.sessions[0], model.snapshot.sessions[1], model.snapshot.sessions[2])
        // Conversation 1 has a title request beside it on its account: still one conversation.
        XCTAssertEqual(title.conversation, first.conversation)
        XCTAssertEqual(model.conversations.map(\.number), [1, 2])
        XCTAssertEqual(model.conversations.first { $0.id == first.conversation }?.sessionIDs.count, 2)
        XCTAssertEqual(model.accountUse[first.accountID], AccountUse(conversations: 1, working: true))
        XCTAssertEqual(model.accountUse[second.accountID], AccountUse(conversations: 1, working: true))
        XCTAssertEqual(model.useSummaryText, "In use: 2 accounts · 2 conversations")
        // Both waiting for the next message: still on their accounts, quietly, and their quota still watched.
        model.snapshot.sessions[0].state = .idle; model.snapshot.sessions[1].state = .idle
        XCTAssertEqual(model.accountUse[first.accountID], AccountUse(conversations: 1, working: false))
        XCTAssertEqual(model.conversations.map(\.state), [.idle, .idle])
        XCTAssertEqual(Set(model.currentSessionAccounts.map(\.id)), [first.accountID, second.accountID])
        // New conversations go where routing would put one, which may be an account already in use.
        XCTAssertEqual(model.newConversationAccount?.id, model.readyAccounts.first?.id)
        XCTAssertEqual(model.newConversationText, "New conversations: " + model.accountName(model.readyAccounts[0].id))
        model.snapshot.sessions = model.snapshot.sessions.map { var ended = $0; ended.state = .ended; return ended }
        XCTAssertTrue(model.conversations.isEmpty)
        XCTAssertEqual(model.useSummaryText, "No conversations")
        XCTAssertTrue(model.currentSessionAccounts.isEmpty)
    }

    func testRouteLanesShowEveryAccountInUse() {
        let ids = (0..<5).map { _ in UUID() }
        func conversation(_ n: Int, _ account: UUID, _ state: SessionState) -> PoolConversation {
            .init(id: "c\(n)", number: n, accountID: account, model: "Opus", state: state, startedAt: Date(), sessionIDs: [UUID()])
        }
        let lanes = RoutingFlowView.lanes([conversation(1, ids[0], .idle), conversation(2, ids[1], .running), conversation(3, ids[0], .idle)])
        XCTAssertEqual(lanes.map(\.accountID), [ids[1], ids[0]], "Answering first, then by conversations")
        XCTAssertEqual(lanes.map(\.conversations), [1, 2])
        let many = (0..<5).map { conversation($0 + 1, ids[$0], .idle) }
        XCTAssertEqual(RoutingFlowView.lanes(many).count, RoutingFlowView.laneLimit)
    }

    func testClaudeCodesOwnOneOffAsksAreNoConversations() {
        let model = PoolAppModel.demoModel()
        let before = model.conversations.count
        for n in 0..<2 {
            model.snapshot.sessions.append(.init(accountID: model.snapshot.accounts[n].id, name: "Claude session", model: "Haiku",
                                                 state: .idle, conversation: "title-\(n)", isOneOff: true))
        }
        XCTAssertEqual(model.conversations.count, before)
    }

    func testExhaustedSubscriptionsCanStartButFreeOnlyCannot() {
        let model = PoolAppModel.demoModel()
        for index in model.snapshot.accounts.indices {
            model.snapshot.accounts[index].state = .limited
            model.snapshot.accounts[index].cooldownUntil = model.now.addingTimeInterval(3600)
        }
        XCTAssertTrue(model.readyAccounts.isEmpty)
        XCTAssertTrue(model.canStartPool)
        for index in model.snapshot.accounts.indices {
            model.snapshot.accounts[index].state = .subscriptionRequired
            model.snapshot.accounts[index].plan = "Free"
        }
        XCTAssertFalse(model.canStartPool)
    }

    func testRouteMotionTracksWorkAndHonorsReducedMotion() {
        let fixture = PoolAppModel.demoModel()
        let model = PoolAppModel(snapshot: fixture.snapshot, preferences: fixture.preferences)
        let id = model.snapshot.sessions[0].id
        XCTAssertEqual(model.routeFlowActivity(for: id), .starting)
        model.generatingSessionIDs = [id]
        XCTAssertEqual(model.routeFlowActivity(for: id), .working)
        XCTAssertTrue(model.routeMotionEnabled(for: id, reduceMotion: false))
        XCTAssertFalse(model.routeMotionEnabled(for: id, reduceMotion: true))
        model.snapshot.sessions[0].state = .idle
        XCTAssertFalse(model.routeMotionEnabled(for: id, reduceMotion: false))
        model.snapshot.sessions[0].state = .waiting
        XCTAssertEqual(model.routeFlowActivity(for: id), .waiting)
        XCTAssertFalse(model.routeMotionEnabled(for: id, reduceMotion: false))
        model.snapshot.sessions[0].state = .running
        model.snapshot.mode = .stopped
        XCTAssertFalse(model.routeMotionEnabled(for: id, reduceMotion: false))
        model.snapshot.mode = .stopping
        XCTAssertTrue(model.routeMotionEnabled(for: id, reduceMotion: false))
        model.snapshot.sessions[0].state = .attention
        XCTAssertFalse(model.routeMotionEnabled(for: id, reduceMotion: false))
        model.privacy.isProcessing = true
        XCTAssertTrue(model.routeMotionEnabled(for: nil, reduceMotion: false))
        XCTAssertEqual(model.routeFlowActivity(for: id), .attention)
        model.privacy.isProcessing = false
        XCTAssertFalse(model.routeMotionEnabled(for: nil, reduceMotion: false))
    }

    func testRoutingFormPreservesSelectionAndReordersActualAccounts() {
        let model = PoolAppModel.demoModel()
        let original = model.orderedRoutingAccounts.map(\.id)
        model.setRoutingStrategy(.ordered)
        model.setRoutingReserve(15)
        model.moveRoutingAccount(original[1], by: -1)
        XCTAssertEqual(model.preferences.routingPolicy.strategy, .ordered)
        XCTAssertEqual(model.preferences.routingPolicy.reservePercent, 15)
        XCTAssertEqual(model.orderedRoutingAccounts.map(\.id), [original[1], original[0], original[2], original[3]])
        model.moveRoutingAccount(original[1], by: -1)
        XCTAssertEqual(model.orderedRoutingAccounts.first?.id, original[1])
    }

    func testPrivacyReadinessGatesPoolAndPreviewIsEphemeral() {
        let model = PoolAppModel.demoModel()
        model.privacy.phase = .notInstalled
        XCTAssertFalse(model.canStartPool)
        model.privacy.phase = .installing
        XCTAssertFalse(model.canStartPool)
        model.privacy.phase = .ready
        XCTAssertTrue(model.canStartPool)
        model.privacyPreview = .init(phase: .ready, text: "Hello {{PERSON_1}}", protectedCount: 1,
                                    categories: [.init(id: "PERSON", title: "PERSON", count: 1)])
        model.perform(.clearPrivacyPreview)
        XCTAssertEqual(model.privacyPreview, .init())
        XCTAssertEqual(model.privacy.phase, .ready)
    }
}
