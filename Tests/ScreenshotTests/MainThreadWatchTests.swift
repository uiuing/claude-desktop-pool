import XCTest
@testable import ClaudePool

final class MainThreadWatchTests: XCTestCase {
    /// A main thread held for longer than the threshold is said once it answers, with how long it took.
    @MainActor func testABlockedMainThreadIsReported() async throws {
        let seen = Seen()
        let watch = MainThreadWatch(interval: 0.02, threshold: 0.15, hung: 10, facts: { .init(menuOpen: true, runs: 3) }) { event, waited, facts in
            seen.add(event, waited, facts.menuOpen)
        }
        watch.start()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(seen.all.isEmpty, "An answering main thread is not a stall")
        hold(0.4)
        try await Task.sleep(for: .milliseconds(150))
        watch.stop()
        let stall = try XCTUnwrap(seen.all.first)
        XCTAssertEqual(stall.event, "ui.stall")
        XCTAssertGreaterThan(stall.waited, 0.25)
        XCTAssertTrue(stall.menu)
    }
    /// A freeze that has not ended is said while it lasts, as one ending in a forced quit never answers.
    @MainActor func testAFreezeStillOnIsReportedOnce() async throws {
        let seen = Seen()
        let watch = MainThreadWatch(interval: 0.02, threshold: 5, hung: 0.15, facts: { .init() }) { event, waited, _ in seen.add(event, waited, false) }
        watch.start()
        try await Task.sleep(for: .milliseconds(80))
        hold(0.5)
        watch.stop()
        XCTAssertEqual(seen.all.map(\.event), ["ui.stalled"])
    }
    /// A freeze says where the main thread is, more than once, so a loop can be told from a wait.
    @MainActor func testAFreezeSaysWhereTheMainThreadIs() async throws {
        let stacks = Stacks()
        let watch = MainThreadWatch(interval: 0.02, threshold: 5, hung: 0.15, facts: { .init() }, record: { _, _, _ in }) { reading, stack in
            stacks.add(reading, stack)
        }
        watch.start()
        try await Task.sleep(for: .milliseconds(80))
        hold(1.0)
        watch.stop()
        let seen = stacks.all
        XCTAssertEqual(seen.map(\.reading), [1, 2], "Read when the freeze is found and again half a second on")
        let first = try XCTUnwrap(seen.first?.stack)
        // the thread sleeps in the system's kernel interface, called from this test
        XCTAssertTrue(first.frames.first?.hasPrefix("libsystem_kernel.dylib+") == true, first.frames.first ?? "no frame")
        XCTAssertTrue(first.frames.contains { $0.contains("PackageTests+") || $0.contains("xctest+") }, "The test's own code is among the frames")
        XCTAssertGreaterThanOrEqual(first.depth, first.frames.count)
        XCTAssertFalse(first.frames.contains { $0.contains(" ") || $0.contains("/") }, "A frame is a file name and an offset, never a path")
        // a thread that answers again is not read
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(stacks.all.count, 2)
    }
    private final class Stacks: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(reading: Int, stack: MainThreadWatch.Stack)] = []
        func add(_ reading: Int, _ stack: MainThreadWatch.Stack) { lock.withLock { items.append((reading, stack)) } }
        var all: [(reading: Int, stack: MainThreadWatch.Stack)] { lock.withLock { items } }
    }
    /// Holds the thread it is called on, as a long layout holds the main thread.
    private nonisolated func hold(_ seconds: Double) { usleep(useconds_t(seconds * 1_000_000)) }
    private final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(event: String, waited: Double, menu: Bool)] = []
        func add(_ event: String, _ waited: Double, _ menu: Bool) { lock.withLock { items.append((event, waited, menu)) } }
        var all: [(event: String, waited: Double, menu: Bool)] { lock.withLock { items } }
    }
}

import PoolCore
final class PoolLimitNoticeTests: XCTestCase {
    /// The pool at its limit is told once, with the earliest reset, and told again when an account is back.
    func testThePoolsLimitIsToldAtItsBeginningAndItsEnd() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        func account(_ name: String, used: Double, back: TimeInterval) -> PoolAccount {
            PoolAccount(email: name + "@example.com", plan: "Pro", state: .ready, windows: [
                QuotaWindow(id: "five_hour", usedPercent: used, observedAt: date, resetsAt: date.addingTimeInterval(back)),
                QuotaWindow(id: "seven_day", usedPercent: 30, observedAt: date, resetsAt: date.addingTimeInterval(5 * 86_400))])
        }
        var notice = PoolLimitNotice()
        XCTAssertNil(notice.update([account("a", used: 40, back: 3000), account("b", used: 100, back: 900)], policy: .init(), now: date))
        let limited = [account("a", used: 100, back: 3000), account("b", used: 100, back: 900)]
        let told = notice.update(limited, policy: .init(), now: date)
        XCTAssertEqual(told?.state, .limited)
        XCTAssertEqual(told?.back, date.addingTimeInterval(900))
        XCTAssertNil(notice.update(limited, policy: .init(), now: date.addingTimeInterval(60)), "A limit already told is not told again")
        // the first reset passes: its account counts as full again by the clock alone
        XCTAssertEqual(notice.update(limited, policy: .init(), now: date.addingTimeInterval(901))?.state, .serving)
        // no account that could serve at all is not the pool's limit
        var none = PoolLimitNotice()
        XCTAssertNil(none.update([PoolAccount(email: "admission@example.invalid", state: .signedOut)], policy: .init(), now: date))
    }
}
