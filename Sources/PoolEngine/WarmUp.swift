import Foundation
import PoolCore
import PoolRuntime

public enum WarmUpUpdate: Equatable, Sendable {
    case sending(UUID)
    case sent(UUID, at: Date)
    /// `reason` is a fixed English sentence the interface translates.
    case failed(UUID, reason: String)
}

/// Looks over the accounts every minute and starts, one account at a time, the limits that are
/// due (`WarmUpPlanner`). Nothing is sent while the Mac sleeps or is offline: a limit that came
/// back meanwhile starts when it wakes. What was sent is kept, so a restart neither repeats a
/// warm-up nor forgets one that was waiting to be tried again.
public actor WarmUpScheduler {
    public typealias Send = @Sendable (PoolAccount) async throws -> Void
    private let workspace: OwnedWorkspace?
    private let send: Send
    private let now: @Sendable () -> Date
    private let calendar: @Sendable () -> Calendar
    private let update: @Sendable (WarmUpUpdate) async -> Void
    private var accounts: [PoolAccount] = []
    private var preferences = WarmUpPreferences()
    private var states: [UUID: WarmUpState] = [:]
    private var available = false
    private var sending: UUID?
    private var loop: Task<Void, Never>?
    private var looked = false

    public init(workspace: OwnedWorkspace?, now: @escaping @Sendable () -> Date = { Date() },
                calendar: @escaping @Sendable () -> Calendar = { Calendar.current },
                send: @escaping Send, update: @escaping @Sendable (WarmUpUpdate) async -> Void = { _ in }) {
        self.workspace = workspace; self.now = now; self.calendar = calendar; self.send = send; self.update = update
        if let workspace, let data = try? workspace.read(workspace.root.appendingPathComponent(Self.fileName), limit: 256 * 1024),
           let saved = try? JSONDecoder().decode([String: WarmUpState].self, from: data) {
            states = Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
        }
    }

    /// The first look comes after `delay`, so a launch is not crowded; then one every `interval`.
    public func start(after delay: TimeInterval = 120, every interval: TimeInterval = 60) {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            var wait = delay
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(max(1, wait) * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                await self.look()
                wait = interval
            }
        }
    }
    public func stop() { loop?.cancel(); loop = nil }

    public func setAccounts(_ accounts: [PoolAccount]) {
        self.accounts = accounts
        let ids = Set(accounts.map(\.id))
        if states.keys.contains(where: { !ids.contains($0) }) { states = states.filter { ids.contains($0.key) }; persist() }
    }
    public func setPreferences(_ preferences: WarmUpPreferences) { self.preferences = preferences }
    /// Waking or coming back online looks at once, once the first look after launch has come.
    public func setAvailable(_ available: Bool) {
        let woke = available && !self.available
        self.available = available
        if woke, looked, loop != nil { Task { await self.look() } }
    }
    public func state(_ id: UUID) -> WarmUpState? { states[id] }
    public func allStates() -> [UUID: WarmUpState] { states }

    /// One look over every account; due warm-ups go one at a time, in the accounts' order.
    public func look() async {
        guard available, sending == nil else { return }
        looked = true
        let date = now(), calendar = calendar()
        var changed = false
        for account in accounts {
            // A stretch ends once its limits run; the next reset begins a new one.
            if var state = states[account.id], state.since != nil,
               !account.windows.contains(where: { WarmUpPlanner.idle($0, at: date) }) {
                state.since = nil; state.tries = 0; state.retryAt = nil
                states[account.id] = state; changed = true
            }
        }
        if changed { persist() }
        for account in accounts {
            guard available, sending == nil,
                  let current = accounts.first(where: { $0.id == account.id }),
                  let plan = WarmUpPlanner.plan(current, preferences: preferences, state: states[account.id], now: now(), calendar: calendar)
            else { continue }
            var state = states[account.id] ?? WarmUpState()
            if state.since != plan.since { state.since = plan.since; state.tries = 0 }
            state.tries += 1
            // Recorded before sending: a request cut short by a crash is not repeated at once.
            state.retryAt = now().addingTimeInterval(WarmUpPlanner.retryDelay(tries: state.tries))
            states[account.id] = state; persist()
            if await perform(current, trigger: plan.daily != nil ? "daily" : "reset", windows: plan.windows, tries: state.tries) == nil, let daily = plan.daily {
                states[account.id]?.daily = daily; persist()
            }
        }
    }

    /// Starts `id`'s limits now, whatever the settings say, unless it cannot be used.
    public func warmNow(_ id: UUID) async throws {
        guard sending == nil else { throw BridgeFailure.busy }
        guard let account = accounts.first(where: { $0.id == id }), account.standing(at: now()) == .usable else {
            throw BridgeFailure.unavailable
        }
        if let error = await perform(account, trigger: "manual", windows: [], tries: 1) { throw error }
        // The looks leave this stretch be while its reading catches up, as after one of their own.
        var state = states[id] ?? WarmUpState()
        if state.since == nil { state.since = now() }
        state.retryAt = max(state.retryAt ?? .distantPast, now().addingTimeInterval(WarmUpPlanner.retryDelay(tries: 1)))
        states[id] = state; persist()
    }

    /// Sends one warm-up; returns why it did not go through, nil when it did.
    private func perform(_ account: PoolAccount, trigger: String, windows: [String], tries: Int) async -> Error? {
        sending = account.id
        defer { sending = nil }
        await update(.sending(account.id))
        let began = Date()
        func log(_ outcome: String) {
            Diagnostics.record("warmup.sent", ["account": Diagnostics.id(account.id), "trigger": trigger,
                "windows": windows.isEmpty ? "-" : windows.joined(separator: "+"), "try": String(tries), "outcome": outcome,
                "ms": String(Int(Date().timeIntervalSince(began) * 1000))])
        }
        do {
            try await send(account)
            log("ok")
            let date = now()
            states[account.id, default: WarmUpState()].warmedAt = date
            persist()
            await update(.sent(account.id, at: date))
            return nil
        } catch {
            log(String(describing: type(of: error)))
            let reason = (error as? LocalizedError)?.errorDescription ?? "The warm-up did not go through."
            await update(.failed(account.id, reason: reason))
            return error
        }
    }

    private static let fileName = "warm-up.json"
    /// Dates are kept exactly: a stretch is known again after a restart by the very reset it began at.
    private func persist() {
        guard let workspace else { return }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let saved = Dictionary(uniqueKeysWithValues: states.map { ($0.key.uuidString, $0.value) })
        try? workspace.write(encoder.encode(saved), to: workspace.root.appendingPathComponent(Self.fileName))
    }
}
