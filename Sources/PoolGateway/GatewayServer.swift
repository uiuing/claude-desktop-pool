import Foundation
import Network
import PoolCore

public actor GatewayServer {
    private let requestedPort: UInt16
    private let token: String
    private let backend: any BridgeBackend
    private var models: [PoolModel]
    private let onCheck: @Sendable (GatewayCheck) -> Void
    private let queue = DispatchQueue(label: "ClaudePool.gateway")
    private var listener: NWListener?
    private var listenerID: UUID?
    private var startup: CheckedContinuation<UInt16, Error>?
    private var connections: [UUID: Task<Void, Never>] = [:]
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []
    private var accepting = false
    private var stopping = false
    /// Connections taken since launch: the `req` of each diagnostics line.
    private var accepted = 0
    public private(set) var port: UInt16 = 0
    public var activeRequestCount: Int { connections.count }

    public init(port: UInt16, token: String, backend: any BridgeBackend, models: [PoolModel] = PoolModel.defaults,
                onCheck: @escaping @Sendable (GatewayCheck) -> Void = { _ in }) throws {
        _ = try GatewayRouter(port: port, token: token, models: models)
        self.requestedPort = port; self.token = token; self.backend = backend; self.models = models; self.onCheck = onCheck
    }
    /// Clients listing models from now on see these.
    public func updateModels(_ models: [PoolModel]) { self.models = models }

    @discardableResult
    public func start() async throws -> UInt16 {
        if accepting, port != 0 { return port }
        guard listener == nil, !stopping else { throw BridgeFailure.busy }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: requestedPort)!)
        parameters.allowLocalEndpointReuse = false
        let created = try NWListener(using: parameters)
        let generation = UUID()
        listener = created; listenerID = generation
        created.stateUpdateHandler = { [weak self] state in Task { await self?.stateChanged(state, generation: generation) } }
        created.newConnectionHandler = { [weak self] connection in
            Task {
                guard let self else { connection.cancel(); return }
                await self.accept(connection)
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            startup = continuation
            created.start(queue: queue)
        }
    }

    /// Stops admission, then waits for accepted HTTP responses, for `limit` seconds at most when
    /// given. It never ends a Claude process.
    public func stop(waitingAtMost limit: TimeInterval? = nil) async {
        if listener != nil { Diagnostics.record("gateway.stop", ["port": String(port), "active": String(connections.count)]) }
        accepting = false; stopping = true
        let old = listener; listener = nil; listenerID = nil; old?.cancel()
        startup?.resume(throwing: BridgeFailure.cancelled); startup = nil
        guard !connections.isEmpty else { stopping = false; return }
        if let limit {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, limit) * 1_000_000_000))
                await self?.stopWaiting()
            }
        }
        await withCheckedContinuation { drainWaiters.append($0) }
    }
    private func stopWaiting() {
        guard !drainWaiters.isEmpty else { return }
        Diagnostics.record("gateway.drain_limit", ["active": String(connections.count)])
        let waiters = drainWaiters; drainWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func stateChanged(_ state: NWListener.State, generation: UUID) {
        guard listenerID == generation else { return }
        switch state {
        case .ready:
            guard let bound = listener?.port?.rawValue else { return }
            port = bound; accepting = true
            Diagnostics.record("gateway.listen", ["port": String(bound)])
            startup?.resume(returning: bound); startup = nil
        case .failed:
            Diagnostics.record("gateway.listen_failed", ["port": String(requestedPort)])
            accepting = false; listener?.cancel(); listener = nil
            startup?.resume(throwing: GatewayHTTPError(status: 503, message: "The local connection could not start. Its port may already be in use.")); startup = nil
        case .cancelled:
            startup?.resume(throwing: BridgeFailure.cancelled); startup = nil
        default: break
        }
    }

    private func accept(_ connection: NWConnection) {
        guard accepting, connections.count < 32, Self.isLoopback(connection.endpoint) else { connection.cancel(); return }
        let id = UUID()
        let router: GatewayRouter
        do { router = try GatewayRouter(port: port, token: token, models: models) }
        catch { connection.cancel(); return }
        accepted += 1
        let session = GatewayConnection(connection: connection, router: router, backend: backend, queue: queue, onCheck: onCheck, number: accepted)
        connections[id] = Task { [weak self] in
            await session.run()
            await self?.finished(id)
        }
    }
    private func finished(_ id: UUID) {
        connections.removeValue(forKey: id)
        if connections.isEmpty {
            stopping = false
            let waiters = drainWaiters; drainWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
    }
    private static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint, case .ipv4(let address) = host else { return false }
        return address == .loopback
    }
}

/// Claude Desktop checked the connection: when, and why the pool could not have taken a request
/// then (nil when it could).
public struct GatewayCheck: Sendable {
    public var at: Date
    public var failure: BridgeFailure?
}

private final class GatewayConnection: @unchecked Sendable {
    let connection: NWConnection
    let router: GatewayRouter
    let backend: any BridgeBackend
    let queue: DispatchQueue
    let onCheck: @Sendable (GatewayCheck) -> Void
    let number: Int
    init(connection: NWConnection, router: GatewayRouter, backend: any BridgeBackend, queue: DispatchQueue,
         onCheck: @escaping @Sendable (GatewayCheck) -> Void, number: Int) {
        self.connection = connection; self.router = router; self.backend = backend; self.queue = queue; self.onCheck = onCheck
        self.number = number
    }
    func run() async {
        await DevRecord.$request.withValue(String(number)) { await serveConnection() }
    }
    private func serveConnection() async {
        connection.start(queue: queue)
        let writer = GatewayWriter(connection, number: number)
        let headerDeadline = Task {
            do { try await Task.sleep(nanoseconds: 15_000_000_000); connection.cancel() } catch {}
        }
        defer { headerDeadline.cancel(); connection.cancel() }
        var received: GatewayHTTPRequest?
        do {
            var parser = GatewayHTTPParser()
            while received == nil {
                let data = try await receive(maximum: 64 * 1024)
                guard !data.isEmpty else { throw GatewayHTTPError.badRequest }
                received = try parser.append(data)
            }
            headerDeadline.cancel()
            let raw = received!
            DevRecord.record(.http, "http.request") {
                // The key that admits the client is Pool's own credential and is never recorded.
                let kept = raw.headers.filter { !Self.secretHeaders.contains($0.key) }.mapValues(JSONValue.string)
                return ["method": .string(raw.method), "path": .string(raw.path), "headers": .object(kept),
                        "withheld_headers": .array(raw.headers.keys.filter(Self.secretHeaders.contains).sorted().map(JSONValue.string)),
                        "body": DevRecord.bytes(raw.body)]
            }
            switch try router.route(raw) {
            case .response(let response): try await writer.respond(response)
            case .messages(let request, let conversationID, let requested):
                var line = GatewayRequestLine(number: number, bytes: raw.body.count)
                line.describe(request, conversationID: conversationID, requestedModel: requested)
                await serve(request, conversationID: conversationID, requestedModel: requested, writer: writer, line: &line)
                await line.record(writer)
            case .check(let model, let requested, let stream):
                var line = GatewayRequestLine(number: number, bytes: raw.body.count)
                line.kind = "check"; line.model = requested; line.messages = 1; line.stream = stream
                await check(model, requestedModel: requested, stream: stream, writer: writer, line: &line)
                await line.record(writer)
            }
        } catch {
            try? await writer.respond(GatewayJSON.failure(error))
            if let raw = received, raw.method == "POST", raw.path == "/v1/messages" {
                var line = GatewayRequestLine(number: number, bytes: raw.body.count)
                line.kind = "rejected"; line.fail(error)
                await line.record(writer)
            }
        }
    }

    static let secretHeaders: Set<String> = ["authorization", "x-api-key", "proxy-authorization", "cookie"]

    /// Answers Desktop's check without a Claude session: the pool says whether it could take a
    /// request for the model now, and an empty single-token reply stands for "it could".
    private func check(_ model: PoolModel, requestedModel: String, stream: Bool, writer: GatewayWriter, line: inout GatewayRequestLine) async {
        do {
            try await backend.checkAdmission(model: model.id)
            var encoder = MessageResponseEncoder(model: requestedModel)
            let chunks = try encoder.encode(.finished(.maxTokens))
            onCheck(GatewayCheck(at: Date(), failure: nil))
            line.outcome = "max_tokens"
            if stream {
                try await writer.beginStream()
                for chunk in chunks { try await writer.send(chunk) }
            } else {
                try await writer.respond(.init(status: 200, headers: ["x-claude-pool-check": "local"], body: try encoder.completeBody()))
            }
        } catch {
            onCheck(GatewayCheck(at: Date(), failure: error as? BridgeFailure ?? .transport))
            line.fail(error)
            try? await writer.respond(GatewayJSON.failure(error))
        }
    }

    /// Relays one reply. A stream's headers wait for the first of the
    /// answer: an error before it (a limit, a session that ended without an answer) is a real
    /// status, never a 200 stream holding nothing but an error. After the headers a failure is an
    /// `error` event with nothing after it. A reply that is not streamed answers any failure with
    /// its status, even after some of its text, which a 200 would pass off as a whole answer.
    /// A failed reply is never cancelled here: the backend settles its own failure, and only a
    /// client that leaves before the reply ends stops it.
    private func serve(_ request: BridgeRequest, conversationID: String, requestedModel: String, writer: GatewayWriter,
                       line: inout GatewayRequestLine) async {
        let lifetime = GatewayRequestLifetime()
        let stream = request.stream == true
        let monitor = Task {
            do { _ = try await receive(maximum: 1) } catch {}
            if !Task.isCancelled, await lifetime.leave() {
                await backend.cancel(conversationID: conversationID)
                connection.cancel()
            }
        }
        var heartbeat: Task<Void, Never>?
        defer { monitor.cancel(); heartbeat?.cancel() }
        var encoder = MessageResponseEncoder(model: requestedModel)
        do {
            let events = try await backend.events(for: request, conversationID: conversationID)
            for try await event in events {
                line.events += 1
                if case .usage(let value) = event { line.usage = value }
                let chunks = try encoder.encode(event)
                // The client can close as soon as it reads the last frame. A normal close after
                // a tool-use response must not cancel the Claude call parked for its result.
                if encoder.finished { await lifetime.finish() }
                if stream, !chunks.isEmpty {
                    if heartbeat == nil {
                        try await toClient { try await writer.beginStream() }
                        heartbeat = Task {
                            do {
                                while !Task.isCancelled {
                                    try await Task.sleep(nanoseconds: 15_000_000_000)
                                    try await writer.send(Data(": keep-alive\n\n".utf8))
                                }
                            } catch {
                                if !Task.isCancelled, await lifetime.leave() { await backend.cancel(conversationID: conversationID) }
                            }
                        }
                    }
                    for chunk in chunks { try await toClient { try await writer.send(chunk) } }
                }
                if encoder.finished { break }
            }
            // The session ended without an answer: a 502.
            guard encoder.finished else { throw BridgeFailure.transport }
            if !stream {
                let body = try encoder.completeBody()
                try await toClient { try await writer.respond(.init(status: 200, body: body)) }
            }
            line.finished(encoder.stopReason)
        } catch {
            // A client gone while its reply was still being answered stops it, as the monitor does.
            let left = error is GatewayClientGone ? await lifetime.leave() : false
            let gone = await lifetime.clientGone
            await lifetime.finish()
            if left { await backend.cancel(conversationID: conversationID) }
            if gone || error is GatewayClientGone {
                line.outcome = "client_gone"; line.reason = error is GatewayClientGone ? "client_gone" : GatewayJSON.reason(error)
            } else {
                line.fail(error)
                if await writer.streaming { try? await writer.send(MessageResponseEncoder.errorEvent(error)) }
                else { try? await writer.respond(GatewayJSON.failure(error)) }
            }
        }
    }
    /// A write that failed means the client is gone, which is not the reply's failure.
    private func toClient(_ write: () async throws -> Void) async throws {
        do { try await write() } catch { throw GatewayClientGone() }
    }
    private func receive(maximum: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else if complete { continuation.resume(returning: Data()) }
                else { continuation.resume(throwing: BridgeFailure.transport) }
            }
        }
    }
}

private struct GatewayClientGone: Error {}

/// One `gateway.request` diagnostics line, one for every request, since there are few: counts, sizes, timings, the
/// outcome and the reply's token counts as the official client reported them, never text, tool names, inputs or credentials. The cache counts show which
/// requests read the prompt cache and which wrote it again.
private struct GatewayRequestLine {
    let number: Int
    let bytes: Int
    let began = ContinuousClock.now
    var kind = "turn"
    var conversation = "-"
    var model = "-"
    var messages = 0, tools = 0, images = 0, events = 0
    var stream = false
    var outcome = "ok"
    var type = "-"
    var reason = "-"
    var usage: BridgeUsage?
    init(number: Int, bytes: Int) { self.number = number; self.bytes = bytes }

    mutating func describe(_ request: BridgeRequest, conversationID: String, requestedModel: String) {
        conversation = Diagnostics.tag(conversationID); model = requestedModel
        messages = request.messages.count; tools = request.tools?.count ?? 0; stream = request.stream == true
        images = request.messages.reduce(0) { $0 + Self.images(in: $1.content) }
        let last = request.messages.last?.content.arrayValue ?? []
        if request.messages.last?.role == "user", last.contains(where: { $0["type"] == .string("tool_result") }) { kind = "tool_result" }
    }
    mutating func finished(_ stop: BridgeStopReason?) {
        switch stop {
        case .toolUse: outcome = "tool_use"
        case .maxTokens: outcome = "max_tokens"
        case .refusal: outcome = "refusal"
        default: outcome = "ok"
        }
    }
    mutating func fail(_ error: Error) {
        reason = GatewayJSON.reason(error); type = GatewayJSON.classify(error).type
        outcome = reason == "cancelled" ? "cancelled" : "failed"
    }
    func record(_ writer: GatewayWriter) async {
        let status = await writer.status, headers = await writer.headersAt
        let began = self.began
        func ms(_ end: ContinuousClock.Instant) -> String { String(Int((end - began) / .milliseconds(1))) }
        Diagnostics.record("gateway.request", [
            "req": String(number), "kind": kind, "conv": conversation, "model": model,
            "msgs": String(messages), "tools": String(tools), "images": String(images), "bytes_in": String(bytes),
            "stream": stream ? "yes" : "no", "headers_ms": headers.map(ms) ?? "-", "total_ms": ms(.now),
            "events": String(events), "outcome": outcome, "status": status.map(String.init) ?? "-", "type": type, "reason": reason,
            "in": count(usage?.inputTokens), "out": count(usage?.outputTokens),
            "cache_r": count(usage?.cacheReadInputTokens), "cache_w": count(usage?.cacheCreationInputTokens),
            "cache_w1h": count(usage?.oneHourCacheWrites)])
    }
    /// A token count, or `-` when the reply told none.
    private func count(_ value: Int?) -> String {
        guard usage != nil, let value else { return "-" }
        return String(max(0, value))
    }
    static func images(in content: JSONValue) -> Int {
        (content.arrayValue ?? []).reduce(0) { count, block in
            if block["type"] == .string("image") { return count + 1 }
            if block["type"] == .string("tool_result"), let inner = block["content"] { return count + images(in: inner) }
            return count
        }
    }
}

private actor GatewayRequestLifetime {
    private(set) var isActive = true
    private(set) var clientGone = false
    func finish() { isActive = false }
    /// The client went away. True when its reply was still being answered, which is then stopped.
    func leave() -> Bool {
        guard isActive else { return false }
        isActive = false; clientGone = true
        return true
    }
}

private actor GatewayWriter {
    private let connection: NWConnection
    private var headersSent = false
    private(set) var streaming = false
    /// The status the client was answered with, and when its headers went.
    private(set) var status: Int?
    private(set) var headersAt: ContinuousClock.Instant?
    private let number: Int
    init(_ connection: NWConnection, number: Int) { self.connection = connection; self.number = number }
    func beginStream() async throws {
        guard !headersSent else { throw BridgeFailure.transport }
        headersSent = true; streaming = true; status = 200; headersAt = .now
        try await send(header(status: 200, fields: ["Content-Type": "text/event-stream", "X-Accel-Buffering": "no"]))
    }
    func respond(_ response: GatewayHTTPResponse) async throws {
        guard !headersSent else { return }
        headersSent = true; status = response.status; headersAt = .now
        var fields = response.headers
        fields["Content-Length"] = String(response.body.count)
        if fields["Content-Type"] == nil { fields["Content-Type"] = "application/json" }
        try await send(header(status: response.status, fields: fields) + response.body)
    }
    func send(_ data: Data) async throws {
        DevRecord.record(.http, "http.sent", ["req": String(number)]) { ["bytes": DevRecord.bytes(data)] }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    private func header(status: Int, fields: [String: String]) -> Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 409: reason = "Conflict"
        case 411: reason = "Length Required"
        case 413: reason = "Content Too Large"
        case 415: reason = "Unsupported Media Type"
        case 429: reason = "Too Many Requests"
        case 499: reason = "Client Closed Request"
        case 502: reason = "Bad Gateway"
        case 503: reason = "Service Unavailable"
        case 529: reason = "Overloaded"
        default: reason = status < 500 ? "Client Error" : "Server Error"
        }
        var lines = ["HTTP/1.1 \(status) \(reason)", "Connection: close", "Cache-Control: no-store", "X-Content-Type-Options: nosniff",
            "x-claude-pool-output-limit: official-client", "x-claude-pool-cache: official-client"]
        for key in fields.keys.sorted() { lines.append("\(key): \(fields[key]!)") }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }
}
