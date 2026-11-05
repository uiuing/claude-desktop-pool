import Foundation
import XCTest
@testable import PoolRuntime

private actor HTTPChunkGate {
    private var open = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release() {
        open = true
        let pending = waiting; waiting.removeAll()
        for continuation in pending { continuation.resume() }
    }
}

private struct RuntimeHTTPResponse: Sendable {
    let chunks: [Data]
    let gate: HTTPChunkGate
    let advertisedLength: Int?
}

private final class RuntimeFixtureProtocol: URLProtocol, @unchecked Sendable {
    private static let routesLock = NSLock()
    private static var routes: [URL: RuntimeHTTPResponse] = [:]
    private let stateLock = NSLock()
    private var worker: Task<Void, Never>?
    private var gate: HTTPChunkGate?
    private var stopped = false

    static func register(_ response: RuntimeHTTPResponse, at url: URL) { routesLock.withLock { routes[url] = response } }
    static func remove(_ url: URL) { _ = routesLock.withLock { routes.removeValue(forKey: url) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let response = Self.routesLock.withLock({ Self.routes[url] }) else {
            client?.urlProtocol(self, didFailWithError: RuntimeInstallError.downloadFailed); return
        }
        let worker = Task { [self] in
            guard !Task.isCancelled else { return }
            var headers = ["Content-Type": "application/octet-stream"]
            if let length = response.advertisedLength { headers["Content-Length"] = String(length) }
            let http = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            for (index, chunk) in response.chunks.enumerated() {
                guard !Task.isCancelled else { return }
                client?.urlProtocol(self, didLoad: chunk)
                if index == 0 { await response.gate.wait() }
            }
            guard !Task.isCancelled else { return }
            client?.urlProtocolDidFinishLoading(self)
        }
        let cancel = stateLock.withLock { () -> Bool in
            self.worker = worker; gate = response.gate
            return stopped
        }
        if cancel { worker.cancel(); Task { await response.gate.release() } }
    }

    override func stopLoading() {
        let pending = stateLock.withLock { () -> (Task<Void, Never>?, HTTPChunkGate?) in
            stopped = true; return (worker, gate)
        }
        pending.0?.cancel()
        if let gate = pending.1 { Task { await gate.release() } }
    }
}

private final class ReceivedRuntimeBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var content = Data()
    private var complete = false
    func append(_ data: Data) { lock.withLock { content.append(data) } }
    func finish() { lock.withLock { complete = true } }
    var bytes: Data { lock.withLock { content } }
    var finished: Bool { lock.withLock { complete } }
}

final class RuntimeDownloaderTests: XCTestCase {
    private func fixture(chunks: [Data], advertisedLength: Int?) throws -> (URL, HTTPChunkGate, OfficialRuntimeDownloader) {
        let url = try XCTUnwrap(URL(string: "https://downloads.claude.ai/claude-code-releases/fixture/\(UUID().uuidString)/claude"))
        let gate = HTTPChunkGate()
        RuntimeFixtureProtocol.register(RuntimeHTTPResponse(chunks: chunks, gate: gate, advertisedLength: advertisedLength), at: url)
        addTeardownBlock { RuntimeFixtureProtocol.remove(url) }
        let downloader = OfficialRuntimeDownloader(configuration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [RuntimeFixtureProtocol.self]
            return configuration
        })
        return (url, gate, downloader)
    }

    func testURLSessionDeliversRealChunksBeforeDownloadFinishes() async throws {
        let chunks = [Data(repeating: 1, count: 64 * 1024), Data(repeating: 2, count: 64 * 1024),
                      Data(repeating: 3, count: 64 * 1024)]
        let total = chunks.reduce(0) { $0 + $1.count }
        let (url, gate, downloader) = try fixture(chunks: chunks, advertisedLength: total)
        let received = ReceivedRuntimeBytes()
        let operation = Task {
            try await downloader.fetch(url, maximumBytes: Int64(total)) { received.append($0) }
            received.finish()
        }
        defer { operation.cancel() }
        try await eventually { received.bytes.count == chunks[0].count }
        XCTAssertFalse(received.finished)
        XCTAssertEqual(received.bytes, chunks[0])
        await gate.release()
        try await operation.value
        XCTAssertEqual(received.bytes, chunks.reduce(Data(), +))
        XCTAssertTrue(received.finished)
    }

    func testCancellationStopsPartialTransferWithoutCompletion() async throws {
        let chunks = [Data(repeating: 1, count: 64 * 1024), Data(repeating: 2, count: 64 * 1024)]
        let total = chunks.reduce(0) { $0 + $1.count }
        let (url, _, downloader) = try fixture(chunks: chunks, advertisedLength: total)
        let received = ReceivedRuntimeBytes()
        let operation = Task {
            try await downloader.fetch(url, maximumBytes: Int64(total)) { received.append($0) }
            received.finish()
        }
        defer { operation.cancel() }
        try await eventually { received.bytes.count == chunks[0].count }
        operation.cancel()
        do { try await operation.value; XCTFail("Cancelled transfer must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(received.bytes, chunks[0]); XCTAssertFalse(received.finished)
    }

    func testUnknownContentLengthStillEnforcesStreamingBound() async throws {
        let first = Data(repeating: 1, count: 64 * 1024)
        let (url, gate, downloader) = try fixture(chunks: [first, Data(repeating: 2, count: 64 * 1024)], advertisedLength: nil)
        let received = ReceivedRuntimeBytes()
        let operation = Task { try await downloader.fetch(url, maximumBytes: Int64(first.count)) { received.append($0) } }
        defer { operation.cancel() }
        try await eventually { received.bytes.count == first.count }
        await gate.release()
        do { try await operation.value; XCTFail("Oversized stream must fail") }
        catch { XCTAssertEqual(error as? RuntimeInstallError, .verificationFailed) }
        XCTAssertEqual(received.bytes, first)
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw RuntimeInstallError.downloadFailed }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}
