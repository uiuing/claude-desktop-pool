import AppKit
import Foundation
import PoolCore
import PoolEngine
import PoolGateway
import PoolRuntime
import PoolPrivacy
import Security
import Network

struct AppServiceDependencies {
    var runtimeFactory: @Sendable (OwnedWorkspace) -> ManagedRuntime = { ManagedRuntime(workspace: $0) }
    var clientFactory: @Sendable (URL, OwnedWorkspace) -> OfficialCLI = { OfficialCLI(executable: $0, workspace: $1) }
    var privacyModelFactory: @Sendable (OwnedWorkspace) -> any PrivacyModelManaging = { AstrLinkDetector(workspace: $0) }
    var quotaLaunch: QuotaRefreshService.Launch = { try SessionTransport.launch($0) }
    var workerFactory: PoolCoordinator.WorkerFactory?
    /// Nil leaves Claude Desktop alone; the app passes `.live`, tests a synthetic home.
    var desktop: DesktopAppControl?
    var gatewayPort: UInt16?
    var observeSystemEvents = true
    var preparePrivacyAutomatically = true
    var checkRuntimeUpdatesAutomatically = true
    /// The official client installs on first launch and updates by itself; running sessions keep
    /// the binary they started with.
    var installRuntimeAutomatically = true
    /// Each account's sign-in is checked quietly at launch and every few hours, so a changed plan,
    /// a lapsed subscription or a revoked sign-in is noticed without a click.
    var checkAccountsAutomatically = true
    var now: @Sendable () -> Date = { Date() }
    var showWindow: @MainActor () -> Void = {
        PoolWindowNavigator.shared.show()
    }
}

@MainActor
final class AppServices {
    let model: PoolAppModel
    private let workspaceOverride: OwnedWorkspace?
    private let dependencies: AppServiceDependencies
    private(set) var listeningPort: UInt16?
    private var workspace: OwnedWorkspace?
    private var store: PoolStore?
    private var library = PoolLibrary()
    private var coordinator: PoolCoordinator?
    private var server: GatewayServer?
    private var gatewayToken: String?
    private var managedRuntime: ManagedRuntime?
    private var quotaService: QuotaRefreshService?
    private var warmUpScheduler: WarmUpScheduler?
    /// The official session a warm-up is running in, closed with the app.
    private var warmUpSession: (any SessionWorker)?
    private var privacyDetector: (any PrivacyModelManaging)?
    private var privacyBridge: PrivacyBridge?
    private var privacyInstallTask: Task<Void, Error>?
    private var privacyPreviewTask: Task<PrivacyPreview, Error>?
    private var previewGeneration = 0
    private var generatingSessions: [UUID: AccountScope] = [:]
    private var quotaObservers: [UUID: UUID] = [:]
    private var pathMonitor: NWPathMonitor?
    private var lifecycleObservers: [NSObjectProtocol] = []
    private var awake = true
    private var sessionActive = true
    private var online = true
    private var officialClient: OfficialCLI?
    private var pendingMutation: Task<Void, Error>?
    private var loginProcesses: [UUID: OwnedPTY] = [:]
    private var pendingAccounts: [UUID: PoolAccount] = [:]
    private var closingLogins: Set<UUID> = []
    private var runtimeUpdateInFlight = false
    private var privacyUpdateInFlight = false
    private var runtimeUpdateRecord: RuntimeUpdateRecord?
    private var runtimeInstallID = UUID()
    private struct RuntimeUpdateRecord: Codable {
        var attemptedAt: Date
        var installedVersion: String
        var availableVersion: String?
        var successful = false
    }
    private var checkingAccounts: Set<UUID> = []
    private var accountChecks: [UUID: Task<AuthStatus, Error>] = [:]
    private var terminalScreens: [UUID: TerminalScreen] = [:]
    private var terminalLinkCollectors: [UUID: TerminalLinkCollector] = [:]
    private var loaded = false
    private var workspaceClaim: OwnedWorkspace.Claim?
    private var recoveryTask: Task<Void, Never>?
    private var accountCheckTask: Task<Void, Never>?
    private var lastQuietCheck = Date.distantPast
    /// When each account was last checked because a read failed, so a failing read checks it at most hourly.
    private var failedReadChecks: [UUID: Date] = [:]
    /// When the account next in line was last read ahead of a switch.
    private var nextConfirmations: [Date] = []
    private var diagnosticsLog: DiagnosticsLog?
    /// The developer recording, when the developer turned it on and confirmed it at launch.
    private var developerRecorder: DeveloperRecorder?
    private var usageStore: UsageStore?
    /// Replies are counted at once and written a little later, so a busy pool writes once, not per reply.
    private var usageSaveTask: Task<Void, Never>?
    /// Quota readings come with every reply and change little but their time: they are kept at once and
    /// written a little later, so a busy pool writes its library once in a while, not per reply.
    private var librarySaveTask: Task<Void, Never>?

    init(model: PoolAppModel, workspace: OwnedWorkspace? = nil, dependencies: AppServiceDependencies = .init()) {
        self.model = model; workspaceOverride = workspace; self.dependencies = dependencies
    }

    func load() async {
        guard !loaded, !model.demo else { return }
        loaded = true
        do {
            let workspace: OwnedWorkspace
            if let workspaceOverride { workspace = workspaceOverride }
            else {
                let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                         appropriateFor: nil, create: false)
                workspace = OwnedWorkspace(root: support.appendingPathComponent("Claude Pool", isDirectory: true))
            }
            try workspace.prepare()
            if workspaceOverride == nil {
                do { workspaceClaim = try workspace.claim() }
                catch RuntimeError.workspaceInUse { yieldToRunningCopy(); throw RuntimeError.workspaceInUse }
                // Only the copy that holds the workspace writes the log.
                if let directory = try? DiagnosticsLog.standardDirectory() {
                    let log = DiagnosticsLog(directory: directory)
                    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
                    if (try? log.install(version: version)) != nil { diagnosticsLog = log }
                }
                startDeveloperRecordingIfAsked(workspace)
            }
            let store = PoolStore(workspace: workspace)
            library = try await store.load()
            if library.accounts.contains(where: { $0.email?.isEmpty != false }) {
                library.accounts.removeAll { $0.email?.isEmpty != false }
                try await store.save(library)
            }
            self.workspace = workspace; self.store = store
            let usageStore = UsageStore(workspace: workspace)
            self.usageStore = usageStore
            model.usage = await usageStore.load()
            let runtime = dependencies.runtimeFactory(workspace)
            managedRuntime = runtime
            model.preferences = library.preferences
            model.snapshot.accounts = library.accounts
            if model.snapshot.mode == .attention { model.snapshot.mode = .stopped }
            do {
                if let installation = try await runtime.current() { await useRuntimePresentation(installation) }
            } catch {
                model.runtime.phase = .failed
                let previous = try? await runtime.previousInstallation()
                model.runtime.previousVersion = previous?.version
                report(error)
            }
            if let bytes = try? workspace.read(workspace.root.appendingPathComponent("runtime-update.json"), limit: 4096),
               let record = try? JSONDecoder().decode(RuntimeUpdateRecord.self, from: bytes) {
                runtimeUpdateRecord = record
                if !record.successful { model.runtime.updateCheckMessage = model.t("Could not check for updates. Try again.") }
                if record.installedVersion == model.runtime.installedVersion,
                   let version = record.availableVersion,
                   version.range(of: #"\A[0-9]+\.[0-9]+\.[0-9]+(?:-[A-Za-z0-9.-]+)?\z"#, options: .regularExpression) != nil {
                    model.runtime.availableVersion = version; model.runtime.phase = .updateAvailable
                }
            }
            refreshDesktop()
            privacyDetector = dependencies.privacyModelFactory(workspace)
            if let privacyDetector { presentPrivacyStatus(await privacyDetector.status(), version: await privacyDetector.installedVersion()) }
            if model.snapshot.executableReady, dependencies.preparePrivacyAutomatically, model.privacy.phase == .notInstalled {
                do { try await installPrivacyModel() } catch { report(error) }
            }
            do { try await prepareQuotaService() } catch { report(error) }
            await prepareWarmUp()
            if model.snapshot.executableReady {
                // A signed-in account that was never read gets its first reading without waiting for the pool to start.
                for account in library.accounts where [.ready, .limited].contains(account.state) && account.windows.isEmpty {
                    await quotaService?.requestRefresh(accountID: account.id, reason: .initial)
                }
            }
            observeAvailability()
            keepRecovering()
            if dependencies.checkAccountsAutomatically { keepCheckingAccounts() }
            await startPoolIfReady()
            if dependencies.installRuntimeAutomatically, !model.snapshot.executableReady, model.runtime.phase == .notInstalled {
                Task { await self.handle(.installRuntime) }
            }
            await checkRuntimeUpdateIfNeeded()
        } catch {
            loaded = store != nil
            report(error)
        }
    }

    func handle(_ action: UIAction) async {
        guard !model.demo else { return }
        await load()
        guard workspace != nil, store != nil else { return }
        let serial: Bool
        switch action {
        case .sendTerminalInput, .sendTerminalKey, .cancelSession, .requestSessionExit,
             .previewPrivacy, .clearPrivacyPreview, .clearPrivacyReview, .closeTerminal, .warmUpNow, .showLog,
             .showDeveloperRecording, .stopDeveloperRecording: serial = false
        default: serial = true
        }
        if serial {
            guard !model.isWorking else { return }
            model.isWorking = true
        }
        defer { if serial { model.isWorking = false } }
        // The queued reads, or nothing to read, take over from the tap's own spin.
        defer { if case .refreshQuota = action { model.quotaReadRequested = false } }
        // Once connected, the pool serves: whatever completed setup also starts it.
        defer { if serial { Task { await self.startPoolIfReady() } } }
        do {
            switch action {
            case .installRuntime, .updateRuntime: try await installRuntime()
            case .checkRuntimeUpdate: try await checkRuntimeUpdate()
            case .installPrivacyModel: try await installPrivacyModel()
            case .previewPrivacy(let text): await previewPrivacy(text)
            case .clearPrivacyPreview:
                previewGeneration += 1; privacyPreviewTask?.cancel(); privacyPreviewTask = nil
                model.privacyPreview = .init()
            case .clearPrivacyReview: model.privacyReviews.removeAll()
            case .rollbackRuntime:
                guard let managedRuntime else { throw RuntimeError.storageFailure }
                let installed = try await managedRuntime.rollback()
                await useRuntimePresentation(installed)
            case .addAccount:
                if let id = model.pendingSignInID { try await signIn(id) }
                else {
                    let account = PoolAccount(); pendingAccounts[account.id] = account; model.pendingSignInID = account.id
                    do { try await signIn(account.id) }
                    catch { pendingAccounts.removeValue(forKey: account.id); model.pendingSignInID = nil; throw error }
                }
            case .signIn(let id): try await signIn(id)
            case .checkAccount(let id): try await checkAccount(id)
            case .refreshQuota(let accountID):
                try await prepareQuotaService()
                // A session held for the user opens for them; a reading in progress or a warm session is just read again.
                if let accountID, model.quotaRefresh[accountID]?.phase == .failed, let observer = quotaObservers.first(where: { $0.value == accountID }) {
                    model.terminal = .init(id: observer.key, title: model.accountName(accountID), output: terminalScreens[observer.key]?.text ?? "", textInputEnabled: false, canRequestExit: true, links: terminalLinkCollectors[observer.key]?.links ?? [])
                    return
                }
                let accounts = accountID.map { [$0] } ?? library.accounts.filter { [.ready, .limited].contains($0.state) }.map(\.id)
                for id in accounts { await quotaService?.requestRefresh(accountID: id, reason: .manual) }
            case .removeAccount(let id):
                if pendingAccounts[id] != nil { try await discardPendingLogin(id); return }
                if let process = loginProcesses[id] {
                    closingLogins.insert(id)
                    defer { closingLogins.remove(id) }
                    try process.interrupt(); _ = try await process.waitForExit()
                    loginProcesses.removeValue(forKey: id)
                }
                try await quiesceAccount(id)
                let client = try await cli()
                do {
                    try await client.logout(accountID: id)
                    try await mutate { $0.accounts.removeAll { $0.id == id } }
                    terminalScreens.removeValue(forKey: id)
                    terminalLinkCollectors.removeValue(forKey: id)
                    if model.terminal?.id == id { model.terminal = nil }
                } catch {
                    if let process = client.activeProcess(accountID: id) as? OwnedPTY { track(process, accountID: id, verifyOnExit: false) }
                    try await mutate { next in
                        if let index = next.accounts.firstIndex(where: { $0.id == id }) { next.accounts[index].state = .needsAttention }
                    }
                    await quotaService?.resume(accountID: id)
                    throw error
                }
            case .connectDesktop: try await connectDesktop()
            case .disconnectDesktop: try await disconnectDesktop()
            case .restartDesktop: await restartDesktop(disconnecting: false)
            case .menuBarPlan(let plan):
                try await mutate { $0.preferences.menuBarPlan = plan }
            case .sendTerminalInput(let input):
                guard let id = model.terminal?.id else { return }
                if let process = loginProcesses[id] {
                    // The sign-in prompt takes the code exactly; surrounding space from a copy is not part of it.
                    let line = input.trimmingCharacters(in: .whitespacesAndNewlines)
                    try await process.submitLine(line, bracketed: terminalScreens[id]?.bracketedPaste == true)
                }
                else if quotaObservers[id] != nil {
                    throw BridgeFailure.unsupported("Use the session controls to continue this quota check.")
                }
                // Claude sessions are the pool's own: nothing is typed into them by hand.
            case .sendTerminalKey(let key):
                guard ["\u{1b}[A", "\u{1b}[B", "\r", "\u{1b}"].contains(key), let id = model.terminal?.id else { return }
                if let process = loginProcesses[id] { try process.write(Data(key.utf8)) }
                else if quotaObservers[id] != nil { try await quotaService?.sendInput(observerID: id, data: Data(key.utf8)) }
            case .cancelSession(let id):
                if pendingAccounts[id] != nil { try await discardPendingLogin(id, closeWindow: false, reason: model.t("This sign-in was cancelled.")) }
                else if let process = loginProcesses[id] { try process.interrupt() }
                else if quotaObservers[id] != nil { try await quotaService?.sendInput(observerID: id, data: Data([3])) }
                else if !(await cancelProtectedRequest(sessionID: id)) { await coordinator?.cancelSession(id) }
            case .requestSessionExit(let id):
                if pendingAccounts[id] != nil { try await discardPendingLogin(id, closeWindow: false, reason: model.t("This sign-in was cancelled.")) }
                else if let process = loginProcesses[id] { try process.interrupt(); _ = try await process.waitForExit() }
                else if quotaObservers[id] != nil {
                    if await quotaService?.closeObserver(observerID: id) != true { throw RuntimeError.processUnresponsive }
                }
                else {
                    guard model.snapshot.sessions.contains(where: { $0.id == id && $0.state != .ended }) else { return }
                    _ = await cancelProtectedRequest(sessionID: id)
                    if await coordinator?.requestSessionExit(id) != true { throw RuntimeError.processUnresponsive }
                }
            case .closeTerminal(let id):
                if pendingAccounts[id] != nil { try await discardPendingLogin(id) }
                else if model.terminal?.id == id { model.terminal = nil }
            case .routePolicy(let policy):
                try await mutate { $0.preferences.routingPolicy = policy }
            case .quotaRefreshPreferences(let preferences):
                guard preferences.isValid else { return }
                try await mutate { $0.preferences.quotaRefresh = preferences }
            case .warmUpPreferences(let preferences):
                try await mutate { $0.preferences.warmUp = WarmUpPreferences(onReset: preferences.onReset, dailyTimes: preferences.dailyTimes) }
            case .warmUpNow(let id):
                await prepareWarmUp()
                try await warmUpScheduler?.warmNow(id)
            case .showDeveloperRecording:
                guard let recorder = developerRecorder else { return }
                NSWorkspace.shared.activateFileViewerSelecting([recorder.root])
            case .stopDeveloperRecording(let delete):
                stopDeveloperRecording(deleting: delete)
            case .showLog:
                // As in Settings › Log: the folder opens in Finder, nothing is shown in the app.
                guard let log = diagnosticsLog else { return }
                let target = FileManager.default.fileExists(atPath: log.file.path) ? log.file : log.directory
                NSWorkspace.shared.activateFileViewerSelecting([target])
            case .language(let language):
                guard (["system"] + L10n.languages.map(\.code)).contains(language) else { return }
                try await mutate { $0.preferences.language = language }
            case .appearance(let appearance):
                guard ["system", "light", "dark"].contains(appearance) else { return }
                try await mutate { $0.preferences.appearance = appearance }
            case .maskEmail(let value):
                try await mutate { $0.preferences.maskEmail = value }
            }
        } catch { report(error) }
    }

    private func mutate(later: Bool = false, _ edit: @escaping @MainActor (inout PoolLibrary) -> Void) async throws {
        let previous = pendingMutation
        let task = Task { @MainActor in
            _ = try? await previous?.value
            guard let store else { throw RuntimeError.storageFailure }
            var next = library
            edit(&next)
            guard next != library else { return }
            if later { saveLibraryLater() }
            else {
                try await store.save(next)
                // what waited to be written is in this save
                librarySaveTask?.cancel(); librarySaveTask = nil
            }
            for previous in library.accounts where !next.accounts.contains(where: { AccountScope(previous).matches($0) }) {
                model.quotaRefresh.removeValue(forKey: previous.id)
                model.quotaCadence.removeValue(forKey: previous.id)
            }
            // Every change of an account's state, at the one place the library changes.
            for account in next.accounts {
                let before = library.accounts.first { $0.id == account.id }
                guard before?.state != account.state || before?.plan != account.plan else { continue }
                Diagnostics.record("account.state", ["account": Diagnostics.id(account.id), "from": before?.state.rawValue ?? "new",
                    "to": account.state.rawValue, "plan": account.plan ?? "-",
                    "cooldown_s": account.cooldownUntil.map { String(Int($0.timeIntervalSinceNow)) } ?? "-"])
            }
            for account in library.accounts where !next.accounts.contains(where: { $0.id == account.id }) {
                Diagnostics.record("account.state", ["account": Diagnostics.id(account.id), "from": account.state.rawValue, "to": "removed"])
            }
            library = next; model.preferences = next.preferences; model.snapshot.accounts = next.accounts
            await coordinator?.updateAccounts(next.accounts)
            await coordinator?.updateRoutingPolicy(next.preferences.routingPolicy)
        }
        pendingMutation = task
        try await task.value
        await quotaService?.setPreferences(library.preferences.quotaRefresh)
        await quotaService?.setReserve(library.preferences.routingPolicy.reservePercent)
        await quotaService?.setAccounts(library.accounts)
        await warmUpScheduler?.setPreferences(library.preferences.warmUp)
        await warmUpScheduler?.setAccounts(library.accounts)
        synchronizeGeneratingAccounts()
    }

    private func installRuntime() async throws {
        guard let managedRuntime else { throw RuntimeError.storageFailure }
        let operation = UUID(); runtimeInstallID = operation
        model.runtime.phase = .installing; model.runtime.progress = nil; model.runtime.stage = "Checking release…"
        model.runtime.targetVersion = nil; model.runtime.downloadedBytes = nil; model.runtime.totalBytes = nil
        do {
            let installed = try await managedRuntime.installLatest(progress: { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.runtimeInstallID == operation, self.model.runtime.phase == .installing else { return }
                    self.model.runtime.progress = progress.fractionCompleted
                    self.model.runtime.targetVersion = progress.version
                    self.model.runtime.downloadedBytes = progress.receivedBytes
                    self.model.runtime.totalBytes = progress.totalBytes
                    switch progress {
                    case .resolving: self.model.runtime.stage = "Checking release…"
                    case .downloading: self.model.runtime.stage = "Downloading…"
                    case .verifying: self.model.runtime.stage = "Verifying…"
                    case .activating: self.model.runtime.stage = "Installing…"
                    case .completed: self.model.runtime.stage = nil
                    }
                }
            })
            await useRuntimePresentation(installed)
        } catch {
            model.runtime.phase = .failed; model.runtime.progress = nil
            throw error
        }
        if model.privacy.phase != .ready { try await installPrivacyModel() }
    }

    private func presentPrivacyStatus(_ status: AstrLinkStatus, version: String) {
        switch status {
        case .notInstalled: model.privacy.phase = .notInstalled; model.privacy.progress = nil
        case .installing(let progress): model.privacy.phase = .installing; model.privacy.progress = progress
        case .ready:
            model.privacy.phase = .ready; model.privacy.progress = nil
            model.privacy.modelVersion = version; model.privacy.message = nil
        case .failed: model.privacy.phase = .failed; model.privacy.progress = nil
        }
    }

    private func installPrivacyModel() async throws {
        if let privacyInstallTask { return try await privacyInstallTask.value }
        guard let privacyDetector else { throw PrivacyFailure.notReady }
        model.privacy.phase = .installing; model.privacy.progress = 0; model.privacy.message = nil
        let task = Task { [weak self] in
            try await privacyDetector.install(progress: { progress in
                Task { @MainActor in
                    guard let self, self.model.privacy.phase == .installing else { return }
                    self.model.privacy.progress = progress
                }
            })
        }
        privacyInstallTask = task
        defer { privacyInstallTask = nil }
        do {
            try await task.value
            presentPrivacyStatus(await privacyDetector.status(), version: await privacyDetector.installedVersion())
        } catch {
            model.privacy.phase = .failed; model.privacy.progress = nil
            model.privacy.message = model.t(PrivacyFailure.installationFailed.errorDescription!)
            throw PrivacyFailure.installationFailed
        }
    }

    private func previewPrivacy(_ text: String) async {
        previewGeneration += 1
        let generation = previewGeneration
        privacyPreviewTask?.cancel()
        guard let privacyDetector else { return }
        model.privacyPreview = .init(phase: .working)
        let task = Task { try await PrivacyBridge.preview(text, detector: privacyDetector) }
        privacyPreviewTask = task
        do {
            let result = try await task.value
            guard generation == previewGeneration else { return }
            model.privacyPreview = .init(phase: .ready, text: result.maskedText, protectedCount: result.maskedOccurrences,
                categories: result.categories.keys.sorted(by: { $0.rawValue < $1.rawValue }).map {
                    PrivacyCategoryCount(id: $0.rawValue, title: $0.rawValue, count: result.categories[$0] ?? 0)
                })
        } catch {
            guard generation == previewGeneration else { return }
            let failure = error as? PrivacyFailure ?? .modelFailed
            model.privacyPreview = .init(phase: .failed, message: model.t(failure.errorDescription!))
        }
        if generation == previewGeneration { privacyPreviewTask = nil }
    }

    private func receivePrivacy(_ update: PrivacyUpdate) async {
        switch update {
        case .processing(let active): model.privacy.isProcessing = active > 0
        case .protected(let statistics):
            model.privacy.protectedCount = statistics.maskedOccurrences
            model.privacy.requestCount = statistics.protectedRequests
            if model.privacy.phase != .failed { model.privacy.message = nil }
        case .blocked(let failure):
            model.privacy.message = model.t(failure.errorDescription!)
            if [.notReady, .modelFailed, .invalidDetection].contains(failure) { model.privacy.phase = .failed }
        case .model(let failure):
            // Requests are not held for the model: the rules redact them alone until it answers again.
            guard model.privacy.phase != .installing else { break }
            if let failure {
                model.privacy.message = model.t(failure.errorDescription!)
                if [.notReady, .modelFailed, .invalidDetection].contains(failure) { model.privacy.phase = .failed }
            } else if model.privacy.phase == .failed {
                model.privacy.phase = .ready; model.privacy.message = nil
            }
        case .requestState: break
        case .reviewed(let review):
            model.privacyReviews = PrivacyReview.kept([review] + model.privacyReviews)
        case .restored(let id, let count):
            if let index = model.privacyReviews.firstIndex(where: { $0.id == id }) { model.privacyReviews[index].restored = count }
        }
        await refreshTerminalInputEligibility()
    }

    private func useRuntimePresentation(_ installation: ManagedRuntimeInstallation) async {
        let previous = try? await managedRuntime?.previousInstallation()
        model.runtime = .init(phase: .ready, installedVersion: installation.version, previousVersion: previous?.version)
        model.snapshot.executableReady = true
        // Existing inference/auth processes keep the immutable binary they started with.
        officialClient = nil
        await updateQuotaAvailability()
    }

    func checkRuntimeUpdateIfNeeded() async {
        await checkPrivacyUpdateIfNeeded()
        guard dependencies.checkRuntimeUpdatesAutomatically, !model.demo, loaded, workspace != nil,
              model.snapshot.executableReady, !model.isWorking, !model.runtime.busy, !runtimeUpdateInFlight else { return }
        let now = dependencies.now()
        if let record = runtimeUpdateRecord, record.attemptedAt <= now,
           Calendar.current.isDate(record.attemptedAt, inSameDayAs: now) { return }
        do { try await checkRuntimeUpdate() }
        catch { model.runtime.updateCheckMessage = model.t("Could not check for updates. Try again."); return }
        if dependencies.installRuntimeAutomatically, model.runtime.phase == .updateAvailable { await handle(.updateRuntime) }
    }

    /// AstrLink Guard updates the way the client does: one check a day, installed by itself beside
    /// the version in use, which keeps protecting conversations until the new one has loaded.
    private func checkPrivacyUpdateIfNeeded() async {
        guard dependencies.checkRuntimeUpdatesAutomatically, !model.demo, loaded, let workspace, let privacyDetector,
              model.privacy.phase == .ready, model.privacy.updatingTo == nil, !privacyUpdateInFlight else { return }
        let now = dependencies.now(), recordURL = workspace.root.appendingPathComponent("privacy-update.json")
        if let data = try? workspace.read(recordURL, limit: 4096),
           let last = try? JSONDecoder().decode(Date.self, from: data), last <= now,
           Calendar.current.isDate(last, inSameDayAs: now) { return }
        privacyUpdateInFlight = true
        defer { privacyUpdateInFlight = false }
        try? workspace.write(JSONEncoder().encode(now), to: recordURL)
        do {
            switch try await privacyDetector.checkForUpdate() {
            case .none: model.privacy.updateMessage = nil
            case .needsNewerApp(let version):
                model.privacy.updateMessage = model.t("AstrLink Guard {0} needs a newer Claude Pool.", version)
            case .available(let release):
                model.privacy.updatingTo = release.version; model.privacy.updateMessage = nil
                defer { model.privacy.updatingTo = nil }
                try await privacyDetector.update(to: release, progress: { _ in })
                model.privacy.modelVersion = await privacyDetector.installedVersion()
            }
        } catch {
            model.privacy.updateMessage = model.t("Could not update AstrLink Guard. The current version keeps working.")
        }
    }

    private func checkRuntimeUpdate() async throws {
        guard let managedRuntime, let workspace else { throw RuntimeError.storageFailure }
        guard !runtimeUpdateInFlight else { return }
        runtimeUpdateInFlight = true
        defer { runtimeUpdateInFlight = false }
        let previous = model.runtime
        let recordURL = workspace.root.appendingPathComponent("runtime-update.json")
        var record = RuntimeUpdateRecord(attemptedAt: dependencies.now(), installedVersion: previous.installedVersion ?? "",
                                         availableVersion: previous.availableVersion)
        try workspace.write(JSONEncoder().encode(record), to: recordURL)
        runtimeUpdateRecord = record
        model.runtime.phase = .checking
        model.runtime.stage = "Checking release…"; model.runtime.progress = nil
        model.runtime.targetVersion = nil; model.runtime.downloadedBytes = nil; model.runtime.totalBytes = nil
        do {
            let release = try await managedRuntime.checkForUpdate()
            record.availableVersion = release?.version
            record.successful = true
            try workspace.write(JSONEncoder().encode(record), to: recordURL)
            runtimeUpdateRecord = record
            model.runtime.availableVersion = release?.version
            model.runtime.updateCheckMessage = nil
            model.runtime.stage = nil
            model.runtime.phase = release == nil ? (model.snapshot.executableReady ? .ready : .notInstalled) : .updateAvailable
        } catch {
            model.runtime = previous
            model.runtime.updateCheckMessage = model.t("Could not check for updates. Try again.")
            throw error
        }
    }

    private func cli() async throws -> OfficialCLI {
        guard let workspace, let managedRuntime, let installed = try await managedRuntime.current() else { throw RuntimeError.invalidExecutable }
        if let officialClient, officialClient.executable == installed.executable { return officialClient }
        let client = dependencies.clientFactory(installed.executable, workspace)
        officialClient = client
        return client
    }

    private func signIn(_ id: UUID) async throws {
        if loginProcesses[id] != nil {
            presentLogin(id)
            return
        }
        if pendingAccounts[id] != nil {
            if checkingAccounts.contains(id) || closingLogins.contains(id) { presentLogin(id); return }
            let child = try await cli().startLogin(accountID: id)
            track(child, accountID: id, verifyOnExit: true)
            return
        }
        guard let previousState = library.accounts.first(where: { $0.id == id })?.state else { return }
        try await quiesceAccount(id)
        do {
            let child = try await cli().startLogin(accountID: id)
            track(child, accountID: id, verifyOnExit: true)
        } catch {
            try await mutate { next in
                if let index = next.accounts.firstIndex(where: { $0.id == id }) { next.accounts[index].state = previousState }
            }
            await quotaService?.resume(accountID: id)
            throw error
        }
    }

    private func quiesceAccount(_ id: UUID) async throws {
        guard loginProcesses[id] == nil, !checkingAccounts.contains(id),
              let previous = library.accounts.first(where: { $0.id == id }) else { throw RuntimeError.processBusy }
        // Stop admitting requests before awaiting either type of owned process.
        try await mutate { next in
            if let index = next.accounts.firstIndex(where: { $0.id == id }) { next.accounts[index].state = .disabled }
        }
        let quotaClosed = await quotaService?.suspend(accountID: id) ?? true
        let sessionsClosed = quotaClosed ? (await coordinator?.closeAccount(id) ?? true) : false
        guard quotaClosed && sessionsClosed else {
            try await mutate { next in
                if let index = next.accounts.firstIndex(where: { $0.id == id }) { next.accounts[index].state = previous.state }
            }
            await quotaService?.resume(accountID: id)
            throw RuntimeError.processBusy
        }
    }

    private func track(_ child: OwnedPTY, accountID id: UUID, verifyOnExit: Bool) {
        loginProcesses[id] = child; terminalScreens[id] = TerminalScreen(); terminalLinkCollectors[id] = TerminalLinkCollector()
        presentLogin(id)
        Task { [weak self] in
            for await event in child.events {
                guard let self, self.loginProcesses[id] === child else { return }
                switch event {
                case .output(let data): appendTerminal(id, data: data)
                case .exited(let status):
                    finishTerminalLinks(id)
                    loginProcesses.removeValue(forKey: id)
                    if model.terminal?.id == id { model.terminal?.isRunning = false; model.terminal?.inputEnabled = false }
                    guard !closingLogins.contains(id) else { return }
                    if pendingAccounts[id] != nil {
                        do {
                            if verifyOnExit && status == 0 { try await completePendingLogin(id) }
                            else { try await discardPendingLogin(id, closeWindow: false, reason: model.t("Claude Code ended before the sign-in finished. Try again for a new sign-in link.")) }
                        } catch {
                            guard pendingAccounts[id] != nil, !closingLogins.contains(id) else { return }
                            let reason = message(for: error)
                            do { try await discardPendingLogin(id, closeWindow: false, reason: reason) } catch { report(error) }
                        }
                    } else if verifyOnExit, library.accounts.contains(where: { $0.id == id }) {
                        var reason: String? = status == 0 ? nil : model.t("Claude Code ended before the sign-in finished. Try again for a new sign-in link.")
                        do { try await checkAccount(id) } catch { reason = message(for: error) }
                        guard model.terminal?.id == id, loginProcesses[id] == nil else { return }
                        if let reason {
                            model.terminal?.failure = reason; model.terminal?.retry = .signIn(id)
                            model.terminal?.title = model.t("Sign-in not completed")
                        } else {
                            model.terminal = nil
                            model.notice = model.t("Signed in as {0}.", model.accountName(id))
                        }
                    }
                }
            }
        }
    }

    private func presentLogin(_ id: UUID) {
        let verifying = checkingAccounts.contains(id), closing = closingLogins.contains(id)
        let title = closing ? model.t("Closing sign-in…") : verifying ? model.t("Checking sign-in…") : model.accountName(id)
        model.terminal = .init(id: id, title: title, output: terminalScreens[id]?.text ?? "",
                              inputEnabled: !verifying && !closing, textInputEnabled: !verifying && !closing,
                              canRequestExit: true, isPendingSignIn: pendingAccounts[id] != nil, links: terminalLinkCollectors[id]?.links ?? [])
    }

    private func completePendingLogin(_ id: UUID) async throws {
        guard var account = pendingAccounts[id] else { return }
        checkingAccounts.insert(id)
        defer { checkingAccounts.remove(id) }
        if model.terminal?.id == id { presentLogin(id) }
        let status = try await cli().authenticationStatus(accountID: id)
        guard pendingAccounts[id] != nil, !closingLogins.contains(id) else { return }
        account.email = status.email; account.plan = status.plan; account.identityFingerprint = status.identityFingerprint
        account.state = status.subscription == .subscribed ? .ready : status.subscription == .required ? .subscriptionRequired : .needsAttention
        if library.accounts.contains(where: { $0.hasSameIdentity(as: account) }) {
            try await discardPendingLogin(id, closeWindow: false, reason: model.t("{0} is already in the pool. Sign in with a different account.", model.displayEmail(status.email)))
            return
        }
        let verifiedAccount = account
        try await mutate { next in
            guard self.pendingAccounts[id] != nil, !self.closingLogins.contains(id) else { return }
            next.accounts.append(verifiedAccount)
        }
        guard !closingLogins.contains(id), library.accounts.contains(where: { $0.id == id }) else { return }
        pendingAccounts.removeValue(forKey: id); model.pendingSignInID = nil
        // The account row now carries the result; an ended successful sign-in has nothing left to inspect.
        if model.terminal?.id == id { model.terminal = nil }
        model.notice = model.t("Signed in as {0}.", model.displayEmail(status.email))
        terminalScreens.removeValue(forKey: id)
        terminalLinkCollectors.removeValue(forKey: id)
        if status.subscribed { await quotaService?.requestRefresh(accountID: id, reason: .initial) }
    }

    private func discardPendingLogin(_ id: UUID, closeWindow: Bool = true, reason: String? = nil) async throws {
        guard pendingAccounts[id] != nil, !closingLogins.contains(id) else { return }
        closingLogins.insert(id)
        defer { closingLogins.remove(id) }
        if model.terminal?.id == id { model.terminal?.inputEnabled = false; model.terminal?.title = model.t("Closing sign-in…") }
        let client = try await cli()
        if let process: any OwnedChild = loginProcesses[id] ?? client.activeProcess(accountID: id) {
            if process.isRunning {
                do { try process.interrupt() } catch RuntimeError.processExited {}
            }
            _ = try await process.waitForExit(timeout: 5)
            loginProcesses.removeValue(forKey: id)
        }
        do { try await client.logout(accountID: id) }
        catch {
            if let process = client.activeProcess(accountID: id) as? OwnedPTY { track(process, accountID: id, verifyOnExit: false) }
            throw error
        }
        try await mutate { $0.accounts.removeAll { $0.id == id } }
        pendingAccounts.removeValue(forKey: id); terminalScreens.removeValue(forKey: id)
        terminalLinkCollectors.removeValue(forKey: id)
        if model.pendingSignInID == id { model.pendingSignInID = nil }
        if model.terminal?.id == id {
            if closeWindow { model.terminal = nil }
            else {
                model.terminal?.isRunning = false; model.terminal?.inputEnabled = false
                model.terminal?.isPendingSignIn = false; model.terminal?.links = []
                model.terminal?.title = model.t("Sign-in not completed")
                model.terminal?.failure = reason ?? model.t("Claude Code ended before the sign-in finished. Try again for a new sign-in link."); model.terminal?.retry = .addAccount
            }
        }
    }

    @discardableResult
    private func checkAccount(_ id: UUID, refreshQuota: Bool = true, automatic: Bool = false) async throws -> AuthStatus {
        guard library.accounts.contains(where: { $0.id == id }) else { throw BridgeFailure.unavailable }
        guard loginProcesses[id] == nil else { throw RuntimeError.processBusy }
        let status: AuthStatus
        if let existing = accountChecks[id] { status = try await existing.value }
        else {
            checkingAccounts.insert(id)
            let task = Task { try await self.performAccountCheck(id, automatic: automatic) }
            accountChecks[id] = task
            defer { accountChecks.removeValue(forKey: id); checkingAccounts.remove(id) }
            status = try await task.value
        }
        if refreshQuota, status.subscribed, library.accounts.first(where: { $0.id == id })?.state == .ready {
            await quotaService?.requestRefresh(accountID: id, reason: .initial)
        }
        return status
    }

    /// `automatic` is a quiet check nobody asked for: it leaves a hold Anthropic placed, and the
    /// account's reads, as they are, and acts only on a definite answer.
    private func performAccountCheck(_ id: UUID, automatic: Bool = false) async throws -> AuthStatus {
        let client = try await cli()
        do {
            let status = try await client.authenticationStatus(accountID: id)
            var duplicate = false, before: PoolAccount?, after: PoolAccount?
            try await mutate { next in
                guard let index = next.accounts.firstIndex(where: { $0.id == id }) else { return }
                before = next.accounts[index]
                if next.accounts[index].email?.lowercased() != status.email.lowercased() ||
                    next.accounts[index].identityFingerprint != status.identityFingerprint || next.accounts[index].plan != status.plan {
                    next.accounts[index].windows = []
                    next.accounts[index].cooldownUntil = nil
                }
                switch status.subscription {
                case .subscribed:
                    if !(automatic && next.accounts[index].state == .suspended) { next.accounts[index].state = .ready }
                case .required: next.accounts[index].state = .subscriptionRequired
                case .unknown: next.accounts[index].state = .needsAttention
                }
                next.accounts[index].plan = status.plan
                next.accounts[index].email = status.email
                next.accounts[index].identityFingerprint = status.identityFingerprint
                // A limit still in force keeps the account limited until its reset.
                Self.reconcileQuotaState(&next.accounts[index])
                duplicate = next.accounts.contains { $0.id != id && $0.hasSameIdentity(as: next.accounts[index]) }
                if duplicate { next.accounts[index].state = .disabled }
                after = next.accounts[index]
            }
            if !automatic { await quotaService?.resume(accountID: id) }
            if duplicate { model.notice = model.t("This account is already connected. The duplicate sign-in is excluded from routing.") }
            else if automatic, let before, let after {
                if before.plan != after.plan, let plan = after.plan {
                    model.notice = model.t("{0} is now on {1}. Its quota is read again.", model.displayEmail(status.email), model.t(plan))
                } else if before.state != .subscriptionRequired, after.state == .subscriptionRequired {
                    model.notice = model.t("{0} no longer has a Claude subscription, so the pool leaves it out.", model.displayEmail(status.email))
                } else if before.state == .subscriptionRequired, after.state == .ready {
                    model.notice = model.t("{0} has a subscription again and is back in the pool.", model.displayEmail(status.email))
                }
            }
            Diagnostics.record("account.check", ["account": Diagnostics.id(id), "automatic": automatic ? "yes" : "no",
                "outcome": status.subscription.rawValue, "from": before.map { "\($0.state)" } ?? "-", "to": after.map { "\($0.state)" } ?? "-"])
            return status
        } catch {
            let failure = error
            if let process = client.activeProcess(accountID: id) as? OwnedPTY, loginProcesses[id] == nil {
                track(process, accountID: id, verifyOnExit: false)
            }
            // A quiet check that could not run (offline, a slow client) says nothing about the account.
            if let error = failure as? RuntimeError, [.signedOut, .unsupportedAuthentication, .invalidAuthentication].contains(error),
               !automatic || error == .signedOut {
                try await mutate { next in
                    guard let index = next.accounts.firstIndex(where: { $0.id == id }) else { return }
                    next.accounts[index].state = error == .signedOut ? .signedOut : .needsAttention
                }
            }
            Diagnostics.record("account.check", ["account": Diagnostics.id(id), "automatic": automatic ? "yes" : "no",
                "outcome": (failure as? RuntimeError).map { "\($0)" } ?? "error"])
            if !automatic { await quotaService?.resume(accountID: id) }
            throw failure
        }
    }

    private func token() throws -> String {
        if let gatewayToken { return gatewayToken }
        guard let workspace else { throw RuntimeError.storageFailure }
        let url = workspace.root.appendingPathComponent("gateway-key")
        let value: String
        do {
            let bytes = try workspace.read(url, limit: 128)
            guard let text = String(data: bytes, encoding: .utf8), text.count == 64,
                  text.allSatisfy({ $0.isHexDigit }) else { throw RuntimeError.invalidLibrary }
            value = text
        } catch RuntimeError.missingFile {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw RuntimeError.storageFailure }
            value = bytes.map { String(format: "%02x", $0) }.joined()
            try workspace.write(Data(value.utf8), to: url)
        }
        gatewayToken = value; return value
    }

    private var desktopConnection: DesktopConnection? {
        guard let desktop = dependencies.desktop, let workspace else { return nil }
        return DesktopConnection(home: desktop.home, record: workspace.root.appendingPathComponent("desktop-connection.json"))
    }
    private var desktopBaseURL: String { DesktopConnection.baseURL(port: library.preferences.port) }

    /// Reads Desktop's settings again: on launch, on activation and when Desktop starts or quits.
    func refreshDesktop() {
        guard let desktop = dependencies.desktop, let connection = desktopConnection, let token = try? token() else { return }
        let link: DesktopLink
        switch connection.status(baseURL: desktopBaseURL, token: token) {
        case .disconnected: link = desktop.installedURL() == nil ? .notInstalled : .disconnected
        case .changed: link = .changed
        case .outdated: link = .outdated
        case .connected:
            let stale = connection.connectedAt.map { at in desktop.launchDates().contains { $0 < at } } ?? false
            link = stale ? .needsRestart : .connected
        }
        let linked = !model.snapshot.desktop.isLinked && link.isLinked
        model.snapshot.desktop = link
        if linked { Task { await startPoolIfReady() } }
    }

    /// One click: Pool writes Desktop's gateway settings, then opens Desktop, or restarts it after
    /// asking when it already runs on what it read before.
    private func connectDesktop() async throws {
        guard let desktop = dependencies.desktop, let connection = desktopConnection else { return }
        guard let app = desktop.installedURL() else {
            refreshDesktop(); model.notice = model.t("Install Claude Desktop, then connect it."); return
        }
        try connection.connect(baseURL: desktopBaseURL, token: token(), now: dependencies.now())
        refreshDesktop()
        if !desktop.running() { _ = await desktop.open(app); refreshDesktop() }
        else if model.snapshot.desktop == .needsRestart { await restartDesktop(disconnecting: false) }
    }

    private func disconnectDesktop() async throws {
        guard let desktop = dependencies.desktop, let connection = desktopConnection else { return }
        let changed = try connection.disconnect()
        refreshDesktop()
        if changed, desktop.running() { await restartDesktop(disconnecting: true) }
    }

    private func restartDesktop(disconnecting: Bool) async {
        guard let desktop = dependencies.desktop, let app = desktop.installedURL() else { return }
        if desktop.running() {
            guard desktop.confirm(model.t(disconnecting ? "Restart Claude Desktop to stop using the pool?" : "Restart Claude Desktop to use the pool?"),
                                  model.t("Desktop reads its connection only as it starts. It quits as with Command-Q and opens again."),
                                  model.t("Restart"), model.t("Later")) else { return }
            desktop.quit()
            let deadline = Date().addingTimeInterval(desktop.quitWait)
            while desktop.running(), Date() < deadline { try? await Task.sleep(for: .milliseconds(250)) }
            guard !desktop.running() else {
                model.notice = model.t("Claude Desktop is still open. Quit it, then open it again."); refreshDesktop(); return
            }
        }
        if !(await desktop.open(app)) { model.notice = model.t("Could not open Claude Desktop. Open it from Applications.") }
        refreshDesktop()
    }

    /// The pool serves as soon as setup is complete: the client is installed, redaction is
    /// ready, Desktop has its connection profile and an account is signed in.
    private func startPoolIfReady() async {
        guard loaded, store != nil, model.snapshot.mode != .running, model.snapshot.mode != .stopping, model.canStartPool else { return }
        do { try await startPool() } catch { report(error) }
    }

    private func startPool() async throws {
        guard let privacyDetector, await privacyDetector.status() == .ready else { throw BridgeFailure.privacyUnavailable }
        if let coordinator, server != nil {
            await coordinator.setPaused(false); model.snapshot.mode = .running
            try await quotaService?.start()
            await updateQuotaAvailability(); return
        }
        guard let workspace, let managedRuntime,
              let helper = Bundle.main.executableURL else { throw RuntimeError.invalidExecutable }
        guard try await managedRuntime.current() != nil else { throw RuntimeError.invalidExecutable }
        guard library.accounts.contains(where: { [.ready, .limited].contains($0.state) }) else { throw BridgeFailure.unavailable }
        let coordinator = PoolCoordinator(accounts: library.accounts, routingPolicy: library.preferences.routingPolicy, factory: { [weak self] account, model in
            guard let self else { throw BridgeFailure.unavailable }
            return try await self.prepareWorker(account: account, model: model, workspace: workspace, helper: helper, runtime: managedRuntime)
        }, onUpdate: { [weak self] update in Task { @MainActor in await self?.receive(update) } })
        // Conversations go on on the accounts they were on before the app was restarted.
        if let saved = try? workspace.read(workspace.root.appendingPathComponent(Self.conversationAccountsFile), limit: 512 * 1024) {
            await coordinator.restoreRememberedAccounts(saved)
        }
        let protection = PrivacyBridge(backend: coordinator, detector: privacyDetector,
            onUpdate: { [weak self] update in Task { @MainActor in await self?.receivePrivacy(update) } })
        let server = try GatewayServer(port: dependencies.gatewayPort ?? library.preferences.port, token: try token(), backend: protection,
            models: PoolModel.listing(library.reportedModels ?? []),
            onCheck: { [weak self] check in Task { @MainActor in self?.model.desktopCheck = .init(at: check.at, failure: check.failure) } })
        listeningPort = try await server.start()
        privacyBridge = protection
        self.coordinator = coordinator; self.server = server; model.snapshot.mode = .running
        await updateQuotaAvailability()
    }

    private func prepareWorker(account: PoolAccount, model: PoolModel, workspace: OwnedWorkspace,
                               helper: URL, runtime: ManagedRuntime) async throws -> any SessionWorker {
        let status: AuthStatus
        do { status = try await checkAccount(account.id, refreshQuota: false) }
        catch RuntimeError.signedOut { throw BridgeFailure.accountUnavailable(.signedOut) }
        catch RuntimeError.unsupportedAuthentication { throw BridgeFailure.accountUnavailable(.needsAttention) }
        catch RuntimeError.processBusy { throw BridgeFailure.busy }
        catch RuntimeError.invalidAuthentication { throw BridgeFailure.compatibility }
        guard status.subscribed, let current = library.accounts.first(where: { $0.id == account.id }), current.state == .ready else {
            throw BridgeFailure.accountUnavailable(status.subscription == .required ? .subscriptionRequired : .needsAttention)
        }
        guard let installation = try await runtime.current() else { throw RuntimeError.invalidExecutable }
        if let workerFactory = dependencies.workerFactory { return try await workerFactory(current, model) }
        return OfficialSession(workspace: workspace, account: current, model: model, executable: installation.executable, helperExecutable: helper)
    }

    private func receive(_ update: EngineUpdate) async {
        switch update {
        case .session(let session):
            if session.state == .ended { finishTerminalLinks(session.id) }
            if session.state == .ended {
                model.snapshot.sessions.removeAll { $0.id == session.id }
                terminalScreens.removeValue(forKey: session.id)
                terminalLinkCollectors.removeValue(forKey: session.id)
                generatingSessions.removeValue(forKey: session.id)
            }
            else if let i = model.snapshot.sessions.firstIndex(where: { $0.id == session.id }) { model.snapshot.sessions[i] = session }
            else { model.snapshot.sessions.append(session) }
            synchronizeGeneratingAccounts()
            if session.state != .ended { await confirmNextAccount() }
            if session.state == .ended, model.terminal?.id == session.id { model.terminal?.isRunning = false; model.terminal?.inputEnabled = false }
            await refreshTerminalInputEligibility()
        case .progress(let scope, let sessionID, let progress):
            guard library.accounts.contains(where: scope.matches) else { return }
            await quotaService?.recordProgress(scope: scope, sessionID: sessionID, progress: progress)
        case .workState(let scope, let sessionID, let state, let at):
            if state == .generating, library.accounts.contains(where: scope.matches) {
                generatingSessions[sessionID] = scope
            } else if generatingSessions[sessionID] == scope {
                generatingSessions.removeValue(forKey: sessionID)
            }
            synchronizeGeneratingAccounts()
            if library.accounts.contains(where: scope.matches) {
                await quotaService?.setWorkState(scope: scope, sessionID: sessionID, state: state, at: at)
            }
        case .quota(let scope, let windows):
            var applied = false
            do { try await mutate(later: true) { next in
                applied = scope.applyObservation(to: &next.accounts) { account in
                    for window in windows {
                        if let old = account.windows.first(where: { $0.id == window.id }), old.observedAt > window.observedAt { continue }
                        account.windows.removeAll { $0.id == window.id }
                        account.windows.append(window)
                    }
                    Self.reconcileQuotaState(&account, observed: windows)
                }
            }
                if applied { await quotaService?.observe(scope: scope, windows: windows); await confirmNextAccount() }
            } catch { report(error) }
        case .accountState(let scope, let state, let cooldown):
            do { try await mutate { next in
                scope.applyObservation(to: &next.accounts) { account in
                    account.state = state; account.cooldownUntil = cooldown
                }
            } } catch { report(error) }
        case .limitUnconfirmed(let scope):
            guard let account = library.accounts.first(where: scope.matches) else { return }
            await quotaService?.requestRefresh(accountID: account.id, reason: .recovery)
        case .terminal(let id, let data): appendTerminal(id, data: data)
        case .model(let identity):
            // Clients are shown the model each alias runs on now, from their next model list.
            var changed = false
            do { try await mutate { next in changed = next.record(identity) } } catch { report(error) }
            if changed { await server?.updateModels(PoolModel.listing(library.reportedModels ?? [])) }
        case .usage(let scope, let id, let name, let usage, let at, let seconds):
            guard library.accounts.contains(where: scope.matches) else { return }
            model.usage.record(usage, accountID: scope.accountID, model: id, name: name, at: at, seconds: seconds)
            scheduleUsageSave()
        case .route(let decision):
            model.snapshot.routeDecisions.append(decision)
            if model.snapshot.routeDecisions.count > 200 { model.snapshot.routeDecisions.removeFirst(model.snapshot.routeDecisions.count - 200) }
        }
    }

    private func scheduleUsageSave() {
        guard usageSaveTask == nil else { return }
        usageSaveTask = Task { [weak self] in
            // A cancelled wait means the ledger was already saved (on quit); saving again would write after it.
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            await self?.saveUsage()
        }
    }
    private func saveLibraryLater() {
        guard librarySaveTask == nil else { return }
        librarySaveTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            await self?.saveLibrary()
        }
    }
    /// Writes what was kept to be written later, after any change still being made.
    private func saveLibrary() async {
        librarySaveTask?.cancel(); librarySaveTask = nil
        _ = try? await pendingMutation?.value
        guard let store else { return }
        do { try await store.save(library) }
        catch { Diagnostics.record("library.save", ["outcome": "failed"]) }
    }
    private func saveUsage() async {
        usageSaveTask?.cancel(); usageSaveTask = nil
        guard let usageStore else { return }
        let ledger = model.usage
        do { try await usageStore.save(ledger) }
        catch { Diagnostics.record("usage.save", ["outcome": "failed"]) }
    }

    private func appendTerminal(_ id: UUID, data: Data) {
        // Terminal UI is ephemeral. It is never included in logs or diagnostics.
        terminalScreens[id, default: TerminalScreen()].feed(data)
        terminalLinkCollectors[id, default: TerminalLinkCollector()].feed(data)
        if model.terminal?.id == id {
            model.terminal?.output = terminalScreens[id]?.text ?? ""
            model.terminal?.links = terminalLinkCollectors[id]?.links ?? []
        }
    }

    private func finishTerminalLinks(_ id: UUID) {
        terminalLinkCollectors[id]?.finish()
        if model.terminal?.id == id { model.terminal?.links = terminalLinkCollectors[id]?.links ?? [] }
    }

    private func refreshTerminalInputEligibility() async {
        guard let terminal = model.terminal, loginProcesses[terminal.id] == nil, quotaObservers[terminal.id] == nil else { return }
        var allowed = false
        if terminal.isRunning, let alias = await coordinator?.conversationAlias(for: terminal.id) {
            allowed = await privacyBridge?.canAcceptManualInput(conversationID: alias) == true
        }
        guard model.terminal?.id == terminal.id else { return }
        model.terminal?.textInputEnabled = allowed
    }

    private func cancelProtectedRequest(sessionID: UUID) async -> Bool {
        guard let alias = await coordinator?.conversationAlias(for: sessionID), let privacyBridge else { return false }
        let cancelled = await privacyBridge.cancelSession(conversationID: alias)
        if cancelled, model.terminal?.id == sessionID { model.terminal?.textInputEnabled = false }
        return cancelled
    }

    private func prepareQuotaService() async throws {
        guard quotaService == nil, let workspace, let managedRuntime, let helper = Bundle.main.executableURL else { return }
        let service = QuotaRefreshService(workspace: workspace, executable: {
            guard let installed = try await managedRuntime.current() else { throw RuntimeError.invalidExecutable }
            return installed.executable
        }, helperExecutable: helper, update: { [weak self] update in await self?.receiveQuota(update) }, launch: dependencies.quotaLaunch)
        await service.setPreferences(library.preferences.quotaRefresh)
        await service.setReserve(library.preferences.routingPolicy.reservePercent)
        await service.setAccounts(library.accounts)
        try await service.start()
        quotaService = service
        await updateQuotaAvailability()
    }

    private func prepareWarmUp() async {
        guard warmUpScheduler == nil, let workspace else { return }
        let scheduler = WarmUpScheduler(workspace: workspace, now: dependencies.now, send: { [weak self] account in
            guard let self else { throw BridgeFailure.cancelled }
            try await self.sendWarmUp(account)
        }, update: { [weak self] update in await self?.receiveWarmUp(update) })
        await scheduler.setPreferences(library.preferences.warmUp)
        await scheduler.setAccounts(library.accounts)
        for (id, state) in await scheduler.allStates() where state.warmedAt != nil { model.warmUp[id, default: .init()].warmedAt = state.warmedAt }
        warmUpScheduler = scheduler
        await scheduler.start()
        await updateQuotaAvailability()
    }

    private func receiveWarmUp(_ update: WarmUpUpdate) {
        switch update {
        case .sending(let id): model.warmUp[id, default: .init()].sending = true
        case .sent(let id, let at):
            model.warmUp[id, default: .init()].sending = false
            model.warmUp[id]?.warmedAt = at; model.warmUp[id]?.failure = nil; model.warmUp[id]?.failedAt = nil
        case .failed(let id, let reason):
            model.warmUp[id, default: .init()].sending = false
            model.warmUp[id]?.failure = reason; model.warmUp[id]?.failedAt = dependencies.now()
        }
    }

    /// One short request through the official client on `account`, which starts its limits that
    /// aren't running. What the client reports of them meanwhile is taken as a reading; without
    /// one, the account is read afterwards.
    private func sendWarmUp(_ account: PoolAccount) async throws {
        guard let workspace, let managedRuntime, let helper = Bundle.main.executableURL,
              let installation = try await managedRuntime.current() else { throw RuntimeError.invalidExecutable }
        guard let current = library.accounts.first(where: { $0.id == account.id }), current.state == .ready,
              let haiku = PoolModel.defaults.first(where: { $0.cliAlias == "haiku" }) else { throw BridgeFailure.unavailable }
        let session: any SessionWorker
        if let factory = dependencies.workerFactory { session = try await factory(current, haiku) }
        else {
            session = OfficialSession(workspace: workspace, account: current, model: haiku, executable: installation.executable,
                                      helperExecutable: helper, timeout: 120)
        }
        warmUpSession = session
        let scope = AccountScope(current), readBefore = current.windows.map(\.observedAt).max()
        let observations = await session.observations()
        let watching = Task { [weak self] in
            for await observation in observations {
                switch observation {
                case .quota(let windows): await self?.receive(.quota(scope: scope, windows: windows))
                case .accountState(let state): await self?.receive(.accountState(scope: scope, state: state, cooldownUntil: nil))
                case .model(let identity): await self?.receive(.model(identity))
                default: break
                }
            }
        }
        var failure: Error?
        do {
            let request = BridgeRequest(model: haiku.id, messages: [.init(role: "user", content: .string(WarmUpPlanner.prompt))], maxTokens: 64)
            for try await event in try await session.events(for: request) { if case .finished = event { break } }
        } catch { failure = error }
        _ = await session.close()
        watching.cancel(); warmUpSession = nil
        if let failure {
            if case BridgeFailure.accountUnavailable(let state) = failure {
                await receive(.accountState(scope: scope, state: state, cooldownUntil: nil))
            } else { await quotaService?.requestRefresh(accountID: current.id, reason: .recovery) }
            throw failure
        }
        let after = library.accounts.first(where: scope.matches)
        let readAfter = after?.windows.map(\.observedAt).max()
        // Whether the client's own figures showed the limits running, so a warm-up that a reading
        // still shows idle is visible in the log.
        let idle = after.map { account in account.windows.filter { WarmUpPlanner.idle($0, at: Date()) }.map(\.id).sorted() } ?? []
        Diagnostics.record("warmup.reading", ["account": Diagnostics.id(current.id),
            "read": readAfter == readBefore ? "none" : "status_line", "still_idle": idle.isEmpty ? "-" : idle.joined(separator: "+")])
        if readAfter == readBefore { await quotaService?.requestRefresh(accountID: current.id, reason: .manual) }
    }

    private func receiveQuota(_ update: QuotaRefreshUpdate) async {
        switch update {
        case .cadence(let scope, let snapshot):
            guard library.accounts.contains(where: scope.matches) else { return }
            model.quotaCadence[scope.accountID] = snapshot
        case .status(let scope, let status):
            guard scope.accountID == status.accountID,
                  library.accounts.contains(where: { scope.matches($0) && [.ready, .limited, .needsAttention].contains($0.state) }) else { return }
            let phase: QuotaRefreshPhase
            switch status.phase {
            case .idle, .paused: phase = .idle
            case .queued: phase = .waiting
            case .refreshing: phase = .refreshing
            // A failed read waiting for its retry is a failure, not a read in progress: an account
            // out of rotation is not retried until its reset, and would otherwise spin until then.
            case .cooldown, .needsAttention, .failed: phase = .failed
            }
            model.quotaRefresh[status.accountID] = .init(phase: phase, updatedAt: status.lastSuccessAt,
                message: status.failure.flatMap(\.errorDescription).map { model.t($0) })
            if status.failure == .authentication || status.failure == .extraUsage {
                do { try await mutate { next in
                    scope.applyObservation(to: &next.accounts) { $0.state = .needsAttention }
                } } catch { report(error) }
            }
            // A lost sign-in shows as a read that asks for it or never finishes. The account is checked
            // right away, at most hourly, so it asks to sign in rather than keep its last figures.
            if status.failure == .authentication || status.failure == .timedOut { checkAfterFailedRead(status.accountID) }
            guard library.accounts.contains(where: scope.matches) else { return }
            if status.phase == .needsAttention, let id = status.observerID {
                quotaObservers[id] = status.accountID
                if model.terminal?.id == status.accountID {
                    model.terminal = .init(id: id, title: model.accountName(status.accountID), output: terminalScreens[id]?.text ?? "", textInputEnabled: false, canRequestExit: true, links: terminalLinkCollectors[id]?.links ?? [])
                } else { model.notice = model.t("An account needs attention to refresh its quota. Open its refresh action to continue.") }
            }
        case .reading(let scope, let windows):
            // Refresh service already owns this observation; avoid feeding it back into itself.
            do { try await mutate { next in
                scope.applyObservation(to: &next.accounts) { account in
                    if let snapshotAt = windows.map(\.observedAt).max() {
                        let returned = Set(windows.map(\.id))
                        account.windows.removeAll { !returned.contains($0.id) && $0.observedAt <= snapshotAt }
                    }
                    for window in windows {
                        if let old = account.windows.first(where: { $0.id == window.id }), old.observedAt > window.observedAt { continue }
                        account.windows.removeAll { $0.id == window.id }; account.windows.append(window)
                    }
                    Self.reconcileQuotaState(&account, observed: windows)
                }
            } } catch { report(error) }
        case .terminal(let scope, let observerID, let data):
            guard library.accounts.contains(where: scope.matches) else { return }
            quotaObservers[observerID] = scope.accountID
            appendTerminal(observerID, data: data)
        case .ended(_, let observerID):
            finishTerminalLinks(observerID)
            quotaObservers.removeValue(forKey: observerID)
            terminalScreens.removeValue(forKey: observerID)
            terminalLinkCollectors.removeValue(forKey: observerID)
            if model.terminal?.id == observerID { model.terminal?.isRunning = false; model.terminal?.inputEnabled = false }
        }
    }

    private func observeAvailability() {
        guard dependencies.observeSystemEvents else { return }
        let center = NSWorkspace.shared.notificationCenter
        lifecycleObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.awake = false; await self?.updateQuotaAvailability() }
        })
        lifecycleObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.awake = true; await self?.updateQuotaAvailability()
                await self?.checkAccountsQuietly()
            }
        })
        lifecycleObservers.append(center.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sessionActive = false; await self?.updateQuotaAvailability() }
        })
        lifecycleObservers.append(center.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.sessionActive = true; await self?.updateQuotaAvailability() }
        })
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            lifecycleObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == DesktopAppControl.bundleID else { return }
                Task { @MainActor in self?.refreshDesktop() }
            })
        }
        lifecycleObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshDesktop() }
        })
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.online = path.status == .satisfied; await self?.updateQuotaAvailability() }
        }
        monitor.start(queue: DispatchQueue(label: "ClaudePool.connectivity")); pathMonitor = monitor
    }

    /// A used-up limit holds the account until it resets; once nothing holds it, it is ready again.
    /// A cooldown Claude stated still in the future keeps it limited.
    static func reconcileQuotaState(_ account: inout PoolAccount, observed: [QuotaWindow]? = nil, now: Date = Date()) {
        guard [.ready, .limited].contains(account.state), observed?.contains(where: { $0.modelFamily == nil }) ?? true else { return }
        let exhausted = account.windows.filter { $0.modelFamily == nil && $0.isExhausted(at: now) }
        if let back = exhausted.map(\.recoversAt).max() {
            account.state = .limited
            account.cooldownUntil = max(back, account.cooldownUntil ?? back)
        } else {
            account.state = account.effectiveState(at: now)
            if account.state == .ready { account.cooldownUntil = nil }
        }
    }

    /// Plans change and sign-ins are revoked without the pool being told. The accounts in use and
    /// the one next in line are checked quietly at launch, every six hours and after the Mac wakes,
    /// so a changed plan is read afresh and a revoked sign-in asks to sign in again before a switch
    /// lands on it. Other accounts are checked when chosen or on request, so a large pool costs no
    /// more than a small one.
    private func keepCheckingAccounts() {
        accountCheckTask?.cancel()
        accountCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkAccountsQuietly()
                do { try await Task.sleep(for: .seconds(6 * 3600)) } catch { return }
            }
        }
    }
    /// Content-free tags of recent conversations and the account each is on.
    static let conversationAccountsFile = "conversation-accounts.json"
    private func checkAfterFailedRead(_ id: UUID) {
        let now = Date()
        guard dependencies.checkAccountsAutomatically, now.timeIntervalSince(failedReadChecks[id] ?? .distantPast) >= 3600,
              loginProcesses[id] == nil, accountChecks[id] == nil else { return }
        failedReadChecks[id] = now
        Task { [weak self] in _ = try? await self?.checkAccount(id, refreshQuota: false, automatic: true) }
    }

    private func checkAccountsQuietly() async {
        let now = Date()
        guard dependencies.checkAccountsAutomatically, model.snapshot.executableReady, online, awake,
              now.timeIntervalSince(lastQuietCheck) >= 3600 else { return }
        lastQuietCheck = now
        // Accounts whose reads fail are checked too, in or out of rotation: a lost sign-in shows as
        // reads that never finish, and an account waiting for its weekly reset is not read before it.
        let failing = model.quotaRefresh.filter { $0.value.failing }.map(\.key)
        let watched = Set(model.currentSessionAccounts.map(\.id) + [model.nextAccount?.id].compactMap { $0 } + failing)
        for account in library.accounts where watched.contains(account.id) && [.ready, .limited].contains(account.state) {
            guard !Task.isCancelled, loginProcesses[account.id] == nil, accountChecks[account.id] == nil else { continue }
            _ = try? await checkAccount(account.id, refreshQuota: false, automatic: true)
        }
    }

    /// Limits come back at their reset without a click: at each account's recovery time the saved
    /// state follows, routing sees it, and the next reading confirms the new cycle.
    private func keepRecovering() {
        recoveryTask?.cancel()
        recoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let now = Date()
                let next = self.library.accounts.compactMap { account -> Date? in
                    guard account.state == .limited else { return nil }
                    let holds = account.windows.filter { $0.modelFamily == nil && $0.isExhausted(at: now) }.map(\.recoversAt)
                    return (holds + [account.cooldownUntil].compactMap { $0 }).filter { $0 > now }.max() ?? now
                }.min()
                if let next, next <= now {
                    do { try await self.mutate { library in
                        for index in library.accounts.indices { Self.reconcileQuotaState(&library.accounts[index], now: Date()) }
                    } } catch { self.report(error) }
                }
                let wait = min(60, max(1, (next ?? now.addingTimeInterval(60)).timeIntervalSince(Date())))
                do { try await Task.sleep(for: .seconds(wait)) } catch { return }
            }
        }
    }

    /// Quota is read whenever the client is installed, before setup finishes too: the menu bar
    /// shows it from the first account on. Only quitting stops reads.
    private func updateQuotaAvailability() async {
        await quotaService?.setAvailability(enabled: model.snapshot.executableReady && model.snapshot.mode != .stopping,
                                            awake: awake && sessionActive, online: online)
        await warmUpScheduler?.setAvailable(model.snapshot.executableReady && model.snapshot.mode != .stopping && awake && sessionActive && online)
    }

    /// As an account in use nears the switch threshold, the account next in line is read if its
    /// reading is over ten minutes old, so the switch lands on a confirmed account. A reading that
    /// moves it down the line brings the new next one, at most three in ten minutes.
    private func confirmNextAccount() async {
        let now = Date(), reserve = library.preferences.routingPolicy.reservePercent
        let nearing = model.currentSessionAccounts.contains { account in
            let quota = PoolRouting.assessment(account, model: PoolRouting.anyModel, now: now)
            return quota.state == .exhausted || (quota.headroom.map { $0 <= reserve + 15 } ?? false)
        }
        guard nearing, let next = model.nextAccount,
              now.timeIntervalSince(model.lastQuotaUpdate(next) ?? .distantPast) >= 600 else { return }
        nextConfirmations = nextConfirmations.filter { now.timeIntervalSince($0) < 600 }
        guard nextConfirmations.count < 3 else { return }
        nextConfirmations.append(now)
        await quotaService?.confirmBeforeUse(accountID: next.id)
    }
    private func synchronizeGeneratingAccounts() {
        generatingSessions = generatingSessions.filter { _, scope in
            library.accounts.contains(where: scope.matches)
        }
        model.generatingSessionIDs = Set(generatingSessions.keys)
    }

    /// Another copy already owns the accounts. Bring it forward; a packaged copy then quits.
    private func yieldToRunningCopy() {
        guard let bundle = Bundle.main.bundleIdentifier else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard let other = others.first else { return }
        other.activate()
        PoolQuit.request()
    }

    func showWindow() {
        dependencies.showWindow()
    }

    func prepareToQuit() async -> Bool {
        guard !model.demo else { return true }
        let began = Date()
        let sessionCount = model.snapshot.sessions.filter { $0.state != .ended }.count
        Diagnostics.record("app.quit", ["outcome": "started", "sessions": String(sessionCount)])
        guard !model.isWorking, privacyInstallTask == nil, !model.privacy.isProcessing else {
            Diagnostics.record("app.quit", ["outcome": "refused", "reason": "busy"])
            model.notice = model.t("Wait for the current operation to finish before quitting.")
            showWindow(); return false
        }
        do {
            for id in Array(pendingAccounts.keys) { try await discardPendingLogin(id) }
        } catch {
            report(error); showWindow(); return false
        }
        // New conversations wait while quitting. A refused quit returns to serving at once.
        let wasRunning = model.snapshot.mode == .running
        await coordinator?.setPaused(true)
        if wasRunning { model.snapshot.mode = .stopping }
        await updateQuotaAvailability()
        func refuse(_ notice: String, reason: String) async -> Bool {
            Diagnostics.record("app.quit", ["outcome": "refused", "reason": reason, "loginsOpen": String(loginProcesses.count),
                                            "ms": String(Int(Date().timeIntervalSince(began) * 1000))])
            model.notice = model.t(notice)
            if wasRunning { await coordinator?.setPaused(false); model.snapshot.mode = .running; await updateQuotaAvailability() }
            showWindow(); return false
        }
        // An account check is Pool's own and ends by itself (its client has a 15-second limit): quitting
        // waits for it rather than asking the person to finish a sign-in they never started.
        let checks = Array(accountChecks.values)
        if !checks.isEmpty {
            Diagnostics.record("app.quit", ["outcome": "waiting", "reason": "account_check", "checks": String(checks.count)])
            for check in checks { _ = try? await check.value }
        }
        // A sign-in is the person's own; Claude sessions are the pool's, and quitting ends them.
        guard loginProcesses.isEmpty, checkingAccounts.isEmpty else {
            if let id = loginProcesses.keys.first {
                presentLogin(id)
                return await refuse("An account sign-in is still open. Finish or cancel it in the sign-in window, then quit again.", reason: "sign_in")
            }
            // A sign-in just finished and its account is being confirmed; it ends by itself in seconds.
            return await refuse("Claude Pool is still confirming a new account's sign-in. Try quitting again in a few seconds.", reason: "sign_in_check")
        }
        // Observers and sessions end together: nothing here waits its turn behind a slow child.
        let quota = quotaService, pool = coordinator
        if let pool, let workspace, let saved = await pool.rememberedAccounts() {
            try? workspace.write(saved, to: workspace.root.appendingPathComponent(Self.conversationAccountsFile))
        }
        async let observersClosing = quota?.stop() ?? true
        async let sessionsClosing = pool?.shutdown() ?? true
        let (observersClosed, sessionsEnded) = await (observersClosing, sessionsClosing)
        guard observersClosed, sessionsEnded else {
            if wasRunning { try? await quota?.start() }
            return await refuse("Claude is still closing. Keep this window open and try again.",
                                reason: sessionsEnded ? "observer_open" : "session_open")
        }
        let sessionsMs = Int(Date().timeIntervalSince(began) * 1000)
        await warmUpScheduler?.stop()
        if let session = warmUpSession {
            await session.cancel()
            var ended = await session.close()
            if !ended { ended = await session.requestExit() }
            guard ended else { return await refuse("Claude is still closing. Keep this window open and try again.", reason: "warm_up_open") }
            warmUpSession = nil
        }
        privacyPreviewTask?.cancel(); previewGeneration += 1; model.privacyPreview = .init()
        await privacyDetector?.unload()
        recoveryTask?.cancel(); accountCheckTask?.cancel()
        // Every run has ended by now, so what is left is a reply saying so; a client that does not
        // read it does not hold the app open.
        await server?.stop(waitingAtMost: 3); listeningPort = nil; pathMonitor?.cancel()
        if usageSaveTask != nil { await saveUsage() }
        if librarySaveTask != nil { await saveLibrary() }
        Diagnostics.record("app.quit", ["outcome": "ended", "sessions": String(sessionCount), "sessions_ms": String(sessionsMs),
                                        "ms": String(Int(Date().timeIntervalSince(began) * 1000))])
        developerRecorder?.flush()
        return true
    }

    // MARK: Developer recording

    /// Turned on in the app's defaults (`DeveloperRecording`), which lasts seven days from when it
    /// was first seen on, or with `--developer-recording` for one launch. It starts only once the
    /// developer confirms it, before the gateway serves anything.
    private func startDeveloperRecordingIfAsked(_ workspace: OwnedWorkspace) {
        let defaults = UserDefaults.standard
        let once = ProcessInfo.processInfo.arguments.contains(DeveloperRecordingKeys.argument)
        guard once || defaults.bool(forKey: DeveloperRecordingKeys.on) else {
            defaults.removeObject(forKey: DeveloperRecordingKeys.since); return
        }
        var until: Date?
        if !once {
            let now = dependencies.now()
            let since = defaults.object(forKey: DeveloperRecordingKeys.since) as? Date ?? now
            defaults.set(since, forKey: DeveloperRecordingKeys.since)
            let end = since.addingTimeInterval(DeveloperRecordingKeys.lifetime)
            guard now < end else {
                Self.forgetDeveloperRecordingSwitch()
                Diagnostics.record("devrecord.expired", ["days": String(Int(DeveloperRecordingKeys.lifetime / 86_400))])
                return
            }
            until = end
        }
        var limits = DeveloperRecorder.defaultLimits
        if let asked = defaults.dictionary(forKey: DeveloperRecordingKeys.limits) {
            for channel in DevRecord.Channel.allCases {
                if let megabytes = (asked[channel.rawValue] as? NSNumber)?.intValue, megabytes > 0 { limits[channel] = megabytes << 20 }
            }
        }
        let recorder = DeveloperRecorder(root: workspace.root.appendingPathComponent("developer-records", isDirectory: true), limits: limits)
        let total = recorder.limits.values.reduce(0, +)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = model.t("Turn on developer recording?")
        alert.informativeText = model.t("Claude Pool will keep what it receives and sends on this Mac, including message text, the originals redaction replaced and Claude's terminal output, up to {0}. Use it only to debug Claude Pool, and delete the records when you are done.",
                                        ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file))
            + (until.map { "\n\n" + model.t("It turns itself off on {0}.", $0.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(model.locale))) } ?? "")
        alert.addButton(withTitle: model.t("Record"))
        alert.addButton(withTitle: model.t("Turn off"))
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            if !once { Self.forgetDeveloperRecordingSwitch() }
            Diagnostics.record("devrecord.declined", [:])
            return
        }
        do { try recorder.install() } catch {
            Diagnostics.record("devrecord.stopped", ["why": "folder_failed"])
            model.notice = model.t("Developer recording could not start: its folder could not be made private.")
            return
        }
        developerRecorder = recorder
        model.developerRecording = DeveloperRecordingPresentation(until: until, limitBytes: total)
    }

    private func stopDeveloperRecording(deleting: Bool) {
        Self.forgetDeveloperRecordingSwitch()
        guard let recorder = developerRecorder else { model.developerRecording = nil; return }
        recorder.uninstall()
        if deleting { recorder.deleteAll() }
        developerRecorder = nil; model.developerRecording = nil
        Diagnostics.record("devrecord.turned_off", ["deleted": deleting ? "yes" : "no"])
    }

    private static func forgetDeveloperRecordingSwitch() {
        UserDefaults.standard.removeObject(forKey: DeveloperRecordingKeys.on)
        UserDefaults.standard.removeObject(forKey: DeveloperRecordingKeys.since)
    }

    private func message(for error: Error) -> String {
        let source: String
        if let error = error as? RuntimeError { source = error.errorDescription ?? "Something needs attention." }
        else if let error = error as? PrivacyFailure { source = error.errorDescription ?? "Something needs attention." }
        else if let error = error as? RuntimeInstallError { source = error.errorDescription ?? "Something needs attention." }
        else if let error = error as? BridgeFailure { source = error.errorDescription ?? "Something needs attention." }
        else if error is DesktopConnectionError { source = "Claude Desktop's settings could not be read, so nothing was changed. Open Desktop once, then try again." }
        else { source = "The operation could not finish. Check your settings and try again." }
        return model.t(source)
    }

    private func report(_ error: Error) {
        model.notice = message(for: error)
        if store == nil { model.snapshot.mode = .attention }
    }
}
