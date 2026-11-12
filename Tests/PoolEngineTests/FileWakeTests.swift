import Foundation
import Darwin
import XCTest
import PoolCore
import PoolRuntime
@testable import PoolEngine

/// A look's wait ends when the run's files change, and at its time when they do not.
final class FileWakeTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("filewake-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    /// A file renamed into the folder, as the helper and hooks write theirs.
    private func renameIn(_ name: String = UUID().uuidString + ".json") throws {
        let temporary = folder.appendingPathComponent("." + UUID().uuidString + ".tmp")
        try Data("{}".utf8).write(to: temporary)
        XCTAssertEqual(rename(temporary.path, folder.appendingPathComponent(name).path), 0)
    }

    private func elapsed(_ body: () async -> Void) async -> TimeInterval {
        let start = Date(); await body(); return Date().timeIntervalSince(start)
    }

    func testAFileRenamedInEndsTheWaitAtOnce() async throws {
        let wake = FileWake([folder.path]); defer { wake.close() }
        let folder = folder!
        Task.detached {
            try await Task.sleep(nanoseconds: 50_000_000)
            let temporary = folder.appendingPathComponent(".x.tmp")
            try Data("{}".utf8).write(to: temporary)
            rename(temporary.path, folder.appendingPathComponent("a.json").path)
        }
        let took = await elapsed { await wake.wait(upTo: .seconds(5)) }
        XCTAssertLessThan(took, 2)
        XCTAssertEqual(wake.woken, 1); XCTAssertEqual(wake.polled, 0)
    }

    func testAnAppendToAWatchedFileEndsTheWait() async throws {
        let file = folder.appendingPathComponent("tap.jsonl")
        try Data().write(to: file)
        let wake = FileWake([file.path]); defer { wake.close() }
        Task.detached {
            try await Task.sleep(nanoseconds: 50_000_000)
            let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd()
            try handle.write(contentsOf: Data("{}\n".utf8)); try handle.close()
        }
        let took = await elapsed { await wake.wait(upTo: .seconds(5)) }
        XCTAssertLessThan(took, 2)
    }

    func testWithNoChangeTheWaitRunsItsTime() async throws {
        let wake = FileWake([folder.path]); defer { wake.close() }
        let took = await elapsed { await wake.wait(upTo: .milliseconds(200)) }
        XCTAssertGreaterThanOrEqual(took, 0.19)
        XCTAssertEqual(wake.polled, 1); XCTAssertEqual(wake.woken, 0)
    }

    func testAChangeBeforeTheWaitIsNotLostAndChangesTogetherWakeOnce() async throws {
        let wake = FileWake([folder.path]); defer { wake.close() }
        try renameIn(); try renameIn(); try renameIn()
        try await Task.sleep(nanoseconds: 100_000_000)
        let first = await elapsed { await wake.wait(upTo: .seconds(5)) }
        XCTAssertLessThan(first, 1, "A change that came before the wait ends it at once")
        let second = await elapsed { await wake.wait(upTo: .milliseconds(200)) }
        XCTAssertGreaterThanOrEqual(second, 0.19, "Changes that came together end one wait")
        XCTAssertEqual(wake.woken, 1); XCTAssertEqual(wake.polled, 1)
    }

    func testBlockingWaitWakesOnAChangeAndRunsItsTimeOtherwise() throws {
        let wake = FileWake([folder.path]); defer { wake.close() }
        var start = Date()
        XCTAssertFalse(wake.waitBlocking(upTo: 0.2))
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.19)
        let folder = folder!
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            let temporary = folder.appendingPathComponent(".y.tmp")
            try? Data("{}".utf8).write(to: temporary)
            rename(temporary.path, folder.appendingPathComponent("b.json").path)
        }
        start = Date()
        XCTAssertTrue(wake.waitBlocking(upTo: 5))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testCancellingEndsTheWaitAtOnce() async throws {
        let wake = FileWake([folder.path]); defer { wake.close() }
        let start = Date()
        let waiting = Task { await wake.wait(upTo: .seconds(10)) }
        try await Task.sleep(nanoseconds: 50_000_000)
        waiting.cancel()
        await waiting.value
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertEqual(wake.woken, 0); XCTAssertEqual(wake.polled, 0)
        let cancelled = Task { await wake.wait(upTo: .seconds(10)) }
        cancelled.cancel()
        let took = await elapsed { await cancelled.value }
        XCTAssertLessThan(took, 2, "A task cancelled before it waits does not wait")
    }

    func testAMissingPathOnlyWaitsAndIsWatchedOnceItIsThere() async throws {
        let later = folder.appendingPathComponent("later", isDirectory: true)
        let wake = FileWake([later.path]); defer { wake.close() }
        XCTAssertEqual(wake.watching, 0)
        let took = await elapsed { await wake.wait(upTo: .milliseconds(150)) }
        XCTAssertGreaterThanOrEqual(took, 0.14)
        try FileManager.default.createDirectory(at: later, withIntermediateDirectories: false)
        wake.watch([later.path])
        XCTAssertEqual(wake.watching, 1)
    }

    func testDescriptorsAreClosedWithTheWake() async throws {
        let file = folder.appendingPathComponent("t.jsonl"); try Data().write(to: file)
        func open() -> Int { (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count) ?? -1 }
        let before = open()
        for _ in 0..<200 {
            let wake = FileWake([folder.path, file.path])
            XCTAssertEqual(wake.watching, 2)
            await wake.wait(upTo: .milliseconds(1))
            wake.close()
        }
        for _ in 0..<50 { _ = FileWake([folder.path, file.path]) }
        // cancel handlers close on the wake's queue
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertLessThanOrEqual(open(), before + 2)
    }

    /// A tap line written while the reply is quiet is told well inside the quiet look's wait.
    func testATapLineIsToldSoonerThanTheQuietLook() async throws {
        let harness = try SessionHarness(); defer { harness.clean() }
        let session = harness.session()
        let log = EventLog.recording(try await session.events(for:
            BridgeRequest(model: "claude-sonnet", messages: [.init(role: "user", content: .string("Hello"))])))
        try await waitFor { harness.sentCount == 1 }
        try harness.tap(#"{"tap":"on"}"#, #"{"s":1,"open":true}"#)
        try harness.stream(1, ClaudeStreamTests.start("msg_1"), ClaudeStreamTests.textStart(0))
        var told = "", took: [TimeInterval] = []
        for piece in ["a", "b", "c", "d", "e"] {
            // quiet long enough for the looks to ease out to their longest wait
            try await Task.sleep(nanoseconds: 1_200_000_000)
            told += piece
            let start = Date()
            try harness.stream(1, ClaudeStreamTests.text(0, piece))
            try await waitFor { await log.text == told }
            took.append(Date().timeIntervalSince(start))
        }
        let median = took.sorted()[took.count / 2]
        print("tap line told after (s):", took.map { String(format: "%.3f", $0) })
        XCTAssertLessThan(median, Double(OfficialSession.quietLook) / 1e9 * 0.6)
        _ = await session.close()
    }
}
