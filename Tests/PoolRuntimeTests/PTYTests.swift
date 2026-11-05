import Foundation
import XCTest
@testable import PoolRuntime

private final class TerminalCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) { lock.withLock { bytes.append(data) } }
    var text: String { lock.withLock { String(decoding: bytes, as: UTF8.self) } }
}

final class PTYTests: XCTestCase {
    private func fixture(script: String) throws -> (URL, URL) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/runtime-fixtures/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("fake-client")
        try Data(("#!/bin/sh\n" + script).utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return (root, executable)
    }

    private func start(_ root: URL, _ executable: URL) throws -> OwnedPTY {
        let process = try OwnedPTY.start(executable: executable, arguments: [], environment: ["PATH": "/usr/bin:/bin", "TERM": "xterm"], directory: root)
        addTeardownBlock {
            if process.isRunning {
                try process.interrupt()
                _ = try await process.waitForExit()
            }
        }
        return process
    }

    func testOwnedTerminalReceivesInputAndIsReaped() async throws {
        let (root, executable) = try fixture(script: "stty -echo\ntest -t 0 || exit 9\nprintf 'ready\\n'\nIFS= read -r -t 5 answer\nprintf 'received:%s\\n' \"$answer\"\nexit 7\n")
        let process = try start(root, executable), capture = TerminalCapture(), ready = expectation(description: "owned terminal ready")
        let observer = Task {
            var announced = false
            for await event in process.events {
                if case .output(let data) = event {
                    capture.append(data)
                    if !announced && capture.text.contains("ready") { announced = true; ready.fulfill() }
                }
            }
        }
        await fulfillment(of: [ready], timeout: 5)
        try process.write(Data("hello\n".utf8))
        let status = try await process.waitForExit()
        await observer.value
        XCTAssertEqual(status, 7)
        XCTAssertFalse(process.isRunning)
        XCTAssertTrue(capture.text.contains("received:hello"))
        XCTAssertThrowsError(try process.write(Data("after exit".utf8)))
    }

    func testTimeoutPreservesProcessUntilNormalExit() async throws {
        let (root, executable) = try fixture(script: "stty -echo\nIFS= read -r -t 5 answer\nexit 0\n")
        let process = try start(root, executable)
        do { _ = try await process.waitForExit(timeout: 0.05); XCTFail("Expected timeout") }
        catch { XCTAssertEqual(error as? RuntimeError, .processUnresponsive) }
        XCTAssertTrue(process.isRunning)
        try process.exitWhenIdle()
        let status = try await process.waitForExit()
        XCTAssertEqual(status, 0)
    }

    func testTerminalInterruptOnlyAffectsOwnedChild() async throws {
        let (root, executable) = try fixture(script: "stty -echo\ntrap 'exit 0' INT\nprintf 'ready\\n'\nfor n in 1 2 3 4 5 6 7 8 9 10; do sleep 0.2; done; exit 3\n")
        let process = try start(root, executable), ready = expectation(description: "interrupt handler ready")
        let observer = Task {
            var sent = false
            for await event in process.events {
                if case .output(let data) = event, !sent, String(decoding: data, as: UTF8.self).contains("ready") {
                    sent = true; ready.fulfill()
                }
            }
        }
        await fulfillment(of: [ready], timeout: 5)
        try process.interrupt()
        let status = try await process.waitForExit()
        await observer.value
        XCTAssertEqual(status, 0)
    }

    func testRejectsControlSequencesAndReportsLaunchFailure() async throws {
        let (root, executable) = try fixture(script: "IFS= read -r -t 5 answer\n")
        let process = try start(root, executable)
        for unsafe in ["text\u{1b}[201~\rcommand", "text\u{3}", "text\u{7}", "first\nsecond", ""] {
            do { try await process.submitLine(unsafe, bracketed: true); XCTFail("Unsafe input was sent") }
            catch { XCTAssertEqual(error as? RuntimeError, .invalidTerminalInput) }
        }
        try process.exitWhenIdle()
        _ = try await process.waitForExit()
        XCTAssertThrowsError(try OwnedPTY.start(executable: executable, arguments: [], environment: [:], directory: root.appendingPathComponent("missing")))
    }

    func testCancellingObserverDoesNotDisconnectLaterObserver() async throws {
        let (root, executable) = try fixture(script: "stty -echo\nprintf 'ready\\n'\nIFS= read -r -t 5 answer\nprintf 'finished\\n'\n")
        let process = try start(root, executable), ready = expectation(description: "first observer")
        let first = Task {
            for await event in process.events {
                if case .output(let data) = event, String(decoding: data, as: UTF8.self).contains("ready") {
                    ready.fulfill(); break
                }
            }
        }
        await fulfillment(of: [ready], timeout: 5)
        first.cancel(); await first.value
        let capture = TerminalCapture()
        let later = Task {
            for await event in process.events {
                if case .output(let data) = event { capture.append(data) }
            }
        }
        try process.exitWhenIdle()
        _ = try await process.waitForExit()
        await later.value
        XCTAssertTrue(capture.text.contains("ready"))
        XCTAssertTrue(capture.text.contains("finished"))
    }
}
