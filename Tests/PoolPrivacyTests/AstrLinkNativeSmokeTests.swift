import Foundation
import PoolRuntime
@testable import PoolPrivacy
import XCTest

private struct PublicFixtureDownload: PrivacyModelDownloader {
    let directory: URL
    func download(_ artifact: PrivacyModelArtifact, progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        let data = try Data(contentsOf: directory.appendingPathComponent(artifact.filename))
        progress(1); return data
    }
}

final class AstrLinkNativeSmokeTests: XCTestCase {
    func testFourConcurrentDetectionsQueuedCancellationAndRecovery() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let fixture = ProcessInfo.processInfo.environment["CLAUDE_POOL_PRIVACY_MODEL_FIXTURE"] else {
            throw XCTSkip("Explicit public-model fixture opt-in required")
        }
        let directory = URL(fileURLWithPath: fixture).standardizedFileURL
        guard directory.path.hasPrefix(repository.appendingPathComponent(".build").path + "/") else {
            throw XCTSkip("Public model fixtures must be inside this repository's .build directory")
        }
        let root = repository.appendingPathComponent(".build/privacy-model-smoke/\(UUID().uuidString)")
        let model = AstrLinkDetector(workspace: OwnedWorkspace(root: root), downloader: PublicFixtureDownload(directory: directory))
        try await model.install()
        let text = String(repeating: "Review the deployment notes. ", count: 1_000) + " Contact Jane Doe."
        let first = Task { try await model.detect(in: text) }
        let second = Task { try await model.detect(in: text) }
        try await privacyQueueEventually { await model.detectionQueueState.active == 2 }
        let cancelled = Task { try await model.detect(in: text) }
        try await privacyQueueEventually { await model.detectionQueueState.waiting == 1 }
        let third = Task { try await model.detect(in: text) }
        try await privacyQueueEventually { await model.detectionQueueState.waiting == 2 }
        let fourth = Task { try await model.detect(in: text) }
        try await privacyQueueEventually { await model.detectionQueueState.waiting == 3 }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Queued native work must cancel") }
        catch { XCTAssertTrue(error is CancellationError) }
        await model.unload()
        for task in [first, second, third, fourth] {
            let spans = try await task.value
            XCTAssertTrue(spans.contains { $0.category == .person })
        }
        let state = await model.detectionQueueState
        XCTAssertEqual(state.active, 0); XCTAssertEqual(state.waiting, 0)
        let next = try await model.detect(in: "Contact Jane Doe.")
        XCTAssertTrue(next.contains { $0.category == .person })
        await model.unload()
    }

    /// Opt-in public weights only, synthetic text only. No Claude process or account.
    /// Use CLAUDE_POOL_PRIVACY_MODEL_FIXTURE=<repo>/.build/<public-model-folder>,
    /// or CLAUDE_POOL_ALLOW_PRIVACY_DOWNLOAD_SMOKE=1 for the actual bounded downloader.
    func testPinnedModelTokenizerAndSyntheticInference() async throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let environment = ProcessInfo.processInfo.environment
        let downloader: any PrivacyModelDownloader
        if let fixture = environment["CLAUDE_POOL_PRIVACY_MODEL_FIXTURE"] {
            let directory = URL(fileURLWithPath: fixture).standardizedFileURL
            guard directory.path.hasPrefix(repository.appendingPathComponent(".build").path + "/") else {
                throw XCTSkip("Public model fixtures must be inside this repository's .build directory")
            }
            downloader = PublicFixtureDownload(directory: directory)
        } else if environment["CLAUDE_POOL_ALLOW_PRIVACY_DOWNLOAD_SMOKE"] == "1" {
            downloader = OfficialPrivacyModelDownloader()
        } else { throw XCTSkip("Explicit public-model smoke opt-in required") }

        let root = repository.appendingPathComponent(".build/privacy-model-smoke/\(UUID().uuidString)")
        let workspace = OwnedWorkspace(root: root), model = AstrLinkDetector(workspace: workspace, downloader: downloader)
        let started = Date()
        try await model.install()
        let installSeconds = Date().timeIntervalSince(started)
        let status = await model.status()
        XCTAssertEqual(status, .ready)
        let directory = root.appendingPathComponent("privacy/astrlink-\(AstrLinkDetector.revision)")
        let tokenizer = try AstrLinkTokenizer(data: workspace.read(directory.appendingPathComponent("tokenizer.json")))
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/astrlink-tokenizer-golden.json")
        let cases = try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as! [[String: Any]]
        for (index, item) in cases.enumerated() {
            let tokens = try tokenizer.encode(item["text"] as! String)
            XCTAssertEqual(tokens.map(\.id), item["ids"] as! [Int], "Tokenizer reference case \(index)")
            let offsets = (item["sourceOffsets"] ?? item["offsets"]) as! [[Int]]
            XCTAssertEqual(tokens.map { [$0.start, $0.end] }, offsets, "Original source alignment case \(index)")
        }

        let english = "\u{1f600} Contact Jane Doe at +1 415-555-0132. Her home address is 42 Willow Street, Boston."
        let chinese = "\u{8bf7}\u{8054}\u{7cfb}\u{5f20}\u{4f1f}\u{ff0c}\u{6536}\u{8d27}\u{5730}\u{5740}\u{ff1a}\u{5317}\u{4eac}\u{5e02}\u{6d77}\u{6dc0}\u{533a}\u{4e2d}\u{5173}\u{6751}\u{5927}\u{8857} 27 \u{53f7}\u{3002}"
        let inferStarted = Date()
        let englishSpans = try await model.detect(in: english)
        let chineseSpans = try await model.detect(in: chinese)
        let secretSpans = try await model.detect(in: "The API key is \"q7Vt2LmX9pRk4sWz8bNc3yHd6fJg1aE5\".")
        XCTAssertTrue(englishSpans.contains { $0.category == .person && (english as NSString).substring(with: NSRange(location: $0.start, length: $0.end - $0.start)).contains("Jane Doe") })
        XCTAssertTrue(englishSpans.contains { $0.category == .phone })
        XCTAssertTrue(chineseSpans.contains { $0.category == .person })
        XCTAssertTrue(chineseSpans.contains { $0.category == .address })
        XCTAssertTrue(secretSpans.contains { $0.category == .secret })
        let longText = String(repeating: "Review the deployment notes. ", count: 160) + english
        let longSpans = try await model.detect(in: longText)
        let name = (longText as NSString).range(of: "Jane Doe")
        XCTAssertTrue(longSpans.contains { $0.category == .person && $0.start <= name.location && $0.end >= NSMaxRange(name) })
        let inferSeconds = Date().timeIntervalSince(inferStarted)

        let cancelled = Task { try await model.detect(in: longText) }; cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Cancelled native detection must not publish") }
        catch { XCTAssertTrue(error is CancellationError) }
        let midRun = Task { try await model.detect(in: String(repeating: "Review the deployment notes. ", count: 2_000)) }
        try await Task.sleep(for: .milliseconds(25)); midRun.cancel()
        do { _ = try await midRun.value; XCTFail("Cancellation between windows must not publish") }
        catch { XCTAssertTrue(error is CancellationError) }
        await model.unload()
        let reloaded = await model.status()
        XCTAssertEqual(reloaded, .ready)

        await model.unload()
        let graph = directory.appendingPathComponent("model_int8.onnx")
        let original = try workspace.read(graph)
        try workspace.write(Data("corrupt synthetic fixture".utf8), to: graph)
        let damaged = await model.status()
        XCTAssertEqual(damaged, .failed)
        do { _ = try await model.detect(in: ""); XCTFail("Damaged model must block empty readiness check") }
        catch { XCTAssertEqual(error as? PrivacyFailure, .modelFailed) }
        try workspace.write(original, to: graph)
        let result: [String: Any] = ["revision": AstrLinkDetector.revision, "tokenizerCases": cases.count,
                                   "installSeconds": installSeconds, "inferenceSeconds": inferSeconds,
                                   "englishSpans": englishSpans.count, "chineseSpans": chineseSpans.count,
                                   "secretSpans": secretSpans.count,
                                   "longInputTokens": try tokenizer.encode(longText).count,
                                   "nativeRuntime": "ONNX Runtime 1.24.2 CPU", "maximumThreads": 2,
                                   "syntheticTextOnly": true, "claudeExecuted": false]
        try workspace.write(JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
                            to: root.appendingPathComponent("verification.json"))
    }
}
