import Foundation
import XCTest
import PoolCore
@testable import PoolRuntime

final class DeveloperRecorderTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("devrecord-" + UUID().uuidString, isDirectory: true)
    }
    override func tearDownWithError() throws {
        DevRecord.install(nil)
        try? FileManager.default.removeItem(at: root)
    }

    func testChannelsAreWrittenToPrivateFilesOfTheirOwn() throws {
        let recorder = DeveloperRecorder(root: root)
        try recorder.install()
        DevRecord.record(.privacy, "privacy.prepared") { ["sent": .string("Hello {{PERSON_1}}")] }
        DevRecord.record(.http, "http.request") { ["body": DevRecord.bytes(Data("{}".utf8))] }
        recorder.flush()
        for channel in [DevRecord.Channel.privacy, .http] {
            let files = try FileManager.default.contentsOfDirectory(atPath: recorder.directory(channel).path)
            XCTAssertEqual(files.count, 1)
            let path = recorder.directory(channel).appendingPathComponent(files[0]).path
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int, 0o600)
            let line = try XCTUnwrap(String(contentsOfFile: path, encoding: .utf8).split(separator: "\n").last)
            XCTAssertTrue(line.contains("\"kind\":\"" + (channel == .privacy ? "privacy.prepared" : "http.request") + "\""))
        }
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int, 0o700)
        recorder.uninstall()
        XCTAssertFalse(DevRecord.isOn)
    }

    func testFilesRollAndTheOldestGoOnceAChannelPassesItsLimit() throws {
        let recorder = DeveloperRecorder(root: root, limits: [.session: 8 * 1024], fileLimit: 2 * 1024)
        try recorder.install()
        let chunk = String(repeating: "x", count: 300)
        for _ in 0..<200 { DevRecord.record(.session, "pty.out") { ["bytes": .object(["text": .string(chunk)])] } }
        recorder.flush()
        let directory = recorder.directory(.session)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertGreaterThan(files.count, 1)
        let total = files.reduce(0) { $0 + ((try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent($1).path)[.size] as? Int) ?? 0) }
        XCTAssertLessThanOrEqual(total, 8 * 1024)
        recorder.deleteAll()
        XCTAssertEqual(recorder.totalBytes(), 0)
    }

    func testUninstalledRecorderWritesNothing() throws {
        let recorder = DeveloperRecorder(root: root)
        DevRecord.record(.privacy, "privacy.prepared") { ["sent": .string("text")] }
        recorder.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}
