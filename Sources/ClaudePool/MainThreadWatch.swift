import CStackProbe
import Darwin
import Foundation
import PoolCore

/// Says in the app log when the main thread stopped answering, so a frozen window or menu can be
/// explained from the log the first time it happens. A background timer asks the main thread to
/// answer; an answer that took `threshold` or more is logged as `ui.stall` with how long, and one
/// still not given after `hung` is logged once as `ui.stalled`, as a freeze that ends in a forced
/// quit never answers. A freeze is then followed by `ui.stack` lines: where the main thread is,
/// read a few times so a loop can be told from a wait. Time is counted in uptime, so sleep is not a stall.
final class MainThreadWatch: @unchecked Sendable {
    /// What the app was showing and doing, read on the main thread when it answers.
    struct Facts: Sendable {
        var menuOpen = false
        var windowOpen = false
        var page = "-"
        var runs = 0
        var accounts = 0
    }
    /// Where the main thread was at one reading: its innermost frames, each as the code file it is
    /// in and how far into it, and how many frames it had in all. Code positions only, never data.
    struct Stack: Sendable, Equatable {
        var frames: [String] = []
        var depth = 0
    }
    private let queue = DispatchQueue(label: "claude-pool.main-watch", qos: .utility)
    private let interval: TimeInterval, threshold: TimeInterval, hung: TimeInterval
    private let facts: @MainActor @Sendable () -> Facts
    private let record: @Sendable (String, Double, Facts) -> Void
    private let trace: @Sendable (Int, Stack) -> Void
    private var timer: DispatchSourceTimer?
    // On `queue` only.
    private var asked: DispatchTime?
    private var reportedHung = false
    private var last = Facts()
    private var mainThread: mach_port_t = 0
    private var readings = 0
    private var readAt: DispatchTime?

    /// Readings of the main thread taken during one freeze, and the time between them.
    static let readingsMost = 3
    static let readingGap: TimeInterval = 0.5
    /// Frames kept of one reading: the innermost say what the thread is doing.
    static let framesMost = 48

    init(interval: TimeInterval = 0.25, threshold: TimeInterval = 0.5, hung: TimeInterval = 3,
         facts: @escaping @MainActor @Sendable () -> Facts,
         record: @escaping @Sendable (String, Double, Facts) -> Void = MainThreadWatch.log,
         trace: @escaping @Sendable (Int, Stack) -> Void = MainThreadWatch.logStack) {
        self.interval = interval; self.threshold = threshold; self.hung = hung; self.facts = facts; self.record = record; self.trace = trace
    }
    deinit { timer?.cancel() }

    func start() {
        // The main thread names itself once, while it answers.
        DispatchQueue.main.async { [self] in
            let thread = pthread_mach_thread_np(pthread_self())
            queue.async { [self] in mainThread = thread }
        }
        queue.async { [self] in
            guard timer == nil else { return }
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(50))
            source.setEventHandler { [weak self] in self?.tick() }
            timer = source; source.resume()
        }
    }
    func stop() { queue.async { [self] in timer?.cancel(); timer = nil; asked = nil } }

    private func tick() {
        if let asked {
            let waited = Self.seconds(since: asked)
            if waited >= hung, !reportedHung { reportedHung = true; readings = 0; readAt = nil; record("ui.stalled", waited, last) }
            if reportedHung, readings < Self.readingsMost, readAt.map({ Self.seconds(since: $0) >= Self.readingGap }) ?? true {
                readings += 1; readAt = .now()
                if let stack = Self.read(mainThread) { trace(readings, stack) }
            }
            return
        }
        let began = DispatchTime.now()
        asked = began
        DispatchQueue.main.async { [self] in
            let now = MainActor.assumeIsolated { facts() }
            queue.async { [self] in
                let waited = Self.seconds(since: began)
                asked = nil; reportedHung = false; last = now
                if waited >= threshold { record("ui.stall", waited, now) }
            }
        }
    }
    private static func seconds(since time: DispatchTime) -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds &- time.uptimeNanoseconds) / 1_000_000_000
    }

    /// Where `thread` is now. The thread is held only while its frames are copied; they are named after it runs again.
    static func read(_ thread: mach_port_t) -> Stack? {
        guard thread != 0 else { return nil }
        var addresses = [UInt](repeating: 0, count: framesMost)
        var depth: Int32 = 0
        let count = addresses.withUnsafeMutableBufferPointer { pool_stack_probe(thread, $0.baseAddress, Int32($0.count), &depth) }
        guard count > 0 else { return nil }
        return Stack(frames: addresses.prefix(Int(count)).map(place), depth: Int(depth))
    }
    /// A code address as the file it is in and the offset into it, which the same build's symbols name.
    private static func place(_ address: UInt) -> String {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0, let base = info.dli_fbase, let path = info.dli_fname else {
            return "?+" + String(address, radix: 16)
        }
        let name = String(cString: path).split(separator: "/").last.map(String.init) ?? "?"
        return name + "+" + String(address &- UInt(bitPattern: base), radix: 16)
    }

    static let log: @Sendable (String, Double, Facts) -> Void = { event, waited, facts in
        Diagnostics.record(event, ["ms": String(Int((waited * 1000).rounded())), "menu_open": facts.menuOpen ? "yes" : "no",
                                   "window_open": facts.windowOpen ? "yes" : "no", "page": facts.page,
                                   "runs": String(facts.runs), "accounts": String(facts.accounts)])
    }
    /// One reading over as many lines as its frames need: a log value is one bounded word.
    static let logStack: @Sendable (Int, Stack) -> Void = { reading, stack in
        let lines = stride(from: 0, to: stack.frames.count, by: 4).map { Array(stack.frames[$0..<min($0 + 4, stack.frames.count)]) }
        for (index, frames) in lines.enumerated() {
            Diagnostics.record("ui.stack", ["reading": String(reading), "depth": String(stack.depth), "part": "\(index + 1)/\(lines.count)",
                                            "frames": frames.joined(separator: ",")])
        }
    }
}
