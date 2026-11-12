import Foundation
import CryptoKit
import XCTest
@testable import PoolRuntime

private actor ReleaseDownloads: RuntimeDownloader {
    var files: [String: Data] = [:]
    var requests: [URL] = []
    var failing: String?
    func set(_ path: String, _ data: Data) { files[path] = data }
    func fail(_ path: String) { failing = path }
    func fetch(_ url: URL, maximumBytes: Int64, receive: @escaping @Sendable (Data) throws -> Void) async throws {
        requests.append(url)
        guard let data = files[url.path] else { throw RuntimeInstallError.downloadFailed }
        for start in stride(from: 0, to: data.count, by: 3) {
            try Task.checkCancellation()
            try receive(data.subdata(in: start..<min(start + 3, data.count)))
            if failing == url.path { throw RuntimeInstallError.downloadFailed }
        }
    }
}

private final class RecordedInstallProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [RuntimeInstallProgress] = []
    func append(_ value: RuntimeInstallProgress) { lock.withLock { values.append(value) } }
    var snapshot: [RuntimeInstallProgress] { lock.withLock { values } }
}

final class ManagedRuntimeTests: XCTestCase {
    private let prefix = "/claude-code-releases/"
    private func workspace() throws -> OwnedWorkspace {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/runtime-fixtures/\(UUID().uuidString)")
        let workspace = OwnedWorkspace(root: root)
        try workspace.prepare()
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return workspace
    }

    private func release(_ version: String, downloads: ReleaseDownloads, platform: RuntimePlatform = .macOSArm64,
                         body: String = "fixture", wrongCPU: Bool = false, corrupt: Bool = false, extra: Bool = false) async throws -> Data {
        let cpu: UInt32 = (platform == .macOSArm64) != wrongCPU ? 0x0100000c : 0x01000007
        var binary = Data([0xcf, 0xfa, 0xed, 0xfe])
        binary.append(contentsOf: (0..<4).map { UInt8((cpu >> (8 * $0)) & 0xff) })
        binary.append(Data(body.utf8))
        let checksum = SHA256.hash(data: binary).map { String(format: "%02x", $0) }.joined()
        let manifest: [String: Any] = ["version": version, "platforms": [platform.rawValue:
            ["binary": "claude", "checksum": corrupt ? String(repeating: "0", count: 64) : checksum, "size": binary.count]]]
        await downloads.set(prefix + "latest", Data(version.utf8))
        await downloads.set(prefix + version + "/manifest.json", try JSONSerialization.data(withJSONObject: manifest))
        await downloads.set(prefix + version + "/" + platform.rawValue + "/claude", extra ? binary + Data([0]) : binary)
        return binary
    }

    func testInstallProgressReportsActualBytesTargetVersionAndPhases() async throws {
        let workspace = try workspace(), downloads = ReleaseDownloads(), progress = RecordedInstallProgress()
        let runtime = ManagedRuntime(workspace: workspace, platform: .macOSArm64, downloader: downloads)
        let bytes = try await release("2.1.300", downloads: downloads, body: "progress-fixture")
        let installed = try await runtime.installLatest { progress.append($0) }
        let events = progress.snapshot
        XCTAssertEqual(events.first, .resolving)
        XCTAssertNil(events.first?.version); XCTAssertNil(events.first?.fractionCompleted)
        let transferred = events.compactMap(\.receivedBytes)
        XCTAssertEqual(transferred.first, 0)
        XCTAssertEqual(transferred.last, Int64(bytes.count))
        XCTAssertEqual(transferred, transferred.sorted())
        XCTAssertTrue(transferred.contains { $0 > 0 && $0 < Int64(bytes.count) })
        for event in events {
            if case .downloading(let version, let received, let total) = event {
                XCTAssertEqual(version, installed.version); XCTAssertEqual(total, Int64(bytes.count))
                XCTAssertEqual(event.fractionCompleted, Double(received) / Double(bytes.count))
            }
        }
        XCTAssertEqual(Array(events.suffix(3)), [.verifying(version: installed.version), .activating(version: installed.version),
                                               .completed(version: installed.version)])
    }

    func testAlreadyInstalledPublishesActualVersionWithoutDownload() async throws {
        let workspace = try workspace(), downloads = ReleaseDownloads(), progress = RecordedInstallProgress()
        let runtime = ManagedRuntime(workspace: workspace, platform: .macOSArm64, downloader: downloads)
        _ = try await release("2.1.300", downloads: downloads)
        let installed = try await runtime.installLatest()
        let returned = try await runtime.installLatest { progress.append($0) }
        XCTAssertEqual(returned, installed)
        XCTAssertEqual(progress.snapshot, [.resolving, .completed(version: installed.version)])
        let requests = await downloads.requests
        XCTAssertEqual(requests.filter { $0.lastPathComponent == "claude" }.count, 1)
    }

    func testFailedVerificationAndDownloadNeverReportCompletion() async throws {
        let workspace = try workspace(), downloads = ReleaseDownloads()
        let runtime = ManagedRuntime(workspace: workspace, platform: .macOSArm64, downloader: downloads)
        _ = try await release("2.1.300", downloads: downloads)
        let installed = try await runtime.installLatest()
        _ = try await release("2.1.301", downloads: downloads, corrupt: true)
        let verification = RecordedInstallProgress()
        do { _ = try await runtime.installLatest { verification.append($0) }; XCTFail("Invalid checksum must fail") }
        catch { XCTAssertEqual(error as? RuntimeInstallError, .verificationFailed) }
        XCTAssertEqual(verification.snapshot.last, .verifying(version: "2.1.301"))
        XCTAssertFalse(verification.snapshot.contains(.activating(version: "2.1.301")))
        XCTAssertFalse(verification.snapshot.contains(.completed(version: "2.1.301")))
        _ = try await release("2.1.302", downloads: downloads)
        await downloads.fail(prefix + "2.1.302/darwin-arm64/claude")
        let transfer = RecordedInstallProgress()
        do { _ = try await runtime.installLatest { transfer.append($0) }; XCTFail("Interrupted download must fail") }
        catch { XCTAssertEqual(error as? RuntimeInstallError, .downloadFailed) }
        XCTAssertEqual(transfer.snapshot.last?.receivedBytes, 3)
        XCTAssertFalse(transfer.snapshot.contains(.verifying(version: "2.1.302")))
        XCTAssertFalse(transfer.snapshot.contains(.completed(version: "2.1.302")))
        let current = try await runtime.current(); XCTAssertEqual(current, installed)
    }

    func testInstallsVerifiedPrivateRuntimeAndKeepsOldVersionPinned() async throws {
        let workspace = try workspace(), downloads = ReleaseDownloads()
        let runtime = ManagedRuntime(workspace: workspace, platform: .macOSArm64, downloader: downloads)
        let missing = try await runtime.current(); XCTAssertNil(missing)
        let firstBytes = try await release("2.1.300", downloads: downloads, body: "first")
        let first = try await runtime.installLatest()
        XCTAssertEqual(first.version, "2.1.300")
        let noPrevious = try await runtime.previousInstallation(); XCTAssertNil(noPrevious)
        XCTAssertTrue(first.executable.path.hasPrefix(workspace.root.path + "/runtime/"))
        XCTAssertEqual(try workspace.read(first.executable), firstBytes)
        let attributes = try FileManager.default.attributesOfItem(atPath: first.executable.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o500)
        let secondBytes = try await release("2.1.301", downloads: downloads, body: "second")
        let update = try await runtime.checkForUpdate()
        XCTAssertEqual(update?.version, "2.1.301")
        let second = try await runtime.install(try XCTUnwrap(update))
        XCTAssertNotEqual(second.executable, first.executable)
        XCTAssertEqual(try workspace.read(first.executable), firstBytes)
        XCTAssertEqual(try workspace.read(second.executable), secondBytes)
        let previous = try await runtime.previousInstallation(); XCTAssertEqual(previous, first)
        let beforeRollback = try await runtime.current(); XCTAssertEqual(beforeRollback, second)
        let rolledBack = try await runtime.rollback()
        XCTAssertEqual(rolledBack, first)
        XCTAssertEqual(try workspace.read(second.executable), secondBytes)
        let selected = try await runtime.current(); XCTAssertEqual(selected, first)
        let requested = await downloads.requests
        XCTAssertTrue(requested.allSatisfy(OfficialRuntimeDownloader.isOfficialURL))
    }

    func testInstallPrunesVersionsBeyondCurrentAndPrevious() async throws {
        let workspace = try workspace(), downloads = ReleaseDownloads()
        let runtime = ManagedRuntime(workspace: workspace, platform: .macOSArm64, downloader: downloads)
        let versions = workspace.root.appendingPathComponent("runtime/versions")
        let stray = versions.appendingPathComponent("2.1.299/darwin-arm64/claude")
        try workspace.write(Data("unselected".utf8), to: stray)
        let none = await runtime.pruneVersions(); XCTAssertEqual(none, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: stray.path))
        try FileManager.default.removeItem(at: versions.appendingPathComponent("2.1.299"))

        _ = try await release("2.1.300", downloads: downloads, body: "first")
        let first = try await runtime.installLatest()
        let staging = versions.appendingPathComponent(".download-\(UUID().uuidString).part")
        try workspace.write(Data("partial".utf8), to: staging)
        try workspace.write(Data("keep".utf8), to: versions.appendingPathComponent("notes/readme"))
        let outside = workspace.root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        try Data("untouched".utf8).write(to: outside.appendingPathComponent("claude"))
        try FileManager.default.createSymbolicLink(at: versions.appendingPathComponent("2.1.298"), withDestinationURL: outside)

        let secondBytes = try await release("2.1.301", downloads: downloads, body: "second")
        let second = try await runtime.installLatest()
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.executable.path))
        let thirdBytes = try await release("2.1.302", downloads: downloads, body: "third")
        let third = try await runtime.installLatest()
        XCTAssertFalse(FileManager.default.fileExists(atPath: versions.appendingPathComponent("2.1.300").path))
        XCTAssertEqual(try workspace.read(second.executable), secondBytes)
        XCTAssertEqual(try workspace.read(third.executable), thirdBytes)
        XCTAssertEqual(try workspace.read(staging), Data("partial".utf8))
        XCTAssertEqual(try workspace.read(versions.appendingPathComponent("notes/readme")), Data("keep".utf8))
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("claude")), Data("untouched".utf8))
        let again = await runtime.pruneVersions(); XCTAssertEqual(again, [])
        let previous = try await runtime.previousInstallation(); XCTAssertEqual(previous, second)
        let rolledBack = try await runtime.rollback(); XCTAssertEqual(rolledBack, second)
    }

    func testFailedChecksumSizeOrArchitecturePreservesCurrentVersion() async throws {
        let workspace = try workspace(), downloads = ReleaseDownloads()
        let runtime = ManagedRuntime(workspace: workspace, platform: .macOSArm64, downloader: downloads)
        _ = try await release("2.1.300", downloads: downloads)
        let good = try await runtime.installLatest()
        for (version, cpu, checksum, extra) in [("2.1.301", false, true, false), ("2.1.302", true, false, false), ("2.1.303", false, false, true)] {
            _ = try await release(version, downloads: downloads, wrongCPU: cpu, corrupt: checksum, extra: extra)
            do { _ = try await runtime.installLatest(); XCTFail("Unverified binary must not activate") }
            catch { XCTAssertEqual(error as? RuntimeInstallError, .verificationFailed) }
            let selected = try await runtime.current(); XCTAssertEqual(selected, good)
            let directory = workspace.root.appendingPathComponent("runtime/versions/\(version)/darwin-arm64")
            XCTAssertEqual(try workspace.entries(in: directory), [])
        }
    }

    func testChannelCannotDowngradeAndMissingPlatformCannotInstall() async throws {
        let workspace = try workspace(), downloads = ReleaseDownloads()
        let runtime = ManagedRuntime(workspace: workspace, platform: .macOSArm64, downloader: downloads)
        _ = try await release("2.2.10", downloads: downloads)
        let current = try await runtime.installLatest()
        _ = try await release("2.2.9", downloads: downloads)
        let stale = try await runtime.installLatest(); XCTAssertEqual(stale, current)
        let noUpdate = try await runtime.checkForUpdate(); XCTAssertNil(noUpdate)
        _ = try await release("2.2.11", downloads: downloads, platform: .macOSIntel)
        do { _ = try await runtime.installLatest(); XCTFail("Wrong platform manifest") }
        catch { XCTAssertEqual(error as? RuntimeInstallError, .invalidRelease) }
        let selected = try await runtime.current(); XCTAssertEqual(selected, current)
    }

    func testReopeningVerifiesTheSelectedBinaryAndRollbackChecksPrevious() async throws {
        let workspace = try workspace(), downloads = ReleaseDownloads()
        let runtime = ManagedRuntime(workspace: workspace, platform: .macOSArm64, downloader: downloads)
        let bytes = try await release("2.1.300", downloads: downloads)
        let first = try await runtime.installLatest()
        let reopened = ManagedRuntime(workspace: workspace, platform: .macOSArm64, downloader: downloads)
        let selected = try await reopened.current(); XCTAssertEqual(selected, first)
        _ = try await release("2.1.301", downloads: downloads)
        let second = try await runtime.installLatest()
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: first.executable.path)
        var changed = bytes; changed[changed.count - 1] ^= 1
        try changed.write(to: first.executable)
        do { _ = try await runtime.previousInstallation(); XCTFail("Changed prior binary must not be offered") }
        catch { XCTAssertEqual(error as? RuntimeInstallError, .verificationFailed) }
        do { _ = try await runtime.rollback(); XCTFail("Changed prior binary must not activate") }
        catch { XCTAssertEqual(error as? RuntimeInstallError, .verificationFailed) }
        let stillCurrent = try await runtime.current(); XCTAssertEqual(stillCurrent, second)
    }

    func testInterruptedDownloadKeepsCurrentAndExplicitReinstallRepairsCorruption() async throws {
        let workspace = try workspace(), downloads = ReleaseDownloads()
        let runtime = ManagedRuntime(workspace: workspace, platform: .macOSArm64, downloader: downloads)
        let bytes = try await release("2.1.300", downloads: downloads)
        let installed = try await runtime.installLatest()
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: installed.executable.path)
        try Data(repeating: 0, count: bytes.count).write(to: installed.executable)
        let repaired = try await runtime.installLatest()
        XCTAssertEqual(repaired, installed)
        XCTAssertEqual(try workspace.read(repaired.executable), bytes)
        _ = try await release("2.1.301", downloads: downloads)
        await downloads.fail(prefix + "2.1.301/darwin-arm64/claude")
        do { _ = try await runtime.installLatest(); XCTFail("Interrupted transfer must not activate") }
        catch { XCTAssertEqual(error as? RuntimeInstallError, .downloadFailed) }
        let stillCurrent = try await runtime.current(); XCTAssertEqual(stillCurrent, installed)
        let pending = workspace.root.appendingPathComponent("runtime/versions/2.1.301/darwin-arm64")
        XCTAssertEqual(try workspace.entries(in: pending), [])
    }

    func testRejectsMalformedReleaseAndUnsafeHostBeforeDownload() async throws {
        let workspace = try workspace(), downloads = ReleaseDownloads()
        let runtime = ManagedRuntime(workspace: workspace, downloader: downloads)
        await downloads.set(prefix + "latest", Data("../../outside".utf8))
        do { _ = try await runtime.installLatest(); XCTFail("Malformed release pointer") }
        catch { XCTAssertEqual(error as? RuntimeInstallError, .invalidRelease) }
        for url in ["http://downloads.claude.ai/claude-code-releases/latest", "https://downloads.claude.ai.evil.invalid/claude-code-releases/latest",
                    "https://downloads.claude.ai/other/latest", "https://downloads.claude.ai/claude-code-releases/latest?token=fixture"] {
            let parsed = try XCTUnwrap(URL(string: url))
            XCTAssertFalse(OfficialRuntimeDownloader.isOfficialURL(parsed))
            do { try await OfficialRuntimeDownloader().fetch(parsed, maximumBytes: 32) { _ in }; XCTFail("Unexpected network request") }
            catch { XCTAssertEqual(error as? RuntimeInstallError, .invalidRelease) }
        }
    }

    func testSymlinkedRuntimeRootCannotReplaceOtherFiles() async throws {
        let workspace = try workspace(), downloads = ReleaseDownloads()
        let outside = workspace.root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        addTeardownBlock { try FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: workspace.root.appendingPathComponent("runtime"), withDestinationURL: outside)
        _ = try await release("2.1.300", downloads: downloads)
        let runtime = ManagedRuntime(workspace: workspace, platform: .macOSArm64, downloader: downloads)
        do { _ = try await runtime.installLatest(); XCTFail("Unsafe path") }
        catch { XCTAssertEqual(error as? RuntimeError, .unsafePath) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    func testMinimumVersionProtectsDownloadCurrentAndRollback() async throws {
        let workspace = try workspace(), downloads = ReleaseDownloads()
        let runtime = ManagedRuntime(workspace: workspace, platform: .macOSArm64, downloader: downloads)
        _ = try await release("2.1.299", downloads: downloads)
        let supported = try await runtime.installLatest()
        XCTAssertEqual(supported.version, ManagedRuntime.minimumVersion)

        let oldVersion = "2.1.298"
        let oldBytes = try await release(oldVersion, downloads: downloads)
        let oldDirectory = workspace.root.appendingPathComponent("runtime/versions/\(oldVersion)/darwin-arm64")
        let oldExecutable = oldDirectory.appendingPathComponent("claude")
        try workspace.write(oldBytes, to: oldExecutable)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: oldExecutable.path)
        let oldReceipt: [String: Any] = ["version": oldVersion, "platform": "darwin-arm64", "size": oldBytes.count,
            "checksum": SHA256.hash(data: oldBytes).map { String(format: "%02x", $0) }.joined()]
        try workspace.write(JSONSerialization.data(withJSONObject: oldReceipt), to: oldDirectory.appendingPathComponent("receipt.json"))
        let selection = workspace.root.appendingPathComponent("runtime/current.json")
        let selected: [String: Any] = ["version": supported.version, "platform": "darwin-arm64", "previous": oldVersion]
        let before = try JSONSerialization.data(withJSONObject: selected)
        try workspace.write(before, to: selection)
        do { _ = try await runtime.previousInstallation(); XCTFail("Unsupported version must not be offered for recovery") }
        catch { XCTAssertEqual(error as? RuntimeInstallError, .unsupportedVersion) }
        do { _ = try await runtime.rollback(); XCTFail("Rollback must preserve the compatibility floor") }
        catch { XCTAssertEqual(error as? RuntimeInstallError, .unsupportedVersion) }
        do { _ = try await runtime.installLatest(); XCTFail("Channel cannot install an unsupported version") }
        catch { XCTAssertEqual(error as? RuntimeInstallError, .unsupportedVersion) }
        XCTAssertEqual(try workspace.read(selection), before)
        let requests = await downloads.requests
        XCTAssertFalse(requests.contains { $0.path == prefix + oldVersion + "/darwin-arm64/claude" })

        try workspace.write(JSONSerialization.data(withJSONObject: ["version": oldVersion, "platform": "darwin-arm64"]), to: selection)
        do { _ = try await runtime.current(); XCTFail("Retained old selection must not launch") }
        catch { XCTAssertEqual(error as? RuntimeInstallError, .unsupportedVersion) }
        _ = try await release("2.1.300", downloads: downloads)
        let update = try await runtime.checkForUpdate(); XCTAssertEqual(update?.version, "2.1.300")
        let recovered = try await runtime.installLatest(); XCTAssertEqual(recovered.version, "2.1.300")
    }
}
