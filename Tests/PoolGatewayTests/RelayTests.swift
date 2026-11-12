import Foundation
import XCTest
@testable import PoolGateway
import PoolCore

private let relayToken = String(repeating: "cd", count: 32)

/// How a reply reaches the client, as the relay hands it over: headers wait for the first of
/// the answer, so an error before it is a real status; after it, an `error` event ends the stream;
/// a failed reply is never cancelled by the gateway. Requests are shaped as Claude Code sends them
/// (ClaudeCodeShapeTests); the contents are synthetic.
final class RelayTests: XCTestCase {
    private static let secret = "PELICAN-SYNTHETIC-7"
    private func body(stream: Bool, toolResult: Bool = false) -> Data {
        let result = toolResult ? #"""
        ,{"role":"assistant","content":[{"type":"text","text":"Running it."},{"type":"tool_use","id":"toolu_01","name":"Bash","input":{"command":"echo synthetic"}}]},
        {"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_01","content":"synthetic output"}]}
        """# : ""
        return Data(#"""
        {"model":"claude-opus-5-5","max_tokens":32000,"stream":\#(stream),
         "system":[{"type":"text","text":"x-anthropic-billing-header: cc_version=2.1.318; cch=00000;"},
                   {"type":"text","text":"You are Claude Code, a synthetic fixture.","cache_control":{"type":"ephemeral","ttl":"1h"}}],
         "tools":[{"name":"Bash","description":"Run a command","input_schema":{"type":"object","properties":{"command":{"type":"string"}}}},
                  {"name":"ToolSearch","description":"Fetches deferred tools","input_schema":{"type":"object"}}],
         "messages":[{"role":"system","content":"","output_config":{"effort":"high"}},
                     {"role":"user","content":[{"type":"text","text":"Say \#(Self.secret) back.","cache_control":{"type":"ephemeral"}}]}\#(result)],
         "metadata":{"user_id":"{\"device_id\":\"fixture\",\"session_id\":\"relay-session\"}"},
         "thinking":{"type":"adaptive","display":"updates"},"output_config":{"effort":"high"},
         "context_management":{"edits":[{"type":"clear_thinking_20251015","keep":"all"}]},
         "safeguards":{"mode":"auto"},"speed":"fast","temperature":1}
        """#.utf8)
    }

    func testQuittingDoesNotWaitForAClientThatSaysNothing() async throws {
        let server = try GatewayServer(port: 0, token: relayToken, backend: ScriptBackend(events: [], failure: nil))
        let port = try await server.start()
        // A connection held open with no request stays for the 15-second header deadline.
        let client = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(client) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET); address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(connected, 0)
        try await Task.sleep(nanoseconds: 200_000_000)
        let began = Date()
        await server.stop(waitingAtMost: 0.2)
        XCTAssertLessThan(Date().timeIntervalSince(began), 5)
    }

    private func serve(_ backend: ScriptBackend, _ requests: [(stream: Bool, toolResult: Bool)]) async throws -> [(Data, HTTPURLResponse)] {
        let server = try GatewayServer(port: 0, token: relayToken, backend: backend)
        let port = try await server.start()
        let configuration = URLSessionConfiguration.ephemeral; configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        var answers: [(Data, HTTPURLResponse)] = []
        do {
            for item in requests {
                var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/messages?beta=true")!)
                request.httpMethod = "POST"; request.httpBody = body(stream: item.stream, toolResult: item.toolResult)
                request.timeoutInterval = 5
                request.setValue("Bearer " + relayToken, forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let (data, response) = try await session.data(for: request)
                answers.append((data, try XCTUnwrap(response as? HTTPURLResponse)))
            }
        } catch {
            session.invalidateAndCancel(); await server.stop(); throw error
        }
        session.invalidateAndCancel(); await server.stop()
        return answers
    }
    private func both(_ backend: ScriptBackend) async throws -> [(Data, HTTPURLResponse)] {
        try await serve(backend, [(true, false), (false, false)])
    }
    private func error(_ data: Data) -> JSONValue? { (try? JSONDecoder().decode(JSONValue.self, from: data))?["error"] }

    func testErrorBeforeAnyAnswerIsAStatusNotAStream() async throws {
        let reset = Date().addingTimeInterval(600)
        // What the logs showed: usage first, then the refusal. Usage is not an answer.
        let backend = ScriptBackend(events: [.usage(.init(inputTokens: 10, outputTokens: 0))], failure: BridgeFailure.rateLimited(reset))
        for (data, response) in try await both(backend) {
            XCTAssertEqual(response.statusCode, 429)
            XCTAssertNotEqual(response.value(forHTTPHeaderField: "Content-Type"), "text/event-stream")
            XCTAssertNotNil(response.value(forHTTPHeaderField: "Retry-After"))
            XCTAssertEqual(error(data)?["type"], .string("rate_limit_error"))
        }
        let cancelled = await backend.cancelled
        XCTAssertEqual(cancelled, [], "A failed reply is settled by the backend, not cancelled by the gateway.")
    }

    func testClaudeCodesOwnTooLongBeforeAnyEventIsA400InBothModes() async throws {
        let backend = ScriptBackend(events: [], failure: BridgeFailure.clientReported(status: 0, message: "Prompt is too long"))
        for (data, response) in try await both(backend) {
            XCTAssertEqual(response.statusCode, 400)
            XCTAssertEqual(error(data)?["type"], .string("invalid_request_error"))
            XCTAssertTrue(error(data)?["message"]?.stringValue?.hasPrefix("Prompt is too long") == true)
        }
        let cancelled = await backend.cancelled
        XCTAssertEqual(cancelled, [])
    }

    func testDeterministicFailuresAreNeverARetried503() async throws {
        let cases: [(ScriptBackend, Int, String)] = [
            (ScriptBackend(events: [], failure: nil), 502, "api_error"),                       // ended without an answer
            (ScriptBackend(events: [.usage(.init(inputTokens: 1, outputTokens: 0))], failure: BridgeFailure.compatibility), 502, "api_error"),
            (ScriptBackend(events: [], failure: nil, refusal: BridgeFailure.privacyUnavailable), 400, "invalid_request_error"),
            (ScriptBackend(events: [], failure: nil, refusal: BridgeFailure.busy), 503, "overloaded_error")]
        for (backend, status, type) in cases {
            for (data, response) in try await both(backend) {
                XCTAssertEqual(response.statusCode, status)
                XCTAssertEqual(error(data)?["type"], .string(type))
            }
            let cancelled = await backend.cancelled
            XCTAssertEqual(cancelled, [])
        }
        XCTAssertEqual(GatewayJSON.failure(BridgeFailure.transport).status, 502)
        XCTAssertEqual(GatewayJSON.failure(BridgeFailure.paused).status, 503)
        XCTAssertEqual(GatewayJSON.failure(BridgeFailure.privacyBusy).status, 503)
        XCTAssertEqual(GatewayJSON.failure(GatewayHTTPError.tooLarge).status, 413)
        XCTAssertEqual(error(GatewayJSON.failure(GatewayHTTPError.tooLarge).body)?["type"], .string("request_too_large"))
    }

    func testUsagelessTurnIsA200WithZeroUsage() async throws {
        let backend = ScriptBackend(events: [.text("Synthetic answer."), .finished(.endTurn)], failure: nil)
        let answers = try await both(backend)
        let (stream, streamed) = answers[0], (plain, response) = answers[1]
        XCTAssertEqual(streamed.statusCode, 200)
        XCTAssertEqual(streamed.value(forHTTPHeaderField: "Content-Type"), "text/event-stream")
        let wire = String(decoding: stream, as: UTF8.self)
        XCTAssertTrue(wire.contains("Synthetic answer.") && wire.hasSuffix("event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"))
        XCTAssertEqual(response.statusCode, 200)
        let message = try JSONDecoder().decode(JSONValue.self, from: plain)
        XCTAssertEqual(message["usage"]?["input_tokens"], .number(0))
        XCTAssertEqual(message["usage"]?["output_tokens"], .number(0))
        XCTAssertEqual(message["model"], .string("claude-opus-5-5"))
    }

    func testFailureAfterTheAnswerBeganEndsTheStreamOnAnErrorEventAndIsAStatusUnstreamed() async throws {
        let backend = ScriptBackend(events: [.text("Partial synthetic"), .usage(.init(inputTokens: 3, outputTokens: 1))],
                                    failure: BridgeFailure.transport)
        let answers = try await both(backend)
        let wire = String(decoding: answers[0].0, as: UTF8.self)
        XCTAssertEqual(answers[0].1.statusCode, 200)
        XCTAssertTrue(wire.contains("Partial synthetic"))
        XCTAssertTrue(wire.hasSuffix("\n\n") && wire.contains("event: error\ndata: "))
        XCTAssertFalse(wire.contains("message_stop"), "Nothing follows an error event.")
        XCTAssertFalse(wire.contains("message_delta"))
        // Unstreamed, text before the failure is no answer: a 200 would pass it off as a whole one.
        XCTAssertEqual(answers[1].1.statusCode, 502)
        XCTAssertFalse(String(decoding: answers[1].0, as: UTF8.self).contains("Partial synthetic"))
        let cancelled = await backend.cancelled
        XCTAssertEqual(cancelled, [], "The retry carrying a tool result must find the conversation settled, not cancelled.")
    }

    func testEveryRequestLeavesOneContentFreeDiagnosticsLine() async throws {
        let lines = Lines()
        Diagnostics.install { lines.add($0) }
        defer { Diagnostics.install(nil) }
        let call = BridgeToolCall(id: "toolu_02", name: "Bash", input: .object(["command": .string("echo " + Self.secret)]))
        let usage = BridgeUsage(inputTokens: 6, outputTokens: 41, cacheReadInputTokens: 182_340, cacheCreationInputTokens: 2_118,
                                oneHourCacheWrites: 2_118)
        let backend = ScriptBackend(events: [.text("Echoing " + Self.secret), .toolUse(call), .usage(usage), .finished(.toolUse)], failure: nil)
        _ = try await serve(backend, [(true, false), (false, true)])
        let failing = ScriptBackend(events: [], failure: BridgeFailure.rateLimited(nil))
        _ = try await serve(failing, [(true, true)])
        let recorded = await lines.waitFor(count: 3)
        let requests = recorded.filter { $0.hasPrefix("event=gateway.request ") }
        XCTAssertEqual(requests.count, 3, recorded.joined(separator: "\n"))
        XCTAssertTrue(recorded.contains { $0.hasPrefix("event=gateway.listen ") })
        XCTAssertTrue(recorded.contains { $0.hasPrefix("event=gateway.stop ") })
        for line in recorded {
            XCTAssertFalse(line.contains(Self.secret), line)
            XCTAssertFalse(line.contains("Bash") || line.contains("echo") || line.contains("relay-session") || line.contains(relayToken), line)
        }
        guard requests.count == 3 else { return }
        let first = fields(requests[0]), second = fields(requests[1]), third = fields(requests[2])
        XCTAssertEqual(first["kind"], "turn"); XCTAssertEqual(first["stream"], "yes"); XCTAssertEqual(first["outcome"], "tool_use")
        XCTAssertEqual(first["status"], "200"); XCTAssertEqual(first["msgs"], "1"); XCTAssertEqual(first["tools"], "2")
        XCTAssertEqual(first["model"], "claude-opus-5-5"); XCTAssertEqual(first["events"], "4")
        XCTAssertEqual(first["in"], "6"); XCTAssertEqual(first["out"], "41")
        XCTAssertEqual(first["cache_r"], "182340"); XCTAssertEqual(first["cache_w"], "2118"); XCTAssertEqual(first["cache_w1h"], "2118")
        XCTAssertEqual(second["cache_r"], "182340", "An unstreamed reply logs its usage too.")
        XCTAssertNotEqual(first["headers_ms"], "-"); XCTAssertNotNil(first["total_ms"].flatMap(Int.init))
        XCTAssertNotNil(first["parse_ms"].flatMap(Int.init)); XCTAssertNotNil(third["parse_ms"].flatMap(Int.init))
        XCTAssertEqual(first["conv"], second["conv"], "One conversation keeps one tag.")
        XCTAssertEqual(second["kind"], "tool_result"); XCTAssertEqual(second["stream"], "no"); XCTAssertEqual(second["msgs"], "3")
        XCTAssertEqual(third["outcome"], "failed"); XCTAssertEqual(third["status"], "429")
        XCTAssertEqual(third["type"], "rate_limit_error"); XCTAssertEqual(third["reason"], "rateLimited")
        XCTAssertEqual(third["cache_r"], "-", "A reply that told no usage logs none, not zero."); XCTAssertEqual(third["in"], "-")
    }
    private func fields(_ line: String) -> [String: String] {
        Dictionary(line.split(separator: " ").compactMap { pair in
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }, uniquingKeysWith: { a, _ in a })
    }
}

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func add(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    /// A request's line is written once its answer went out, so the client can be ahead of it.
    func waitFor(count: Int) async -> [String] {
        for _ in 0..<100 {
            if all.filter({ $0.hasPrefix("event=gateway.request ") }).count >= count { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return all
    }
}

private actor ScriptBackend: BridgeBackend {
    let script: [BridgeEvent]
    let failure: Error?
    let refusal: Error?
    var cancelled: [String] = []
    init(events: [BridgeEvent], failure: Error?, refusal: Error? = nil) {
        script = events; self.failure = failure; self.refusal = refusal
    }
    func events(for request: BridgeRequest, conversationID: String?) async throws -> AsyncThrowingStream<BridgeEvent, Error> {
        if let refusal { throw refusal }
        let script = self.script, failure = self.failure
        return AsyncThrowingStream { continuation in
            for event in script { continuation.yield(event) }
            continuation.finish(throwing: failure)
        }
    }
    func cancel(conversationID: String) async { cancelled.append(conversationID) }
}
