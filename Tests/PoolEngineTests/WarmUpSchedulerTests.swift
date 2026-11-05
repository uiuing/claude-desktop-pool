import Foundation
import XCTest
import PoolCore
import PoolRuntime
@testable import PoolEngine

final class WarmUpSchedulerTests: XCTestCase {
    func testDueWarmUpGoesOnceAndAFailureIsTriedAgainLater() async throws {
        let clock = WarmUpClock(Date(timeIntervalSince1970: 1_800_000_000))
        let sends = WarmUpSends(), updates = WarmUpUpdates()
        let account = idleAccount(at: clock.now)
        let scheduler = WarmUpScheduler(workspace: nil, now: { clock.now }, send: { try await sends.send($0) },
                                        update: { updates.add($0) })
        await scheduler.setAccounts([account])
        await scheduler.setPreferences(.init(onReset: .all))
        await scheduler.look()
        var sent = await sends.accounts
        XCTAssertTrue(sent.isEmpty, "Nothing goes while the Mac is asleep or offline")

        await scheduler.setAvailable(true)
        await sends.failNext()
        await scheduler.look()
        sent = await sends.accounts
        XCTAssertEqual(sent, [account.id])
        XCTAssertEqual(updates.all, [.sending(account.id), .failed(account.id, reason: "The local Claude session stopped responding. Check it in Claude Pool.")])
        await scheduler.look()
        sent = await sends.accounts
        XCTAssertEqual(sent.count, 1, "A failed try waits before the next")

        clock.advance(901)
        await scheduler.look()
        sent = await sends.accounts
        XCTAssertEqual(sent.count, 2)
        let state = await scheduler.state(account.id)
        XCTAssertEqual(state?.tries, 2)
        XCTAssertEqual(state?.warmedAt, clock.now)
        XCTAssertEqual(updates.all.last, .sent(account.id, at: clock.now))

        // Once the limit runs, the stretch is over; its next reset begins a new one.
        var running = account
        running.windows = [QuotaWindow(id: "five_hour", usedPercent: 1, observedAt: clock.now, resetsAt: clock.now.addingTimeInterval(18000))]
        await scheduler.setAccounts([running])
        await scheduler.look()
        let ended = await scheduler.state(account.id)
        XCTAssertNil(ended?.since)
        XCTAssertEqual(ended?.tries, 0)
        sent = await sends.accounts
        XCTAssertEqual(sent.count, 2)
    }

    func testStartingNowIgnoresSettingsButNeverAnAccountThatCannotServe() async throws {
        let clock = WarmUpClock(Date(timeIntervalSince1970: 1_800_000_000))
        let sends = WarmUpSends()
        let usable = idleAccount(at: clock.now)
        var limited = idleAccount(at: clock.now)
        limited.windows = [QuotaWindow(id: "five_hour", usedPercent: 100, observedAt: clock.now, resetsAt: clock.now.addingTimeInterval(3600))]
        let scheduler = WarmUpScheduler(workspace: nil, now: { clock.now }, send: { try await sends.send($0) })
        await scheduler.setAccounts([usable, limited])
        await scheduler.setPreferences(.init(onReset: .off))
        try await scheduler.warmNow(usable.id)
        // Its reading has not caught up yet; the looks do not send another for it meanwhile.
        await scheduler.setPreferences(.init(onReset: .all)); await scheduler.setAvailable(true)
        await scheduler.look()
        do { try await scheduler.warmNow(limited.id); XCTFail("An account at its limit was warmed") }
        catch { XCTAssertEqual(error as? BridgeFailure, .unavailable) }
        let sent = await sends.accounts
        XCTAssertEqual(sent, [usable.id])
    }

    func testWhatWasSentSurvivesARestart() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/warm-up-fixtures/\(UUID().uuidString)")
        let workspace = OwnedWorkspace(root: root); try workspace.prepare()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        // A reset with a fraction of a second: the stretch must be recognised after the restart.
        let clock = WarmUpClock(Date(timeIntervalSince1970: 1_800_000_000.375))
        let sends = WarmUpSends()
        let account = idleAccount(at: clock.now)
        let first = WarmUpScheduler(workspace: workspace, now: { clock.now }, send: { try await sends.send($0) })
        await first.setAccounts([account]); await first.setPreferences(.init(onReset: .all)); await first.setAvailable(true)
        await first.look()
        let second = WarmUpScheduler(workspace: workspace, now: { clock.now }, send: { try await sends.send($0) })
        await second.setAccounts([account]); await second.setPreferences(.init(onReset: .all)); await second.setAvailable(true)
        await second.look()
        let sent = await sends.accounts
        XCTAssertEqual(sent.count, 1, "A restart does not repeat a warm-up that is waiting to be tried again")
        let restored = await second.state(account.id)
        XCTAssertEqual(restored?.warmedAt, clock.now)
    }

    private func idleAccount(at now: Date) -> PoolAccount {
        PoolAccount(email: "warm@example.invalid", plan: "Pro", state: .ready, windows: [
            QuotaWindow(id: "five_hour", usedPercent: 30, observedAt: now.addingTimeInterval(-20000), resetsAt: now.addingTimeInterval(-600)),
            QuotaWindow(id: "seven_day", usedPercent: 20, observedAt: now.addingTimeInterval(-600), resetsAt: now.addingTimeInterval(86400))])
    }
}

private final class WarmUpClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    var now: Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); date = date.addingTimeInterval(seconds); lock.unlock() }
}

private actor WarmUpSends {
    private(set) var accounts: [UUID] = []
    private var failing = false
    func failNext() { failing = true }
    func send(_ account: PoolAccount) throws {
        accounts.append(account.id)
        if failing { failing = false; throw BridgeFailure.transport }
    }
}

private final class WarmUpUpdates: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [WarmUpUpdate] = []
    func add(_ update: WarmUpUpdate) { lock.lock(); stored.append(update); lock.unlock() }
    var all: [WarmUpUpdate] { lock.lock(); defer { lock.unlock() }; return stored }
}
