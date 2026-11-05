import Foundation
import XCTest
import PoolCore
@testable import PoolEngine

final class CoordinatorActivityTests: XCTestCase {
    func testOnlyMeasuredUsageCountsActivityAndNativeGenerationTransitionsAreDeduplicated() async throws {
        let account = PoolAccount(email: "po•••olive@example.com", plan: "Pro", state: .ready)
        let worker = ActivityWorker(), updates = ActivityUpdates(), date = Date(timeIntervalSince1970: 1_800_000_000)
        let pool = PoolCoordinator(accounts: [account], now: { date }, factory: { _, _ in worker }, onUpdate: { updates.record($0) })
        let stream = try await pool.events(for: request(), conversationID: "activity")
        let response = Task { for try await _ in stream {} }
        try await activityWait { await worker.started }
        XCTAssertTrue(updates.progresses.isEmpty)
        XCTAssertTrue(updates.states.isEmpty, "Admission's running UI state is not native generation evidence.")
        await worker.observe(.working); await worker.observe(.working)
        try await activityWait { updates.states.count == 1 }
        await worker.emit(.usage(.init(inputTokens: 10, outputTokens: 1)))
        await worker.emit(.usage(.init(inputTokens: 10, outputTokens: 2)))
        await worker.emit(.text("Reply")); await worker.emit(.finished(.endTurn))
        try await response.value
        await worker.observe(.idle)
        XCTAssertEqual(updates.progresses.filter { $0.progress.usage != nil }.count, 1)
        XCTAssertEqual(updates.progresses.first?.scope, AccountScope(account))
        XCTAssertEqual(updates.progresses.first?.progress.observedAt, date)
        XCTAssertEqual(updates.states.map(\.state), [.generating, .idle])
        // The usage ledger takes one row per reply, however often the reply restates its usage.
        XCTAssertEqual(updates.ledger.count, 1)
        XCTAssertEqual(updates.ledger.first?.scope, AccountScope(account))
        XCTAssertEqual(updates.ledger.first?.at, date)
        XCTAssertFalse(updates.ledger.first?.model.isEmpty ?? true)
        XCTAssertTrue(updates.states.allSatisfy { $0.scope == AccountScope(account) && $0.sessionID == worker.id })

        var continued = request()
        continued.messages += [.init(role: "assistant", content: .array([.object(["type": .string("text"), "text": .string("Reply")])])),
                               .init(role: "user", content: .string("Continue"))]
        let nextStream = try await pool.events(for: continued, conversationID: "activity")
        let nextResponse = Task { for try await _ in nextStream {} }
        try await activityWait { await worker.requestCount == 2 }
        await worker.emit(.usage(.init(inputTokens: 20, outputTokens: 1))); await worker.emit(.finished(.endTurn))
        try await nextResponse.value
        XCTAssertEqual(Set(updates.progresses.map { $0.progress.requestID }).count, 2, "Each measured attempt has a distinct deduplication identity.")
        XCTAssertEqual(updates.ledger.count, 2)
        let closed = await pool.shutdown(); XCTAssertTrue(closed)
    }

    func testToolPermissionIdleFailureExitAndCancelClearNativeGeneration() async throws {
        for ending in ActivityEnding.allCases {
            let worker = ActivityWorker(), updates = ActivityUpdates()
            let pool = PoolCoordinator(accounts: [.init(email: "po•••olive@example.com", state: .ready)],
                                       factory: { _, _ in worker }, onUpdate: { updates.record($0) })
            let stream = try await pool.events(for: request(), conversationID: "ending")
            let response = Task { for try await _ in stream {} }
            try await activityWait { await worker.started }
            await worker.observe(.working)
            try await activityWait { updates.states.count == 1 }
            switch ending {
            case .tool:
                await worker.emit(.toolUse(.init(id: "call", name: "read", input: .object([:]))))
                await worker.emit(.finished(.toolUse))
            case .attention: await worker.observe(.attention)
            case .idle: await worker.observe(.idle)
            case .failure: await worker.fail(.transport)
            case .exit: await worker.observe(.ended)
            case .cancel: await pool.cancelSession(worker.id)
            }
            try await activityWait { updates.states.count == 2 }
            XCTAssertEqual(updates.states.first?.state, .generating)
            XCTAssertNotEqual(updates.states.last?.state, .generating, "\(ending)")
            XCTAssertTrue(updates.progresses.isEmpty, "Lifecycle transitions are not measured responses.")
            if [.attention, .idle, .exit].contains(ending) { await worker.fail(.transport) }
            _ = try? await response.value
            await worker.observe(.ended)
            _ = await pool.shutdown()
        }
    }

    func testLateOldScopeUsageAndWorkingDoNotCreateActivityForReplacementIdentity() async throws {
        let account = PoolAccount(email: "po•••olive@example.com", plan: "Pro", state: .ready)
        let worker = ActivityWorker(), updates = ActivityUpdates()
        let pool = PoolCoordinator(accounts: [account], factory: { _, _ in worker }, onUpdate: { updates.record($0) })
        let stream = try await pool.events(for: request(), conversationID: "old-scope")
        let response = Task { for try await _ in stream {} }
        try await activityWait { await worker.started }
        var replacement = account; replacement.plan = "Ultra"
        await pool.updateAccounts([replacement])
        await worker.observe(.working)
        await worker.emit(.usage(.init(inputTokens: 10, outputTokens: 1)))
        await worker.emit(.finished(.endTurn))
        try await response.value
        let closed = await pool.shutdown(); XCTAssertTrue(closed)
        XCTAssertTrue(updates.progresses.isEmpty)
        XCTAssertFalse(updates.states.contains { $0.state == .generating })
    }

    func testProgressCoalescesTerminalSizedTextChunksAndFlushesCountsOnlyAtCompletion() async throws {
        let worker = ActivityWorker(), updates = ActivityUpdates(), date = Date(timeIntervalSince1970: 1_800_000_000)
        let pool = PoolCoordinator(accounts: [.init(email: "po•••olive@example.com", state: .ready)], now: { date },
                                   factory: { _, _ in worker }, onUpdate: { updates.record($0) })
        let stream = try await pool.events(for: request(), conversationID: "coalesced")
        let response = Task { for try await _ in stream {} }
        try await activityWait { await worker.started }
        await worker.observe(.working)
        for _ in 0..<50 { await worker.emit(.text("chunk")) }
        await worker.emit(.usage(.init(inputTokens: 20, outputTokens: 10))); await worker.emit(.finished(.endTurn))
        try await response.value
        XCTAssertEqual(updates.progresses.count, 2)
        XCTAssertEqual(updates.progresses.last?.progress.outputCharacters, 250)
        XCTAssertEqual(updates.progresses.last?.progress.usage, .init(inputTokens: 20, outputTokens: 10))
        XCTAssertEqual(updates.progresses.last?.progress.activeDuration, 0, "An unobserved duration must not be invented.")
        let closed = await pool.shutdown(); XCTAssertTrue(closed)
    }

    private func request() -> BridgeRequest {
        .init(model: "claude-sonnet", messages: [.init(role: "user", content: .string("Hello"))], tools: [.init(name: "Read", inputSchema: .object(["type": .string("object")]))])
    }
}

private enum ActivityEnding: CaseIterable { case tool, attention, idle, failure, exit, cancel }
private actor ActivityWorker: SessionWorker {
    nonisolated let id = UUID()
    private var observer: AsyncStream<WorkerObservation>.Continuation?
    private var response: AsyncThrowingStream<BridgeEvent, Error>.Continuation?
    private(set) var requestCount = 0
    var started: Bool { response != nil }
    func observations() -> AsyncStream<WorkerObservation> { AsyncStream { observer = $0 } }
    func events(for request: BridgeRequest) -> AsyncThrowingStream<BridgeEvent, Error> {
        requestCount += 1
        return AsyncThrowingStream { response = $0 }
    }
    func emit(_ event: BridgeEvent) { response?.yield(event); if case .finished = event { response?.finish() } }
    func fail(_ failure: BridgeFailure) { response?.finish(throwing: failure) }
    func observe(_ event: WorkerObservation) { observer?.yield(event) }
    func sendInput(_ data: Data) {}
    func cancel() { response?.finish(throwing: BridgeFailure.cancelled) }
    func close() -> Bool { observer?.finish(); return true }
}
private final class ActivityUpdates: @unchecked Sendable {
    struct Progress { var scope: AccountScope; var sessionID: UUID; var progress: QuotaProgress }
    struct State { var scope: AccountScope; var sessionID: UUID; var state: QuotaWorkState }
    private let lock = NSLock()
    private var progressStorage: [Progress] = []
    private var stateStorage: [State] = []
    struct Ledger { var scope: AccountScope; var model: String; var at: Date }
    private var ledgerStorage: [Ledger] = []
    var ledger: [Ledger] { lock.withLock { ledgerStorage } }
    var progresses: [Progress] { lock.withLock { progressStorage } }
    var states: [State] { lock.withLock { stateStorage } }
    func record(_ update: EngineUpdate) {
        lock.withLock {
            if case .progress(let scope, let id, let progress) = update { progressStorage.append(.init(scope: scope, sessionID: id, progress: progress)) }
            if case .workState(let scope, let id, let state, _) = update { stateStorage.append(.init(scope: scope, sessionID: id, state: state)) }
            if case .usage(let scope, let model, _, _, let at, _) = update { ledgerStorage.append(.init(scope: scope, model: model, at: at)) }
        }
    }
}
private func activityWait(_ condition: () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(3)
    while !(await condition()) {
        if Date() >= deadline { throw BridgeFailure.transport }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}
