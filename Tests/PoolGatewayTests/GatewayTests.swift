import Foundation
import XCTest
@testable import PoolGateway
import PoolCore

private let fixtureToken = "fixture-local-token-0123456789-abcdefgh"

final class GatewayTests: XCTestCase {
    private func message(stream: Bool = false) throws -> Data {
        try JSONEncoder().encode(BridgeRequest(model: "claude-sonnet", messages: [.init(role: "user", content: .string("A synthetic greeting."))], stream: stream))
    }
    private func headers() -> [String: String] {
        ["host": "127.0.0.1:18473", "authorization": "Bearer " + fixtureToken, "content-type": "application/json"]
    }
    func testParserWaitsForWholeRequest() throws {
        let body = try message()
        let head = Data("POST /v1/messages HTTP/1.1\r\nHost: 127.0.0.1:18473\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        var parser = GatewayHTTPParser()
        XCTAssertNil(try parser.append(head + body.prefix(5)))
        let request = try XCTUnwrap(parser.append(body.dropFirst(5)))
        XCTAssertEqual(request.body, body)
        XCTAssertEqual(request.headers["host"], "127.0.0.1:18473")
    }
    func testParserRejectsAmbiguousFraming() {
        let requests = [
            "POST /v1/messages HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n",
            "POST /v1/messages HTTP/1.1\r\nContent-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\n",
            "POST /v1/messages HTTP/1.1\r\nContent-Length: +4\r\n\r\ntest",
            "GET /health HTTP/1.1\r\nHost : 127.0.0.1\r\n\r\n",
            "GET /health HTTP/1.1\r\n folded: bad\r\n\r\n",
            "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\nGET /health HTTP/1.1\r\n\r\n"
        ]
        for input in requests {
            var parser = GatewayHTTPParser()
            XCTAssertThrowsError(try parser.append(Data(input.utf8)))
        }
    }
    func testParserBoundsHeadersAndBody() {
        var headers = GatewayHTTPParser()
        XCTAssertThrowsError(try headers.append(Data(repeating: 65, count: GatewayHTTPParser.maximumHeaderBytes + 1)))
        var body = GatewayHTTPParser()
        XCTAssertThrowsError(try body.append(Data("POST /v1/messages HTTP/1.1\r\nContent-Length: \(GatewayHTTPParser.maximumBodyBytes + 1)\r\n\r\n".utf8)))
    }
    func testRouterRequiresOriginFreeLiteralHostAndCredential() throws {
        let router = try GatewayRouter(port: 18473, token: fixtureToken)
        for origin in ["null", "https://untrusted.invalid", ""] {
            var h = headers(); h["origin"] = origin
            XCTAssertThrowsError(try router.route(.init(method: "GET", path: "/health", headers: h)))
        }
        for host in ["localhost:18473", "127.0.0.1:80", "evil.invalid:18473", "[::1]:18473"] {
            var h = headers(); h["host"] = host
            XCTAssertThrowsError(try router.route(.init(method: "GET", path: "/health", headers: h)))
        }
        var h = headers(); h.removeValue(forKey: "authorization")
        XCTAssertThrowsError(try router.route(.init(method: "GET", path: "/health", headers: h)))
        h["authorization"] = "Bearer " + String(fixtureToken.dropLast()) + "z"
        XCTAssertThrowsError(try router.route(.init(method: "GET", path: "/health", headers: h)))
        guard case .response(let healthy) = try router.route(.init(method: "GET", path: "/health", headers: headers())) else { return XCTFail() }
        XCTAssertEqual(healthy.status, 200)
        XCTAssertFalse(String(decoding: healthy.body, as: UTF8.self).contains(fixtureToken))
    }
    func testValidationTakesControlsTheClientCannotApplyAndRefusesMalformedContent() throws {
        let valid = try JSONDecoder().decode(JSONValue.self, from: message()).objectValue!
        let controls: [String: JSONValue] = ["stop_sequences": .array([.string("stop")]), "tool_choice": .object(["type": .string("any")]),
            "output_config": .object(["format": .object(["type": .string("json_schema")])]), "mcp_servers": .array([])]
        for (key, value) in controls {
            var request = valid; request[key] = value
            XCTAssertNoThrow(try GatewayRequestValidation.decode(JSONValue.object(request).encoded()), key)
        }
        var any = valid; any["tool_choice"] = .object(["type": .string("any")])
        XCTAssertEqual(try GatewayRequestValidation.decode(JSONValue.object(any).encoded()).toolChoice, "required")
        // a block of any kind goes as it came, the service deciding on it; one with no kind at all is malformed
        var untyped = valid
        untyped["messages"] = .array([.object(["role": .string("user"), "content": .array([.object(["text": .string("No type.")])])])])
        XCTAssertThrowsError(try GatewayRequestValidation.decode(JSONValue.object(untyped).encoded()))
        var image = valid
        image["messages"] = .array([.object(["role": .string("user"), "content": .array([.object(["type": .string("image")])])])])
        XCTAssertEqual(try GatewayRequestValidation.decode(JSONValue.object(image).encoded()).messages[0].content,
                       .array([.object(["type": .string("image")])]))
    }
    func testDefaultReasoningAndToolSelectionAccepted() throws {
        var request = try JSONDecoder().decode(JSONValue.self, from: message()).objectValue!
        request["thinking"] = .object(["type": .string("adaptive")])
        request["tool_choice"] = .object(["type": .string("auto"), "disable_parallel_tool_use": .bool(false)])
        XCTAssertEqual(try GatewayRequestValidation.decode(JSONValue.object(request).encoded()).model, "claude-sonnet")
    }
    func testToolScreenshotDataIsPreservedAndBounded() throws {
        let pixels = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9ZlSMAAAAASUVORK5CYII="
        func request(source: JSONValue) throws -> Data {
            let result = JSONValue.object(["type": .string("tool_result"), "tool_use_id": .string("tool_fixture"),
                "content": .array([.object(["type": .string("text"), "text": .string("Fixture screenshot")]),
                    .object(["type": .string("image"), "source": source])])])
            return try JSONEncoder().encode(BridgeRequest(model: "claude-sonnet", messages: [.init(role: "user", content: .array([result]))]))
        }
        for media in ["image/png", "image/jpeg", "image/webp", "image/gif"] {
            let source = JSONValue.object(["type": .string("base64"), "media_type": .string(media), "data": .string(pixels)])
            let decoded = try GatewayRequestValidation.decode(request(source: source))
            XCTAssertEqual(decoded.messages[0].content.arrayValue?[0]["content"]?.arrayValue?[1]["source"], source)
        }
        // an image of any other source goes as the tool returned it: the service, not Pool, decides on it
        let asSent: [JSONValue] = [
            .object(["type": .string("url"), "url": .string("https://untrusted.invalid/image.png")]),
            .object(["type": .string("base64"), "media_type": .string("image/svg+xml"), "data": .string(pixels)]),
            .object(["type": .string("base64"), "media_type": .string("image/png"), "data": .string("")]),
            .object(["type": .string("base64"), "media_type": .string("image/png"), "data": .string("not base64!")]),
            .object(["type": .string("base64"), "media_type": .string("image/png"), "data": .string(Data(repeating: 0, count: 4 * 1024 * 1024 + 1).base64EncodedString())])
        ]
        for source in asSent {
            let decoded = try GatewayRequestValidation.decode(request(source: source))
            XCTAssertEqual(decoded.messages[0].content.arrayValue?[0]["content"]?.arrayValue?[1]["source"], source)
        }
    }
    /// The person's images are kept as they came, those Pool could not paste too: the service decides on them.
    func testUserImageInputIsKeptAsItCame() throws {
        let pixels = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9ZlSMAAAAASUVORK5CYII="
        let image = JSONValue.object(["type": .string("image"), "source": .object([
            "type": .string("base64"), "media_type": .string("image/png"), "data": .string(pixels)])])
        let request = BridgeRequest(model: "claude-sonnet", messages: [.init(role: "user", content: .array([
            .object(["type": .string("text"), "text": .string("Compare these")]), image, image]))])
        let decoded = try GatewayRequestValidation.decode(JSONEncoder().encode(request))
        XCTAssertEqual(decoded.messages, request.messages)
        var mismatched = image["source"]!.objectValue!
        mismatched["media_type"] = .string("image/jpeg")
        var other = request
        for content in [JSONValue.array([.object(["type": .string("image"), "source": .object(mismatched)])]),
                        .array([.object(["type": .string("image"), "source": .object([
                            "type": .string("url"), "url": .string("https://untrusted.invalid/image.png")])])])] {
            other.messages[0].content = content
            XCTAssertEqual(try GatewayRequestValidation.decode(JSONEncoder().encode(other)).messages, other.messages)
        }
    }
    func testConversationIdentityRejectsConflictsAndIgnoresPlainUserIDs() throws {
        var request = BridgeRequest(model: "claude-sonnet", messages: [.init(role: "user", content: .string("A fixture"))])
        request.metadata = .object(["user_id": .string("not-a-conversation")])
        XCTAssertNil(try GatewayRequestValidation.conversationID(headers: [:], request: request))
        request.metadata = .object(["user_id": .string("{\"session_id\":\"fixture-session\"}")])
        XCTAssertEqual(try GatewayRequestValidation.conversationID(headers: [:], request: request), "fixture-session")
        XCTAssertThrowsError(try GatewayRequestValidation.conversationID(headers: ["x-session-id": "another-session"], request: request))
    }
    func testResponseKeepsToolsOrderedAndSaysUsageAtTheEnd() throws {
        var encoder = MessageResponseEncoder(model: "claude-sonnet", id: "msg_fixture")
        XCTAssertEqual(try encoder.encode(.usage(.init(inputTokens: 1, outputTokens: 0))), [], "Usage alone is no answer yet.")
        XCTAssertFalse(encoder.started)
        var chunks = try encoder.encode(.text("First\nline"))
        XCTAssertTrue(encoder.started)
        chunks += try encoder.encode(.toolUse(.init(id: "tool_fixture", name: "read_file", input: .object(["path": .string("fixture.txt")]))))
        chunks += try encoder.encode(.usage(.init(inputTokens: 12, outputTokens: 4)))
        chunks += try encoder.encode(.finished(.toolUse))
        let wire = String(decoding: chunks.reduce(Data(), +), as: UTF8.self)
        XCTAssertTrue(wire.hasPrefix("event: message_start\n"))
        XCTAssertTrue(wire.contains("event: content_block_stop\n"))
        XCTAssertTrue(wire.contains("\"output_tokens\":4"))
        XCTAssertTrue(wire.hasSuffix("event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"))
        let body = try JSONDecoder().decode(JSONValue.self, from: encoder.completeBody())
        XCTAssertEqual(body["usage"]?["input_tokens"], .number(12))
        XCTAssertEqual(body["stop_reason"], .string("tool_use"))
        XCTAssertEqual(body["content"]?.arrayValue?.count, 2)
        XCTAssertEqual(body["content"]?.arrayValue?[1]["id"], .string("tool_fixture"))
        XCTAssertThrowsError(try encoder.encode(.text("Late event")))
    }
    /// Thinking is a block of its own, closed before the words open, its indexes running on with
    /// theirs and the call's; the whole body keeps it only with its signature.
    func testThinkingIsItsOwnBlockClosedBeforeTheWords() throws {
        var encoder = MessageResponseEncoder(model: "claude-sonnet", id: "msg_fixture")
        var chunks = try encoder.encode(.usage(.init(inputTokens: 3, outputTokens: 1)))
        chunks += try encoder.encode(.thinking("Weighing"))
        chunks += try encoder.encode(.thinking(" the file"))
        chunks += try encoder.encode(.thinkingSignature("c2lnLXN5bnRoZXRpYw=="))
        chunks += try encoder.encode(.text("Reading"))
        chunks += try encoder.encode(.toolUse(.init(id: "toolu_fixture", name: "read_file", input: .object(["path": .string("a")]))))
        chunks += try encoder.encode(.finished(.toolUse))
        let events = try Self.events(chunks)
        let blocks = events.filter { ($0["type"]?.stringValue ?? "").hasPrefix("content_block") }
            .map { "\($0["type"]!.stringValue!):\(Int($0["index"]?.doubleValue ?? -1)):" + ($0["content_block"]?["type"]?.stringValue ?? $0["delta"]?["type"]?.stringValue ?? "") }
        XCTAssertEqual(blocks, ["content_block_start:0:thinking", "content_block_delta:0:thinking_delta", "content_block_delta:0:thinking_delta",
                                "content_block_delta:0:signature_delta", "content_block_stop:0:",
                                "content_block_start:1:text", "content_block_delta:1:text_delta", "content_block_stop:1:",
                                "content_block_start:2:tool_use", "content_block_delta:2:input_json_delta", "content_block_stop:2:"])
        XCTAssertEqual(events.first { $0["type"] == .string("content_block_start") }?["content_block"],
                       .object(["type": .string("thinking"), "thinking": .string(""), "signature": .string("")]))
        let body = try JSONDecoder().decode(JSONValue.self, from: encoder.completeBody())
        XCTAssertEqual(body["content"]?.arrayValue?.map { $0["type"]?.stringValue ?? "" }, ["thinking", "text", "tool_use"])
        XCTAssertEqual(body["content"]?.arrayValue?.first,
                       .object(["type": .string("thinking"), "thinking": .string("Weighing the file"), "signature": .string("c2lnLXN5bnRoZXRpYw==")]))
    }
    /// Thinking cut off before its signature is shown as it streamed but left out of the whole body,
    /// so the client never sends it back unsigned.
    func testUnsignedThinkingIsLeftOutOfTheWholeBody() throws {
        var encoder = MessageResponseEncoder(model: "claude-sonnet", id: "msg_fixture")
        var chunks = try encoder.encode(.thinking("Weighing"))
        chunks += try encoder.encode(.text("Answer"))
        chunks += try encoder.encode(.finished(.endTurn))
        let starts = try Self.events(chunks).filter { $0["type"] == .string("content_block_start") }
        XCTAssertEqual(starts.map { Int($0["index"]?.doubleValue ?? -1) }, [0, 1])
        let body = try JSONDecoder().decode(JSONValue.self, from: encoder.completeBody())
        XCTAssertEqual(body["content"]?.arrayValue, [.object(["type": .string("text"), "text": .string("Answer")])])
    }
    private static func events(_ chunks: [Data]) throws -> [JSONValue] {
        try String(decoding: chunks.reduce(Data(), +), as: UTF8.self).components(separatedBy: "\n")
            .filter { $0.hasPrefix("data: ") }.map { try JSONDecoder().decode(JSONValue.self, from: Data($0.dropFirst(6).utf8)) }
    }
    /// What the request read, told before the reply, is in `message_start` as Anthropic's is: Claude
    /// Code counts the conversation's context from it, and from `message_delta` only the output.
    func testMessageStartSaysWhatTheRequestRead() throws {
        var encoder = MessageResponseEncoder(model: "claude-sonnet", id: "msg_fixture")
        var read = BridgeUsage(inputTokens: 2, outputTokens: 1, cacheReadInputTokens: 180_000, cacheCreationInputTokens: 900)
        var chunks = try encoder.encode(.usage(read))
        chunks += try encoder.encode(.text("Synthetic answer"))
        read.outputTokens = 40
        chunks += try encoder.encode(.usage(read))
        chunks += try encoder.encode(.finished(.endTurn))
        let wire = String(decoding: chunks.reduce(Data(), +), as: UTF8.self)
        let start = try XCTUnwrap(wire.components(separatedBy: "\n").first { $0.hasPrefix("data: {\"message\"") || ($0.hasPrefix("data: ") && $0.contains("\"message_start\"")) })
        let event = try JSONDecoder().decode(JSONValue.self, from: Data(start.dropFirst(6).utf8))
        XCTAssertEqual(event["message"]?["usage"]?["cache_read_input_tokens"], .number(180_000))
        XCTAssertEqual(event["message"]?["usage"]?["cache_creation_input_tokens"], .number(900))
        XCTAssertEqual(event["message"]?["usage"]?["input_tokens"], .number(2))
        let body = try JSONDecoder().decode(JSONValue.self, from: encoder.completeBody())
        XCTAssertEqual(body["usage"]?["output_tokens"], .number(40))
    }
    /// A reply the client never measured is whole with zero
    /// counts, never a failure, and none of its text is lost.
    func testUnobservedUsageCompletesWithZeroCounts() throws {
        var encoder = MessageResponseEncoder(model: "claude-sonnet")
        var chunks = try encoder.encode(.text("Synthetic answer"))
        chunks += try encoder.encode(.finished(.endTurn))
        let wire = String(decoding: chunks.reduce(Data(), +), as: UTF8.self)
        XCTAssertTrue(wire.contains("Synthetic answer"))
        XCTAssertTrue(wire.contains("\"input_tokens\":0") && wire.contains("\"output_tokens\":0"))
        XCTAssertTrue(wire.hasSuffix("event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n"))
        let body = try JSONDecoder().decode(JSONValue.self, from: encoder.completeBody())
        XCTAssertEqual(body["usage"]?["input_tokens"], .number(0))
        XCTAssertEqual(body["usage"]?["output_tokens"], .number(0))
        XCTAssertEqual(body["content"]?.arrayValue?.first?["text"], .string("Synthetic answer"))
    }
    func testKnownUsageRetainedAndIncompleteResponseFails() throws {
        var encoder = MessageResponseEncoder(model: "claude-sonnet")
        _ = try encoder.encode(.usage(.init(inputTokens: 12, outputTokens: 4)))
        _ = try encoder.encode(.text("Done"))
        XCTAssertThrowsError(try encoder.completeBody())
        _ = try encoder.encode(.finished(.endTurn))
        let body = try JSONDecoder().decode(JSONValue.self, from: encoder.completeBody())
        XCTAssertEqual(body["usage"]?["input_tokens"], .number(12))
        XCTAssertEqual(body["usage"]?["output_tokens"], .number(4))
    }
    func testRealLoopbackHTTPAndSSEUseInjectedBackend() async throws {
        let backend = FixtureBackend()
        let server = try GatewayServer(port: 0, token: fixtureToken, backend: backend)
        let port = try await server.start()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        do {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/messages")!)
            request.httpMethod = "POST"; request.httpBody = try message()
            request.setValue("Bearer " + fixtureToken, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 5
            let (data, response) = try await session.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "x-claude-pool-output-limit"), "official-client")
            let body = try JSONDecoder().decode(JSONValue.self, from: data)
            XCTAssertEqual(body["content"]?.arrayValue?.first?["text"], .string("Fixture reply."))
            request.httpBody = try message(stream: true)
            let (stream, streamResponse) = try await session.data(for: request)
            XCTAssertEqual((streamResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), "text/event-stream")
            XCTAssertTrue(String(decoding: stream, as: UTF8.self).contains("event: message_stop"))
            request.setValue("null", forHTTPHeaderField: "Origin")
            let (_, denied) = try await session.data(for: request)
            XCTAssertEqual((denied as? HTTPURLResponse)?.statusCode, 403)
            let seen = await backend.requests
            XCTAssertEqual(seen.count, 2)
            XCTAssertTrue(seen.allSatisfy { $0.hasPrefix("request:") })
        } catch {
            session.invalidateAndCancel(); await server.stop(); throw error
        }
        session.invalidateAndCancel(); await server.stop()
    }

    func testDeveloperRecordingKeepsTheBytesButNeverTheGatewayKey() async throws {
        let lock = NSLock()
        nonisolated(unsafe) var lines: [Data] = []
        DevRecord.install { entry in lock.withLock { lines.append(entry.line) } }
        defer { DevRecord.install(nil) }
        let server = try GatewayServer(port: 0, token: fixtureToken, backend: FixtureBackend())
        let port = try await server.start()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/messages")!)
        request.httpMethod = "POST"; request.httpBody = try message(stream: true)
        request.setValue("Bearer " + fixtureToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 5
        _ = try await session.data(for: request)
        await server.stop()
        let all = lock.withLock { lines }
        XCTAssertFalse(all.contains { String(decoding: $0, as: UTF8.self).contains(fixtureToken) })
        let records = all.compactMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        let received = try XCTUnwrap(records.first { $0["kind"] == .string("http.request") })
        XCTAssertEqual(received["data"]?["withheld_headers"], .array([.string("authorization")]))
        // A conversation is kept as a change from the session's last request; this is its first, so it is all there.
        let body = try XCTUnwrap(received["data"]?["body"]), conversation = try XCTUnwrap(body["conversation"])
        XCTAssertEqual(conversation["kept"], .number(0))
        guard case .object(var whole)? = body["json"] else { return XCTFail("The body was not kept as JSON") }
        whole["messages"] = conversation["messages"]
        for key in ["system", "tools"] where conversation[key] != .null { whole[key] = conversation[key] }
        XCTAssertEqual(JSONValue.object(whole), try JSONDecoder().decode(JSONValue.self, from: try message(stream: true)))
        let number = try XCTUnwrap(received["req"])
        let sent = records.filter { $0["kind"] == .string("http.sent") }
        XCTAssertTrue(sent.allSatisfy { $0["req"] == number })
        XCTAssertTrue(sent.compactMap { $0["data"]?["bytes"]?["text"]?.stringValue }.joined().contains("event: message_stop"))
        XCTAssertTrue(records.contains { $0["kind"] == .string("log.gateway.request") && $0["req"] == number })
    }

    func testNormalHTTPCompletionPreservesParkedToolCall() async throws {
        let backend = LifecycleBackend(toolResponse: true)
        let server = try GatewayServer(port: 0, token: fixtureToken, backend: backend)
        let port = try await server.start()
        let configuration = URLSessionConfiguration.ephemeral; configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        do {
            for streaming in [false, true] {
                var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/messages")!)
                request.httpMethod = "POST"; request.httpBody = try message(stream: streaming); request.timeoutInterval = 5
                request.setValue("Bearer " + fixtureToken, forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let (_, response) = try await session.data(for: request)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            }
        } catch {
            session.invalidateAndCancel(); await server.stop(); throw error
        }
        session.invalidateAndCancel(); await server.stop()
        let cancelled = await backend.cancelledCount
        XCTAssertEqual(cancelled, 0, "A completed tool-use HTTP response leaves its underlying MCP call parked.")
    }

    func testDisconnectCancelsOnlyItsActiveRequest() async throws {
        let started = expectation(description: "The fixture request started")
        let cancelled = expectation(description: "The fixture request was cancelled")
        let backend = LifecycleBackend(toolResponse: false, onStart: { started.fulfill() }, onCancel: { cancelled.fulfill() })
        let server = try GatewayServer(port: 0, token: fixtureToken, backend: backend)
        let port = try await server.start()
        let configuration = URLSessionConfiguration.ephemeral; configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/messages")!)
        request.httpMethod = "POST"; request.httpBody = try message(stream: true)
        request.setValue("Bearer " + fixtureToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("fixture-cancel-session", forHTTPHeaderField: "x-session-id")
        let task = Task { try await session.data(for: request) }
        await fulfillment(of: [started], timeout: 30)
        task.cancel()
        await fulfillment(of: [cancelled], timeout: 30)
        await backend.finish(); session.invalidateAndCancel(); await server.stop()
        let ids = await backend.cancelledIDs
        XCTAssertEqual(ids.count, 1)
        XCTAssertTrue(ids.first?.hasPrefix("fixture-cancel-session#") == true)
    }

    func testClaudeCodeRequestShapeIsAccepted() throws {
        var parser = GatewayHTTPParser()
        let head = "POST /v1/messages?beta=true HTTP/1.1\r\nHost: 127.0.0.1:18473\r\nContent-Length: 2\r\n\r\n{}"
        XCTAssertEqual(try parser.append(Data(head.utf8))?.path, "/v1/messages")
        var request = try JSONDecoder().decode(JSONValue.self, from: message()).objectValue!
        request["model"] = .string("claude-sonnet-4-5-20250929[1m]")
        request["temperature"] = .number(1)
        request["thinking"] = .object(["type": .string("enabled"), "budget_tokens": .number(1024)])
        request["output_config"] = .object(["effort": .string("high")])
        request["context_management"] = .object(["edits": .array([])])
        request["system"] = .array([
            .object(["type": .string("text"), "text": .string("x-anthropic-billing-header: cc_version=1; cch=abc;")]),
            .object(["type": .string("text"), "text": .string("You are helpful."), "cache_control": .object(["type": .string("ephemeral")])])])
        request["messages"] = .array([.object(["role": .string("user"), "content": .array([
            .object(["type": .string("text"), "text": .string("Hi"), "cache_control": .object(["type": .string("ephemeral")])])])])])
        let decoded = try GatewayRequestValidation.decode(JSONValue.object(request).encoded())
        XCTAssertEqual(decoded.model, "claude-sonnet")
        XCTAssertEqual(decoded.system, .array([.object(["type": .string("text"), "text": .string("You are helpful.")])]))
        XCTAssertEqual(decoded.messages.first?.content, .array([.object(["type": .string("text"), "text": .string("Hi")])]))
        XCTAssertEqual(PoolModel.resolve("claude-opus-4-1")?.id, "claude-opus")
        XCTAssertEqual(PoolModel.resolve("claude-haiku-4-5-20251001")?.id, "claude-haiku")
        XCTAssertNil(PoolModel.resolve("gpt-5"))
    }

    func testSideRequestsInOneSessionAreSeparateConversations() throws {
        let main = BridgeRequest(model: "claude-sonnet", messages: [.init(role: "user", content: .string("Work"))], system: .string("Main"))
        var title = main; title.system = .string("Write a title")
        var later = main; later.messages.append(.init(role: "user", content: .string("More")))
        let key = GatewayRequestValidation.conversationKey(session: "s", request: main)
        XCTAssertEqual(key, GatewayRequestValidation.conversationKey(session: "s", request: later))
        XCTAssertNotEqual(key, GatewayRequestValidation.conversationKey(session: "s", request: title))
    }

    func testAccountFailuresNeverLookLikeABadGatewayKey() {
        XCTAssertEqual(GatewayJSON.failure(BridgeFailure.accountUnavailable(.signedOut)).status, 403)
        let reset = Date().addingTimeInterval(120)
        let limited = GatewayJSON.failure(BridgeFailure.rateLimited(reset))
        XCTAssertEqual(limited.status, 429)
        XCTAssertEqual(limited.headers["Retry-After"].flatMap(Int.init).map { (119...121).contains($0) }, true)
        XCTAssertNil(GatewayJSON.failure(BridgeFailure.rateLimited(nil)).headers["Retry-After"])
        // The pool at its limit: a 429 said as Anthropic says a subscription's, with its reset.
        let back = Date().addingTimeInterval(3600)
        let pool = GatewayJSON.failure(BridgeFailure.poolLimited(back))
        XCTAssertEqual(pool.status, 429)
        XCTAssertEqual(pool.headers["Retry-After"].flatMap(Int.init).map { (3599...3601).contains($0) }, true)
        XCTAssertEqual(pool.headers["anthropic-ratelimit-unified-status"], "rejected")
        XCTAssertEqual(pool.headers["anthropic-ratelimit-unified-reset"], String(Int(back.timeIntervalSince1970.rounded(.up))))
        XCTAssertEqual(GatewayJSON.reason(BridgeFailure.poolLimited(back)), "poolLimited")
        XCTAssertNil(GatewayJSON.failure(BridgeFailure.poolLimited(nil)).headers["anthropic-ratelimit-unified-reset"])
    }

    func testDesktopConnectionCheckIsAnsweredWithoutASession() async throws {
        let backend = FixtureBackend(), checks = CheckRecorder()
        let server = try GatewayServer(port: 0, token: fixtureToken, backend: backend, onCheck: { checks.add($0) })
        let port = try await server.start()
        let configuration = URLSessionConfiguration.ephemeral; configuration.connectionProxyDictionary = [:]
        let session = URLSession(configuration: configuration)
        func send(_ body: String) async throws -> (Data, HTTPURLResponse) {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/messages")!)
            request.httpMethod = "POST"; request.httpBody = Data(body.utf8); request.timeoutInterval = 5
            request.setValue("Bearer " + fixtureToken, forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await session.data(for: request)
            return (data, try XCTUnwrap(response as? HTTPURLResponse))
        }
        do {
            let check = #"{"model":"claude-haiku-5-5","max_tokens":1,"messages":[{"role":"user","content":"."}]}"#
            let (data, response) = try await send(check)
            XCTAssertEqual(response.statusCode, 200)
            XCTAssertEqual(response.value(forHTTPHeaderField: "x-claude-pool-check"), "local")
            let body = try JSONDecoder().decode(JSONValue.self, from: data)
            XCTAssertEqual(body["model"], .string("claude-haiku-5-5"))
            XCTAssertEqual(body["content"], .array([]))
            XCTAssertEqual(body["stop_reason"], .string("max_tokens"))
            let (stream, streamed) = try await send(#"{"model":"claude-haiku-5-5","max_tokens":1,"stream":true,"messages":[{"role":"user","content":"."}]}"#)
            XCTAssertEqual(streamed.value(forHTTPHeaderField: "Content-Type"), "text/event-stream")
            XCTAssertTrue(String(decoding: stream, as: UTF8.self).contains("event: message_stop"))
            let started = await backend.requests
            XCTAssertTrue(started.isEmpty, "The check never starts a Claude session.")

            let reset = Date().addingTimeInterval(600)
            await backend.setAdmission(.rateLimited(reset))
            let (_, limited) = try await send(check)
            XCTAssertEqual(limited.statusCode, 429)
            XCTAssertNotNil(limited.value(forHTTPHeaderField: "Retry-After"))
            XCTAssertEqual(checks.failures, [nil, nil, .rateLimited(reset)])

            // Anything more than the check is a turn, and reaches the pool with the id it asked for.
            let (reply, turn) = try await send(#"{"model":"claude-haiku-5-5","max_tokens":200,"messages":[{"role":"user","content":"."}]}"#)
            XCTAssertEqual(turn.statusCode, 200)
            XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: reply)["model"], .string("claude-haiku-5-5"))
            let turns = await backend.requests
            XCTAssertEqual(turns.count, 1)
        } catch {
            session.invalidateAndCancel(); await server.stop(); throw error
        }
        session.invalidateAndCancel(); await server.stop()
    }

    func testConnectionCheckIsOnlyDesktopsCheck() throws {
        let check: [String: JSONValue] = ["model": .string("claude-haiku-5-5"), "max_tokens": .number(1),
            "messages": .array([.object(["role": .string("user"), "content": .string(".")])])]
        func body(_ fields: [String: JSONValue]) throws -> Data { try JSONValue.object(fields).encoded() }
        XCTAssertEqual(GatewayRequestValidation.connectionCheck(try body(check))?.model.id, "claude-haiku")
        var blocks = check
        blocks["messages"] = .array([.object(["role": .string("user"), "content": .array([.object(["type": .string("text"), "text": .string(".")])])])])
        XCTAssertNotNil(GatewayRequestValidation.connectionCheck(try body(blocks)))
        var longer = check; longer["max_tokens"] = .number(200)
        var titled = check; titled["system"] = .string("You write short session titles.")
        var tooled = check; tooled["tools"] = .array([])
        var worded = check; worded["messages"] = .array([.object(["role": .string("user"), "content": .string("hi")])])
        var unknown = check; unknown["model"] = .string("gpt-5")
        for variant in [longer, titled, tooled, worded, unknown] {
            XCTAssertNil(GatewayRequestValidation.connectionCheck(try body(variant)))
        }
    }

    func testModelListNamesTheOfficialModelsAndTheirTiers() throws {
        let router = try GatewayRouter(port: 18473, token: fixtureToken)
        guard case .response(let listed) = try router.route(.init(method: "GET", path: "/v1/models", headers: headers())) else { return XCTFail() }
        let rows = try JSONDecoder().decode(JSONValue.self, from: listed.body)["data"]?.arrayValue ?? []
        XCTAssertEqual(rows.compactMap { $0["id"]?.stringValue }, ["claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5", "claude-fable-5-2"])
        XCTAssertEqual(rows.compactMap { $0["anthropic_family_tier"]?.stringValue }, ["sonnet", "opus", "haiku", "fable"])
        XCTAssertEqual(rows.first?["display_name"], .string("Sonnet 5.5"))
        // What the client reports an alias runs on replaces the built-in id; old and new ids keep resolving.
        let newer = try XCTUnwrap(ModelIdentity(alias: "opus", id: "claude-opus-6", name: "Opus"))
        let models = PoolModel.listing([newer])
        XCTAssertEqual(models.map(\.listedID), ["claude-sonnet-5-5", "claude-opus-6", "claude-haiku-5-5", "claude-fable-5-2"])
        XCTAssertEqual(models[1].listedName, "Opus 6")
        XCTAssertEqual(PoolModel.resolve("claude-opus-6", in: models)?.id, "claude-opus")
        XCTAssertEqual(PoolModel.resolve("claude-opus-5-5", in: models)?.id, "claude-opus")
        XCTAssertEqual(PoolModel.resolve("claude-haiku", in: models)?.id, "claude-haiku")
    }
}

private final class CheckRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [BridgeFailure?] = []
    func add(_ check: GatewayCheck) { lock.lock(); stored.append(check.failure); lock.unlock() }
    var failures: [BridgeFailure?] { lock.lock(); defer { lock.unlock() }; return stored }
}

private actor FixtureBackend: BridgeBackend {
    var requests: [String] = []
    var admission: BridgeFailure?
    func setAdmission(_ failure: BridgeFailure?) { admission = failure }
    func checkAdmission(model: String) async throws { if let admission { throw admission } }
    func events(for request: BridgeRequest, conversationID: String?) async throws -> AsyncThrowingStream<BridgeEvent, Error> {
        requests.append(conversationID ?? "")
        return AsyncThrowingStream { continuation in
            continuation.yield(.text("Fixture reply.")); continuation.yield(.usage(.init(inputTokens: 4, outputTokens: 3)))
            continuation.yield(.finished(.endTurn)); continuation.finish()
        }
    }
    func cancel(conversationID: String) async {}
}

private actor LifecycleBackend: BridgeBackend {
    let toolResponse: Bool
    let onStart: @Sendable () -> Void
    let onCancel: @Sendable () -> Void
    var continuation: AsyncThrowingStream<BridgeEvent, Error>.Continuation?
    var cancelledIDs: [String] = []
    var cancelledCount: Int { cancelledIDs.count }
    init(toolResponse: Bool, onStart: @escaping @Sendable () -> Void = {}, onCancel: @escaping @Sendable () -> Void = {}) {
        self.toolResponse = toolResponse; self.onStart = onStart; self.onCancel = onCancel
    }
    func events(for request: BridgeRequest, conversationID: String?) async throws -> AsyncThrowingStream<BridgeEvent, Error> {
        let stream = AsyncThrowingStream<BridgeEvent, Error> { continuation in
            if toolResponse {
                continuation.yield(.usage(.init(inputTokens: 4, outputTokens: 3)))
                continuation.yield(.toolUse(.init(id: "tool_fixture", name: "read_file", input: .object([:]))))
                continuation.yield(.finished(.toolUse)); continuation.finish()
            } else {
                self.continuation = continuation
                continuation.yield(.text("Working"))
            }
        }
        onStart(); return stream
    }
    func cancel(conversationID: String) async {
        cancelledIDs.append(conversationID)
        continuation?.finish(throwing: BridgeFailure.cancelled); continuation = nil
        onCancel()
    }
    func finish() { continuation?.finish(throwing: BridgeFailure.cancelled); continuation = nil }
}
