import Foundation
import Observation
import PoolCore
import PoolPrivacy
import SwiftUI

enum UIAction: Equatable {
    case installRuntime, checkRuntimeUpdate, updateRuntime, rollbackRuntime, addAccount, signIn(UUID), checkAccount(UUID), removeAccount(UUID)
    case connectDesktop, disconnectDesktop, restartDesktop, menuBarPlan(String?), sendTerminalInput(String), sendTerminalKey(String), cancelSession(UUID)
    case requestSessionExit(UUID), closeTerminal(UUID)
    case installPrivacyModel, previewPrivacy(String), clearPrivacyPreview, clearPrivacyReview
    case language(String), appearance(String), routePolicy(RoutingPolicy), refreshQuota(UUID?), quotaRefreshPreferences(QuotaRefreshPreferences)
    case warmUpPreferences(WarmUpPreferences), warmUpNow(UUID), showLog, maskEmail(Bool), redaction(Bool)
    case fullLog(Bool), showFullLog, clearFullLog, measureFullLog
}

/// The full log's keys in the app's defaults. It is turned on in Settings › General, after two
/// confirmations, and stays on until turned off there.
enum FullLogKeys {
    static let on = "DeveloperRecording"
    /// Megabytes per channel: `{privacy = 8192; http = 2048;}`.
    static let limits = "DeveloperRecordingLimitsMB"
}

/// The full log: whether it records now and what it holds on this Mac.
struct FullLogPresentation: Equatable {
    var on = false
    var storedBytes = 0
    var limitBytes = 0
}

enum RuntimePhase: Equatable { case notInstalled, checking, installing, ready, updateAvailable, failed }
struct RuntimePresentation: Equatable {
    var phase: RuntimePhase = .notInstalled
    var installedVersion: String?
    var previousVersion: String?
    var availableVersion: String?
    var progress: Double?
    var stage: String?
    var targetVersion: String?
    var downloadedBytes: Int64?
    var totalBytes: Int64?
    var updateCheckMessage: String?
    var busy: Bool { phase == .checking || phase == .installing }
}
enum QuotaRefreshPhase: Equatable { case idle, waiting, refreshing, failed }
/// The pool starting an account's limits: now, when it last did, and why the last try failed.
struct WarmUpPresentation: Equatable {
    var sending = false
    var warmedAt: Date?
    var failure: String?
    var failedAt: Date?
}
struct QuotaRefreshPresentation: Equatable {
    var phase: QuotaRefreshPhase = .idle
    var updatedAt: Date?
    var message: String?
    var busy: Bool { phase == .waiting || phase == .refreshing }
    /// The last read failed, including while it waits to retry. Only a failure carries a message.
    var failing: Bool { message != nil }
}

/// The first setup step still to do. The client installs and redaction prepares by themselves;
/// adding an account and connecting Desktop are the person's own steps.
enum SetupStep: Equatable {
    case installClient, prepareRedaction, addAccount, getDesktop, connectDesktop, updateDesktop
    var title: String {
        switch self {
        case .installClient: return "Install Claude Code"
        case .prepareRedaction: return "Sensitive data redaction"
        case .addAccount: return "Add your first account"
        case .getDesktop, .connectDesktop: return "Connect Claude Desktop"
        case .updateDesktop: return "Update Desktop connection"
        }
    }
    @MainActor func detail(_ model: PoolAppModel) -> String {
        switch self {
        case .installClient: return model.runtime.busy ? (model.runtime.stage ?? "Installing…") : "Claude Pool uses its own official client."
        case .prepareRedaction: return model.privacyStatusTitle
        case .addAccount: return "Sign in with Claude in a separate account space."
        case .getDesktop: return "Install Claude Desktop, then connect it."
        case .connectDesktop: return "One click. Pool sets up Desktop for you and can undo it."
        case .updateDesktop: return "Desktop then loads tools only as they are needed, so conversations stay small."
        }
    }
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, services, about
    var id: String { rawValue }
    var title: String { switch self { case .general: return "General"; case .services: return "Services"; case .about: return "About" } }
}

enum PoolPage: String, CaseIterable, Identifiable {
    case pool, accounts, routing, usage, settings
    var id: String { rawValue }
    var title: String { switch self { case .pool: return "Pool"; case .accounts: return "Accounts"; case .routing: return "Routing"; case .usage: return "Usage"; case .settings: return "Settings" } }
    var symbol: String { switch self { case .pool: return "square.stack.3d.up"; case .accounts: return "person.2"; case .routing: return "arrow.triangle.branch"; case .usage: return "chart.bar.xaxis"; case .settings: return "slider.horizontal.3" } }
}

enum UsageMetric: String, CaseIterable, Identifiable {
    case tokens, cost
    var id: String { rawValue }
}

struct UsageSummaryKey: Equatable {
    var revision: Int
    var range: UsageRange
    var filter: UsageFilter
    var grouping: UsageGrouping
    var day: String
    var hour: Int
    var plans: [UUID: String]
}

/// One plan's quota. Plans have different capacities, so their percentages are never added.
struct PlanQuota: Identifiable, Equatable {
    var id: String
    var title: String
    var accountIDs: [UUID]
    /// Each limit's average remaining share across all of this plan's accounts, in display order.
    var windows: [QuotaPoolGroup]
    var usableCount: Int
    /// At a 5-hour limit or with the week used up: back at a reset.
    var limitedCount: Int
    var unreadCount: Int
    /// Signed out, needing attention, without a subscription or restricted.
    var unavailableCount: Int
    /// The earliest official reset that brings a limited account back.
    var nextRecovery: Date?
    /// The 5-hour and weekly limits that apply to every model: what the menu bar shows.
    var session: QuotaPoolGroup? { windows.first { $0.windowID == "five_hour" && $0.modelFamily == nil } }
    var week: QuotaPoolGroup? { windows.first { $0.windowID == "seven_day" && $0.modelFamily == nil } }
}

/// The figures beside the menu bar icon: what the shown plan has left in its 5-hour and weekly limits.
struct MenuBarFigures: Hashable {
    var session: Int?
    var week: Int?
}

struct PoolTerminal: Identifiable, Equatable {
    var id: UUID
    var title: String
    var output: String
    var isRunning = true
    var inputEnabled = true
    var textInputEnabled = true
    var canRequestExit = false
    var isPendingSignIn = false
    var links: [URL] = []
    /// Why an ended sign-in did not add or confirm its account, and how to start it again.
    var failure: String?
    var retry: UIAction?
    init(id: UUID, title: String, output: String, isRunning: Bool = true, inputEnabled: Bool = true, textInputEnabled: Bool = true, canRequestExit: Bool = false, isPendingSignIn: Bool = false, links: [URL] = []) {
        self.id = id; self.title = title; self.output = output
        self.isRunning = isRunning; self.inputEnabled = inputEnabled
        self.canRequestExit = canRequestExit
        self.textInputEnabled = textInputEnabled
        self.isPendingSignIn = isPendingSignIn; self.links = links
    }
}

/// One Desktop conversation, which may hold several runs (its side requests), on one account.
struct PoolConversation: Identifiable, Equatable {
    var id: String
    var number: Int
    var accountID: UUID
    var model: String
    var state: SessionState
    var startedAt: Date
    var sessionIDs: [UUID]
    var isWorking: Bool { ![.idle, .ended].contains(state) }
}
struct AccountUse: Equatable {
    var conversations = 0
    var working = false
}

@MainActor @Observable
final class PoolAppModel {
    /// A reading is timed when it is taken, so the displayed time moves with the accounts. Behind it,
    /// the new reading counts as not yet taken and its figures drop out until the next clock tick.
    var snapshot: PoolSnapshot {
        didSet { if !demo, oldValue.accounts != snapshot.accounts { displayDate = Date() } }
    }
    var preferences: PoolPreferences
    let demo: Bool
    var page = PoolPage.pool
    var settingsTab = SettingsTab.general
    /// Opens Settings at Claude Pool's version and updates.
    func showAbout() { page = .settings; settingsTab = .about }
    var runtime = RuntimePresentation()
    var privacy = PrivacyPresentation()
    var privacyPreview = PrivacyPreviewPresentation()
    /// Recent requests that had something redacted, newest first; in memory only.
    var privacyReviews: [PrivacyReview] = []
    /// The full log, shown in Settings and, while it records, beside redaction.
    var fullLog = FullLogPresentation()
    var generatingSessionIDs: Set<UUID> = []
    var quotaRefresh: [UUID: QuotaRefreshPresentation] = [:]
    var quotaCadence: [UUID: QuotaCadenceSnapshot] = [:]
    var warmUp: [UUID: WarmUpPresentation] = [:]
    var terminal: PoolTerminal?
    /// Tokens of the replies Pool served, by day, account and model.
    var usage = UsageLedger() { didSet { usageRevision &+= 1 } }
    var usageRange = UsageRange.today
    var usageFilter = UsageFilter()
    var usageGrouping = UsageGrouping.model
    var usageMetric = UsageMetric.tokens
    @ObservationIgnored private var usageRevision = 0
    @ObservationIgnored private var usageSummaryCache: (key: UsageSummaryKey, summary: UsageSummary)?
    var pendingSignInID: UUID?
    var showsSignInRisk = false
    /// Set by a tap on a refresh action until the service has queued its reads.
    var quotaReadRequested = false
    @ObservationIgnored private var signInRiskAccepted = false
    var notice: String?
    var isWorking = false
    /// Claude Pool's own release check; previews show the packaged version without reading GitHub.
    let updates: AppUpdates
    private var displayDate = Date()
    @ObservationIgnored var onAction: (@MainActor (UIAction) -> Void)?
    @ObservationIgnored var onSettingAction: (@MainActor (UIAction) async -> Void)?
    @ObservationIgnored var referenceDate: Date?

    init(snapshot: PoolSnapshot = .init(), preferences: PoolPreferences = .init(), demo: Bool = false) {
        self.snapshot = snapshot; self.preferences = preferences; self.demo = demo
        updates = AppUpdates(demo: demo, currentVersion: demo ? "0.1.0" : AppUpdates.bundleVersion)
        updates.language = { [weak self] in self?.preferences.language ?? "system" }
    }

    var now: Date { referenceDate ?? displayDate }
    /// Advances the displayed time while a view that shows it is open: every second for countdowns,
    /// coarser for the menu and menu bar. A coarse clock moves on the whole interval and also at
    /// the next limit renewal or cooldown end, so no figure lags a boundary.
    func updateClock(every interval: Double = 1) async {
        guard !demo else { return }
        while !Task.isCancelled {
            let date = Date()
            displayDate = date
            var wait = interval - date.timeIntervalSince1970.truncatingRemainder(dividingBy: interval)
            if interval > 1, let boundary = nextQuotaBoundary(after: date) { wait = min(wait, boundary.timeIntervalSince(date) + 0.05) }
            do { try await Task.sleep(for: .seconds(max(0.05, wait))) } catch { return }
        }
    }
    /// The next time any account's figures change by themselves: a limit renews or a cooldown ends.
    func nextQuotaBoundary(after date: Date) -> Date? {
        var times: [Date] = []
        for account in snapshot.accounts {
            for window in account.windows where window.state == .reported { times.append(window.recoversAt) }
            if let cooldown = account.cooldownUntil { times.append(cooldown) }
        }
        return times.filter { $0 > date }.min()
    }
    func t(_ source: String, _ arguments: String...) -> String {
        L10n.tr(source, language: preferences.language, arguments: arguments)
    }
    var locale: Locale { Locale(identifier: L10n.resolvedLanguage(preferences.language)) }
    /// The selected range, computed once per change of the ledger, the range or the hour.
    /// Reading it in a view also observes the ledger, the range, the filter and the grouping.
    var usageSummary: UsageSummary {
        let date = now, calendar = Calendar.current
        _ = usage
        let plans = usagePlans
        let key = UsageSummaryKey(revision: usageRevision, range: usageRange, filter: usageFilter, grouping: usageGrouping,
                                  day: UsageLedger.key(date, calendar: calendar), hour: calendar.component(.hour, from: date), plans: plans)
        if let cache = usageSummaryCache, cache.key == key { return cache.summary }
        let summary = usage.summary(usageRange, filter: usageFilter, grouping: usageGrouping, plans: plans, now: date, calendar: calendar)
        usageSummaryCache = (key, summary)
        return summary
    }
    /// Each account's plan as it is now; usage is grouped by it.
    var usagePlans: [UUID: String] {
        Dictionary(snapshot.accounts.map { ($0.id, $0.plan ?? "") }, uniquingKeysWith: { first, _ in first })
    }
    var preferredColorScheme: ColorScheme? {
        switch preferences.appearance { case "light": return .light; case "dark": return .dark; default: return nil }
    }
    var readyAccounts: [PoolAccount] {
        PoolRouting.candidates(snapshot.accounts, model: PoolRouting.anyModel, now: now, policy: preferences.routingPolicy, load: conversationLoad)
    }
    /// Conversations each account serves now, counted as routing counts them.
    var conversationLoad: [UUID: Int] {
        PoolRouting.conversationLoad(snapshot.sessions)
    }
    var quotaSummary: QuotaPoolSummary { QuotaPoolSummary.evaluate(snapshot.accounts, model: PoolRouting.anyModel, now: now) }
    var confirmedReadyCount: Int { quotaSummary.usableAccounts }
    var planQuotas: [PlanQuota] {
        let buckets = Dictionary(grouping: quotaSummary.groups) { String($0.id.split(separator: "/", maxSplits: 1).first ?? "") }
        return buckets.map { key, groups in
            let ordered = groups.sorted { quotaWindowOrder($0.windowID) < quotaWindowOrder($1.windowID) }
            let ids = ordered.first?.accountIDs ?? []
            let members = snapshot.accounts.filter { ids.contains($0.id) }
            let recoveries = members.compactMap { account -> Date? in
                if case .scheduled(let date) = QuotaRecovery.account(account, model: PoolRouting.anyModel, now: now) { return date }
                return nil
            }
            var title = ordered.first?.plan.map { t($0) } ?? t("Plan not reported")
            if key.hasPrefix("account:"), let id = ids.first { title += " · " + accountName(id) }
            let standings = members.map { $0.standing(at: now) }
            func count(_ kinds: AccountStanding...) -> Int { standings.filter { kinds.contains($0) }.count }
            return PlanQuota(id: key, title: title, accountIDs: ids, windows: ordered,
                             usableCount: count(.usable), limitedCount: count(.limited, .weekUsed),
                             unreadCount: count(.unread), unavailableCount: count(.unavailable), nextRecovery: recoveries.min())
        }.sorted { ($0.accountIDs.count, $1.title) > ($1.accountIDs.count, $0.title) }
    }
    /// The plan the menu bar shows: the saved choice, else the plan with the most accounts.
    var menuBarPlan: PlanQuota? {
        let plans = planQuotas
        return plans.first { $0.id == preferences.menuBarPlan } ?? plans.first
    }
    /// How the plan's accounts stand, adding up to all of them: "5 usable · 2 at limit · 3 unavailable".
    func planBreakdown(_ plan: PlanQuota) -> String {
        let parts = [t("{0} usable", "\(plan.usableCount)"),
                     plan.limitedCount > 0 ? t("{0} at limit", "\(plan.limitedCount)") : nil,
                     plan.unreadCount > 0 ? t("{0} unread", "\(plan.unreadCount)") : nil,
                     plan.unavailableCount > 0 ? t("{0} unavailable", "\(plan.unavailableCount)") : nil]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }
    /// What the shown plan has left: its 5-hour limit, and its weekly limit when it has one.
    var menuBarFigures: MenuBarFigures? {
        guard let plan = menuBarPlan else { return nil }
        let figures = MenuBarFigures(session: plan.session?.averageRemainingPercent.map { Int($0.rounded()) },
                                     week: plan.week?.averageRemainingPercent.map { Int($0.rounded()) })
        return figures.session == nil && figures.week == nil ? nil : figures
    }
    /// Accounts best first: usable by what is left, then unread, then coming back soonest, unusable last.
    var rankedAccounts: [PoolAccount] {
        AccountOrdering.ranked(snapshot.accounts, now: now, policy: preferences.routingPolicy, load: conversationLoad)
    }
    /// The account a turn moves to when its conversation's account runs low: the first usable account
    /// no conversation is on. Its quota is confirmed before the move; it is not shown as a label.
    var nextAccount: PoolAccount? {
        let busy = Set(currentSessionAccounts.map(\.id))
        let candidates = readyAccounts
        return candidates.first { !busy.contains($0.id) } ?? (busy.isEmpty ? candidates.first : nil)
    }
    /// Where routing puts a conversation Desktop starts now: the first usable account by the selection rule.
    var newConversationAccount: PoolAccount? { readyAccounts.first }
    var newConversationText: String {
        if let next = newConversationAccount { return t("New conversations: {0}", accountName(next.id)) }
        if let back = quotaSummary.recovery.nextRecoveryAt { return t("No account for new conversations · back {0}", clockTime(back)) }
        return t("No account for new conversations")
    }
    /// Accounts holding a run that has not ended, idle runs kept for their next turn included: their
    /// quota is watched. Shown to the user as conversations, never as a "current" account.
    var currentSessionAccounts: [PoolAccount] {
        let ids = Set(snapshot.sessions.filter { $0.state != .ended }.map(\.accountID))
        return snapshot.accounts.filter { ids.contains($0.id) }.sorted { accountName($0.id) < accountName($1.id) }
    }
    /// Desktop's conversations as the user sees them: a conversation's side requests (titles, summaries)
    /// are part of it, and it is on the account its latest run is on. Numbered in the order they began.
    var conversations: [PoolConversation] {
        // Claude Code's own one-off asks (titles, topics) are not the user's conversations.
        let live = snapshot.sessions.filter { $0.state != .ended && !$0.isOneOff }
        let groups = Dictionary(grouping: live) { $0.conversation ?? $0.id.uuidString }
        return groups.values.map { runs -> PoolConversation in
            let latest = runs.max { $0.startedAt < $1.startedAt }!
            let working = runs.first { ![.idle, .ended].contains($0.state) }
            return PoolConversation(id: latest.conversation ?? latest.id.uuidString, number: 0, accountID: (working ?? latest).accountID,
                                    model: (working ?? latest).model, state: working?.state ?? latest.state,
                                    startedAt: runs.map(\.startedAt).min()!, sessionIDs: runs.map(\.id))
        }.sorted { $0.startedAt < $1.startedAt }.enumerated().map { index, conversation in
            var numbered = conversation; numbered.number = index + 1; return numbered
        }
    }
    /// How many conversations are on each account, and whether one of them is answering.
    var accountUse: [UUID: AccountUse] {
        var use: [UUID: AccountUse] = [:]
        for conversation in conversations {
            use[conversation.accountID, default: .init()].conversations += 1
            if conversation.isWorking { use[conversation.accountID, default: .init()].working = true }
        }
        return use
    }
    /// "2 accounts · 3 conversations", or that there are none.
    var useSummaryText: String {
        let conversations = conversations
        guard !conversations.isEmpty else { return t("No conversations") }
        let accounts = Set(conversations.map(\.accountID)).count
        return t("In use: {0} · {1}", accounts == 1 ? t("1 account") : t("{0} accounts", "\(accounts)"), conversationCountText(conversations.count))
    }
    func conversationCountText(_ count: Int) -> String { count == 1 ? t("1 conversation") : t("{0} conversations", "\(count)") }
    /// What a conversation is doing, as the user would say it.
    func conversationStateText(_ state: SessionState) -> String {
        switch state {
        case .starting, .running: return t("Answering")
        case .waiting: return t("Running a tool")
        case .idle: return t("Waiting for your next message")
        case .attention: return t("Needs attention")
        case .ended: return t("Finished")
        }
    }
    var activeSessions: [PoolSession] { snapshot.sessions.filter { $0.state != .ended && $0.state != .idle } }
    var hasSignedInAccount: Bool { snapshot.accounts.contains { $0.state != .signedOut && $0.email?.isEmpty == false } }
    /// When Claude Desktop last checked its connection, and what would have stopped a request then.
    var desktopCheck: DesktopCheck?
    /// "Desktop checked the connection at 21:33", or why its check failed, while Desktop is linked.
    var desktopCheckText: String? {
        guard let check = desktopCheck, snapshot.desktop.isLinked else { return nil }
        guard let failure = check.failure else { return t("Desktop checked the connection at {0}.", clockTime(check.at)) }
        let reason: String
        switch failure {
        case .rateLimited(let back?): reason = t("Every account is at its limit until {0}.", clockTime(back))
        case .rateLimited(nil): reason = t("Every account is at its limit.")
        case .unavailable: reason = t("No account can be used now.")
        default: reason = t(failure.errorDescription ?? "The local request failed. Open Claude Pool for help.")
        }
        return t("Desktop's check at {0} failed: {1}", clockTime(check.at), reason)
    }
    var desktopStatus: String {
        switch snapshot.desktop {
        case .notInstalled: t("Claude Desktop is not installed.")
        case .disconnected: t("Not connected")
        case .connected: t("Connected. Chat, Cowork and Code in Desktop use the pool.")
        case .needsRestart: t("Restart Claude Desktop to start using the pool.")
        case .changed: t("Desktop's connection settings were changed.")
        case .outdated: t("Update the connection so Desktop loads tools only as they are needed.")
        }
    }
    /// Redaction that is on must be ready before the pool serves; turned off, it is not waited for.
    var redactionReady: Bool { !preferences.redaction || privacy.phase == .ready }
    var setupComplete: Bool { snapshot.executableReady && redactionReady && hasSignedInAccount && snapshot.desktop.isLinked }
    var setupStep: SetupStep? {
        if !snapshot.executableReady { return .installClient }
        if !redactionReady { return .prepareRedaction }
        if !hasSignedInAccount { return .addAccount }
        if snapshot.desktop == .notInstalled { return .getDesktop }
        if !snapshot.desktop.isLinked { return .connectDesktop }
        if snapshot.desktop == .outdated { return .updateDesktop }
        return nil
    }
    /// Whether a quota reading is running now.
    var isReadingQuota: Bool { quotaRefresh.values.contains { $0.phase == .refreshing } }
    /// A read the person asked for shows at once, through its wait in the queue, until the readings are in.
    var isRefreshingQuota: Bool { quotaReadRequested || quotaRefresh.values.contains { $0.phase == .waiting || $0.phase == .refreshing } }
    var canStartPool: Bool { setupComplete && snapshot.accounts.contains { $0.state == .ready || $0.state == .limited } }
    var orderedRoutingAccounts: [PoolAccount] {
        let ids = preferences.routingPolicy.accountOrder + snapshot.accounts.map(\.id)
        var seen = Set<UUID>()
        return ids.compactMap { id in seen.insert(id).inserted ? snapshot.accounts.first { $0.id == id } : nil }
    }
    func setRoutingStrategy(_ strategy: RoutingStrategy) {
        var policy = preferences.routingPolicy; policy.strategy = strategy; perform(.routePolicy(policy))
    }
    func setRoutingReserve(_ value: Double) {
        perform(routingReserveAction(value))
    }
    private func routingReserveAction(_ value: Double) -> UIAction {
        var policy = preferences.routingPolicy; policy.reservePercent = value; return .routePolicy(policy)
    }
    func saveRoutingReserve(_ value: Double) async -> Double {
        await performSetting(routingReserveAction(value))
        return preferences.routingPolicy.reservePercent
    }
    /// Claude Code processes running now: each conversation's, each subagent's and each short ask's.
    var liveRuns: Int { snapshot.sessions.filter { $0.state != .ended }.count }
    /// "Claude Code processes: 3", for the dashboard, the menu panel and Settings. No bound: shown only.
    var runsInUseText: String { t("Claude Code processes: {0}", String(liveRuns)) }
    /// Short tasks running now: Claude Code's own titles, topics and auto mode safety checks.
    var liveShortTasks: Int { snapshot.sessions.filter { $0.state != .ended && $0.isOneOff }.count }
    /// What the processes in use are doing: conversations (subagents among them) and short tasks, which
    /// the conversation count leaves out, so the two numbers do not look as if they disagree.
    var runsBreakdownText: String {
        t("{0} for conversations and subagents, {1} for short tasks", String(liveRuns - liveShortTasks), String(liveShortTasks))
    }
    /// What takes a process, said beside the count.
    var runsExplainedText: String { t("Conversations, subagents and short tasks take one each.") }
    func moveRoutingAccount(_ id: UUID, by offset: Int) {
        var ids = orderedRoutingAccounts.map(\.id)
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset) else { return }
        ids.swapAt(index, index + offset)
        var policy = preferences.routingPolicy; policy.accountOrder = ids; perform(.routePolicy(policy))
    }
    private func performSetting(_ action: UIAction) async {
        if let onSettingAction { await onSettingAction(action) }
        else { perform(action) }
    }
    var modeTitle: String {
        switch snapshot.mode {
        case .stopped, .ready: return t(setupComplete ? "Starting" : "Setup needed")
        case .running: return t("Running")
        case .stopping: return t("Quitting")
        case .attention: return t("Needs attention")
        }
    }
    func accountName(_ id: UUID) -> String { snapshot.accounts.first { $0.id == id }?.email.map(displayEmail) ?? t("Sign-in pending") }
    /// An email as shown in the app: masked before "@" when the person asked for it.
    func displayEmail(_ email: String) -> String { preferences.maskEmail ? EmailMask.masked(email) : email }
    var quotaWindowIDs: [String] {
        Array(Set(snapshot.accounts.flatMap { $0.windows.filter { $0.state != .notApplicable }.map(\.id) }))
            .sorted { quotaWindowOrder($0) < quotaWindowOrder($1) }
    }
    func quotaWindowOrder(_ id: String) -> String {
        switch id { case "five_hour": return "0"; case "seven_day": return "1"; default: return "2" + id }
    }
    func quotaTitle(_ id: String) -> String {
        switch id {
        case "five_hour": return t("Session limit")
        case "seven_day": return t("Weekly limit")
        case "seven_day_opus": return t("Weekly · Opus")
        case "seven_day_sonnet": return t("Weekly · Sonnet")
        default: return t("Additional limit")
        }
    }
    /// A limit by its span, as the menu shows it: "5 hours", "7 days".
    func limitName(_ id: String) -> String {
        switch id {
        case "five_hour": return t("5 hours")
        case "seven_day": return t("7 days")
        default: return quotaTitle(id)
        }
    }
    /// The shortest name, under a ring: "5h", "7d".
    func limitShortName(_ id: String) -> String {
        switch id {
        case "five_hour": return t("5h")
        case "seven_day": return t("7d")
        default: return quotaTitle(id)
        }
    }
    /// When the account's running limits reset: "Resets 5h 23:10 · 7d Mon 01:00". A limit that has
    /// not started is left out; an account with none running has not been used since they renewed.
    func nextResetText(_ account: PoolAccount) -> String {
        let global = account.windows.filter { $0.modelFamily == nil && !$0.isNotApplicable(at: now) }
            .sorted { quotaWindowOrder($0.id) < quotaWindowOrder($1.id) }
        let running = global.filter { ($0.resetsAt ?? .distantPast) > now }
        if !running.isEmpty {
            return t("Resets {0}", running.map { limitShortName($0.id) + " " + clockTime($0.resetsAt!) }.joined(separator: " · "))
        }
        if global.isEmpty { return t("Quota not read yet") }
        if global.contains(where: { ($0.usedPercent ?? 0) > 0 && $0.resetsAt == nil && !$0.isRenewed(at: now) }) { return t("Reset time not reported") }
        return t("Not used yet")
    }
    /// A usable account whose reads are failing and whose last reading is hours old, so the figures
    /// are shown as of that time. An idle account is not read by time, so age alone means nothing.
    func isStale(_ account: PoolAccount) -> Bool {
        guard account.standing(at: now) == .usable, quotaRefresh[account.id]?.failing == true,
              let last = lastQuotaUpdate(account) else { return false }
        return now.timeIntervalSince(last) > 2 * 3600
    }
    /// "Updated just now", "Updated 3 minutes ago".
    func updatedText(_ date: Date) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return t("Updated just now") }
        return t("Updated {0}", relativeTime(date))
    }
    /// "3 minutes ago", "2 hours ago".
    func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter(); formatter.locale = locale; formatter.unitsStyle = .full
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }
    /// Whether one short request would start this account's 5-hour limit now: it can be used and
    /// that limit is not running. Not offered again for ten minutes after one went through, while
    /// its reading catches up. While the pool starts 5-hour limits at their resets itself, it is
    /// offered only once the pool's own try failed: otherwise it would show during every wait
    /// the pool leaves before and between its own tries.
    func canWarmUp(_ account: PoolAccount) -> Bool {
        let state = warmUp[account.id]
        if preferences.warmUp.onReset == .all, state?.failure == nil { return false }
        return snapshot.executableReady && state?.sending != true && account.standing(at: now) == .usable &&
            (state?.warmedAt.map { now.timeIntervalSince($0) >= 600 } ?? true) &&
            account.windows.contains { $0.id == "five_hour" && WarmUpPlanner.idle($0, at: now) }
    }
    /// What the pool last did to start limits: starting one now, the last that went through, or
    /// why the latest try failed.
    var warmUpStatusText: String? {
        if let sending = warmUp.first(where: { $0.value.sending }) { return t("Starting {0}'s limits…", accountName(sending.key)) }
        let started = warmUp.compactMap { id, state in state.warmedAt.map { (id, $0) } }.max { $0.1 < $1.1 }
        let failed = warmUp.compactMap { id, state in state.failedAt.map { (id, $0, state.failure ?? "") } }.max { $0.1 < $1.1 }
        if let failed, failed.1 > started?.1 ?? .distantPast {
            return t("Couldn't start {0}'s limits: {1}", accountName(failed.0), t(failed.2))
        }
        return started.map { t("Last started {0}'s limits {1}.", accountName($0.0), relativeTime($0.1)) }
    }
    func displayedWindows(_ account: PoolAccount) -> [QuotaWindow] {
        account.windows.filter { !$0.isNotApplicable(at: now) }.sorted { quotaWindowOrder($0.id) < quotaWindowOrder($1.id) }
    }
    /// What a limit has left as shown: none while Claude refuses the account at it, whatever the
    /// last reading said (`readRemaining` keeps that reading).
    func remaining(_ account: PoolAccount, window: String) -> Double? {
        guard let reading = account.windows.first(where: { $0.id == window }) else { return nil }
        if account.isRefused(reading, at: now) { return 0 }
        return PoolRouting.remaining(reading, in: account, now: now)
    }
    func readRemaining(_ account: PoolAccount, window: String) -> Double? {
        account.windows.first { $0.id == window }.flatMap { PoolRouting.remaining($0, in: account, now: now) }
    }
    /// For a limit Claude refused the account at though its reading had room left: what the reading said.
    func refusedNote(_ account: PoolAccount, window: String) -> String? {
        guard let reading = account.windows.first(where: { $0.id == window }), account.isRefused(reading, at: now),
              let left = readRemaining(account, window: window) else { return nil }
        return t("Claude refused at this limit · usage showed {0}% left", "\(Int(left.rounded()))")
    }
    func quotaText(_ account: PoolAccount, window: String) -> String {
        if let reading = account.windows.first(where: { $0.id == window }), reading.isNotApplicable(at: now) { return t("Not applicable") }
        return remaining(account, window: window).map { "\(Int($0.rounded()))%" } ?? "—"
    }
    func poolQuotaText(_ group: QuotaPoolGroup) -> String {
        group.averageRemainingPercent.map { "\(Int($0.rounded()))%" } ?? "—"
    }
    func resetText(_ account: PoolAccount, window: String) -> String {
        guard let reading = account.windows.first(where: { $0.id == window }) else { return t("Not reported yet") }
        if reading.isNotApplicable(at: now) { return t("Not applicable") }
        if reading.waitsForFirstUse(at: now) {
            // The pool starts it itself a minute or two after its reset.
            if preferences.warmUp.onReset == .all, account.standing(at: now) == .usable, warmUp[account.id]?.failure == nil {
                return t("Starting automatically")
            }
            return t("Starts on next use")
        }
        if reading.isRenewed(at: now) { return t("Renewed · full again") }
        guard let reset = reading.resetsAt else {
            return remaining(account, window: window) == nil ? t("Not reported yet") : t("Last read {0}", clockTime(reading.observedAt))
        }
        // A countdown helps only within the day; later ones read better as their day.
        return reset.timeIntervalSince(now) < 86400
            ? t("Resets {0} · {1}", clockTime(reset), countdown(reset)) : t("Resets {0}", clockTime(reset))
    }
    func exactTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = demo ? TimeZone(identifier: "Asia/Taipei") : .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss z"
        return formatter.string(from: date)
    }
    func countdown(_ date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(now)))
        if seconds == 0 { return t("Now") }
        let days = seconds / 86400, hours = (seconds / 3600) % 24, minutes = (seconds / 60) % 60, remainder = seconds % 60
        if days > 0 { return t("in {0}d {1}h", "\(days)", "\(hours)") }
        if hours > 0 { return t("in {0}h {1}m", "\(hours)", "\(minutes)") }
        return t("in {0}m {1}s", "\(minutes)", "\(remainder)")
    }
    func lastQuotaUpdate(_ account: PoolAccount) -> Date? {
        quotaRefresh[account.id]?.updatedAt ?? account.windows.map(\.observedAt).max()
    }
    /// The calendar times are read in: Taipei for the demo, otherwise the Mac's, whose first
    /// weekday says where "this week" starts.
    private var displayCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        calendar.timeZone = demo ? TimeZone(identifier: "Asia/Taipei")! : .current
        calendar.firstWeekday = demo ? 2 : Calendar.current.firstWeekday
        return calendar
    }
    /// A time as a person says it: "14:30" today, "Tomorrow 09:00" or "Yesterday 22:10", "Fri 09:00"
    /// within this week, otherwise "Nov 12 at 09:00", with the year only when it is another year.
    /// Never a time-zone code; `exactTime` keeps the full time for tooltips.
    func clockTime(_ date: Date) -> String {
        let calendar = displayCalendar
        let formatter = DateFormatter(); formatter.locale = locale; formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "HH:mm"
        let time = formatter.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return t("Tomorrow {0}", time)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return t("Yesterday {0}", time)
        }
        let template = calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) ? "EEEHHmm"
            : calendar.isDate(date, equalTo: now, toGranularity: .year) ? "MMMdHHmm" : "yMMMdHHmm"
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
    /// "02:00 reset (in 2h 0m)", for one limit of one account.
    func shortReset(_ account: PoolAccount, window: String) -> String {
        guard let reading = account.windows.first(where: { $0.id == window }) else { return t("Not reported yet") }
        if let reset = reading.resetsAt, reset > now { return t("Resets {0}", clockTime(reset)) }
        return resetText(account, window: window)
    }
    func accountColor(_ account: PoolAccount) -> Color {
        switch account.standing(at: now) {
        case .usable: return PoolPalette.good
        case .unread: return .secondary
        case .limited, .weekUsed: return PoolPalette.amber
        case .unavailable: return account.state == .disabled ? .secondary : .red
        }
    }
    /// When a limited account is back, if Claude said.
    func backAt(_ account: PoolAccount) -> Date? {
        if case .scheduled(let date) = QuotaRecovery.account(account, model: PoolRouting.anyModel, now: now) { return date }
        return nil
    }
    /// One account's state in a few words: what it has left, or why it cannot be used and until when.
    func accountStatus(_ account: PoolAccount) -> String {
        guard account.email?.isEmpty == false else { return stateTitle(.signedOut) }
        switch account.standing(at: now) {
        case .usable:
            let headroom = PoolRouting.assessment(account, model: PoolRouting.anyModel, now: now).headroom
            return headroom.map { t("{0}% left", "\(Int($0.rounded()))") } ?? t("Available")
        case .unread: return quotaRefresh[account.id]?.busy == true ? t("Reading quota…") : t("Quota not read yet")
        case .limited: return backAt(account).map { t("5-hour limit reached · back {0}", clockTime($0)) } ?? t("Limit reached")
        case .weekUsed: return backAt(account).map { t("Week used up · back {0}", clockTime($0)) } ?? t("Week used up")
        case .unavailable: return stateTitle(account.effectiveState(at: now))
        }
    }
    func stateTitle(_ state: AccountState) -> String {
        switch state {
        case .signedOut: return t("Sign in needed")
        case .ready: return t("Available")
        case .limited: return t("Limit reached")
        case .needsAttention: return t("Needs attention")
        case .disabled: return t("Duplicate account")
        case .subscriptionRequired: return t("Subscription required")
        case .suspended: return t("Restricted by Anthropic")
        }
    }
    func sessionTitle(_ state: SessionState) -> String {
        switch state {
        case .starting: return t("Starting")
        case .running: return t("Working")
        case .waiting: return t("Waiting for you")
        case .idle: return t("Idle")
        case .attention: return t("Needs attention")
        case .ended: return t("Finished")
        }
    }
    func routeReason(_ reason: RoutingReason) -> String {
        switch reason {
        case .sessionAffinity: return t("Stayed on its account")
        case .toolContinuation: return t("Continuing the pending tool call")
        case .accountOrder: return t("Selected by account order")
        case .headroom: return t("More confirmed quota remaining")
        case .unknownQuota: return t("Quota needs confirmation")
        case .accountLimited: return t("Account is waiting for recovery")
        case .accountUnavailable: return t("Account is unavailable")
        case .paused: return t("Quitting")
        case .cancelled: return t("Request was interrupted")
        case .noAvailableAccount: return t("No available account")
        case .requestRejected: return t("Request was not accepted")
        case .lowQuota: return t("Low quota: moving between turns")
        case .quotaExhausted: return t("Quota exhausted: selecting a backup")
        case .failover: return t("Backup account selected")
        case .capacityReached: return t("Session capacity reached")
        case .modelUnavailable: return t("Model unavailable for this account")
        }
    }
    func timeText(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.locale = locale; formatter.timeStyle = .short
        formatter.timeZone = demo ? TimeZone(identifier: "Asia/Taipei") : .current
        return formatter.string(from: date)
    }
    func perform(_ action: UIAction) {
        if action == .addAccount, needsSignInRiskAcceptance { showsSignInRisk = true; return }
        if case .refreshQuota = action { quotaReadRequested = true }
        if let onAction { onAction(action) }
        else if demo { performDemo(action) }
    }
    /// Only the first account is warned about, and a sign-in that is already under way never is.
    private var needsSignInRiskAcceptance: Bool { snapshot.accounts.isEmpty && pendingSignInID == nil && !signInRiskAccepted }
    func acceptSignInRisk() {
        signInRiskAccepted = true; showsSignInRisk = false
        perform(.addAccount)
    }
    func cancelSignInRisk() { showsSignInRisk = false }

    private func performDemo(_ action: UIAction) {
        switch action {
        case .installRuntime, .updateRuntime:
            snapshot.executableReady = true
            runtime = .init(phase: .ready, installedVersion: "2.1.301")
        case .checkRuntimeUpdate: runtime.phase = .ready
        case .rollbackRuntime:
            guard let previous = runtime.previousVersion else { return }
            runtime = .init(phase: .ready, installedVersion: previous, previousVersion: runtime.installedVersion)
        case .installPrivacyModel: privacy = .init(phase: .ready, modelVersion: "0.1.3")
        case .previewPrivacy:
            privacyPreview = .init(phase: .failed, message: "Preview only. No text was inspected.")
        case .clearPrivacyPreview: privacyPreview = .init()
        case .clearPrivacyReview: privacyReviews = []
        case .addAccount:
            let id = pendingSignInID ?? UUID(); pendingSignInID = id
            terminal = .init(id: id, title: t("Sign in with Claude"), output: t("Preview only. Official sign-in will appear here."), isPendingSignIn: true)
        case .signIn(let id), .checkAccount(let id):
            terminal = .init(id: id, title: accountName(id), output: t("Preview only. Official sign-in will appear here."))
        case .removeAccount(let id): snapshot.accounts.removeAll { $0.id == id }
        case .connectDesktop, .restartDesktop: snapshot.desktop = .connected
        case .disconnectDesktop: snapshot.desktop = .disconnected
        case .menuBarPlan(let plan): preferences.menuBarPlan = plan
        case .sendTerminalInput, .sendTerminalKey: notice = t("Preview only. No input was sent.")
        case .cancelSession(let id):
            if let index = snapshot.sessions.firstIndex(where: { $0.id == id }) {
                snapshot.sessions[index].state = .attention
            } else if terminal?.id == id { terminal?.isRunning = false }
        case .requestSessionExit(let id):
            guard let index = snapshot.sessions.firstIndex(where: { $0.id == id }) else { return }
            snapshot.sessions[index].state = .ended
            if terminal?.id == id { terminal?.isRunning = false; terminal?.inputEnabled = false }
        case .showLog, .showFullLog, .measureFullLog: break
        case .fullLog(let on): fullLog.on = on
        case .clearFullLog: fullLog.storedBytes = 0
        case .language(let language): preferences.language = language
        case .appearance(let appearance): preferences.appearance = appearance
        case .maskEmail(let value): preferences.maskEmail = value
        case .redaction(let value): preferences.redaction = value
        case .closeTerminal(let id):
            if pendingSignInID == id { pendingSignInID = nil }
            if terminal?.id == id { terminal = nil }
        case .routePolicy(let policy): preferences.routingPolicy = policy
        case .refreshQuota: quotaReadRequested = false; notice = t("Preview only. No quota request was sent.")
        case .quotaRefreshPreferences(let preferences): self.preferences.quotaRefresh = preferences
        case .warmUpPreferences(let preferences): self.preferences.warmUp = preferences
        case .warmUpNow: notice = t("Preview only. No request was sent.")
        }
    }

    static func demoModel(language: String = "en", setup: Bool = false) -> PoolAppModel {
        let date = Date(timeIntervalSince1970: 1_793_772_000)
        let ids = (1...4).map { UUID(uuidString: "0a1b2c3d-1111-4aaa-8bbb-00000000000\($0)")! }
        func windows(_ session: Double, _ week: Double) -> [QuotaWindow] {
            [.init(id: "five_hour", usedPercent: session, observedAt: date.addingTimeInterval(-60), resetsAt: date.addingTimeInterval(7200)),
             .init(id: "seven_day", usedPercent: week, observedAt: date.addingTimeInterval(-60), resetsAt: date.addingTimeInterval(172800))]
        }
        let accounts = [
            PoolAccount(id: ids[0], email: "mi•••ella@example.com", plan: "Ultra", state: .ready,
                        windows: [.init(id: "seven_day", usedPercent: 36, observedAt: date.addingTimeInterval(-60), resetsAt: date.addingTimeInterval(172800))], createdAt: date),
            PoolAccount(id: ids[1], email: "sa•••ahmad@example.org", plan: "Max 5x", state: .ready, windows: windows(42, 23), createdAt: date),
            PoolAccount(id: ids[2], email: "al•••ezra@example.net", plan: "Pro", state: .limited, windows: windows(100, 61), cooldownUntil: date.addingTimeInterval(7200), createdAt: date),
            // Its 5-hour limit came back half an hour ago and has not been used since.
            PoolAccount(id: ids[3], email: "jo•••ana@example.com", plan: "Max 5x", state: .ready, windows: [
                .init(id: "five_hour", usedPercent: 21, observedAt: date.addingTimeInterval(-7200), resetsAt: date.addingTimeInterval(-1800)),
                .init(id: "seven_day", usedPercent: 38, observedAt: date.addingTimeInterval(-60), resetsAt: date.addingTimeInterval(172800))], createdAt: date)
        ]
        let model = PoolAppModel(snapshot: .init(mode: setup ? .stopped : .running, accounts: setup ? [] : accounts,
            sessions: setup ? [] : [
                .init(id: UUID(uuidString: "1a1b2c3d-1111-4aaa-8bbb-000000000001")!, accountID: ids[0], name: "Website refresh", model: "Sonnet", state: .running, startedAt: date.addingTimeInterval(-480), conversation: "demo-1"),
                .init(id: UUID(uuidString: "1a1b2c3d-1111-4aaa-8bbb-000000000002")!, accountID: ids[1], name: "Plan the next release", model: "Opus", state: .waiting, startedAt: date.addingTimeInterval(-1200), conversation: "demo-2"),
                // Conversation 1's title request: on its account, part of it, not a conversation of its own.
                .init(id: UUID(uuidString: "1a1b2c3d-1111-4aaa-8bbb-000000000003")!, accountID: ids[0], name: "Claude session", model: "Haiku", state: .idle, startedAt: date.addingTimeInterval(-470), conversation: "demo-1")
            ], executableReady: !setup, desktop: setup ? .disconnected : .connected),
            preferences: .init(language: language), demo: true)
        model.runtime = setup ? .init() : .init(phase: .ready, installedVersion: "2.1.301")
        model.privacy = setup ? .init() : .init(phase: .ready, modelVersion: "0.1.3", protectedCount: 18, requestCount: 7)
        model.generatingSessionIDs = Set(model.snapshot.sessions.filter { $0.state == .running }.map(\.id))
        if !setup { model.quotaCadence[ids[0]] = .init(interval: 45, demand: 1, generatingSessions: 1) }
        if !setup { model.warmUp[ids[1]] = .init(warmedAt: date.addingTimeInterval(-7200)) }
        if !setup {
            model.privacyReviews = [
                PrivacyReview(id: UUID(uuidString: "2a1b2c3d-1111-4aaa-8bbb-000000000001")!, at: date.addingTimeInterval(-90), fields: [
                    PrivacyReviewField(location: "messages/4/content/0/text", segments: [
                        .text("Deploy the preview to "),
                        .replaced(original: "build-07.studio.example", placeholder: "host-1", category: .hostname),
                        .text(" and send the report to "),
                        .replaced(original: "lin.mei@studio.example", placeholder: "{{EMAIL_1}}", category: .email),
                        .text(" when it passes.")])],
                    categories: [.hostname: 1, .email: 1], restored: 2),
                PrivacyReview(id: UUID(uuidString: "2a1b2c3d-1111-4aaa-8bbb-000000000002")!, at: date.addingTimeInterval(-420), fields: [
                    PrivacyReviewField(location: "messages/2/content/1/content/0/text", segments: [
                        .text("STRIPE_KEY="),
                        .replaced(original: "sk_test_51Hx2fixture0000", placeholder: "{{API_KEY_1}}", category: .apiKey),
                        .text("\nDATABASE_HOST="),
                        .replaced(original: "10.20.4.17", placeholder: "public-ip-1", category: .ip)])],
                    categories: [.apiKey: 1, .ip: 1])
            ]
        }
        if !setup {
            let session = model.snapshot.sessions[0].id
            model.snapshot.routeDecisions = [
                .init(timestamp: date.addingTimeInterval(-480), sessionID: session, accountID: ids[2], model: "Sonnet", reason: .quotaExhausted, strategy: .mostHeadroom),
                .init(timestamp: date.addingTimeInterval(-479), sessionID: session, accountID: ids[0], model: "Sonnet", reason: .failover, strategy: .mostHeadroom),
                .init(timestamp: date.addingTimeInterval(-200), sessionID: model.snapshot.sessions[1].id, accountID: ids[1], model: "Opus", reason: .headroom, strategy: .mostHeadroom),
                .init(timestamp: date.addingTimeInterval(-60), sessionID: session, accountID: ids[0], model: "Sonnet", reason: .sessionAffinity, strategy: .mostHeadroom)
            ]
        }
        if !setup { model.usage = demoUsage(ids: ids, now: date) }
        model.referenceDate = date
        return model
    }
    /// Thirty days of replies across the demo accounts, the same on every run: a few accounts carry most
    /// of the work, as in a real pool. Times count back from the demo clock, so today has replies too.
    static func demoUsage(ids: [UUID], now: Date) -> UsageLedger {
        var ledger = UsageLedger(), seed: UInt64 = 0x5EED
        func next(_ range: Int) -> Int { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Int((seed >> 33) % UInt64(max(1, range))) }
        let models = [("claude-sonnet-5-5", "Sonnet 5.5"), ("claude-opus-5-5", "Opus 5.5"), ("claude-haiku-5-5", "Haiku 5.5"), ("claude-fable-5-1", "Fable 5.1")]
        let daily = 12 + ids.count * 2
        for day in (0..<30).reversed() {
            let weekend = Calendar.current.isDateInWeekend(now.addingTimeInterval(Double(-day) * 86_400))
            for _ in 0..<((weekend ? daily / 3 : daily) + next(daily / 2)) {
                let pick = Double(next(1000)) / 1000, account = ids[min(ids.count - 1, Int(pick * pick * Double(ids.count)))]
                let roll = next(16), model = models[roll < 9 ? 0 : roll < 13 ? 1 : roll < 15 ? 2 : 3]
                let at = now.addingTimeInterval(Double(-day) * 86_400 - Double(next(10 * 3600)))
                let write = 1_000 + next(22_000)
                let usage = BridgeUsage(inputTokens: 40 + next(2_000), outputTokens: 600 + next(9_000),
                                        cacheReadInputTokens: 30_000 + next(160_000), cacheCreationInputTokens: write,
                                        oneHourCacheWrites: next(5) == 0 ? 0 : write)
                let speed = Double(30 + next(60))
                ledger.record(usage, accountID: account, model: model.0, name: model.1, at: at, seconds: Double(usage.outputTokens) / speed)
            }
        }
        return ledger
    }
    /// A pool of `count` accounts across plans, for previews of a large pool.
    static func demoAccounts(_ count: Int, at date: Date) -> [PoolAccount] {
        let plans = ["Pro", "Pro", "Pro", "Max 5x", "Pro", "Pro", "Ultra", "Pro", "Max 5x", "Pro"]
        return (0..<count).map { index in
            PoolAccount(id: UUID(uuidString: String(format: "0a1b2c3d-2222-4aaa-8bbb-%012d", index))!, email: "builder\(index + 1)@studio.example",
                        plan: plans[index % plans.count], state: .ready, windows: [], createdAt: date)
        }
    }
}

/// Claude Desktop checked its connection: when, and what would have stopped a request then.
struct DesktopCheck: Equatable {
    var at: Date
    var failure: BridgeFailure?
}
