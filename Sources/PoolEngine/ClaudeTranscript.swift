import Foundation
import Darwin
import PoolCore

/// Claude Code's own record of the session, read as it is written, from its size when the run
/// started: a turn's lifecycle comes from it, in interactive mode. A row Pool does not
/// know is ignored, so no turn fails on the client writing something new.
struct ClaudeTranscript {
    /// A content block of an answer as the client wrote it: its words, or a call with the name the
    /// session called it by (`mcp__pool__<alias>`) under Claude Code's own tool-use id.
    enum Block: Equatable {
        case text(String)
        case toolUse(id: String, name: String, input: JSONValue?)
    }
    enum Row: Equatable {
        /// A message the person sent reached the session: a user row that is no tool's result, or
        /// one queued mid-turn.
        case accepted
        /// Content blocks of an answer (Claude Code writes one a row), under its message's id, with
        /// the message's usage so far.
        case assistant(message: String, blocks: [Block], usage: BridgeUsage?, stop: String?)
        /// The client's own error for the turn: a `<synthetic>` message.
        case apiError(status: Int?, text: String, rateLimits: JSONValue?)
        /// The turn's end.
        case turnEnded
    }

    static func row(_ line: Data) -> Row? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: line), value["isSidechain"]?.boolValue != true else { return nil }
        switch value["type"]?.stringValue {
        case "queue-operation":
            return value["operation"]?.stringValue == "enqueue" ? .accepted : nil
        case "user":
            return value["isMeta"]?.boolValue != true && isPrompt(value["message"]) ? .accepted : nil
        case "assistant":
            guard let message = value["message"] else { return nil }
            let blocks = message["content"]?.arrayValue ?? []
            let text = blocks.filter { $0["type"]?.stringValue == "text" }.compactMap { $0["text"]?.stringValue }.joined()
            if message["model"]?.stringValue == "<synthetic>" {
                guard value["isApiErrorMessage"]?.boolValue == true else { return nil }
                let status = value["apiErrorStatus"]?.doubleValue.flatMap { $0.isFinite && $0 >= 0 && $0 < 1000 ? Int($0) : nil }
                let info = value["apiErrorParams"]?["rate_limit_info"]
                return .apiError(status: status, text: text, rateLimits: info == .null ? nil : info)
            }
            let told: [Block] = blocks.compactMap { block in
                switch block["type"]?.stringValue {
                case "text": return block["text"]?.stringValue.map(Block.text)
                case "tool_use":
                    guard let id = block["id"]?.stringValue, let name = block["name"]?.stringValue else { return nil }
                    return .toolUse(id: id, name: name, input: block["input"])
                default: return nil
                }
            }
            return .assistant(message: message["id"]?.stringValue ?? "", blocks: told,
                              usage: usage(message["usage"]), stop: message["stop_reason"]?.stringValue)
        case "system":
            return value["subtype"]?.stringValue == "turn_duration" ? .turnEnded : nil
        default:
            return nil
        }
    }

    /// Whether a user row is a message typed in: text, not a tool's result (transcript.go isPrompt).
    private static func isPrompt(_ message: JSONValue?) -> Bool {
        guard let content = message?["content"] else { return false }
        if content.stringValue != nil { return true }
        guard let blocks = content.arrayValue else { return false }
        return !blocks.isEmpty && !blocks.contains { $0["type"]?.stringValue == "tool_result" }
    }

    /// A message's usage as Anthropic reports it, in a row or in a stream's events.
    static func usage(_ value: JSONValue?) -> BridgeUsage? {
        guard let value, value.objectValue != nil else { return nil }
        func count(_ key: String) -> Int? {
            guard let number = value[key]?.doubleValue, number.isFinite, number >= 0, number <= Double(Int32.max) else { return nil }
            return Int(number)
        }
        var usage = BridgeUsage(inputTokens: count("input_tokens") ?? 0, outputTokens: count("output_tokens") ?? 0,
                           cacheReadInputTokens: count("cache_read_input_tokens"),
                           cacheCreationInputTokens: count("cache_creation_input_tokens"))
        // The 1-hour share of the writes is kept apart; none said is none counted.
        if let hour = value["cache_creation"]?["ephemeral_1h_input_tokens"]?.doubleValue, hour.isFinite, hour >= 0, hour <= Double(Int32.max) {
            usage.oneHourCacheWrites = Int(hour)
        }
        return usage
    }

    // MARK: Tail

    private let candidates: [URL]
    private let projects: URL
    private let session: String
    private(set) var url: URL?
    private var offset: UInt64
    private var partial = Data()
    private var skipping = false
    private var lastScan = Date.distantPast
    private static let maximumLine = 96 * 1024 * 1024

    /// `config` is the account's directory, `work` the run's working folder.
    init(config: URL, work: URL, session: String) {
        projects = config.appendingPathComponent("projects", isDirectory: true)
        candidates = ClaudeReplay.projectDirectories(config: config, work: work).reversed().map { $0.appendingPathComponent(session + ".jsonl") }
        self.session = session
        // a resumed session's file has its earlier turns: only what is written after the start is read
        offset = 0
        for candidate in candidates {
            var info = stat()
            if lstat(candidate.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG { url = candidate; offset = UInt64(info.st_size); break }
        }
    }

    var bytesAtStart: UInt64 { offset }

    private mutating func locate() -> URL? {
        if let url { return url }
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) { url = candidate; return candidate }
        // the client may name its project folder otherwise; its session file is looked up by id
        guard Date().timeIntervalSince(lastScan) >= 0.5 else { return nil }
        lastScan = Date()
        let folders = (try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        for folder in folders.prefix(4096) {
            let candidate = folder.appendingPathComponent(session + ".jsonl")
            if FileManager.default.fileExists(atPath: candidate.path) { url = candidate; return candidate }
        }
        return nil
    }

    /// The rows written since the last read.
    mutating func read() -> [Row] {
        guard let url = locate() else { return [] }
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return [] }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              UInt64(info.st_size) > offset else { return [] }
        let length = Int(min(UInt64(info.st_size) - offset, 8 * 1024 * 1024))
        var chunk = Data(count: length)
        let count = chunk.withUnsafeMutableBytes { raw in pread(descriptor, raw.baseAddress!, length, off_t(offset)) }
        guard count > 0 else { return [] }
        DevRecord.record(.session, "transcript.read", ["run": String(session.prefix(8))]) {
            ["offset": .number(Double(offset)), "bytes": DevRecord.bytes(chunk.prefix(count))]
        }
        offset += UInt64(count)
        return lines(chunk.prefix(count))
    }

    private mutating func lines(_ chunk: Data) -> [Row] {
        var rows: [Row] = []
        var rest = chunk[...]
        while let newline = rest.firstIndex(of: 10) {
            let piece = rest[..<newline]
            rest = rest[rest.index(after: newline)...]
            if skipping { skipping = false; partial = Data(); continue }
            partial.append(contentsOf: piece)
            if !partial.isEmpty, let row = Self.row(partial) { rows.append(row) }
            partial = Data()
        }
        if !skipping { partial.append(contentsOf: rest) }
        // a row too long to keep is skipped to its end rather than held without bound
        if partial.count > Self.maximumLine { partial = Data(); skipping = true }
        return rows
    }
}

/// How the client's own error for a turn is told apart.
enum ClientErrorWords {
    private static let quota = try! NSRegularExpression(pattern:
        // The Chinese words are written as ICU \x{…} escapes: Pool's sources keep no CJK literals.
        #"(?i)quota|insufficient|balance|credit|billing|out of budget|budget (exceeded|exhausted)|exceeded|rate.?limit|usage.?limit|limit.?reached|hit your .*limit|limit.{0,24}resets|too many requests|overloaded|\x{4F59}\x{989D}|\x{989D}\x{5EA6}|\x{6B20}\x{8D39}|\x{9650}\x{6D41}|\x{9891}\x{7387}|\x{9891}\x{7E41}|\x{901F}\x{7387}|\x{5957}\x{9910}|\x{7528}\x{91CF}|\x{4E0A}\x{9650}"#)
    private static let pace = try! NSRegularExpression(pattern:
        #"(?i)rate.?limit|per (minute|hour|day)|\bTP[MD]\b|please wait|try again later|throttl|\x{901F}\x{7387}|\x{9891}\x{7E41}|\x{9891}\x{7387}|\x{9650}\x{6D41}|\x{5E76}\x{53D1}|\x{6BCF}(\x{79D2}|\x{5206}\x{949F}|\x{5C0F}\x{65F6}|\x{5929}|\x{65E5})|\x{7A0D}\x{540E}(\x{518D}\x{8BD5}|\x{91CD}\x{8BD5})"#)
    private static let tooLongWords = try! NSRegularExpression(pattern:
        #"(?i)context_length_exceeded|prompt is too long|input is too long|(exceeds?|exceeded|over|beyond)( the)?( model'?s?)?( maximum)? context|context (length|limit|window) (exceeded|is exceeded)|context (window )?(is )?full\b|maximum context length|too many (input |prompt )?tokens|\x{4E0A}\x{4E0B}\x{6587}(\x{957F}\x{5EA6})?(\x{8D85}|\x{8FC7}\x{957F})|\x{8D85}(\x{8FC7}|\x{51FA})(\x{4E86})?(\x{6A21}\x{578B})?(\x{7684})?(\x{6700}\x{5927})?\x{4E0A}\x{4E0B}\x{6587}"# +
        #"|input token count.*exceeds the maximum|maximum prompt length is \d|reduce the length of the messages|maximum allowed input length|longer than the model'?s context length|available context size|greater than the context length|prompt token count of [\d,]+ exceeds the limit|context window exceeds limit|exceeded model token limit|configured context size|prompt too long|prompt exceeds max length|context_window_exceeded|exceeded (max |maximum )?context length|range of input length should be|token limit exceeded|input tokens? (count )?(exceeds?|exceeded) (the )?(max(imum)? )?limit"# +
        #"|(\x{5185}\x{5BB9}|\x{8F93}\x{5165}|\x{6587}\x{672C}|\x{63D0}\x{793A}\x{8BCD}?|prompt|\x{95EE}\x{9898}|\x{5BF9}\x{8BDD}|\x{6D88}\x{606F})(\x{5185}\x{5BB9}|\x{6587}\x{672C})?(\x{957F}\x{5EA6})?\s*(\x{592A}\x{957F}|\x{8FC7}\x{957F}|\x{8D85}\x{957F})|\x{5B57}\x{6570}(\x{592A}\x{591A}|\x{8FC7}\x{591A})"# +
        #"|(\x{5185}\x{5BB9}|\x{8F93}\x{5165}|\x{6587}\x{672C}|\x{63D0}\x{793A}\x{8BCD}?|prompt|\x{95EE}\x{9898}|\x{5BF9}\x{8BDD}|\x{6D88}\x{606F})[^\x{FF0C}\x{3002},.;\x{FF1B}!\x{FF01}]{0,12}\x{8D85}(\x{8FC7}|\x{51FA})[^\x{FF0C}\x{3002},.;\x{FF1B}!\x{FF01}]{0,12}(\x{957F}\x{5EA6}|token|\x{4EE4}\x{724C}|\x{5B57}\x{6570})"# +
        #"|(\x{8F93}\x{5165}|\x{63D0}\x{793A}\x{8BCD}?|prompt)\s*\x{7684}?\s*(\x{957F}\x{5EA6}|token|\x{4EE4}\x{724C}|\x{5B57}\x{6570})[^\x{FF0C}\x{3002},.;\x{FF1B}!\x{FF01}]{0,8}\x{8D85}(\x{8FC7}|\x{51FA})"#)

    private static func matches(_ expression: NSRegularExpression, _ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
    static func tooLong(status: Int, _ text: String) -> Bool {
        guard status >= 400, status < 500, status != 429 else { return false }
        let lower = text.lowercased()
        if ["max_tokens", "max_output_tokens", "max_completion_tokens"].contains(where: lower.contains) { return false }
        return !matches(pace, text) && matches(tooLongWords, text)
    }
    /// Words that say out of quota or slow down, unless they say the conversation is too long.
    static func quotaSaid(_ text: String) -> Bool { matches(quota, text) && !tooLong(status: 400, text) }

    /// The allowance windows a refusal's rate-limit info tells (claude_subscription.go claudeLimits).
    static func windows(_ info: JSONValue, at now: Date) -> [QuotaWindow] {
        func valid(_ key: String) -> Bool {
            !key.isEmpty && key.utf8.count <= 96 && key.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }
        }
        func reset(_ value: JSONValue?) -> Date? {
            guard var seconds = value?.doubleValue, seconds.isFinite, seconds > 0 else { return nil }
            if seconds > 100_000_000_000 { seconds /= 1000 }
            return Date(timeIntervalSince1970: seconds)
        }
        func used(_ value: Double) -> Double { min(100, max(0, value * 100)) }
        var windows: [QuotaWindow] = []
        let unified = info["unifiedWindows"]?.objectValue ?? [:]
        for (kind, window) in unified.sorted(by: { $0.key < $1.key }) where valid(kind) {
            guard let utilization = window["utilization"]?.doubleValue, utilization.isFinite else { continue }
            windows.append(QuotaWindow(id: kind, usedPercent: used(utilization), observedAt: now, resetsAt: reset(window["resetsAt"])))
        }
        if let kind = info["rateLimitType"]?.stringValue, valid(kind), unified[kind] == nil {
            if let utilization = info["utilization"]?.doubleValue, utilization.isFinite {
                windows.append(QuotaWindow(id: kind, usedPercent: used(utilization), observedAt: now, resetsAt: reset(info["resetsAt"])))
            } else if info["status"]?.stringValue == "rejected" {
                windows.append(QuotaWindow(id: kind, usedPercent: 100, observedAt: now, resetsAt: reset(info["resetsAt"])))
            }
        }
        return windows
    }
}

