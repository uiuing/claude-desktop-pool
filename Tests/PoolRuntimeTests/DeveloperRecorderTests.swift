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

    /// Records repeat their field names and much of their words: a closed file is kept compressed,
    /// whole, private, and counted and cleared as any other.
    func testAClosedFileIsKeptCompressedAndReadsBackWhole() throws {
        let recorder = DeveloperRecorder(root: root, fileLimit: 4 * 1024)
        try recorder.install()
        let chunk = String(repeating: "Claude Pool repeats itself. ", count: 20)
        for _ in 0..<40 { DevRecord.record(.session, "pty.out") { ["bytes": .object(["text": .string(chunk)])] } }
        recorder.uninstall()
        let directory = recorder.directory(.session)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertFalse(names.isEmpty)
        XCTAssertTrue(names.allSatisfy { $0.hasSuffix(DeveloperRecorder.compressedSuffix) }, "Closed files, the last one at turning off included")
        var lines = 0, packed = 0
        for name in names {
            let path = directory.appendingPathComponent(name).path
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int, 0o600)
            let data = try Data(contentsOf: URL(fileURLWithPath: path)); packed += data.count
            let text = try XCTUnwrap(String(data: try (data as NSData).decompressed(using: .zlib) as Data, encoding: .utf8))
            lines += text.split(separator: "\n").filter { $0.contains("\"pty.out\"") }.count
        }
        XCTAssertEqual(lines, 40)
        XCTAssertLessThan(packed, 40 * chunk.utf8.count / 4)
        // Pool's own log lines went to the events channel, compressed too; the total counts every channel.
        let everyFile = DevRecord.Channel.allCases.flatMap { channel in
            ((try? FileManager.default.contentsOfDirectory(atPath: recorder.directory(channel).path)) ?? []).map { recorder.directory(channel).appendingPathComponent($0).path }
        }
        XCTAssertTrue(everyFile.allSatisfy { $0.hasSuffix(DeveloperRecorder.compressedSuffix) })
        XCTAssertEqual(recorder.totalBytes(), everyFile.reduce(0) { $0 + ((try? FileManager.default.attributesOfItem(atPath: $1)[.size] as? Int) ?? 0) })
        XCTAssertGreaterThan(recorder.totalBytes(), packed - 1)
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
