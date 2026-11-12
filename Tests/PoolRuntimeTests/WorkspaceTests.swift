import Foundation
import XCTest
import PoolCore
@testable import PoolRuntime

final class WorkspaceTests: XCTestCase {
    private func fixture() throws -> URL {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/runtime-fixtures/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }

    func testOnlyOneCopyOfTheAppHoldsTheWorkspace() throws {
        let workspace = OwnedWorkspace(root: try fixture().appendingPathComponent("app"))
        try workspace.prepare()
        var first: OwnedWorkspace.Claim? = try workspace.claim()
        XCTAssertThrowsError(try workspace.claim()) { XCTAssertEqual($0 as? RuntimeError, .workspaceInUse) }
        XCTAssertNotNil(first)
        first = nil
        XCTAssertNoThrow(try workspace.claim())
    }

    func testStablePrivateDirectoriesAndAtomicReplacement() throws {
        let base = try fixture(), workspace = OwnedWorkspace(root: base.appendingPathComponent("app"))
        try workspace.prepare()
        let id = UUID(), account = try workspace.accountDirectory(id)
        XCTAssertEqual(try workspace.accountDirectory(id), account)
        XCTAssertNotEqual(try workspace.accountDirectory(UUID()), account)
        let file = try workspace.runDirectory(UUID()).appendingPathComponent("events/message.json")
        try workspace.write(Data("first".utf8), to: file)
        try workspace.write(Data("second".utf8), to: file)
        XCTAssertEqual(try workspace.read(file), Data("second".utf8))
        let rootAttributes = try FileManager.default.attributesOfItem(atPath: workspace.root.path)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((rootAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try workspace.entries(in: file.deletingLastPathComponent()).count, 1)
    }

    func testRefusesToAdoptUnrelatedDirectory() throws {
        let base = try fixture(), file = base.appendingPathComponent("existing.txt")
        try Data("keep".utf8).write(to: file)
        XCTAssertThrowsError(try OwnedWorkspace(root: base).prepare())
        XCTAssertEqual(try Data(contentsOf: file), Data("keep".utf8))
    }

    func testRefusesRootAncestorAndFileSymlinksWithoutTouchingDestination() throws {
        let base = try fixture(), target = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let linkedRoot = base.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: target)
        XCTAssertThrowsError(try OwnedWorkspace(root: linkedRoot).prepare())
        let workspace = OwnedWorkspace(root: base.appendingPathComponent("app"))
        try workspace.prepare()
        let run = try workspace.runDirectory(UUID()), link = run.appendingPathComponent("link")
        let original = target.appendingPathComponent("original")
        try Data("keep".utf8).write(to: original)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        XCTAssertThrowsError(try workspace.read(link))
        XCTAssertThrowsError(try workspace.write(Data("replace".utf8), to: link))
        let directoryLink = run.appendingPathComponent("directory")
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: target)
        XCTAssertThrowsError(try workspace.write(Data(), to: directoryLink.appendingPathComponent("new")))
        XCTAssertEqual(try Data(contentsOf: original), Data("keep".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.appendingPathComponent("new").path))
    }

    func testBoundsReadsAndRejectsEscapes() throws {
        let base = try fixture(), workspace = OwnedWorkspace(root: base.appendingPathComponent("app"))
        try workspace.prepare()
        let file = workspace.root.appendingPathComponent("small")
        try workspace.write(Data(repeating: 1, count: 8), to: file)
        XCTAssertThrowsError(try workspace.read(file, limit: 7)) { XCTAssertEqual($0 as? RuntimeError, .oversizedInput) }
        XCTAssertThrowsError(try workspace.write(Data(), to: base.appendingPathComponent("outside")))
        XCTAssertThrowsError(try workspace.remove(workspace.root.appendingPathComponent(".claude-pool-workspace")))
        try workspace.remove(file)
        XCTAssertThrowsError(try workspace.read(file)) { XCTAssertEqual($0 as? RuntimeError, .missingFile) }
    }

    func testStorePreservesCorruptLibrary() async throws {
        let workspace = OwnedWorkspace(root: try fixture().appendingPathComponent("app"))
        let store = PoolStore(workspace: workspace)
        let empty = try await store.load()
        XCTAssertTrue(empty.accounts.isEmpty)
        let library = PoolLibrary(accounts: [PoolAccount(email: "mi•••ella@example.com", state: .ready)])
        try await store.save(library)
        let loaded = try await store.load()
        XCTAssertEqual(loaded, library)
        let file = workspace.root.appendingPathComponent("library.json"), broken = Data("{bad json".utf8)
        try workspace.write(broken, to: file)
        do { _ = try await store.load(); XCTFail("Corruption must not become an empty library") }
        catch { XCTAssertEqual(error as? RuntimeError, .invalidLibrary) }
        XCTAssertEqual(try workspace.read(file), broken)
    }

    private func run(_ id: UUID, in workspace: OwnedWorkspace) throws -> URL {
        let directory = try workspace.runDirectory(id)
        try workspace.write(JSONSerialization.data(withJSONObject: ["session_id": id.uuidString]),
                            to: directory.appendingPathComponent("run.json"))
        return directory
    }

    func testCompletedRunCleanupRemovesOnlyItsGeneratedFiles() throws {
        let workspace = OwnedWorkspace(root: try fixture().appendingPathComponent("app"))
        try workspace.prepare()
        let id = UUID(), directory = try run(id, in: workspace)
        let other = try run(UUID(), in: workspace)
        let account = try workspace.accountDirectory(UUID()).appendingPathComponent("native-owned")
        try workspace.write(Data("keep".utf8), to: account)
        for name in ["tools.json", "tools-listed.json", "settings.json", "mcp.json", "instructions.txt", "cancelled",
                     "events/1790000000000000-\(UUID().uuidString).json", "results/\(UUID().uuidString).json", "results/toolu_01AbC-d_9.json",
                     "work/image-\(UUID().uuidString).png", ".\(UUID().uuidString).tmp", "events/.pool-\(UUID().uuidString).tmp"] {
            try workspace.write(Data("generated".utf8), to: directory.appendingPathComponent(name))
        }
        try workspace.removeRun(id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        XCTAssertEqual(try workspace.read(account), Data("keep".utf8))
        XCTAssertNoThrow(try workspace.removeRun(id))
    }

    func testRunCleanupPreflightPreservesOutsideSymlinkAndOriginalFiles() throws {
        let base = try fixture(), workspace = OwnedWorkspace(root: base.appendingPathComponent("app"))
        try workspace.prepare()
        let id = UUID(), directory = try run(id, in: workspace)
        let instructions = directory.appendingPathComponent("instructions.txt")
        try workspace.write(Data("preserve pending cleanup".utf8), to: instructions)
        let outside = base.appendingPathComponent("outside")
        try Data("untouched".utf8).write(to: outside)
        let events = directory.appendingPathComponent("events")
        try workspace.createDirectory(at: events)
        let link = events.appendingPathComponent("1790000000000000-\(UUID().uuidString).json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try workspace.removeRun(id)) { XCTAssertEqual($0 as? RuntimeError, .unsafePath) }
        XCTAssertEqual(try Data(contentsOf: outside), Data("untouched".utf8))
        XCTAssertEqual(try workspace.read(instructions), Data("preserve pending cleanup".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("run.json").path))
        try FileManager.default.removeItem(at: link)
        try workspace.createDirectory(at: events.appendingPathComponent("unexpected"))
        XCTAssertThrowsError(try workspace.removeRun(id)) { XCTAssertEqual($0 as? RuntimeError, .unsafePath) }
        XCTAssertEqual(try workspace.read(instructions), Data("preserve pending cleanup".utf8))
    }

    func testRunCleanupRejectsWrongIdentityAndPreservesUnknownWork() throws {
        let workspace = OwnedWorkspace(root: try fixture().appendingPathComponent("app"))
        try workspace.prepare()
        let id = UUID(), directory = try run(id, in: workspace)
        let marker = directory.appendingPathComponent("run.json")
        try workspace.write(JSONSerialization.data(withJSONObject: ["session_id": UUID().uuidString]), to: marker)
        XCTAssertThrowsError(try workspace.removeRun(id)) { XCTAssertEqual($0 as? RuntimeError, .unsafePath) }
        _ = try run(id, in: workspace)
        let oddResult = directory.appendingPathComponent("results/call.notes.json")
        try workspace.write(Data("keep".utf8), to: oddResult)
        XCTAssertThrowsError(try workspace.removeRun(id)) { XCTAssertEqual($0 as? RuntimeError, .unsafePath) }
        try workspace.remove(oddResult)
        let unowned = directory.appendingPathComponent("work/notes.txt")
        try workspace.write(Data("keep notes".utf8), to: unowned)
        XCTAssertThrowsError(try workspace.removeRun(id)) { XCTAssertEqual($0 as? RuntimeError, .unsafePath) }
        XCTAssertEqual(try workspace.read(unowned), Data("keep notes".utf8))
        try workspace.remove(unowned)
        try workspace.removeRun(id)
        let empty = try workspace.runDirectory(id)
        try workspace.removeRun(id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: empty.path))
    }

    func testStaleRunsAndOrphanAccountsGoWithoutFollowingLinks() throws {
        let base = try fixture(), workspace = OwnedWorkspace(root: base.appendingPathComponent("app"))
        try workspace.prepare()
        XCTAssertEqual(workspace.removeStaleRuns(keeping: []), 0)
        let live = UUID(), crashed = UUID()
        _ = try run(live, in: workspace)
        let leftover = try run(crashed, in: workspace)
        try workspace.write(Data("anything".utf8), to: leftover.appendingPathComponent("work/notes/deep.txt"))
        let runs = base.appendingPathComponent("app/runs")
        try workspace.write(Data("keep".utf8), to: runs.appendingPathComponent("not-a-run/file"))
        let outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("untouched".utf8).write(to: outside.appendingPathComponent("file"))
        let linkedRun = runs.appendingPathComponent(UUID().uuidString.lowercased())
        try FileManager.default.createSymbolicLink(at: linkedRun, withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: leftover.appendingPathComponent("work/link"), withDestinationURL: outside)
        XCTAssertEqual(workspace.removeStaleRuns(keeping: [live]), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: runs.appendingPathComponent(live.uuidString.lowercased()).path))
        XCTAssertEqual(try workspace.read(runs.appendingPathComponent("not-a-run/file")), Data("keep".utf8))
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: linkedRun.path))
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("file")), Data("untouched".utf8))

        let kept = UUID(), orphan = UUID()
        try workspace.write(Data("kept".utf8), to: try workspace.accountDirectory(kept).appendingPathComponent(".claude.json"))
        let orphanDirectory = try workspace.accountDirectory(orphan).deletingLastPathComponent()
        try workspace.write(Data("gone".utf8), to: orphanDirectory.appendingPathComponent("cli/projects/p/s.jsonl"))
        try FileManager.default.createSymbolicLink(at: orphanDirectory.appendingPathComponent("cli/outside"), withDestinationURL: outside)
        let accounts = base.appendingPathComponent("app/accounts")
        try workspace.write(Data("keep".utf8), to: accounts.appendingPathComponent("shared/file"))
        XCTAssertEqual(workspace.removeOrphanAccounts(keeping: [kept]), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanDirectory.path))
        XCTAssertEqual(try workspace.read(try workspace.accountDirectory(kept).appendingPathComponent(".claude.json")), Data("kept".utf8))
        XCTAssertEqual(try workspace.read(accounts.appendingPathComponent("shared/file")), Data("keep".utf8))
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("file")), Data("untouched".utf8))
    }

    func testStaleSessionsGoWithTheirToolResultsOnly() throws {
        let base = try fixture(), workspace = OwnedWorkspace(root: base.appendingPathComponent("app"))
        try workspace.prepare()
        let account = UUID(), now = Date()
        XCTAssertEqual(workspace.removeStaleSessions(account: account, keeping: [], olderThan: 7200, now: now).count, 0)
        let project = try workspace.accountDirectory(account).appendingPathComponent("projects/-Users-someone-example-work")
        func session(_ name: String, age: TimeInterval, results: Bool = false) throws -> URL {
            let file = project.appendingPathComponent(name)
            try workspace.write(Data("0123456789".utf8), to: file)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: file.path)
            if results {
                try workspace.write(Data("12345".utf8), to: project.appendingPathComponent(
                    String(name.dropLast(6)) + "/tool-results/toolu_01AbC.json"))
            }
            return file
        }
        let stale = try session(UUID().uuidString.lowercased() + ".jsonl", age: 3 * 3600, results: true)
        let upper = try session(UUID().uuidString + ".jsonl", age: 3 * 3600)
        let keptID = UUID().uuidString.lowercased()
        let kept = try session(keptID + ".jsonl", age: 3 * 3600, results: true)
        let fresh = try session(UUID().uuidString.lowercased() + ".jsonl", age: 600)
        let history = try session("history.jsonl", age: 3 * 3600)
        let outside = base.appendingPathComponent("outside.jsonl")
        try Data("untouched".utf8).write(to: outside)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3 * 3600)], ofItemAtPath: outside.path)
        let link = project.appendingPathComponent(UUID().uuidString.lowercased() + ".jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        let result = workspace.removeStaleSessions(account: account, keeping: [keptID.uppercased()], olderThan: 7200, now: now)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.bytes, 25)
        for gone in [stale, upper, stale.deletingPathExtension()] { XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path)) }
        for still in [kept, fresh, history, kept.deletingPathExtension()] { XCTAssertTrue(FileManager.default.fileExists(atPath: still.path)) }
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path))
        XCTAssertEqual(try Data(contentsOf: outside), Data("untouched".utf8))
    }

    func testLoadingTheLibraryLiftsAnOldModelCooldownOffTheWholeAccount() async throws {
        let workspace = OwnedWorkspace(root: try fixture().appendingPathComponent("app"))
        let store = PoolStore(workspace: workspace)
        let reset = Date().addingTimeInterval(3 * 86400)
        let window = QuotaWindow(id: "seven_day_overage_included", usedPercent: 100, observedAt: Date(), resetsAt: reset)
        try await store.save(PoolLibrary(accounts: [PoolAccount(email: "reset@example.com", state: .limited, windows: [window], cooldownUntil: reset)]))
        let loaded = try await store.load().accounts[0]
        XCTAssertNil(loaded.cooldownUntil)
        XCTAssertEqual(loaded.windows[0].refusedUntil.map { Int($0.timeIntervalSince1970) }, Int(reset.timeIntervalSince1970))
    }
}
