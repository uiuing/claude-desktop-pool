import Foundation

/// The account identity and subscription under which an asynchronous observation was produced.
public struct AccountScope: Equatable, Sendable {
    public let accountID: UUID
    public let email: String?
    public let identityFingerprint: String?
    public let plan: String?

    public init(_ account: PoolAccount) {
        accountID = account.id
        email = account.email?.lowercased()
        identityFingerprint = account.identityFingerprint
        plan = account.plan
    }

    public func matches(_ account: PoolAccount) -> Bool { self == AccountScope(account) }

    /// Run inside the serialized library mutation, after any preceding account changes.
    @discardableResult
    public func applyObservation(to accounts: inout [PoolAccount], _ update: (inout PoolAccount) -> Void) -> Bool {
        guard let index = accounts.firstIndex(where: matches),
              [.ready, .limited, .needsAttention].contains(accounts[index].state) else { return false }
        update(&accounts[index])
        return true
    }
}
