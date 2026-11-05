import Foundation
import Darwin
import PoolCore

enum EngineSpool {
    static let maximumBytes = 8 * 1024 * 1024
    static let hookNames: Set<String> = ["SessionStart", "UserPromptSubmit", "MessageDisplay", "Stop", "StopFailure", "Notification", "PermissionRequest", "SessionEnd", "statusLine"]

    /// A call's id as the helper names its result file by: Claude Code's own tool-use id
    /// (`toolu_…`), or one the helper made.
    static func isCallID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128 &&
            id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }

    static func validate(_ directory: URL) throws -> UUID {
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else { throw BridgeFailure.compatibility }
        let manifest = try read(directory.appendingPathComponent("run.json"))
        guard let id = manifest["session_id"]?.stringValue.flatMap(UUID.init(uuidString:)) else { throw BridgeFailure.compatibility }
        return id
    }

    static func read(_ file: URL) throws -> JSONValue {
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw BridgeFailure.transport }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_size >= 0, info.st_size <= maximumBytes else { throw BridgeFailure.compatibility }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { raw -> Int in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.read(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n <= 0 { return -1 }
                offset += n
            }
            return offset
        }
        guard count == data.count else { throw BridgeFailure.transport }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    static func write(_ value: JSONValue, to file: URL) throws {
        let data = try value.encoded()
        guard data.count <= maximumBytes else { throw BridgeFailure.invalidRequest("The local session message is too large.") }
        let temporary = file.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw BridgeFailure.transport }
        var installed = false
        defer { close(descriptor); if !installed { unlink(temporary.path) } }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                guard n > 0 else { throw BridgeFailure.transport }
                offset += n
            }
        }
        guard fsync(descriptor) == 0, rename(temporary.path, file.path) == 0 else { throw BridgeFailure.transport }
        installed = true
    }

    static func enqueue(_ value: JSONValue, directory: URL) throws {
        let instant = UInt64(Date().timeIntervalSince1970 * 1_000_000)
        let file = directory.appendingPathComponent("events/\(instant)-\(UUID().uuidString).json")
        try write(value, to: file)
    }

    static func readPipeChunk(_ input: FileHandle) throws -> Data? {
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(input.fileDescriptor, &bytes, bytes.count)
            if count == 0 { return nil }
            if count > 0 { return Data(bytes.prefix(count)) }
            if errno != EINTR { throw BridgeFailure.transport }
        }
    }
    static func readInput(_ input: FileHandle, limit: Int = maximumBytes) throws -> Data {
        var result = Data()
        while let chunk = try readPipeChunk(input) {
            guard result.count + chunk.count <= limit else { throw BridgeFailure.invalidRequest("The local session message is too large.") }
            result.append(chunk)
        }
        return result
    }
}

public enum EngineHelpers {
    /// Called before the application creates a UI or reads its account library.
    public static func dispatch(arguments: [String]) -> Int32? {
        guard let command = arguments.first, command == "--bridge-hook" || command == "--mcp-helper" else { return nil }
        do {
            if command == "--bridge-hook", arguments.count == 3 {
                try hook(directory: URL(fileURLWithPath: arguments[1]), event: arguments[2], input: .standardInput)
            } else if command == "--mcp-helper", arguments.count == 2 {
                try mcp(directory: URL(fileURLWithPath: arguments[1]), input: .standardInput, output: .standardOutput)
            } else { return 64 }
            return 0
        } catch { return 1 }
    }

    public static func hook(directory: URL, event: String, input: FileHandle) throws {
        let sessionID = try EngineSpool.validate(directory)
        guard EngineSpool.hookNames.contains(event) else { throw BridgeFailure.compatibility }
        let body = try JSONDecoder().decode(JSONValue.self, from: EngineSpool.readInput(input))
        guard body["session_id"]?.stringValue.flatMap(UUID.init(uuidString:)) == sessionID else { throw BridgeFailure.compatibility }
        // Main-session callbacks alone belong to this bridge response.
        if body["agent_id"] != nil { return }
        let fields: Set<String> = ["session_id", "prompt_id", "turn_id", "message_id", "index", "final", "delta", "source", "model",
            "last_assistant_message", "background_tasks", "session_crons", "error", "notification_type", "rate_limits",
            "context_window", "prompt_cache", "tool_name", "prompt"]
        var observed = body.objectValue?.filter { fields.contains($0.key) } ?? [:]
        observed["event"] = .string(event)
        try EngineSpool.enqueue(.object(observed), directory: directory)
        // Empty success output leaves normal Claude behavior and decisions intact.
    }

    public static func mcp(directory: URL, input: FileHandle, output: FileHandle) throws {
        _ = try EngineSpool.validate(directory)
        let catalogURL = directory.appendingPathComponent("tools.json")
        let initialCatalog = try MCPToolCatalog.read(catalogURL)
        let writer = RPCWriter(output: output)
        let group = DispatchGroup()
        let alive = HelperLifetime()
        defer { alive.stop() }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            var notified = initialCatalog.revision
            var stamp = ""
            // 50 ms while the catalog has just changed, then 250 ms: a new list is acknowledged well
            // inside toolCatalogTimeout either way, and a resting run's helper wakes 4 times a second.
            var changedAt = Date()
            while alive.isRunning {
                if alive.isInitialized {
                    var info = stat()
                    let nextStamp = lstat(catalogURL.path, &info) == 0 ? "\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)" : "missing"
                    if stamp != nextStamp {
                        stamp = nextStamp; changedAt = Date()
                        do {
                            let next = try MCPToolCatalog.read(catalogURL)
                            if next.revision != notified {
                                notified = next.revision
                                writer.notification("notifications/tools/list_changed")
                            }
                        } catch { alive.stop(); return }
                    }
                }
                Thread.sleep(forTimeInterval: Date().timeIntervalSince(changedAt) < 2 ? 0.05 : 0.25)
            }
        }
        var listedNames: Set<String> = []
        let calls = HelperCalls()
        var buffer = Data()
        while let chunk = try EngineSpool.readPipeChunk(input) {
            buffer.append(chunk)
            guard buffer.count <= EngineSpool.maximumBytes else { throw BridgeFailure.transport }
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                let request = try JSONDecoder().decode(JSONValue.self, from: line)
                guard let method = request["method"]?.stringValue else { throw BridgeFailure.invalidRequest("Invalid local tool request.") }
                guard let id = request["id"] else {
                    if method == "notifications/initialized" { alive.initialize() }
                    continue
                }
                switch method {
                case "initialize":
                    writer.result(id: id, .object(["protocolVersion": .string("2024-11-05"), "capabilities": .object(["tools": .object(["listChanged": .bool(true)])]),
                        "serverInfo": .object(["name": .string("claude-pool"), "version": .string("1")])]))
                case "ping": writer.result(id: id, .object([:]))
                case "tools/list":
                    do {
                        let catalog = try MCPToolCatalog.read(catalogURL)
                        guard writer.result(id: id, .object(["tools": .array(catalog.tools)])) else { throw BridgeFailure.transport }
                        try EngineSpool.write(.object(["revision": .string(catalog.revision)]), to: directory.appendingPathComponent("tools-listed.json"))
                        listedNames = catalog.names
                    } catch { writer.error(id: id, code: -32603, message: "The local tool catalog is unavailable.") }
                case "tools/call":
                    // A call made while the list is being taken up again is answered:
                    // the tool is one the client
                    // was listed, or one the catalog has now. Only a name in neither is refused.
                    let current = (try? MCPToolCatalog.read(catalogURL))?.names ?? []
                    guard let name = request["params"]?["name"]?.stringValue, current.contains(name) || listedNames.contains(name) else {
                        writer.error(id: id, code: -32602, message: "Refresh the tool list before calling this tool."); continue
                    }
                    // A call whose input Claude Code has not written yet comes with no arguments
                    // at all: it is handed over without one, for its message to
                    // tell it whole.
                    let arguments = request["params"]?["arguments"].flatMap { $0 == .null ? nil : $0 }
                    guard arguments == nil || arguments?.objectValue != nil else {
                        writer.error(id: id, code: -32602, message: "Unknown tool or invalid arguments."); continue
                    }
                    // Claude Code names the call it is making, its own tool-use id, which its
                    // stream and transcript tell the call by; a client
                    // that does not gets an id of the helper's.
                    let named = request["params"]?["_meta"]?["claudecode/toolUseId"]?.stringValue ?? ""
                    let callID = EngineSpool.isCallID(named) && calls.begin(named) ? named : UUID().uuidString
                    if callID != named { _ = calls.begin(callID) }
                    var call: [String: JSONValue] = ["event": .string("toolCall"), "id": .string(callID), "name": .string(name)]
                    if let arguments { call["input"] = arguments }
                    do { try EngineSpool.enqueue(.object(call), directory: directory) } catch { calls.end(callID); throw error }
                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        defer { calls.end(callID); group.leave() }
                        let resultPath = directory.appendingPathComponent("results/\(callID).json")
                        let began = Date(), deadline = began.addingTimeInterval(3600)
                        while alive.isRunning && Date() < deadline {
                            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("cancelled").path) {
                                writer.error(id: id, code: -32800, message: "The client cancelled this request."); return
                            }
                            if FileManager.default.fileExists(atPath: resultPath.path) {
                                do { writer.result(id: id, try EngineSpool.read(resultPath)); try FileManager.default.removeItem(at: resultPath) }
                                catch { writer.error(id: id, code: -32603, message: "The local tool result was unavailable.") }
                                return
                            }
                            // a result comes quickly or after the client has run the tool: 25 ms for
                            // the first seconds, then 200 ms for a call parked on the client
                            Thread.sleep(forTimeInterval: Date().timeIntervalSince(began) < 5 ? 0.025 : 0.2)
                        }
                        if alive.isRunning { writer.error(id: id, code: -32800, message: "The client did not return a tool result.") }
                    }
                default: writer.error(id: id, code: -32601, message: "Method not found.")
                }
            }
        }
        alive.stop()
        group.wait()
    }

}

private final class HelperLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    private var initialized = false
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    var isInitialized: Bool { lock.lock(); defer { lock.unlock() }; return initialized }
    func initialize() { lock.lock(); initialized = true; lock.unlock() }
    func stop() { lock.lock(); running = false; lock.unlock() }
}

/// The calls the helper is waiting on, by id: a second call under one id still waiting gets an id
/// of its own, so no two wait on one result file.
private final class HelperCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: Set<String> = []
    func begin(_ id: String) -> Bool { lock.withLock { waiting.insert(id).inserted } }
    func end(_ id: String) { lock.withLock { _ = waiting.remove(id) } }
}

private struct MCPToolCatalog {
    var revision: String
    var tools: [JSONValue]
    var names: Set<String>
    static func read(_ url: URL) throws -> MCPToolCatalog {
        let value = try EngineSpool.read(url)
        guard let revision = value["revision"]?.stringValue, UUID(uuidString: revision) != nil,
              let tools = value["tools"]?.arrayValue, tools.count <= 256 else { throw BridgeFailure.compatibility }
        let names = tools.compactMap { $0["name"]?.stringValue }
        guard names.count == tools.count, Set(names).count == names.count,
              names.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 }),
              tools.allSatisfy({ $0["inputSchema"]?.objectValue != nil }) else { throw BridgeFailure.compatibility }
        return MCPToolCatalog(revision: revision, tools: tools, names: Set(names))
    }
}

private final class RPCWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let output: FileHandle
    init(output: FileHandle) { self.output = output }
    @discardableResult func result(id: JSONValue, _ result: JSONValue) -> Bool { send(.object(["jsonrpc": .string("2.0"), "id": id, "result": result])) }
    func error(id: JSONValue, code: Int, message: String) {
        send(.object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(Double(code)), "message": .string(message)])]))
    }
    func notification(_ method: String) { send(.object(["jsonrpc": .string("2.0"), "method": .string(method)])) }
    @discardableResult private func send(_ value: JSONValue) -> Bool {
        lock.lock(); defer { lock.unlock() }
        do { var data = try value.encoded(); data.append(10); try output.write(contentsOf: data); return true }
        catch { return false }
    }
}
