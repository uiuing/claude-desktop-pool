import Observation
import XCTest
import SwiftUI
import ViewInspector
import PoolCore
@testable import ClaudePool

/// The menu panel froze with many accounts while many runs worked: every routed request and every
/// run's state change had the panel sized again, and sizing it measured every account's card.
@MainActor
final class MenuPanelLoadTests: XCTestCase {
    /// A pool of `count` read accounts with runs on most of them.
    private func pool(_ count: Int) -> PoolAppModel {
        let model = PoolAppModel.demoModel(language: "en")
        let date = model.now
        model.snapshot.accounts = PoolAppModel.demoAccounts(count, at: date).enumerated().map { index, account in
            var account = account
            account.plan = "Pro"
            account.windows = [
                .init(id: "five_hour", usedPercent: Double(index * 5 % 90), observedAt: date.addingTimeInterval(-60), resetsAt: date.addingTimeInterval(7200)),
                .init(id: "seven_day", usedPercent: Double(index * 7 % 80), observedAt: date.addingTimeInterval(-60), resetsAt: date.addingTimeInterval(172_800))]
            return account
        }
        model.snapshot.sessions = model.snapshot.accounts.prefix(max(1, count - 2)).enumerated().map { index, account in
            .init(id: UUID(), accountID: account.id, name: "Claude session", model: "Opus", state: index % 2 == 0 ? .running : .waiting,
                  startedAt: date.addingTimeInterval(Double(-index) * 30), conversation: "load-\(index % 6)")
        }
        return model
    }
    /// Seconds to take `changes` changes in, each followed by the sizing a menu bar window asks for: the
    /// fastest of `rounds` rounds, as another process taking the machine for a moment slows one round,
    /// not all of them.
    private func cost(of model: PoolAppModel, rounds: Int = 3, changes: Int, change: (PoolAppModel, Int) -> Void) -> TimeInterval {
        let host = NSHostingView(rootView: MenuPanel(model: model))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 340, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        _ = host.fittingSize
        var fastest = TimeInterval.infinity
        for round in 0..<rounds {
            let began = Date()
            for step in 0..<changes {
                change(model, round * changes + step)
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.001))
                _ = host.fittingSize
                host.layoutSubtreeIfNeeded()
            }
            fastest = min(fastest, Date().timeIntervalSince(began))
        }
        window.contentView = nil
        return fastest
    }
    private func flip(_ model: PoolAppModel, _ step: Int) {
        let index = step % model.snapshot.sessions.count
        model.snapshot.sessions[index].state = model.snapshot.sessions[index].state == .running ? .waiting : .running
    }

    private final class Fired: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var happened: Bool { lock.withLock { value } }
    }
    /// Reads the panel as SwiftUI would, every view in it, and says when anything it read changes.
    private func watchPanel(_ model: PoolAppModel) -> (texts: Int, fired: Fired) {
        let fired = Fired()
        let texts = withObservationTracking {
            (try? MenuPanel(model: model).inspect().findAll(ViewType.Text.self).count) ?? 0
        } onChange: { fired.set() }
        return (texts, fired)
    }

    /// A routed request changes nothing the panel shows, so the panel is not worked out again for it.
    /// Read from what the panel's views observe, not timed, so a busy machine cannot fail or pass it.
    func testARoutedRequestDoesNotSizeThePanelAgain() {
        let model = pool(17)
        let account = model.snapshot.accounts[0].id
        let routed = watchPanel(model)
        XCTAssertGreaterThan(routed.texts, 0, "The panel must have been read")
        model.recordRoute(.init(accountID: account, model: "Opus", reason: .headroom, strategy: .mostHeadroom))
        XCTAssertFalse(routed.fired.happened, "A routed request must not have the panel sized again")
        // What the panel does show still reaches it.
        let changed = watchPanel(model)
        flip(model, 0)
        XCTAssertTrue(changed.fired.happened, "A run's change of state must reach the panel")
    }

    /// A run's change of state reaches the panel but no account's card: a card reads nothing of the whole
    /// snapshot, and what the panel hands it stays the same, so SwiftUI leaves it as it was. Before, every
    /// card was worked out and laid out again at each change, and forty accounts cost more than twice what twelve did.
    /// Read from what the cards observe and are given, not timed.
    func testARunsChangeOfStateReachesNoAccountCard() {
        let model = pool(17)
        let before = MenuPanel.cards(model, accounts: model.rankedAccounts, showsPlan: true)
        let fired = Fired()
        let texts = withObservationTracking {
            before.reduce(0) { $0 + ((try? $1.inspect().findAll(ViewType.Text.self).count) ?? 0) }
        } onChange: { fired.set() }
        XCTAssertGreaterThan(texts, before.count, "Every card must have been read")
        flip(model, 0)
        XCTAssertFalse(fired.happened, "A run's change of state must not have the cards worked out again")
        XCTAssertTrue(MenuPanel.cards(model, accounts: model.rankedAccounts, showsPlan: true) == before,
                      "Nor may it change what the panel hands a card")
        // What a card does show still reaches it.
        model.preferences.maskEmail.toggle()
        XCTAssertTrue(fired.happened, "A change a card shows must reach it")
    }

    /// Sizing the panel does not measure every card: a pool of forty accounts costs about what one of
    /// twelve does. Measured against itself, so a slower machine does not fail it.
    func testSizingDoesNotGrowWithTheAccounts() {
        let few = cost(of: pool(12), changes: 40, change: flip)
        let many = cost(of: pool(40), changes: 40, change: flip)
        print("menu.load accounts12=\(Int(few * 1000))ms accounts40=\(Int(many * 1000))ms per 40")
        XCTAssertLessThan(many, few * 2 + 0.25, "The panel's cost must not grow with the number of accounts")
    }
}
