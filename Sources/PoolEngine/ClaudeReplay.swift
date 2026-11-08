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
