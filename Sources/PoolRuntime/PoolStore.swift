import Foundation
import PoolCore

public actor PoolStore {
    public let workspace: OwnedWorkspace
    public init(workspace: OwnedWorkspace) { self.workspace = workspace }

    public func load() throws -> PoolLibrary {
        try workspace.prepare()
        let data: Data
        do { data = try workspace.read(workspace.root.appendingPathComponent("library.json")) }
        catch RuntimeError.missingFile { return PoolLibrary() }
        var library: PoolLibrary
        do { library = try JSONDecoder().decode(PoolLibrary.self, from: data) }
        catch { throw RuntimeError.invalidLibrary }
        guard library.version == 1, ["system", "light", "dark"].contains(library.preferences.appearance), library.preferences.routingPolicy.isValid, library.preferences.quotaRefresh.isValid,
              Set(library.accounts.map(\.id)).count == library.accounts.count else {
            throw RuntimeError.invalidLibrary
        }
        library.liftModelCooldowns(at: Date())
        return library
    }

    public func save(_ library: PoolLibrary) throws {
        guard library.version == 1, ["system", "light", "dark"].contains(library.preferences.appearance), library.preferences.routingPolicy.isValid, library.preferences.quotaRefresh.isValid,
              Set(library.accounts.map(\.id)).count == library.accounts.count else {
            throw RuntimeError.invalidLibrary
        }
        try workspace.prepare()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try workspace.write(encoder.encode(library), to: workspace.root.appendingPathComponent("library.json"))
    }
}
