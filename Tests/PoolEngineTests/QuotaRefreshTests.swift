import Foundation
import XCTest
import PoolCore
import PoolRuntime
@testable import PoolEngine

final class QuotaRefreshTests: XCTestCase {
    // Synthetic data in the visible /usage layout described by Claude's docs.
    // No saved private panel or account record is used.
    private let panel = """
    Settings  Status  Config  Usage  Stats
    Current session
    ███ 12% used
    Resets 11am (UTC)
    Current week (all models)
    ███ 9% used
    Resets Nov 7 at 2pm (UTC)
    Current week (Fable)
    █ 3% used
    Resets Nov 7 at 2pm (UTC)
    Esc to cancel
    """
    private var now: Date { ISO8601DateFormatter().date(from: "2026-11-04T08:00:00Z")! }
    /// The same panel for the fixture client, whose readings are taken at the wall clock: its resets
    /// stay a few hours and a few days ahead, so a fixed date never reads as a reset that has passed.
    private var livePanel: String {
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let session = Date().addingTimeInterval(2 * 3600), week = Date().addingTimeInterval(3 * 86400)
        let hour = utc.component(.hour, from: session)
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let day = "\(months[utc.component(.month, from: week) - 1]) \(utc.component(.day, from: week))"
        return panel.replacingOccurrences(of: "Resets 11am (UTC)", with: "Resets \(hour % 12 == 0 ? 12 : hour % 12)\(hour < 12 ? "am" : "pm") (UTC)")
            .replacingOccurrences(of: "Resets Nov 7 at 2pm (UTC)", with: "Resets \(day) at 2pm (UTC)")
    }

    func testLoadedNativePanelPreservesDynamicWindowsAndResets() throws {
        let windows = try NativeUsageParser.parse(panel, plan: "Max 5x", observedAt: now)
        XCTAssertEqual(windows.map(\.id), ["five_hour", "seven_day", "seven_day_fable"])
        XCTAssertEqual(windows.map(\.usedPercent), [12, 9, 3])
        XCTAssertEqual(windows[0].resetsAt, now.addingTimeInterval(3 * 3600))
        XCTAssertEqual(windows[2].modelFamily, "fable")
    }
    func testVerifiedUltraSessionAbsenceIsNotZeroQuota() throws {
        let text = "Settings Status Config Usage Stats\nCurrent week (all models) 17% used\nResets Nov 7 at 2pm (UTC)"
        let windows = try NativeUsageParser.parse(text, plan: "Ultra", observedAt: now)
        XCTAssertEqual(windows.first?.id, "five_hour")
        XCTAssertEqual(windows.first?.state, .notApplicable)
        XCTAssertNil(windows.first?.usedPercent)
        let unknownPlan = try NativeUsageParser.parse(text, plan: "Plan unknown", observedAt: now)
        XCTAssertEqual(unknownPlan.map(\.id), ["seven_day"])
        let unverified = try NativeUsageParser.parse(panel, plan: "Ultra", observedAt: now)
        XCTAssertEqual(unverified.first?.state, .reported)
    }
    func testValidPanelDoesNotInventAnUnreportedWeeklyWindow() throws {
        let text = "Settings Status Config Usage Stats\nCurrent session 0% used"
        let windows = try NativeUsageParser.parse(text, plan: "Team", observedAt: now)
        XCTAssertEqual(windows.map(\.id), ["five_hour"])
        XCTAssertEqual(windows[0].usedPercent, 0)
        XCTAssertNil(windows[0].resetsAt)
        XCTAssertFalse(windows[0].startsOnNextUse)
    }
    func testLoadingFailureAndUnsupportedPanelsNeverBecomeZero() {
        for text in [panel + "\nLoading usage data...", "Settings Status Usage\nFailed to load usage data", "Settings Usage\nCurrent week (all models) NaN% used", "Settings Usage\nCurrent week (all models) 105% used"] {
            XCTAssertThrowsError(try NativeUsageParser.parse(text, plan: "Pro", observedAt: now))
        }
    }
    func testAPanelStillDrawingItsFiguresIsLoadingNotUnsupported() {
        for text in ["Settings Status Config Usage Stats", "Settings Status Config Usage Stats\nCurrent session\n", "Settings Usage\nCurrent session 12% used\nCurrent week (all models)"] {
            XCTAssertThrowsError(try NativeUsageParser.parse(text, plan: "Pro", observedAt: now)) {
                XCTAssertEqual($0 as? QuotaRefreshFailure, .loading)
            }
        }
    }
    func testQuittingDuringAReadIsNotSavedAsAFailure() async throws {
        let workspace = try fixtureWorkspace(), reading = expectation(description: "Read started")
        reading.assertForOverFulfill = false
        let fixture = UsageProcessFixture(workspace: workspace, panel: "Settings Usage\nLoading usage data")
        let service = makeService(workspace: workspace, fixture: fixture) { update in
            if case .status(_, let status) = update, status.phase == .refreshing { reading.fulfill() }
        }
        let account = fixtureAccount()
        try await service.start(); await service.setAccounts([account]); await service.requestRefresh(accountID: account.id)
        await fulfillment(of: [reading], timeout: 30)
        _ = await service.stop()
        let restored = makeService(workspace: workspace, fixture: fixture) { _ in }
        try await restored.start(); await restored.setAccounts([account])
        let status = await restored.statuses()[account.id]
        XCTAssertNil(status?.failure, "A read stopped by quitting must not stop later automatic reads")
        _ = await restored.stop()
    }
    func testExtraUsageIsTypedStateNotAnInventedMeasurement() throws {
        let text = panel + "\nYou are currently using your overages to power your Claude Code usage."
        let windows = try NativeUsageParser.parse(text, plan: "Pro", observedAt: now)
        XCTAssertTrue(NativeUsageParser.usesExtraUsage(text))
        XCTAssertFalse(windows.contains { $0.id == "extra_usage" })
        XCTAssertEqual(windows.map(\.usedPercent), [12, 9, 3])
    }
    func testOnlyModelSuffixIsNormalized() throws {
        let text = "Settings Usage\nCurrent week (all models) 4% used\nCurrent week (Sonnet only) 100% used"
        let windows = try NativeUsageParser.parse(text, plan: "Pro", observedAt: now)
        XCTAssertEqual(windows[1].id, "seven_day_sonnet")
        XCTAssertEqual(windows[1].modelFamily, "sonnet")
    }
    func testUnknownWeeklyHeadingCannotBypassAnExhaustedAccountConstraint() throws {
        for heading in ["Claude Code", "Sonnet and Opus"] {
            let text = "Settings Usage\nCurrent week (all models) 4% used\nCurrent week (\(heading)) 100% used\nResets Nov 7 at 2pm (UTC)"
            let windows = try NativeUsageParser.parse(text, plan: "Pro", observedAt: now)
            XCTAssertEqual(windows.count, 2)
            XCTAssertNil(windows[1].modelFamily)
            XCTAssertEqual(windows[1].usedPercent, 100)
            let account = PoolAccount(email: "a•••@gmail.com", plan: "Pro", state: .ready, windows: windows)
            for model in PoolModel.defaults {
                XCTAssertTrue(windows[1].applies(to: model.cliAlias))
                XCTAssertTrue(PoolRouting.candidates([account], model: model.cliAlias, now: now).isEmpty)
            }
        }
    }
    /// A client that lost its sign-in (11-06) shows API billing and a panel of costs without limits.
    func testASignedOutPanelAsksToSignInInsteadOfLoadingUntilTimeout() {
        let text = "Opus 5.5 · API Usage Billing\nSettings Status Config Usage Stats\nSession\nTotal cost: $0.0000\nTotal duration (API): 0s\nEsc to cancel"
        XCTAssertThrowsError(try NativeUsageParser.parse(text, plan: "Pro", observedAt: now)) { XCTAssertEqual($0 as? QuotaRefreshFailure, .authentication) }
    }
    /// The real 2.1.318 screen of a signed-out account (11-06): the banner naming the billing has
    /// scrolled away, and the tab shows only costs. It timed out at the panel stage on every read.
    func testASignedOutCostTabWithoutTheBillingBannerAsksToSignIn() {
        let text = """
               ~/…/Claude Pool/accounts/example/work
        ────────────────────────────────────────────
           Settings  Status   Config   Usage   Stats

           Session
           Total cost:            $0.0000
           Total duration (API):  0s
           Total duration (wall): 39s
           Total code changes:    0 lines added, 0 lines removed
           Usage:                 0 input, 0 output, 0 cache read, 0 cache write

           Esc to cancel
        """
        XCTAssertThrowsError(try NativeUsageParser.parse(text, plan: "Pro", observedAt: now)) { XCTAssertEqual($0 as? QuotaRefreshFailure, .authentication) }
    }
    func testResetParsingRejectsUnknownOrAmbiguousTime() {
        for text in ["11am", "11am (Missing/Zone)", "in 3 hours (UTC)", "7pm (UTC)"] {
            XCTAssertNil(NativeUsageParser.resetTime(text, observedAt: now, windowID: "five_hour"))
        }
        XCTAssertNil(NativeUsageParser.resetTime("11am (UTC)", observedAt: now, windowID: "seven_day"))
        let dst = ISO8601DateFormatter().date(from: "2026-11-01T04:30:00Z")!
        XCTAssertNil(NativeUsageParser.resetTime("1:30am (America/New_York)", observedAt: dst, windowID: "five_hour"))
    }
    func testNamedZoneAndYearBoundaryAreReadWithoutMachineTimezone() {
        XCTAssertEqual(NativeUsageParser.resetTime("5pm (Asia/Taipei)", observedAt: now, windowID: "five_hour"), now.addingTimeInterval(3600))
        // Right after a reset the panel can still show the cycle that ended: its passed reset is
        // kept, so that reading is told apart from a current one instead of losing its reset.
        XCTAssertEqual(NativeUsageParser.resetTime("3pm (Asia/Taipei)", observedAt: now, windowID: "five_hour"), now.addingTimeInterval(-3600))
        let december = ISO8601DateFormatter().date(from: "2026-12-31T23:00:00Z")!
        let january = ISO8601DateFormatter().date(from: "2027-01-01T02:00:00Z")!
        XCTAssertEqual(NativeUsageParser.resetTime("Jan 1, 2am (UTC)", observedAt: december, windowID: "seven_day"), january)
        XCTAssertEqual(NativeUsageParser.resetTime("Jan 1, 2027 at 2am (UTC)", observedAt: december, windowID: "seven_day"), january)
    }

    func testManualRefreshUsesDedicatedOfficialCommandAndClosesNormally() async throws {
        let workspace = try fixtureWorkspace()
        let fixture = UsageProcessFixture(workspace: workspace, panel: livePanel)
        let done = expectation(description: "Usage returned and the observer exited")
        let log = QuotaUpdateLog()
        let service = makeService(workspace: workspace, fixture: fixture) { update in
            await log.append(update)
            if case .status(_, let status) = update, status.phase == .idle, status.lastSuccessAt != nil { done.fulfill() }
        }
        let account = fixtureAccount()
        try await service.start(); await service.setAccounts([account])
        await service.requestRefresh(accountID: account.id)
        await fulfillment(of: [done], timeout: 30)
        let windows = await log.readings.first
        XCTAssertEqual(windows?.map(\.usedPercent), [12, 9, 3])
        let plan = try XCTUnwrap(fixture.plans.first)
        XCTAssertFalse(plan.arguments.contains("-p"))
        XCTAssertFalse(plan.arguments.contains("--bare"))
        XCTAssertFalse(plan.arguments.contains("--dangerously-skip-permissions"))
        XCTAssertEqual(fixture.commands.filter { $0 == Data("/usage".utf8) }.count, 1)
        XCTAssertEqual(fixture.exitCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.runDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.directory.path))
        let stopped = await service.stop(); XCTAssertTrue(stopped)
    }
    func testSessionEndHookDoesNotAuthorizeCleanupOrAccountMutationBeforeProcessExit() async throws {
        let workspace = try fixtureWorkspace(), attention = expectation(description: "Owned process has not exited")
        let exited = expectation(description: "Owned process exit observed")
        let fixture = UsageProcessFixture(workspace: workspace, panel: livePanel, deferExit: true)
        let service = makeService(workspace: workspace, fixture: fixture) { update in
            if case .status(_, let status) = update, status.phase == .needsAttention { attention.fulfill() }
            if case .ended = update { exited.fulfill() }
        }
        let account = fixtureAccount()
        await service.setAccounts([account]); try await service.start()
        await service.requestRefresh(accountID: account.id)
        await fulfillment(of: [attention], timeout: 30)
        let plan = try XCTUnwrap(fixture.plans.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.runDirectory.path))
        let premature = await service.suspend(accountID: account.id)
        XCTAssertFalse(premature)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.runDirectory.path))
        XCTAssertEqual(fixture.plans.count, 1)

        fixture.completeExit()
        await fulfillment(of: [exited], timeout: 30)
        let confirmed = await service.suspend(accountID: account.id)
        XCTAssertTrue(confirmed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.runDirectory.path))
        let stopped = await service.stop(); XCTAssertTrue(stopped)
    }
    func testCleanupFailureKeepsRunAndReportsStorageUntilSafeRetry() async throws {
        let workspace = try fixtureWorkspace(), failed = expectation(description: "Cleanup requires attention")
        let fixture = UsageProcessFixture(workspace: workspace, panel: livePanel, blockCleanup: true)
        let failures = QuotaEventCounter()
        let service = makeService(workspace: workspace, fixture: fixture) { update in
            if case .status(_, let status) = update, status.failure == .storage,
               await failures.increment() == 1 { failed.fulfill() }
        }
        let account = fixtureAccount()
        await service.setAccounts([account]); try await service.start()
        await service.requestRefresh(accountID: account.id)
        await fulfillment(of: [failed], timeout: 30)
        let plan = try XCTUnwrap(fixture.plans.first)
        XCTAssertEqual(fixture.exitCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.runDirectory.appendingPathComponent("run.json").path))
        let unclean = await service.suspend(accountID: account.id)
        XCTAssertFalse(unclean)
        try workspace.remove(plan.runDirectory.appendingPathComponent("unexpected.txt"))
        let cleaned = await service.suspend(accountID: account.id)
        XCTAssertTrue(cleaned)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.runDirectory.path))
        let stopped = await service.stop(); XCTAssertTrue(stopped)
    }
    func testOfflineManualRefreshQueuesUntilConnectivityReturns() async throws {
        let workspace = try fixtureWorkspace(), done = expectation(description: "Queued usage read completed")
        let fixture = UsageProcessFixture(workspace: workspace, panel: livePanel)
        let service = makeService(workspace: workspace, fixture: fixture) { update in
            if case .status(_, let status) = update, status.phase == .idle, status.lastSuccessAt != nil { done.fulfill() }
        }
        let account = fixtureAccount()
        try await service.start(); await service.setAccounts([account])
        await service.setAvailability(enabled: false, awake: true, online: false)
        await service.requestRefresh(accountID: account.id)
        XCTAssertEqual(fixture.plans.count, 0)
        await service.setAvailability(enabled: false, awake: true, online: true)
        await fulfillment(of: [done], timeout: 30)
        XCTAssertEqual(fixture.plans.count, 1)
        let stopped = await service.stop(); XCTAssertTrue(stopped)
    }
    func testManualRefreshCoalescesAndFailureBackoffSurvivesRestart() async throws {
        let workspace = try fixtureWorkspace(), failed = expectation(description: "Native failure retained")
        let fixture = UsageProcessFixture(workspace: workspace, panel: "Settings Usage\nFailed to load usage data")
        let log = QuotaUpdateLog(), clock = QuotaTestClock()
        let service = makeService(workspace: workspace, fixture: fixture, now: { clock.value }) { update in
            await log.append(update)
            if case .status(_, let status) = update, status.phase == .cooldown { failed.fulfill() }
        }
        let account = fixtureAccount()
        try await service.start(); await service.setAccounts([account])
        await service.requestRefresh(accountID: account.id)
        await fulfillment(of: [failed], timeout: 30)
        await service.requestRefresh(accountID: account.id)
        XCTAssertEqual(fixture.plans.count, 1)
        let before = await service.statuses()[account.id]
        XCTAssertEqual(before?.lastSuccessAt, nil)
        XCTAssertEqual(before?.nextAttemptAt, clock.value.addingTimeInterval(60))
        let stopped = await service.stop(); XCTAssertTrue(stopped)
        let restored = makeService(workspace: workspace, fixture: fixture, now: { clock.value }) { _ in }
        try await restored.start(); await restored.setAccounts([account]); await restored.requestRefresh(accountID: account.id)
        XCTAssertEqual(fixture.plans.count, 1)
        let restoredStatus = await restored.statuses()[account.id]
        XCTAssertEqual(restoredStatus?.failure, .unavailable)
        XCTAssertEqual(restoredStatus?.nextAttemptAt, before?.nextAttemptAt)
        let restoredStopped = await restored.stop(); XCTAssertTrue(restoredStopped)
    }
    func testChangedPlanEmailOrOrganizationDiscardsPersistedFailureAndResetReceipts() async throws {
        for changedField in ["plan", "email", "organization"] {
            let workspace = try fixtureWorkspace(), failed = expectation(description: "Old scope failure persisted")
            let fixture = UsageProcessFixture(workspace: workspace, panel: "Settings Usage\nFailed to load usage data")
            let service = makeService(workspace: workspace, fixture: fixture) { update in
                if case .status(_, let status) = update, status.phase == .cooldown { failed.fulfill() }
            }
            var original = fixtureAccount()
            original.email = "a•••@gmail.com"; original.identityFingerprint = "fixture-organization-a"
            original.windows = [.init(id: "five_hour", usedPercent: 100, observedAt: Date().addingTimeInterval(-3_600),
                                      resetsAt: Date().addingTimeInterval(-60))]
            await service.setAccounts([original]); try await service.start()
            await service.requestRefresh(accountID: original.id)
            await fulfillment(of: [failed], timeout: 30)
            let stateFile = workspace.root.appendingPathComponent("quota-refresh.json")
            let oldData = try workspace.read(stateFile, limit: 512 * 1024)
            let oldRecord = try XCTUnwrap(JSONDecoder().decode([JSONValue].self, from: oldData).first)
            XCTAssertNotNil(oldRecord["resetChecks"]?["five_hour"])
            XCTAssertEqual(oldRecord["scope"]?.stringValue?.count, 64)
            let storedText = String(decoding: oldData, as: UTF8.self)
            XCTAssertFalse(storedText.contains(original.email!))
            XCTAssertFalse(storedText.contains(original.identityFingerprint!))

            var replacement = original; replacement.windows = []
            switch changedField {
            case "plan": replacement.plan = "Ultra"
            case "email": replacement.email = "b•••@gmail.com"
            default: replacement.identityFingerprint = "fixture-organization-b"
            }
            await service.setAccounts([replacement])
            let clearedData = try workspace.read(stateFile, limit: 512 * 1024)
            let cleared = try XCTUnwrap(JSONDecoder().decode([JSONValue].self, from: clearedData).first)
            XCTAssertNotEqual(cleared["scope"], oldRecord["scope"])
            XCTAssertNil(cleared["status"]?["failure"])
            XCTAssertNil(cleared["resetChecks"])
            let stopped = await service.stop(); XCTAssertTrue(stopped)

            // A restart can see an older scheduler file than the account library.
            try workspace.write(oldData, to: stateFile)
            let restarted = makeService(workspace: workspace, fixture: fixture) { _ in }
            await restarted.setAccounts([replacement]); try await restarted.start()
            let status = await restarted.statuses()[replacement.id]
            XCTAssertNil(status?.failure)
            XCTAssertNil(status?.lastAttemptAt)
            XCTAssertNil(status?.lastSuccessAt)
            let persisted = try XCTUnwrap(JSONDecoder().decode([JSONValue].self,
                from: workspace.read(stateFile, limit: 512 * 1024)).first)
            XCTAssertNil(persisted["resetChecks"])
            XCTAssertEqual(persisted["scope"], cleared["scope"])
            await restarted.setAccounts([])
            let removed = try JSONDecoder().decode([JSONValue].self, from: workspace.read(stateFile, limit: 512 * 1024))
            XCTAssertTrue(removed.isEmpty)
            let restartedStopped = await restarted.stop(); XCTAssertTrue(restartedStopped)
            XCTAssertEqual(fixture.plans.count, 1)
        }
    }
    func testFirstUseTrustPromptResumesSameObserverAfterExplicitInput() async throws {
        let workspace = try fixtureWorkspace(), attention = expectation(description: "Native trust prompt surfaced")
        let done = expectation(description: "Original observer continued after input")
        attention.assertForOverFulfill = false
        let fixture = UsageProcessFixture(workspace: workspace, panel: livePanel, needsTrust: true)
        let service = makeService(workspace: workspace, fixture: fixture) { update in
            if case .status(_, let status) = update, status.phase == .needsAttention { attention.fulfill() }
            if case .status(_, let status) = update, status.phase == .idle, status.lastSuccessAt != nil { done.fulfill() }
        }
        let account = fixtureAccount()
        try await service.start(); await service.setAccounts([account]); await service.requestRefresh(accountID: account.id)
        await fulfillment(of: [attention], timeout: 30)
        let status = await service.statuses()[account.id]
        let observer = try XCTUnwrap(status?.observerID)
        await service.requestRefresh(accountID: account.id)
        let held = await service.statuses()[account.id]
        XCTAssertEqual(held?.phase, .needsAttention, "A held session must not be shown as a queued refresh that never starts")
        XCTAssertEqual(fixture.plans.count, 1)
        try await service.sendInput(observerID: observer, data: Data("y\r".utf8))
        await fulfillment(of: [done], timeout: 30)
        XCTAssertEqual(fixture.plans.count, 1)
        XCTAssertEqual(fixture.commands.filter { $0 == Data("/usage".utf8) }.count, 1)
        let stopped = await service.stop(); XCTAssertTrue(stopped)
    }
    func testFreshAccountFolderFirstRunScreensAreAnsweredWithoutUserInput() async throws {
        let workspace = try fixtureWorkspace(), done = expectation(description: "Usage read after first-run screens")
        let fixture = UsageProcessFixture(workspace: workspace, panel: livePanel, firstRun: ["theme", "notes", "trust-no", "trust-yes"])
        let log = QuotaUpdateLog()
        let service = makeService(workspace: workspace, fixture: fixture) { update in
            await log.append(update)
            if case .status(_, let status) = update, status.phase == .idle, status.lastSuccessAt != nil { done.fulfill() }
        }
        let account = fixtureAccount()
        try await service.start(); await service.setAccounts([account]); await service.requestRefresh(accountID: account.id, reason: .initial)
        await fulfillment(of: [done], timeout: 30)
        XCTAssertEqual(fixture.plans.count, 1)
        XCTAssertEqual(Array(fixture.commands.prefix(4)), [Data("\r".utf8), Data("\r".utf8), Data("\u{1b}[B".utf8), Data("\r".utf8)])
        XCTAssertEqual(fixture.commands.filter { $0 == Data("/usage".utf8) }.count, 1)
        let attention = await log.updates.contains { if case .status(_, let status) = $0 { return status.phase == .needsAttention }; return false }
        XCTAssertFalse(attention)
        let stopped = await service.stop(); XCTAssertTrue(stopped)
    }
    func testSignInScreenIsReportedAsAuthenticationAndNotAnswered() async throws {
        let workspace = try fixtureWorkspace(), failed = expectation(description: "Sign-in required")
        failed.assertForOverFulfill = false
        let fixture = UsageProcessFixture(workspace: workspace, panel: livePanel, firstRun: ["login"])
        let service = makeService(workspace: workspace, fixture: fixture) { update in
            if case .status(_, let status) = update, status.failure == .authentication { failed.fulfill() }
        }
        let account = fixtureAccount()
        try await service.start(); await service.setAccounts([account]); await service.requestRefresh(accountID: account.id, reason: .initial)
        await fulfillment(of: [failed], timeout: 30)
        XCTAssertTrue(fixture.commands.isEmpty, "Nothing is typed into the official sign-in")
        _ = await service.stop()
    }
    func testExplicitExitEndsASessionHeldBeforeItsPromptWithNormalInterrupts() async throws {
        let workspace = try fixtureWorkspace(), attention = expectation(description: "Held before its prompt")
        attention.assertForOverFulfill = false
        let fixture = UsageProcessFixture(workspace: workspace, panel: livePanel, firstRun: ["An unfamiliar first-run screen"])
        let service = makeService(workspace: workspace, fixture: fixture, observerTimeout: 2) { update in
            if case .status(_, let status) = update, status.phase == .needsAttention { attention.fulfill() }
        }
        let account = fixtureAccount()
        try await service.start(); await service.setAccounts([account]); await service.requestRefresh(accountID: account.id, reason: .initial)
        await fulfillment(of: [attention], timeout: 30)
        XCTAssertEqual(fixture.interruptCount, 0, "An automatic failure keeps the session for the user")
        let held = await service.statuses()[account.id]
        let observer = try XCTUnwrap(held?.observerID)
        let closed = await service.closeObserver(observerID: observer)
        XCTAssertTrue(closed)
        XCTAssertEqual(fixture.interruptCount, 2)
        XCTAssertFalse(fixture.commands.contains(Data("/exit\r".utf8)))
        // runDirectory(_:) creates its folder, so check the path itself.
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.root.appendingPathComponent("runs/\(observer.uuidString.lowercased())").path))
        let stopped = await service.stop(); XCTAssertTrue(stopped)
    }
    func testQuitCountsAKeyThatFindsTheChildGoneAsItsExit() async throws {
        let workspace = try fixtureWorkspace(), attention = expectation(description: "Held session")
        attention.assertForOverFulfill = false
        let fixture = UsageProcessFixture(workspace: workspace, panel: livePanel, needsTrust: true)
        fixture.exitEventLags = true
        let service = makeService(workspace: workspace, fixture: fixture) { update in
            if case .status(_, let status) = update, status.phase == .needsAttention { attention.fulfill() }
        }
        let account = fixtureAccount()
        try await service.start(); await service.setAccounts([account]); await service.requestRefresh(accountID: account.id, reason: .initial)
        await fulfillment(of: [attention], timeout: 30)
        let stopped = await service.stop()
        XCTAssertTrue(stopped)
    }
    func testQuitEndsAHeldSessionAndNeverEscalatesWhenInterruptIsIgnored() async throws {
        for ignores in [false, true] {
            let workspace = try fixtureWorkspace(), attention = expectation(description: "Held session")
            attention.assertForOverFulfill = false
            let fixture = UsageProcessFixture(workspace: workspace, panel: livePanel, needsTrust: true)
            fixture.ignoresInterrupt = ignores
            let service = makeService(workspace: workspace, fixture: fixture) { update in
                if case .status(_, let status) = update, status.phase == .needsAttention { attention.fulfill() }
            }
            let account = fixtureAccount()
            try await service.start(); await service.setAccounts([account]); await service.requestRefresh(accountID: account.id, reason: .initial)
            await fulfillment(of: [attention], timeout: 30)
            let stopped = await service.stop()
            XCTAssertEqual(stopped, !ignores)
            XCTAssertEqual(fixture.interruptCount, ignores ? 4 : 2, "Only paired normal interrupts are sent")
            if ignores { fixture.completeExit() }
        }
    }
    func testQuitEndsACheckWhoseClientIgnoresExit() async throws {
        let workspace = try fixtureWorkspace()
        let fixture = UsageProcessFixture(workspace: workspace, panel: livePanel)
        fixture.ignoresExit = true
        let service = makeService(workspace: workspace, fixture: fixture) { _ in }
        let account = fixtureAccount()
        try await service.start(); await service.setAccounts([account])
        await service.requestRefresh(accountID: account.id)
        let deadline = Date().addingTimeInterval(30)
        while fixture.exitCount == 0, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertGreaterThan(fixture.exitCount, 0)
        XCTAssertEqual(fixture.interruptCount, 0, "Checks end with /exit while the app keeps running")
        // Quitting still ends it, with the client's own double Ctrl-C and never a forced end.
        let stopped = await service.stop()
        XCTAssertTrue(stopped)
        XCTAssertEqual(fixture.interruptCount, 2)
    }
    func testAttentionFromAnEndedRunDoesNotBlockTheNextLaunch() async throws {
        let workspace = try fixtureWorkspace(), attention = expectation(description: "Held session")
        attention.assertForOverFulfill = false
        let fixture = UsageProcessFixture(workspace: workspace, panel: livePanel, needsTrust: true)
        let service = makeService(workspace: workspace, fixture: fixture) { update in
            if case .status(_, let status) = update, status.phase == .needsAttention { attention.fulfill() }
        }
        let account = fixtureAccount()
        try await service.start(); await service.setAccounts([account]); await service.requestRefresh(accountID: account.id, reason: .initial)
        await fulfillment(of: [attention], timeout: 30)
        let stateFile = workspace.root.appendingPathComponent("quota-refresh.json")
        let saved = try workspace.read(stateFile, limit: 512 * 1024)
        XCTAssertTrue(String(decoding: saved, as: UTF8.self).contains("needsAttention"))
        let restarted = makeService(workspace: workspace, fixture: fixture) { _ in }
        await restarted.setAccounts([account]); try await restarted.start()
        let status = await restarted.statuses()[account.id]
        XCTAssertNil(status?.failure)
        XCTAssertEqual(status?.phase, .idle)
        _ = await restarted.stop()
        _ = await service.stop()
    }
    func testFastSingleConversationCanRefreshAtTenSeconds() async throws {
        let workspace = try fixtureWorkspace(), first = expectation(description: "First automatic read"), second = expectation(description: "Ten-second follow-up")
        let fixture = UsageProcessFixture(workspace: workspace, panel: livePanel), clock = QuotaTestClock(), counter = QuotaEventCounter()
        let service = makeService(workspace: workspace, fixture: fixture, now: { clock.value }) { update in
            if case .status(_, let status) = update, status.phase == .idle, status.lastAttemptAt != nil, status.observerID == nil {
                let count = await counter.increment(); if count == 1 { first.fulfill() }; if count == 2 { second.fulfill() }
            }
        }
        var account = fixtureAccount()
        account.windows = [.init(id: "five_hour", usedPercent: 5, observedAt: clock.value, resetsAt: clock.value.addingTimeInterval(3600))]
        let session = UUID()
        try await service.start(); await service.setAccounts([account])
        await service.setWorkState(scope: AccountScope(account), sessionID: session, state: .generating, at: clock.value.addingTimeInterval(-2))
        await service.recordProgress(scope: AccountScope(account), sessionID: session, progress: fastProgress(at: clock.value))
        await service.setAvailability(enabled: true, awake: true, online: true)
        clock.advance(9); await service.setAvailability(enabled: true, awake: true, online: true)
        XCTAssertEqual(fixture.plans.count, 0)
        clock.advance(2); await service.setAvailability(enabled: true, awake: true, online: true)
        await fulfillment(of: [first], timeout: 30)
        clock.advance(9); await service.setAvailability(enabled: true, awake: true, online: true)
        XCTAssertEqual(fixture.plans.count, 1)
        clock.advance(2); await service.setAvailability(enabled: true, awake: true, online: true)
        await fulfillment(of: [second], timeout: 30)
        XCTAssertEqual(fixture.commands.filter { $0 == Data("/usage".utf8) }.count, 2, "Automatic refresh is not held behind the manual 30s throttle.")
        XCTAssertEqual(fixture.plans.count, 1, "A ten-second read reuses the session kept at its prompt instead of starting Claude Code again")
        XCTAssertEqual(fixture.exitCount, 0)
        let stopped = await service.stop(); XCTAssertTrue(stopped)
        XCTAssertEqual(fixture.exitCount, 1, "Quitting ends the kept session normally")
    }
    func testRetainedIdleAccountFallsBackToBackgroundReadsAndManualStillWorks() async throws {
        let workspace = try fixtureWorkspace(), done = expectation(description: "Explicit manual refresh")
        let fixture = UsageProcessFixture(workspace: workspace, panel: livePanel), clock = QuotaTestClock()
        let service = makeService(workspace: workspace, fixture: fixture, now: { clock.value }) { update in
            if case .status(_, let status) = update, status.phase == .idle, status.lastAttemptAt != nil { done.fulfill() }
        }
        var account = fixtureAccount()
        account.windows = [.init(id: "five_hour", usedPercent: 5, observedAt: clock.value, resetsAt: clock.value.addingTimeInterval(3600))]
        let session = UUID()
        try await service.start(); await service.setAccounts([account])
        await service.setAvailability(enabled: true, awake: true, online: true)
        for _ in 0..<30 { await service.setWorkState(scope: AccountScope(account), sessionID: session, state: .idle, at: clock.value) }
        clock.advance(600); await service.setAvailability(enabled: true, awake: true, online: true)
        let early = expectation(description: "Retained idle is dormant"); early.isInverted = true
        fixture.onLaunch { early.fulfill() }; await fulfillment(of: [early], timeout: 0.15); fixture.onLaunch {}
        XCTAssertEqual(fixture.plans.count, 0)
        let cadence = await service.cadence(accountID: account.id); XCTAssertNil(cadence.interval, "Without work nothing is read by time")
        await service.requestRefresh(accountID: account.id)
        await fulfillment(of: [done], timeout: 30)
        XCTAssertEqual(fixture.plans.count, 1)
        let stopped = await service.stop(); XCTAssertTrue(stopped)
    }
    func testNativeFreshnessDefersDedicatedReadDespiteOlderAttemptWhileGenerating() async throws {
        let workspace = try fixtureWorkspace(), first = expectation(description: "Manual read"), second = expectation(description: "Read after freshness expires")
        let fixture = UsageProcessFixture(workspace: workspace, panel: livePanel), clock = QuotaTestClock(), counter = QuotaEventCounter()
        let service = makeService(workspace: workspace, fixture: fixture, now: { clock.value }) { update in
            if case .status(_, let status) = update, status.phase == .idle, status.lastAttemptAt != nil, status.observerID == nil {
                let count = await counter.increment(); if count == 1 { first.fulfill() }; if count == 2 { second.fulfill() }
            }
        }
        let account = fixtureAccount(), session = UUID()
        try await service.start(); await service.setAccounts([account]); await service.requestRefresh(accountID: account.id)
        await fulfillment(of: [first], timeout: 30)
        clock.advance(50)
        var fresh = account
        fresh.windows = [.init(id: "five_hour", usedPercent: 8, observedAt: clock.value, resetsAt: clock.value.addingTimeInterval(3600))]
        await service.setAccounts([fresh]); await service.observe(scope: AccountScope(fresh), windows: fresh.windows)
        await service.setWorkState(scope: AccountScope(fresh), sessionID: session, state: .generating, at: clock.value)
        await service.recordProgress(scope: AccountScope(fresh), sessionID: session, progress: fastProgress(at: clock.value))
        await service.setAvailability(enabled: true, awake: true, online: true)
        clock.advance(9); await service.setAvailability(enabled: true, awake: true, online: true)
        let early = expectation(description: "Recent native observation suppresses duplicate read"); early.isInverted = true
        fixture.onLaunch { early.fulfill() }; await fulfillment(of: [early], timeout: 0.15); fixture.onLaunch {}
        XCTAssertEqual(fixture.plans.count, 1)
        clock.advance(2); await service.setAvailability(enabled: true, awake: true, online: true)
        await fulfillment(of: [second], timeout: 30)
        XCTAssertEqual(fixture.plans.count, 2)
        let stopped = await service.stop(); XCTAssertTrue(stopped)
    }
    func testIdentityChangeClearsDemandAndRejectsQueuedOldScopeProgress() async throws {
        let workspace = try fixtureWorkspace(), done = expectation(description: "New account genuine work")
        let fixture = UsageProcessFixture(workspace: workspace, panel: livePanel), clock = QuotaTestClock()
        let service = makeService(workspace: workspace, fixture: fixture, now: { clock.value }) { update in
            if case .status(_, let status) = update, status.phase == .idle, status.lastAttemptAt != nil { done.fulfill() }
        }
        var account = fixtureAccount()
        account.windows = [.init(id: "seven_day", usedPercent: 5, observedAt: clock.value, resetsAt: clock.value.addingTimeInterval(3600))]
        let session = UUID()
        try await service.start(); await service.setAccounts([account])
        await service.setWorkState(scope: AccountScope(account), sessionID: session, state: .generating, at: clock.value)
        await service.recordProgress(scope: AccountScope(account), sessionID: session, progress: fastProgress(at: clock.value))
        var changed = account; changed.plan = "Ultra"
        await service.setAccounts([changed])
        await service.setWorkState(scope: AccountScope(account), sessionID: session, state: .generating, at: clock.value)
        await service.recordProgress(scope: AccountScope(account), sessionID: session, progress: fastProgress(at: clock.value))
        await service.setAvailability(enabled: true, awake: true, online: true)
        clock.advance(31); await service.setAvailability(enabled: true, awake: true, online: true)
        let early = expectation(description: "Old identity activity cannot accelerate the new identity"); early.isInverted = true
        fixture.onLaunch { early.fulfill() }; await fulfillment(of: [early], timeout: 0.15); fixture.onLaunch {}
        XCTAssertEqual(fixture.plans.count, 0)
        await service.setWorkState(scope: AccountScope(changed), sessionID: session, state: .generating, at: clock.value)
        await service.recordProgress(scope: AccountScope(changed), sessionID: session, progress: fastProgress(at: clock.value))
        await fulfillment(of: [done], timeout: 30)
        XCTAssertEqual(fixture.plans.count, 1)
        let stopped = await service.stop(); XCTAssertTrue(stopped)
    }
    func testCadenceUpdatesPauseForSleepAndDormancyThenResumeFromRealWork() async throws {
        let workspace = try fixtureWorkspace()
        let fixture = UsageProcessFixture(workspace: workspace, panel: livePanel)
        let clock = QuotaTestClock(), log = QuotaUpdateLog(), session = UUID()
        let service = makeService(workspace: workspace, fixture: fixture, now: { clock.value }) { await log.append($0) }
        var account = fixtureAccount()
        account.windows = [.init(id: "five_hour", usedPercent: 5, observedAt: clock.value, resetsAt: clock.value.addingTimeInterval(3600))]
        try await service.start(); await service.setAccounts([account])
        await service.setAvailability(enabled: true, awake: true, online: true)
        await service.setWorkState(scope: AccountScope(account), sessionID: session, state: .generating, at: clock.value)
        let generating = await service.cadence(accountID: account.id); XCTAssertEqual(generating.interval!, 45, accuracy: 0.001)
        await service.setAvailability(enabled: true, awake: false, online: true)
        let asleep = await service.cadence(accountID: account.id); XCTAssertNil(asleep.interval)
        await service.setAvailability(enabled: true, awake: true, online: false)
        let offline = await service.cadence(accountID: account.id); XCTAssertNil(offline.interval)
        await service.setAvailability(enabled: true, awake: true, online: true)
        await service.setWorkState(scope: AccountScope(account), sessionID: session, state: .waitingTool, at: clock.value)
        clock.advance(121); await service.setAvailability(enabled: true, awake: true, online: true)
        let dormant = await service.cadence(accountID: account.id); XCTAssertNil(dormant.interval, "Without work nothing is read by time")
        XCTAssertEqual(fixture.plans.count, 0)
        let updates = await log.updates
        XCTAssertTrue(updates.contains { if case .cadence(_, let value) = $0 { return value.generatingSessions == 1 }; return false })
        if case .cadence(_, let value) = updates.last { XCTAssertNil(value.interval) }
        let stopped = await service.stop(); XCTAssertTrue(stopped)
    }
    private func fastProgress(at date: Date) -> QuotaProgress {
        .init(requestID: UUID(), sequence: 0, outputCharacters: 2400, activeDuration: 2, observedAt: date)
    }
    func testFailedQuiesceResumePreservesActualConcurrentWorkWithoutAnotherGeneratingEvent() async throws {
        let workspace = try fixtureWorkspace(), clock = QuotaTestClock()
        let fixture = UsageProcessFixture(workspace: workspace, panel: livePanel)
        let service = makeService(workspace: workspace, fixture: fixture, now: { clock.value }) { _ in }
        var account = fixtureAccount()
        account.windows = [.init(id: "five_hour", usedPercent: 5, observedAt: clock.value, resetsAt: clock.value.addingTimeInterval(3600))]
        let first = UUID(), second = UUID(), scope = AccountScope(account)
        try await service.start(); await service.setAccounts([account])
        await service.setAvailability(enabled: true, awake: true, online: true)
        for id in [first, second] {
            await service.setWorkState(scope: scope, sessionID: id, state: .generating, at: clock.value)
        }
        let before = await service.cadence(accountID: account.id)
        XCTAssertEqual(before.generatingSessions, 2)
        var disabled = account; disabled.state = .disabled
        await service.setAccounts([disabled])
        let suspended = await service.suspendAccount(account.id); XCTAssertTrue(suspended)
        await service.recordProgress(scope: scope, sessionID: first, progress: fastProgress(at: clock.value))
        let paused = await service.cadence(accountID: account.id); XCTAssertNil(paused.interval)
        // The inference workers refuse ordinary close. Restoring the account does not
        // cause their unchanged native generating state to be emitted again.
        await service.setAccounts([account]); await service.resumeAccount(account.id)
        let resumed = await service.cadence(accountID: account.id)
        XCTAssertEqual(resumed.generatingSessions, 2)
        XCTAssertEqual(resumed.interval!, 10, accuracy: 0.001)
        XCTAssertEqual(fixture.plans.count, 0)
        let stopped = await service.stop(); XCTAssertTrue(stopped)
    }
    func testEndedOrReplacedWorkDuringQuiesceCannotResurrectOnResume() async throws {
        for outcome in ["ended", "changed", "removed"] {
            let workspace = try fixtureWorkspace(), clock = QuotaTestClock()
            let fixture = UsageProcessFixture(workspace: workspace, panel: livePanel)
            let service = makeService(workspace: workspace, fixture: fixture, now: { clock.value }) { _ in }
            var account = fixtureAccount()
            account.windows = [.init(id: "five_hour", usedPercent: 5, observedAt: clock.value, resetsAt: clock.value.addingTimeInterval(3600))]
            let session = UUID(), scope = AccountScope(account)
            try await service.start(); await service.setAccounts([account])
            await service.setAvailability(enabled: true, awake: true, online: true)
            await service.setWorkState(scope: scope, sessionID: session, state: .generating, at: clock.value)
            var disabled = account; disabled.state = .disabled
            await service.setAccounts([disabled])
            let suspended = await service.suspendAccount(account.id); XCTAssertTrue(suspended)
            if outcome == "ended" {
                await service.setWorkState(scope: scope, sessionID: session, state: .ended, at: clock.value)
            } else if outcome == "changed" {
                account.plan = "Ultra"
                var changed = account; changed.state = .disabled
                await service.setAccounts([changed])
                await service.setWorkState(scope: scope, sessionID: session, state: .generating, at: clock.value)
            } else {
                await service.setAccounts([])
                await service.setWorkState(scope: scope, sessionID: session, state: .generating, at: clock.value)
            }
            await service.setAccounts([account]); await service.resumeAccount(account.id)
            let resumed = await service.cadence(accountID: account.id)
            XCTAssertEqual(resumed.generatingSessions, 0, outcome)
            clock.advance(121); await service.setAvailability(enabled: true, awake: true, online: true)
            let idle = await service.cadence(accountID: account.id)
            XCTAssertNil(idle.interval, outcome); XCTAssertEqual(idle.generatingSessions, 0, outcome)
            XCTAssertEqual(fixture.plans.count, 0)
            let stopped = await service.stop(); XCTAssertTrue(stopped)
        }
    }
    func testFreshNativeObservationCoalescesAnAutomaticReadWaitingForExecutable() async throws {
        let workspace = try fixtureWorkspace(), waiting = expectation(description: "Observer launch is being prepared")
        let unwanted = expectation(description: "Fresh native quota makes the dedicated read redundant"); unwanted.isInverted = true
        let fixture = UsageProcessFixture(workspace: workspace, panel: livePanel), clock = QuotaTestClock(), gate = QuotaExecutableGate()
        let service = QuotaRefreshService(workspace: workspace, executable: {
            waiting.fulfill(); return await gate.wait()
        }, helperExecutable: workspace.root.appendingPathComponent("fixture-helper"), update: { _ in }, launch: { plan in
            unwanted.fulfill(); return try fixture.launch(plan)
        }, observerTimeout: 2, now: { clock.value })
        var account = fixtureAccount()
        account.windows = [.init(id: "five_hour", usedPercent: 5, observedAt: clock.value, resetsAt: clock.value.addingTimeInterval(3600))]
        let session = UUID()
        try await service.start(); await service.setAccounts([account])
        await service.setWorkState(scope: AccountScope(account), sessionID: session, state: .generating, at: clock.value)
        await service.recordProgress(scope: AccountScope(account), sessionID: session, progress: fastProgress(at: clock.value))
        await service.setAvailability(enabled: true, awake: true, online: true)
        clock.advance(11); await service.setAvailability(enabled: true, awake: true, online: true)
        await fulfillment(of: [waiting], timeout: 30)
        await service.observe(scope: AccountScope(account), windows: [.init(id: "five_hour", usedPercent: 6, observedAt: clock.value)])
        await gate.release(workspace.root.appendingPathComponent("fixture-client"))
        await fulfillment(of: [unwanted], timeout: 0.2)
        XCTAssertEqual(fixture.plans.count, 0)
        let stopped = await service.stop(); XCTAssertTrue(stopped)
    }
    func testElapsedResetRefreshesBeforeOrdinaryPeriodicDeadline() async throws {
        let workspace = try fixtureWorkspace(), first = expectation(description: "Initial read"), second = expectation(description: "Reset read")
        let fixture = UsageProcessFixture(workspace: workspace, panel: livePanel), clock = QuotaTestClock(), counter = QuotaEventCounter()
        let service = makeService(workspace: workspace, fixture: fixture, now: { clock.value }) { update in
            if case .status(_, let status) = update, status.phase == .idle, status.lastSuccessAt != nil {
                let count = await counter.increment()
                if count == 1 { first.fulfill() }; if count == 2 { second.fulfill() }
            }
        }
        var account = fixtureAccount()
        account.windows = [.init(id: "five_hour", usedPercent: 100, observedAt: clock.value, resetsAt: clock.value.addingTimeInterval(60))]
        try await service.start(); await service.setAccounts([account]); await service.requestRefresh(accountID: account.id)
        await fulfillment(of: [first], timeout: 30)
        // A reset is read a minute after it passes, once Claude has rolled the limit over.
        clock.advance(61); await service.setAvailability(enabled: true, awake: true, online: true)
        XCTAssertEqual(fixture.plans.count, 1)
        clock.advance(60); await service.setAvailability(enabled: true, awake: true, online: true)
        await fulfillment(of: [second], timeout: 30)
        XCTAssertEqual(fixture.plans.count, 2)
        XCTAssertEqual(fixture.plans[0].directory, fixture.plans[1].directory, "Official workspace trust stays with the stable account folder.")
        XCTAssertNotEqual(fixture.plans[0].sessionID, fixture.plans[1].sessionID)
        let repeated = expectation(description: "The same official reset is not fetched twice"); repeated.isInverted = true
        fixture.onLaunch { repeated.fulfill() }
        clock.advance(120); await service.setAvailability(enabled: true, awake: true, online: true)
        await fulfillment(of: [repeated], timeout: 0.2)
        let stopped = await service.stop(); XCTAssertTrue(stopped)
        let restartedRead = expectation(description: "Reset receipt survives a restart"); restartedRead.isInverted = true
        fixture.onLaunch { restartedRead.fulfill() }
        let restarted = makeService(workspace: workspace, fixture: fixture, now: { clock.value }) { _ in }
        await restarted.setAccounts([account]); try await restarted.start()
        await restarted.setAvailability(enabled: true, awake: true, online: true)
        await fulfillment(of: [restartedRead], timeout: 0.2)
        let restartedStopped = await restarted.stop(); XCTAssertTrue(restartedStopped)
    }
    func testAccountWhoseWeekIsUsedUpIsNotReadUntilTheWeekResets() async throws {
        let workspace = try fixtureWorkspace(), back = expectation(description: "Read once the week is back")
        let fixture = UsageProcessFixture(workspace: workspace, panel: livePanel), clock = QuotaTestClock()
        let service = makeService(workspace: workspace, fixture: fixture, now: { clock.value }) { update in
            if case .status(_, let status) = update, status.phase == .idle, status.lastAttemptAt != nil, status.lastSuccessAt != nil { back.fulfill() }
        }
        var account = fixtureAccount(); account.state = .limited
        account.windows = [.init(id: "five_hour", usedPercent: 0, observedAt: clock.value, resetsAt: clock.value.addingTimeInterval(60)),
                           .init(id: "seven_day", usedPercent: 100, observedAt: clock.value, resetsAt: clock.value.addingTimeInterval(2 * 86400))]
        let early = expectation(description: "Neither its 5-hour reset nor time passing reads it"); early.isInverted = true
        fixture.onLaunch { early.fulfill() }
        await service.setAccounts([account]); try await service.start()
        for _ in 0..<8 { clock.advance(3 * 3600); await service.setAvailability(enabled: true, awake: true, online: true) }
        await fulfillment(of: [early], timeout: 0.2)
        XCTAssertEqual(fixture.plans.count, 0)
        fixture.onLaunch {}
        clock.advance(86400 + 120); await service.setAvailability(enabled: true, awake: true, online: true)
        await fulfillment(of: [back], timeout: 30)
        XCTAssertEqual(fixture.plans.count, 1)
        let stopped = await service.stop(); XCTAssertTrue(stopped)
    }
    func testAPoolOfAHundredUnusedAccountsIsReadOnlyAtAReset() async throws {
        let workspace = try fixtureWorkspace(), reset = expectation(description: "The account whose limit reset is read")
        let fixture = UsageProcessFixture(workspace: workspace, panel: livePanel), clock = QuotaTestClock()
        let start = clock.value
        let accounts = (0..<100).map { index in
            PoolAccount(plan: "Pro", state: .ready, windows: [
                .init(id: "five_hour", usedPercent: 12, observedAt: start),
                .init(id: "seven_day", usedPercent: 9, observedAt: start, resetsAt: start.addingTimeInterval(Double(3 + index) * 86400))])
        }
        let resetting = accounts[0].id
        var withReset = accounts
        withReset[0].windows[0] = .init(id: "five_hour", usedPercent: 40, observedAt: start, resetsAt: start.addingTimeInterval(36 * 3600))
        let service = makeService(workspace: workspace, fixture: fixture, now: { clock.value }) { update in
            if case .status(let scope, let status) = update, scope.accountID == resetting, status.phase == .idle, status.lastAttemptAt != nil { reset.fulfill() }
        }
        let early = expectation(description: "A day of unused accounts starts no reads"); early.isInverted = true
        fixture.onLaunch { early.fulfill() }
        await service.setAccounts(withReset); try await service.start()
        await service.setAvailability(enabled: true, awake: true, online: true)
        for _ in 0..<24 { clock.advance(3600); await service.setAvailability(enabled: true, awake: true, online: true) }
        await fulfillment(of: [early], timeout: 0.3)
        XCTAssertEqual(fixture.plans.count, 0)
        for account in accounts.prefix(5) {
            let cadence = await service.cadence(accountID: account.id); XCTAssertNil(cadence.interval)
        }
        fixture.onLaunch {}
        // A stated reset is read a minute after it passes, for an unused account too.
        clock.advance(12 * 3600 + 61); await service.setAvailability(enabled: true, awake: true, online: true)
        await fulfillment(of: [reset], timeout: 30)
        XCTAssertEqual(fixture.plans.count, 1)
        let stopped = await service.stop(); XCTAssertTrue(stopped)
    }
    func testWorkThatStopsIsReadOnceAndThenLeftAlone() async throws {
        let workspace = try fixtureWorkspace(), settled = expectation(description: "One read once work stops")
        let fixture = UsageProcessFixture(workspace: workspace, panel: livePanel), clock = QuotaTestClock(), session = UUID()
        let service = makeService(workspace: workspace, fixture: fixture, now: { clock.value }) { update in
            if case .status(_, let status) = update, status.phase == .idle, status.lastAttemptAt != nil { settled.fulfill() }
        }
        var account = fixtureAccount()
        account.windows = [.init(id: "seven_day", usedPercent: 9, observedAt: clock.value, resetsAt: clock.value.addingTimeInterval(6 * 86400))]
        try await service.start(); await service.setAccounts([account])
        await service.setAvailability(enabled: true, awake: true, online: true)
        clock.advance(5)
        await service.setWorkState(scope: AccountScope(account), sessionID: session, state: .generating, at: clock.value)
        await service.recordProgress(scope: AccountScope(account), sessionID: session, progress: fastProgress(at: clock.value))
        await service.setWorkState(scope: AccountScope(account), sessionID: session, state: .ended, at: clock.value)
        let working = await service.cadence(accountID: account.id); XCTAssertNotNil(working.interval)
        clock.advance(130); await service.setAvailability(enabled: true, awake: true, online: true)
        await fulfillment(of: [settled], timeout: 30)
        XCTAssertEqual(fixture.plans.count, 1)
        let again = expectation(description: "Left open and unused, it is not read again"); again.isInverted = true
        fixture.onLaunch { again.fulfill() }
        for _ in 0..<12 { clock.advance(1800); await service.setAvailability(enabled: true, awake: true, online: true) }
        await fulfillment(of: [again], timeout: 0.3)
        XCTAssertEqual(fixture.plans.count, 1)
        let stopped = await service.stop(); XCTAssertTrue(stopped)
    }
    func testAnAccountStartingWorkWithAnOldReadingIsReadFirst() async throws {
        let workspace = try fixtureWorkspace(), confirmed = expectation(description: "The chosen account is read")
        let fixture = UsageProcessFixture(workspace: workspace, panel: livePanel), clock = QuotaTestClock()
        var fresh = PoolAccount(plan: "Pro", state: .ready), old = PoolAccount(plan: "Pro", state: .ready)
        fresh.windows = [.init(id: "seven_day", usedPercent: 9, observedAt: clock.value, resetsAt: clock.value.addingTimeInterval(6 * 86400))]
        old.windows = [.init(id: "seven_day", usedPercent: 9, observedAt: clock.value.addingTimeInterval(-3600), resetsAt: clock.value.addingTimeInterval(6 * 86400))]
        let oldID = old.id
        let service = makeService(workspace: workspace, fixture: fixture, now: { clock.value }) { update in
            if case .status(let scope, let status) = update, scope.accountID == oldID, status.phase == .idle, status.lastAttemptAt != nil { confirmed.fulfill() }
        }
        try await service.start(); await service.setAccounts([fresh, old])
        await service.setAvailability(enabled: true, awake: true, online: true)
        let trusted = expectation(description: "A reading under ten minutes old is trusted"); trusted.isInverted = true
        fixture.onLaunch { trusted.fulfill() }
        await service.confirmBeforeUse(accountID: fresh.id)
        await service.setWorkState(scope: AccountScope(fresh), sessionID: UUID(), state: .generating, at: clock.value)
        await fulfillment(of: [trusted], timeout: 0.2)
        XCTAssertEqual(fixture.plans.count, 0)
        fixture.onLaunch {}
        await service.setWorkState(scope: AccountScope(old), sessionID: UUID(), state: .generating, at: clock.value)
        await fulfillment(of: [confirmed], timeout: 30)
        XCTAssertEqual(fixture.plans.count, 1)
        let stopped = await service.stop(); XCTAssertTrue(stopped)
    }
    func testAccountsAreStaggeredAndSleepPausesNewObservers() async throws {
        let workspace = try fixtureWorkspace(), first = expectation(description: "First account read"), second = expectation(description: "Second account read")
        let fixture = UsageProcessFixture(workspace: workspace, panel: livePanel), clock = QuotaTestClock(), counter = QuotaEventCounter()
        let service = makeService(workspace: workspace, fixture: fixture, now: { clock.value }) { update in
            if case .status(_, let status) = update, status.phase == .idle, status.lastSuccessAt != nil {
                let count = await counter.increment()
                if count == 1 { first.fulfill() }; if count == 2 { second.fulfill() }
            }
        }
        let a = fixtureAccount(), b = PoolAccount(plan: "Pro", state: .ready)
        try await service.start(); await service.setAccounts([a, b])
        await service.setAvailability(enabled: true, awake: false, online: true)
        XCTAssertEqual(fixture.plans.count, 0)
        await service.setAvailability(enabled: true, awake: true, online: true)
        await fulfillment(of: [first], timeout: 30)
        clock.advance(1); await service.setAvailability(enabled: true, awake: true, online: true)
        XCTAssertEqual(fixture.plans.count, 1)
        clock.advance(2); await service.setAvailability(enabled: true, awake: true, online: true)
        await fulfillment(of: [second], timeout: 30)
        XCTAssertEqual(fixture.plans.count, 2)
        XCTAssertNotEqual(fixture.plans[0].environment["CLAUDE_CONFIG_DIR"], fixture.plans[1].environment["CLAUDE_CONFIG_DIR"])
        let stopped = await service.stop(); XCTAssertTrue(stopped)
    }
    func testSuspendInvalidatesAnObserverWaitingForManagedExecutable() async throws {
        let workspace = try fixtureWorkspace(), waiting = expectation(description: "Executable lookup pending")
        let unexpectedLaunch = expectation(description: "Old generation must not launch"); unexpectedLaunch.isInverted = true
        let fixture = UsageProcessFixture(workspace: workspace, panel: livePanel), gate = QuotaExecutableGate()
        let service = QuotaRefreshService(workspace: workspace, executable: {
            waiting.fulfill(); return await gate.wait()
        }, helperExecutable: workspace.root.appendingPathComponent("fixture-helper"), update: { _ in }, launch: { plan in
            unexpectedLaunch.fulfill(); return try fixture.launch(plan)
        }, observerTimeout: 2)
        let account = fixtureAccount()
        try await service.start(); await service.setAccounts([account]); await service.requestRefresh(accountID: account.id)
        await fulfillment(of: [waiting], timeout: 30)
        let suspended = await service.suspendAccount(account.id); XCTAssertTrue(suspended)
        await service.resumeAccount(account.id)
        await gate.release(workspace.root.appendingPathComponent("fixture-client"))
        await fulfillment(of: [unexpectedLaunch], timeout: 0.2)
        XCTAssertEqual(fixture.plans.count, 0)
        let stopped = await service.stop(); XCTAssertTrue(stopped)
    }
    func testPlanChangeWhileReadingDeliveryWaitsDoesNotPublishOldSuccessInNewScope() async throws {
        let workspace = try fixtureWorkspace(), delivered = expectation(description: "Old plan reading queued")
        let fixture = UsageProcessFixture(workspace: workspace, panel: livePanel), log = QuotaUpdateLog()
        let gate = AsyncStream<Void>.makeStream()
        let service = makeService(workspace: workspace, fixture: fixture) { update in
            await log.append(update)
            if case .reading = update {
                delivered.fulfill()
                for await _ in gate.stream { break }
            }
        }
        let original = fixtureAccount()
        try await service.start(); await service.setAccounts([original])
        await service.requestRefresh(accountID: original.id)
        await fulfillment(of: [delivered], timeout: 30)
        var replacement = original; replacement.plan = "Ultra"
        await service.setAccounts([replacement])
        await service.observe(scope: AccountScope(original), windows: [
            .init(id: "five_hour", usedPercent: 10, observedAt: Date())
        ])
        gate.continuation.yield(()); gate.continuation.finish()
        let stopped = await service.stop(); XCTAssertTrue(stopped)

        let status = await service.statuses()[original.id]
        XCTAssertNil(status?.lastSuccessAt)
        XCTAssertNil(status?.failure)
        let updates = await log.updates
        let scopes = updates.compactMap { update -> AccountScope? in
            if case .reading(let scope, _) = update { return scope }; return nil
        }
        XCTAssertEqual(scopes, [AccountScope(original)])
        XCTAssertFalse(updates.contains { update in
            if case .status(let scope, let value) = update {
                return scope == AccountScope(replacement) && value.lastSuccessAt != nil
            }
            return false
        })
        XCTAssertEqual(fixture.plans.count, 1)
    }
    func testUnsavableRefreshStateDoesNotStartARead() async throws {
        let workspace = try fixtureWorkspace(), failed = expectation(description: "Persistence failure surfaced")
        let fixture = UsageProcessFixture(workspace: workspace, panel: livePanel)
        let service = makeService(workspace: workspace, fixture: fixture) { update in
            if case .status(_, let status) = update, status.failure == .storage { failed.fulfill() }
        }
        let account = fixtureAccount()
        try await service.start(); await service.setAccounts([account])
        let stateFile = workspace.root.appendingPathComponent("quota-refresh.json")
        try workspace.remove(stateFile)
        try workspace.createDirectory(at: stateFile)
        await service.requestRefresh(accountID: account.id)
        await fulfillment(of: [failed], timeout: 30)
        XCTAssertEqual(fixture.plans.count, 0)
        let stopped = await service.stop(); XCTAssertTrue(stopped)
    }

    private func fixtureAccount() -> PoolAccount {
        .init(id: UUID(uuidString: "0a1b2c3d-1111-4aaa-8bbb-000000000001")!, email: nil, plan: "Pro", state: .ready)
    }
    private func fixtureWorkspace() throws -> OwnedWorkspace {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = base.appendingPathComponent(".build/quota-fixtures/\(UUID().uuidString)")
        let workspace = OwnedWorkspace(root: root); try workspace.prepare(); return workspace
    }
    /// `observerTimeout` bounds one reading. Generous by default, so a slow machine still finishes the
    /// first-run screens; a test about a reading that cannot finish passes a short one.
    private func makeService(workspace: OwnedWorkspace, fixture: UsageProcessFixture, now: @escaping @Sendable () -> Date = { Date() },
                             observerTimeout: TimeInterval = 20, update: @escaping QuotaRefreshService.Update) -> QuotaRefreshService {
        QuotaRefreshService(workspace: workspace, executable: { workspace.root.appendingPathComponent("fixture-client") },
                            helperExecutable: workspace.root.appendingPathComponent("fixture-helper"), update: update,
                            launch: { try fixture.launch($0) }, observerTimeout: observerTimeout, now: now)
    }
}

private actor QuotaUpdateLog {
    var updates: [QuotaRefreshUpdate] = []
    var readings: [[QuotaWindow]] = []
    func append(_ update: QuotaRefreshUpdate) {
        updates.append(update)
        if case .reading(_, let windows) = update { readings.append(windows) }
    }
}
private actor QuotaEventCounter {
    private var count = 0
    func increment() -> Int { count += 1; return count }
}
private actor QuotaExecutableGate {
    private var continuation: CheckedContinuation<URL, Never>?
    func wait() async -> URL { await withCheckedContinuation { continuation = $0 } }
    func release(_ url: URL) { continuation?.resume(returning: url); continuation = nil }
}
private final class QuotaTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date()
    var value: Date { lock.withLock { date } }
    func advance(_ interval: TimeInterval) { lock.withLock { date = date.addingTimeInterval(interval) } }
}
private final class UsageProcessFixture: @unchecked Sendable {
    private let lock = NSLock()
    private let workspace: OwnedWorkspace, panel: String
    private let deferExit: Bool, blockCleanup: Bool
    /// A child that does not end on Ctrl-C. Pool must then report it, never escalate.
    var ignoresInterrupt = false
    /// As a real child: its exit reaches the observer later, and a key sent meanwhile fails.
    var exitEventLags = false
    private var gone = false
    /// A child left on a screen where the typed /exit does nothing.
    var ignoresExit = false
    private var interrupts: [Date] = []
    var interruptCount: Int { lock.withLock { interrupts.count } }
    private var needsTrust: Bool
    /// First-run screens of a freshly signed-in account folder, in the official order.
    private var firstRun: [String]
    private var current: SessionLaunch?
    private var output: AsyncStream<PTYEvent>.Continuation?
    private var launched: [SessionLaunch] = []
    private var sent: [Data] = []
    private var exits = 0
    private var launchObserver: (@Sendable () -> Void)?
    var plans: [SessionLaunch] { lock.withLock { launched } }
    var commands: [Data] { lock.withLock { sent } }
    var exitCount: Int { lock.withLock { exits } }
    func onLaunch(_ observer: @escaping @Sendable () -> Void) { lock.withLock { launchObserver = observer } }
    init(workspace: OwnedWorkspace, panel: String, needsTrust: Bool = false, firstRun: [String] = [], deferExit: Bool = false, blockCleanup: Bool = false) {
        self.workspace = workspace; self.panel = panel; self.needsTrust = needsTrust; self.firstRun = firstRun
        self.deferExit = deferExit; self.blockCleanup = blockCleanup
    }
    func launch(_ plan: SessionLaunch) throws -> SessionTransport {
        let stream = AsyncStream<PTYEvent>.makeStream()
        lock.withLock { launched.append(plan); current = plan; output = stream.continuation }
        lock.withLock { launchObserver }?()
        if let screen = lock.withLock({ firstRun.first }) {
            stream.continuation.yield(.output(Data(Self.draw(screen).utf8)))
        } else if needsTrust {
            stream.continuation.yield(.output(Data("Trust this workspace?".utf8)))
            try hook("PermissionRequest", plan: plan)
        } else {
            stream.continuation.yield(.output(Data("> ".utf8))); try hook("SessionStart", plan: plan)
        }
        if blockCleanup { try workspace.write(Data("fixture".utf8), to: plan.runDirectory.appendingPathComponent("unexpected.txt")) }
        return SessionTransport(events: stream.stream, write: { try self.write($0) }, interrupt: { try self.interrupt() }, exit: { try self.exit() }, waitForExit: {
            guard self.lock.withLock({ self.output == nil }) else { throw RuntimeError.processUnresponsive }
            return 0
        })
    }
    private func write(_ data: Data) throws {
        let state = lock.withLock { () -> (SessionLaunch?, AsyncStream<PTYEvent>.Continuation?) in sent.append(data); return (current, output) }
        if let screen = lock.withLock({ firstRun.first }) {
            let answered: Bool
            switch screen {
            case "theme", "notes", "trust-yes": answered = data == Data("\r".utf8)
            case "trust-no": answered = data == Data("\u{1b}[B".utf8)
            default: answered = false
            }
            guard answered else { return }
            let next = lock.withLock { () -> String? in firstRun.removeFirst(); return firstRun.first }
            if let next { state.1?.yield(.output(Data(Self.draw(next).utf8))) }
            else if let plan = state.0 { try hook("SessionStart", plan: plan); state.1?.yield(.output(Data("\u{1b}[2J\u{1b}[H> ".utf8))) }
        } else if data == Data("y\r".utf8), let plan = state.0 {
            lock.withLock { needsTrust = false }
            try hook("SessionStart", plan: plan); state.1?.yield(.output(Data("\u{1b}[2J\u{1b}[H> ".utf8)))
        } else if data == Data("/usage".utf8) { state.1?.yield(.output(Data("\r> /usage".utf8))) }
        else if data == Data([13]) { state.1?.yield(.output(Data(("\u{1b}[2J\u{1b}[H" + panel.replacingOccurrences(of: "\n", with: "\r\n")).utf8))) }
        else if data.first == 27 { state.1?.yield(.output(Data("\u{1b}[2J\u{1b}[H> ".utf8))) }
    }
    /// Like the official client, a second Ctrl-C shortly after the first ends the process.
    private func interrupt() throws {
        if lock.withLock({ gone }) { completeExit(); throw RuntimeError.processExited }
        let doubled = lock.withLock { () -> Bool in
            let previous = interrupts.last; interrupts.append(Date())
            return !ignoresInterrupt && previous.map { Date().timeIntervalSince($0) < 1 } == true
        }
        if doubled {
            if exitEventLags { lock.withLock { gone = true } } else { completeExit() }
        }
    }
    private static func draw(_ screen: String) -> String {
        let text: String
        switch screen {
        case "theme": text = "Let's get started.\r\n\r\nChoose the text style that looks best with your terminal\r\n❯ 1. Dark mode"
        case "notes": text = "Security notes:\r\n 1. Claude can make mistakes\r\n\r\nPress Enter to continue…"
        case "trust-no": text = "Do you trust the files in this folder?\r\n  Yes, I trust this folder\r\n❯ No, exit"
        case "trust-yes": text = "Do you trust the files in this folder?\r\n❯ Yes, I trust this folder\r\n  No, exit"
        case "login": text = "Select login method:\r\n❯ 1. Claude account with subscription"
        default: text = screen
        }
        return "\u{1b}[2J\u{1b}[H" + text
    }
    private func exit() throws {
        let (plan, ignored) = lock.withLock { exits += 1; return (current, ignoresExit) }
        if ignored { return }
        if deferExit, let plan { try hook("SessionEnd", plan: plan) }
        else { completeExit() }
    }
    func completeExit() {
        let sink = lock.withLock { () -> AsyncStream<PTYEvent>.Continuation? in let s = output; output = nil; return s }
        sink?.yield(.exited(0)); sink?.finish()
    }
    private func hook(_ event: String, plan: SessionLaunch) throws {
        let file = plan.runDirectory.appendingPathComponent("fixture-hook-\(UUID().uuidString).json")
        try workspace.write(JSONValue.object(["session_id": .string(plan.sessionID.uuidString), "source": .string("startup")]).encoded(), to: file)
        let input = try FileHandle(forReadingFrom: file); defer { try? input.close() }
        try EngineHelpers.hook(directory: plan.runDirectory, event: event, input: input)
        try workspace.remove(file)
    }
}
