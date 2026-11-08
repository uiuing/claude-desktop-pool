import Foundation
import PoolCore
import PoolRuntime

public enum EngineUpdate: Sendable {
    case session(PoolSession)
    case progress(scope: AccountScope, sessionID: UUID, progress: QuotaProgress)
    case workState(scope: AccountScope, sessionID: UUID, state: QuotaWorkState, at: Date)
    case quota(scope: AccountScope, windows: [QuotaWindow])
    case accountState(scope: AccountScope, state: AccountState, cooldownUntil: Date?)
    /// The account refused for its limit without proof of which limit. Its usage should be read
    /// now; the read, never a guess, decides whether it is limited.
    case limitUnconfirmed(scope: AccountScope)
    case terminal(sessionID: UUID, data: Data)
    case route(RouteDecision)
    /// A reply's tokens as the official client reported them, once per reply, for the usage ledger.
    case usage(scope: AccountScope, model: String, name: String, usage: BridgeUsage, at: Date, generationSeconds: TimeInterval?)
    /// What a model alias runs on now, as a session on it reported.
    case model(ModelIdentity)
}

public enum WorkerObservation: Sendable {
    case terminal(Data), quota([QuotaWindow]), accountState(AccountState), working, attention, idle, ended
    case model(ModelIdentity)
}

/// Created inside the engine only after the original worker accepted its matching tool results.
public struct VerifiedToolReplay: Sendable {
    public let request: BridgeRequest
    init(request: BridgeRequest) { self.request = request }
}

/// A run's own Claude Code session, kept once its run was let go for its conversation's next turn:
/// that turn starts Claude Code with `--resume` on it, told only the messages since, so Anthropic is asked the
/// conversation as the run would have asked it, a prefix it has cached.
public struct ShelvedSession: Sendable {
    /// Claude Code's session id, as its transcript is named.
    public let session: String
    public let accountID: UUID
    /// How many of the client's messages the session holds, for a session let go while it waited on
    /// its calls: what follows, the calls first, is told to the run that resumes it. Nil: the
    /// conversation up to its last reply.
    public let held: Int?
    /// The ids of the calls the session is cut before, for a conversation that went another way at
    /// them (Claude Code's compaction asks the conversation up to a call's results with its own
    /// words after them): the run that resumes it goes on from a copy of the session up to those
    /// calls, and the session itself stays as it is. Nil: the session whole.
    public let cut: Set<String>?
    /// Removes the session's files, once its conversation is not coming back for it.
    public let discard: @Sendable () -> Void
    public init(session: String, accountID: UUID, held: Int? = nil, cut: Set<String>? = nil, discard: @escaping @Sendable () -> Void) {
        self.session = session; self.accountID = accountID; self.held = held; self.cut = cut; self.discard = discard
    }
    /// The same session, holding `count` of the client's messages.
    public func holding(_ count: Int) -> ShelvedSession {
        ShelvedSession(session: session, accountID: accountID, held: count, cut: cut, discard: discard)
    }
    /// A copy of the session cut before `calls`, holding `count` of the client's messages: the
    /// session's own files stay with it, so the copy discards nothing.
    public func forking(_ count: Int, before calls: Set<String>) -> ShelvedSession {
        ShelvedSession(session: session, accountID: accountID, held: count, cut: calls, discard: {})
    }
}

public protocol SessionWorker: Sendable {
    var id: UUID { get }
    var accountSnapshot: PoolAccount? { get }
    func events(for request: BridgeRequest) async throws -> AsyncThrowingStream<BridgeEvent, Error>
    func events(replaying replay: VerifiedToolReplay) async throws -> AsyncThrowingStream<BridgeEvent, Error>
    func observations() async -> AsyncStream<WorkerObservation>
    func sendInput(_ data: Data) async throws
    func cancel() async
    func close() async -> Bool
    func requestExit() async -> Bool
    /// Ends the idle run normally and keeps its session for the conversation's next turn;
    /// nil when it could not be kept, the run then ended as `close` ends it, or still running.
    func shelve() async -> ShelvedSession?
    /// Ends the run waiting on its calls with the client's own interrupt and keeps its session for the
    /// request that brings their results; nil when it could not be kept, the run then still to be ended.
    func shelveCalls() async -> ShelvedSession?
    /// Ends a run that cannot take its conversation's next turn (its reply stopped or failed, or the
    /// turn is not one it can be told) as `close`, else the client's interrupt, ends it, and keeps its
    /// session for the run that takes the turn; nil when it could not be kept, the run then still to be ended.
    func shelveEnding() async -> ShelvedSession?
    /// Before its first request: the run goes on from a shelved session of its account (unshelve), and
    /// is then told only what came since the conversation's last reply. False when it cannot.
    func resume(from saved: ShelvedSession) async -> Bool
}
public extension SessionWorker {
    var accountSnapshot: PoolAccount? { nil }
    func requestExit() async -> Bool { await close() }
    func events(replaying replay: VerifiedToolReplay) async throws -> AsyncThrowingStream<BridgeEvent, Error> {
        throw BridgeFailure.invalidRequest("This session cannot continue completed tool history.")
    }
    func shelve() async -> ShelvedSession? { nil }
    func shelveCalls() async -> ShelvedSession? { nil }
    func shelveEnding() async -> ShelvedSession? { nil }
    func resume(from saved: ShelvedSession) async -> Bool { false }
}

public struct SessionLaunch: Sendable {
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var directory: URL
    public var runDirectory: URL
    public var sessionID: UUID
}

public struct SessionTransport: Sendable {
    public var events: AsyncStream<PTYEvent>
    public var write: @Sendable (Data) throws -> Void
    public var interrupt: @Sendable () throws -> Void
    public var exit: @Sendable () throws -> Void
    public var waitForExit: @Sendable () async throws -> Int32
    public init(events: AsyncStream<PTYEvent>, write: @escaping @Sendable (Data) throws -> Void,
                interrupt: @escaping @Sendable () throws -> Void, exit: @escaping @Sendable () throws -> Void,
                waitForExit: @escaping @Sendable () async throws -> Int32 = { throw BridgeFailure.busy }) {
        self.events = events; self.write = write; self.interrupt = interrupt; self.exit = exit
        self.waitForExit = waitForExit
    }
    public static func launch(_ plan: SessionLaunch) throws -> SessionTransport {
        let child = try OwnedPTY.start(executable: plan.executable, arguments: plan.arguments,
                                      environment: plan.environment, directory: plan.directory)
        return SessionTransport(events: child.events, write: { try child.write($0) },
                                interrupt: { try child.interrupt() }, exit: { try child.exitWhenIdle() },
                                waitForExit: { try await child.waitForExit(timeout: 5) })
    }
}

extension SessionLaunch {
    /// The launch as the developer recording keeps it: the command, its folders and its
    /// environment, with the values of credential-named variables withheld.
    func recorded() -> [String: JSONValue] {
        let secret = ["TOKEN", "KEY", "SECRET", "PASSWORD", "AUTH", "COOKIE", "CREDENTIAL"]
        var environment: [String: JSONValue] = [:]
        for (name, value) in self.environment {
            environment[name] = secret.contains(where: name.uppercased().contains) ? .string("<withheld>") : .string(value)
        }
        return ["executable": .string(executable.path), "arguments": .array(arguments.map(JSONValue.string)),
                "environment": .object(environment), "directory": .string(directory.path),
                "run_directory": .string(runDirectory.path), "session_id": .string(sessionID.uuidString.lowercased())]
    }
}

extension SessionTransport {
    /// While the developer recording is on, the same transport with every byte it carries recorded
    /// under `run`: what the child wrote, what was typed to it, its interrupts and its exit.
    /// Off, the transport itself.
    public func recorded(run: String, role: String) -> SessionTransport {
        guard DevRecord.isOn else { return self }
        let source = events
        let (stream, continuation) = AsyncStream<PTYEvent>.makeStream()
        let relay = Task {
            for await event in source {
                switch event {
                case .output(let data): DevRecord.record(.session, "pty.out", ["run": run, "role": role]) { ["bytes": DevRecord.bytes(data)] }
                case .exited(let status): DevRecord.record(.session, "pty.exited", ["run": run, "role": role]) { ["status": .number(Double(status))] }
                }
                continuation.yield(event)
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in relay.cancel() }
        let write = self.write, interrupt = self.interrupt, exit = self.exit
        return SessionTransport(
            events: stream,
            write: { data in
                DevRecord.record(.session, "pty.in", ["run": run, "role": role]) { ["bytes": DevRecord.bytes(data)] }
                try write(data)
            },
            interrupt: {
                DevRecord.record(.session, "pty.interrupt", ["run": run, "role": role])
                try interrupt()
            },
            exit: {
                DevRecord.record(.session, "pty.exit_requested", ["run": run, "role": role])
                try exit()
            },
            waitForExit: waitForExit)
    }
}

enum RequestContent {
    static func text(_ content: JSONValue) throws -> String {
        if let string = content.stringValue { return string }
        guard let blocks = content.arrayValue else { throw BridgeFailure.invalidRequest("Messages must contain text blocks.") }
        return try blocks.map { block in
            guard block["type"]?.stringValue == "text", let text = block["text"]?.stringValue else {
                throw BridgeFailure.unsupported("This Claude connection currently accepts text and client tools.")
            }
            return text
        }.joined(separator: "\n")
    }

    /// The client's results for a run's calls, each as the MCP helper hands it to its call: words and
    /// images, which MCP carries as they are. Images sent beside the results, in the same message, go with
    /// the last result. Anything a result holds that MCP cannot
    /// carry as it is throws: such results go in the session instead (`liveResults`).
    static func toolResults(_ request: BridgeRequest) throws -> [(String, JSONValue)] {
        guard let last = request.messages.last, last.role == "user", let blocks = last.content.arrayValue,
              blocks.contains(where: { $0["type"]?.stringValue == "tool_result" }) else { return [] }
        var results: [(String, [JSONValue], Bool)] = []
        var beside: [JSONValue] = []
        for block in blocks {
            switch block["type"]?.stringValue {
            case "tool_result":
                guard let id = block["tool_use_id"]?.stringValue, !id.isEmpty else {
                    throw BridgeFailure.invalidRequest("A tool result must identify its original call.")
                }
                let content = block["content"] ?? .string("")
                var parts: [JSONValue] = []
                if let text = content.stringValue {
                    parts = [.object(["type": .string("text"), "text": .string(text)])]
                } else {
                    guard let inner = content.arrayValue else { throw BridgeFailure.invalidRequest("Invalid tool result content.") }
                    parts = try inner.map(mcpPart)
                }
                results.append((id, parts, block["is_error"]?.boolValue ?? false))
            case "image": beside.append(try mcpPart(block))
            case "text": continue // the person's words beside the results: typed as a message of theirs
            default: throw BridgeFailure.unsupported("This message holds content a running session cannot take.")
            }
        }
        if !beside.isEmpty, !results.isEmpty { results[results.count - 1].1 += beside }
        return results.map { ($0.0, .object(["content": .array($0.1), "isError": .bool($0.2)])) }
    }
    /// The calls a request's last message answers, by Claude Code's ids, whatever the results hold.
    static func resultIDs(_ request: BridgeRequest) throws -> [String] {
        guard let last = request.messages.last, last.role == "user", let blocks = last.content.arrayValue else { return [] }
        return try blocks.compactMap { block in
            guard block["type"]?.stringValue == "tool_result" else { return nil }
            guard let id = block["tool_use_id"]?.stringValue, !id.isEmpty else {
                throw BridgeFailure.invalidRequest("A tool result must identify its original call.")
            }
            return id
        }
    }
    /// Whether a request's results, and what came beside them, can go to the run waiting on them as they
    /// are: through MCP, with the person's words typed (Pool's own; else the run's session takes them).
    static func liveResults(_ request: BridgeRequest) -> Bool { (try? toolResults(request)) != nil }
    /// A part MCP carries as it is: words, or an image within what the helper hands on.
    private static func mcpPart(_ block: JSONValue) throws -> JSONValue {
        if block["type"]?.stringValue == "text", block["text"]?.stringValue != nil { return block }
        guard block["type"]?.stringValue == "image", let source = block["source"], source["type"]?.stringValue == "base64",
              let mime = source["media_type"]?.stringValue, ["image/png", "image/jpeg", "image/webp", "image/gif"].contains(mime),
              let data = source["data"]?.stringValue, data.utf8.count <= 6 * 1024 * 1024,
              let decoded = Data(base64Encoded: data), !decoded.isEmpty, decoded.count <= 4 * 1024 * 1024 else {
            throw BridgeFailure.unsupported("This tool result holds content a running session cannot take.")
        }
        return .object(["type": .string("image"), "data": .string(data), "mimeType": .string(mime)])
    }

}
