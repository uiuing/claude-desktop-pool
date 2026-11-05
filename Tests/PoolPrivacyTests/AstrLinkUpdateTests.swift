import CryptoKit
import Foundation
import PoolRuntime
@testable import PoolPrivacy
import XCTest

/// Synthetic releases only: fake weights, fake metadata and a fake session. Nothing is downloaded.
private final class FakeSession: AstrLinkInference {
    let path: URL
    init(path: URL) { self.path = path }
    func tokens(_ text: String) throws -> [AstrLinkTokenizer.Token] { [] }
    func logits(_ ids: [Int64]) throws -> [Float] { [Float](repeating: 0, count: ids.count * 21) }
}

private actor FakeReleases: PrivacyModelDownloader {
    var files: [String: Data] = [:]
    var metadataFiles: [String: Data] = [:]
    private(set) var downloads: [String] = []
    func put(_ data: Data, revision: String, file: String) { files[revision + "/" + file] = data }
    func putMetadata(_ data: Data, url: String) { metadataFiles[url] = data }
    func download(_ artifact: PrivacyModelArtifact, progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        downloads.append(artifact.revision + "/" + artifact.filename)
        guard let data = files[artifact.revision + "/" + artifact.filename] else { throw PrivacyFailure.modelFailed }
        progress(1); return data
    }
    func metadata(_ url: URL, limit: Int) async throws -> Data {
        guard let data = metadataFiles[url.absoluteString], data.count <= limit else { throw PrivacyFailure.modelFailed }
        return data
    }
}

private struct FixedSource: AstrLinkReleaseSource {
    let update: AstrLinkUpdate
    func latest() async throws -> AstrLinkUpdate { update }
}

final class AstrLinkUpdateTests: XCTestCase {
    private func workspace() throws -> OwnedWorkspace {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/privacy-fixtures/\(UUID().uuidString)")
        let workspace = OwnedWorkspace(root: root); try workspace.prepare()
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return workspace
    }
    private func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func revision(_ n: Int) -> String { String(repeating: String(n), count: 40) }

    /// A release of three small synthetic files, published to `releases`.
    private func release(_ version: String, _ n: Int, in releases: FakeReleases) async -> AstrLinkRelease {
        var artifacts: [PrivacyModelArtifact] = []
        for name in AstrLinkRelease.filenames {
            let data = Data("\(name) \(version)".utf8)
            await releases.put(data, revision: revision(n), file: name)
            artifacts.append(PrivacyModelArtifact(filename: name, bytes: data.count, sha256: hex(data), revision: revision(n)))
        }
        return AstrLinkRelease(version: version, revision: revision(n), artifacts: artifacts)
    }
    private func detector(_ workspace: OwnedWorkspace, _ releases: FakeReleases, update: AstrLinkUpdate = .none,
                          loaded: @escaping @Sendable (URL) -> Void = { _ in }) -> AstrLinkDetector {
        AstrLinkDetector(workspace: workspace, downloader: releases, releases: FixedSource(update: update), session: { path, _ in
            loaded(path); return FakeSession(path: path)
        })
    }
    private func activate(_ release: AstrLinkRelease, in workspace: OwnedWorkspace) throws {
        try workspace.createDirectory(at: workspace.root.appendingPathComponent("privacy"))
        try workspace.write(JSONEncoder().encode(release), to: workspace.root.appendingPathComponent("privacy/current.json"))
    }

    func testANewerReleaseInstallsBesideTheCurrentOneAndBecomesActive() async throws {
        let workspace = try workspace(), releases = FakeReleases()
        let first = await release("0.1.3", 1, in: releases), next = await release("0.1.4", 2, in: releases)
        try activate(first, in: workspace)
        let model = detector(workspace, releases, update: .available(next))
        try await model.install()
        let installed = await model.installedVersion(); XCTAssertEqual(installed, "0.1.3")

        let update = try await model.checkForUpdate()
        XCTAssertEqual(update, .available(next))
        try await model.update(to: next)
        let version = await model.installedVersion(), status = await model.status()
        XCTAssertEqual(version, "0.1.4"); XCTAssertEqual(status, .ready)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.root.appendingPathComponent("privacy/astrlink-\(revision(1))").path),
                      "the release replaced stays until the next update")

        // A restarted Pool runs the activated release.
        let restarted = detector(workspace, releases)
        let restartedVersion = await restarted.installedVersion(); XCTAssertEqual(restartedVersion, "0.1.4")

        let third = await release("0.2.0", 3, in: releases)
        try await model.update(to: third)
        let privacy = workspace.root.appendingPathComponent("privacy")
        let kept = try workspace.entries(in: privacy).filter { $0.lastPathComponent.hasPrefix("astrlink-") }
            .filter { !((try? workspace.entries(in: $0)) ?? []).isEmpty }.map(\.lastPathComponent)
        XCTAssertEqual(Set(kept), ["astrlink-\(revision(2))", "astrlink-\(revision(3))"], "only the current and previous releases keep their files")
    }

    func testAFailedUpdateKeepsTheCurrentReleaseWorking() async throws {
        let workspace = try workspace(), releases = FakeReleases()
        let first = await release("0.1.3", 1, in: releases)
        var broken = await release("0.1.4", 2, in: releases)
        broken.artifacts[1] = PrivacyModelArtifact(filename: broken.artifacts[1].filename, bytes: broken.artifacts[1].bytes,
                                                   sha256: String(repeating: "0", count: 64), revision: revision(2))
        try activate(first, in: workspace)
        let model = detector(workspace, releases)
        try await model.install()
        do { try await model.update(to: broken); XCTFail("a wrong checksum must not activate") }
        catch { XCTAssertEqual(error as? PrivacyFailure, .modelFailed) }
        let version = await model.installedVersion(), status = await model.status()
        XCTAssertEqual(version, "0.1.3"); XCTAssertEqual(status, .ready)
        let spans = try await model.detect(in: "synthetic text")
        XCTAssertEqual(spans, [])
        let saved = try JSONDecoder().decode(AstrLinkRelease.self, from: workspace.read(workspace.root.appendingPathComponent("privacy/current.json")))
        XCTAssertEqual(saved, first)
    }

    func testOlderOrMalformedReleasesAreIgnored() async throws {
        let workspace = try workspace(), releases = FakeReleases()
        let first = await release("0.1.3", 1, in: releases), older = await release("0.1.2", 2, in: releases)
        try activate(first, in: workspace)
        let model = detector(workspace, releases, update: .available(older))
        let update = try await model.checkForUpdate(); XCTAssertEqual(update, .none)
        try await model.update(to: older)
        let downloads = await releases.downloads
        XCTAssertTrue(downloads.isEmpty)
        var foreign = await release("0.1.5", 4, in: releases); foreign.artifacts.removeLast()
        XCTAssertFalse(foreign.isWellFormed)
    }

    func testThePublishedReleaseIsReadFromItsTagChecksumsAndLabels() async throws {
        let releases = FakeReleases(), commit = revision(7), api = "https://huggingface.co/api/models/QuantumNous/astrlink-guard"
        let files = "https://huggingface.co/QuantumNous/astrlink-guard/resolve/\(commit)/int8/"
        await releases.putMetadata(Data(#"{"tags":[{"name":"v0.1.9"},{"name":"v0.1.10"},{"name":"latest"}],"branches":[]}"#.utf8), url: api + "/refs")
        await releases.putMetadata(Data(#"{"sha":"\#(commit)","cardData":{"license":"apache-2.0"}}"#.utf8), url: api + "/revision/v0.1.10")
        let labels = Dictionary(uniqueKeysWithValues: AstrLinkRelease.labels.enumerated().map { (String($0.offset), $0.element) })
        await releases.putMetadata(try JSONEncoder().encode(["id2label": labels]), url: files + "labels.json")
        let sum = String(repeating: "a", count: 64)
        await releases.putMetadata(Data(#"{"model_int8.onnx":{"sha256":"\#(sum)","size":10},"model_int8.onnx_data":{"sha256":"\#(sum)","size":20},"tokenizer.json":{"sha256":"\#(sum)","size":30},"labels.json":{"sha256":"\#(sum)","size":5}}"#.utf8), url: files + "CHECKSUMS.json")
        let source = OfficialAstrLinkReleases(downloader: releases)
        guard case .available(let found) = try await source.latest() else { return XCTFail("expected a release") }
        XCTAssertEqual(found.version, "0.1.10"); XCTAssertEqual(found.revision, commit)
        XCTAssertEqual(found.artifacts.map(\.bytes), [10, 20, 30])

        var changed = labels; changed["21"] = "B-new_kind"
        await releases.putMetadata(try JSONEncoder().encode(["id2label": changed]), url: files + "labels.json")
        let incompatible = try await source.latest()
        XCTAssertEqual(incompatible, .needsNewerApp("0.1.10"))

        await releases.putMetadata(try JSONEncoder().encode(["id2label": labels]), url: files + "labels.json")
        await releases.putMetadata(Data(#"{"sha":"\#(commit)","cardData":{"license":"other"}}"#.utf8), url: api + "/revision/v0.1.10")
        let relicensed = try await source.latest()
        XCTAssertEqual(relicensed, .needsNewerApp("0.1.10"))
    }

    func testTheBuiltInReleaseMatchesThePinnedFiles() {
        XCTAssertTrue(AstrLinkDetector.builtIn.isWellFormed)
        XCTAssertEqual(AstrLinkDetector.builtIn.artifacts.map(\.url.absoluteString).first,
                       "https://huggingface.co/QuantumNous/astrlink-guard/resolve/\(AstrLinkDetector.revision)/int8/model_int8.onnx")
    }
}
