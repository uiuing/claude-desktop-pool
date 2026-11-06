import Foundation
import PoolCore

public actor PoolCoordinator: BridgeBackend {
    public typealias WorkerFactory = @Sendable (PoolAccount, PoolModel) async throws -> any SessionWorker
    private struct Binding {
        var worker: any SessionWorker
        var session: PoolSession
        var request: BridgeRequest
        var accountAtStart: PoolAccount
        /// The conversation with the run's last reply, as the run's next turn goes on from it:
        /// what the client sent and the reply told to it.
        var history: [BridgeMessage]
        /// The conversation as the client had it in the last request this run answers:
        /// tool results are the run's while the
        /// request goes on from it. The reply is not in it, so a client that keeps the reply its own way
        /// still finds the run.
        var told: [BridgeMessage] = []
        var busy = false
        var workState: QuotaWorkState = .idle
        var generationBeganAt: Date?
        var generationDuration: TimeInterval = 0
        var progressRequestID = UUID()
        var progressSequence = 0
        var progressCharacters = 0
        var progressSentCharacters = 0
        var progressReportedAt: Date?
        var pending: Set<String> = []
        var lastActive: Date
        var retiring = false
        /// The run never takes another turn: the reply was stopped or failed. It is ended normally
        /// when its conversation returns, when room is needed, or by the idle timer.
        var stopped = false
        /// The request this run answers now. A cancellation stops the run only for that request.
        var serving: UInt64?
        /// When the run began waiting on its reply's tool calls, and when it is let
        /// go if no result comes (its timer: runTimeout, or parkLongest once released).
        var parkedAt: Date?
        var parkEnds: Date?
        /// The client went on without this run's calls: it may still hear them, so it
        /// is kept, but it is the first of the waiting runs to give up its room.
        var released = false
    }
    /// A request between admission and the end of its reply: the conversation it came for and,
    /// once admitted, the run serving it. Cancellation names one of these, never a whole conversation.
    private struct Activity {
        var alias: String
        var binding: UUID?
    }
    private var accounts: [PoolAccount]
    private var routingPolicy: RoutingPolicy
    private let factory: WorkerFactory
    private let onUpdate: @Sendable (EngineUpdate) -> Void
    private var bindings: [UUID: Binding] = [:]
    private var aliases: [String: UUID] = [:]
    private var toolOwners: [String: UUID] = [:]
    private var observationTasks: [UUID: Task<Void, Never>] = [:]
    private var paused = false
    private var generations: UInt64 = 0
    private var active: [UInt64: Activity] = [:]
    private var cancelledGenerations = Set<UInt64>()
    /// The last request of a conversation whose reply failed, and when: a cancel for the conversation
    /// that arrives just after is that request's, not the retry's admitted since.
    private var creating = 0
    /// No bound in the app (Pool's own: macOS compresses and swaps memory itself, and a Claude Code process
    /// is some 170-205 MiB of footprint, so a bound read from memory only held conversations back); tests
    /// set one to exercise how runs make way.
    private let maximumWorkers: Int
    private let idleTimeout: TimeInterval
    private let idleKeep: TimeInterval
    private let idleMost: Int
    private let roomWait: TimeInterval
    private let parkLongest: TimeInterval
    private let runTimeout: TimeInterval
    private let parkedMost: Int
    private let duplicateWait: TimeInterval
    private let now: @Sendable () -> Date
    private var retirementTask: Task<Void, Never>?
    /// Accounts that refused for an unconfirmed limit rest briefly while their usage is read.
    private var resting: [UUID: Date] = [:]
    /// The shelf: the saved sessions of runs let go while they
    /// waited for their conversation's next turn, by that conversation, kept as long as the run would
    /// have waited, 64 at most.
    private struct Shelved {
        var saved: ShelvedSession
        var model: String
        var system: JSONValue?
        var tools: [BridgeTool]?
        var until: Date
        /// Only a conversation's own turns are shelved and taken: none with a tool choice, search or schema.
        func plain(_ request: BridgeRequest) -> Bool { request.toolChoice == nil && !request.webSearch && request.answerSchema == nil }
    }
    private var shelf: [String: Shelved] = [:]
    /// The account each conversation is on, kept the hour its prompt cache lasts (Pool's own): the cache
    /// is the account's, so a conversation whose run ended (stopped, parked too long, shelf out or
    /// edited) still goes back to that account while it can take it. Set when a run for the conversation
    /// starts, so a handoff to another account moves it at once, and renewed at each reply. Tags only.
    private var recentAccounts: [String: (account: UUID, until: Date)] = [:]
    /// Each run's state as last written to the log, so every change is logged once.
    private var loggedStates: [UUID: SessionState] = [:]
    private var healthTicks = 0
    /// The same, by how a conversation began: Desktop starts a new client session for a
    /// conversation after an error or a restart, and its next turns then carry a new session id.
    private var recentOpenings: [String: (account: UUID, until: Date)] = [:]
    private static let recentAccountsMost = 256
    private static let shelfMost = 64
    private static let unconfirmedRest: TimeInterval = 60

    /// `parkLongest`, `runTimeout` and `parkedMost` are the park bounds: a run waiting on
    /// tool calls is kept at most `runTimeout`, an hour (a subagent or a long command
    /// is one call, and a run let go before its result has its conversation told again in one message,
    /// written to the cache whole, while the hour's cache it wrote still holds it; past the hour the
    /// cache is gone either way, and room is still given up after `parkLongest`); once `parkedMost` runs
    /// have waited `parkLongest`, the longest waiting are let
    /// go, and one that has waited `parkLongest` gives its room to a new conversation. A result that
    /// comes after goes on in a new run told the whole conversation. `duplicateWait` is how long a
    /// request for a conversation still being answered waits for that reply to end before it is
    /// served on its own. `idleTimeout` and `idleMost` bound the idle runs:
    /// a run waits for its conversation's next turn as long as the
    /// hour's prompt cache it wrote lasts, and six such runs are kept. `maximumWorkers` and `roomWait`
    /// bound the room: a new run that finds it full waits for one to end, two
    /// minutes at most, before its request is answered busy; the app passes no bound, so
    /// only tests fill it. `idleKeep`: a run waiting for its conversation's next turn keeps its process five minutes, then is shelved for the rest of the
    /// hour. Keeping the process the whole hour would be needed if a run let go had its conversation told to a
    /// new one in one message, a prefix the cache never saw; Pool's shelf resumes the same session, so
    /// the next turn still reads the cache; most next turns come within five minutes, if at all.
    public init(accounts: [PoolAccount], routingPolicy: RoutingPolicy = .init(), maximumWorkers: Int = .max,
                idleTimeout: TimeInterval = 3600, idleKeep: TimeInterval = 300, idleMost: Int = 6, roomWait: TimeInterval = 120,
                parkLongest: TimeInterval = 300, runTimeout: TimeInterval = 3600,
                parkedMost: Int = 16, duplicateWait: TimeInterval = 1.5,
                now: @escaping @Sendable () -> Date = { Date() }, factory: @escaping WorkerFactory,
                onUpdate: @escaping @Sendable (EngineUpdate) -> Void = { _ in }) {
        self.accounts = accounts; self.routingPolicy = routingPolicy; self.factory = factory; self.onUpdate = onUpdate
        self.maximumWorkers = max(1, maximumWorkers); self.idleTimeout = max(1, idleTimeout); self.idleKeep = max(1, min(idleKeep, idleTimeout)); self.now = now
        self.idleMost = max(0, idleMost); self.roomWait = max(0, roomWait)
        self.parkLongest = max(0, parkLongest); self.runTimeout = max(1, runTimeout); self.parkedMost = max(0, parkedMost)
        self.duplicateWait = max(0, duplicateWait)
    }
    /// Which account each recent conversation is on, by content-free tags only, so a restart of the
    /// app keeps conversations on their accounts and their prompt caches.
    private struct Remembered: Codable { var conversations: [String: Entry]; var openings: [String: Entry]
        struct Entry: Codable { var account: UUID; var until: Date } }
    public func rememberedAccounts() -> Data? {
        let date = now()
        for binding in bindings.values { rememberAccount(binding) }
        func pack(_ table: [String: (account: UUID, until: Date)]) -> [String: Remembered.Entry] {
            table.filter { $0.value.until > date }.mapValues { .init(account: $0.account, until: $0.until) }
        }
        return try? JSONEncoder().encode(Remembered(conversations: pack(recentAccounts), openings: pack(recentOpenings)))
    }
    public func restoreRememberedAccounts(_ data: Data) {
        guard let saved = try? JSONDecoder().decode(Remembered.self, from: data) else { return }
        let date = now(), known = Set(accounts.map(\.id))
        for (key, entry) in saved.conversations where entry.until > date && known.contains(entry.account) && recentAccounts[key] == nil {
            recentAccounts[key] = (entry.account, entry.until)
        }
        for (key, entry) in saved.openings where entry.until > date && known.contains(entry.account) && recentOpenings[key] == nil {
            recentOpenings[key] = (entry.account, entry.until)
        }
    }
    public func updateAccounts(_ accounts: [PoolAccount]) { self.accounts = accounts }
    public func updateRoutingPolicy(_ policy: RoutingPolicy) { routingPolicy = policy }
    public func setPaused(_ paused: Bool) { self.paused = paused }
    public func sessions() -> [PoolSession] { bindings.values.map(\.session).sorted { $0.startedAt < $1.startedAt } }
    public func conversationAlias(for sessionID: UUID) -> String? {
        let matches = aliases.compactMap { $0.value == sessionID && !$0.key.hasPrefix("request:") ? $0.key : nil }
        let serving = Set(active.values.filter { $0.binding == sessionID }.map(\.alias))
        let current = matches.filter { serving.contains($0) }
        return (current.isEmpty ? matches : current).sorted {
            if $0.hasPrefix("privacy:") != $1.hasPrefix("privacy:") { return $0.hasPrefix("privacy:") }
            return $0 < $1
        }.first
    }

    /// The Desktop conversation an alias belongs to, as a content-free tag of its client session: a
    /// redaction context's id carries it after "@", a direct key before its shape's "#". A request that
    /// named no session belongs to none.
    static func conversationTag(_ alias: String) -> String? {
        if alias.hasPrefix("request:") { return nil }
        if alias.hasPrefix("privacy:") {
            guard let at = alias.lastIndex(of: "@") else { return nil }
            return String(alias[alias.index(after: at)...])
        }
        return Diagnostics.tag(String(alias.split(separator: "#", maxSplits: 1).first ?? Substring(alias)))
    }
    /// A one-off ask: no tools and
    /// no earlier reply, such as a title, a topic or the auto mode classifier. It has no next turn.
    static func isOneOff(_ request: BridgeRequest) -> Bool {
        (request.tools ?? []).isEmpty && !request.messages.contains { $0.role == "assistant" }
    }
    /// The account a conversation's latest run is on, while one is.
    /// A content-free tag of a conversation's first exchange, once it has one: its first message
    /// and the reply to it. Nil before a reply, so two conversations that open alike stay apart.
    static func openingTag(_ messages: [BridgeMessage]) -> String? {
        guard messages.count >= 2, messages[0].role == "user", messages[1].role == "assistant" else { return nil }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(Array(messages.prefix(2))) else { return nil }
        return Diagnostics.tag(String(decoding: data, as: UTF8.self))
    }
    private func openingAccount(of request: BridgeRequest) -> UUID? {
        // Only a turn that goes on from a reply: a first message alone is a new conversation.
        guard request.messages.count >= 3, let tag = Self.openingTag(request.messages), let recent = recentOpenings[tag], recent.until > now() else { return nil }
        return recent.account
    }
    private func leadAccount(of conversation: String) -> UUID? {
        if let live = bindings.values.filter({ $0.session.conversation == conversation && $0.session.state != .ended })
            .max(by: { $0.lastActive < $1.lastActive })?.session.accountID { return live }
        guard let recent = recentAccounts[conversation], recent.until > now() else { return nil }
        return recent.account
    }
    private func rememberAccount(_ binding: Binding) {
        guard let conversation = binding.session.conversation, !binding.session.isOneOff else { return }
        let date = now()
        recentAccounts[conversation] = (binding.session.accountID, binding.lastActive.addingTimeInterval(idleTimeout))
        recentAccounts = recentAccounts.filter { $0.value.until > date }
        if let opening = Self.openingTag(binding.history) {
            recentOpenings[opening] = (binding.session.accountID, binding.lastActive.addingTimeInterval(idleTimeout))
        }
        recentOpenings = recentOpenings.filter { $0.value.until > date }
        while recentOpenings.count > Self.recentAccountsMost, let oldest = recentOpenings.min(by: { $0.value.until < $1.value.until }) {
            recentOpenings.removeValue(forKey: oldest.key)
        }
        while recentAccounts.count > Self.recentAccountsMost, let oldest = recentAccounts.min(by: { $0.value.until < $1.value.until }) {
            recentAccounts.removeValue(forKey: oldest.key)
        }
    }

    public func events(for request: BridgeRequest, conversationID: String?) async throws -> AsyncThrowingStream<BridgeEvent, Error> {
        guard let model = PoolModel.defaults.first(where: { $0.id == request.model || $0.cliAlias == request.model }) else {
            throw BridgeFailure.unsupported("Choose a model listed by Claude Pool.")
        }
        guard !request.messages.isEmpty else { throw BridgeFailure.invalidRequest("The conversation is empty.") }
        let requestAlias = conversationID ?? "request:\(UUID().uuidString)"
        let results = try RequestContent.toolResults(request)
        guard Set(results.map(\.0)).count == results.count else { throw BridgeFailure.invalidRequest("A tool result was supplied more than once.") }
        if paused && results.isEmpty { route(model: model.id, reason: .paused); throw BridgeFailure.paused }
        generations += 1
        let generation = generations
        active[generation] = Activity(alias: requestAlias)
        var handedOff = false
        defer { if !handedOff { endGeneration(generation) } }
        // Claude Code sends a request again while the first is still answered (a resend, a retry after a
        // stream error). It waits briefly for that reply to end; past that it is its own conversation and
        // gets a run of its own, told it whole.
        let concurrent = await awaitOthers(on: requestAlias, generation: generation)
        guard !cancelledGenerations.contains(generation), !Task.isCancelled else { throw BridgeFailure.cancelled }
        let bindingID: UUID
        var replay = false
        var workerRequest = request
        if !results.isEmpty {
            let ids = Set(results.map(\.0))
            let (owner, why) = toolOwner(ids, request: request, concurrent: concurrent)
            if let owner {
                bindingID = owner
                route(id: owner, model: model.id, reason: .toolContinuation)
            } else {
                // Never refused: Claude Code does not retry a refusal and its agent stops. The results go on
                // in a new run told the whole conversation, as a new run is started when no
                // run waits for them.
                await settleForReplay(ids, why: why, alias: requestAlias, concurrent: concurrent)
                Diagnostics.record("coordinator.route", ["decision": "tool_result_replayed:" + why, "conversation": Diagnostics.tag(requestAlias),
                                                         "results": String(ids.count), "messages": String(request.messages.count)])
                bindingID = try await create(request: request, model: model, generation: generation, continuing: true)
                replay = true
            }
        } else if concurrent {
            Diagnostics.record("coordinator.route", ["decision": "busy_replaced", "why": "serving", "conversation": Diagnostics.tag(requestAlias),
                                                     "messages": String(request.messages.count)])
            bindingID = try await create(request: request, model: model, generation: generation)
        } else if !requestAlias.hasPrefix("request:"), let existing = aliases[requestAlias], let binding = bindings[existing], binding.stopped {
            // A stopped or failed reply never continues in its run. The run ends normally and the next turn
            // starts a new one with the client's full history.
            _ = await releaseStopped(existing)
            bindingID = try await create(request: request, model: model, generation: generation)
        } else if !requestAlias.hasPrefix("request:"), let existing = aliases[requestAlias], let binding = bindings[existing] {
            if binding.busy || binding.retiring || !binding.pending.isEmpty {
                // The client went on without the calls' results (a rewind or an edit), or the run is ending:
                // the turn starts a new run told the whole conversation. A run waiting on calls goes on
                // waiting parkLongest more.
                if !binding.pending.isEmpty && !binding.busy { release(existing) }
                Diagnostics.record("coordinator.route", ["decision": "busy_replaced",
                    "why": !binding.pending.isEmpty ? "pending_calls" : binding.busy ? "serving" : "retiring",
                    "conversation": Diagnostics.tag(requestAlias), "messages": String(request.messages.count)])
                bindingID = try await create(request: request, model: model, generation: generation)
            } else {
                let lowQuota = shouldHandoff(binding, model: model)
                let turn = compatible(binding, request: request) ? nextTurn(of: binding, request: request, alias: requestAlias) : nil
                if binding.session.state != .idle {
                    Diagnostics.record("coordinator.route", ["decision": "run_not_idle", "state": binding.session.state.rawValue,
                        "conversation": Diagnostics.tag(requestAlias), "messages": String(request.messages.count)])
                }
                if binding.session.state == .idle, let turn, eligible(binding, model: model), !lowQuota {
                    bindingID = existing; workerRequest = turn
                    route(id: existing, model: model.id, reason: .sessionAffinity)
                } else {
                    if lowQuota { route(id: existing, model: model.id, reason: .lowQuota) }
                    else if !eligible(binding, model: model) { route(id: existing, model: model.id, reason: unavailableReason(binding, model: model)) }
                    bindingID = try await replaceRun(existing, alias: requestAlias, request: request, model: model, generation: generation, lowQuota: lowQuota)
                }
            }
        } else {
            var turns: [UUID: BridgeRequest] = [:]
            for (id, binding) in bindings where !binding.busy && !binding.retiring && !binding.stopped && binding.pending.isEmpty &&
                binding.session.state == .idle && compatible(binding, request: request) && !binding.history.isEmpty {
                if let turn = nextTurn(of: binding, request: request, alias: requestAlias) { turns[id] = turn }
            }
            if turns.count == 1, let (only, turn) = turns.first, let candidate = bindings[only] {
                let lowQuota = shouldHandoff(candidate, model: model)
                if eligible(candidate, model: model) && !lowQuota {
                    bindingID = only; workerRequest = turn; route(id: only, model: model.id, reason: .sessionAffinity)
                }
                else {
                    route(id: only, model: model.id, reason: lowQuota ? .lowQuota : unavailableReason(candidate, model: model))
                    bindingID = try await replaceRun(only, alias: requestAlias, request: request, model: model, generation: generation, lowQuota: lowQuota)
                }
            } else if let (entry, turn) = takeShelved(request, model: model) {
                // The conversation's next turn goes on from its run's own session, on its
                // account; when that account can't take it now, the turn goes as any new one
                do { bindingID = try await create(request: request, model: model, generation: generation, only: entry.saved.accountID) }
                catch BridgeFailure.unavailable {
                    entry.saved.discard()
                    bindingID = try await create(request: request, model: model, generation: generation)
                }
                if bindings[bindingID]?.session.accountID == entry.saved.accountID,
                   await bindings[bindingID]?.worker.resume(from: entry.saved) == true {
                    workerRequest = turn
                    Diagnostics.record("coordinator.route", ["decision": "unshelved", "conversation": Diagnostics.tag(requestAlias),
                                                             "messages": String(request.messages.count)])
                } else { entry.saved.discard() }
            } else { bindingID = try await create(request: request, model: model, generation: generation) }
        }
        guard var binding = bindings[bindingID], !binding.busy, !binding.retiring else { throw BridgeFailure.busy }
        guard !cancelledGenerations.contains(generation), !Task.isCancelled else {
            if binding.pending.isEmpty, await binding.worker.close() { remove(bindingID) }
            else { bindings[bindingID]?.stopped = true; bindings[bindingID]?.session.state = .attention; publish(bindingID) }
            throw BridgeFailure.cancelled
        }
        // Pause admits continuations so tools already delivered can finish, but no new user turn.
        if paused && results.isEmpty { throw BridgeFailure.paused }
        binding.busy = true; binding.session.state = .running
        binding.lastActive = now()
        binding.parkedAt = nil; binding.parkEnds = nil; binding.released = false
        binding.serving = generation
        binding.request = request
        bindings[bindingID] = binding; aliases[requestAlias] = bindingID
        active[generation]?.binding = bindingID
        handedOff = true
        logState(bindingID, binding); onUpdate(.session(binding.session))
        let stream = AsyncThrowingStream<BridgeEvent, Error> { continuation in
            let task = Task { [weak self] in
                await self?.serve(bindingID, request: request, workerRequest: workerRequest, replay: replay, model: model,
                                  alias: requestAlias, generation: generation, continuation: continuation)
            }
            continuation.onTermination = { [weak self] reason in
                if case .cancelled = reason {
                    task.cancel()
                    // Only this request is cancelled: a retry admitted meanwhile is another one.
                    Task { await self?.cancel(generation: generation) }
                }
            }
        }
        return stream
    }

    /// Whether a new turn for `model` would find an account now. Nothing is started for it: a
    /// session that is already running, or room for one, is not needed to say so.
    public func checkAdmission(model id: String) async throws {
        guard let model = PoolModel.defaults.first(where: { $0.id == id || $0.cliAlias == id }) else {
            throw BridgeFailure.unsupported("Choose a model listed by Claude Pool.")
        }
        if paused { throw BridgeFailure.paused }
        let date = now(), resting = restingAccounts()
        guard PoolRouting.candidates(accounts, model: model.cliAlias, excluding: resting, now: date, policy: routingPolicy).isEmpty else { return }
        // Every account that could serve is at a limit: say when the first is back.
        var back: [Date] = self.resting.filter { resting.contains($0.key) }.map(\.value)
        var atLimit = !back.isEmpty
        for account in accounts where account.email?.isEmpty == false && [.ready, .limited].contains(account.effectiveState(at: date)) {
            guard account.effectiveState(at: date) == .limited ||
                  PoolRouting.assessment(account, model: model.cliAlias, now: date).state == .exhausted else { continue }
            atLimit = true
            if case .scheduled(let at) = QuotaRecovery.account(account, model: model.cliAlias, now: date) { back.append(at) }
        }
        throw atLimit ? BridgeFailure.rateLimited(back.min()) : BridgeFailure.unavailable
    }

    /// Waits up to `duplicateWait` for the conversation's other requests to end; true when one is still on.
    private func awaitOthers(on alias: String, generation: UInt64) async -> Bool {
        guard !alias.hasPrefix("request:") else { return false }
        let deadline = Date().addingTimeInterval(duplicateWait)
        while active.contains(where: { $0.key != generation && $0.value.alias == alias }) {
            if Date() >= deadline || Task.isCancelled || cancelledGenerations.contains(generation) { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }
    private func endGeneration(_ generation: UInt64) {
        active.removeValue(forKey: generation); cancelledGenerations.remove(generation)
    }

    /// The run the results go on in: the one that made the calls, while it still waits on these and the
    /// request's conversation goes on from the one it was told.
    /// Otherwise nil and why, as the gateway log names it, so the results are replayed, never refused.
    private func toolOwner(_ ids: Set<String>, request: BridgeRequest, concurrent: Bool) -> (UUID?, String) {
        if concurrent { return (nil, "answered_elsewhere") }
        let owners = Set(ids.compactMap { toolOwners[$0] })
        guard let owner = owners.first, let binding = bindings[owner] else { return (nil, "no_run_waiting") }
        guard owners.count == 1 else { return (nil, "ambiguous") }
        if binding.stopped { return (nil, "run_stopped") }
        guard !binding.busy, !binding.retiring, ids.isSubset(of: binding.pending), ids.allSatisfy({ toolOwners[$0] == owner }) else {
            return (nil, "answered_elsewhere")
        }
        guard sameIdentity(binding) else { return (nil, "account_changed") }
        guard binding.request.model == request.model else { return (nil, "model_changed") }
        guard compatible(binding, request: request, allowingToolChanges: true) else { return (nil, "context_changed") }
        // The request goes on from the one the run was told, or is it with only the client's images
        // taken out, or only the reminders Claude Code puts in once and takes out after (lostNotices, Pool's own).
        let notices = ConversationWords.lostNotices(was: binding.told, now: request.messages)
        if notices { Diagnostics.record("coordinator.route", ["decision": "notices_taken_out", "messages": String(request.messages.count)]) }
        guard ConversationWords.follows(request.messages, history: binding.told) ||
              ConversationWords.lostMedia(was: binding.told, now: request.messages) || notices else {
            recordDivergence(binding.told, request.messages)
            return (nil, "history_changed")
        }
        return (owner, "")
    }

    /// Where a request stopped going on from what its run was told: the first message that differs,
    /// its role and block kinds on each side. Never its words.
    private func recordDivergence(_ told: [BridgeMessage], _ now: [BridgeMessage]) {
        let before = ConversationWords.prefixKeys(told), after = ConversationWords.prefixKeys(now)
        let index = zip(before, after).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(before.count, after.count)
        func kinds(_ messages: [BridgeMessage]) -> String {
            guard index < messages.count else { return "-" }
            let message = messages[index]
            let blocks = message.content.stringValue != nil ? ["string"] :
                (message.content.arrayValue ?? []).map { $0["type"]?.stringValue ?? "?" }
            return message.role + ":" + blocks.joined(separator: "+")
        }
        Diagnostics.record("coordinator.diverged", ["at": String(index), "told": String(told.count), "now": String(now.count),
                                                    "was": kinds(told), "is": kinds(now)])
    }

    /// Before results are replayed: a stopped run, or one whose account changed, is ended normally;
    /// a healthy run whose calls these were, for a conversation rewritten since, goes on waiting for its own client's results parkLongest more.
    /// The conversation's own stopped run is ended too.
    private func settleForReplay(_ ids: Set<String>, why: String, alias: String, concurrent: Bool) async {
        for owner in Set(ids.compactMap { toolOwners[$0] }) {
            guard let binding = bindings[owner], !binding.busy else { continue }
            switch why {
            case "run_stopped": _ = await releaseStopped(owner)
            case "account_changed":
                bindings[owner]?.stopped = true; bindings[owner]?.session.state = .attention; publish(owner)
                _ = await releaseStopped(owner)
            case "history_changed" where !alias.hasPrefix("request:") &&
                    binding.session.conversation != nil && binding.session.conversation == Self.conversationTag(alias):
                // Pool's own: the conversation's own run, for a history its client has moved on from. A new
                // run carries the conversation now, so this one is ended normally rather than held
                // parkLongest more as a process that holds memory.
                release(owner)
                Task { [weak self] in _ = await self?.evictParked(owner, why: "replaced") }
            case "model_changed", "context_changed", "history_changed": release(owner)
            default: break
            }
        }
        if !concurrent, !alias.hasPrefix("request:"), let existing = aliases[alias], bindings[existing]?.stopped == true,
           bindings[existing]?.busy == false {
            _ = await releaseStopped(existing)
        }
    }
    /// The run goes on waiting on its calls, parkLongest more.
    private func release(_ id: UUID) {
        guard bindings[id]?.parkedAt != nil else { return }
        bindings[id]?.parkEnds = now().addingTimeInterval(parkLongest)
        bindings[id]?.released = true
    }

    /// The request the run that had the conversation's last turn is told the next one with:
    /// the conversation up to its last plain reply is the run's, compared by its
    /// words (or with that turn rewritten as a client does), and what came since is the user's. Several
    /// user messages since are told as one; a client's own tool calls since need a run told it whole.
    private func nextTurn(of binding: Binding, request: BridgeRequest, alias: String) -> BridgeRequest? {
        guard let turn = ConversationWords.nextTurn(request.messages), !turn.since.isEmpty else { return nil }
        let exact = ConversationWords.key(turn.before) == ConversationWords.key(binding.history)
        guard exact || ConversationWords.rewrote(turn.before, was: binding.history) else { return nil }
        if !exact { Diagnostics.record("coordinator.route", ["decision": "turn_rewritten_continued", "conversation": Diagnostics.tag(alias)]) }
        return turnRequest(request, turn: turn, alias: alias)
    }

    /// The request a run that has the conversation up to its last reply is told the next turn with:
    /// the request itself for one message since; several user messages as one; nil for a client's
    /// own tool calls since, which need a run told the conversation whole.
    private func turnRequest(_ request: BridgeRequest, turn: (before: [BridgeMessage], since: [BridgeMessage]), alias: String) -> BridgeRequest? {
        if turn.since.count == 1 { return request }
        guard turn.since.allSatisfy({ $0.role == "user" && !ConversationWords.carriesTools($0) }) else { return nil }
        var blocks: [JSONValue] = []
        for message in turn.since {
            if let text = message.content.stringValue { blocks.append(.object(["type": .string("text"), "text": .string(text)])) }
            else { blocks += message.content.arrayValue ?? [] }
        }
        Diagnostics.record("coordinator.route", ["decision": "turn_messages_joined", "conversation": Diagnostics.tag(alias),
                                                 "messages": String(turn.since.count)])
        var joined = request
        joined.messages = turn.before + [BridgeMessage(role: "user", content: .array(blocks))]
        return joined
    }

    /// The model, instructions and tools, and
    /// what a turn may call, whether it searches and its answer's schema, which a run is started with.
    private func compatible(_ binding: Binding, request: BridgeRequest, allowingToolChanges: Bool = false) -> Bool {
        binding.request.model == request.model && binding.request.system == request.system &&
            (allowingToolChanges || binding.request.tools == request.tools) &&
            binding.request.webSearch == request.webSearch && binding.request.answerSchema == request.answerSchema &&
            (allowingToolChanges || binding.request.toolChoice == request.toolChoice)
    }
    private func eligible(_ binding: Binding, model: PoolModel) -> Bool {
        sameIdentity(binding) && PoolRouting.candidates(accounts, model: model.cliAlias, excluding: restingAccounts(), policy: routingPolicy)
            .contains { $0.id == binding.session.accountID }
    }
    /// Conversations each account serves now, from the runs that have not been stopped.
    private func conversationLoad() -> [UUID: Int] {
        PoolRouting.conversationLoad(bindings.values.filter { !$0.stopped }.map(\.session))
    }
    private func restingAccounts() -> Set<UUID> {
        let date = now()
        resting = resting.filter { $0.value > date }
        return Set(resting.keys)
    }
    private func sameIdentity(_ binding: Binding) -> Bool {
        guard let current = accounts.first(where: { $0.id == binding.session.accountID }) else { return false }
        return current.email == binding.accountAtStart.email && current.plan == binding.accountAtStart.plan &&
            current.identityFingerprint == binding.accountAtStart.identityFingerprint
    }
    private func shouldHandoff(_ binding: Binding, model: PoolModel) -> Bool {
        PoolRouting.handoff(accounts, model: model.cliAlias, currentID: binding.session.accountID, policy: routingPolicy)?.reason == .lowQuota
    }
    private func unavailableReason(_ binding: Binding, model: PoolModel) -> RoutingReason {
        guard let account = accounts.first(where: { $0.id == binding.session.accountID }) else { return .accountUnavailable }
        return PoolRouting.assessment(account, model: model.cliAlias).state == .exhausted ? .quotaExhausted : .accountUnavailable
    }

    /// A new run that finds the room full ends a stopped run, then lets go of the run idle longest, else of one that has waited
    /// parkLongest on tool calls, and otherwise waits for one to end, `roomWait` at most, looking again as
    /// runs come to wait parkLongest. Busy runs and runs waiting on calls made recently are kept.
    /// Two things are Pool's own. A released run gives its room up at once rather than after parkLongest:
    /// it stays for results that may never come, and if they do they are replayed in a new
    /// run, so only a run that holds up others is let go.
    private func takeRoom(model: PoolModel, generation: UInt64, blocked: () -> Bool) async throws {
        let began = Date(), deadline = began.addingTimeInterval(roomWait)
        var waiting = false
        func room() -> Int { maximumWorkers }
        while bindings.count + creating >= room() {
            for id in bindings.filter({ $0.value.stopped }).map(\.key) { _ = await releaseStopped(id) }
            if bindings.count + creating < room() { break }
            if let (id, _) = bindings.filter({ isRetirable($0.value) }).min(by: { $0.value.lastActive < $1.value.lastActive }),
               await shelveOrRetire(id) { continue }
            let date = now()
            if let (id, _) = bindings.filter({ !$0.value.busy && !$0.value.retiring && $0.value.parkedAt != nil &&
                    ($0.value.released || ($0.value.parkedAt.map { date.timeIntervalSince($0) >= parkLongest } ?? false)) })
                .min(by: { $0.value.parkedAt! < $1.value.parkedAt! }), await evictParked(id, why: "room") { continue }
            guard Date() < deadline else {
                Diagnostics.record("coordinator.room", ["decision": "no_room", "live": String(bindings.count), "most": String(room()),
                                                        "ms": String(Int(Date().timeIntervalSince(began) * 1000))])
                route(model: model.id, reason: .capacityReached); throw BridgeFailure.busy
            }
            if !waiting {
                waiting = true
                Diagnostics.record("coordinator.room", ["decision": "waiting", "live": String(bindings.count), "most": String(room())])
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled, !cancelledGenerations.contains(generation) else { throw BridgeFailure.cancelled }
            guard !blocked() else { throw BridgeFailure.paused }
        }
        if waiting {
            Diagnostics.record("coordinator.room", ["decision": "had_room", "ms": String(Int(Date().timeIntervalSince(began) * 1000))])
        }
    }

    /// A conversation's run that cannot take its next turn ends, and the turn starts a new run told
    /// the whole conversation. Unless the account is low, the new run stays on the same account, so
    /// the conversation keeps its prompt cache. A run that does not leave its idle prompt normally
    /// gets the client's own Ctrl-C; one that still does not end is kept for the user and reported,
    /// and the turn goes on without it rather than being refused.
    private func replaceRun(_ id: UUID, alias: String, request: BridgeRequest, model: PoolModel, generation: UInt64,
                            lowQuota: Bool) async throws -> UUID {
        guard let binding = bindings[id] else { return try await create(request: request, model: model, generation: generation) }
        let account = binding.session.accountID
        var ended = await binding.worker.close()
        if !ended { ended = await binding.worker.requestExit() }
        if ended { remove(id) }
        else {
            bindings[id]?.stopped = true; bindings[id]?.session.state = .attention
            if aliases[alias] == id { aliases.removeValue(forKey: alias) }
            publish(id)
        }
        Diagnostics.record("coordinator.route", ["decision": "run_replaced", "ended": ended ? "yes" : "no",
            "same_account": lowQuota ? "no" : "tried", "conversation": Diagnostics.tag(alias)])
        if lowQuota {
            return try await create(request: request, model: model, generation: generation,
                                    excluding: [account], minimumHeadroom: routingPolicy.reservePercent)
        }
        do { return try await create(request: request, model: model, generation: generation, only: account) }
        catch BridgeFailure.unavailable { return try await create(request: request, model: model, generation: generation) }
    }

    /// `continuing`: the run is for tool results already delivered, which pause still lets finish.
    private func create(request: BridgeRequest, model: PoolModel, generation: UInt64, excluding: Set<UUID> = [], minimumHeadroom: Double? = nil,
                        reasonOverride: RoutingReason? = nil, continuing: Bool = false, only: UUID? = nil) async throws -> UUID {
        func blocked() -> Bool { paused && !continuing }
        guard !Task.isCancelled, !cancelledGenerations.contains(generation) else { throw BridgeFailure.cancelled }
        guard !blocked() else { throw BridgeFailure.paused }
        await endExpiredParks()
        try await takeRoom(model: model, generation: generation, blocked: blocked)
        creating += 1
        defer { creating -= 1 }
        var excluded = excluding
        var selection: (PoolAccount, any SessionWorker)?
        var rejectedAccount = false
        let conversation = active[generation].flatMap { Self.conversationTag($0.alias) }
        let lead = conversation.flatMap { leadAccount(of: $0) } ?? (Self.isOneOff(request) ? nil : openingAccount(of: request))
        while selection == nil {
            guard !Task.isCancelled, !cancelledGenerations.contains(generation) else { throw BridgeFailure.cancelled }
            guard !blocked() else { throw BridgeFailure.paused }
            var candidates = PoolRouting.candidates(accounts, model: model.cliAlias, excluding: excluded.union(restingAccounts()), now: now(),
                                                    policy: routingPolicy, load: conversationLoad())
                .filter { only == nil || $0.id == only }
            // A side request of a conversation (a title, a summary) goes to the account the conversation is on
            // while that account would take a new conversation, so one conversation uses one account.
            if let lead, let i = candidates.firstIndex(where: { $0.id == lead }), i > 0,
               PoolRouting.assessment(candidates[i], model: model.cliAlias).headroom.map({ $0 > routingPolicy.reservePercent }) ?? true {
                candidates.insert(candidates.remove(at: i), at: 0)
            }
            guard let account = candidates.first(where: { candidate in
                guard let minimumHeadroom else { return true }
                return PoolRouting.assessment(candidate, model: model.cliAlias).headroom.map { $0 > minimumHeadroom } ?? false
            }) else { route(model: model.id, reason: .noAvailableAccount); throw BridgeFailure.unavailable }
            // Why this account: what the conversation asked for and how the others scored.
            let load = conversationLoad(), date = now()
            let scored = candidates.prefix(5).map { candidate in
                Diagnostics.id(candidate.id) + ":" + (PoolRouting.score(candidate, model: model.cliAlias, now: date, load: load[candidate.id] ?? 0)
                    .map { String(Int($0.rounded())) } ?? "?") + "/" + String(load[candidate.id] ?? 0)
            }
            Diagnostics.record("coordinator.pick", ["account": Diagnostics.id(account.id), "conversation": conversation ?? "-",
                "kept": lead.map { $0 == account.id ? "yes" : "no:" + Diagnostics.id($0) } ?? "none", "only": only.map(Diagnostics.id) ?? "-",
                "excluded": String(excluded.count), "candidates": scored.joined(separator: ",")])
            do { selection = (account, try await factory(account, model)) }
            catch BridgeFailure.accountUnavailable(let state) {
                markUnavailable(AccountScope(account), state: state)
                onUpdate(.route(RouteDecision(accountID: account.id, model: model.id, reason: .accountUnavailable, strategy: routingPolicy.strategy)))
                excluded.insert(account.id); rejectedAccount = true
            }
            catch BridgeFailure.modelUnavailable {
                onUpdate(.route(RouteDecision(accountID: account.id, model: model.id, reason: .modelUnavailable, strategy: routingPolicy.strategy)))
                excluded.insert(account.id); rejectedAccount = true
            }
        }
        let (account, worker) = selection!
        let verifiedAccount = worker.accountSnapshot ?? account
        let session = PoolSession(id: worker.id, accountID: account.id, name: "Claude session", model: model.name, state: .starting, startedAt: now(),
                                  conversation: conversation, isOneOff: Self.isOneOff(request))
        bindings[worker.id] = Binding(worker: worker, session: session, request: request, accountAtStart: verifiedAccount, history: [], lastActive: now())
        // the conversation is on this account from now on, a handoff's new account included
        rememberAccount(bindings[worker.id]!)
        let observations = await worker.observations()
        observationTasks[worker.id] = Task { [weak self] in
            for await event in observations { await self?.observe(event, sessionID: worker.id) }
        }
        if let created = bindings[worker.id] { logState(worker.id, created) }
        onUpdate(.session(session))
        startRetirementTimer()
        guard !blocked(), !Task.isCancelled, !cancelledGenerations.contains(generation), let binding = bindings[worker.id], eligible(binding, model: model) else {
            if await worker.close() { remove(worker.id) }
            else { bindings[worker.id]?.session.state = .attention; publish(worker.id) }
            if Task.isCancelled || cancelledGenerations.contains(generation) { throw BridgeFailure.cancelled }
            throw blocked() ? BridgeFailure.paused : BridgeFailure.unavailable
        }
        let reason: RoutingReason = reasonOverride ?? (rejectedAccount ? .failover : routingPolicy.strategy == .ordered ? .accountOrder :
            (PoolRouting.assessment(verifiedAccount, model: model.cliAlias).headroom == nil ? .unknownQuota : .headroom))
        route(id: worker.id, model: model.id, reason: reason)
        return worker.id
    }

    private func serve(_ initialID: UUID, request: BridgeRequest, workerRequest: BridgeRequest, replay: Bool, model: PoolModel, alias: String,
                       generation: UInt64, continuation: AsyncThrowingStream<BridgeEvent, Error>.Continuation) async {
        defer { endGeneration(generation) }
        let resultIDs: Set<String>
        do { resultIDs = Set(try RequestContent.toolResults(request).map(\.0)) }
        catch { continuation.finish(throwing: error); return }
        var id = initialID
        var attempted: Set<UUID> = []
        var committed = false
        var resultsConsumed = resultIDs.isEmpty || replay
        var replayCompletedResults = replay
        var content: [JSONValue] = []
        var text = ""
        func cancelled() -> Bool { Task.isCancelled || cancelledGenerations.contains(generation) }
        while let binding = bindings[id], !cancelled(), !binding.stopped {
            // the run now answers this conversation.
            bindings[id]?.told = request.messages
            attempted.insert(binding.session.accountID)
            resetProgress(id)
            var reportedUsage = false
            do {
                let source: AsyncThrowingStream<BridgeEvent, Error>
                if replayCompletedResults {
                    source = try await binding.worker.events(replaying: VerifiedToolReplay(request: request))
                } else if !resultIDs.isEmpty {
                    let accepted: AsyncThrowingStream<BridgeEvent, Error>?
                    do { accepted = try await binding.worker.events(for: workerRequest) }
                    catch BridgeFailure.transport { accepted = nil }
                    catch BridgeFailure.invalidRequest { accepted = nil }
                    guard let accepted else {
                        // The run could not be told the results, as it ended while it waited: a new one is
                        // told the whole conversation.
                        guard !cancelled() else { throw BridgeFailure.cancelled }
                        bindings[id]?.busy = false; bindings[id]?.serving = nil; bindings[id]?.stopped = true
                        Diagnostics.record("coordinator.route", ["decision": "tool_result_replayed:run_expired",
                            "conversation": Diagnostics.tag(alias), "results": String(resultIDs.count)])
                        _ = await releaseStopped(id)
                        id = try await create(request: request, model: model, generation: generation, continuing: true)
                        adopt(id, alias: alias, generation: generation)
                        replayCompletedResults = true; resultsConsumed = true
                        continue
                    }
                    guard let current = bindings[id], !current.stopped, !cancelled(),
                          sameIdentity(current), resultIDs.isSubset(of: current.pending),
                          resultIDs.allSatisfy({ toolOwners[$0] == id }) else { throw BridgeFailure.cancelled }
                    // Returning a stream acknowledges that this worker validated and accepted the
                    // exact completed results. Only then is their ownership consumed here.
                    for callID in resultIDs {
                        bindings[id]?.pending.remove(callID); toolOwners.removeValue(forKey: callID)
                    }
                    resultsConsumed = bindings[id]?.pending.isEmpty == true
                    source = accepted
                } else {
                    source = try await binding.worker.events(for: workerRequest)
                }
                var completed = false
                for try await event in source {
                    try Task.checkCancellation()
                    guard !cancelled(), bindings[id]?.stopped == false else { throw BridgeFailure.cancelled }
                    switch event {
                    case .text(let delta):
                        committed = true; text += delta
                        setWorkState(id, state: .generating)
                        bindings[id]?.progressCharacters += delta.count
                        publishProgress(id)
                    case .toolUse(let call):
                        setWorkState(id, state: .waitingTool)
                        if !text.isEmpty { content.append(.object(["type": .string("text"), "text": .string(text)])); text = "" }
                        committed = true
                        guard toolOwners[call.id] == nil else { throw BridgeFailure.compatibility }
                        toolOwners[call.id] = id
                        bindings[id]?.pending.insert(call.id)
                        content.append(.object(["type": .string("tool_use"), "id": .string(call.id), "name": .string(call.name), "input": call.input]))
                    case .finished(let reason):
                        setWorkState(id, state: reason == .toolUse ? .waitingTool : .idle)
                        guard reason == .toolUse || bindings[id]?.pending.isEmpty == true else { throw BridgeFailure.compatibility }
                        completed = true
                        if !text.isEmpty { content.append(.object(["type": .string("text"), "text": .string(text)])); text = "" }
                        bindings[id]?.history = request.messages + [BridgeMessage(role: "assistant", content: .array(content))]
                        bindings[id]?.busy = false; bindings[id]?.serving = nil
                        bindings[id]?.lastActive = now()
                        if let finished = bindings[id] { rememberAccount(finished) }
                        bindings[id]?.session.state = reason == .toolUse ? .waiting : .idle
                        if reason == .toolUse {
                            let date = now()
                            bindings[id]?.parkedAt = date; bindings[id]?.parkEnds = date.addingTimeInterval(runTimeout)
                        }
                        publish(id)
                    case .usage(let usage):
                        if !reportedUsage, sameIdentity(binding) {
                            reportedUsage = true
                            publishProgress(id, usage: usage, force: true)
                            // One ledger row per reply, one record per call.
                            // Generating time of this request, as the quota progress counts it; tool waits are not in it.
                            let date = now(), current = bindings[id] ?? binding
                            let seconds = current.generationDuration + (current.generationBeganAt.map { max(0, date.timeIntervalSince($0)) } ?? 0)
                            onUpdate(.usage(scope: AccountScope(binding.accountAtStart), model: model.listedID, name: model.listedName, usage: usage, at: date,
                                            generationSeconds: seconds > 0 ? seconds : nil))
                            // Which run on which account read the prompt cache or wrote it again: tags and counts only.
                            Diagnostics.record("coordinator.usage", [
                                "conversation": Diagnostics.tag(alias), "run": Diagnostics.id(id),
                                "account": Diagnostics.id(binding.accountAtStart.id), "replay": replay ? "yes" : "no",
                                "cache_r": String(max(0, usage.cacheReadInputTokens ?? 0)),
                                "cache_w": String(max(0, usage.cacheCreationInputTokens ?? 0))])
                        }
                    }
                    continuation.yield(event)
                    if completed { break }
                }
                guard completed else { throw BridgeFailure.transport }
                continuation.finish()
                if alias.hasPrefix("request:") { aliases.removeValue(forKey: alias) }
                // A one-off ask has no next turn: kept, its run would sit idle for an hour, counted and
                // holding room. It ends with the client's normal exit once it has answered.
                if bindings[id]?.session.state == .idle, Self.isOneOff(request), let worker = bindings[id]?.worker {
                    bindings[id]?.retiring = true
                    if await worker.close() {
                        Diagnostics.record("coordinator.route", ["decision": "one_off_ended", "conversation": Diagnostics.tag(alias)])
                        if bindings[id] != nil { bindings[id]?.session.state = .ended; publish(id); remove(id) }
                    } else { bindings[id]?.retiring = false }
                }
                await enforceParkCap()
                await enforceIdleCap()
                return
            } catch {
                setWorkState(id, state: .waitingUser)
                if Task.isCancelled { await binding.worker.cancel() }
                var provenAccountFailure = false
                switch error {
                case BridgeFailure.quotaLimited(let windows):
                    let evidence = windows.filter { $0.applies(to: model.cliAlias) && $0.isExhausted(at: now()) }
                    let accepted = sameIdentity(binding) ? applyLimits(evidence, accountID: binding.session.accountID) : []
                    route(id: id, model: model.id, reason: .accountLimited)
                    provenAccountFailure = !accepted.isEmpty
                case BridgeFailure.modelUnavailable:
                    route(id: id, model: model.id, reason: .modelUnavailable)
                    provenAccountFailure = true
                case BridgeFailure.accountUnavailable(let state):
                    markUnavailable(AccountScope(binding.accountAtStart), state: state)
                    route(id: id, model: model.id, reason: .accountUnavailable)
                    provenAccountFailure = true
                case BridgeFailure.rateLimited(let recovery):
                    route(id: id, model: model.id, reason: .accountLimited)
                    if sameIdentity(binding) { limit(binding.session.accountID, until: recovery) }
                    // A generic 429 without a confirmed recovery is not quota evidence.
                    provenAccountFailure = recovery.map { $0 > now() } ?? false
                default: break
                }
                if provenAccountFailure, canHandoff(id, generation: generation, committed: committed, resultsConsumed: resultsConsumed) {
                    do {
                        if await binding.worker.close() {
                            let stillSafe = canHandoff(id, generation: generation, committed: committed, resultsConsumed: resultsConsumed)
                            bindings[id]?.session.state = .ended; publish(id); remove(id)
                            if stillSafe {
                                id = try await create(request: request, model: model, generation: generation, excluding: attempted,
                                                      reasonOverride: .failover, continuing: !resultIDs.isEmpty)
                                adopt(id, alias: alias, generation: generation)
                                replayCompletedResults = !resultIDs.isEmpty
                                continue
                            }
                        }
                    } catch { continuation.finish(throwing: error); return }
                }
                let wasCancelled = cancelled() || bindings[id]?.stopped == true
                if bindings[id]?.serving == generation || bindings[id]?.busy == true {
                    bindings[id]?.busy = false; bindings[id]?.serving = nil; bindings[id]?.stopped = true; bindings[id]?.session.state = .attention
                    publish(id)
                }
                continuation.finish(throwing: wasCancelled ? BridgeFailure.cancelled : error)
                return
            }
        }
        setWorkState(id, state: .waitingUser)
        if bindings[id]?.serving == generation { bindings[id]?.busy = false; bindings[id]?.serving = nil; publish(id) }
        continuation.finish(throwing: BridgeFailure.cancelled)
    }

    /// A run started within a request's reply (a replay or a handoff) takes that request on.
    private func adopt(_ id: UUID, alias: String, generation: UInt64) {
        aliases[alias] = id; active[generation]?.binding = id
        bindings[id]?.busy = true; bindings[id]?.serving = generation; bindings[id]?.session.state = .running
        publish(id)
    }

    private func canHandoff(_ id: UUID, generation: UInt64, committed: Bool, resultsConsumed: Bool) -> Bool {
        guard !Task.isCancelled, !cancelledGenerations.contains(generation), !committed, resultsConsumed, !paused,
              let binding = bindings[id], binding.busy, !binding.retiring, !binding.stopped,
              binding.pending.isEmpty, sameIdentity(binding) else { return false }
        return true
    }

    private func limit(_ accountID: UUID, until reset: Date?) {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        if let reset {
            accounts[index].cooldownUntil = reset
            onUpdate(.accountState(scope: AccountScope(accounts[index]), state: accounts[index].state, cooldownUntil: reset))
        } else {
            // A refusal without a confirmed limit is neither quota nor a reset. The account rests
            // briefly, and its usage read decides whether it is limited.
            resting[accountID] = now().addingTimeInterval(Self.unconfirmedRest)
            onUpdate(.limitUnconfirmed(scope: AccountScope(accounts[index])))
        }
    }
    private func markUnavailable(_ scope: AccountScope, state: AccountState) {
        guard let index = accounts.firstIndex(where: scope.matches) else { return }
        accounts[index].state = state
        onUpdate(.accountState(scope: scope, state: state, cooldownUntil: accounts[index].cooldownUntil))
    }
    private func applyLimits(_ windows: [QuotaWindow], accountID: UUID) -> [QuotaWindow] {
        guard let index = accounts.firstIndex(where: { $0.id == accountID }) else { return [] }
        let accepted = mergeWindows(windows, accountIndex: index)
        if !accepted.isEmpty { onUpdate(.quota(scope: AccountScope(accounts[index]), windows: accepted)) }
        if let reset = accepted.filter({ $0.modelFamily == nil }).compactMap(\.resetsAt).filter({ $0 > now() }).max() {
            accounts[index].cooldownUntil = max(reset, accounts[index].cooldownUntil ?? reset)
            onUpdate(.accountState(scope: AccountScope(accounts[index]), state: accounts[index].state, cooldownUntil: accounts[index].cooldownUntil))
        }
        return accepted
    }
    private func mergeWindows(_ windows: [QuotaWindow], accountIndex: Int) -> [QuotaWindow] {
        var accepted: [QuotaWindow] = []
        for window in windows {
            if let current = accounts[accountIndex].windows.first(where: { $0.id == window.id }), current.observedAt > window.observedAt { continue }
            accounts[accountIndex].windows.removeAll { $0.id == window.id }
            accounts[accountIndex].windows.append(window); accepted.append(window)
        }
        return accepted
    }

    private func observe(_ event: WorkerObservation, sessionID: UUID) {
        guard let binding = bindings[sessionID] else { return }
        switch event {
        case .terminal(let data): onUpdate(.terminal(sessionID: sessionID, data: data))
        case .model(let identity): onUpdate(.model(identity))
        case .accountState(let state): markUnavailable(AccountScope(binding.accountAtStart), state: state)
        case .working:
            if binding.busy, !binding.stopped, sameIdentity(binding) { setWorkState(sessionID, state: .generating) }
            if binding.busy && binding.session.state != .running { bindings[sessionID]?.session.state = .running; publish(sessionID) }
        case .quota(let windows):
            guard sameIdentity(binding) else { return }
            if let index = accounts.firstIndex(where: { $0.id == binding.session.accountID }) {
                let accepted = mergeWindows(windows, accountIndex: index)
                if !accepted.isEmpty { onUpdate(.quota(scope: AccountScope(binding.accountAtStart), windows: accepted)) }
            }
        case .attention:
            setWorkState(sessionID, state: .waitingUser)
            bindings[sessionID]?.session.state = .attention; publish(sessionID)
        case .idle:
            setWorkState(sessionID, state: .idle)
            if !binding.busy && !binding.stopped && binding.pending.isEmpty { bindings[sessionID]?.session.state = .idle; publish(sessionID) }
        case .ended:
            setWorkState(sessionID, state: .ended)
            bindings[sessionID]?.session.state = .ended; publish(sessionID)
            if !binding.busy { remove(sessionID) }
        }
    }
    private func resetProgress(_ id: UUID) {
        let generationBeganAt = bindings[id]?.workState == .generating ? now() : nil
        bindings[id]?.progressRequestID = UUID()
        bindings[id]?.progressSequence = 0
        bindings[id]?.progressCharacters = 0; bindings[id]?.progressSentCharacters = 0
        bindings[id]?.progressReportedAt = nil; bindings[id]?.generationDuration = 0
        bindings[id]?.generationBeganAt = generationBeganAt
    }
    private func publishProgress(_ id: UUID, usage: BridgeUsage? = nil, force: Bool = false) {
        guard let binding = bindings[id], sameIdentity(binding), !binding.stopped,
              binding.progressCharacters > binding.progressSentCharacters || usage != nil else { return }
        let date = now()
        if !force, let last = binding.progressReportedAt, date.timeIntervalSince(last) < 2 { return }
        let active = binding.generationDuration + (binding.generationBeganAt.map { max(0, date.timeIntervalSince($0)) } ?? 0)
        let progress = QuotaProgress(requestID: binding.progressRequestID, sequence: binding.progressSequence,
            outputCharacters: binding.progressCharacters, usage: usage, activeDuration: active, observedAt: date)
        bindings[id]?.progressSequence += 1; bindings[id]?.progressSentCharacters = binding.progressCharacters
        bindings[id]?.progressReportedAt = date
        onUpdate(.progress(scope: AccountScope(binding.accountAtStart), sessionID: id, progress: progress))
    }
    private func setWorkState(_ id: UUID, state: QuotaWorkState) {
        guard let binding = bindings[id], binding.workState != state else { return }
        if binding.workState == .generating { publishProgress(id, force: true) }
        let date = now()
        if let began = binding.generationBeganAt {
            bindings[id]?.generationDuration += max(0, date.timeIntervalSince(began))
        }
        bindings[id]?.generationBeganAt = state == .generating ? date : nil
        bindings[id]?.workState = state
        onUpdate(.workState(scope: AccountScope(binding.accountAtStart), sessionID: id, state: state, at: date))
    }
    private func publish(_ id: UUID) {
        guard let binding = bindings[id] else { return }
        logState(id, binding)
        onUpdate(.session(binding.session))
    }
    /// Every change of a run's state, where it is published: what it was, what it is, and the
    /// flags that decide whether it can take its conversation's next turn.
    private func logState(_ id: UUID, _ binding: Binding) {
        let state = binding.session.state
        guard loggedStates[id] != state else { return }
        Diagnostics.record("coordinator.state", ["run": Diagnostics.id(id), "account": Diagnostics.id(binding.session.accountID),
            "from": loggedStates[id]?.rawValue ?? "new", "to": state.rawValue, "busy": binding.busy ? "yes" : "no",
            "pending": String(binding.pending.count), "stopped": binding.stopped ? "yes" : "no", "retiring": binding.retiring ? "yes" : "no"])
        loggedStates[id] = state
    }
    private func route(id: UUID? = nil, model: String, reason: RoutingReason) {
        let account = id.flatMap { bindings[$0]?.session.accountID }
        Diagnostics.record("coordinator.decision", ["reason": reason.rawValue, "run": id.map(Diagnostics.id) ?? "-",
                                                    "account": account.map(Diagnostics.id) ?? "-", "model": model])
        onUpdate(.route(RouteDecision(sessionID: id, accountID: account, model: model, reason: reason, strategy: routingPolicy.strategy)))
    }
    /// Every five minutes while runs exist: how many in each state, the longest busy and parked.
    private func logHealth() {
        healthTicks += 1
        guard healthTicks % 5 == 0, !bindings.isEmpty else { return }
        let date = now(), runs = Array(bindings.values)
        func count(_ state: SessionState) -> String { String(runs.filter { $0.session.state == state }.count) }
        let busiest = runs.filter(\.busy).map { date.timeIntervalSince($0.lastActive) }.max()
        let parked = runs.compactMap(\.parkedAt).map { date.timeIntervalSince($0) }.max()
        Diagnostics.record("coordinator.health", ["runs": String(runs.count), "running": count(.running), "waiting": count(.waiting),
            "idle": count(.idle), "attention": count(.attention), "stopped": String(runs.filter(\.stopped).count),
            "busy_longest_s": busiest.map { String(Int($0)) } ?? "-", "parked_longest_s": parked.map { String(Int($0)) } ?? "-",
            "accounts": String(Set(runs.map(\.session.accountID)).count)])
    }
    private func remove(_ id: UUID) {
        if let binding = bindings[id] {
            Diagnostics.record("coordinator.state", ["run": Diagnostics.id(id), "account": Diagnostics.id(binding.session.accountID),
                "from": loggedStates[id]?.rawValue ?? "new", "to": "removed", "busy": binding.busy ? "yes" : "no",
                "pending": String(binding.pending.count), "stopped": binding.stopped ? "yes" : "no", "retiring": binding.retiring ? "yes" : "no"])
        }
        loggedStates.removeValue(forKey: id)
        setWorkState(id, state: .ended)
        observationTasks.removeValue(forKey: id)?.cancel()
        bindings.removeValue(forKey: id)
        aliases = aliases.filter { $0.value != id }; toolOwners = toolOwners.filter { $0.value != id }
        if bindings.isEmpty { retirementTask?.cancel(); retirementTask = nil }
    }

    private func shelfKey(_ conversation: [BridgeMessage], model: String) -> String {
        model + "\u{0}" + ConversationWords.key(conversation)
    }
    /// The shelved session a new turn goes on from: its conversation up to the last
    /// reply is one a run was let go at, with the same model, instructions and tools, on an account that
    /// can still serve it and needs no handoff; and the request that tells only the turn since.
    private func takeShelved(_ request: BridgeRequest, model: PoolModel) -> (Shelved, BridgeRequest)? {
        guard !shelf.isEmpty, let turn = ConversationWords.nextTurn(request.messages), !turn.since.isEmpty,
              let entry = shelf.removeValue(forKey: shelfKey(turn.before, model: request.model)) else { return nil }
        let account = entry.saved.accountID
        guard entry.until > now(), entry.system == request.system, entry.tools == request.tools, entry.plain(request),
              PoolRouting.candidates(accounts, model: model.cliAlias, excluding: restingAccounts(), policy: routingPolicy).contains(where: { $0.id == account }),
              PoolRouting.handoff(accounts, model: model.cliAlias, currentID: account, policy: routingPolicy)?.reason != .lowQuota,
              let told = turnRequest(request, turn: turn, alias: "shelf") else { entry.saved.discard(); return nil }
        return (entry, told)
    }
    /// Lets an idle run go for room or past idleMost with its session shelved for its conversation's
    /// next turn, else ends it as `retire` does.
    private func shelveOrRetire(_ id: UUID) async -> Bool {
        guard let binding = bindings[id], isRetirable(binding), !binding.history.isEmpty, sameIdentity(binding),
              binding.request.toolChoice == nil, !binding.request.webSearch, binding.request.answerSchema == nil else { return await retire(id) }
        bindings[id]?.retiring = true
        guard let saved = await binding.worker.shelve() else { bindings[id]?.retiring = false; return await retire(id) }
        let key = shelfKey(binding.history, model: binding.request.model)
        shelf.removeValue(forKey: key)?.saved.discard()
        shelf[key] = Shelved(saved: saved, model: binding.request.model, system: binding.request.system, tools: binding.request.tools,
                             until: binding.lastActive.addingTimeInterval(idleTimeout))
        while shelf.count > Self.shelfMost, let oldest = shelf.min(by: { $0.value.until < $1.value.until }) {
            shelf.removeValue(forKey: oldest.key)?.saved.discard()
        }
        Diagnostics.record("coordinator.route", ["decision": "shelved", "messages": String(binding.history.count)])
        if bindings[id] != nil { bindings[id]?.session.state = .ended; publish(id); remove(id) }
        return true
    }
    private func discardShelf(where match: (Shelved) -> Bool) {
        for (key, entry) in shelf where match(entry) { shelf.removeValue(forKey: key); entry.saved.discard() }
    }

    private func isRetirable(_ binding: Binding) -> Bool {
        !binding.busy && !binding.retiring && !binding.stopped && binding.pending.isEmpty && binding.session.state == .idle
    }
    /// Ends a stopped run with the client's normal exit, so it neither blocks its conversation nor holds capacity.
    private func releaseStopped(_ id: UUID) async -> Bool {
        guard let binding = bindings[id] else { return true }
        guard binding.stopped, !binding.busy, !binding.retiring else { return false }
        bindings[id]?.retiring = true
        var ended = await binding.worker.close()
        if !ended { ended = await binding.worker.requestExit() }
        guard ended else { bindings[id]?.retiring = false; bindings[id]?.session.state = .attention; publish(id); return false }
        if bindings[id] != nil { bindings[id]?.session.state = .ended; publish(id); remove(id) }
        return true
    }
    /// Lets a run waiting on tool calls go (parked, with its timer): it is ended with the client's
    /// own exit, and a result that comes after goes on in a new run told the whole conversation.
    private func evictParked(_ id: UUID, why: String) async -> Bool {
        guard let binding = bindings[id], binding.parkedAt != nil, !binding.busy, !binding.retiring else { return false }
        Diagnostics.record("coordinator.route", ["decision": "parked_evicted", "why": why, "calls": String(binding.pending.count)])
        setWorkState(id, state: .waitingUser)
        bindings[id]?.stopped = true; bindings[id]?.session.state = .attention; publish(id)
        return await releaseStopped(id)
    }
    /// Runs past their timer: `runTimeout` waiting on calls, or `parkLongest` after they were released.
    private func endExpiredParks() async {
        let date = now()
        for id in bindings.filter({ !$0.value.busy && ($0.value.parkEnds.map { $0 <= date } ?? false) }).map(\.key) {
            _ = await evictParked(id, why: "timeout")
        }
    }
    /// Of the runs that have waited parkLongest on their calls, parkedMost are kept, the
    /// longest waiting let go first.
    private func enforceParkCap() async {
        let date = now()
        let parked = bindings.filter { !$0.value.busy && ($0.value.parkedAt.map { date.timeIntervalSince($0) >= parkLongest } ?? false) }
            .sorted { $0.value.parkedAt! < $1.value.parkedAt! }
        guard parked.count > parkedMost else { return }
        for (id, _) in parked.prefix(parked.count - parkedMost) { _ = await evictParked(id, why: "cap") }
    }
    /// Of the runs waiting for their
    /// conversation's next turn, six are kept, the one waiting longest let go first.
    private func enforceIdleCap() async {
        let idle = bindings.filter { isRetirable($0.value) }.sorted { $0.value.lastActive < $1.value.lastActive }
        guard idle.count > idleMost else { return }
        for (id, _) in idle.prefix(idle.count - idleMost) { _ = await shelveOrRetire(id) }
    }
    private func retire(_ id: UUID) async -> Bool {
        guard let binding = bindings[id], isRetirable(binding) else { return false }
        bindings[id]?.retiring = true
        if await binding.worker.close() {
            bindings[id]?.session.state = .ended; publish(id); remove(id); return true
        }
        bindings[id]?.retiring = false; bindings[id]?.session.state = .attention; publish(id)
        return false
    }
    public func retireIdle() async {
        let date = now()
        discardShelf { $0.until <= date }
        for id in bindings.filter({ $0.value.stopped }).map(\.key) { _ = await releaseStopped(id) }
        await endExpiredParks()
        await enforceParkCap()
        // past idleKeep a waiting run is shelved for the rest of its hour, or ended if it cannot be
        let expired = bindings.filter { isRetirable($0.value) && now().timeIntervalSince($0.value.lastActive) >= idleKeep }
            .sorted { $0.value.lastActive < $1.value.lastActive }.map(\.key)
        for id in expired { _ = await shelveOrRetire(id) }
    }
    private func startRetirementTimer() {
        guard retirementTask == nil else { return }
        retirementTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled, self != nil else { return }
                await self?.retireIdle()
                await self?.logHealth()
            }
        }
    }

    /// Cancels the conversation's request being answered now: the gateway calls this only when its
    /// client has gone while the reply was still under way, never after a failed reply, so a retry that follows a failure is never reached by its predecessor's cancel.
    public func cancel(conversationID: String) async {
        let targets = active.filter { $0.value.alias == conversationID }
        if let serving = targets.filter({ $0.value.binding != nil }).keys.min() { await cancel(generation: serving); return }
        for generation in targets.keys.sorted() { await cancel(generation: generation) }
    }
    /// Cancels one request. Its run is stopped only while it still answers that request.
    private func cancel(generation: UInt64) async {
        guard let activity = active[generation] else { return }
        cancelledGenerations.insert(generation)
        guard let id = activity.binding, let binding = bindings[id], binding.serving == generation else { return }
        setWorkState(id, state: .waitingUser)
        bindings[id]?.stopped = true; bindings[id]?.busy = false; bindings[id]?.serving = nil; bindings[id]?.session.state = .attention
        await binding.worker.cancel()
        route(id: id, model: binding.request.model, reason: .cancelled)
        bindings[id]?.busy = false; bindings[id]?.session.state = .attention; publish(id)
    }
    public func cancelSession(_ sessionID: UUID) async {
        guard let binding = bindings[sessionID] else { return }
        setWorkState(sessionID, state: .waitingUser)
        bindings[sessionID]?.stopped = true; bindings[sessionID]?.busy = false; bindings[sessionID]?.serving = nil
        bindings[sessionID]?.session.state = .attention
        for (generation, activity) in active where activity.binding == sessionID { cancelledGenerations.insert(generation) }
        await binding.worker.cancel()
        route(id: sessionID, model: binding.request.model, reason: .cancelled)
        bindings[sessionID]?.busy = false; bindings[sessionID]?.session.state = .attention; publish(sessionID)
    }
    public func sendInput(sessionID: UUID, data: Data) async throws {
        guard let binding = bindings[sessionID] else { throw BridgeFailure.unavailable }
        guard !binding.retiring else { throw BridgeFailure.busy }
        bindings[sessionID]?.lastActive = now()
        bindings[sessionID]?.session.state = .attention
        publish(sessionID)
        try await binding.worker.sendInput(data)
    }
    public func closeAccount(_ accountID: UUID) async -> Bool {
        discardShelf { $0.saved.accountID == accountID }
        let targets = bindings.filter { $0.value.session.accountID == accountID }
        guard targets.values.allSatisfy({ !$0.busy && $0.pending.isEmpty }) else { return false }
        for (id, binding) in targets {
            guard await binding.worker.close() else { return false }
            bindings[id]?.session.state = .ended; publish(id)
            remove(id)
        }
        return true
    }
    public func closeSession(_ sessionID: UUID) async -> Bool {
        guard let binding = bindings[sessionID] else { return true }
        guard !binding.busy, binding.pending.isEmpty, !binding.retiring else { return false }
        bindings[sessionID]?.retiring = true
        if await binding.worker.close() { bindings[sessionID]?.session.state = .ended; publish(sessionID); remove(sessionID); return true }
        bindings[sessionID]?.retiring = false; bindings[sessionID]?.session.state = .attention; publish(sessionID)
        return false
    }
    public func requestSessionExit(_ sessionID: UUID) async -> Bool {
        guard let binding = bindings[sessionID], !binding.retiring else { return bindings[sessionID] == nil }
        bindings[sessionID]?.retiring = true
        if await binding.worker.requestExit() {
            bindings[sessionID]?.session.state = .ended; publish(sessionID); remove(sessionID); return true
        }
        bindings[sessionID]?.retiring = false; bindings[sessionID]?.busy = false
        bindings[sessionID]?.session.state = .attention; publish(sessionID)
        return false
    }
    /// Quitting ends every session the pool runs; nobody has to end one by hand first. An idle
    /// session takes the client's own exit. One answering, waiting on a tool or holding input has
    /// its request cancelled and receives the client's own Ctrl-C (`requestExit`), never a forced
    /// end. Returns false only when a child did not end; that session is kept and reported.
    public func shutdown() async -> Bool {
        paused = true
        discardShelf { _ in true }
        var allEnded = true
        for (id, binding) in bindings {
            bindings[id]?.retiring = true
            var ended = false
            if !binding.busy && binding.pending.isEmpty { ended = await binding.worker.close() }
            if !ended {
                for (generation, activity) in active where activity.binding == id { cancelledGenerations.insert(generation) }
                ended = await binding.worker.requestExit()
            }
            if ended {
                bindings[id]?.session.state = .ended; publish(id)
                remove(id)
            } else {
                bindings[id]?.retiring = false; bindings[id]?.session.state = .attention; publish(id)
                allEnded = false
            }
        }
        return allEnded
    }
}
