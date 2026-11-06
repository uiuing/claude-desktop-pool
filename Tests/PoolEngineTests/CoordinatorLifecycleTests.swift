import Foundation
import XCTest
import PoolCore
@testable import PoolEngine

final class CoordinatorLifecycleTests: XCTestCase {
    func testCapacityRetiresOldestIdleAndUsesOrdinaryHistoryWhenReturning() async throws {
        let factory = LifecycleFactory()
        let pool = coordinator(factory, capacity: 1)
        let first = ask("First")
        _ = try await drain(pool, first, id: "first")
        let original = try await factory.worker(0)
        _ = try await drain(pool, ask("Other"), id: "other")
        let closed = await original.closeAttempts
        XCTAssertEqual(closed, 1)
        let count = await factory.count
        XCTAssertEqual(count, 2)
        var continued = first
        continued.messages += [.init(role: "assistant", content: .array([.object(["type": .string("text"), "text": .string("Reply")])])),
                               .init(role: "user", content: .string("Continue"))]
        _ = try await drain(pool, continued, id: "first")
        let resumed = try await factory.worker(2)
        let received = await resumed.requests
        XCTAssertEqual(received.first?.messages, continued.messages)
        _ = await pool.shutdown()
    }

    func testPendingToolKeepsItsRoomForParkLongestThenALateResultIsReplayed() async throws {
        let clock = LifecycleClock(), factory = LifecycleFactory(modes: [.tool, .reply, .reply])
        let pool = coordinator(factory, capacity: 1, clock: clock)
        let tool = ask("Tool")
        _ = try await drain(pool, tool, id: "tool")
        // A call the client is still running keeps its run for parkLongest.
        do { _ = try await pool.events(for: ask("New"), conversationID: "new"); XCTFail("A fresh pending call was evicted") }
        catch { XCTAssertEqual(error as? BridgeFailure, .busy) }
        let worker = try await factory.worker(0)
        let early = await worker.closeAttempts
        XCTAssertEqual(early, 0)
        // Nobody answered for parkLongest: the run gives its room to a new conversation.
        clock.advance(301)
        let fresh = try await drain(pool, ask("New"), id: "new")
        XCTAssertTrue(fresh.contains(.finished(.endTurn)))
        let closes = await worker.closeAttempts
        XCTAssertEqual(closes, 1)
        // The late result goes on in a new run told the whole conversation, never a refusal.
        var late = tool
        late.messages += [.init(role: "assistant", content: .array([.object(["type": .string("tool_use"), "id": .string("pending"),
                                                                             "name": .string("read"), "input": .object([:])])])),
                          .init(role: "user", content: .array([.object(["type": .string("tool_result"), "tool_use_id": .string("pending"),
                                                                        "content": .string("Synthetic result.")])]))]
        let answer = try await drain(pool, late, id: "tool")
        XCTAssertTrue(answer.contains(.finished(.endTurn)))
        let replayed = try await factory.worker(2)
        let replays = await replayed.replays
        XCTAssertEqual(replays, [late])
        let closed = await pool.shutdown()
        XCTAssertTrue(closed)
    }

    func testRunTimeoutEndsAParkedRunAndQuitStillEndsOne() async throws {
        let clock = LifecycleClock(), factory = LifecycleFactory(mode: .tool)
        let pool = coordinator(factory, capacity: 2, clock: clock)
        _ = try await drain(pool, ask("Tool"), id: "tool")
        let worker = try await factory.worker(0)
        clock.advance(3599)
        await pool.retireIdle()
        let kept = await worker.closeAttempts
        XCTAssertEqual(kept, 0)
        clock.advance(2)
        await pool.retireIdle()
        let ended = await worker.closeAttempts
        XCTAssertEqual(ended, 1)
        let sessions = await pool.sessions()
        XCTAssertTrue(sessions.isEmpty)
        // Quitting still ends a parked one: the pool's own session never holds the app open.
        _ = try await drain(pool, ask("Another tool"), id: "another")
        let closed = await pool.shutdown()
        XCTAssertTrue(closed)
    }

    func testIdleRetirementUsesQuietPeriodAndNormalExit() async throws {
        let clock = LifecycleClock(), factory = LifecycleFactory()
        let pool = coordinator(factory, capacity: 2, clock: clock)
        _ = try await drain(pool, ask("Idle"), id: "idle")
        let worker = try await factory.worker(0)
        clock.advance(599)
        await pool.retireIdle()
        let before = await worker.closeAttempts
        XCTAssertEqual(before, 0)
        clock.advance(2)
        await pool.retireIdle()
        let after = await worker.closeAttempts
        XCTAssertEqual(after, 1)
        let sessions = await pool.sessions()
        XCTAssertTrue(sessions.isEmpty)
    }

    func testFailedNormalExitRetainsTheWorkerAndRequiresAttention() async throws {
        let factory = LifecycleFactory(canClose: false)
        let pool = coordinator(factory, capacity: 1)
        _ = try await drain(pool, ask("First"), id: "first")
        do { _ = try await pool.events(for: ask("Second"), conversationID: "second"); XCTFail("Unconfirmed process exit was ignored") }
        catch { XCTAssertEqual(error as? BridgeFailure, .busy) }
        let sessions = await pool.sessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.state, .attention)
        let count = await factory.count
        XCTAssertEqual(count, 1)
        let worker = try await factory.worker(0)
        await worker.simulateExit()
    }

    /// A real conversation (11-06): its run had answered, yet was not idle at the next turn, and the
    /// turn was refused; Desktop started a new client session and the conversation moved accounts.
    func testARunThatCannotTakeItsNextTurnIsReplacedOnTheSameAccount() async throws {
        let ended = LoggedLines()
        let (pool, factory, used, first, second) = twoAccountPool(onUpdate: { update in
            if case .session(let session) = update, session.state == .ended { ended.add(session.id.uuidString) }
        })
        let opening = ask("First")
        _ = try await drain(pool, opening, id: "conversation")
        let opened = await used.accounts
        let original = try XCTUnwrap(opened.first)
        // The other account now has more left: the conversation still stays where its cache is.
        await pool.updateAccounts(original == first.id ? [first, better(second)] : [better(first), second])
        let worker = try await factory.worker(0)
        await worker.needAttention()
        try await lifecycleWait { await pool.sessions().contains { $0.id == worker.id && $0.state == .attention } }
        _ = try await drain(pool, followUp(opening), id: "conversation")
        let accounts = await used.accounts
        XCTAssertEqual(accounts, [original, original])
        // The replaced run leaves the app's list too, not just the coordinator.
        XCTAssertTrue(ended.all.contains(worker.id.uuidString))
        _ = await pool.shutdown()
    }

    func testANewClientSessionOfTheSameConversationStaysOnItsAccount() async throws {
        let (pool, factory, used, first, second) = twoAccountPool()
        let opening = ask("First")
        _ = try await drain(pool, opening, id: "session-1#shape")
        let opened = await used.accounts
        let original = try XCTUnwrap(opened.first)
        await pool.updateAccounts(original == first.id ? [first, better(second)] : [better(first), second])
        // Its run is gone (Desktop restarted the client): the next turn arrives under a new session id.
        let worker = try await factory.worker(0)
        await worker.simulateExit()
        try await lifecycleWait { await pool.sessions().isEmpty }
        _ = try await drain(pool, followUp(opening), id: "session-2#shape")
        let accounts = await used.accounts
        XCTAssertEqual(accounts, [original, original])
        // Another conversation goes where most is left.
        let resumed = try await factory.worker(1)
        await resumed.simulateExit()
        try await lifecycleWait { await pool.sessions().isEmpty }
        _ = try await drain(pool, followUp(ask("Other")), id: "session-3#shape")
        let third = await used.accounts.last
        XCTAssertNotEqual(third, original)
        _ = await pool.shutdown()
    }

    private func twoAccountPool(onUpdate: @escaping @Sendable (EngineUpdate) -> Void = { _ in }) -> (PoolCoordinator, LifecycleFactory, UsedAccounts, PoolAccount, PoolAccount) {
        let clock = LifecycleClock(), factory = LifecycleFactory(), used = UsedAccounts()
        let window = { (used: Double) in [QuotaWindow(id: "five_hour", usedPercent: used, observedAt: clock.now, resetsAt: clock.now.addingTimeInterval(3 * 3600)),
                                          QuotaWindow(id: "seven_day", usedPercent: used, observedAt: clock.now, resetsAt: clock.now.addingTimeInterval(5 * 86400))] }
        let first = PoolAccount(email: "one@example.com", plan: "Pro", state: .ready, windows: window(40))
        let second = PoolAccount(email: "two@example.com", plan: "Pro", state: .ready, windows: window(50))
        let pool = PoolCoordinator(accounts: [first, second], maximumWorkers: 4, idleTimeout: 600, idleKeep: 600, roomWait: 0,
                                   now: { clock.now }, factory: { account, _ in await used.add(account.id); return await factory.make() }, onUpdate: onUpdate)
        return (pool, factory, used, first, second)
    }
    private func better(_ account: PoolAccount) -> PoolAccount {
        var account = account
        for index in account.windows.indices { account.windows[index].usedPercent = 0 }
        return account
    }
    private func followUp(_ request: BridgeRequest) -> BridgeRequest {
        var next = request
        next.messages += [.init(role: "assistant", content: .array([.object(["type": .string("text"), "text": .string("Reply")])])),
                          .init(role: "user", content: .string("Continue"))]
        return next
    }

    /// Every run state change and every account pick is in the log, so a run that cannot take
    /// its next turn, or a conversation that moved, can be explained from the log alone.
    func testRunStatesAndPicksAreLoggedOncePerChange() async throws {
        let lines = LoggedLines()
        Diagnostics.install { lines.add($0) }
        defer { Diagnostics.install(nil) }
        let (pool, factory, _, _, _) = twoAccountPool()
        _ = try await drain(pool, ask("First"), id: "conversation")
        let worker = try await factory.worker(0)
        let run = Diagnostics.id(worker.id)
        await worker.needAttention()
        try await lifecycleWait { lines.all.contains { $0.contains("event=coordinator.state run=\(run)") && $0.contains("to=attention") } }
        let states = lines.all.filter { $0.hasPrefix("event=coordinator.state run=\(run)") }
        XCTAssertTrue(states.first?.contains("from=new to=starting") == true || states.first?.contains("from=new to=running") == true, "\(states)")
        XCTAssertEqual(states.filter { $0.contains("to=attention") }.count, 1)
        let pick = try XCTUnwrap(lines.all.first { $0.hasPrefix("event=coordinator.pick") })
        XCTAssertTrue(pick.contains("kept=none") && pick.contains("candidates="), pick)
        XCTAssertTrue(lines.all.contains { $0.hasPrefix("event=coordinator.decision reason=") && $0.contains(" run=\(run) ") },
                      lines.all.filter { $0.contains("decision") }.joined(separator: "\n"))
        _ = await pool.shutdown()
    }

    func testActiveResponseIsNotRetiredToMakeSpace() async throws {
        let factory = LifecycleFactory(mode: .held)
        let pool = coordinator(factory, capacity: 1)
        let stream = try await pool.events(for: ask("Working"), conversationID: "working")
        let response = Task { var events: [BridgeEvent] = []; for try await event in stream { events.append(event) }; return events }
        let worker = try await factory.worker(0)
        try await lifecycleWait { await worker.requests.count == 1 }
        do { _ = try await pool.events(for: ask("New"), conversationID: "new"); XCTFail("Active worker was evicted") }
        catch { XCTAssertEqual(error as? BridgeFailure, .busy) }
        await pool.cancelSession(worker.id)
        do { _ = try await response.value; XCTFail("Cancel completed successfully") }
        catch { XCTAssertEqual(error as? BridgeFailure, .cancelled) }
        let closes = await worker.closeAttempts
        XCTAssertEqual(closes, 0)
        await worker.simulateExit()
    }

    func testStoppedReplyEndsItsRunAndTheConversationContinuesWithHistory() async throws {
        let factory = LifecycleFactory(modes: [.held, .reply, .held, .reply])
        let pool = coordinator(factory, capacity: 1)
        let first = ask("First")
        try await stop(pool, first, id: "stopped", worker: 0, factory: factory)
        // Desktop's retry after Stop sends the same turn again. It starts a new run, never a 403.
        let retried = try await drain(pool, first, id: "stopped")
        XCTAssertTrue(retried.contains(.finished(.endTurn)))
        let stopped = try await factory.worker(0)
        let closes = await stopped.closeAttempts
        XCTAssertEqual(closes, 1)
        let rerun = try await factory.worker(1)
        let received = await rerun.requests
        XCTAssertEqual(received.first?.messages, first.messages)
        // Repeated stops never use up capacity: a stopped run is ended for the next new conversation.
        try await stop(pool, ask("Another"), id: "another", worker: 2, factory: factory)
        let fresh = try await drain(pool, ask("Fresh"), id: "fresh")
        XCTAssertTrue(fresh.contains(.finished(.endTurn)))
        let count = await factory.count
        XCTAssertEqual(count, 4)
        let closed = await pool.shutdown(); XCTAssertTrue(closed)
    }

    func testIdleTimerEndsStoppedRuns() async throws {
        let factory = LifecycleFactory(mode: .held)
        let pool = coordinator(factory, capacity: 2)
        try await stop(pool, ask("Stopped"), id: "stopped", worker: 0, factory: factory)
        await pool.retireIdle()
        let sessions = await pool.sessions()
        XCTAssertTrue(sessions.isEmpty)
    }

    func testPartialShutdownPublishesOnlyConfirmedClosedSessions() async throws {
        let sequence = ShutdownSequence(), updates = ShutdownUpdates()
        let pool = PoolCoordinator(accounts: [.init(email: "po•••olive@example.com", state: .ready)], maximumWorkers: 2,
                                   factory: { _, _ in ShutdownWorker(sequence: sequence) }, onUpdate: { updates.record($0) })
        _ = try await drain(pool, ask("First idle conversation"), id: "shutdown-first")
        _ = try await drain(pool, ask("Second idle conversation"), id: "shutdown-second")
        let closed = await pool.shutdown()
        XCTAssertFalse(closed)
        // The refused close is followed by the client's normal exit once more, never a forced end.
        let attempts = await sequence.attempts
        XCTAssertEqual(attempts.count, 3)
        XCTAssertEqual(attempts[2], attempts[1])
        XCTAssertEqual(updates.endedIDs, [attempts[0]], "Confirmed closure must reach the UI even if a later worker refuses to exit.")
        let retained = await pool.sessions()
        XCTAssertEqual(retained.map(\.id), [attempts[1]])
        XCTAssertNotEqual(retained.first?.state, .ended)
        await sequence.allowRemaining()
        let cleanup = await pool.shutdown(); XCTAssertTrue(cleanup)
    }

    func testAToolResultArrivingAfterQuitBeganStartsNoRun() async throws {
        let clock = LifecycleClock(), factory = LifecycleFactory(modes: [.tool, .reply])
        let pool = coordinator(factory, capacity: 2, clock: clock)
        let tool = ask("Tool")
        _ = try await drain(pool, tool, id: "tool")
        var late = tool
        late.messages += [.init(role: "assistant", content: .array([.object(["type": .string("tool_use"), "id": .string("pending"),
                                                                             "name": .string("read"), "input": .object([:])])])),
                          .init(role: "user", content: .array([.object(["type": .string("tool_result"), "tool_use_id": .string("pending"),
                                                                        "content": .string("Synthetic result.")])]))]
        let closed = await pool.shutdown(); XCTAssertTrue(closed)
        // A run started now would outlive the others and hold quitting for its whole turn.
        do { _ = try await pool.events(for: late, conversationID: "tool"); XCTFail("A run started after quit began") }
        catch { XCTAssertEqual(error as? BridgeFailure, .paused) }
        let started = await factory.count
        XCTAssertEqual(started, 1)
        // A refused quit serves again: the same result goes on.
        await pool.setPaused(false)
        let answer = try await drain(pool, late, id: "tool")
        XCTAssertTrue(answer.contains(.finished(.endTurn)))
        _ = await pool.shutdown()
    }

    func testQuitEndsSessionsTogether() async throws {
        let barrier = ShutdownBarrier(expected: 2)
        let pool = PoolCoordinator(accounts: [.init(email: "po•••olive@example.com", state: .ready)], maximumWorkers: 2,
                                   factory: { _, _ in BarrierWorker(barrier: barrier) })
        _ = try await drain(pool, ask("First idle conversation"), id: "together-first")
        _ = try await drain(pool, ask("Second idle conversation"), id: "together-second")
        // Each close returns only once the other has begun, which one at a time never reaches.
        let closed = await pool.shutdown()
        XCTAssertTrue(closed)
    }

    private func coordinator(_ factory: LifecycleFactory, capacity: Int, clock: LifecycleClock = LifecycleClock()) -> PoolCoordinator {
        PoolCoordinator(accounts: [.init(email: "po•••olive@example.com", state: .ready)], maximumWorkers: capacity,
                        idleTimeout: 600, idleKeep: 600, roomWait: 0, now: { clock.now }, factory: { _, _ in await factory.make() })
    }
    private func ask(_ text: String) -> BridgeRequest {
        // Desktop's conversations always offer Claude Code's tools; a toolless first ask is a one-off.
        BridgeRequest(model: "claude-sonnet", messages: [.init(role: "user", content: .string(text))], tools: [.init(name: "Read", inputSchema: .object(["type": .string("object")]))])
    }
    /// Starts a reply and stops it the way Desktop does, by dropping the response stream.
    private func stop(_ pool: PoolCoordinator, _ request: BridgeRequest, id: String, worker index: Int, factory: LifecycleFactory) async throws {
        let stream = try await pool.events(for: request, conversationID: id)
        let response = Task { for try await _ in stream {} }
        try await lifecycleWait { (try? await factory.worker(index).requests.count) == 1 }
        response.cancel()
        _ = try? await response.value
        let worker = try await factory.worker(index)
        try await lifecycleWait {
            let sessions = await pool.sessions()
            return await worker.cancelled && sessions.contains { $0.id == worker.id && $0.state == .attention }
        }
    }
    private func drain(_ pool: PoolCoordinator, _ request: BridgeRequest, id: String) async throws -> [BridgeEvent] {
        var events: [BridgeEvent] = []
        for try await event in try await pool.events(for: request, conversationID: id) { events.append(event) }
        return events
    }
}

private final class LoggedLines: @unchecked Sendable {
    private let lock = NSLock(); private var values: [String] = []
    func add(_ line: String) { lock.withLock { values.append(line) } }
    var all: [String] { lock.withLock { values } }
}
private actor UsedAccounts {
    private(set) var accounts: [UUID] = []
    func add(_ id: UUID) { accounts.append(id) }
}
private actor LifecycleFactory {
    enum Mode { case reply, tool, held }
    private var workers: [LifecycleWorker] = []
    private let modes: [Mode]
    private let canClose: Bool
    init(mode: Mode = .reply, canClose: Bool = true) { self.modes = [mode]; self.canClose = canClose }
    init(modes: [Mode]) { self.modes = modes; self.canClose = true }
    var count: Int { workers.count }
    func make() -> LifecycleWorker {
        let worker = LifecycleWorker(mode: modes[min(workers.count, modes.count - 1)], canClose: canClose)
        workers.append(worker); return worker
    }
    func worker(_ index: Int) throws -> LifecycleWorker {
        guard index < workers.count else { throw BridgeFailure.unavailable }; return workers[index]
    }
}
private actor LifecycleWorker: SessionWorker {
    nonisolated let id = UUID()
    var requests: [BridgeRequest] = []
    var replays: [BridgeRequest] = []
    var closeAttempts = 0
    var cancelled = false
    private let mode: LifecycleFactory.Mode
    private let canClose: Bool
    private var held: AsyncThrowingStream<BridgeEvent, Error>.Continuation?
    private var observer: AsyncStream<WorkerObservation>.Continuation?
    init(mode: LifecycleFactory.Mode, canClose: Bool) { self.mode = mode; self.canClose = canClose }
    func observations() -> AsyncStream<WorkerObservation> { AsyncStream { observer = $0 } }
    func events(replaying replay: VerifiedToolReplay) throws -> AsyncThrowingStream<BridgeEvent, Error> {
        replays.append(replay.request)
        return AsyncThrowingStream { continuation in
            continuation.yield(.text("Reply")); continuation.yield(.finished(.endTurn)); continuation.finish()
        }
    }
    func events(for request: BridgeRequest) throws -> AsyncThrowingStream<BridgeEvent, Error> {
        requests.append(request)
        return AsyncThrowingStream { continuation in
            switch mode {
            case .reply:
                continuation.yield(.usage(.init(inputTokens: 10, outputTokens: 1)))
                continuation.yield(.text("Reply")); continuation.yield(.finished(.endTurn)); continuation.finish()
            case .tool:
                continuation.yield(.usage(.init(inputTokens: 10, outputTokens: 2)))
                continuation.yield(.toolUse(.init(id: "pending", name: "read", input: .object([:]))))
                continuation.yield(.finished(.toolUse)); continuation.finish()
            case .held: held = continuation
            }
        }
    }
    func sendInput(_ data: Data) {}
    func cancel() { cancelled = true; held?.finish(throwing: BridgeFailure.cancelled); held = nil }
    func close() -> Bool { closeAttempts += 1; if canClose { observer?.yield(.ended); observer?.finish() }; return canClose }
    func simulateExit() { observer?.yield(.ended); observer?.finish() }
    func needAttention() { observer?.yield(.attention) }
}
private final class LifecycleClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_900_000_000)
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value.addTimeInterval(seconds) } }
}
private actor ShutdownSequence {
    private(set) var attempts: [UUID] = []
    private var allowAll = false
    func close(_ id: UUID) -> Bool { attempts.append(id); return allowAll || attempts.count == 1 }
    func allowRemaining() { allowAll = true }
}
private actor ShutdownWorker: SessionWorker {
    nonisolated let id = UUID()
    let sequence: ShutdownSequence
    init(sequence: ShutdownSequence) { self.sequence = sequence }
    // A confirmed close does not depend on a separate process-observation callback arriving.
    func observations() -> AsyncStream<WorkerObservation> { AsyncStream { $0.finish() } }
    func events(for request: BridgeRequest) -> AsyncThrowingStream<BridgeEvent, Error> {
        AsyncThrowingStream { $0.yield(.text("Reply")); $0.yield(.finished(.endTurn)); $0.finish() }
    }
    func sendInput(_ data: Data) {}
    func cancel() {}
    func close() async -> Bool { await sequence.close(id) }
}
private actor ShutdownBarrier {
    private var arrived = 0
    private let expected: Int
    init(expected: Int) { self.expected = expected }
    func arrive() async -> Bool {
        arrived += 1
        let deadline = Date().addingTimeInterval(2)
        while arrived < expected, Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        return arrived >= expected
    }
}
private actor BarrierWorker: SessionWorker {
    nonisolated let id = UUID()
    let barrier: ShutdownBarrier
    init(barrier: ShutdownBarrier) { self.barrier = barrier }
    func observations() -> AsyncStream<WorkerObservation> { AsyncStream { $0.finish() } }
    func events(for request: BridgeRequest) -> AsyncThrowingStream<BridgeEvent, Error> {
        AsyncThrowingStream { $0.yield(.text("Reply")); $0.yield(.finished(.endTurn)); $0.finish() }
    }
    func sendInput(_ data: Data) {}
    func cancel() {}
    func close() async -> Bool { await barrier.arrive() }
    func requestExit() async -> Bool { false }
}
private final class ShutdownUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private var ended: [UUID] = []
    var endedIDs: [UUID] { lock.withLock { ended } }
    func record(_ update: EngineUpdate) {
        if case .session(let session) = update, session.state == .ended { lock.withLock { ended.append(session.id) } }
    }
}
private func lifecycleWait(_ condition: () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(30)
    while !(await condition()) {
        if Date() > deadline { throw BridgeFailure.transport }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}
