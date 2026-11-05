import Foundation
import PoolRuntime
@testable import PoolPrivacy
import XCTest

private actor DetectionGrants {
    var order: [Int] = []
    func record(_ value: Int) { order.append(value) }
}

final class AstrLinkQueueTests: XCTestCase {
    private func detector() -> AstrLinkDetector {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/privacy-queue-fixtures/\(UUID().uuidString)")
        return AstrLinkDetector(workspace: OwnedWorkspace(root: root))
    }

    func testFIFOReservesTransferredSlotBeforeNewArrival() async throws {
        let model = detector(), grants = DetectionGrants()
        try await model.acquireDetection(); try await model.acquireDetection()
        let first = Task { try await model.acquireDetection(); await grants.record(1) }
        try await privacyQueueEventually { await model.detectionQueueState.waiting == 1 }
        let second = Task { try await model.acquireDetection(); await grants.record(2) }
        try await privacyQueueEventually { await model.detectionQueueState.waiting == 2 }
        await model.releaseDetection(); try await first.value
        let third = Task { try await model.acquireDetection(); await grants.record(3) }
        try await privacyQueueEventually { await model.detectionQueueState.waiting == 2 }
        await model.releaseDetection(); try await second.value
        await model.releaseDetection(); try await third.value
        let order = await grants.order
        XCTAssertEqual(order, [1, 2, 3])
        await model.releaseDetection(); await model.releaseDetection()
        let state = await model.detectionQueueState
        XCTAssertEqual(state.active, 0); XCTAssertEqual(state.waiting, 0)
    }

    func testQueuedCancellationPreservesFollowerAndReleasesCapacity() async throws {
        let model = detector()
        try await model.acquireDetection(); try await model.acquireDetection()
        let cancelled = Task { try await model.acquireDetection() }
        try await privacyQueueEventually { await model.detectionQueueState.waiting == 1 }
        let follower = Task { try await model.acquireDetection() }
        try await privacyQueueEventually { await model.detectionQueueState.waiting == 2 }
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("Queued cancellation must throw") }
        catch { XCTAssertTrue(error is CancellationError) }
        let queued = await model.detectionQueueState
        XCTAssertEqual(queued.active, 2); XCTAssertEqual(queued.waiting, 1)
        await model.releaseDetection(); try await follower.value
        await model.releaseDetection(); await model.releaseDetection()
        try await model.acquireDetection(); await model.releaseDetection()
        let state = await model.detectionQueueState
        XCTAssertEqual(state.active, 0); XCTAssertEqual(state.waiting, 0)
    }

    func testCancellationAroundGrantCannotLeakDetectSlot() async throws {
        let model = detector()
        for attempt in 0..<20 {
            try await model.acquireDetection(); try await model.acquireDetection()
            let waiting = Task { try await model.detect(in: "") }
            try await privacyQueueEventually { await model.detectionQueueState.waiting == 1 }
            if attempt.isMultiple(of: 2) { waiting.cancel(); await model.releaseDetection() }
            else { await model.releaseDetection(); waiting.cancel() }
            do { _ = try await waiting.value; XCTFail("No model is installed in this fixture") }
            catch { XCTAssertTrue(error is CancellationError || error as? PrivacyFailure == .notReady) }
            await model.releaseDetection()
            let state = await model.detectionQueueState
            XCTAssertEqual(state.active, 0); XCTAssertEqual(state.waiting, 0)
        }
    }

    /// No queue cap and no queue deadline: how long a request waits for the model is the bridge's own,
    /// and one that stops waiting cancels its place.
    func testQueueNeverRefusesAndOversizedInputHasItsOwnFailure() async throws {
        let model = detector()
        try await model.acquireDetection(); try await model.acquireDetection()
        var waiting: [Task<Void, Error>] = []
        for count in 1...24 {
            waiting.append(Task { try await model.acquireDetection() })
            try await privacyQueueEventually { await model.detectionQueueState.waiting == count }
        }
        do { _ = try await model.detect(in: String(repeating: "x", count: 1024 * 1024 + 1)); XCTFail("Oversized text must not enter the queue") }
        catch { XCTAssertEqual(error as? PrivacyFailure, .inputTooLarge) }
        // The first in line is served when a place frees; the rest stop waiting.
        await model.releaseDetection()
        try await waiting[0].value
        for task in waiting.dropFirst() { task.cancel() }
        for task in waiting.dropFirst() {
            do { try await task.value; XCTFail("Cancelled waiters must leave the queue") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        await model.releaseDetection(); await model.releaseDetection()
        let state = await model.detectionQueueState
        XCTAssertEqual(state.active, 0); XCTAssertEqual(state.waiting, 0)
    }
}

func privacyQueueEventually(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await condition()) {
        guard ContinuousClock.now < deadline else { throw PrivacyFailure.busy }
        try await Task.sleep(for: .milliseconds(1))
    }
}
