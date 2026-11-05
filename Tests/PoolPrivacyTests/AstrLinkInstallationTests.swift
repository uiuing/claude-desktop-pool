import Foundation
import PoolRuntime
@testable import PoolPrivacy
import XCTest

private actor InvalidModelDownload: PrivacyModelDownloader {
    private(set) var calls = 0
    func download(_ artifact: PrivacyModelArtifact, progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        calls += 1
        return Data(repeating: 0, count: artifact.bytes)
    }
}

private struct CancelledModelDownload: PrivacyModelDownloader {
    func download(_ artifact: PrivacyModelArtifact, progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        try await Task.sleep(for: .seconds(5))
        return Data()
    }
}

final class AstrLinkInstallationTests: XCTestCase {
    private func workspace() -> OwnedWorkspace {
        OwnedWorkspace(root: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/privacy-fixtures/\(UUID().uuidString)"))
    }

    func testChecksumFailureNeverPublishesModel() async throws {
        let workspace = workspace(), downloader = InvalidModelDownload()
        let model = AstrLinkDetector(workspace: workspace, downloader: downloader)
        do { try await model.install(); XCTFail("Wrong publisher hash must fail") }
        catch { XCTAssertEqual(error as? PrivacyFailure, .modelFailed) }
        let status = await model.status(), calls = await downloader.calls
        XCTAssertEqual(status, .failed); XCTAssertEqual(calls, 1)
        let files = try workspace.entries(in: workspace.root.appendingPathComponent("privacy/astrlink-\(AstrLinkDetector.revision)"))
        XCTAssertTrue(files.isEmpty)
    }

    func testSymlinkedModelFolderCannotEscapeWorkspace() async throws {
        let workspace = workspace(); try workspace.prepare()
        let outside = workspace.root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let marker = outside.appendingPathComponent("keep.txt")
        try Data("fixture".utf8).write(to: marker)
        try FileManager.default.createSymbolicLink(at: workspace.root.appendingPathComponent("privacy"), withDestinationURL: outside)
        let downloader = InvalidModelDownload(), model = AstrLinkDetector(workspace: workspace, downloader: downloader)
        do { try await model.install(); XCTFail("Symlink must fail") }
        catch { XCTAssertEqual(error as? PrivacyFailure, .modelFailed) }
        let calls = await downloader.calls
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(try Data(contentsOf: marker), Data("fixture".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["keep.txt"])
    }

    func testCancelledInstallRemainsUnavailable() async throws {
        let model = AstrLinkDetector(workspace: workspace(), downloader: CancelledModelDownload())
        let operation = Task { try await model.install() }
        try await Task.sleep(for: .milliseconds(20)); operation.cancel()
        do { try await operation.value; XCTFail("Cancellation must propagate") }
        catch { XCTAssertTrue(error is CancellationError) }
        let status = await model.status()
        XCTAssertEqual(status, .notInstalled)
    }

    func testExplicitLargeArtifactWriteDoesNotRelaxDefaultLimit() throws {
        let workspace = workspace(); try workspace.prepare()
        let data = Data(repeating: 7, count: 17 * 1024 * 1024), url = workspace.root.appendingPathComponent("model-fixture.bin")
        XCTAssertThrowsError(try workspace.write(data, to: url))
        try workspace.write(data, to: url, limit: 64 * 1024 * 1024)
        XCTAssertEqual(try workspace.read(url, limit: data.count).count, data.count)
        XCTAssertThrowsError(try workspace.write(Data(), to: url, limit: -1))
        XCTAssertThrowsError(try workspace.write(Data(), to: url, limit: 64 * 1024 * 1024 + 1))
    }
}
