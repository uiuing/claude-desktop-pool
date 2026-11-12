import Foundation
import CryptoKit
import XCTest
import PoolCore
import PoolEngine
import PoolPrivacy
import PoolRuntime
import PoolGateway
@testable import ClaudePool

@MainActor
final class AppServicesTests: XCTestCase {
    /// What the person does is logged by name with its outcome, and in the full log with what it set;
    /// what is typed into a terminal (a sign-in code goes that way) is only counted.
    func testActionsAreLoggedAndTerminalInputIsNot() {
        let lock = NSLock()
        nonisolated(unsafe) var lines: [Data] = []
        DevRecord.install { entry in lock.withLock { lines.append(entry.line) } }
        defer { DevRecord.install(nil) }
        let policy = RoutingPolicy(reservePercent: 15), began = Date()
        AppServices.recordAction(.routePolicy(policy), began: began, failure: nil)
        AppServices.recordAction(.sendTerminalInput("code-synthetic-4417"), began: began, failure: nil)
        AppServices.recordAction(.measureFullLog, began: began, failure: nil)
        let all = lock.withLock { lines }
        XCTAssertFalse(all.contains { String(decoding: $0, as: UTF8.self).contains("code-synthetic-4417") })
        let records = all.compactMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        let logged = records.filter { $0["kind"] == .string("log.ui.action") }.compactMap { $0["data"]?["action"]?.stringValue }
        XCTAssertEqual(logged, ["routePolicy", "sendTerminalInput"], "Reading the full log's size is not an action")
        let set = records.first { $0["kind"] == .string("ui.action") && $0["action"] == .string("routePolicy") }
        XCTAssertEqual(set?["data"]?["routing_policy"]?["reservePercent"], .number(15))
        let typed = records.first { $0["kind"] == .string("ui.action") && $0["action"] == .string("sendTerminalInput") }
        XCTAssertEqual(typed?["data"]?["chars"], .number(19))
    }

    private func fixture() throws -> OwnedWorkspace {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/app-services-fixtures/\(UUID().uuidString)")
        let workspace = OwnedWorkspace(root: root)
        try workspace.prepare()
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return workspace
    }

    private func inertDependencies() -> AppServiceDependencies {
        var dependencies = AppServiceDependencies()
        dependencies.observeSystemEvents = false
        dependencies.showWindow = {}
        dependencies.preparePrivacyAutomatically = false
        dependencies.checkRuntimeUpdatesAutomatically = false
        dependencies.installRuntimeAutomatically = false
        dependencies.checkAccountsAutomatically = false
        dependencies.privacyModelFactory = { _ in AppPrivacyModel() }
        dependencies.quotaLaunch = { _ in throw QuotaRefreshFailure.unavailable }
        return dependencies
    }

    private func application(accounts: [PoolAccount] = [], installed: Bool = true, connected: Bool = false, desktop: AppDesktopFixture? = nil,
                             privacy: AppPrivacyModel = AppPrivacyModel(), workerFactory: PoolCoordinator.WorkerFactory? = nil,
                             quotaTrust: Bool? = nil, quotaPanel: String = AppQuotaFixture.defaultPanel,
                             clock: AppTestClock? = nil, automaticUpdates: Bool = false,
                             updateDrainLimit: TimeInterval? = nil) async throws -> FixtureApplication {
        let workspace = try fixture(), downloads = AppReleaseDownloads(), auth = try AppAuthFixture(workspace: workspace)
        try await downloads.publish("2.1.300")
        let runtime = ManagedRuntime(workspace: workspace, downloader: downloads)
        if installed { _ = try await runtime.installLatest() }
        await downloads.resetRequests()
        try await PoolStore(workspace: workspace).save(PoolLibrary(accounts: accounts))
        let desktop = try desktop ?? AppDesktopFixture(workspace: workspace)
        if connected { try desktop.connect() }
        for account in accounts {
            try auth.setStatus(account.id, email: account.email ?? "mi•••ella@example.com", plan: account.plan?.lowercased() ?? "pro")
        }
        var dependencies = inertDependencies()
        dependencies.runtimeFactory = { _ in runtime }
        dependencies.clientFactory = { _, _ in auth.client }
        dependencies.privacyModelFactory = { _ in privacy }
        dependencies.checkRuntimeUpdatesAutomatically = automaticUpdates
        if let updateDrainLimit { dependencies.updateDrainLimit = updateDrainLimit }
        if let clock { dependencies.now = { clock.value } }
        dependencies.workerFactory = workerFactory
        dependencies.gatewayPort = 0
        dependencies.desktop = desktop.control
        let quota = quotaTrust.map { AppQuotaFixture(workspace: workspace, needsTrust: $0, panel: quotaPanel) }
        if let quota { dependencies.quotaLaunch = { try quota.launch($0) } }
        let model = PoolAppModel(), services = AppServices(model: model, workspace: workspace, dependencies: dependencies)
        await services.load()
        addTeardownBlock { @MainActor in
            let ids = model.snapshot.accounts.map(\.id) + [model.pendingSignInID].compactMap { $0 }
            for id in ids {
                if let child = auth.client.activeProcess(accountID: id) {
                    try? child.write(Data("fixture-finish\n".utf8))
                    _ = try? await child.waitForExit(timeout: 2)
                }
            }
            if let id = model.pendingSignInID { await services.handle(.closeTerminal(id)) }
            for session in model.snapshot.sessions where session.state != .ended {
                await services.handle(.requestSessionExit(session.id))
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(4))
            var closed = await services.prepareToQuit()
            while !closed, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
                closed = await services.prepareToQuit()
            }
            XCTAssertTrue(closed, "The fixture must close its owned services before deleting their files.")
        }
        return FixtureApplication(workspace: workspace, desktop: desktop, model: model, services: services, auth: auth,
                                  downloads: downloads, runtime: runtime, privacy: privacy, quota: quota)
    }

    private func reopen(_ app: FixtureApplication, clock: AppTestClock) async -> FixtureApplication {
        let closed = await app.services.prepareToQuit(); XCTAssertTrue(closed)
        let runtime = app.runtime, auth = app.auth, privacy = app.privacy
        var dependencies = inertDependencies()
        dependencies.runtimeFactory = { _ in runtime }
        dependencies.clientFactory = { _, _ in auth.client }
        dependencies.privacyModelFactory = { _ in privacy }
        dependencies.checkRuntimeUpdatesAutomatically = true
        dependencies.now = { clock.value }
        dependencies.gatewayPort = 0
        dependencies.desktop = app.desktop.control
        let model = PoolAppModel(), services = AppServices(model: model, workspace: app.workspace, dependencies: dependencies)
        await services.load()
        addTeardownBlock { @MainActor in
            let closed = await services.prepareToQuit(); XCTAssertTrue(closed)
        }
        return FixtureApplication(workspace: app.workspace, desktop: app.desktop, model: model, services: services, auth: app.auth,
                                  downloads: app.downloads, runtime: app.runtime, privacy: app.privacy, quota: nil)
    }

    private func eventually(_ description: String, file: StaticString = #filePath, line: UInt = #line,
                            _ condition: @escaping @MainActor () async -> Bool) async {
        // Returns as soon as the condition holds; the bound only has to outlast a busy CI machine
        // running every suite at once, where a quota read's first steps took longer than 4 s.
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail(description, file: file, line: line)
    }

    private func request(_ app: FixtureApplication, text: String) async throws -> (Int, JSONValue) {
        try await request(app, body: .init(model: "claude-sonnet", messages: [.init(role: "user", content: .string(text))], tools: [.init(name: "Read", inputSchema: .object(["type": .string("object")]))], stream: false))
    }

    private func request(_ app: FixtureApplication, body: BridgeRequest) async throws -> (Int, JSONValue) {
        let port = try XCTUnwrap(app.services.listeningPort)
        let token = String(decoding: try app.workspace.read(app.workspace.root.appendingPathComponent("gateway-key")), as: UTF8.self)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/messages")!)
        request.httpMethod = "POST"; request.timeoutInterval = 4
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, try JSONDecoder().decode(JSONValue.self, from: data))
    }

    func testUnsupportedRuntimeStillLoadsProfileAndAllowsPassiveQuotaControls() async throws {
        let workspace = try fixture(), store = PoolStore(workspace: workspace)
        let account = PoolAccount(email: "mi•••ella@example.com", plan: "Pro", state: .ready)
        try await store.save(PoolLibrary(accounts: [account]))
        let desktop = try AppDesktopFixture(workspace: workspace); try desktop.connect()
        var dependencies = inertDependencies(); dependencies.desktop = desktop.control
        try workspace.write(JSONSerialization.data(withJSONObject: ["version": "2.1.298", "platform": RuntimePlatform.current.rawValue]),
                            to: workspace.root.appendingPathComponent("runtime/current.json"))
        let model = PoolAppModel(), services = AppServices(model: model, workspace: workspace, dependencies: dependencies)
        await services.load()
        XCTAssertEqual(model.runtime.phase, .failed)
        XCTAssertFalse(model.snapshot.executableReady)
        XCTAssertEqual(model.snapshot.desktop, .connected)
        XCTAssertEqual(model.snapshot.accounts, [account])
        XCTAssertEqual(model.quotaRefresh[account.id]?.phase, .idle)
        XCTAssertEqual(model.quotaRefresh[account.id]?.busy, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.root.appendingPathComponent("runs").path))
        let closed = await services.prepareToQuit()
        XCTAssertTrue(closed)
    }

    func testStartupCanRetryAfterAnUnreadableLibraryIsRepaired() async throws {
        let workspace = try fixture()
        let original = Data("{invalid".utf8)
        let libraryFile = workspace.root.appendingPathComponent("library.json")
        try workspace.write(original, to: libraryFile)
        let desktop = try AppDesktopFixture(workspace: workspace)
        var dependencies = inertDependencies(); dependencies.desktop = desktop.control
        let model = PoolAppModel(), services = AppServices(model: model, workspace: workspace, dependencies: dependencies)
        await services.load()
        XCTAssertEqual(model.snapshot.mode, .attention)
        XCTAssertEqual(try workspace.read(libraryFile), original)
        let account = PoolAccount(email: "sa•••ahmad@example.org", plan: "Pro", state: .ready)
        try await PoolStore(workspace: workspace).save(PoolLibrary(accounts: [account]))
        try desktop.connect()
        await services.load()
        XCTAssertEqual(model.snapshot.accounts, [account])
        XCTAssertEqual(model.snapshot.desktop, .connected)
        XCTAssertEqual(model.snapshot.mode, .stopped)
        XCTAssertEqual(model.quotaRefresh[account.id]?.phase, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.root.appendingPathComponent("runs").path))
        let closed = await services.prepareToQuit()
        XCTAssertTrue(closed)
    }

    func testRoutingAndSettingsEditsPersistAcrossRestartWithoutStartingAClient() async throws {
        let workspace = try fixture(), store = PoolStore(workspace: workspace)
        let a = PoolAccount(email: "mi•••ella@example.com", plan: "Pro", state: .ready)
        let b = PoolAccount(email: "sa•••ahmad@example.org", plan: "Ultra", state: .ready)
        try await store.save(PoolLibrary(accounts: [a, b]))
        let model = PoolAppModel(), services = AppServices(model: model, workspace: workspace, dependencies: inertDependencies())
        await services.load()
        let policy = RoutingPolicy(strategy: .ordered, accountOrder: [b.id, a.id], reservePercent: 17)
        var refresh = model.preferences.quotaRefresh
        refresh.burstInterval = 15
        refresh.confirmAfterReset = false
        await services.handle(.routePolicy(policy))
        await services.handle(.quotaRefreshPreferences(refresh))
        await services.handle(.language("zh-Hans"))
        await services.handle(.language("unsupported-language"))
        let saved = try await store.load()
        XCTAssertEqual(saved.preferences.routingPolicy, policy)
        XCTAssertEqual(saved.preferences.quotaRefresh, refresh)
        XCTAssertEqual(saved.preferences.language, "zh-Hans")
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.root.appendingPathComponent("runs").path))
        let closed = await services.prepareToQuit(); XCTAssertTrue(closed)

        let restoredModel = PoolAppModel(), restored = AppServices(model: restoredModel, workspace: workspace, dependencies: inertDependencies())
        await restored.load()
        XCTAssertEqual(restoredModel.preferences, saved.preferences)
        XCTAssertEqual(restoredModel.snapshot.accounts, [a, b])
        XCTAssertFalse(restoredModel.snapshot.executableReady)
        XCTAssertEqual(restoredModel.snapshot.mode, .stopped)
        let restoredClosed = await restored.prepareToQuit(); XCTAssertTrue(restoredClosed)
    }

    func testInvalidControlsAndFailedSaveDoNotPublishUnsavedPreferences() async throws {
        let workspace = try fixture(), store = PoolStore(workspace: workspace)
        try await store.save(PoolLibrary())
        let model = PoolAppModel(), services = AppServices(model: model, workspace: workspace, dependencies: inertDependencies())
        await services.load()
        let initial = model.preferences
        var invalidRefresh = initial.quotaRefresh; invalidRefresh.burstInterval = 1
        await services.handle(.quotaRefreshPreferences(invalidRefresh))
        await services.handle(.routePolicy(.init(reservePercent: 26)))
        XCTAssertEqual(model.preferences, initial)

        let libraryFile = workspace.root.appendingPathComponent("library.json")
        try workspace.remove(libraryFile)
        try workspace.createDirectory(at: libraryFile)
        await services.handle(.language("zh-Hans"))
        XCTAssertEqual(model.preferences, initial)
        XCTAssertNotNil(model.notice)
        XCTAssertFalse(model.isWorking)
        try FileManager.default.removeItem(at: libraryFile)
        await services.handle(.language("zh-Hans"))
        let saved = try await store.load()
        XCTAssertEqual(saved.preferences.language, "zh-Hans")
        XCTAssertEqual(model.preferences, saved.preferences)
        let closed = await services.prepareToQuit(); XCTAssertTrue(closed)
    }

    func testFailedFirstLoginDoesNotPersistAnAccountOrKeepPendingState() async throws {
        let workspace = try fixture(), model = PoolAppModel()
        let services = AppServices(model: model, workspace: workspace, dependencies: inertDependencies())
        await services.handle(.addAccount)
        let saved = try await PoolStore(workspace: workspace).load()
        XCTAssertTrue(saved.accounts.isEmpty)
        XCTAssertEqual(model.snapshot.accounts, saved.accounts)
        XCTAssertNil(model.pendingSignInID)
        XCTAssertNil(model.terminal)
        XCTAssertNotNil(model.notice)
        XCTAssertFalse(model.isWorking)
        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.root.appendingPathComponent("runs").path))
        let closed = await services.prepareToQuit(); XCTAssertTrue(closed)
    }

    func testDemoServiceActionsNeverCreatePersistenceOrNativeSessions() async throws {
        let workspace = try fixture(), model = PoolAppModel.demoModel()
        let services = AppServices(model: model, workspace: workspace, dependencies: inertDependencies())
        let accountID = try XCTUnwrap(model.snapshot.accounts.first?.id)
        let sessionID = try XCTUnwrap(model.snapshot.sessions.first?.id)
        let before = try workspace.entries(in: workspace.root).map(\.lastPathComponent).sorted()
        let actions: [UIAction] = [.installRuntime, .checkRuntimeUpdate, .updateRuntime, .rollbackRuntime, .addAccount,
            .signIn(accountID), .checkAccount(accountID), .removeAccount(accountID), .connectDesktop, .menuBarPlan("plan:Pro"),
            .sendTerminalInput("fixture"), .sendTerminalKey("\r"), .cancelSession(sessionID),
            .requestSessionExit(sessionID), .language("zh-Hans"), .routePolicy(.init(strategy: .ordered)),
            .refreshQuota(accountID), .quotaRefreshPreferences(.init(quietInterval: 240)),
            .installPrivacyModel, .previewPrivacy("Synthetic preview"), .clearPrivacyPreview, .closeTerminal(sessionID)]
        for action in actions { await services.handle(action) }
        XCTAssertEqual(try workspace.entries(in: workspace.root).map(\.lastPathComponent).sorted(), before)
        XCTAssertFalse(model.isWorking)
        let closed = await services.prepareToQuit(); XCTAssertTrue(closed)
    }

    func testRuntimeActionsInstallUpdatePreserveFailureAndRollbackPresentation() async throws {
        let app = try await application(installed: false)
        XCTAssertFalse(app.model.snapshot.executableReady)
        await app.services.handle(.installRuntime)
        XCTAssertEqual(app.model.runtime.phase, .ready)
        XCTAssertEqual(app.model.runtime.installedVersion, "2.1.300")
        XCTAssertTrue(app.model.snapshot.executableReady)
        try await app.downloads.publish("2.1.301")
        await app.services.handle(.checkRuntimeUpdate)
        XCTAssertEqual(app.model.runtime.phase, .updateAvailable)
        XCTAssertEqual(app.model.runtime.availableVersion, "2.1.301")
        await app.services.handle(.updateRuntime)
        XCTAssertEqual(app.model.runtime.installedVersion, "2.1.301")
        XCTAssertEqual(app.model.runtime.previousVersion, "2.1.300")
        await app.downloads.setFailure(true)
        await app.services.handle(.updateRuntime)
        XCTAssertEqual(app.model.runtime.phase, .failed)
        XCTAssertEqual(app.model.runtime.installedVersion, "2.1.301")
        XCTAssertTrue(app.model.snapshot.executableReady)
        XCTAssertFalse(app.model.isWorking)
        await app.services.handle(.rollbackRuntime)
        XCTAssertEqual(app.model.runtime.phase, .ready)
        XCTAssertEqual(app.model.runtime.installedVersion, "2.1.300")
        let current = try await app.runtime.current()
        XCTAssertEqual(current?.version, "2.1.300")
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.workspace.root.appendingPathComponent("runs").path))
    }

    func testLoginCanReopenItsOriginalProcessAndUsesOnlyOfficialReturnedIdentity() async throws {
        let app = try await application()
        await app.services.handle(.addAccount)
        let id = try XCTUnwrap(app.model.pendingSignInID)
        let child = try XCTUnwrap(app.auth.client.activeProcess(accountID: id))
        XCTAssertTrue(app.model.snapshot.accounts.isEmpty)
        let before = try await PoolStore(workspace: app.workspace).load()
        XCTAssertTrue(before.accounts.isEmpty)
        XCTAssertFalse(app.model.hasSignedInAccount)
        await eventually("The synthetic login prompt did not arrive") { app.model.terminal?.output.contains("Synthetic sign-in") == true }
        app.model.terminal = nil
        await app.services.handle(.addAccount)
        XCTAssertEqual(app.model.pendingSignInID, id)
        XCTAssertEqual(app.model.terminal?.id, id)
        XCTAssertTrue(app.model.terminal?.output.contains("Synthetic sign-in") == true)
        XCTAssertEqual(app.auth.client.activeProcess(accountID: id)?.processID, child.processID)
        XCTAssertEqual(try app.auth.commands(id).filter { $0 == "auth login" }.count, 1)
        try app.auth.setStatus(id, email: "mi•••ella@example.com", plan: "ultra")
        await app.services.handle(.sendTerminalInput("finish synthetic login"))
        await eventually("Official status was not applied after login exit") {
            app.model.snapshot.accounts.first?.state == .ready && app.model.pendingSignInID == nil
        }
        XCTAssertEqual(app.model.snapshot.accounts.first?.email, "mi•••ella@example.com")
        XCTAssertEqual(app.model.snapshot.accounts.first?.plan, "Ultra")
        XCTAssertEqual(app.model.snapshot.accounts.first?.id, id)
        XCTAssertNil(app.model.pendingSignInID)
        XCTAssertTrue(app.model.hasSignedInAccount)
        XCTAssertNil(app.model.terminal, "A completed sign-in closes its ended terminal")
        XCTAssertEqual(app.model.notice, app.model.t("Signed in as {0}.", "mi•••ella@example.com"))
        let saved = try await PoolStore(workspace: app.workspace).load()
        XCTAssertEqual(saved.accounts, app.model.snapshot.accounts)
    }

    func testAccountChecksClearChangedPlanQuotaAndKeepFreeDistinctFromSignOut() async throws {
        let now = Date(), account = PoolAccount(email: "mi•••ella@example.com", plan: "Pro", state: .ready,
            windows: [.init(id: "five_hour", usedPercent: 80, observedAt: now, resetsAt: now.addingTimeInterval(3_600))])
        let app = try await application(accounts: [account])
        try app.auth.setStatus(account.id, plan: "ultra")
        await app.services.handle(.checkAccount(account.id))
        XCTAssertEqual(app.model.snapshot.accounts.first?.plan, "Ultra")
        XCTAssertTrue(app.model.snapshot.accounts.first?.windows.isEmpty == true)
        let statusFile = try app.workspace.accountDirectory(account.id).appendingPathComponent("fixture-status.json")
        try app.workspace.write(Data("{invalid synthetic status".utf8), to: statusFile)
        await app.services.handle(.checkAccount(account.id))
        XCTAssertEqual(app.model.snapshot.accounts.first?.plan, "Ultra")
        XCTAssertEqual(app.model.snapshot.accounts.first?.state, .needsAttention)
        XCTAssertFalse(app.model.notice?.contains("invalid synthetic status") == true)
        try app.auth.setStatus(account.id, plan: "future-plan")
        await app.services.handle(.checkAccount(account.id))
        XCTAssertEqual(app.model.snapshot.accounts.first?.plan, "Plan unknown")
        XCTAssertEqual(app.model.snapshot.accounts.first?.state, .needsAttention)
        try app.auth.setStatus(account.id, plan: "free")
        await app.services.handle(.checkAccount(account.id))
        XCTAssertEqual(app.model.snapshot.accounts.first?.state, .subscriptionRequired)
        XCTAssertEqual(app.model.snapshot.accounts.first?.email, account.email)
        XCTAssertTrue(app.model.readyAccounts.isEmpty)
        try app.workspace.remove(statusFile)
        await app.services.handle(.checkAccount(account.id))
        XCTAssertEqual(app.model.snapshot.accounts.first?.state, .signedOut)
        XCTAssertEqual(app.model.snapshot.accounts.first?.plan, "Free")
    }

    func testDuplicateSignInIsExcludedAndFailedLogoutRetainsAccount() async throws {
        let a = PoolAccount(email: "mi•••ella@example.com", plan: "Pro", state: .ready)
        let b = PoolAccount(email: "sa•••ahmad@example.org", plan: "Pro", state: .ready)
        let app = try await application(accounts: [a, b])
        try app.auth.setStatus(b.id, email: a.email!)
        await app.services.handle(.checkAccount(b.id))
        XCTAssertEqual(app.model.snapshot.accounts.first { $0.id == b.id }?.state, .disabled)
        XCTAssertEqual(app.model.readyAccounts.map(\.id), [a.id])
        try app.auth.setLogoutFailure(b.id, fails: true)
        await app.services.handle(.removeAccount(b.id))
        XCTAssertEqual(app.model.snapshot.accounts.count, 2)
        XCTAssertNotNil(app.model.notice)
        let retained = try await PoolStore(workspace: app.workspace).load()
        XCTAssertEqual(retained.accounts.count, 2)
        try app.auth.setLogoutFailure(b.id, fails: false)
        await app.services.handle(.removeAccount(b.id))
        XCTAssertEqual(app.model.snapshot.accounts.map(\.id), [a.id])
        let removed = try await PoolStore(workspace: app.workspace).load()
        XCTAssertEqual(removed.accounts.map(\.id), [a.id])
        XCTAssertEqual(try app.auth.commands(b.id).filter { $0 == "auth logout" }.count, 2)
    }

    func testConnectWritesDesktopSettingsOpensDesktopAndDisconnectRestores() async throws {
        let account = PoolAccount(email: "mi•••ella@example.com", plan: "Pro", state: .ready)
        let app = try await application(accounts: [account])
        let desktop = app.desktop
        try desktop.put(#"{"deploymentMode":"1p","mcpServers":{}}"#, "Claude-3p/claude_desktop_config.json")
        XCTAssertEqual(app.model.snapshot.desktop, .disconnected)
        await app.services.handle(.connectDesktop)
        XCTAssertEqual(app.model.snapshot.desktop, .connected)
        XCTAssertEqual(desktop.opened, 1, "a Desktop that was not running is opened")
        XCTAssertEqual(desktop.confirmations, 0)
        XCTAssertEqual(try desktop.json("Claude-3p/claude_desktop_config.json")["deploymentMode"], .string("3p"))

        await app.services.handle(.disconnectDesktop)
        XCTAssertEqual(app.model.snapshot.desktop, .disconnected)
        XCTAssertEqual(try desktop.json("Claude-3p/claude_desktop_config.json"), .object(["deploymentMode": .string("1p"), "mcpServers": .object([:])]))
        XCTAssertFalse(app.model.isWorking)
    }

    func testARunningDesktopIsRestartedOnlyAfterAskingAndNeverForced() async throws {
        let account = PoolAccount(email: "mi•••ella@example.com", plan: "Pro", state: .ready)
        let desktop = try AppDesktopFixture(workspace: nil)
        desktop.launches = [Date(timeIntervalSince1970: 1_000)]
        desktop.answer = false; desktop.quitWait = 0.3
        let app = try await application(accounts: [account], desktop: desktop)
        await app.services.handle(.connectDesktop)
        XCTAssertEqual(desktop.confirmations, 1)
        XCTAssertEqual(desktop.quits, 0)
        XCTAssertEqual(app.model.snapshot.desktop, .needsRestart)
        XCTAssertTrue(app.model.setupComplete, "the pool serves while Desktop waits for its restart")

        // Desktop keeps a question open and does not quit: it is left as it is.
        desktop.answer = true; desktop.refusesToQuit = true
        await app.services.handle(.restartDesktop)
        XCTAssertEqual(desktop.quits, 1)
        XCTAssertEqual(desktop.opened, 0)
        XCTAssertEqual(app.model.snapshot.desktop, .needsRestart)
        XCTAssertNotNil(app.model.notice)

        desktop.refusesToQuit = false
        await app.services.handle(.restartDesktop)
        XCTAssertEqual(desktop.opened, 1)
        XCTAssertEqual(app.model.snapshot.desktop, .connected)
    }

    func testDesktopSettingsChangedElsewhereOfferReconnect() async throws {
        let account = PoolAccount(email: "mi•••ella@example.com", plan: "Pro", state: .ready)
        let app = try await application(accounts: [account], connected: true)
        XCTAssertEqual(app.model.snapshot.desktop, .connected)
        try app.desktop.put(#"{"appliedId":"elsewhere","entries":[{"id":"elsewhere"},{"id":"\#(DesktopConnection.profileID)"}]}"#,
                            "Claude-3p/configLibrary/_meta.json")
        app.services.refreshDesktop()
        XCTAssertEqual(app.model.snapshot.desktop, .changed)
        XCTAssertTrue(app.model.setupComplete)
        await app.services.handle(.connectDesktop)
        XCTAssertEqual(app.model.snapshot.desktop, .connected)
    }

    func testMissingDesktopIsReportedWithoutWritingAnything() async throws {
        let account = PoolAccount(email: "mi•••ella@example.com", plan: "Pro", state: .ready)
        let desktop = try AppDesktopFixture(workspace: nil); desktop.installed = false
        let app = try await application(accounts: [account], desktop: desktop)
        XCTAssertEqual(app.model.snapshot.desktop, .notInstalled)
        await app.services.handle(.connectDesktop)
        XCTAssertEqual(app.model.snapshot.desktop, .notInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: desktop.home.appendingPathComponent("Library").path))
    }

    func testLiveRoutingAndTerminalActionsReachTheOwnedWorker() async throws {
        let a = PoolAccount(email: "mi•••ella@example.com", plan: "Pro", state: .ready)
        let b = PoolAccount(email: "sa•••ahmad@example.org", plan: "Pro", state: .ready)
        let first = AppWorker(), second = AppWorker()
        let app = try await application(accounts: [a, b], connected: true, workerFactory: { account, _ in
            account.id == a.id ? first : second
        })
        await app.services.handle(.routePolicy(.init(strategy: .ordered, accountOrder: [a.id, b.id], reservePercent: 12)))
        await eventually("The pool did not start once setup was complete") { app.services.listeningPort != nil }
        XCTAssertEqual(app.model.snapshot.mode, .running)
        XCTAssertNotNil(app.services.listeningPort)
        let reply = try await request(app, text: "Contact mi•••ella@example.com")
        XCTAssertEqual(reply.0, 200)
        XCTAssertEqual(reply.1["content"]?.arrayValue?.first?["text"], .string("Contact mi•••ella@example.com"))
        await eventually("Current account binding was not published") { app.model.currentSessionAccounts.map(\.id) == [a.id] }
        let upstream = await first.requests
        let forwarded = try XCTUnwrap(upstream.first?.messages.last?.content.stringValue)
        XCTAssertFalse(forwarded.contains("mi•••ella@example.com"))
        XCTAssertTrue(forwarded.hasPrefix("Contact "))
        await eventually("Privacy counts were not published") { app.model.privacy.protectedCount > 0 }
        XCTAssertGreaterThan(app.model.privacy.protectedCount, 0)
        await app.services.handle(.routePolicy(.init(strategy: .ordered, accountOrder: [b.id, a.id], reservePercent: 19)))
        let next = try await request(app, text: "A different synthetic task.")
        XCTAssertEqual(next.0, 200)
        await eventually("Edited account order did not reach live routing") {
            app.model.currentSessionAccounts.count == 2 && app.model.routeDecisions.contains { $0.accountID == b.id && $0.reason == .accountOrder }
        }
        XCTAssertTrue(app.model.routeDecisions.contains { $0.accountID == b.id && $0.reason == .accountOrder })
        // Claude sessions are the pool's own: nothing opens one, and no input reaches it by hand.
        await app.services.handle(.sendTerminalInput("Idle input must remain in Desktop."))
        for key in ["\u{1b}[A", "\r"] { await app.services.handle(.sendTerminalKey(key)) }
        let idleInputs = await first.inputs; XCTAssertTrue(idleInputs.isEmpty)
        XCTAssertNil(app.model.terminal)
        await first.holdNextReply()
        let continuation = BridgeRequest(model: "claude-sonnet", messages: [
            .init(role: "user", content: .string("Contact mi•••ella@example.com")),
            .init(role: "assistant", content: try XCTUnwrap(reply.1["content"])),
            .init(role: "user", content: .string("Continue this synthetic task."))
        ], tools: [.init(name: "Read", inputSchema: .object(["type": .string("object")]))], stream: false)
        let waiting = Task { try await self.request(app, body: continuation) }
        await eventually("The continuation did not stay on the original worker") { await first.requests.count == 2 }
        await app.services.handle(.cancelSession(first.id))
        let interrupted = try await waiting.value; XCTAssertNotEqual(interrupted.0, 200)
        let cancelled = await first.cancellations; XCTAssertEqual(cancelled, 1)
        await app.services.handle(.requestSessionExit(first.id))
        await eventually("The exited session did not end") { await first.exits == 1 }
        let exits = await first.exits; XCTAssertEqual(exits, 1)
        XCTAssertFalse(app.model.currentSessionAccounts.contains { $0.id == a.id })
    }

    /// An update restarts only after the replies Claude is still writing: nothing new is admitted
    /// meanwhile, a held reply is waited for, not cut, and the wait ends at its cap all the same.
    func testUpdateWaitsForAReplyUnderWayAndRestartsOnceTheCapPasses() async throws {
        let lock = NSLock()
        nonisolated(unsafe) var lines: [String] = []
        Diagnostics.install { line in lock.withLock { lines.append(line) } }
        defer { Diagnostics.install(nil) }
        func drains() -> [String] { lock.withLock { lines.filter { $0.hasPrefix("event=app.update_drain ") } } }
        let account = PoolAccount(email: "mi•••ella@example.com", plan: "Pro", state: .ready)
        // Long enough that the second wait sees the reply end first on a busy machine; short of the
        // request helper's 4-second timeout for the held reply.
        let worker = AppWorker(), cap: TimeInterval = 1.5
        let app = try await application(accounts: [account], connected: true, workerFactory: { _, _ in worker },
                                        updateDrainLimit: cap)
        await eventually("The pool did not start once setup was complete") { app.services.listeningPort != nil }
        let first = try await request(app, text: "A synthetic task.")
        XCTAssertEqual(first.0, 200)
        await worker.holdNextReply()
        let continuation = BridgeRequest(model: "claude-sonnet", messages: [
            .init(role: "user", content: .string("A synthetic task.")),
            .init(role: "assistant", content: try XCTUnwrap(first.1["content"])),
            .init(role: "user", content: .string("Continue this synthetic task."))
        ], tools: [.init(name: "Read", inputSchema: .object(["type": .string("object")]))], stream: false)
        let held = Task { try await self.request(app, body: continuation) }
        await eventually("The held reply did not start") { await worker.requests.count == 2 }

        // The reply never ends by itself: the update waits for it until the cap, then goes on.
        let began = Date()
        let capped = Task { await app.services.drainForUpdate() }
        await eventually("The update did not begin waiting") { drains().count == 1 }
        XCTAssertTrue(drains()[0].contains("answering=1"), drains()[0])
        let refused = try await request(app, text: "A new synthetic conversation.")
        XCTAssertEqual(refused.0, 503, "Nothing new is admitted while an update waits")
        await capped.value
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(began), cap, "The update did not wait for the reply under way")
        let ended = try XCTUnwrap(drains().last)
        for field in ["outcome=ended", "reason=cap", "waited=1", "left=1", "cap=yes"] { XCTAssertTrue(ended.contains(field), ended) }
        let cutByWaiting = await worker.cancellations
        XCTAssertEqual(cutByWaiting, 0, "Waiting must not cut the reply")
        XCTAssertTrue(app.model.snapshot.sessions.contains { $0.state == .running })

        // Asked again, the wait ends as soon as the reply does, and the reply reaches the client whole.
        let drained = Task { await app.services.drainForUpdate() }
        await eventually("The second wait did not begin") { drains().count == 3 }
        await worker.finishHeldReply("The held reply finished.")
        await drained.value
        let finished = try await held.value
        XCTAssertEqual(finished.0, 200)
        XCTAssertEqual(finished.1["content"]?.arrayValue?.first?["text"], .string("The held reply finished."))
        let last = try XCTUnwrap(drains().last)
        for field in ["reason=drained", "waited=1", "left=0", "cap=no"] { XCTAssertTrue(last.contains(field), last) }
        let closed = await app.services.prepareToQuit(); XCTAssertTrue(closed)
        let cancelled = await worker.cancellations
        XCTAssertEqual(cancelled, 0, "No reply was under way when the app quit")
    }

    func testPrivacyInstallPreviewAndClearingAQueuedResultUseOnlyLocalState() async throws {
        let detector = AppPrivacyModel(ready: false)
        let app = try await application(privacy: detector)
        XCTAssertEqual(app.model.privacy.phase, .notInstalled)
        await app.services.handle(.previewPrivacy("Contact mi•••ella@example.com"))
        XCTAssertEqual(app.model.privacyPreview.phase, .failed)
        await app.services.handle(.installPrivacyModel)
        XCTAssertEqual(app.model.privacy.phase, .ready)
        await app.services.handle(.previewPrivacy("Contact mi•••ella@example.com"))
        XCTAssertEqual(app.model.privacyPreview.phase, .ready)
        XCTAssertFalse(app.model.privacyPreview.text.contains("mi•••ella@example.com"))
        XCTAssertGreaterThan(app.model.privacyPreview.protectedCount, 0)
        let before = await detector.detectionCount
        let gate = AsyncStream<Void>.makeStream()
        await detector.holdDetection(on: gate.stream)
        let preview = Task { await app.services.handle(.previewPrivacy("Queued mi•••ella@example.com")) }
        await eventually("Preview did not reach the local detector") { await detector.detectionCount > before }
        await app.services.handle(.clearPrivacyPreview)
        gate.continuation.yield(()); gate.continuation.finish()
        await preview.value
        XCTAssertEqual(app.model.privacyPreview.phase, .idle)
        XCTAssertTrue(app.model.privacyPreview.text.isEmpty)
        XCTAssertTrue(app.model.privacyPreview.categories.isEmpty)
        XCTAssertFalse(app.model.isWorking)
        let persisted = String(decoding: try app.workspace.read(app.workspace.root.appendingPathComponent("library.json")), as: UTF8.self)
        XCTAssertFalse(persisted.contains("Queued mi•••ella@example.com"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.workspace.root.appendingPathComponent("runs").path))
    }

    func testManualQuotaRefreshReopensTrustObserverAndPublishesItsConfirmedReading() async throws {
        let account = PoolAccount(email: "mi•••ella@example.com", plan: "Pro", state: .ready)
        let app = try await application(accounts: [account], quotaTrust: true)
        await app.services.handle(.refreshQuota(account.id))
        await eventually("Native quota trust prompt was not surfaced") { app.model.quotaRefresh[account.id]?.phase == .failed }
        XCTAssertNil(app.model.terminal)
        await app.services.handle(.refreshQuota(account.id))
        let observerID = try XCTUnwrap(app.model.terminal?.id)
        XCTAssertNotEqual(observerID, account.id)
        XCTAssertTrue(app.model.terminal?.output.contains("Trust this workspace?") == true)
        XCTAssertEqual(app.model.terminal?.inputEnabled, true)
        XCTAssertEqual(app.model.terminal?.textInputEnabled, false)
        await app.services.handle(.sendTerminalInput("This must not become a quota-session inference prompt."))
        XCTAssertTrue(app.quota?.inputs.isEmpty == true)
        await app.services.handle(.sendTerminalKey("\r"))
        await eventually("Confirmed quota did not reach the account card") {
            app.model.snapshot.accounts.first?.windows.count == 2 && app.model.quotaRefresh[account.id]?.phase == .idle
        }
        app.model.referenceDate = Date()
        XCTAssertEqual(app.model.snapshot.accounts.first?.windows.map(\.usedPercent), [25, 10])
        XCTAssertEqual(app.model.quotaText(app.model.snapshot.accounts[0], window: "five_hour"), "75%")
        XCTAssertEqual(app.quota?.launchCount, 1)
        XCTAssertEqual(app.model.terminal?.id, observerID)
        XCTAssertEqual(app.model.terminal?.isRunning, false)
        let saved = try await PoolStore(workspace: app.workspace).load()
        XCTAssertEqual(saved.accounts.first?.windows, app.model.snapshot.accounts.first?.windows)
    }

    func testRefreshingAfterAResetClearsSavedSessionAndWeeklyCooldowns() async throws {
        let now = Date(), old = now.addingTimeInterval(-60)
        let weekReset = now.addingTimeInterval(4 * 86400)
        let idle = QuotaWindow(id: "five_hour", usedPercent: 0, observedAt: old)
        let week = QuotaWindow(id: "seven_day", usedPercent: 0, observedAt: old, resetsAt: weekReset)
        let short = PoolAccount(email: "short@example.com", plan: "Pro", state: .limited, windows: [idle, week],
                                cooldownUntil: now.addingTimeInterval(3600))
        let weekly = PoolAccount(email: "week@example.com", plan: "Pro", state: .limited, windows: [idle, week],
                                 cooldownUntil: weekReset)
        let app = try await application(accounts: [short, weekly], quotaTrust: false,
            quotaPanel: "Settings Status Config Usage Stats\r\nCurrent session 0% used\r\nCurrent week (all models) 0% used\r\nCurrent week (Fable) 0% used")
        await app.services.handle(.refreshQuota(nil))
        await eventually("Official reset did not release both accounts") {
            app.model.snapshot.accounts.allSatisfy { $0.state == .ready && $0.cooldownUntil == nil }
        }
        app.model.referenceDate = Date()
        XCTAssertEqual(Set(app.model.readyAccounts.map(\.id)), Set([short.id, weekly.id]))
        for account in app.model.snapshot.accounts {
            XCTAssertEqual(app.model.quotaText(account, window: "seven_day"), "100%")
            XCTAssertEqual(app.model.accountStatus(account), app.model.t("{0}% left", "100"))
        }
        let saved = try await PoolStore(workspace: app.workspace).load()
        XCTAssertTrue(saved.accounts.allSatisfy { $0.state == .ready && $0.cooldownUntil == nil })
    }

    func testNeverReadAccountGetsItsFirstReadingAtLaunchWithoutStartingThePool() async throws {
        let unread = PoolAccount(email: "mi•••ella@example.com", plan: "Pro", state: .ready)
        let read = PoolAccount(email: "sa•••ahmad@example.org", plan: "Pro", state: .ready,
            windows: [.init(id: "five_hour", usedPercent: 5, observedAt: Date(), resetsAt: Date().addingTimeInterval(3600))])
        let app = try await application(accounts: [unread, read], quotaTrust: false)
        XCTAssertNotEqual(app.model.snapshot.mode, .running)
        await eventually("The never-read account was not read at launch") {
            app.model.snapshot.accounts.first(where: { $0.id == unread.id })?.windows.count == 2
        }
        XCTAssertEqual(app.quota?.launchCount, 1, "An account with a retained reading is not read again")
        XCTAssertNil(app.model.terminal)
    }

    func testHeldQuotaSessionCanBeExitedAndDoesNotBlockQuit() async throws {
        for useExitButton in [true, false] {
            let account = PoolAccount(email: "mi•••ella@example.com", plan: "Pro", state: .ready)
            let app = try await application(accounts: [account], quotaTrust: true)
            await app.services.handle(.refreshQuota(account.id))
            await eventually("Held quota session was not surfaced") { app.model.quotaRefresh[account.id]?.phase == .failed }
            if useExitButton {
                await app.services.handle(.refreshQuota(account.id))
                let observerID = try XCTUnwrap(app.model.terminal?.id)
                app.model.notice = nil
                await app.services.handle(.requestSessionExit(observerID))
                XCTAssertNil(app.model.notice, "Exit session must end a held quota session")
                await eventually("Exited quota session still looks running") { app.model.terminal?.isRunning == false }
            }
            let closed = await app.services.prepareToQuit()
            XCTAssertTrue(closed, "Quitting must end a held quota session normally")
            XCTAssertEqual(app.quota?.interruptCount, 2)
            XCTAssertEqual(app.quota?.launchCount, 1)
        }
    }

    func testQuitEndsASessionWaitingOnATool() async throws {
        let account = PoolAccount(email: "mi•••ella@example.com", plan: "Pro", state: .ready)
        let call = BridgeToolCall(id: "tool_fixture_quit", name: "read_file", input: .object(["path": .string("note.txt")]))
        let worker = AppWorker(tool: call)
        let app = try await application(accounts: [account], connected: true, workerFactory: { _, _ in worker })
        await eventually("The pool did not start once setup was complete") { app.services.listeningPort != nil }
        let body = BridgeRequest(model: "claude-sonnet", messages: [.init(role: "user", content: .string("Read the synthetic note."))],
            tools: [.init(name: "read_file", inputSchema: .object(["type": .string("object")]))], stream: false)
        let offered = try await request(app, body: body)
        XCTAssertEqual(offered.1["stop_reason"], .string("tool_use"))
        await eventually("Pending tool did not appear as active work") { app.model.activeSessions.contains { $0.id == worker.id && $0.state == .waiting } }
        // Nothing has to be ended by hand: quitting ends the session through the client's own exit.
        let quit = await app.services.prepareToQuit()
        XCTAssertTrue(quit)
        let exits = await worker.exits; XCTAssertEqual(exits, 1)
        XCTAssertNil(app.services.listeningPort)
    }

    func testPendingToolKeepsItsAccountAndFinishes() async throws {
        let account = PoolAccount(email: "mi•••ella@example.com", plan: "Pro", state: .ready)
        let call = BridgeToolCall(id: "tool_fixture_wait", name: "read_file", input: .object(["path": .string("note.txt")]))
        let worker = AppWorker(tool: call)
        let app = try await application(accounts: [account], connected: true, workerFactory: { _, _ in worker })
        await eventually("The pool did not start once setup was complete") { app.services.listeningPort != nil }
        var body = BridgeRequest(model: "claude-sonnet", messages: [.init(role: "user", content: .string("Read the synthetic note."))],
            tools: [.init(name: "read_file", inputSchema: .object(["type": .string("object")]))], stream: false)
        let offered = try await request(app, body: body)
        XCTAssertEqual(offered.0, 200)
        XCTAssertEqual(offered.1["stop_reason"], .string("tool_use"))
        await eventually("Pending tool did not appear as active work") { app.model.activeSessions.contains { $0.id == worker.id && $0.state == .waiting } }
        await app.services.handle(.removeAccount(account.id))
        XCTAssertEqual(app.model.snapshot.accounts.first?.id, account.id)
        XCTAssertEqual(app.model.snapshot.accounts.first?.state, .ready)
        XCTAssertFalse(try app.auth.commands(account.id).contains("auth logout"))
        body.messages += [
            .init(role: "assistant", content: try XCTUnwrap(offered.1["content"])),
            .init(role: "user", content: .array([.object(["type": .string("tool_result"), "tool_use_id": .string(call.id),
                "content": .string("Synthetic file content.")])]))
        ]
        let finished = try await request(app, body: body)
        XCTAssertEqual(finished.0, 200)
        await eventually("The pending tool did not finish") { app.model.activeSessions.isEmpty }
        XCTAssertEqual(app.model.currentSessionAccounts.map(\.id), [account.id])
        let requests = await worker.requests; XCTAssertEqual(requests.count, 2)
        let closed = await app.services.prepareToQuit(); XCTAssertTrue(closed)
        XCTAssertNil(app.services.listeningPort)
    }

    func testRunsSoonAfterAConfirmedCheckReuseItAndAManualCheckStillAsks() async throws {
        let account = PoolAccount(email: "mi•••ella@example.com", plan: "Pro", state: .ready)
        let app = try await application(accounts: [account], connected: true, workerFactory: { _, _ in AppWorker() })
        await eventually("The pool did not start once setup was complete") { app.services.listeningPort != nil }
        // the fixture client writes its command log at its first command
        func checks() throws -> Int {
            do { return try app.auth.commands(account.id).filter { $0 == "auth status" }.count }
            catch RuntimeError.missingFile { return 0 }
        }
        let before = try checks()
        for text in ["First synthetic question.", "Second synthetic question."] {
            let answered = try await request(app, text: text)
            XCTAssertEqual(answered.0, 200)
        }
        XCTAssertLessThanOrEqual(try checks() - before, 1, "A run soon after a confirmed check must not ask the client again")
        let afterRuns = try checks()
        await app.services.handle(.checkAccount(account.id))
        XCTAssertEqual(try checks(), afterRuns + 1, "A check the person asks for still asks the client")
        let closed = await app.services.prepareToQuit(); XCTAssertTrue(closed)
    }

    func testPrivacyNotReadyBlocksStartAndLaterModelFailureSendsWithTheRulesAlone() async throws {
        let account = PoolAccount(email: "mi•••ella@example.com", plan: "Pro", state: .ready)
        let detector = AppPrivacyModel(ready: false), worker = AppWorker()
        let app = try await application(accounts: [account], connected: true, privacy: detector, workerFactory: { _, _ in worker })
        XCTAssertNil(app.services.listeningPort)
        XCTAssertEqual(app.model.snapshot.mode, .stopped)
        await app.services.handle(.installPrivacyModel)
        await eventually("The pool did not start once setup was complete") { app.services.listeningPort != nil }
        await detector.setFailure(true)
        // A model that stops answering does not hold the request: the rules redact it alone.
        let sent = try await request(app, text: "Contact synthetic.user@gmail.com")
        XCTAssertEqual(sent.0, 200)
        let requests = await worker.requests; XCTAssertEqual(requests.count, 1)
        XCTAssertFalse(requests.first?.messages.last?.content.stringValue?.contains("synthetic.user@gmail.com") ?? true)
        await eventually("The model's failure was not visible") { app.model.privacy.message != nil && app.model.privacy.phase == .failed }
    }

    func testLoginInterruptKeepsPreviouslyVerifiedIdentityAndQuitWaitsForTheChild() async throws {
        let account = PoolAccount(email: "mi•••ella@example.com", plan: "Pro", state: .ready)
        let app = try await application(accounts: [account])
        await app.services.handle(.signIn(account.id))
        let child = try XCTUnwrap(app.auth.client.activeProcess(accountID: account.id))
        await eventually("Synthetic sign-in did not become interactive") { app.model.terminal?.output.contains("Synthetic sign-in") == true }
        let blocked = await app.services.prepareToQuit(); XCTAssertFalse(blocked)
        XCTAssertTrue(child.isRunning)
        await app.services.handle(.cancelSession(account.id))
        await eventually("Interrupted login did not return to its verified account state") {
            !child.isRunning && app.model.snapshot.accounts.first?.state == .ready && app.model.terminal?.isRunning == false
        }
        XCTAssertEqual(app.model.snapshot.accounts.first?.email, account.email)
        XCTAssertEqual(app.model.snapshot.accounts.first?.plan, "Pro")
        XCTAssertEqual(try app.auth.commands(account.id).filter { $0 == "auth login" }.count, 1)
    }

    func testPrivacyInstallFailureKeepsVerifiedRuntimeAndCanBeRetriedSeparately() async throws {
        let detector = AppPrivacyModel(ready: false)
        let app = try await application(installed: false, privacy: detector)
        await detector.setFailure(true)
        await app.services.handle(.installRuntime)
        XCTAssertTrue(app.model.snapshot.executableReady)
        XCTAssertEqual(app.model.runtime.phase, .ready)
        XCTAssertEqual(app.model.privacy.phase, .failed)
        XCTAssertNotNil(app.model.notice)
        let installed = try await app.runtime.current()
        await detector.setFailure(false)
        await app.services.handle(.installPrivacyModel)
        XCTAssertEqual(app.model.privacy.phase, .ready)
        let unchanged = try await app.runtime.current()
        XCTAssertEqual(unchanged, installed)
    }

    func testBusyPrivacyModelNeverHoldsARequestOrChangesTheAccount() async throws {
        let account = PoolAccount(email: "mi•••ella@example.com", plan: "Pro", state: .ready)
        let detector = AppPrivacyModel(), worker = AppWorker()
        let app = try await application(accounts: [account], connected: true, privacy: detector, workerFactory: { _, _ in worker })
        await eventually("The pool did not start once setup was complete") { app.services.listeningPort != nil }
        await detector.setBusy(true)
        let busy = try await request(app, text: "A synthetic request.")
        XCTAssertEqual(busy.0, 200)
        let before = await worker.requests; XCTAssertEqual(before.count, 1)
        XCTAssertEqual(app.model.privacy.phase, .ready)
        XCTAssertEqual(app.model.snapshot.accounts.first?.state, .ready)
        await detector.setBusy(false)
        let retried = try await request(app, text: "Contact mi•••ella@example.com")
        XCTAssertEqual(retried.0, 200)
        let sent = await worker.requests; XCTAssertEqual(sent.count, 2)
        XCTAssertFalse(sent.last?.messages.last?.content.stringValue?.contains("mi•••ella@example.com") ?? true)
        XCTAssertNil(app.model.privacy.message)
    }

    func testQuitCancelsUnfinishedNewLoginWithoutSavingAnAccount() async throws {
        let app = try await application()
        await app.services.handle(.addAccount)
        let id = try XCTUnwrap(app.model.pendingSignInID)
        let child = try XCTUnwrap(app.auth.client.activeProcess(accountID: id))
        await eventually("Synthetic sign-in did not become interactive") { app.model.terminal?.output.contains("Synthetic sign-in") == true }
        let allowed = await app.services.prepareToQuit()
        XCTAssertTrue(allowed)
        XCTAssertFalse(child.isRunning)
        XCTAssertNil(app.model.pendingSignInID)
        XCTAssertNil(app.model.terminal)
        XCTAssertTrue(app.model.snapshot.accounts.isEmpty)
        XCTAssertTrue(try app.auth.commands(id).contains("auth logout"))
        let saved = try await PoolStore(workspace: app.workspace).load()
        XCTAssertTrue(saved.accounts.isEmpty)
    }

    func testPendingLoginCloseCancelExitAndRemoveNeverPersistAndUseNormalLogout() async throws {
        for action in 0..<4 {
            let app = try await application()
            await app.services.handle(.addAccount)
            let id = try XCTUnwrap(app.model.pendingSignInID)
            let child = try XCTUnwrap(app.auth.client.activeProcess(accountID: id))
            await eventually("Pending login did not become interactive") { app.model.terminal?.output.contains("Synthetic sign-in") == true }
            try app.auth.setStatus(id)
            switch action {
            case 0: await app.services.handle(.closeTerminal(id))
            case 1: await app.services.handle(.cancelSession(id))
            case 2: await app.services.handle(.requestSessionExit(id))
            default: await app.services.handle(.removeAccount(id))
            }
            XCTAssertFalse(child.isRunning)
            XCTAssertNil(app.auth.client.activeProcess(accountID: id))
            XCTAssertNil(app.model.pendingSignInID)
            XCTAssertTrue(app.model.snapshot.accounts.isEmpty)
            let saved = try await PoolStore(workspace: app.workspace).load()
            XCTAssertTrue(saved.accounts.isEmpty)
            XCTAssertEqual(try app.auth.commands(id).filter { $0 == "auth logout" }.count, 1)
            let statusFile = try app.workspace.accountDirectory(id).appendingPathComponent("fixture-status.json")
            XCTAssertFalse(FileManager.default.fileExists(atPath: statusFile.path))
            if action == 0 || action == 3 { XCTAssertNil(app.model.terminal) }
            else {
                XCTAssertEqual(app.model.terminal?.id, id)
                XCTAssertEqual(app.model.terminal?.isRunning, false)
                XCTAssertEqual(app.model.terminal?.inputEnabled, false)
                XCTAssertEqual(app.model.terminal?.isPendingSignIn, false)
                await app.services.handle(.closeTerminal(id))
                XCTAssertNil(app.model.terminal)
            }
        }
    }

    func testFailedPendingLoginKeepsEndedOutputButNoAccountOrCredentials() async throws {
        let app = try await application()
        await app.services.handle(.addAccount)
        let id = try XCTUnwrap(app.model.pendingSignInID)
        await eventually("Pending login did not become interactive") { app.model.terminal?.output.contains("Synthetic sign-in") == true }
        try app.auth.setStatus(id)
        try app.auth.setLoginFailure(id)
        await app.services.handle(.sendTerminalInput("finish failed sign-in"))
        await eventually("Failed sign-in was not discarded") { app.model.pendingSignInID == nil }
        XCTAssertTrue(app.model.snapshot.accounts.isEmpty)
        let saved = try await PoolStore(workspace: app.workspace).load()
        XCTAssertTrue(saved.accounts.isEmpty)
        XCTAssertEqual(app.model.terminal?.id, id)
        XCTAssertEqual(app.model.terminal?.isRunning, false)
        XCTAssertEqual(app.model.terminal?.inputEnabled, false)
        XCTAssertEqual(app.model.terminal?.isPendingSignIn, false)
        XCTAssertEqual(app.model.terminal?.failure, app.model.t("Claude Code ended before the sign-in finished. Try again for a new sign-in link."))
        XCTAssertEqual(app.model.terminal?.retry, .addAccount)
        let commands = try app.auth.commands(id)
        XCTAssertFalse(commands.contains("auth status"))
        XCTAssertEqual(commands.filter { $0 == "auth logout" }.count, 1)
        let statusFile = try app.workspace.accountDirectory(id).appendingPathComponent("fixture-status.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: statusFile.path))
        await app.services.handle(.closeTerminal(id))
        XCTAssertNil(app.model.terminal)
    }

    func testPendingLoginWithoutValidOfficialEmailCannotEnterTheLibrary() async throws {
        for invalidEmail in [nil, "invalid-official-email"] as [String?] {
            let app = try await application()
            await app.services.handle(.addAccount)
            let id = try XCTUnwrap(app.model.pendingSignInID)
            await eventually("Pending login did not become interactive") { app.model.terminal?.output.contains("Synthetic sign-in") == true }
            if let invalidEmail { try app.auth.setStatus(id, email: invalidEmail) }
            await app.services.handle(.sendTerminalInput("finish synthetic sign-in"))
            await eventually("Unverified identity was retained") { app.model.pendingSignInID == nil }
            XCTAssertTrue(app.model.snapshot.accounts.isEmpty)
            let saved = try await PoolStore(workspace: app.workspace).load()
            XCTAssertTrue(saved.accounts.isEmpty)
            XCTAssertEqual(app.model.terminal?.isRunning, false)
            XCTAssertEqual(app.model.terminal?.failure, app.model.t(invalidEmail == nil
                ? "Sign in to this account with Claude Code." : "Claude Code did not confirm this account's isolated sign-in."))
            XCTAssertEqual(app.model.terminal?.retry, .addAccount)
            XCTAssertEqual(try app.auth.commands(id).filter { $0 == "auth logout" }.count, 1)
        }
    }

    func testSignInCodeIsEnteredExactlyAndEnterFollowsSeparately() async throws {
        for bracketed in [false, true] {
            let app = try await application()
            if bracketed { try app.auth.enableBracketedPaste() }
            await app.services.handle(.addAccount)
            let current = try XCTUnwrap(app.model.pendingSignInID)
            await eventually("Pending login did not become interactive") { app.model.terminal?.output.contains("Synthetic sign-in") == true }
            try app.auth.setStatus(current)
            await app.services.handle(.sendTerminalInput("  synthetic-code#synthetic-state \n"))
            await eventually("Verified sign-in was not saved") { app.model.snapshot.accounts.count == 1 }
            let recorded = try app.auth.loginInput(current)
            XCTAssertEqual(recorded, bracketed ? "\u{1b}[200~synthetic-code#synthetic-state\u{1b}[201~" : "synthetic-code#synthetic-state")
        }
    }

    func testFailedSignInOffersARetryThatStartsANewOfficialLogin() async throws {
        let app = try await application()
        await app.services.handle(.addAccount)
        let first = try XCTUnwrap(app.model.pendingSignInID)
        await eventually("Pending login did not become interactive") { app.model.terminal?.output.contains("Synthetic sign-in") == true }
        try app.auth.setLoginFailure(first)
        await app.services.handle(.sendTerminalInput("rejected-code#state"))
        await eventually("Failed sign-in did not offer a retry") { app.model.terminal?.retry == .addAccount }
        await app.services.handle(.addAccount)
        let second = try XCTUnwrap(app.model.pendingSignInID)
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(app.model.terminal?.id, second)
        XCTAssertNil(app.model.terminal?.failure)
        XCTAssertEqual(app.model.terminal?.isRunning, true)
        await eventually("Retried login did not become interactive") { app.model.terminal?.output.contains("Synthetic sign-in") == true }
        try app.auth.setStatus(second)
        await app.services.handle(.sendTerminalInput("accepted-code#state"))
        await eventually("Retried sign-in was not saved and closed") {
            app.model.snapshot.accounts.map(\.id) == [second] && app.model.terminal == nil
        }
    }

    func testDuplicateSignInExplainsWhyInTheSheet() async throws {
        let existing = PoolAccount(email: "mi•••ella@example.com", plan: "Pro", state: .ready)
        let app = try await application(accounts: [existing])
        await app.services.handle(.addAccount)
        let id = try XCTUnwrap(app.model.pendingSignInID)
        await eventually("Pending login did not become interactive") { app.model.terminal?.output.contains("Synthetic sign-in") == true }
        try app.auth.setStatus(id, email: "mi•••ella@example.com", plan: "pro")
        await app.services.handle(.sendTerminalInput("synthetic-code#state"))
        await eventually("Duplicate sign-in was not explained") { app.model.terminal?.failure != nil }
        XCTAssertEqual(app.model.terminal?.failure, app.model.t("{0} is already in the pool. Sign in with a different account.", "mi•••ella@example.com"))
        XCTAssertEqual(app.model.snapshot.accounts, [existing])
    }

    func testVerifiedFreeLoginIsSavedWithoutBecomingRoutingEligible() async throws {
        let app = try await application()
        await app.services.handle(.addAccount)
        let id = try XCTUnwrap(app.model.pendingSignInID)
        await eventually("Pending login did not become interactive") { app.model.terminal?.output.contains("Synthetic sign-in") == true }
        try app.auth.setStatus(id, plan: "free")
        await app.services.handle(.sendTerminalInput("finish synthetic sign-in"))
        await eventually("Verified Free identity was not saved") { app.model.pendingSignInID == nil && app.model.snapshot.accounts.count == 1 }
        XCTAssertEqual(app.model.snapshot.accounts.first?.state, .subscriptionRequired)
        XCTAssertEqual(app.model.snapshot.accounts.first?.email, "mi•••ella@example.com")
        XCTAssertTrue(app.model.hasSignedInAccount)
        XCTAssertTrue(app.model.readyAccounts.isEmpty)
        let saved = try await PoolStore(workspace: app.workspace).load()
        XCTAssertEqual(saved.accounts, app.model.snapshot.accounts)
    }

    func testPendingVerificationCanReopenAndCancelWithoutLateAccountCommit() async throws {
        let app = try await application()
        await app.services.handle(.addAccount)
        let id = try XCTUnwrap(app.model.pendingSignInID)
        await eventually("Pending login did not become interactive") { app.model.terminal?.output.contains("Synthetic sign-in") == true }
        try app.auth.setStatus(id)
        try app.auth.holdStatus(id)
        await app.services.handle(.sendTerminalInput("finish synthetic login"))
        await eventually("Official verification did not start") { app.auth.statusIsWaiting(id) }
        let verifying = try XCTUnwrap(app.auth.client.activeProcess(accountID: id))
        app.model.notice = nil
        await app.services.handle(.addAccount)
        XCTAssertEqual(app.model.pendingSignInID, id)
        XCTAssertEqual(app.auth.client.activeProcess(accountID: id)?.processID, verifying.processID)
        XCTAssertEqual(app.model.terminal?.inputEnabled, false)
        XCTAssertEqual(app.model.terminal?.textInputEnabled, false)
        XCTAssertNil(app.model.notice)
        XCTAssertEqual(try app.auth.commands(id).filter { $0 == "auth login" }.count, 1)
        let closing = Task { await app.services.handle(.closeTerminal(id)) }
        await eventually("Cancellation did not disable pending verification") { app.model.terminal?.title == app.model.t("Closing sign-in…") }
        try verifying.write(Data("release synthetic status\n".utf8))
        await closing.value
        XCTAssertFalse(verifying.isRunning)
        XCTAssertNil(app.model.pendingSignInID)
        XCTAssertNil(app.model.terminal)
        XCTAssertTrue(app.model.snapshot.accounts.isEmpty)
        let saved = try await PoolStore(workspace: app.workspace).load()
        XCTAssertTrue(saved.accounts.isEmpty)
        XCTAssertEqual(try app.auth.commands(id).filter { $0 == "auth logout" }.count, 1)
    }

    func testLegacyUnverifiedPlaceholdersArePrunedWithoutRemovingSavedIdentity() async throws {
        let saved = PoolAccount(email: "mi•••ella@example.com", plan: "Pro", state: .ready)
        let placeholder = PoolAccount(state: .disabled)
        let app = try await application(accounts: [saved, placeholder])
        XCTAssertEqual(app.model.snapshot.accounts.map(\.id), [saved.id])
        XCTAssertNil(app.model.pendingSignInID)
        let persisted = try await PoolStore(workspace: app.workspace).load()
        XCTAssertEqual(persisted.accounts, [saved])
        XCTAssertNil(app.auth.client.activeProcess(accountID: placeholder.id))
        await app.services.handle(.removeAccount(placeholder.id))
        XCTAssertEqual(app.model.snapshot.accounts, [saved])
    }

    func testExistingAccountReloginFailureDoesNotDiscardItsVerifiedRecord() async throws {
        let account = PoolAccount(email: "mi•••ella@example.com", plan: "Pro", state: .ready)
        let app = try await application(accounts: [account])
        await app.services.handle(.signIn(account.id))
        XCTAssertNil(app.model.pendingSignInID)
        await eventually("Re-login did not become interactive") { app.model.terminal?.output.contains("Synthetic sign-in") == true }
        try app.auth.setLoginFailure(account.id)
        await app.services.handle(.sendTerminalInput("finish failed re-login"))
        await eventually("Existing account was not reverified after failed re-login") {
            app.model.terminal?.isRunning == false && app.model.snapshot.accounts.first?.state == .ready
        }
        XCTAssertEqual(app.model.snapshot.accounts, [account])
        let persisted = try await PoolStore(workspace: app.workspace).load()
        XCTAssertEqual(persisted.accounts, [account])
        XCTAssertFalse(try app.auth.commands(account.id).contains("auth logout"))
    }

    func testRemovingExistingAccountDuringReloginWaitsForExitAndClosesTerminal() async throws {
        let a = PoolAccount(email: "mi•••ella@example.com", plan: "Pro", state: .ready)
        let b = PoolAccount(email: "sa•••ahmad@example.org", plan: "Ultra", state: .ready)
        let app = try await application(accounts: [a, b])
        await app.services.handle(.signIn(a.id))
        let child = try XCTUnwrap(app.auth.client.activeProcess(accountID: a.id))
        await eventually("Re-login did not become interactive") { app.model.terminal?.output.contains("Synthetic sign-in") == true }
        await app.services.handle(.removeAccount(a.id))
        XCTAssertFalse(child.isRunning)
        XCTAssertNil(app.auth.client.activeProcess(accountID: a.id))
        XCTAssertNil(app.model.terminal)
        XCTAssertNil(app.model.pendingSignInID)
        XCTAssertEqual(app.model.snapshot.accounts, [b])
        let persisted = try await PoolStore(workspace: app.workspace).load()
        XCTAssertEqual(persisted.accounts, [b])
        XCTAssertEqual(try app.auth.commands(a.id).filter { $0 == "auth logout" }.count, 1)
    }

    func testTheClientInstallsAndUpdatesWithoutAClick() async throws {
        let clock = AppTestClock()
        let app = try await application(installed: false, clock: clock)
        XCTAssertFalse(app.model.snapshot.executableReady)
        var dependencies = inertDependencies()
        let runtime = app.runtime, auth = app.auth, privacy = app.privacy
        dependencies.runtimeFactory = { _ in runtime }
        dependencies.clientFactory = { _, _ in auth.client }
        dependencies.privacyModelFactory = { _ in privacy }
        dependencies.now = { clock.value }
        dependencies.gatewayPort = 0
        dependencies.desktop = app.desktop.control
        dependencies.installRuntimeAutomatically = true
        dependencies.checkRuntimeUpdatesAutomatically = true
        _ = await app.services.prepareToQuit()
        let model = PoolAppModel(), services = AppServices(model: model, workspace: app.workspace, dependencies: dependencies)
        await services.load()
        for _ in 0..<200 where !model.snapshot.executableReady || model.isWorking { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(model.snapshot.executableReady)
        XCTAssertEqual(model.runtime.installedVersion, "2.1.300")

        try await app.downloads.publish("2.1.301")
        clock.nextDay()
        await services.checkRuntimeUpdateIfNeeded()
        XCTAssertEqual(model.runtime.installedVersion, "2.1.301")
        XCTAssertEqual(model.runtime.phase, .ready)
        let closed = await services.prepareToQuit(); XCTAssertTrue(closed)
    }

    func testAstrLinkGuardUpdatesByItselfOnceADayAndKeepsWorkingWhenAnUpdateFails() async throws {
        let clock = AppTestClock(), privacy = AppPrivacyModel()
        let artifacts = AstrLinkDetector.builtIn.artifacts.map {
            PrivacyModelArtifact(filename: $0.filename, bytes: $0.bytes, sha256: $0.sha256, revision: String(repeating: "b", count: 40))
        }
        let next = AstrLinkRelease(version: "0.1.4", revision: String(repeating: "b", count: 40), artifacts: artifacts)
        await privacy.publish(.available(next))
        let app = try await application(privacy: privacy, clock: clock, automaticUpdates: true)
        XCTAssertEqual(app.model.privacy.modelVersion, "0.1.4")
        XCTAssertNil(app.model.privacy.updatingTo)
        XCTAssertEqual(app.model.privacyModelLine, "AstrLink Guard 0.1.4 · " + app.model.t("Updates automatically"))
        await app.services.checkRuntimeUpdateIfNeeded()
        let sameDay = await privacy.updateChecks; XCTAssertEqual(sameDay, 1)

        let later = AstrLinkRelease(version: "0.1.5", revision: String(repeating: "c", count: 40), artifacts: artifacts)
        await privacy.publish(.available(later)); await privacy.setFailure(true)
        clock.nextDay()
        await app.services.checkRuntimeUpdateIfNeeded()
        XCTAssertEqual(app.model.privacy.modelVersion, "0.1.4")
        XCTAssertNotNil(app.model.privacy.updateMessage)
        XCTAssertEqual(app.model.privacy.phase, .ready)
    }

    func testClientUpdateChecksRunEveryFourHoursPersistAcrossRestartAndManualCheckBypassesTheGate() async throws {
        let clock = AppTestClock()
        let app = try await application(clock: clock, automaticUpdates: true)
        let firstCount = await app.downloads.latestRequests; XCTAssertEqual(firstCount, 1)
        try await app.downloads.publish("2.1.301")
        await app.services.checkRuntimeUpdateIfNeeded()
        let sameDayCount = await app.downloads.latestRequests; XCTAssertEqual(sameDayCount, 1)
        let restarted = await reopen(app, clock: clock)
        let restartCount = await app.downloads.latestRequests; XCTAssertEqual(restartCount, 1)
        XCTAssertEqual(restarted.model.runtime.installedVersion, "2.1.300")
        // Three hours on is still inside the interval; four is not.
        clock.advance(hours: 3)
        await restarted.services.checkRuntimeUpdateIfNeeded()
        let insideCount = await app.downloads.latestRequests; XCTAssertEqual(insideCount, 1)
        clock.advance(hours: 1)
        await restarted.services.checkRuntimeUpdateIfNeeded()
        let nextDayCount = await app.downloads.latestRequests; XCTAssertEqual(nextDayCount, 2)
        XCTAssertEqual(restarted.model.runtime.availableVersion, "2.1.301")
        XCTAssertEqual(restarted.model.runtime.phase, .updateAvailable)
        await restarted.services.handle(.checkRuntimeUpdate)
        let manualCount = await app.downloads.latestRequests; XCTAssertEqual(manualCount, 3)
        let again = await reopen(restarted, clock: clock)
        let finalCount = await app.downloads.latestRequests; XCTAssertEqual(finalCount, 3)
        XCTAssertEqual(again.model.runtime.availableVersion, "2.1.301")
        XCTAssertEqual(again.model.runtime.phase, .updateAvailable)
    }

    /// Settings' Check for updates looks at once, inside the four-hour interval, and installs what it finds.
    func testCheckForUpdatesInSettingsInstallsANewerClientAtOnce() async throws {
        let clock = AppTestClock()
        let app = try await application(clock: clock, automaticUpdates: true)
        XCTAssertEqual(app.model.runtime.installedVersion, "2.1.300")
        try await app.downloads.publish("2.1.301")
        await app.services.handle(.checkAndUpdateRuntime)
        XCTAssertEqual(app.model.runtime.installedVersion, "2.1.301")
        XCTAssertEqual(app.model.runtime.phase, .ready)
        XCTAssertNil(app.model.runtime.updateCheckMessage)
        // Nothing newer: the client stays as it is.
        await app.services.handle(.checkAndUpdateRuntime)
        XCTAssertEqual(app.model.runtime.installedVersion, "2.1.301")
        XCTAssertEqual(app.model.runtime.phase, .ready)
    }

    func testFailedCheckPreservesKnownUpdateAndDoesNotRetryBeforeFourHours() async throws {
        let clock = AppTestClock()
        let app = try await application(clock: clock, automaticUpdates: true)
        try await app.downloads.publish("2.1.301")
        await app.services.handle(.checkRuntimeUpdate)
        await app.downloads.setFailure(true)
        clock.advance(hours: 4)
        await app.services.checkRuntimeUpdateIfNeeded()
        let failedCount = await app.downloads.latestRequests; XCTAssertEqual(failedCount, 3)
        XCTAssertEqual(app.model.runtime.installedVersion, "2.1.300")
        XCTAssertEqual(app.model.runtime.availableVersion, "2.1.301")
        XCTAssertEqual(app.model.runtime.phase, .updateAvailable)
        XCTAssertNotNil(app.model.runtime.updateCheckMessage)
        XCTAssertTrue(app.model.snapshot.executableReady)
        clock.advance(hours: 3)
        await app.services.checkRuntimeUpdateIfNeeded()
        let repeatedCount = await app.downloads.latestRequests; XCTAssertEqual(repeatedCount, 3)
        let restarted = await reopen(app, clock: clock)
        let restartCount = await app.downloads.latestRequests; XCTAssertEqual(restartCount, 3)
        XCTAssertEqual(restarted.model.runtime.availableVersion, "2.1.301")
        XCTAssertEqual(restarted.model.runtime.phase, .updateAvailable)
        XCTAssertNotNil(restarted.model.runtime.updateCheckMessage)
        await app.downloads.setFailure(false)
        clock.advance(hours: 1)
        await restarted.services.checkRuntimeUpdateIfNeeded()
        let recoveredCount = await app.downloads.latestRequests; XCTAssertEqual(recoveredCount, 4)
        XCTAssertNil(restarted.model.runtime.updateCheckMessage)
        XCTAssertEqual(restarted.model.runtime.availableVersion, "2.1.301")
    }
}

@MainActor
private struct FixtureApplication {
    let workspace: OwnedWorkspace
    var desktop: AppDesktopFixture
    let model: PoolAppModel
    let services: AppServices
    let auth: AppAuthFixture
    let downloads: AppReleaseDownloads
    let runtime: ManagedRuntime
    let privacy: AppPrivacyModel
    let quota: AppQuotaFixture?
}

private actor AppReleaseDownloads: RuntimeDownloader {
    private var files: [String: Data] = [:]
    private var requests: [String: Int] = [:]
    var fails = false
    var latestRequests: Int { requests["/claude-code-releases/latest", default: 0] }
    func resetRequests() { requests.removeAll() }
    func setFailure(_ value: Bool) { fails = value }
    func publish(_ version: String) throws {
        let cpu: UInt32 = RuntimePlatform.current == .macOSArm64 ? 0x0100000c : 0x01000007
        var binary = Data([0xcf, 0xfa, 0xed, 0xfe])
        binary.append(contentsOf: (0..<4).map { UInt8((cpu >> (8 * $0)) & 0xff) })
        binary.append(Data("inert-fixture-\(version)".utf8))
        let checksum = SHA256.hash(data: binary).map { String(format: "%02x", $0) }.joined()
        let prefix = "/claude-code-releases/"
        files[prefix + "latest"] = Data(version.utf8)
        files[prefix + version + "/manifest.json"] = try JSONSerialization.data(withJSONObject: [
            "version": version, "platforms": [RuntimePlatform.current.rawValue:
                ["binary": "claude", "checksum": checksum, "size": binary.count]]])
        files[prefix + version + "/" + RuntimePlatform.current.rawValue + "/claude"] = binary
    }
    func fetch(_ url: URL, maximumBytes: Int64, receive: @escaping @Sendable (Data) throws -> Void) async throws {
        requests[url.path, default: 0] += 1
        guard !fails, let data = files[url.path], data.count <= maximumBytes else { throw RuntimeInstallError.downloadFailed }
        try receive(data)
    }
}

private actor AppPrivacyModel: PrivacyModelManaging {
    private var state: AstrLinkStatus
    private var gate: AsyncStream<Void>?
    private var failure = false
    private var busy = false
    private(set) var detectionCount = 0
    init(ready: Bool = true) { state = ready ? .ready : .notInstalled }
    func status() -> AstrLinkStatus { state }
    func setFailure(_ value: Bool) { failure = value }
    func setBusy(_ value: Bool) { busy = value }
    func holdDetection(on gate: AsyncStream<Void>?) { self.gate = gate }
    func install(progress: @escaping @Sendable (Double) -> Void) throws {
        progress(0.5)
        if failure { state = .failed; throw PrivacyFailure.modelFailed }
        state = .ready; progress(1)
    }
    func unload() {}
    private var version = AstrLinkDetector.modelVersion
    private var published: AstrLinkUpdate = .none
    private(set) var updateChecks = 0
    func publish(_ update: AstrLinkUpdate) { published = update }
    func installedVersion() -> String { version }
    func checkForUpdate() throws -> AstrLinkUpdate { updateChecks += 1; return published }
    func update(to release: AstrLinkRelease, progress: @escaping @Sendable (Double) -> Void) throws {
        if failure { throw PrivacyFailure.modelFailed }
        version = release.version; published = .none
    }
    func detect(in text: String) async throws -> [PrivacySpan] {
        detectionCount += 1
        if let gate { for await _ in gate { break } }
        if busy { throw PrivacyFailure.busy }
        guard state == .ready, !failure else { throw PrivacyFailure.notReady }
        let range = (text as NSString).range(of: "mi•••ella@example.com")
        return range.location == NSNotFound ? [] : [.init(start: range.location, end: NSMaxRange(range), category: .email)]
    }
}

private final class AppAuthFixture: @unchecked Sendable {
    let workspace: OwnedWorkspace
    let client: OfficialCLI
    init(workspace: OwnedWorkspace) throws {
        self.workspace = workspace
        let executable = workspace.root.appendingPathComponent("fixture-auth")
        let script = """
        #!/bin/sh
        printf '%s %s\\n' "$1" "$2" >> "$CLAUDE_CONFIG_DIR/fixture-commands"
        case "$1 $2" in
          'auth login')
            trap 'exit 130' INT
            test ! -f "$(/usr/bin/dirname "$0")/fixture-bracketed-paste" || printf '\\033[?2004h'
            printf 'Synthetic sign-in is waiting\\n'
            IFS= read -r reply
            printf '%s' "$reply" > "$CLAUDE_CONFIG_DIR/fixture-input"
            test ! -f "$CLAUDE_CONFIG_DIR/fixture-login-fails" || exit 4
            ;;
          'auth status')
            if test -f "$CLAUDE_CONFIG_DIR/fixture-status-wait"; then
              trap '' INT
              /bin/stty -echo
              printf 'waiting' > "$CLAUDE_CONFIG_DIR/fixture-status-started"
              IFS= read -r release
            fi
            if test -t 1; then
              # The official client renders this document for a terminal, which is not JSON.
              printf '\\033[?25h{\\r\\r\\n\\033[3G"loggedIn":\\033[15Gtrue,\\r\\r\\n'
            elif test -f "$CLAUDE_CONFIG_DIR/fixture-status.json"; then
              /bin/cat "$CLAUDE_CONFIG_DIR/fixture-status.json"
            else
              printf '{"loggedIn":false}\\n'
              exit 1
            fi
            ;;
          'auth logout')
            test ! -f "$CLAUDE_CONFIG_DIR/fixture-logout-fails" || exit 4
            /bin/rm -f "$CLAUDE_CONFIG_DIR/fixture-status.json"
            ;;
          *) exit 9 ;;
        esac
        """
        try workspace.write(Data(script.utf8), to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        client = OfficialCLI(executable: executable, workspace: workspace)
    }
    func setStatus(_ id: UUID, email: String = "mi•••ella@example.com", plan: String = "pro") throws {
        let directory = try workspace.accountDirectory(id)
        let data = try JSONSerialization.data(withJSONObject: ["loggedIn": true, "authMethod": "claude.ai",
            "subscriptionType": plan, "email": email, "configDirectory": directory.path])
        try workspace.write(data, to: directory.appendingPathComponent("fixture-status.json"))
    }
    func setLogoutFailure(_ id: UUID, fails: Bool) throws {
        let url = try workspace.accountDirectory(id).appendingPathComponent("fixture-logout-fails")
        if fails { try workspace.write(Data(), to: url) } else { try workspace.remove(url) }
    }
    func enableBracketedPaste() throws {
        try workspace.write(Data(), to: workspace.root.appendingPathComponent("fixture-bracketed-paste"))
    }
    func loginInput(_ id: UUID) throws -> String {
        String(decoding: try workspace.read(workspace.accountDirectory(id).appendingPathComponent("fixture-input")), as: UTF8.self)
    }
    func setLoginFailure(_ id: UUID) throws {
        try workspace.write(Data(), to: workspace.accountDirectory(id).appendingPathComponent("fixture-login-fails"))
    }
    func holdStatus(_ id: UUID) throws {
        try workspace.write(Data(), to: workspace.accountDirectory(id).appendingPathComponent("fixture-status-wait"))
    }
    func statusIsWaiting(_ id: UUID) -> Bool {
        guard let directory = try? workspace.accountDirectory(id) else { return false }
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent("fixture-status-started").path)
    }
    func commands(_ id: UUID) throws -> [String] {
        let url = try workspace.accountDirectory(id).appendingPathComponent("fixture-commands")
        return String(decoding: try workspace.read(url), as: UTF8.self).split(separator: "\n").map(String.init)
    }
}

private final class AppTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = Date(timeIntervalSince1970: 1_800_000_000)
    var value: Date { lock.withLock { instant } }
    func nextDay() {
        lock.withLock { instant = Calendar.current.date(byAdding: .day, value: 1, to: instant)! }
    }
    func advance(hours: Double) {
        lock.withLock { instant = instant.addingTimeInterval(hours * 3600) }
    }
}

private actor AppWorker: SessionWorker {
    nonisolated let id = UUID()
    private let observation = AsyncStream<WorkerObservation>.makeStream()
    private(set) var inputs: [Data] = []
    private(set) var cancellations = 0
    private(set) var exits = 0
    private(set) var requests: [BridgeRequest] = []
    private var tool: BridgeToolCall?
    private var hold = false
    private var held: AsyncThrowingStream<BridgeEvent, Error>.Continuation?
    init(tool: BridgeToolCall? = nil) { self.tool = tool }
    func holdNextReply() { hold = true }
    /// Ends the held reply as a finished one ends.
    func finishHeldReply(_ text: String) {
        guard let sink = held else { return }
        held = nil
        sink.yield(.text(text)); sink.yield(.finished(.endTurn)); sink.finish()
    }
    func observations() -> AsyncStream<WorkerObservation> { observation.stream }
    func events(for request: BridgeRequest) -> AsyncThrowingStream<BridgeEvent, Error> {
        requests.append(request)
        let text = request.messages.last?.content.stringValue ?? "Fixture completed."
        let call = tool; tool = nil
        let waiting = hold; hold = false
        return AsyncThrowingStream { sink in
            sink.yield(.usage(.init(inputTokens: 9, outputTokens: 4)))
            if waiting { held = sink; return }
            if let call { sink.yield(.toolUse(call)); sink.yield(.finished(.toolUse)) }
            else { sink.yield(.text(text)); sink.yield(.finished(.endTurn)) }
            sink.finish()
        }
    }
    func sendInput(_ data: Data) { inputs.append(data) }
    func cancel() {
        cancellations += 1; held?.finish(throwing: BridgeFailure.cancelled); held = nil
        observation.continuation.yield(.attention)
    }
    func close() -> Bool {
        held?.finish(throwing: BridgeFailure.cancelled); held = nil; observation.continuation.finish(); return true
    }
    func requestExit() -> Bool {
        held?.finish(throwing: BridgeFailure.cancelled); held = nil
        exits += 1; observation.continuation.yield(.ended); observation.continuation.finish(); return true
    }
}

private final class AppQuotaFixture: @unchecked Sendable {
    static let defaultPanel = "Settings Status Config Usage Stats\r\nCurrent session 25% used\r\nCurrent week (all models) 10% used"
    private let lock = NSLock(), workspace: OwnedWorkspace
    private let panel: String
    private var needsTrust: Bool
    private var launches = 0
    private var interrupts = 0
    private var sent: [Data] = []
    var launchCount: Int { lock.withLock { launches } }
    var interruptCount: Int { lock.withLock { interrupts } }
    var inputs: [Data] { lock.withLock { sent } }
    init(workspace: OwnedWorkspace, needsTrust: Bool, panel: String) {
        self.workspace = workspace; self.needsTrust = needsTrust; self.panel = panel
    }
    func launch(_ plan: SessionLaunch) throws -> SessionTransport {
        lock.withLock { launches += 1 }
        let events = AsyncStream<PTYEvent>.makeStream()
        if lock.withLock({ needsTrust }) {
            try hook("PermissionRequest", plan: plan)
            events.continuation.yield(.output(Data("Trust this workspace?".utf8)))
        } else {
            try hook("SessionStart", plan: plan)
            events.continuation.yield(.output(Data("> ".utf8)))
        }
        return SessionTransport(events: events.stream, write: { data in
            self.lock.withLock { self.sent.append(data) }
            if self.lock.withLock({ self.needsTrust }) {
                self.lock.withLock { self.needsTrust = false }
                try self.hook("SessionStart", plan: plan)
                events.continuation.yield(.output(Data("\u{1b}[2J\u{1b}[H> ".utf8)))
            } else if data == Data("/usage".utf8) {
                events.continuation.yield(.output(Data("\r> /usage".utf8)))
            } else if data == Data([13]) {
                events.continuation.yield(.output(Data("\u{1b}[2J\u{1b}[H\(self.panel)".utf8)))
            } else if data.first == 27 {
                events.continuation.yield(.output(Data("\u{1b}[2J\u{1b}[H> ".utf8)))
            }
        }, interrupt: {
            // Like the official client, a second Ctrl-C ends the process.
            let count = self.lock.withLock { self.interrupts += 1; return self.interrupts }
            if count % 2 == 0 { events.continuation.yield(.exited(130)); events.continuation.finish() }
        }, exit: { events.continuation.yield(.exited(0)); events.continuation.finish() }, waitForExit: { 0 })
    }
    private func hook(_ event: String, plan: SessionLaunch) throws {
        let file = plan.runDirectory.appendingPathComponent("events/1000-\(UUID().uuidString).json")
        try workspace.write(try JSONValue.object(["event": .string(event), "session_id": .string(plan.sessionID.uuidString)]).encoded(), to: file)
    }
}

/// A synthetic Claude Desktop: its settings live under a temporary home and its app is a fake.
@MainActor
final class AppDesktopFixture {
    let home: URL
    private let workspace: OwnedWorkspace?
    var installed = true
    var launches: [Date] = []
    var answer = true
    var refusesToQuit = false
    var quitWait: TimeInterval = 30
    private(set) var opened = 0
    private(set) var quits = 0
    private(set) var confirmations = 0

    init(workspace: OwnedWorkspace?) throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("pool-desktop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        self.workspace = workspace
    }
    deinit { try? FileManager.default.removeItem(at: home) }

    var control: DesktopAppControl {
        DesktopAppControl(home: home,
            installedURL: { [self] in installed ? URL(fileURLWithPath: "/Applications/Claude.app") : nil },
            launchDates: { [self] in launches },
            running: { [self] in !launches.isEmpty },
            quit: { [self] in quits += 1; if !refusesToQuit { launches = [] } },
            open: { [self] _ in opened += 1; launches = [Date.distantFuture]; return true },
            confirm: { [self] _, _, _, _ in confirmations += 1; return answer },
            quitWait: quitWait)
    }

    /// Connects the way the app does, with the workspace's gateway key.
    func connect(port: UInt16 = PoolPreferences().port) throws {
        guard let workspace else { return }
        let key = workspace.root.appendingPathComponent("gateway-key")
        let token: String
        if let data = try? workspace.read(key, limit: 128), let text = String(data: data, encoding: .utf8) { token = text }
        else { token = String(repeating: "c4", count: 32); try workspace.write(Data(token.utf8), to: key) }
        try DesktopConnection(home: home, record: workspace.root.appendingPathComponent("desktop-connection.json"))
            .connect(baseURL: DesktopConnection.baseURL(port: port), token: token, now: Date(timeIntervalSince1970: 0))
    }
    func put(_ text: String, _ path: String) throws {
        let url = home.appendingPathComponent("Library/Application Support").appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    func json(_ path: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: home.appendingPathComponent("Library/Application Support").appendingPathComponent(path)))
    }
}
