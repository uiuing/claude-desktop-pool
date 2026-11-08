import Foundation
import XCTest
import PoolCore
@testable import PoolRuntime

final class DiagnosticsLogTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pool-log-\(UUID().uuidString)/Logs/Claude Pool")
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        return url
    }

    func testLogIsPrivateAndRecordsOnlyDecisions() throws {
        let log = DiagnosticsLog(directory: try folder())
        try log.install(version: "0.1.0")
        defer { Diagnostics.install(nil) }
        Diagnostics.record("gateway.request", ["status": "400", "reason": "clientReported:0"])
        let text = try String(contentsOf: log.file, encoding: .utf8)
        XCTAssertTrue(text.contains("event=app.started version=0.1.0"))
        XCTAssertTrue(text.contains("event=gateway.request status=400 reason=clientReported:0"))
        let file = try FileManager.default.attributesOfItem(atPath: log.file.path)[.posixPermissions] as? Int
        let dir = try FileManager.default.attributesOfItem(atPath: log.directory.path)[.posixPermissions] as? Int
        XCTAssertEqual(file, 0o600); XCTAssertEqual(dir, 0o700)
    }

    func testCredentialShapesAreScrubbedAsABackstop() {
        let line = DiagnosticsLog.scrub("event=x auth=Bearer abcdefgh12345678 key=sk-ant-abcdefgh12 who=fixture@example.com")
        XCTAssertFalse(line.contains("abcdefgh12345678")); XCTAssertFalse(line.contains("sk-ant")); XCTAssertFalse(line.contains("@example.com"))
    }

    func testFullLogMovesAsideSoAtMostTwoFilesExist() throws {
        // The rotation at a small size: the same code as at 10 MiB, without writing 10 MiB.
        let log = DiagnosticsLog(directory: try folder(), maxSize: 64 << 10)
        try log.install(version: "0.1.0")
        defer { Diagnostics.install(nil) }
        let padding = String(repeating: "x", count: 150)
        for i in 0..<(log.maxSize / 180 + 50) { Diagnostics.record("fill", ["i": String(i), "pad": padding]) }
        let old = log.directory.appendingPathComponent("pool.old.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
        let current = try FileManager.default.attributesOfItem(atPath: log.file.path)[.size] as? Int ?? 0
        XCTAssertLessThanOrEqual(current, log.maxSize)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: log.directory.path).sorted(), ["pool.log", "pool.old.log"])
    }
}
