import Foundation
import CryptoKit
import PoolCore
import PoolRuntime

/// `selected`: an account starts being used, or is next in line, with a reading older than ten minutes.
/// `settle`: the account was used since its last reading and its work has stopped.
public enum QuotaRefreshReason: String, Codable, Sendable { case initial, manual, periodic, reset, recovery, selected, settle }
public enum QuotaRefreshPhase: String, Codable, Sendable { case idle, queued, refreshing, paused, cooldown, needsAttention, failed }
public enum QuotaRefreshFailure: String, Error, Codable, Sendable, LocalizedError {
    case loading, unavailable, authentication, unsupportedFormat, timedOut, needsAttention, storage, cancelled, extraUsage
    public var errorDescription: String? {
        switch self {
        case .loading: return "Claude is still loading usage."
        case .unavailable: return "Claude could not refresh usage. The previous reading is kept."
        case .authentication: return "Sign in to this account again to refresh its usage."
        case .unsupportedFormat: return "This Claude version did not show a supported usage panel."
        case .timedOut: return "The usage refresh timed out. The previous reading is kept."
        case .needsAttention: return "The usage session needs your attention."
        case .storage: return "The usage refresh state could not be saved."
        case .cancelled: return "The usage refresh was stopped."
        case .extraUsage: return "Claude reports that this account is using usage credits. Review the account before continuing."
        }
    }
}

public struct QuotaRefreshStatus: Codable, Equatable, Sendable {
    public var accountID: UUID
    public var phase: QuotaRefreshPhase = .idle
    public var observerID: UUID?
    public var lastAttemptAt: Date?
    public var lastSuccessAt: Date?
    public var nextAttemptAt: Date?
    public var failure: QuotaRefreshFailure?
    public init(accountID: UUID) { self.accountID = accountID }
}

public enum QuotaRefreshUpdate: Sendable {
    case cadence(scope: AccountScope, snapshot: QuotaCadenceSnapshot)
    case status(scope: AccountScope, status: QuotaRefreshStatus)
    case reading(scope: AccountScope, windows: [QuotaWindow])
    case terminal(scope: AccountScope, observerID: UUID, data: Data)
    case ended(scope: AccountScope, observerID: UUID)
}

/// The visible native /usage panel is a versioned presentation adapter, not a quota estimate.
/// Recognized headings and reset forms follow Claude Code's interactive Usage screen.
public enum NativeUsageParser {
    public static func parse(_ text: String, plan: String?, observedAt: Date) throws -> [QuotaWindow] {
        guard text.utf8.count <= 256 * 1024 else { throw QuotaRefreshFailure.unsupportedFormat }
        let flat = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        let lower = flat.lowercased()
        if ["not logged in", "not signed in", "sign-in has expired", "authentication required"].contains(where: lower.contains) {
            throw QuotaRefreshFailure.authentication
        }
        if lower.contains("failed to load usage data") || lower.contains("usage is temporarily unavailable") { throw QuotaRefreshFailure.unavailable }
        if lower.contains("loading usage") { throw QuotaRefreshFailure.loading }
        // A client that lost its sign-in falls back to API billing: its panel has costs and no
        // limits, and would otherwise read as still loading until the read times out.
        // A signed-out client (2.1.318) draws the same cost-only tab without naming the billing:
        // "Session · Total cost: $0.0000 · Total duration (API) …".
        if lower.contains("api usage billing") || lower.contains("total cost:"), isPanel(flat),
           !lower.contains("current session"), !lower.contains("current week") {
            throw QuotaRefreshFailure.authentication
        }
        guard isPanel(flat) else { throw QuotaRefreshFailure.loading }
        let headings = matches(#"Current\s+(session|week(?:\s*\([^)]+\))?)"#, in: flat)
        // The panel draws its frame before its figures. A frame without them is still loading.
        guard !headings.isEmpty else { throw QuotaRefreshFailure.loading }
        guard headings.count <= 16 else { throw QuotaRefreshFailure.unsupportedFormat }
        var windows: [QuotaWindow] = [], seen = Set<String>()
        for (index, heading) in headings.enumerated() {
            guard let range = Range(heading.range, in: flat), let nameRange = Range(heading.range(at: 1), in: flat) else { continue }
            let end = index + 1 < headings.count ? Range(headings[index + 1].range, in: flat)!.lowerBound : flat.endIndex
            let section = String(flat[range.upperBound..<end])
            guard let percent = capture(#"([0-9]+(?:\.[0-9]+)?)%\s+used"#, in: section) else { throw QuotaRefreshFailure.loading }
            guard let used = Double(percent), used.isFinite, (0...100).contains(used) else { throw QuotaRefreshFailure.unsupportedFormat }
            let headingName = String(flat[nameRange]).lowercased()
            let id: String, family: String?
            if headingName == "session" { id = "five_hour"; family = nil }
            else if let scope = capture(#"\(([^)]+)\)"#, in: headingName), scope != "all models" {
                let cleaned = scope.replacingOccurrences(of: #"\s+only$"#, with: "", options: .regularExpression)
                let slug = cleaned.replacingOccurrences(of: #"[^a-z0-9]+"#, with: "_", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
                guard !slug.isEmpty else { throw QuotaRefreshFailure.unsupportedFormat }
                // An unfamiliar heading can describe a product-wide constraint. Only an
                // explicit single model family can narrow which requests it limits.
                family = ["opus", "sonnet", "haiku", "fable", "mythos"].first(where: { cleaned == $0 })
                id = "seven_day_" + slug
            } else { id = "seven_day"; family = nil }
            guard seen.insert(id).inserted else { throw QuotaRefreshFailure.unsupportedFormat }
            let resetText = capture(#"Resets\s+([^()]+\([^)]+\))"#, in: section)
            let reset = resetText.flatMap { resetTime($0, observedAt: observedAt, windowID: id) }
            windows.append(.init(id: id, usedPercent: used, observedAt: observedAt, resetsAt: reset, modelFamily: family))
        }
        guard !windows.isEmpty else { throw QuotaRefreshFailure.unsupportedFormat }
        if !seen.contains("five_hour"), seen.contains("seven_day") {
            // Official Ultra guidance identifies verification by the absent Current session bar.
            // Only a loaded panel with known Ultra identity can establish not-applicable.
            if plan == "Ultra" { windows.insert(.init(id: "five_hour", observedAt: observedAt, state: .notApplicable), at: 0) }
        }
        return windows
    }
    public static func usesExtraUsage(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("using your overages") || lower.contains("using usage credits")
    }

    public static func isPanel(_ text: String) -> Bool {
        text.range(of: #"\bSettings\b[\s\S]*\bUsage\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Named-zone calendar readings are accepted only when their date is unambiguous. Relative
    /// durations, unknown zones, missing zones, and a time-only weekly reset remain unknown.
    /// A reset up to one span in the past is kept: right after a reset Claude can still show the
    /// cycle that ended, and only its passed reset tells that reading apart from a current one.
    public static func resetTime(_ text: String, observedAt now: Date, windowID: String) -> Date? {
        guard let all = matches(#"^\s*(.+?)\s*\(([^)]+)\)\s*$"#, in: text).first,
              let dateRange = Range(all.range(at: 1), in: text), let zoneRange = Range(all.range(at: 2), in: text),
              let zone = TimeZone(identifier: String(text[zoneRange])) else { return nil }
        let value = String(text[dateRange])
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone; calendar.locale = Locale(identifier: "en_US_POSIX")
        let current = calendar.dateComponents([.year, .month, .day], from: now)
        let span: TimeInterval = windowID == "five_hour" ? 5 * 3600 : 7 * 86400
        var dates: [(Int, Int, Int)] = []
        var clock = value
        var explicitYear = false
        if let match = matches(#"^([A-Za-z]{3})\s+([0-9]{1,2})(?:,\s*([0-9]{4}))?(?:\s+at|,)?\s+(.+)$"#, in: value).first {
            func part(_ index: Int) -> String? { Range(match.range(at: index), in: value).map { String(value[$0]) } }
            let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
            guard let month = part(1).flatMap({ months.firstIndex(of: $0.lowercased()) }).map({ $0 + 1 }),
                  let day = part(2).flatMap(Int.init), (1...31).contains(day), let time = part(4), let year = current.year else { return nil }
            clock = time
            if let explicit = part(3).flatMap(Int.init) { dates = [(explicit, month, day)]; explicitYear = true }
            else { dates = [year - 1, year, year + 1].map { ($0, month, day) } }
        } else {
            guard windowID == "five_hour", let today = calendar.date(from: current) else { return nil }
            dates = [-1, 0, 1].compactMap { offset in
                guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
                let c = calendar.dateComponents([.year, .month, .day], from: day)
                return (c.year!, c.month!, c.day!)
            }
        }
        guard let time = clockComponents(clock) else { return nil }
        var candidates: [Date] = []
        for (year, month, day) in dates {
            var components = DateComponents(); components.year = year; components.month = month; components.day = day
            guard let midnight = calendar.date(from: components) else { continue }
            let check = calendar.dateComponents([.year, .month, .day], from: midnight)
            guard check.year == year, check.month == month, check.day == day else { continue }
            let target = DateComponents(hour: time.0, minute: time.1, second: 0)
            for policy in [Calendar.RepeatedTimePolicy.first, .last] {
                guard let date = calendar.nextDate(after: midnight.addingTimeInterval(-1), matching: target, matchingPolicy: .strict, repeatedTimePolicy: policy),
                      calendar.isDate(date, inSameDayAs: midnight) else { continue }
                if explicitYear || (date >= now.addingTimeInterval(-span) && date <= now.addingTimeInterval(span + 60)) { candidates.append(date) }
            }
        }
        let unique = Set(candidates)
        return unique.count == 1 ? unique.first : nil
    }
    private static func clockComponents(_ value: String) -> (Int, Int)? {
        guard let match = matches(#"^([0-9]{1,2})(?::([0-9]{2}))?\s*([ap]m)?$"#, in: value).first,
              let hourRange = Range(match.range(at: 1), in: value), var hour = Int(value[hourRange]) else { return nil }
        let minute = Range(match.range(at: 2), in: value).flatMap { Int(value[$0]) } ?? 0
        guard minute < 60 else { return nil }
        if let meridiem = Range(match.range(at: 3), in: value).map({ value[$0].lowercased() }) {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (meridiem == "pm" ? 12 : 0)
        } else { guard match.range(at: 2).location != NSNotFound, hour < 24 else { return nil } }
        return (hour, minute)
    }
    private static func matches(_ pattern: String, in value: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        return regex.matches(in: value, range: NSRange(value.startIndex..., in: value))
    }
    private static func capture(_ pattern: String, in value: String) -> String? {
        guard let match = matches(pattern, in: value).first, let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }
}

public actor QuotaRefreshService {
    public typealias Update = @Sendable (QuotaRefreshUpdate) async -> Void
    public typealias Launch = @Sendable (SessionLaunch) throws -> SessionTransport
    private struct Record: Codable {
        var status: QuotaRefreshStatus
        var scope: String?
        var failures = 0
        /// Each limit's passed reset that a reading has since moved past.
        var resetChecks: [String: Date]?
        /// Right after a reset Claude can still show the ended cycle; such a reading is retried.
        var resetAttempts: Int?
        var resetRetryAt: Date?
    }
    /// Claude takes a moment to roll a limit over; a reset is confirmed a minute after it passes.
    static let resetGrace: TimeInterval = 60
    /// A reading this recent is trusted when an account starts being used.
    static let freshFor: TimeInterval = 600
    /// Use stops counting as one stretch after this long without work.
    static let stretchGap: TimeInterval = 120
    private let workspace: OwnedWorkspace
    private let executable: @Sendable () async throws -> URL
    private let helperExecutable: URL
    private let update: Update
    private let launch: Launch
    private let observerTimeout: TimeInterval
    private let now: @Sendable () -> Date
    private var accounts: [PoolAccount] = []
    private var records: [UUID: Record] = [:]
    private var requested: [UUID: QuotaRefreshReason] = [:]
    private var suspended = Set<UUID>()
    private var generations: [UUID: UInt64] = [:]
    private var preferences = QuotaRefreshPreferences()
    private var displayedCadence: [UUID: QuotaCadenceSnapshot] = [:]
    /// Each account's read phase and failure as last written to the log.
    private var loggedStatus: [UUID: String] = [:]
    private var cadence: [UUID: QuotaCadence] = [:]
    private var burn: [UUID: QuotaBurn] = [:]
    /// When each account last generated or reported progress. Only accounts the pool uses are
    /// read by time; the rest are read at their resets, when chosen, or when asked.
    private var lastWork: [UUID: Date] = [:]
    private var reserve = 10.0
    /// A session kept at its prompt after a reading, so frequent reads of one account do not
    /// start Claude Code each time. It is ended when another account is read, when it has not
    /// been needed for a while, and on every explicit end.
    private var warm: QuotaObserver?
    private var warmSince = Date.distantPast
    private static let warmFor: TimeInterval = 90
    private var enabled = false, awake = true, online = true, started = false, stopping = false
    /// Each account's observer: reading, or held for the user. Accounts are read side by side,
    /// up to `concurrentReads` at once; a held session holds back only its own account.
    private var active: [UUID: QuotaObserver] = [:]
    static let concurrentReads = 3
    private var task: Task<Void, Never>?
    private var refreshTasks: [UUID: Task<Void, Never>] = [:]
    private var nextLaunchAt = Date.distantPast
    public init(workspace: OwnedWorkspace, executable: @escaping @Sendable () async throws -> URL,
                helperExecutable: URL, update: @escaping Update, launch: @escaping Launch = { try SessionTransport.launch($0) },
                observerTimeout: TimeInterval = 60, now: @escaping @Sendable () -> Date = { Date() }) {
        self.workspace = workspace; self.executable = executable; self.helperExecutable = helperExecutable
        self.update = update; self.launch = launch; self.observerTimeout = max(0.1, observerTimeout)
        self.now = now
    }
    public func start() async throws {
        guard !started else { return }
        try workspace.prepare()
        do {
            let saved = try JSONDecoder().decode([Record].self, from: workspace.read(stateFile, limit: 512 * 1024))
            let matching = saved.filter { record in
                guard let scope = record.scope else { return false }
                return accounts.isEmpty || accounts.contains { $0.id == record.status.accountID && Self.scopeKey($0) == scope }
            }
            let restored = Dictionary(matching.map { ($0.status.accountID, $0) }, uniquingKeysWith: { first, _ in first })
            records.merge(restored) { _, saved in saved }
            for id in records.keys {
                // A session that needed attention, or a read stopped by quitting, ended with the
                // previous run; its next read starts fresh.
                if [.needsAttention, .cancelled].contains(records[id]?.status.failure) {
                    records[id]?.status.failure = nil; records[id]?.status.nextAttemptAt = nil; records[id]?.failures = 0
                }
                let phase: QuotaRefreshPhase = [.authentication, .extraUsage].contains(records[id]?.status.failure) ? .needsAttention : .idle
                records[id]?.status.phase = phase
                records[id]?.status.observerID = nil
            }
            if !accounts.isEmpty {
                let ids = Set(accounts.map(\.id)); records = records.filter { ids.contains($0.key) }
            }
            if matching.count != saved.count, !(await persist()) { throw QuotaRefreshFailure.storage }
        } catch RuntimeError.missingFile {} catch { throw QuotaRefreshFailure.storage }
        started = true; stopping = false
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            }
        }
    }
    public func setAccounts(_ accounts: [PoolAccount]) async {
        let next = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changed = false
        for old in self.accounts {
            if let current = next[old.id], AccountScope(old).matches(current) { continue }
            generations[old.id, default: 0] &+= 1
            requested.removeValue(forKey: old.id)
            cadence.removeValue(forKey: old.id); displayedCadence.removeValue(forKey: old.id); burn.removeValue(forKey: old.id)
            lastWork.removeValue(forKey: old.id)
            records.removeValue(forKey: old.id); changed = true
        }
        self.accounts = accounts
        let kept = Set(accounts.map(\.id)); requested = requested.filter { kept.contains($0.key) }
        if records.keys.contains(where: { !kept.contains($0) }) { changed = true }
        records = records.filter { kept.contains($0.key) }
        cadence = cadence.filter { kept.contains($0.key) }
        lastWork = lastWork.filter { kept.contains($0.key) }
        displayedCadence = displayedCadence.filter { kept.contains($0.key) }
        suspended = suspended.intersection(kept)
        for account in accounts { burn[account.id, default: QuotaBurn()].record(account.windows) }
        burn = burn.filter { kept.contains($0.key) }
        if let warm, !accounts.contains(where: { AccountScope(warm.account).matches($0) }) { await retireWarm(endHeld: true) }
        for account in accounts {
            let scope = Self.scopeKey(account)
            if records[account.id]?.scope == scope {
                if let latest = account.windows.map(\.observedAt).filter({ $0 <= now() }).max(),
                   latest > (records[account.id]?.status.lastSuccessAt ?? .distantPast) {
                    records[account.id]?.status.lastSuccessAt = latest; changed = true
                }
                continue
            }
            var status = QuotaRefreshStatus(accountID: account.id)
            status.lastSuccessAt = account.windows.map(\.observedAt).max()
            records[account.id] = Record(status: status, scope: scope); changed = true
        }
        if changed, started { await persist() }
        await tick()
    }
    private static func scopeKey(_ account: PoolAccount) -> String {
        let scope = AccountScope(account)
        let values: [String?] = [scope.accountID.uuidString, scope.email, scope.identityFingerprint, scope.plan]
        let encoded = values.map { $0.map { "\($0.utf8.count):\($0)" } ?? "-" }.joined(separator: "|")
        return SHA256.hash(data: Data(encoded.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public func setPreferences(_ preferences: QuotaRefreshPreferences) async {
        guard preferences.isValid, preferences != self.preferences else { return }
        self.preferences = preferences
        discardDisabledRequests()
        await tick()
    }
    /// The switch threshold: reads come sooner as an account's tightest limit nears it.
    public func setReserve(_ percent: Double) async {
        guard percent.isFinite, (0...100).contains(percent), percent != reserve else { return }
        reserve = percent; await tick()
    }
    public func setWorkState(scope: AccountScope, sessionID: UUID, state: QuotaWorkState, at date: Date) async {
        guard acceptsActivity(scope), date <= now() else { return }
        let id = scope.accountID
        if state == .generating {
            let starting = lastWork[id].map { date.timeIntervalSince($0) >= Self.stretchGap } ?? true
            lastWork[id] = max(date, lastWork[id] ?? date)
            if starting { queueConfirmation(id) }
        }
        cadence[id, default: QuotaCadence()].setState(state, sessionID: sessionID, at: date)
        await tick()
    }
    public func recordProgress(scope: AccountScope, sessionID: UUID, progress: QuotaProgress) async {
        guard acceptsActivity(scope), progress.observedAt <= now() else { return }
        lastWork[scope.accountID] = max(progress.observedAt, lastWork[scope.accountID] ?? progress.observedAt)
        cadence[scope.accountID, default: QuotaCadence()].record(progress, sessionID: sessionID)
        await tick()
    }
    private func acceptsActivity(_ scope: AccountScope) -> Bool {
        // Quiescing pauses reads, not the owned worker. Its authoritative progress and
        // exit transitions still reconcile this scope until it is replaced or removed.
        accounts.contains { scope.matches($0) }
    }
    public func cadence(accountID: UUID) -> QuotaCadenceSnapshot {
        guard started, enabled, awake, online, !suspended.contains(accountID),
              let account = accounts.first(where: { $0.id == accountID && [.ready, .limited].contains($0.state) }) else { return .init() }
        var result = cadence[accountID]?.snapshot(at: now(), preferences: preferences) ?? .init()
        let pace = burn[accountID] ?? QuotaBurn()
        // Without work the account's figures do not move by the pool's doing: no timed reads, at
        // any pool size. Its reset, its being chosen, or the user brings the next one.
        result.interval = result.interval.map { pace.interval($0, account: account, reserve: reserve, now: now()) }
        return result
    }
    private func discardDisabledRequests() {
        requested = requested.filter { _, reason in reason != .reset || preferences.confirmAfterReset }
    }
    private func publishCadence() async {
        for account in accounts {
            var value = cadence(accountID: account.id)
            value.interval = value.interval.map { $0.rounded() }
            value.demand = (value.demand * 1000).rounded() / 1000
            // Decay changes the figures every second; the window needs only real changes.
            if let shown = displayedCadence[account.id], shown.generatingSessions == value.generatingSessions,
               (shown.interval == nil) == (value.interval == nil),
               abs((shown.interval ?? 0) - (value.interval ?? 0)) < max(5, (shown.interval ?? 0) * 0.1) { continue }
            displayedCadence[account.id] = value
            await update(.cadence(scope: AccountScope(account), snapshot: value))
        }
    }
    public func statuses() -> [UUID: QuotaRefreshStatus] { records.mapValues(\.status) }
    public func setAvailability(enabled: Bool, awake: Bool, online: Bool) async {
        self.enabled = enabled; self.awake = awake; self.online = online
        if !enabled { requested = requested.filter { $0.value == .manual || $0.value == .initial } }
        for account in accounts where active[account.id] == nil {
            if !awake || !online || (!enabled && requested[account.id] == nil) {
                records[account.id]?.status.phase = .paused; await publish(account.id)
            } else if records[account.id]?.status.phase == .paused {
                records[account.id]?.status.phase = requested[account.id] == nil ? .idle : .queued
                await publish(account.id)
            }
        }
        await tick()
    }
    /// Reads an account about to be used unless its reading is recent: the account a new
    /// conversation goes to, or the one next in line as the current one nears the threshold.
    public func confirmBeforeUse(accountID: UUID) async {
        queueConfirmation(accountID); await tick()
    }
    private func queueConfirmation(_ id: UUID) {
        guard !suspended.contains(id), let account = accounts.first(where: { $0.id == id }), account.isInRotation(at: now()),
              active[id] == nil, let record = records[id],
              now().timeIntervalSince(record.status.lastSuccessAt ?? .distantPast) >= Self.freshFor else { return }
        if let pending = requested[id], priority(pending) <= priority(.selected) { return }
        requested[id] = .selected
        if record.status.phase == .idle { records[id]?.status.phase = .queued }
    }
    public func requestRefresh(accountID: UUID, reason: QuotaRefreshReason = .manual) async {
        guard !suspended.contains(accountID), accounts.contains(where: { $0.id == accountID && [.ready, .limited, .needsAttention].contains($0.state) }) else { return }
        // A held session is this account's refresh already. Queuing another read behind it would
        // wait for itself and show a refresh that never starts.
        if active[accountID] != nil, refreshTasks[accountID] == nil {
            await publish(accountID); return
        }
        if reason == .initial, [.authentication, .needsAttention, .cancelled].contains(records[accountID]?.status.failure) {
            records[accountID]?.status.failure = nil; records[accountID]?.failures = 0
        }
        requested[accountID] = reason
        records[accountID]?.status.phase = .queued
        if records[accountID]?.status.failure == nil, reason != .periodic {
            let next = max(now(), (records[accountID]?.status.lastAttemptAt ?? .distantPast).addingTimeInterval(10))
            records[accountID]?.status.nextAttemptAt = next
        }
        await publish(accountID); await tick()
    }
    /// Quiesce before changing an account's authentication or removing its owned directory.
    public func suspend(accountID: UUID) async -> Bool {
        generations[accountID, default: 0] &+= 1
        suspended.insert(accountID); requested.removeValue(forKey: accountID)
        await publishCadence()
        records[accountID]?.status.phase = .paused; await publish(accountID)
        if warm?.account.id == accountID { await retireWarm(endHeld: true) }
        guard let observer = active[accountID] else { return true }
        refreshTasks[accountID]?.cancel()
        let closed = await close(observer, endHeld: true)
        await refreshTasks[accountID]?.value
        if closed, active[accountID]?.id == observer.id { active[accountID] = nil }
        return closed
    }
    public func resume(accountID: UUID) async {
        suspended.remove(accountID)
        if active[accountID] == nil { records[accountID]?.status.phase = .idle; await publish(accountID) }
        await tick()
    }
    public func suspendAccount(_ id: UUID) async -> Bool { await suspend(accountID: id) }
    public func resumeAccount(_ id: UUID) async { await resume(accountID: id) }
    public func observe(scope: AccountScope, windows: [QuotaWindow]) async {
        let accountID = scope.accountID
        guard accounts.contains(where: { scope.matches($0) && [.ready, .limited, .needsAttention].contains($0.state) }) else { return }
        guard var record = records[accountID], let newest = windows.map(\.observedAt).max(), newest <= now(),
              newest > (record.status.lastSuccessAt ?? .distantPast) else { return }
        record.status.lastSuccessAt = newest
        if requested[accountID] == .periodic { requested.removeValue(forKey: accountID) }
        if record.status.failure == nil {
            if active[accountID] == nil { record.status.phase = .idle }
        }
        records[accountID] = record; await persist(); await publish(accountID, scope: scope)
    }
    public func sendInput(observerID: UUID, data: Data) async throws {
        guard let observer = active.values.first(where: { $0.id == observerID }) else { throw QuotaRefreshFailure.needsAttention }
        let id = observer.account.id
        try await observer.sendInput(data)
        if records[id]?.status.phase == .needsAttention {
            await refreshTasks[id]?.value
            if started, !stopping, refreshTasks[id] == nil, active[id]?.id == observer.id, currentIdentity(observer.account), !suspended.contains(id) {
                let generation = generations[id, default: 0]
                refreshTasks[id] = Task { [weak self] in
                    await self?.perform(observer.account, generation: generation, reason: .manual, reusing: observer)
                    await self?.finishedTask(id)
                }
            }
        }
    }
    public func closeObserver(observerID: UUID) async -> Bool {
        if warm?.id == observerID { return await retireWarm(endHeld: true) }
        guard let observer = active.values.first(where: { $0.id == observerID }) else { return true }
        let id = observer.account.id
        refreshTasks[id]?.cancel()
        let closed = await close(observer, endHeld: true)
        await refreshTasks[id]?.value
        if closed { if active[id]?.id == observer.id { active[id] = nil }; await tick() }
        return closed
    }
    @discardableResult public func stop() async -> Bool {
        stopping = true; started = false; task?.cancel(); task = nil; refreshTasks.values.forEach { $0.cancel() }
        await publishCadence()
        // Observers end together, so one slow child does not hold up the rest.
        let observers = active
        let closed = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await self.retireWarm(endHeld: true) }
            for (id, observer) in observers { group.addTask { await self.closeForStop(id, observer) } }
            var allClosed = true
            for await ended in group where !ended { allClosed = false }
            return allClosed
        }
        for running in refreshTasks.values { await running.value }
        return closed
    }
    private func closeForStop(_ id: UUID, _ observer: QuotaObserver) async -> Bool {
        guard await close(observer, endHeld: true) else { return false }
        if active[id]?.id == observer.id { active[id] = nil }
        return true
    }
    private func close(_ observer: QuotaObserver, endHeld: Bool = false) async -> Bool {
        let closed = await observer.close(endHeld: endHeld)
        if !closed, await observer.cleanupFailed, currentIdentity(observer.account) {
            records[observer.account.id]?.status.failure = .storage
            records[observer.account.id]?.status.phase = .needsAttention
            await persist(); await publish(observer.account.id, scope: AccountScope(observer.account))
        }
        return closed
    }
    private var stateFile: URL { workspace.root.appendingPathComponent("quota-refresh.json") }
    private func tick() async {
        await publishCadence()
        for (id, observer) in active where refreshTasks[id] == nil {
            if await observer.hasEnded, active[id]?.id == observer.id {
                active[id] = nil; records[id]?.status.observerID = nil
                // Its session was held only because it did not close in time; it has ended since,
                // so nothing waits for the person. Sign-in and usage-credit attention stay.
                if records[id]?.status.failure == .needsAttention {
                    records[id]?.status.failure = nil; records[id]?.status.phase = .idle; records[id]?.status.nextAttemptAt = nil
                    Diagnostics.record("quota.close", ["account": Diagnostics.id(id), "outcome": "ended_later"])
                    await persist(); await publish(id)
                }
            }
        }
        if let observer = warm, await observer.hasEnded, warm?.id == observer.id { warm = nil }
        for account in accounts where records[account.id]?.status.phase == .cooldown && !account.isInRotation(at: now()) {
            records[account.id]?.status.phase = .idle; await publish(account.id)
        }
        guard started, !stopping, busyAccounts.count < Self.concurrentReads else { return }
        if warm != nil, !awake || !online || !enabled || now().timeIntervalSince(warmSince) > Self.warmFor { await retireWarm() }
        guard awake, online, now() >= nextLaunchAt else { return }
        let now = now()
        // A queued timed read may have become unnecessary while another account was being
        // observed, or while native inference supplied a newer reading. A queued automatic read
        // is dropped too once its account is out of rotation: used-up week or unusable.
        requested = requested.filter { id, reason in
            guard reason != .manual, reason != .initial else { return true }
            guard let account = accounts.first(where: { $0.id == id }), let record = records[id] else { return false }
            guard reason == .periodic else { return account.isInRotation(at: now) }
            return dueReason(account, record: record, now: now) == .periodic
        }
        if enabled {
            for account in accounts where account.state == .ready || account.state == .limited {
                guard !suspended.contains(account.id), let record = records[account.id], let reason = dueReason(account, record: record, now: now) else { continue }
                requested[account.id] = requested[account.id] ?? reason
            }
        }
        let candidates = accounts.filter { account in
            guard !suspended.contains(account.id), !busyAccounts.contains(account.id), let reason = requested[account.id], [.ready, .limited, .needsAttention].contains(account.state),
                  reason == .manual || reason == .initial || enabled else { return false }
            let status = records[account.id]?.status
            // The person's own request does not wait out a failed read's backoff; it would sit queued, spinning, for up to half an hour.
            let due = status?.failure != nil && reason != .manual ? (status?.nextAttemptAt ?? .distantPast) : .distantPast
            let spacing: TimeInterval = 10
            return now >= due && now >= (status?.lastAttemptAt ?? .distantPast).addingTimeInterval(spacing)
        }.sorted { a, b in
            let pa = priority(requested[a.id]!), pb = priority(requested[b.id]!)
            if pa != pb { return pa < pb }
            return (records[a.id]?.status.lastAttemptAt ?? .distantPast) < (records[b.id]?.status.lastAttemptAt ?? .distantPast)
        }
        guard let account = candidates.first else { return }
        if let warm, warm.account.id != account.id { guard await retireWarm() else { return } }
        guard busyAccounts.count < Self.concurrentReads, !busyAccounts.contains(account.id) else { return }
        let reason = requested.removeValue(forKey: account.id)!
        let generation = generations[account.id, default: 0]
        refreshTasks[account.id] = Task { [weak self] in await self?.perform(account, generation: generation, reason: reason); await self?.finishedTask(account.id) }
        // Reads start a second apart, so several clients do not all launch in the same instant.
        nextLaunchAt = max(nextLaunchAt, now.addingTimeInterval(1))
    }
    /// Accounts with a read running or a session held: each takes one of the concurrent slots.
    private var busyAccounts: Set<UUID> { Set(active.keys).union(refreshTasks.keys) }
    private func dueReason(_ account: PoolAccount, record: Record, now: Date) -> QuotaRefreshReason? {
        // An account whose week is used up comes back only at that reset, and an unusable one only
        // once it is fixed: neither is read by itself until then, so passing 5-hour resets, timed
        // reads and failed-read retries do not keep trying it. Its weekly reset puts it back in
        // rotation, and that reset is read then.
        guard account.isInRotation(at: now) else { return nil }
        if let failure = record.status.failure {
            // Reads that failed for a passing reason keep retrying, backing off to 30 minutes.
            guard [.unavailable, .timedOut, .loading, .unsupportedFormat].contains(failure),
                  (record.status.nextAttemptAt ?? .distantFuture) <= now else { return nil }
            return .recovery
        }
        if record.status.lastSuccessAt == nil && account.windows.isEmpty { return .initial }
        if preferences.confirmAfterReset, (record.resetRetryAt ?? .distantPast) <= now, account.windows.contains(where: { window in
            window.state == .reported && window.resetsAt.map { $0 <= now.addingTimeInterval(-Self.resetGrace) && record.resetChecks?[window.id] != $0 } == true
        }) { return .reset }
        let last = max(record.status.lastAttemptAt ?? .distantPast, record.status.lastSuccessAt ?? .distantPast)
        guard let interval = cadence(accountID: account.id).interval else {
            // Work stopped since the last reading: one read records where it left the account.
            return (lastWork[account.id] ?? .distantPast) > last ? .settle : nil
        }
        return last.addingTimeInterval(interval) <= now ? .periodic : nil
    }
    private func priority(_ reason: QuotaRefreshReason) -> Int {
        switch reason {
        case .manual: return 0; case .initial, .selected: return 1; case .reset: return 2; case .recovery: return 3; case .periodic, .settle: return 4
        }
    }
    private func finishedTask(_ id: UUID) async { refreshTasks[id] = nil; await tick() }
    private func perform(_ account: PoolAccount, generation: UInt64, reason: QuotaRefreshReason, reusing: QuotaObserver? = nil) async {
        guard !suspended.contains(account.id), currentIdentity(account), generations[account.id, default: 0] == generation else { return }
        let scope = AccountScope(account)
        let now = now()
        let began = Date()
        let tag = Diagnostics.id(account.id)
        let previousAttempt = records[account.id]?.status.lastAttemptAt
        let previousSuccess = records[account.id]?.status.lastSuccessAt ?? .distantPast
        let previousResetChecks = records[account.id]?.resetChecks
        let previousFailure = records[account.id]?.status.failure
        let previousRetry = records[account.id]?.status.nextAttemptAt
        records[account.id]?.status.lastAttemptAt = now
        records[account.id]?.status.phase = .refreshing
        if reusing == nil {
            // A passed reset is read once; a failed read retries through its own backoff instead.
            var checks = records[account.id]?.resetChecks ?? [:]
            for window in account.windows where window.state == .reported {
                if let reset = window.resetsAt, reset <= now { checks[window.id] = reset }
            }
            records[account.id]?.resetChecks = checks
        }
        guard await persist() else {
            nextLaunchAt = now.addingTimeInterval(60); await publish(account.id, scope: scope); return
        }
        await publish(account.id, scope: scope)
        do {
            let observer: QuotaObserver
            if let reusing { observer = reusing }
            else {
                let binary = try await executable()
                try Task.checkCancellation()
                guard !suspended.contains(account.id), currentIdentity(account), generations[account.id, default: 0] == generation else { throw QuotaRefreshFailure.cancelled }
                let available = awake && online && (enabled || reason == .manual || reason == .initial)
                let interval = cadence(accountID: account.id).interval
                let latest = records[account.id]?.status.lastSuccessAt ?? .distantPast
                let redundant: Bool
                switch reason {
                case .periodic: redundant = interval == nil || (latest > previousSuccess && latest.addingTimeInterval(interval ?? 0) > self.now())
                case .settle: redundant = latest >= (lastWork[account.id] ?? .distantFuture)
                case .selected: redundant = self.now().timeIntervalSince(latest) < Self.freshFor
                default: redundant = false
                }
                if !available || redundant {
                    Diagnostics.record("quota.read", ["account": tag, "reason": reason.rawValue, "outcome": available ? "redundant" : "paused"])
                    if !available, reason == .manual || reason == .initial { requested[account.id] = reason }
                    records[account.id]?.status.lastAttemptAt = previousAttempt
                    records[account.id]?.resetChecks = previousResetChecks
                    records[account.id]?.status.phase = available ? .idle : .paused
                    await persist(); await publish(account.id, scope: scope)
                    return
                }
                if let warm, AccountScope(warm.account).matches(account), !(await warm.hasEnded) {
                    observer = warm; self.warm = nil
                } else {
                    observer = QuotaObserver(account: account, workspace: workspace, executable: binary,
                                             helper: helperExecutable, launch: launch, update: update, timeout: observerTimeout)
                }
            }
            active[account.id] = observer
            records[account.id]?.status.observerID = observer.id; await publish(account.id, scope: scope)
            try Task.checkCancellation()
            guard !suspended.contains(account.id), currentIdentity(account), generations[account.id, default: 0] == generation else { throw QuotaRefreshFailure.cancelled }
            let windows = try await observer.read()
            let timings = await observer.timings()
            let fiveHour = windows.first { $0.id == "five_hour" }
            Diagnostics.record("quota.read", ["account": tag, "reason": reason.rawValue, "outcome": "ok",
                "reused": await observer.reads > 1 ? "yes" : "no",
                "ms": String(Int(Date().timeIntervalSince(began) * 1000)),
                "ready_ms": timings.readyMS.map(String.init) ?? "-", "panel_ms": timings.panelMS.map(String.init) ?? "-",
                "windows": String(windows.count),
                "five_hour": fiveHour.map { $0.state != .reported ? $0.state.rawValue : $0.resetsAt == nil ? "no_reset" : $0.resetsAt! <= $0.observedAt ? "past_reset" : "reset" } ?? "-"])
            guard !suspended.contains(account.id), currentIdentity(account), generations[account.id, default: 0] == generation else { throw QuotaRefreshFailure.cancelled }
            await update(.reading(scope: scope, windows: windows))
            guard !suspended.contains(account.id), currentIdentity(account), generations[account.id, default: 0] == generation else { throw QuotaRefreshFailure.cancelled }
            confirmResets(account, reading: windows)
            records[account.id]?.status.lastSuccessAt = windows.map(\.observedAt).max()
            records[account.id]?.status.nextAttemptAt = nil
            records[account.id]?.status.failure = nil; records[account.id]?.failures = 0
            let extraUsage = await observer.extraUsage
            let rested = !extraUsage && keepsWarm(account) ? await observer.rest() : false
            let closed = rested ? true : await close(observer)
            let cleanupFailed = await observer.cleanupFailed
            guard currentIdentity(account), generations[account.id, default: 0] == generation else {
                if rested { _ = await close(observer, endHeld: true) }
                if closed, active[account.id]?.id == observer.id { active[account.id] = nil }
                return
            }
            if rested { warm = observer; warmSince = self.now() }
            if closed { active[account.id] = nil; records[account.id]?.status.phase = .idle; records[account.id]?.status.observerID = nil }
            else {
                Diagnostics.record("quota.close", ["account": tag, "outcome": "held", "why": cleanupFailed ? "cleanup_failed" : (await observer.heldBecause ?? "-"),
                                                   "ended": await observer.hasEnded ? "yes" : "no"])
                records[account.id]?.status.phase = .needsAttention; records[account.id]?.status.failure = cleanupFailed ? .storage : .needsAttention
            }
            if extraUsage {
                records[account.id]?.status.failure = .extraUsage; records[account.id]?.status.phase = .needsAttention
            }
        } catch {
            if generations[account.id, default: 0] != generation || !currentIdentity(account) {
                if let observer = active[account.id], await close(observer) { active[account.id] = nil }
                nextLaunchAt = self.now().addingTimeInterval(2)
                return
            }
            let failure = (error as? QuotaRefreshFailure) ?? (error is CancellationError ? .cancelled : .unavailable)
            let timings = await active[account.id]?.timings()
            Diagnostics.record("quota.read", ["account": tag, "reason": reason.rawValue, "outcome": failure.rawValue,
                "stage": timings?.stage ?? "launch", "ms": String(Int(Date().timeIntervalSince(began) * 1000)),
                "ready_ms": timings?.readyMS.map(String.init) ?? "-"])
            if failure == .cancelled {
                // A read stopped by exit, quit or an account change says nothing about the account.
                records[account.id]?.status.failure = previousFailure
                records[account.id]?.status.nextAttemptAt = previousRetry
                records[account.id]?.status.lastAttemptAt = previousAttempt
                records[account.id]?.status.phase = .idle
            } else {
                let count = min(6, (records[account.id]?.failures ?? 0) + 1)
                records[account.id]?.failures = count
                records[account.id]?.status.failure = failure
                records[account.id]?.status.nextAttemptAt = self.now().addingTimeInterval(min(1800, 60 * pow(2, Double(count - 1))))
                records[account.id]?.status.phase = failure == .authentication || failure == .needsAttention ? .needsAttention : .cooldown
            }
            if let observer = active[account.id] {
                let closed = await close(observer)
                let cleanupFailed = await observer.cleanupFailed
                guard currentIdentity(account), generations[account.id, default: 0] == generation else {
                    if closed, active[account.id]?.id == observer.id { active[account.id] = nil }
                    return
                }
                if closed { active[account.id] = nil; records[account.id]?.status.observerID = nil }
                else {
                    // A held sign-in screen still means the account must be signed in again.
                    records[account.id]?.status.phase = .needsAttention
                    records[account.id]?.status.failure = cleanupFailed ? .storage : failure == .authentication ? .authentication : .needsAttention
                }
            }
        }
        nextLaunchAt = self.now().addingTimeInterval(2)
        await persist(); await publish(account.id, scope: scope)
    }
    /// Right after a reset Claude can still show the cycle that ended. Such a reading is read
    /// again, backing off to 15 minutes; after six tries the reset counts as confirmed, since the
    /// limit was restored at its time anyway. Any other reading confirms the resets it moved past.
    private func confirmResets(_ account: PoolAccount, reading windows: [QuotaWindow]) {
        var checks = records[account.id]?.resetChecks ?? [:]
        let lagging = windows.filter { window in window.state == .reported && window.resetsAt.map { $0 <= window.observedAt } == true }
        let attempts = (records[account.id]?.resetAttempts ?? 0) + 1
        if lagging.isEmpty || attempts > 6 {
            for window in lagging { checks[window.id] = window.resetsAt }
            records[account.id]?.resetAttempts = nil; records[account.id]?.resetRetryAt = nil
        } else {
            for window in lagging { checks.removeValue(forKey: window.id) }
            records[account.id]?.resetAttempts = attempts
            records[account.id]?.resetRetryAt = now().addingTimeInterval(min(900, 60 * pow(2, Double(attempts - 1))))
        }
        records[account.id]?.resetChecks = checks
    }
    /// Only an account read again within `warmFor` keeps its session, and only while nothing else waits.
    private func keepsWarm(_ account: PoolAccount) -> Bool {
        guard started, !stopping, enabled, awake, online, !suspended.contains(account.id),
              let interval = cadence(accountID: account.id).interval, interval <= Self.warmFor else { return false }
        return !requested.keys.contains { $0 != account.id }
    }
    @discardableResult private func retireWarm(endHeld: Bool = false) async -> Bool {
        guard let observer = warm else { return true }
        warm = nil
        if await close(observer, endHeld: endHeld) { return true }
        // It did not leave its prompt normally: keep it for the user, as any held session.
        active[observer.account.id] = observer
        records[observer.account.id]?.status.phase = .needsAttention
        records[observer.account.id]?.status.observerID = observer.id
        await publish(observer.account.id)
        return false
    }
    private func publish(_ id: UUID, scope expected: AccountScope? = nil) async {
        guard let account = accounts.first(where: { $0.id == id }), let status = records[id]?.status else { return }
        let scope = expected ?? AccountScope(account)
        guard scope.matches(account) else { return }
        // Every change of an account's read state, where it is published.
        let shown = status.phase.rawValue + "/" + (status.failure?.rawValue ?? "-")
        if loggedStatus[id] != shown {
            Diagnostics.record("quota.state", ["account": Diagnostics.id(id), "from": loggedStatus[id] ?? "new", "to": shown,
                "failures": String(records[id]?.failures ?? 0),
                "retry_in_s": status.nextAttemptAt.map { String(Int($0.timeIntervalSince(now()))) } ?? "-"])
            loggedStatus[id] = shown
        }
        await update(.status(scope: scope, status: status))
    }
    private func currentIdentity(_ account: PoolAccount) -> Bool {
        let scope = AccountScope(account)
        return accounts.contains { scope.matches($0) && [.ready, .limited, .needsAttention].contains($0.state) }
    }
    @discardableResult private func persist() async -> Bool {
        do { try workspace.write(JSONEncoder().encode(Array(records.values)), to: stateFile); return true }
        catch {
            for id in records.keys { records[id]?.status.failure = .storage; records[id]?.status.phase = .failed }
            return false
        }
    }
}

private actor QuotaObserver {
    nonisolated let id = UUID()
    nonisolated let account: PoolAccount
    private let workspace: OwnedWorkspace, executable: URL, helper: URL
    private let launch: QuotaRefreshService.Launch, update: QuotaRefreshService.Update
    private let timeout: TimeInterval
    private var transport: SessionTransport?
    private var directory: URL?
    private var processTask: Task<Void, Never>?
    private var screen = TerminalScreen()
    private var firstRun = FirstRunScreens()
    private var lastOutput = Date.distantPast
    private var typedAt = Date.distantPast
    private var ready = false, typed = false, submitted = false, ended = false, closing = false, sessionEnding = false
    private(set) var extraUsage = false
    private(set) var cleanupFailed = false
    /// When this read's client was started, reached its prompt and had /usage submitted, for the log.
    private var launchedAt: Date?, readyAt: Date?, submittedAt: Date?
    /// Reads this session has taken: more than one means it was kept at its prompt and reused.
    private(set) var reads = 0
    /// Why the last automatic close kept this session, for the log.
    private(set) var heldBecause: String?
    private var failure: QuotaRefreshFailure?
    var hasEnded: Bool { ended && !cleanupFailed }
    static let panelTimeout: TimeInterval = 20
    init(account: PoolAccount, workspace: OwnedWorkspace, executable: URL, helper: URL,
         launch: @escaping QuotaRefreshService.Launch, update: @escaping QuotaRefreshService.Update, timeout: TimeInterval) {
        self.account = account; self.workspace = workspace; self.executable = executable; self.helper = helper
        self.launch = launch; self.update = update; self.timeout = timeout
    }
    func read() async throws -> [QuotaWindow] {
        try Task.checkCancellation()
        reads += 1
        if transport == nil { try start() }
        if failure == .needsAttention { failure = nil }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if ended { throw cleanupFailed ? QuotaRefreshFailure.storage : .unavailable }
            if let failure { throw failure }
            try pollHooks()
            if let failure { throw failure }
            if !ready, let transport {
                switch firstRun.respond(to: screen.visibleText, at: Date()) {
                case .send(let key): try transport.write(key)
                case .signInRequired: throw QuotaRefreshFailure.authentication
                case .stuck: throw QuotaRefreshFailure.needsAttention
                case .none: break
                }
            }
            if ready, !typed {
                try transport?.write(Data("/usage".utf8)); typed = true; typedAt = Date()
            }
            // An earlier /usage can still be on screen; Return waits for this one to be drawn.
            if typed, !submitted, lastOutput > typedAt, screen.visibleText.contains("/usage"), Date().timeIntervalSince(lastOutput) >= 0.15 {
                try transport?.write(Data([13])); submitted = true; submittedAt = Date()
            }
            // A panel that has not drawn its figures this long after /usage will not: the read
            // gives way at once rather than holding a slot for the whole timeout.
            if submitted, let submittedAt, Date().timeIntervalSince(submittedAt) > Self.panelTimeout { throw QuotaRefreshFailure.timedOut }
            if submitted, Date().timeIntervalSince(lastOutput) >= 0.35 {
                do {
                    let windows = try NativeUsageParser.parse(screen.visibleText, plan: account.plan, observedAt: Date())
                    extraUsage = NativeUsageParser.usesExtraUsage(screen.visibleText)
                    return windows
                }
                catch QuotaRefreshFailure.loading {} catch { throw error }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw ready ? QuotaRefreshFailure.timedOut : .needsAttention
    }
    /// After a reading, closes the panel the way a person does and leaves the session at its
    /// prompt for the next read. False when it is not cleanly back at the prompt.
    func rest() async -> Bool {
        guard !ended, ready, failure == nil, let transport else { return false }
        do {
            try pollHooks()
            if submitted {
                try transport.write(Data([27]))
                let deadline = Date().addingTimeInterval(2)
                while NativeUsageParser.isPanel(screen.visibleText), !ended, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
                guard !NativeUsageParser.isPanel(screen.visibleText), !ended, failure == nil else { return false }
            }
            typed = false; submitted = false; extraUsage = false
            return true
        } catch { return false }
    }
    /// Where a read got to, and how long the client took to reach its prompt and then to draw the
    /// panel, in milliseconds. A reused session reports no start.
    func timings() -> (stage: String, readyMS: Int?, panelMS: Int?) {
        let stage = ended ? "ended" : !ready ? "starting" : !submitted ? "typing" : "panel"
        let ms = { (from: Date?, to: Date?) -> Int? in
            guard let from, let to else { return nil }; return Int(to.timeIntervalSince(from) * 1000)
        }
        return (stage, ms(launchedAt, readyAt), ms(submittedAt, submitted ? Date() : nil))
    }
    func sendInput(_ data: Data) throws {
        guard !ended, data.count <= 64 * 1024, let transport else { throw QuotaRefreshFailure.needsAttention }
        try transport.write(data)
    }
    /// `endHeld` is an explicit end (exit, quit, account change). Automatic closes keep a session
    /// that is not at its idle prompt so the user can continue it.
    func close(endHeld: Bool = false) async -> Bool {
        if ended { return cleanupRun() }
        try? pollHooks()
        guard let transport, !closing else { return self.transport == nil }
        closing = true; defer { closing = false }
        do {
            if sessionEnding {
                _ = try await transport.waitForExit()
            } else if !ready || failure == .needsAttention {
                guard endHeld else { heldBecause = !ready ? "not_at_prompt" : "held_for_user"; return false }
                // Before its prompt (a first-run or sign-in screen) or on a prompt held for the user,
                // /exit cannot be typed. The client's own double Ctrl-C ends it normally.
                guard try await interruptUntilEnded(transport) else { return false }
            } else {
                var cleared = true
                if submitted {
                    try transport.write(Data([27]))
                    let deadline = Date().addingTimeInterval(2)
                    while NativeUsageParser.isPanel(screen.visibleText), !ended, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
                    cleared = !NativeUsageParser.isPanel(screen.visibleText) || ended
                } else if typed {
                    // Clear only the fixed /usage draft owned by this observer before a normal exit.
                    try transport.write(Data([27, 21]))
                }
                var exited = ended
                if cleared, !ended {
                    try transport.exit()
                    exited = (try? await transport.waitForExit()) != nil || ended
                }
                // Quitting never waits on a panel or prompt that kept /exit from working: the
                // client's own double Ctrl-C ends it normally.
                if !exited {
                    guard endHeld, try await interruptUntilEnded(transport) else {
                        heldBecause = cleared ? "exit_not_confirmed" : "panel_stayed"; return false
                    }
                }
            }
            let reportExit = !ended
            ended = true; processTask?.cancel()
            let cleaned = cleanupRun()
            if reportExit { await update(.ended(scope: AccountScope(account), observerID: id)) }
            return cleaned
        } catch { heldBecause = "write_failed"; return false }
    }
    /// Normal terminal interrupts only, each pair spaced as a person presses them. Never a forced end.
    private func interruptUntilEnded(_ transport: SessionTransport) async throws -> Bool {
        for _ in 0..<2 where !ended {
            do {
                try transport.interrupt()
                try await Task.sleep(nanoseconds: 200_000_000)
                if !ended { try transport.interrupt() }
            } catch RuntimeError.processExited {
                // The first key ended it; its exit is still on the way here.
                return (try? await transport.waitForExit()) != nil || ended
            }
            let deadline = Date().addingTimeInterval(3)
            while !ended, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        return ended
    }
    private func cleanupRun() -> Bool {
        guard ended else { return false }
        guard directory != nil else { return true }
        do { try workspace.removeRun(id); directory = nil; cleanupFailed = false; return true }
        catch { cleanupFailed = true; return false }
    }
    private func start() throws {
        try workspace.prepare()
        let directory = try workspace.runDirectory(id); self.directory = directory
        try workspace.createDirectory(at: directory.appendingPathComponent("events"))
        // Official workspace trust belongs to a stable account folder, not a fresh folder on
        // every scheduled read. The observer still has its own process, session and hook spool.
        let work = try workspace.workDirectory(account.id)
        try workspace.write(JSONValue.object(["session_id": .string(id.uuidString)]).encoded(), to: directory.appendingPathComponent("run.json"))
        var hooks: [String: JSONValue] = [:]
        for event in ["SessionStart", "SessionEnd", "Notification", "PermissionRequest", "StopFailure"] {
            let command = quote(helper.path) + " --bridge-hook " + quote(directory.path) + " " + event
            hooks[event] = .array([.object(["hooks": .array([.object(["type": .string("command"), "command": .string(command), "timeout": .number(10)])])])])
        }
        let settings = directory.appendingPathComponent("settings.json")
        try workspace.write(JSONValue.object(["hooks": .object(hooks)]).encoded(), to: settings)
        let mcp = directory.appendingPathComponent("mcp.json")
        try workspace.write(JSONValue.object(["mcpServers": .object([:])]).encoded(), to: mcp)
        var environment = OfficialCLI.environment(for: try workspace.accountDirectory(account.id))
        environment["LANG"] = "en_US.UTF-8"; environment["LC_ALL"] = "en_US.UTF-8"
        let arguments = ["--session-id", id.uuidString, "--restricted", "--tools", "", "--strict-mcp-config", "--mcp-config", mcp.path,
                         "--settings", settings.path, "--permission-mode", "default"]
        let plan = SessionLaunch(executable: executable, arguments: arguments, environment: environment,
                                 directory: work, runDirectory: directory, sessionID: id)
        let run = Diagnostics.id(id)
        DevRecord.record(.session, "quota.launch", ["run": run, "account": Diagnostics.id(account.id)]) { plan.recorded() }
        let child = try launch(plan).recorded(run: run, role: "quota")
        transport = child; launchedAt = Date()
        processTask = Task { [weak self] in
            for await event in child.events { await self?.receive(event) }
        }
    }
    private func receive(_ event: PTYEvent) async {
        switch event {
        case .output(let data):
            if let reply = TerminalScreen.replies(to: data) { try? transport?.write(reply) }
            screen.feed(data); lastOutput = Date()
            await update(.terminal(scope: AccountScope(account), observerID: id, data: data))
        case .exited:
            guard !ended else { return }
            ended = true
            _ = cleanupRun()
            await update(.ended(scope: AccountScope(account), observerID: id))
        }
    }
    private func pollHooks() throws {
        guard let directory else { return }
        let files = try workspace.entries(in: directory.appendingPathComponent("events")).filter { $0.pathExtension == "json" }
        guard files.count <= 128 else { throw QuotaRefreshFailure.unsupportedFormat }
        for file in files {
            let event = try JSONDecoder().decode(JSONValue.self, from: workspace.read(file, limit: 256 * 1024))
            guard event["session_id"]?.stringValue.flatMap(UUID.init(uuidString:)) == id else { throw QuotaRefreshFailure.unsupportedFormat }
            switch event["event"]?.stringValue {
            case "SessionStart": ready = true; readyAt = readyAt ?? Date(); if failure == .needsAttention { failure = nil }
            case "SessionEnd": sessionEnding = true; ready = false; failure = .unavailable
            case "PermissionRequest": failure = .needsAttention
            case "Notification":
                if event["notification_type"]?.stringValue == "permission_prompt" { failure = .needsAttention }
            case "StopFailure": failure = .unavailable
            default: break
            }
            try workspace.remove(file)
        }
    }
    private func quote(_ string: String) -> String { "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
