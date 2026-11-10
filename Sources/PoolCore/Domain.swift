import Foundation

/// `suspended`: Anthropic put the account on hold or its organisation refuses this client.
public enum AccountState: String, Codable, Sendable { case signedOut, ready, limited, subscriptionRequired, needsAttention, disabled, suspended }
/// The pool serves whenever setup is complete; there is no user pause. `stopping` is only quitting.
public enum PoolMode: String, Codable, Sendable { case stopped, ready, running, stopping, attention }
public enum SessionState: String, Codable, Sendable { case starting, running, waiting, idle, attention, ended }
public enum QuotaWindowState: String, Codable, Sendable { case reported, unknown, notApplicable }

/// Which requests a window's limit holds back. `other` windows are shown but never stop an
/// account, route a request or count in a pool's global figures: only an id Pool recognises can.
public enum QuotaScope: Equatable, Sendable {
    /// Every model: the 5-hour and the weekly limit.
    case all
    /// Only these model families.
    case models(Set<String>)
    /// A window Pool does not recognise.
    case other
}

extension QuotaScope {
    var isModels: Bool { if case .models = self { return true } else { return false } }
}

public struct QuotaWindow: Codable, Equatable, Sendable, Identifiable {
    /// The shared weekly limit of the models Claude lets run on usage credits once it is used up.
    public static let overageIncludedID = "seven_day_overage_included"
    /// The models that limit holds today (the server sends a list; Fable is the only one seen so far).
    public static let overageIncludedModels: Set<String> = ["fable"]
    /// The model families a weekly limit can be named after.
    public static let modelFamilies = ["opus", "sonnet", "haiku", "fable", "mythos"]

    public var id: String
    public var usedPercent: Double?
    public var observedAt: Date
    public var resetsAt: Date?
    public var state: QuotaWindowState
    public var scope: QuotaScope
    /// Claude refused the account at this model-scoped limit until this time. A later reading that
    /// shows room (the panel can show room a turn does not fit in) does not lift it before then.
    public var refusedUntil: Date?
    /// Whether the refusal came with the limit's own reset (true) or `refusedUntil` is only a cycle
    /// guessed after it (false). Nil in a library saved before the field: taken as stated.
    public var refusalStatedReset: Bool?
    public var startsOnNextUse: Bool
    /// `scope` is for a window whose id says nothing; a recognised id always gives its own.
    public init(id: String, usedPercent: Double? = nil, observedAt: Date, resetsAt: Date? = nil,
                state: QuotaWindowState = .reported, scope: QuotaScope? = nil, refusedUntil: Date? = nil,
                startsOnNextUse: Bool = false, refusalStatedReset: Bool? = nil) {
        let known = Self.canonical(id)
        self.id = known?.id ?? id
        self.usedPercent = usedPercent; self.observedAt = observedAt; self.resetsAt = resetsAt
        self.state = usedPercent == nil && state == .reported ? .unknown : state
        self.scope = known?.scope ?? scope ?? .other
        self.refusedUntil = self.scope == .all ? nil : refusedUntil
        self.refusalStatedReset = self.refusedUntil == nil ? nil : refusalStatedReset
        self.startsOnNextUse = startsOnNextUse && id == "five_hour" && state == .reported && usedPercent == 0 && resetsAt == nil
    }
    /// The one place a window's name becomes its identity and scope. Nil for a name not recognised.
    public static func canonical(_ id: String) -> (id: String, scope: QuotaScope)? {
        switch id {
        case "five_hour", "seven_day": return (id, .all)
        case overageIncludedID, "seven_day_fable": return (overageIncludedID, .models(overageIncludedModels))
        default:
            for family in modelFamilies where id == "seven_day_\(family)" { return (id, .models([family])) }
            return nil
        }
    }
    /// A weekly limit named after what it covers ("Fable", "Fable 5.1", "Sonnet only"): a model
    /// family alone, with an optional version and "only". Anything else keeps its own slug and has
    /// no scope. Nil when the name leaves nothing to name it by.
    public static func scoped(name: String) -> (id: String, scope: QuotaScope)? {
        let lower = name.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let family = lower.range(of: #"^([a-z]+)(?: [0-9]+(?:\.[0-9]+)*)?(?: only)?$"#, options: .regularExpression)
            .flatMap { _ in lower.split(separator: " ").first.map(String.init) }
            .flatMap { modelFamilies.contains($0) ? $0 : nil }
        if let family, let known = canonical("seven_day_\(family)") { return known }
        let slug = slug(lower.replacingOccurrences(of: #" only$"#, with: "", options: .regularExpression))
        return slug.isEmpty ? nil : ("seven_day_" + slug, .other)
    }
    public static func slug(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }
    enum CodingKeys: String, CodingKey { case id, usedPercent, observedAt, resetsAt, state, modelFamily, scope, scopeModels, refusedUntil, refusalStatedReset, startsOnNextUse }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Saved before scopes: a model family stood for a model-scoped window, none for a global one.
        // Only the ids Pool recognises keep a scope now (seven_day_fable becomes the overage-included window).
        var stored: QuotaScope?
        switch try values.decodeIfPresent(String.self, forKey: .scope) {
        case "all"?: stored = .all
        case "models"?: stored = .models(Set(try values.decodeIfPresent([String].self, forKey: .scopeModels) ?? []))
        case "other"?: stored = .other
        default:
            if let family = try values.decodeIfPresent(String.self, forKey: .modelFamily), Self.modelFamilies.contains(family) { stored = .models([family]) }
        }
        self.init(id: try values.decode(String.self, forKey: .id),
                  usedPercent: try values.decodeIfPresent(Double.self, forKey: .usedPercent),
                  observedAt: try values.decode(Date.self, forKey: .observedAt),
                  resetsAt: try values.decodeIfPresent(Date.self, forKey: .resetsAt),
                  state: try values.decodeIfPresent(QuotaWindowState.self, forKey: .state) ?? .reported,
                  scope: stored,
                  refusedUntil: try values.decodeIfPresent(Date.self, forKey: .refusedUntil),
                  startsOnNextUse: try values.decodeIfPresent(Bool.self, forKey: .startsOnNextUse) ?? false,
                  refusalStatedReset: try values.decodeIfPresent(Bool.self, forKey: .refusalStatedReset))
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encodeIfPresent(usedPercent, forKey: .usedPercent)
        try values.encode(observedAt, forKey: .observedAt)
        try values.encodeIfPresent(resetsAt, forKey: .resetsAt)
        try values.encode(state, forKey: .state)
        switch scope {
        case .all: try values.encode("all", forKey: .scope)
        case .models(let models): try values.encode("models", forKey: .scope); try values.encode(models.sorted(), forKey: .scopeModels)
        case .other: try values.encode("other", forKey: .scope)
        }
        try values.encodeIfPresent(refusedUntil, forKey: .refusedUntil)
        try values.encodeIfPresent(refusalStatedReset, forKey: .refusalStatedReset)
        try values.encode(startsOnNextUse, forKey: .startsOnNextUse)
    }
    public var isGlobal: Bool { scope == .all }
    /// The order model-scoped limits are listed in.
    public static let modelDisplayOrder = ["fable", "opus", "sonnet", "haiku", "mythos"]
    /// What a model-scoped limit is named after: "Fable", "Opus". Nil for the other scopes.
    public static func modelName(of scope: QuotaScope) -> String? {
        guard case .models(let families) = scope, !families.isEmpty else { return nil }
        let known = modelDisplayOrder.filter { families.contains($0) }
        let rest = families.subtracting(modelDisplayOrder).sorted()
        return (known + rest).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: "/")
    }
    public var modelName: String? { Self.modelName(of: scope) }
    /// Where a window is listed, by id: 5 hours, the week, each model's week (Fable, Opus, Sonnet, Haiku, Mythos), the rest.
    public static func displayRank(_ id: String) -> Int {
        switch canonical(id)?.scope {
        case .all?: return id == "five_hour" ? 0 : 1
        case .models(let families)?:
            return 2 + (modelDisplayOrder.firstIndex { families.contains($0) } ?? modelDisplayOrder.count)
        default: return 100
        }
    }
    public func applies(to model: String) -> Bool {
        switch scope {
        case .all: return true
        case .other: return false
        case .models(let families):
            let parts = Set(model.lowercased().split(separator: "-").map(String.init))
            return families.contains { parts.contains($0.lowercased()) }
        }
    }
    /// Claude refused the account at this model-scoped limit and its reset has not come.
    public func holdsRefusal(at now: Date) -> Bool { refusedUntil.map { $0 > now } ?? false }
    /// This window as a new reading of it, given what was saved: a refusal still standing is kept
    /// whatever the reading says, unless the reading belongs to a later cycle.
    public func carrying(_ old: QuotaWindow?, at now: Date) -> QuotaWindow {
        guard scope != .all, let old, old.holdsRefusal(at: now), let until = old.refusedUntil else { return self }
        if let reset = resetsAt, reset > until.addingTimeInterval(60) { return self }
        var held = self
        held.refusedUntil = until
        held.refusalStatedReset = old.refusalStatedReset
        // A refusal that stated no reset only guessed a cycle: the limit's own reset, read later,
        // ends it, earlier than the guess. A reset already past lifts it.
        if old.refusalStatedReset == false, let reset = resetsAt {
            if reset <= now { return self }
            if reset < until { held.refusedUntil = reset; held.refusalStatedReset = true }
        }
        held.resetsAt = resetsAt ?? old.resetsAt
        held.state = .reported; held.usedPercent = 100
        return held
    }
    /// This window as a refusal: used up until its reset (a cycle after the refusal without one).
    public func refused() -> QuotaWindow {
        guard scope != .all else { return self }
        var held = self
        held.usedPercent = 100; held.state = .reported
        held.refusedUntil = recoversAt
        held.refusalStatedReset = resetsAt != nil
        return held
    }
    public func isFresh(at now: Date) -> Bool {
        observedAt <= now && now.timeIntervalSince(observedAt) <= 600
    }
    /// How long one cycle of this limit lasts: five hours for the session limit, a week otherwise.
    public var span: TimeInterval { id == "five_hour" ? 5 * 3600 : 7 * 86400 }
    /// Last official value, as read.
    public func recordedRemaining(at now: Date) -> Double? {
        guard state == .reported, let usedPercent, usedPercent.isFinite, (0...100).contains(usedPercent), observedAt <= now else { return nil }
        return 100 - usedPercent
    }
    /// A new cycle began after this reading: its stated reset passed or, without one, a whole
    /// cycle went by. Claude restores a limit at its reset, so it is full again until read.
    public func isRenewed(at now: Date) -> Bool {
        guard state == .reported, observedAt <= now, !holdsRefusal(at: now) else { return false }
        if let resetsAt { return resetsAt <= now }
        return now.timeIntervalSince(observedAt) >= span
    }
    /// The session limit has no cycle running: it starts with the next request.
    public func waitsForFirstUse(at now: Date) -> Bool {
        id == "five_hour" && state == .reported && observedAt <= now && (isRenewed(at: now) || (usedPercent == 0 && resetsAt == nil))
    }
    public func isNotApplicable(at now: Date) -> Bool {
        state == .notApplicable && observedAt <= now && (resetsAt.map { $0 > now } ?? true)
    }
    /// What is left now: the last reading within its cycle, all of it once the cycle renewed.
    public func remaining(at now: Date) -> Double? {
        guard let recorded = recordedRemaining(at: now) else { return nil }
        if holdsRefusal(at: now) { return 0 }
        return isRenewed(at: now) ? 100 : recorded
    }
    /// Used up until the reset: the stated one, or at the latest a cycle after the reading.
    public func isExhausted(at now: Date) -> Bool {
        state == .reported && observedAt <= now && (holdsRefusal(at: now) || (usedPercent == 100 && !isRenewed(at: now)))
    }
    /// When an exhausted limit comes back: its stated reset, or at the latest a cycle after the reading.
    public var recoversAt: Date { resetsAt ?? observedAt.addingTimeInterval(span) }
}

public struct PoolAccount: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var email: String?
    public var identityFingerprint: String?
    public var plan: String?
    public var state: AccountState
    public var windows: [QuotaWindow]
    public var cooldownUntil: Date?
    public var createdAt: Date
    public init(id: UUID = UUID(), email: String? = nil, identityFingerprint: String? = nil,
                plan: String? = nil, state: AccountState = .signedOut,
                windows: [QuotaWindow] = [], cooldownUntil: Date? = nil, createdAt: Date = Date()) {
        self.id = id; self.email = email; self.identityFingerprint = identityFingerprint; self.plan = plan; self.state = state
        self.windows = windows; self.cooldownUntil = cooldownUntil; self.createdAt = createdAt
    }
    public func hasSameIdentity(as other: PoolAccount) -> Bool {
        guard let email, let otherEmail = other.email, !email.isEmpty, email.lowercased() == otherEmail.lowercased() else { return false }
        return identityFingerprint == nil || other.identityFingerprint == nil || identityFingerprint == other.identityFingerprint
    }
    /// The state now. A reached limit lasts only until its reset or the cooldown Claude stated,
    /// so a limited account is ready again by itself once that time passes.
    public func effectiveState(at now: Date) -> AccountState {
        guard state == .limited else { return state }
        if let cooldownUntil, cooldownUntil > now { return .limited }
        return windows.contains { $0.isGlobal && $0.isExhausted(at: now) } ? .limited : .ready
    }
    /// Whether Claude refused the account at `window`'s limit before its reset, though the last
    /// reading had some of it left: the refusal's cooldown ends at the window's reset. Claude's usage
    /// panel can show room a turn still does not fit in, so until then the window has none.
    public func isRefused(_ window: QuotaWindow, at now: Date) -> Bool {
        guard effectiveState(at: now) == .limited, window.isGlobal, let cooldownUntil, cooldownUntil > now,
              let reset = window.resetsAt, abs(reset.timeIntervalSince(cooldownUntil)) < 60 else { return false }
        return !window.isExhausted(at: now)
    }
    /// How usable the account is now. Lists put better standing first; pool figures count only
    /// accounts that can serve this week.
    public func standing(at now: Date) -> AccountStanding {
        guard email?.isEmpty == false else { return .unavailable }
        let state = effectiveState(at: now)
        guard state == .ready || state == .limited else { return .unavailable }
        if isWeekUsedUp(at: now) { return .weekUsed }
        if state == .limited || windows.contains(where: { $0.isGlobal && $0.isExhausted(at: now) }) { return .limited }
        return PoolRouting.assessment(self, model: PoolRouting.anyModel, now: now).state == .unknown ? .unread : .usable
    }
    /// A limit longer than the 5-hour one, for every model, is used up until its reset.
    public func isWeekUsedUp(at now: Date) -> Bool {
        windows.contains { $0.isGlobal && $0.id != "five_hour" && $0.isExhausted(at: now) }
    }
    /// Worth reading without being asked: it can serve now or within hours. A used-up week comes
    /// back only at its reset, and an unusable account only once it is fixed.
    public func isInRotation(at now: Date) -> Bool {
        [.ready, .limited].contains(effectiveState(at: now)) && !isWeekUsedUp(at: now)
    }
    /// Takes in readings of windows, newest word first: an older reading never replaces a newer one,
    /// and a refusal Claude gave at a model's limit outlasts a reading that shows room. With
    /// `replacingSnapshot` windows the reading did not return are dropped, except those held by a refusal.
    /// Returns the windows taken.
    @discardableResult
    public mutating func absorb(_ readings: [QuotaWindow], replacingSnapshot: Bool = false, at now: Date = Date()) -> [QuotaWindow] {
        if replacingSnapshot, let snapshotAt = readings.map(\.observedAt).max() {
            let returned = Set(readings.map(\.id))
            windows.removeAll { !returned.contains($0.id) && $0.observedAt <= snapshotAt && !$0.holdsRefusal(at: now) }
        }
        var taken: [QuotaWindow] = []
        for reading in readings {
            let old = windows.first { $0.id == reading.id }
            if let old, old.observedAt > reading.observedAt { continue }
            let window = reading.carrying(old, at: now)
            windows.removeAll { $0.id == window.id }
            windows.append(window); taken.append(window)
        }
        return taken
    }
}

/// Best first. Every account counts in the pool's figures. Only the first three are in rotation:
/// usable now or within hours, so worth reading by themselves. A used-up week comes back only at
/// its reset and an unusable account only after it is fixed, so neither is read until then.
public enum AccountStanding: Int, Comparable, Sendable {
    case usable, unread, limited, weekUsed, unavailable
    public var isInRotation: Bool { self == .usable || self == .unread || self == .limited }
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

public struct PoolSession: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var accountID: UUID
    public var name: String
    public var model: String
    public var state: SessionState
    public var startedAt: Date
    /// The Desktop conversation the run serves, as a content-free tag of its client session id. Side
    /// requests (titles, summaries) carry their conversation's tag, so the app counts conversations,
    /// not runs. Nil for a request that named no session.
    public var conversation: String?
    /// A one-off ask Claude Code makes by itself (a title, a topic, the auto mode classifier): no tools
    /// and no earlier reply. It is no conversation of the user's, and its run ends once it has answered.
    public var isOneOff: Bool
    public init(id: UUID = UUID(), accountID: UUID, name: String, model: String, state: SessionState, startedAt: Date = Date(),
                conversation: String? = nil, isOneOff: Bool = false) {
        self.id = id; self.accountID = accountID; self.name = name; self.model = model; self.state = state; self.startedAt = startedAt
        self.conversation = conversation; self.isOneOff = isOneOff
    }
}

public struct PoolPreferences: Codable, Equatable, Sendable {
    public var port: UInt16
    public var language: String
    public var appearance: String
    public var routingPolicy: RoutingPolicy
    public var quotaRefresh: QuotaRefreshPreferences
    /// The plan whose quota the menu bar shows when accounts have different plans.
    public var menuBarPlan: String?
    /// When the pool starts accounts' limits itself.
    public var warmUp: WarmUpPreferences
    /// Shows account emails with the name before "@" masked, for screen sharing.
    public var maskEmail: Bool
    /// Whether requests are redacted before they reach Claude. On unless the person turns it off.
    public var redaction: Bool
    public init(port: UInt16 = 18473, language: String = "system", routingPolicy: RoutingPolicy = .init(),
                quotaRefresh: QuotaRefreshPreferences = .init(), appearance: String = "system", menuBarPlan: String? = nil,
                warmUp: WarmUpPreferences = .init(), maskEmail: Bool = false, redaction: Bool = true) {
        self.port = port; self.language = language; self.routingPolicy = routingPolicy; self.quotaRefresh = quotaRefresh
        self.appearance = appearance; self.menuBarPlan = menuBarPlan; self.warmUp = warmUp; self.maskEmail = maskEmail
        self.redaction = redaction
    }
    enum CodingKeys: String, CodingKey { case port, language, routingPolicy, quotaRefresh, appearance, menuBarPlan, warmUp, maskEmail, redaction }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(port: try values.decode(UInt16.self, forKey: .port), language: try values.decode(String.self, forKey: .language),
                  routingPolicy: try values.decodeIfPresent(RoutingPolicy.self, forKey: .routingPolicy) ?? .init(),
                  quotaRefresh: try values.decodeIfPresent(QuotaRefreshPreferences.self, forKey: .quotaRefresh) ?? .init(),
                  appearance: try values.decodeIfPresent(String.self, forKey: .appearance) ?? "system",
                  menuBarPlan: try values.decodeIfPresent(String.self, forKey: .menuBarPlan),
                  warmUp: (try? values.decodeIfPresent(WarmUpPreferences.self, forKey: .warmUp)) ?? .init(),
                  maskEmail: try values.decodeIfPresent(Bool.self, forKey: .maskEmail) ?? false,
                  redaction: try values.decodeIfPresent(Bool.self, forKey: .redaction) ?? true)
        guard ["system", "light", "dark"].contains(appearance) else {
            throw DecodingError.dataCorruptedError(forKey: .appearance, in: values, debugDescription: "Invalid appearance")
        }
    }
}

public enum EmailMask {
    /// `ada.lovelace@example.com` → `a••••••••••e@example.com`: the name before "@" keeps only its first
    /// and last characters, so accounts stay apart; a name of one or two characters is hidden entirely.
    public static func masked(_ email: String) -> String {
        guard let at = email.lastIndex(of: "@") else { return email }
        let name = email[..<at], domain = email[at...]
        guard !name.isEmpty else { return email }
        let hidden = String(repeating: "•", count: min(max(name.count - 2, 3), 8))
        guard name.count > 2, let first = name.first, let last = name.last else { return "•••" + domain }
        return String(first) + hidden + String(last) + domain
    }
}

public struct QuotaRefreshPreferences: Codable, Equatable, Sendable {
    public var quietInterval: TimeInterval
    public var interactiveInterval: TimeInterval
    public var generatingInterval: TimeInterval
    public var concurrentInterval: TimeInterval
    public var burstInterval: TimeInterval
    public var confirmAfterReset: Bool
    public var isValid: Bool {
        let rates = [quietInterval, interactiveInterval, generatingInterval, concurrentInterval, burstInterval]
        return rates.allSatisfy { $0.isFinite && (10...600).contains($0) } &&
            zip(rates, rates.dropFirst()).allSatisfy { $0 >= $1 }
    }
    public init(quietInterval: TimeInterval = 300, interactiveInterval: TimeInterval = 120,
                generatingInterval: TimeInterval = 45, concurrentInterval: TimeInterval = 20, burstInterval: TimeInterval = 10,
                confirmAfterReset: Bool = true) {
        self.quietInterval = quietInterval; self.interactiveInterval = interactiveInterval
        self.generatingInterval = generatingInterval; self.concurrentInterval = concurrentInterval; self.burstInterval = burstInterval
        self.confirmAfterReset = confirmAfterReset
    }
    /// Anchors describe a continuous demand curve; they are not selected as fixed modes.
    public func interval(demand: Double) -> TimeInterval {
        let anchors: [(Double, TimeInterval)] = [(0, quietInterval), (0.5, interactiveInterval),
            (1, generatingInterval), (2, concurrentInterval), (4, burstInterval)]
        let value = min(4, max(0, demand))
        for (lower, upper) in zip(anchors, anchors.dropFirst()) where value <= upper.0 {
            let weight = (value - lower.0) / (upper.0 - lower.0)
            return exp(log(lower.1) * (1 - weight) + log(upper.1) * weight)
        }
        return burstInterval
    }
    enum CodingKeys: String, CodingKey {
        case quietInterval, interactiveInterval, generatingInterval, concurrentInterval, burstInterval
        case lowInterval, mediumInterval, highInterval, activeInterval, confirmAfterReset
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let oldActive = try values.decodeIfPresent(TimeInterval.self, forKey: .activeInterval)
        let oldHigh = try values.decodeIfPresent(TimeInterval.self, forKey: .highInterval) ?? oldActive
        let oldMedium = try values.decodeIfPresent(TimeInterval.self, forKey: .mediumInterval) ?? oldActive.map { min(600, $0 * 2) }
        let oldLow = try values.decodeIfPresent(TimeInterval.self, forKey: .lowInterval) ?? oldActive.map { min(600, $0 * 5) }
        let burst = try values.decodeIfPresent(TimeInterval.self, forKey: .burstInterval) ?? oldHigh ?? 10
        let interactive = try values.decodeIfPresent(TimeInterval.self, forKey: .interactiveInterval) ?? oldMedium ?? 120
        self.init(quietInterval: try values.decodeIfPresent(TimeInterval.self, forKey: .quietInterval) ?? oldLow ?? 300,
                  interactiveInterval: interactive,
                  generatingInterval: try values.decodeIfPresent(TimeInterval.self, forKey: .generatingInterval) ??
                    (oldHigh == nil ? max(burst, min(45, interactive)) : sqrt(interactive * burst)),
                  concurrentInterval: try values.decodeIfPresent(TimeInterval.self, forKey: .concurrentInterval) ??
                    (oldHigh == nil ? max(burst, min(20, interactive)) : burst),
                  burstInterval: burst,
                  confirmAfterReset: try values.decodeIfPresent(Bool.self, forKey: .confirmAfterReset) ?? true)
        guard isValid else { throw DecodingError.dataCorruptedError(forKey: .burstInterval, in: values, debugDescription: "Invalid quota refresh interval.") }
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(quietInterval, forKey: .quietInterval)
        try values.encode(interactiveInterval, forKey: .interactiveInterval)
        try values.encode(generatingInterval, forKey: .generatingInterval)
        try values.encode(concurrentInterval, forKey: .concurrentInterval)
        try values.encode(burstInterval, forKey: .burstInterval)
        try values.encode(confirmAfterReset, forKey: .confirmAfterReset)
    }
}

/// Both strategies keep usable existing conversations on their current account.
public enum RoutingStrategy: String, Codable, CaseIterable, Sendable { case mostHeadroom, ordered }

public struct RoutingPolicy: Codable, Equatable, Sendable {
    public var strategy: RoutingStrategy
    public var accountOrder: [UUID]
    public var reservePercent: Double
    public var isValid: Bool { reservePercent.isFinite && (0...25).contains(reservePercent) }
    public init(strategy: RoutingStrategy = .mostHeadroom, accountOrder: [UUID] = [], reservePercent: Double = 10) {
        self.strategy = strategy; self.accountOrder = accountOrder; self.reservePercent = reservePercent
    }
    enum CodingKeys: String, CodingKey { case strategy, accountOrder, reservePercent }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(strategy: try values.decode(RoutingStrategy.self, forKey: .strategy),
                  accountOrder: try values.decode([UUID].self, forKey: .accountOrder),
                  reservePercent: try values.decodeIfPresent(Double.self, forKey: .reservePercent) ?? 10)
        guard isValid else { throw DecodingError.dataCorruptedError(forKey: .reservePercent, in: values, debugDescription: "Invalid routing reserve.") }
    }
}

public enum RoutingReason: String, Codable, Sendable {
    case sessionAffinity, toolContinuation, accountOrder, headroom, unknownQuota
    case accountLimited, accountUnavailable, paused, cancelled, noAvailableAccount, requestRejected
    case lowQuota, quotaExhausted, failover, capacityReached, modelUnavailable
}

/// Account identity and prompt contents are resolved by the local UI, never written into a route record.
public struct RouteDecision: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    public var sessionID: UUID?
    public var accountID: UUID?
    public var model: String
    public var reason: RoutingReason
    public var strategy: RoutingStrategy
    public init(id: UUID = UUID(), timestamp: Date = Date(), sessionID: UUID? = nil, accountID: UUID? = nil,
                model: String, reason: RoutingReason, strategy: RoutingStrategy) {
        self.id = id; self.timestamp = timestamp; self.sessionID = sessionID; self.accountID = accountID
        self.model = model; self.reason = reason; self.strategy = strategy
    }
}

public struct QuotaAssessment: Equatable, Sendable {
    public enum State: String, Sendable { case available, unknown, exhausted, notApplicable }
    public var state: State
    /// The smallest reported remaining fraction, used for ordering only; never a capacity estimate.
    public var headroom: Double?
    public init(state: State, headroom: Double? = nil) { self.state = state; self.headroom = headroom }
}

public struct RoutingHandoff: Equatable, Sendable {
    public var account: PoolAccount
    public var reason: RoutingReason
    public init(account: PoolAccount, reason: RoutingReason) { self.account = account; self.reason = reason }
}

public struct QuotaPoolGroup: Equatable, Sendable, Identifiable {
    public var id: String
    public var windowID: String
    public var scope: QuotaScope
    public var plan: String?
    public var accountIDs: [UUID]
    public var knownCount: Int
    public var unknownCount: Int
    public var notApplicableCount: Int
    /// The sum of reported remaining fractions for comparable accounts; not tokens or time.
    public var remainingUnits: Double?
    /// The average over the accounts whose limit is known.
    public var averageRemainingPercent: Double?
    /// Excludes accounts whose other relevant windows or authentication prevent use now.
    public var usableNowUnits: Double?
    public var nextResetAt: Date?
    public var isComplete: Bool { unknownCount == 0 }
}

public struct QuotaPoolSummary: Equatable, Sendable {
    public var groups: [QuotaPoolGroup]
    public var totalAccounts: Int
    public var usableAccounts: Int
    public var unknownAccounts: Int
    public var recovery: PoolRecoverySummary

    public static func evaluate(_ savedAccounts: [PoolAccount], model: String, now: Date = Date()) -> QuotaPoolSummary {
        let accounts = savedAccounts.filter { $0.state != .disabled }
        // Generic Max, Team and Enterprise labels do not establish comparable seat capacities.
        let comparablePlans: Set<String> = ["Pro", "Max 5x", "Max 20x", "Ultra"]
        let buckets = Dictionary(grouping: accounts) { account in
            account.plan.flatMap { comparablePlans.contains($0) ? "plan:\($0)" : nil } ?? "account:\(account.id.uuidString)"
        }
        var groups: [QuotaPoolGroup] = []
        for key in buckets.keys.sorted() {
            let members = buckets[key]!
            let windowIDs = Set(members.flatMap { $0.windows.filter { model == PoolRouting.anyModel || $0.applies(to: model) }.map(\.id) })
            for windowID in windowIDs.sorted(by: { (QuotaWindow.displayRank($0), $0) < (QuotaWindow.displayRank($1), $1) }) {
                var known = 0, unknown = 0, notApplicable = 0
                let isModelWindow = QuotaWindow.canonical(windowID).map { if case .models = $0.scope { return true } else { return false } } ?? false
                var remaining = 0.0, usable = 0.0
                var resets: [Date] = []
                var scope: QuotaScope?
                for account in members {
                    guard let window = account.windows.first(where: { $0.id == windowID && (model == PoolRouting.anyModel || $0.applies(to: model)) }) else {
                        // An account whose panel was read and has no row for a model is held only by the global limits for it:
                        // it is not unknown there. One never read still is.
                        if isModelWindow, account.windows.contains(where: { $0.isGlobal && $0.state == .reported }) { continue }
                        unknown += 1; continue
                    }
                    scope = window.scope
                    if window.isNotApplicable(at: now) { notApplicable += 1; continue }
                    guard var amount = PoolRouting.remaining(window, in: account, now: now) else { unknown += 1; continue }
                    // A shorter limit is of no use while a longer one is used up: a 5-hour limit renewed under a
                    // spent week counts as nothing left, not as full. What a week has left under a spent 5-hour
                    // limit is real and comes back at that limit's reset.
                    if window.isGlobal,
                       account.windows.contains(where: { $0.isGlobal && $0.span > window.span && $0.isExhausted(at: now) }) { amount = 0 }
                    // Percent sums stay exact for the whole-number readings Claude shows.
                    known += 1; remaining += amount
                    if account.effectiveState(at: now) == .ready, account.cooldownUntil.map({ $0 <= now }) ?? true,
                       PoolRouting.assessment(account, model: model, now: now).state == .available { usable += amount }
                    if let reset = window.resetsAt, reset > now { resets.append(reset) }
                }
                if scope == nil { scope = members.lazy.compactMap { $0.windows.first { $0.id == windowID } }.first?.scope }
                groups.append(QuotaPoolGroup(id: key + "/" + windowID, windowID: windowID, scope: scope ?? .other,
                    plan: members.first?.plan, accountIDs: members.map(\.id), knownCount: known, unknownCount: unknown,
                    notApplicableCount: notApplicable,
                    remainingUnits: known > 0 ? remaining / 100 : nil,
                    averageRemainingPercent: known > 0 ? remaining / Double(known) : nil,
                    usableNowUnits: known > 0 ? usable / 100 : nil, nextResetAt: resets.min()))
            }
        }
        return QuotaPoolSummary(groups: groups, totalAccounts: accounts.count,
            usableAccounts: PoolRouting.candidates(accounts, model: model, now: now).filter {
                [.available, .notApplicable].contains(PoolRouting.assessment($0, model: model, now: now).state)
            }.count,
            unknownAccounts: accounts.filter { $0.standing(at: now) == .unread }.count,
            recovery: QuotaRecovery.pool(accounts, model: model, now: now))
    }
}

/// Accounts best first: usable ones in the order routing would give them a new conversation, then
/// the unread, then those coming back soonest, and those that cannot be used last. Ties keep their
/// saved order. The first account listed is the one a new conversation goes to.
public enum AccountOrdering {
    public static func ranked(_ accounts: [PoolAccount], now: Date, policy: RoutingPolicy = .init(), load: [UUID: Int] = [:]) -> [PoolAccount] {
        let routed = PoolRouting.candidates(accounts, model: PoolRouting.anyModel, now: now, policy: policy, load: load)
        let routeIndex = Dictionary(routed.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let keyed = accounts.enumerated().map { index, account -> (account: PoolAccount, standing: AccountStanding, route: Int, left: Double, back: Date, index: Int) in
            var back = Date.distantFuture
            if case .scheduled(let date) = QuotaRecovery.account(account, model: PoolRouting.anyModel, now: now) { back = date }
            return (account, account.standing(at: now), routeIndex[account.id] ?? Int.max,
                    PoolRouting.assessment(account, model: PoolRouting.anyModel, now: now).headroom ?? -1, back, index)
        }
        return keyed.sorted { a, b in
            if a.standing != b.standing { return a.standing < b.standing }
            if a.route != b.route { return a.route < b.route }
            if a.left != b.left { return a.left > b.left }
            if a.back != b.back { return a.back < b.back }
            return a.index < b.index
        }.map(\.account)
    }
}

public enum AccountRecovery: Equatable, Sendable {
    case available, scheduled(Date), unknown, unavailable
}

public struct PoolRecoverySummary: Equatable, Sendable {
    /// When the first blocked account is back: every limit holding it has reset by then.
    public var nextRecoveryAt: Date?
    public var availableCount: Int
    public var unknownCount: Int
}

public enum QuotaRecovery {
    /// A limit is back at its reset; Claude restores it then, and the next reading confirms it.
    public static func account(_ account: PoolAccount, model: String, now: Date = Date()) -> AccountRecovery {
        guard account.email?.isEmpty == false, [.ready, .limited].contains(account.state) else { return .unavailable }
        let windows = account.windows.filter { $0.applies(to: model) }
        guard !windows.isEmpty else { return .unknown }
        var deadlines: [Date] = []
        var unknown = false
        for window in windows where !window.isNotApplicable(at: now) {
            guard window.remaining(at: now) != nil else { unknown = true; continue }
            if window.isExhausted(at: now) {
                // Without a stated reset the time it is back is not known, though it is at most a cycle away.
                if let reset = window.resetsAt { deadlines.append(reset) } else { unknown = true }
            }
        }
        if let cooldown = account.cooldownUntil, cooldown > now { deadlines.append(cooldown) }
        guard !unknown else { return .unknown }
        if let latest = deadlines.max() { return .scheduled(latest) }
        return .available
    }

    public static func pool(_ accounts: [PoolAccount], model: String, now: Date = Date()) -> PoolRecoverySummary {
        let states = accounts.map { account($0, model: model, now: now) }
        let deadlines = states.compactMap { state -> Date? in if case .scheduled(let date) = state { return date }; return nil }
        return PoolRecoverySummary(nextRecoveryAt: deadlines.min(),
            availableCount: states.filter { $0 == .available }.count,
            unknownCount: states.filter { $0 == .unknown }.count)
    }
}

public struct PoolLibrary: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var accounts: [PoolAccount]
    public var preferences: PoolPreferences
    /// What each model alias ran on when a session last reported it; clients are shown these ids.
    public var reportedModels: [ModelIdentity]?
    public init(accounts: [PoolAccount] = [], preferences: PoolPreferences = .init(), reportedModels: [ModelIdentity]? = nil) {
        self.accounts = accounts; self.preferences = preferences; self.reportedModels = reportedModels
    }
    /// 0.1.9 could put the whole account on cooldown for a refusal at one model's limit (Fable's).
    /// Such a cooldown, one that matches a model window's reset and no global window's, is lifted
    /// and held by that window alone. Returns whether anything changed.
    @discardableResult
    public mutating func liftModelCooldowns(at now: Date) -> Bool {
        var changed = false
        for index in accounts.indices {
            guard let cooldown = accounts[index].cooldownUntil, cooldown > now else { continue }
            let windows = accounts[index].windows
            func matches(_ window: QuotaWindow) -> Bool { window.resetsAt.map { abs($0.timeIntervalSince(cooldown)) < 60 } ?? false }
            guard !windows.contains(where: { $0.isGlobal && (matches($0) || $0.isExhausted(at: now)) }),
                  let target = windows.firstIndex(where: { $0.scope.isModels && matches($0) }) else { continue }
            accounts[index].cooldownUntil = nil
            var window = accounts[index].windows[target]
            window.usedPercent = 100; window.state = .reported
            window.refusedUntil = cooldown; window.refusalStatedReset = true
            accounts[index].windows[target] = window
            changed = true
        }
        return changed
    }
    /// Records what `identity`'s alias runs on; returns whether that changed.
    public mutating func record(_ identity: ModelIdentity) -> Bool {
        var models = reportedModels ?? []
        guard !models.contains(identity) else { return false }
        models.removeAll { $0.alias == identity.alias }
        models.append(identity)
        reportedModels = models.sorted { $0.alias < $1.alias }
        return true
    }
}

/// How Claude Desktop reaches the pool, as Desktop's own settings files say.
public enum DesktopLink: String, Codable, Equatable, Sendable {
    case notInstalled, disconnected, connected
    /// Connected, but the running Desktop started before and still uses what it read then.
    case needsRestart
    /// Pool connected it, and Desktop's settings were changed since.
    case changed
    /// Connected by an earlier version: Connect again writes what this one adds (tool search).
    case outdated
    /// Pool connected Desktop and it was not disconnected: the pool serves.
    public var isLinked: Bool { self == .connected || self == .needsRestart || self == .changed || self == .outdated }
}

public struct PoolSnapshot: Equatable, Sendable {
    public var mode: PoolMode
    public var accounts: [PoolAccount]
    public var sessions: [PoolSession]
    public var executableReady: Bool
    public var desktop: DesktopLink
    public var notice: String?
    public var routeDecisions: [RouteDecision]
    public init(mode: PoolMode = .stopped, accounts: [PoolAccount] = [], sessions: [PoolSession] = [],
                executableReady: Bool = false, desktop: DesktopLink = .disconnected, notice: String? = nil, routeDecisions: [RouteDecision] = []) {
        self.mode = mode; self.accounts = accounts; self.sessions = sessions
        self.executableReady = executableReady; self.desktop = desktop; self.notice = notice
        self.routeDecisions = routeDecisions
    }
}

public enum PoolRouting {
    /// Assess only the limits that apply to every model. Pool readiness and totals are never
    /// filtered by one model; a model's own weekly limit is shown as its own figure.
    public static let anyModel = ""
    /// Work each account serves now. A conversation counts once while at most one of its runs is
    /// answering (a new run starts while the one it replaces winds down idle); each run answering at
    /// the same time counts on its own (a conversation's sub-agents, sessions of their own under its
    /// tag), so a batch weighs on its account as the work it is. A run that named no conversation
    /// counts on its own, and one-off asks and ended runs not at all.
    public static func conversationLoad(_ sessions: [PoolSession]) -> [UUID: Int] {
        var live: [UUID: [String: Int]] = [:]
        for session in sessions where session.state != .ended && !session.isOneOff {
            let key = session.conversation ?? session.id.uuidString
            let answering = [.starting, .running, .waiting].contains(session.state) ? 1 : 0
            live[session.accountID, default: [:]][key, default: 0] += answering
        }
        return live.mapValues { $0.values.reduce(0) { $0 + max(1, $1) } }
    }
    /// How well an account suits a new conversation, from 0 to about 100. Nothing decides alone:
    /// what is left of the 5-hour limit and of the week weigh about the same; a 5-hour limit that is
    /// about to renew counts for a little more than it reads; a week within two days of its reset
    /// counts what it has used less and less, as that comes back, and its unused share is worth spending first; and each conversation already on the account weighs against it.
    /// A week nearly used up caps the 5-hour limit: below `weekCaps` percent left, the 5-hour share
    /// counts only in proportion, since the account stops when its week does, however full the 5 hours.
    /// Nil when a limit's figure is unknown.
    /// Weekly percent left below which the week limits what the 5-hour share is worth.
    public static let weekCaps = 25.0
    /// How long before its reset a week starts to count as coming back, and its unused share as lapsing.
    public static let weekSoon: TimeInterval = 2 * 86400
    public static func score(_ account: PoolAccount, model: String, now: Date = Date(), load: Int = 0) -> Double? {
        guard assessment(account, model: model, now: now).state == .available else { return nil }
        let windows = account.windows.filter { $0.applies(to: model) && !$0.isNotApplicable(at: now) }
        func left(_ id: String) -> (Double, TimeInterval?)? {
            let found = windows.filter { $0.id == id || (id == "seven_day" && $0.id.hasPrefix("seven_day")) }
            guard let tightest = found.compactMap({ w in w.remaining(at: now).map { (w, $0) } }).min(by: { $0.1 < $1.1 }) else { return nil }
            let (w, value) = tightest
            return (value, w.isRenewed(at: now) ? nil : w.resetsAt.map { max(0, $0.timeIntervalSince(now)) })
        }
        let session = left("five_hour"), week = left("seven_day")
        guard session != nil || week != nil else { return nil }
        var sessionValue = session?.0 ?? week!.0
        if let (value, until) = session, let until {
            // Up to half of what is used comes back in the score as the reset nears.
            sessionValue = value + (100 - value) * 0.5 * max(0, 1 - until / (5 * 3600))
        }
        if let (value, _) = week { sessionValue *= min(1, max(0, value) / weekCaps) }
        var weekValue = week?.0 ?? sessionValue
        if let (value, until) = week, let until {
            // What the week has used comes back at its reset: over its last two days it weighs less and less.
            weekValue = value + (100 - value) * max(0, 1 - until / weekSoon)
        }
        var expiring = 0.0
        if let (value, until) = week, let until { expiring = value * max(0, 1 - until / weekSoon) }
        let total = 0.45 * sessionValue + 0.40 * weekValue + 0.15 * expiring - 8 * Double(max(0, load))
        return total
    }
    /// Points a warm prompt cache adds to an account's score: one per `warmTokensPerPoint` tokens of
    /// instructions and tools it already holds for the model, at most `warmMost` (Pool's own). It weighs
    /// with the quota factors and never decides alone: an account with clearly more left still wins, and
    /// the largest prefix is worth about one conversation already on the account.
    public static let warmTokensPerPoint = 5000.0
    public static let warmMost = 10.0
    public static func warmBonus(tokens: Int) -> Double { min(warmMost, max(0, Double(tokens)) / warmTokensPerPoint) }
    /// `bonus`: points added to an account's score, for what it already has cached of the request.
    public static func candidates(_ accounts: [PoolAccount], model: String, preferred: UUID? = nil,
                                  excluding: Set<UUID> = [], now: Date = Date(), policy: RoutingPolicy = .init(),
                                  load: [UUID: Int] = [:], bonus: [UUID: Double] = [:]) -> [PoolAccount] {
        let originalOrder = Dictionary(accounts.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        let configuredOrder = Dictionary(policy.accountOrder.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        func rank(_ id: UUID) -> Int { configuredOrder[id] ?? (policy.accountOrder.count + (originalOrder[id] ?? accounts.count)) }
        return accounts.filter { account in
            guard !excluding.contains(account.id), account.email?.isEmpty == false, account.effectiveState(at: now) == .ready,
                  account.cooldownUntil.map({ $0 <= now }) ?? true else { return false }
            return assessment(account, model: model, now: now).state != .exhausted
        }.sorted { a, b in
            if (a.id == preferred) != (b.id == preferred) { return a.id == preferred }
            if policy.strategy == .mostHeadroom {
                let qa = score(a, model: model, now: now, load: load[a.id] ?? 0).map { $0 + (bonus[a.id] ?? 0) }
                let qb = score(b, model: model, now: now, load: load[b.id] ?? 0).map { $0 + (bonus[b.id] ?? 0) }
                if (qa == nil) != (qb == nil) { return qa != nil }
                if let qa, let qb, qa != qb { return qa > qb }
            }
            if rank(a.id) != rank(b.id) { return rank(a.id) < rank(b.id) }
            return a.id.uuidString < b.id.uuidString
        }
    }
    public static func assessment(_ account: PoolAccount, model: String, now: Date = Date()) -> QuotaAssessment {
        let windows = account.windows.filter { $0.applies(to: model) }
        guard !windows.isEmpty else { return .init(state: .unknown) }
        // A confirmed exhausted window stays blocked until its stated reset, even if the reading is stale.
        if windows.contains(where: { $0.isExhausted(at: now) }) { return .init(state: .exhausted) }
        let applicable = windows.filter { !$0.isNotApplicable(at: now) }
        guard !applicable.isEmpty else { return .init(state: .notApplicable) }
        let values = applicable.compactMap { remaining($0, in: account, now: now) }
        guard values.count == applicable.count else { return .init(state: .unknown) }
        return .init(state: .available, headroom: values.min())
    }
    public static func remaining(_ window: QuotaWindow, in account: PoolAccount, now: Date = Date()) -> Double? {
        window.remaining(at: now)
    }
    /// Use only between user turns. Pending client tools must stay on the worker that issued them.
    /// Moving a conversation to another account writes its whole context there once, so a move costs what
    /// the conversation holds (Pool's own). One small enough now (`smallMoveTokens`, such as just after a
    /// compaction) on an account nearly used up (`smallMoveBelow` percent left) goes at its next turn to an
    /// account with clearly more left (`smallMoveGain` points more), instead of growing there until the
    /// limit stops it and the move writes far more. Nil when it should stay.
    public static let smallMoveTokens = 60_000
    public static let smallMoveBelow = 20.0
    public static let smallMoveGain = 40.0
    public static func moveWhileSmall(_ accounts: [PoolAccount], model: String, currentID: UUID, contextTokens: Int?,
                                      policy: RoutingPolicy = .init(), now: Date = Date()) -> PoolAccount? {
        guard policy.isValid, policy.strategy == .mostHeadroom, let tokens = contextTokens, tokens > 0, tokens <= smallMoveTokens,
              let current = accounts.first(where: { $0.id == currentID }),
              let headroom = assessment(current, model: model, now: now).headroom, headroom < smallMoveBelow else { return nil }
        return candidates(accounts, model: model, excluding: [currentID], now: now, policy: policy)
            .first { (assessment($0, model: model, now: now).headroom ?? -1) >= headroom + smallMoveGain }
    }
    public static func handoff(_ accounts: [PoolAccount], model: String, currentID: UUID,
                               policy: RoutingPolicy = .init(), now: Date = Date()) -> RoutingHandoff? {
        guard policy.isValid, let current = accounts.first(where: { $0.id == currentID }) else { return nil }
        let backups = candidates(accounts, model: model, excluding: [currentID], now: now, policy: policy)
        let currentQuota = assessment(current, model: model, now: now)
        let eligible = current.email?.isEmpty == false && current.effectiveState(at: now) == .ready &&
            (current.cooldownUntil.map { $0 <= now } ?? true) && currentQuota.state != .exhausted
        if !eligible, let backup = backups.first {
            return .init(account: backup, reason: currentQuota.state == .exhausted ? .quotaExhausted : .accountUnavailable)
        }
        guard let currentHeadroom = currentQuota.headroom, currentHeadroom <= policy.reservePercent,
              let backup = backups.first(where: { (assessment($0, model: model, now: now).headroom ?? -1) > policy.reservePercent }) else { return nil }
        return .init(account: backup, reason: .lowQuota)
    }
}
