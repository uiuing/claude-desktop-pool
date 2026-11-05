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
private final class ShutdownUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private var ended: [UUID] = []
    var endedIDs: [UUID] { lock.withLock { ended } }
    func record(_ update: EngineUpdate) {
        if case .session(let session) = update, session.state == .ended { lock.withLock { ended.append(session.id) } }
    }
}
private func lifecycleWait(_ condition: () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(3)
    while !(await condition()) {
        if Date() > deadline { throw BridgeFailure.transport }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}
