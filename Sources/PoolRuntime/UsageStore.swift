import Foundation
import PoolCore

/// `usage.json` in the app's own workspace: token counts by day, account id and model, nothing else.
public actor UsageStore {
    public let workspace: OwnedWorkspace
    public init(workspace: OwnedWorkspace) { self.workspace = workspace }
    private var url: URL { workspace.root.appendingPathComponent("usage.json") }
    /// A hundred accounts using four models every day for `UsageLedger.keptDays` stays well under this.
    private static let limit = 48 * 1024 * 1024

    /// A missing file is an empty ledger; one this version cannot read starts over rather than
    /// blocking the app, since it holds only statistics.
    public func load() -> UsageLedger {
        guard let data = try? workspace.read(url, limit: Self.limit),
              var ledger = try? JSONDecoder().decode(UsageLedger.self, from: data), ledger.version == 2 else { return UsageLedger() }
        ledger.compact(now: Date())
        return ledger
    }

    public func save(_ ledger: UsageLedger) throws {
        try workspace.prepare()
        try workspace.write(JSONEncoder().encode(ledger), to: url, limit: Self.limit)
    }
}
