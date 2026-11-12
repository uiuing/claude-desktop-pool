import Foundation
import PoolCore
@preconcurrency import UserNotifications

/// Whether the pool as a whole is at its limit, and telling the person when that begins and ends.
/// A pool is at its limit when no account can take a new conversation and at least one that is signed
/// in is held only by a limit; a pool with no usable account at all is not (it needs the person, and
/// the app says so elsewhere). Each change is logged (`pool.limit`) and, in a packaged app, told as a
/// macOS notification: when the first account is back, then that one is.
struct PoolLimitNotice {
    enum State: String, Equatable { case serving, limited }
    private(set) var state = State.serving
    /// The earliest reset told with the last "at its limit", so a later one is not told again.
    private(set) var back: Date?

    /// What the accounts say now: limited with when the first is back (the earliest, nil when unknown), else serving.
    static func assess(_ accounts: [PoolAccount], policy: RoutingPolicy, now: Date) -> (state: State, back: Date?) {
        guard PoolRouting.candidates(accounts, model: PoolRouting.anyModel, now: now, policy: policy).isEmpty else { return (.serving, nil) }
        var limited = false, back: [Date] = []
        for account in accounts where account.email?.isEmpty == false && [.ready, .limited].contains(account.effectiveState(at: now)) {
            guard account.effectiveState(at: now) == .limited ||
                  PoolRouting.assessment(account, model: PoolRouting.anyModel, now: now).state == .exhausted else { continue }
            limited = true
            if case .scheduled(let at) = QuotaRecovery.account(account, model: PoolRouting.anyModel, now: now), at > now { back.append(at) }
        }
        return limited ? (.limited, back.min()) : (.serving, nil)
    }

    /// Takes the accounts in; the change to tell, if there is one.
    mutating func update(_ accounts: [PoolAccount], policy: RoutingPolicy, now: Date) -> (state: State, back: Date?)? {
        let (next, at) = Self.assess(accounts, policy: policy, now: now)
        guard next != state else { return nil }
        state = next; back = at
        return (next, at)
    }

    /// A macOS notification for a change; only a packaged app can post one.
    static func post(_ change: (state: State, back: Date?), language: String, clock: (Date) -> String) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let content = UNMutableNotificationContent()
        switch change.state {
        case .limited:
            content.title = L10n.tr("Every account is at its limit.", language: language, arguments: [])
            if let back = change.back { content.body = L10n.tr("The first account is back at {0}.", language: language, arguments: [clock(back)]) }
        case .serving:
            content.title = L10n.tr("An account is available again.", language: language, arguments: [])
            content.body = L10n.tr("Conversations waiting for a limit can go on.", language: language, arguments: [])
        }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            // One notification stands for the pool's limit: the newer replaces the older.
            center.add(UNNotificationRequest(identifier: "pool.limit", content: content, trigger: nil))
        }
    }
}
