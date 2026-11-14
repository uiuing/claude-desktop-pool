import Foundation
import PoolCore

enum AccountListOrder: String, CaseIterable {
    case ranked = "Default order"
    case expirySoonest = "Expiry · earliest first"
    case expiryLatest = "Expiry · latest first"
    case sessionMost = "5-hour remaining · most first"
    case sessionLeast = "5-hour remaining · least first"
    case weekMost = "Weekly remaining · most first"
    case weekLeast = "Weekly remaining · least first"
    case name = "Account name"
    case newest = "Date added · newest first"
}

enum AccountListPlan: Hashable {
    case all
    case plan(String?)

    var title: String {
        switch self {
        case .all: "All plans"
        case .plan(let name): name ?? "Plan not reported"
        }
    }
}

enum AccountListStatus: String, CaseIterable {
    case all = "All statuses"
    case usable = "Usable"
    case unread = "Quota unread"
    case limited = "At limit"
    case unavailable = "Unavailable"

    func matches(_ account: PoolAccount, at now: Date) -> Bool {
        guard self != .all else { return true }
        return switch account.standing(at: now) {
        case .usable: self == .usable
        case .unread: self == .unread
        case .limited, .weekUsed: self == .limited
        case .unavailable: self == .unavailable
        }
    }
}

enum AccountListExpiry: String, CaseIterable {
    case all = "Any expiry"
    case soon = "Expiring within 3 days"
    case expired = "Expired"
    case unset = "No expiry set"

    static let soonInterval: TimeInterval = 3 * 86_400

    func matches(_ date: Date?, at now: Date) -> Bool {
        switch self {
        case .all: true
        case .soon: date.map { $0 > now && $0.timeIntervalSince(now) <= Self.soonInterval } ?? false
        case .expired: date.map { $0 <= now } ?? false
        case .unset: date == nil
        }
    }
}

struct AccountListFilters {
    var search = ""
    var plan = AccountListPlan.all
    var status = AccountListStatus.all
    var expiry = AccountListExpiry.all

    var query: String { search.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isActive: Bool { !query.isEmpty || plan != .all || status != .all || expiry != .all }
}

extension PoolAppModel {
    var accountListPlanOptions: [AccountListPlan] {
        var plans = Set(snapshot.accounts.map(\.plan))
        if case .plan(let selected) = accountListFilters.plan { plans.insert(selected) }
        let reported = plans.compactMap { $0 }.sorted {
            t($0).localizedStandardCompare(t($1)) == .orderedAscending
        }
        return [.all] + reported.map { .plan($0) } + (plans.contains(nil) ? [.plan(nil)] : [])
    }

    var listedAccounts: [PoolAccount] {
        let filters = accountListFilters
        let date = now
        let query = filters.query
        let accounts = rankedAccounts.filter { account in
            (filters.plan == .all || filters.plan == .plan(account.plan)) &&
                filters.status.matches(account, at: date) &&
                filters.expiry.matches(account.expiresAt, at: date) &&
                (query.isEmpty || accountName(account).localizedStandardContains(query))
        }

        switch accountListOrder {
        case .ranked: return accounts
        case .expirySoonest: return ordered(accounts, by: \.expiresAt, ascending: true)
        case .expiryLatest: return ordered(accounts, by: \.expiresAt, ascending: false)
        case .sessionMost, .sessionLeast:
            return ordered(accounts, by: { remaining($0, window: "five_hour") }, ascending: accountListOrder == .sessionLeast)
        case .weekMost, .weekLeast:
            return ordered(accounts, by: { remaining($0, window: "seven_day") }, ascending: accountListOrder == .weekLeast)
        case .name:
            return accounts.map { ($0, accountName($0)) }.sorted {
                $0.1.localizedStandardCompare($1.1) == .orderedAscending
            }.map(\.0)
        case .newest: return accounts.sorted { $0.createdAt > $1.createdAt }
        }
    }

    // Missing values come last in either direction. Swift's stable sort keeps the default order for ties.
    private func ordered<Value: Comparable>(_ accounts: [PoolAccount], by value: (PoolAccount) -> Value?,
                                            ascending: Bool) -> [PoolAccount] {
        accounts.map { ($0, value($0)) }.sorted { left, right in
            guard let a = left.1 else { return false }
            guard let b = right.1 else { return true }
            return ascending ? a < b : a > b
        }.map(\.0)
    }
}
