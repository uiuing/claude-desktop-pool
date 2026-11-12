import Foundation
import Darwin
import PoolCore

/// Where Claude Code keeps a session of an account, and the saved session a new run goes on
/// from, as Pool writes it: Claude Code's own
/// transcript of the conversation up to its last reply, two lines, which a run started with
/// `--resume` loads, so only the turn after the reply is typed. Told whole, a long conversation
/// was one pasted message, refused, and its images pasted one by one until the paste timed out.
enum ClaudeReplay {
    /// The folder Claude Code keeps a working directory's sessions under: the path with everything
    /// but ASCII letters and digits made "-" (claude_subscription.go claudeProjectName, 420-427).
    static func projectName(_ path: String) -> String {
        String(String.UnicodeScalarView(path.unicodeScalars.map { scalar -> Unicode.Scalar in
            let value = scalar.value
            return (48...57).contains(value) || (65...90).contains(value) || (97...122).contains(value) ? scalar : "-"
        }))
    }

    /// The path with every link followed, as the client's working folder reads (/var is
    /// /private/var on a Mac); the path itself when it cannot be resolved.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The account's session folders for a working folder: by its path, and by its real path,
    /// the one the client uses last (claude_subscription.go claudeSessions, 2644-2656).
    static func projectDirectories(config: URL, work: URL) -> [URL] {
        var directories: [URL] = []
        for path in [work.path, realPath(work.path)] {
            let directory = config.appendingPathComponent("projects").appendingPathComponent(projectName(path), isDirectory: true)
            if !directories.contains(directory) { directories.append(directory) }
        }
        return directories
    }

    static func sessionKey(_ id: UUID) -> String { id.uuidString.lowercased() }

    /// The two lines a run started at the reply's turn would have written: the conversation
    /// before the reply as one user message, and the reply's words.
    static func lines(user: [JSONValue], reply: String, session: String, work: String, model: String, at date: Date) throws -> Data {
        let userID = UUID().uuidString.lowercased(), assistantID = UUID().uuidString.lowercased()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        func line(parent: String?, uuid: String, kind: String, message: JSONValue, at: Date) throws -> Data {
            var data = try ClaudePrompt.canonical(.object([
                "parentUuid": parent.map(JSONValue.string) ?? .null, "isSidechain": .bool(false), "userType": .string("external"),
                "cwd": .string(work), "sessionId": .string(session), "type": .string(kind), "message": message,
                "uuid": .string(uuid), "timestamp": .string(formatter.string(from: at))]))
            data.append(10)
            return data
        }
        var data = try line(parent: nil, uuid: userID, kind: "user",
                            message: .object(["role": .string("user"), "content": .array(user)]), at: date)
        data.append(try line(parent: userID, uuid: assistantID, kind: "assistant", message: .object([
            "id": .string("msg_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")),
            "type": .string("message"), "role": .string("assistant"), "model": .string(model),
            "content": .array([.object(["type": .string("text"), "text": .string(reply)])]),
            "stop_reason": .string("end_turn"), "stop_sequence": .null,
            "usage": .object(["input_tokens": .number(0), "output_tokens": .number(0)])]), at: date.addingTimeInterval(0.001)))
        return data
    }

    /// Adds a user message to the end of a session, its content as it came, so Claude Code resumed on it
    /// sends that content to the service unchanged, whatever its kind (Pool's own): only words and images
    /// can be typed into it. The message follows the session's last row; a session with none starts with
    /// it. Claude Code answers a session that ends on a user message with its own "No response requested."
    /// before the next typed turn.
    static func append(user content: [JSONValue], config: URL, work: URL, session: String, at date: Date) throws {
        guard let directory = projectDirectories(config: config, work: work).last else { throw BridgeFailure.transport }
        let file = directory.appendingPathComponent(session + ".jsonl")
        let existing = (try? Data(contentsOf: file)) ?? Data()
        var parent: String?
        for line in existing.split(separator: UInt8(ascii: "\n")).reversed() {
            guard let row = try? JSONDecoder().decode(JSONValue.self, from: Data(line)), let uuid = row["uuid"]?.stringValue,
                  row["parentUuid"] != nil, row["isSidechain"]?.boolValue != true else { continue }
            parent = uuid; break
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        var row = try ClaudePrompt.canonical(.object([
            "parentUuid": parent.map(JSONValue.string) ?? .null, "isSidechain": .bool(false), "userType": .string("external"),
            "cwd": .string(realPath(work.path)), "sessionId": .string(session), "type": .string("user"),
            "message": .object(["role": .string("user"), "content": .array(content)]),
            "uuid": .string(UUID().uuidString.lowercased()), "timestamp": .string(formatter.string(from: date))]))
        row.append(10)
        if existing.isEmpty { _ = try write(row, config: config, work: work, session: session); return }
        var data = existing
        if data.last != 10 { data.append(10) }
        data.append(row)
        try data.write(to: file, options: .atomic)
        chmod(file.path, 0o600)
    }

    /// Writes the saved session where the client looks: the real path's project folder.
    static func write(_ data: Data, config: URL, work: URL, session: String) throws -> URL {
        guard let directory = projectDirectories(config: config, work: work).last else { throw BridgeFailure.transport }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent(session + ".jsonl")
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw BridgeFailure.transport }
        var written = false
        defer { close(descriptor); if !written { unlink(file.path) } }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw BridgeFailure.transport }
                offset += count
            }
        }
        guard fsync(descriptor) == 0 else { throw BridgeFailure.transport }
        written = true
        return file
    }

    /// Writes `session` as a copy of the saved session `from` up to the answer that made one of
    /// `calls`: its rows before that answer's first, kept byte for byte, so Claude Code resumed on it
    /// asks the conversation before the calls as the saved session asked it, a prefix the service has
    /// cached. Rows of a side task are not the answer. False, and nothing written, when the saved
    /// session has no such answer or cannot be read.
    static func fork(config: URL, work: URL, from: String, to session: String, before calls: Set<String>) -> Bool {
        guard !calls.isEmpty, UUID(uuidString: from) != nil, UUID(uuidString: session) != nil,
              let file = projectDirectories(config: config, work: work).reversed()
                .map({ $0.appendingPathComponent(from + ".jsonl") })
                .first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return false }
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        func row(_ line: Data.SubSequence) -> JSONValue? {
            guard !line.isEmpty, let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line)),
                  value["type"]?.stringValue == "assistant", value["isSidechain"]?.boolValue != true else { return nil }
            return value
        }
        // the answer that made a call, by its message id; then the first of its rows
        var answer: String?
        for line in lines {
            guard let value = row(line), let blocks = value["message"]?["content"]?.arrayValue,
                  blocks.contains(where: { $0["type"]?.stringValue == "tool_use" && calls.contains($0["id"]?.stringValue ?? "") }) else { continue }
            answer = value["message"]?["id"]?.stringValue; break
        }
        guard let answer, !answer.isEmpty,
              let first = lines.firstIndex(where: { row($0)?["message"]?["id"]?.stringValue == answer }), first > 0 else { return false }
        var kept = Data()
        for line in lines[..<first] { kept.append(contentsOf: line); kept.append(UInt8(ascii: "\n")) }
        // the rows name their session: the copy's are its own
        kept = Data(String(decoding: kept, as: UTF8.self)
            .replacingOccurrences(of: "\"sessionId\":\"\(from)\"", with: "\"sessionId\":\"\(session)\"").utf8)
        return (try? write(kept, config: config, work: work, session: session)) != nil
    }

    /// Writes `session` as a copy of the saved session `from` cut to `bytes`, where the run that had
    /// it began its last turn: the rows before that turn, byte for byte, so Claude Code resumed on it
    /// asks the conversation before the turn as the saved session asked it, a prefix the service has
    /// cached. The cut is made only where a turn begins (`turnBoundary`). False, and nothing written, otherwise.
    static func fork(config: URL, work: URL, from: String, to session: String, upTo bytes: Int) -> Bool {
        forkRefusal(config: config, work: work, from: from, to: session, upTo: bytes) == nil
    }
    /// The same, saying what kept the copy from being made, by name only; nil once it is written.
    static func forkRefusal(config: URL, work: URL, from: String, to session: String, upTo bytes: Int) -> String? {
        guard UUID(uuidString: from) != nil, UUID(uuidString: session) != nil,
              let file = sessionFile(config: config, work: work, session: from),
              let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return "unread" }
        if let refusal = turnBoundary(data, at: bytes) { return refusal }
        // the rows name their session: the copy's are its own
        let copy = Data(String(decoding: data[data.startIndex..<(data.startIndex + bytes)], as: UTF8.self)
            .replacingOccurrences(of: "\"sessionId\":\"\(from)\"", with: "\"sessionId\":\"\(session)\"").utf8)
        return (try? write(copy, config: config, work: work, session: session)) != nil ? nil : "unwritten"
    }
    /// Cuts a saved session to `bytes` where it is, for a session whose run has ended: the same cut
    /// as `fork`, with the session's id and what Claude Code keeps beside it (large tool results, which
    /// its rows name by path) as they were. What kept it from being cut, by name only, the session
    /// then left whole; nil once it is cut.
    static func cutRefusal(config: URL, work: URL, session: String, upTo bytes: Int) -> String? {
        guard UUID(uuidString: session) != nil, let file = sessionFile(config: config, work: work, session: session) else { return "unread" }
        // read and let go before the file is cut under it
        let refusal: String? = {
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return "unread" }
            return turnBoundary(data, at: bytes)
        }()
        if let refusal { return refusal }
        var info = stat()
        guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              truncate(file.path, off_t(bytes)) == 0 else { return "unwritten" }
        return nil
    }
    private static func sessionFile(config: URL, work: URL, session: String) -> URL? {
        projectDirectories(config: config, work: work).reversed().map { $0.appendingPathComponent(session + ".jsonl") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
    /// Whether `bytes` into a session's transcript is where a turn begins, else why not, by name:
    /// whole rows; the last row of the conversation before it an answer Claude ended itself (never one
    /// cut off, the client's own error row, or one that calls a tool); the first after it the turn's
    /// own message, which brings no result. A length that falls anywhere else (a reply still being
    /// written when it was taken, a stopped turn left in the session) is refused.
    static func turnBoundary(_ data: Data, at bytes: Int) -> String? {
        guard bytes > 0 else { return "empty" }
        guard data.count >= bytes else { return "shorter" }
        let newline = UInt8(ascii: "\n")
        let end = data.startIndex + bytes
        guard data[end - 1] == newline else { return "inside_row" }
        // A row of the conversation itself, the person's or an answer's and never a side task's:
        // its role, whether it holds a block of `kind`, and whether it is an answer Claude ended itself.
        func row(_ line: Data.SubSequence, holding kind: String) -> (role: String, holds: Bool, ended: Bool)? {
            guard !line.isEmpty, let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line)),
                  value["isSidechain"]?.boolValue != true, let type = value["type"]?.stringValue,
                  type == "user" || type == "assistant" else { return nil }
            let message = value["message"]
            let holds = message?["content"]?.arrayValue?.contains { $0["type"]?.stringValue == kind } == true
            let ended = ["end_turn", "stop_sequence"].contains(message?["stop_reason"]?.stringValue ?? "") &&
                value["isApiErrorMessage"]?.boolValue != true && message?["model"]?.stringValue != "<synthetic>"
            return (type, holds, ended)
        }
        guard let last = data[data.startIndex..<end].split(separator: newline).reversed().lazy
            .compactMap({ row($0, holding: "tool_use") }).first else { return "empty" }
        guard last.role == "assistant" else { return "after_message" }
        guard !last.holds else { return "after_call" }
        guard last.ended else { return "after_unfinished" }
        guard let next = data[end...].split(separator: newline).lazy.compactMap({ row($0, holding: "tool_result") }).first else {
            return "nothing_after"
        }
        if next.role != "user" { return "before_answer" }
        if next.holds { return "before_result" }
        return nil
    }
    /// How long a session's transcript is now, in bytes; nil when it has none.
    static func length(config: URL, work: URL, session: String) -> Int? {
        for directory in projectDirectories(config: config, work: work).reversed() {
            var info = stat()
            if stat(directory.appendingPathComponent(session + ".jsonl").path, &info) == 0 { return Int(info.st_size) }
        }
        return nil
    }

    /// Removes a session's file and the folder of its own the client may keep beside it, once
    /// its run has ended (claude_subscription.go removeSession, 2660-2671).
    static func remove(config: URL, work: URL, session: String) {
        guard UUID(uuidString: session) != nil else { return }
        for directory in projectDirectories(config: config, work: work) {
            unlink(directory.appendingPathComponent(session + ".jsonl").path)
            let folder = directory.appendingPathComponent(session, isDirectory: true)
            var info = stat()
            if lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }
}
