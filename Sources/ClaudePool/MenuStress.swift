#if DEBUG
import AppKit
import PoolCore

/// Debug builds only, with `--demo`: `POOL_MENU_STRESS=<seconds>` fills the pool with working Pro
/// accounts, opens the menu bar panel and changes run states, runs, readings and the clock many times
/// a second, as a workflow does. When the main thread stops answering, where it is goes to
/// `POOL_MENU_STRESS_SAMPLE` and the process ends with status 86.
@MainActor
enum MenuStress {
    private struct Dice: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
    private final class Pulse: @unchecked Sendable {
        private let lock = NSLock()
        private var at = DispatchTime.now()
        private var worst = 0.0
        func beat() {
            lock.withLock {
                let now = DispatchTime.now()
                worst = max(worst, Double(now.uptimeNanoseconds &- at.uptimeNanoseconds) / 1_000_000_000)
                at = now
            }
        }
        var silence: Double { lock.withLock { Double(DispatchTime.now().uptimeNanoseconds &- at.uptimeNanoseconds) / 1_000_000_000 } }
        var longest: Double { lock.withLock { worst } }
    }
    private static var dice = Dice(state: 1)
    private static var timers: [Timer] = []
    private static var opened = 0

    static func startIfAsked(_ model: PoolAppModel) {
        let environment = ProcessInfo.processInfo.environment
        guard model.demo, let seconds = environment["POOL_MENU_STRESS"].flatMap(Double.init) else { return }
        let count = environment["POOL_MENU_STRESS_ACCOUNTS"].flatMap(Int.init) ?? 11
        let rate = environment["POOL_MENU_STRESS_RATE"].flatMap(Double.init) ?? 30
        let sample = environment["POOL_MENU_STRESS_SAMPLE"] ?? NSTemporaryDirectory() + "menu-stress-hang.txt"
        dice = Dice(state: environment["POOL_MENU_STRESS_SEED"].flatMap(UInt64.init) ?? 1)
        fill(model, accounts: count)
        let pulse = Pulse()
        let pid = ProcessInfo.processInfo.processIdentifier
        let watcher = Thread {
            while true {
                if pulse.silence > 4 {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                    process.arguments = [String(pid), "2", "-file", sample]
                    try? process.run(); process.waitUntilExit()
                    say("menu.stress outcome=hung accounts=\(count) rate=\(Int(rate))")
                    exit(86)
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        watcher.start()
        add(Timer(timeInterval: 1 / rate, repeats: true) { _ in
            MainActor.assumeIsolated { change(model); pulse.beat() }
        })
        add(Timer(timeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { openPanel() } })
        add(Timer(timeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated {
                say("menu.stress outcome=answered accounts=\(count) rate=\(Int(rate)) opened=\(opened) worst_ms=\(Int(pulse.longest * 1000))")
                exit(0)
            }
        })
    }
    private static func add(_ timer: Timer) { RunLoop.main.add(timer, forMode: .common); timers.append(timer) }
    private nonisolated static func say(_ line: String) { FileHandle.standardError.write(Data((line + "\n").utf8)) }

    private static func fill(_ model: PoolAppModel, accounts count: Int) {
        let date = Date()
        model.referenceDate = date
        model.snapshot.accounts = PoolAppModel.demoAccounts(count, at: date).enumerated().map { index, account in
            var account = account
            account.plan = "Pro"
            account.windows = [
                .init(id: "five_hour", usedPercent: Double(index * 7 % 90), observedAt: date.addingTimeInterval(-60), resetsAt: date.addingTimeInterval(7200 + Double(index) * 300)),
                .init(id: "seven_day", usedPercent: Double(index * 5 % 80), observedAt: date.addingTimeInterval(-60), resetsAt: date.addingTimeInterval(172_800))]
            return account
        }
        model.snapshot.sessions = model.snapshot.accounts.enumerated().map { index, account in
            .init(id: UUID(), accountID: account.id, name: "Claude session", model: "Opus", state: index % 2 == 0 ? .running : .waiting,
                  startedAt: date.addingTimeInterval(Double(-index) * 30), conversation: "stress-\(index % 5)")
        }
        model.quotaRefresh = [:]; model.warmUp = [:]
    }

    private static func change(_ model: PoolAppModel) {
        let roll = Int.random(in: 0..<100, using: &dice)
        let accounts = model.snapshot.accounts
        guard !accounts.isEmpty else { return }
        // The clock moves with the changes, as the menu bar's own does every twenty seconds.
        if roll % 10 == 0 { model.referenceDate = Date() }
        switch roll {
        case 0..<70:
            guard !model.snapshot.sessions.isEmpty else { return }
            let index = Int.random(in: 0..<model.snapshot.sessions.count, using: &dice)
            model.snapshot.sessions[index].state = model.snapshot.sessions[index].state == .running ? .waiting : .running
        case 70..<80:
            guard model.snapshot.sessions.count < accounts.count * 3 else { return }
            let account = accounts[Int.random(in: 0..<accounts.count, using: &dice)]
            model.snapshot.sessions.append(.init(id: UUID(), accountID: account.id, name: "Claude session", model: "Sonnet", state: .starting,
                                                 startedAt: Date(), conversation: "stress-\(Int.random(in: 0..<9, using: &dice))"))
        case 80..<90:
            guard model.snapshot.sessions.count > 1 else { return }
            model.snapshot.sessions.remove(at: Int.random(in: 0..<model.snapshot.sessions.count, using: &dice))
        case 90..<96:
            let index = Int.random(in: 0..<accounts.count, using: &dice)
            guard !model.snapshot.accounts[index].windows.isEmpty else { return }
            model.snapshot.accounts[index].windows[0].usedPercent = Double(Int.random(in: 0...100, using: &dice))
            model.snapshot.accounts[index].windows[0].observedAt = Date()
        default:
            let id = accounts[Int.random(in: 0..<accounts.count, using: &dice)].id
            model.quotaRefresh[id] = .init(phase: model.quotaRefresh[id]?.phase == .refreshing ? .idle : .refreshing, updatedAt: Date())
        }
        model.generatingSessionIDs = Set(model.snapshot.sessions.filter { $0.state == .running }.map(\.id))
    }

    /// Opens the menu bar panel when it is not open, by the click a person makes on the menu bar item.
    private static func openPanel() {
        let windows = NSApp.windows
        if windows.contains(where: { $0.isVisible && $0.className.contains("MenuBarExtra") }) { return }
        for window in windows where window.className.contains("StatusBar") {
            if let button = button(in: window.contentView) { opened += 1; button.performClick(nil); return }
        }
        say("menu.stress outcome=no_item windows=" + windows.map(\.className).joined(separator: ","))
    }
    private static func button(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for child in view.subviews { if let found = button(in: child) { return found } }
        return nil
    }
}
#endif
