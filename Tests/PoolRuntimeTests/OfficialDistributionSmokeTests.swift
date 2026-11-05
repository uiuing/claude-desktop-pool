import Foundation
import XCTest
@testable import PoolRuntime

/// Opt-in public distribution check. It downloads and verifies a binary but never executes it.
/// Run with CLAUDE_POOL_ALLOW_DOWNLOAD_SMOKE=1 and select this test explicitly.
/// The receipt and binary remain under .build/official-runtime-smoke/<UUID>/ for inspection.
final class OfficialDistributionSmokeTests: XCTestCase {
    func testDownloadOfficialRuntimeWithoutExecutingIt() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CLAUDE_POOL_ALLOW_DOWNLOAD_SMOKE"] == "1",
                          "Public distribution downloads are opt-in; ordinary tests stay offline.")
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = repository.appendingPathComponent(".build/official-runtime-smoke/\(UUID().uuidString)")
        let workspace = OwnedWorkspace(root: root)
        let runtime = ManagedRuntime(workspace: workspace)
        let installed = try await runtime.installLatest()
        XCTAssertTrue(installed.executable.path.hasPrefix(root.path + "/runtime/versions/"))
        let reopened = ManagedRuntime(workspace: workspace)
        let checked = try await reopened.current()
        XCTAssertEqual(checked, installed)
        let receiptURL = installed.executable.deletingLastPathComponent().appendingPathComponent("receipt.json")
        let receipt = try JSONDecoder().decode(RuntimeRelease.self, from: workspace.read(receiptURL, limit: 4096))
        struct Evidence: Encodable {
            var checkedAt: Date
            var version: String
            var platform: String
            var size: Int64
            var sha256: String
            var executable: String
            var binaryExecuted: Bool
        }
        let evidence = Evidence(checkedAt: Date(), version: installed.version, platform: installed.platform.rawValue,
            size: receipt.size, sha256: receipt.checksum,
            executable: "runtime/versions/\(installed.version)/\(installed.platform.rawValue)/claude", binaryExecuted: false)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try workspace.write(encoder.encode(evidence), to: root.appendingPathComponent("verification.json"))
    }
}
