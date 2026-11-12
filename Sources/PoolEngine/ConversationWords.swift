import Foundation
import CryptoKit
import PoolCore

/// A conversation as it is compared: its words, tool calls and results. Whitespace, thinking and how a reply is
/// split into messages are left out, as clients keep those differently. A call is told by its place
/// among the conversation's calls, and a result by the call it answers, not by their ids.
enum ConversationWords {
    /// A part of a message as the conversation is compared:
    /// its kind, its words, and for a tool result how many images it carried beside them.
    struct WordPart: Equatable {
        enum Kind: Equatable { case text, call, result, image }
        var kind: Kind
        var words: String
        var media = 0
    }

    /// Each message's parts with words. A call is told
    /// by its place among the conversation's calls, and a result by the call it answers.
    static func parts(_ messages: [BridgeMessage]) -> [[WordPart]] {
        var calls = Calls()
        return messages.map { message in
            var parts: [WordPart] = []
            eachPart(message, &calls) { kind, text, media in
                let words = squeezed(text)
                if !words.isEmpty { parts.append(WordPart(kind: kind, words: words, media: media)) }
            }
            return parts
        }
    }

    /// The calls made so far: each call's place among the conversation's calls, by its id.
    struct Calls: Sendable {
        var places: [String: Int] = [:]
        var count = 0
    }

    /// Each part of a message as text before its words are taken (kind, text, images beside it), in order.
    private static func eachPart(_ message: BridgeMessage, _ calls: inout Calls, _ add: (WordPart.Kind, String, Int) -> Void) {
        if let text = message.content.stringValue { add(.text, text, 0) }
        for block in message.content.arrayValue ?? [] {
            switch block["type"]?.stringValue {
            case "text": add(.text, block["text"]?.stringValue ?? "", 0)
            case "tool_use":
                calls.count += 1
                if let id = block["id"]?.stringValue { calls.places[id] = calls.count }
                add(.call, "\u{1}call \(block["name"]?.stringValue ?? "") #\(calls.count)", 0)
            case "tool_result":
                let place = block["tool_use_id"]?.stringValue.flatMap { calls.places[$0] }.map(String.init) ?? "?"
                let images = block["content"]?.arrayValue?.filter { $0["type"]?.stringValue == "image" }.count ?? 0
                add(.result, "\u{1}result #\(place) " + resultText(block["content"]), images)
            case "image":
                add(.image, "\u{1}image \(block["source"]?["data"]?.stringValue?.utf8.count ?? 0)", 0)
            case "thinking", "redacted_thinking", nil: continue // the service's own record, not the conversation's words
            default:
                // a block of any other kind the person sent: by its kind and a digest of it as sent
                add(.text, "\u{1}block \(block["type"]?.stringValue ?? "") " + digest(block), 0)
            }
        }
    }

    /// A text's words, one space between them: the text split at each character that is a space or a line break.
    static func squeezed(_ text: String) -> String {
        var bytes: [UInt8] = []
        appendWords(text, to: &bytes)
        guard !bytes.isEmpty else { return "" }
        bytes.removeLast()
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Appends each of a text's words to `out`, a space after each: the text split where a character is
    /// a space or a line break (`Character.isWhitespace || isNewline`). The bytes are read once; when a space
    /// shares its character with the scalar before or after it (a mark on it, a sign before it), which the
    /// bytes alone do not tell, the text is split by characters instead, so the words are the same either way.
    static func appendWords(_ text: String, to out: inout [UInt8]) {
        let start = out.count
        var text = text
        let read = text.withUTF8 { appendWords(bytes: $0, to: &out) }
        guard !read else { return }
        out.removeSubrange(start...)
        for word in text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
            out.append(contentsOf: word.utf8)
            out.append(0x20)
        }
    }

    /// `appendWords` over valid UTF-8, false when a space is not a character of its own.
    private static func appendWords(bytes: UnsafeBufferPointer<UInt8>, to out: inout [UInt8]) -> Bool {
        let count = bytes.count
        var index = 0, wordStart = -1, previous: UInt32 = 0
        while index < count {
            let (scalar, length) = decode(bytes, at: index)
            if isSpace(scalar) {
                // An ASCII scalar never joins a space's character; any other one next to it is asked.
                if previous >= 0x80 && !separate(previous, scalar) { return false }
                if index + length < count && bytes[index + length] >= 0x80
                    && !separate(scalar, decode(bytes, at: index + length).scalar) { return false }
                if wordStart >= 0 {
                    out.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[wordStart..<index]))
                    out.append(0x20)
                    wordStart = -1
                }
            } else if wordStart < 0 {
                wordStart = index
            }
            previous = scalar
            index += length
        }
        if wordStart >= 0 {
            out.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[wordStart..<count]))
            out.append(0x20)
        }
        return true
    }

    @inline(__always)
    private static func decode(_ bytes: UnsafeBufferPointer<UInt8>, at index: Int) -> (scalar: UInt32, length: Int) {
        let lead = UInt32(bytes[index])
        if lead < 0x80 { return (lead, 1) }
        if lead < 0xE0 { return ((lead & 0x1F) << 6 | UInt32(bytes[index + 1] & 0x3F), 2) }
        if lead < 0xF0 {
            return ((lead & 0x0F) << 12 | UInt32(bytes[index + 1] & 0x3F) << 6 | UInt32(bytes[index + 2] & 0x3F), 3)
        }
        return ((lead & 0x07) << 18 | UInt32(bytes[index + 1] & 0x3F) << 12 | UInt32(bytes[index + 2] & 0x3F) << 6
                | UInt32(bytes[index + 3] & 0x3F), 4)
    }

    /// Whether a scalar, as a character of its own, is a space or a line break: Unicode's White_Space.
    static func isSpace(_ scalar: UInt32) -> Bool {
        if scalar < 0x80 { return scalar == 0x20 || (scalar >= 0x09 && scalar <= 0x0D) }
        switch scalar {
        case 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: return true
        default: return false
        }
    }

    /// Whether two scalars in a row are two characters. Only these two decide it when one is a space.
    private static func separate(_ first: UInt32, _ second: UInt32) -> Bool {
        guard let a = Unicode.Scalar(first), let b = Unicode.Scalar(second) else { return true }
        var pair = String(Character(a))
        pair.unicodeScalars.append(b)
        return pair.count == 2
    }

    /// Each message's words, as `key` reads them.
    static func words(_ messages: [BridgeMessage]) -> [String] {
        parts(messages).map { $0.map(\.words).joined(separator: " ") }
    }

    /// Whether images were taken out: `now` is `was`, the conversation a run was told,
    /// with images taken out and that alone, as far as `was` goes; `now` may go on after it. Each image of
    /// `was` is in `now`, gone, or has text in its place; a tool result may have text added to its end when
    /// it carried images. Nothing else changed, and something was taken out.
    static func lostMedia(was: [BridgeMessage], now: [BridgeMessage]) -> Bool {
        let wasRuns = runs(was), nowRuns = runs(now)
        guard nowRuns.count >= wasRuns.count else { return false }
        var lost = 0
        for (index, run) in wasRuns.enumerated() {
            guard nowRuns[index].role == run.role, let taken = lostFromRun(run.parts, nowRuns[index].parts) else { return false }
            lost += taken
        }
        return lost > 0
    }

    /// `now` is `was`, the conversation a run was told, with only texts of a user's message taken out that
    /// the agent put in or that came after tool results, as far as `was` goes; `now` may go on after it.
    /// Claude Code takes its one-off reminders back out of the history it sends next, so a user message
    /// can arrive with fewer texts than the run heard; the run heard them, so it holds the conversation whole. Pool's own, in the
    /// shape of the image check above, the texts told as the agent's notices.
    static func lostNotices(was: [BridgeMessage], now: [BridgeMessage]) -> Bool {
        let wasRuns = runs(was), nowRuns = runs(now)
        guard nowRuns.count >= wasRuns.count else { return false }
        var lost = 0
        for (index, run) in wasRuns.enumerated() {
            guard nowRuns[index].role == run.role else { return false }
            if run.role != "user" {
                guard run.parts == nowRuns[index].parts else { return false }
                continue
            }
            guard let taken = noticesFromRun(run.parts, nowRuns[index].parts) else { return false }
            lost += taken
        }
        return lost > 0
    }
    /// How many texts were taken out of a user's run `was` to make `now`, nil when anything else changed.
    private static func noticesFromRun(_ was: [WordPart], _ now: [WordPart]) -> Int? {
        var lost = 0, j = 0, afterResult = false
        for part in was {
            if j < now.count && part.kind == now[j].kind && part.words == now[j].words {
                j += 1
            } else if part.kind == .text && (afterResult || agentText(part.words)) {
                lost += 1
            } else {
                return nil
            }
            if part.kind == .result { afterResult = true } else if part.kind != .text { afterResult = false }
        }
        return j == now.count ? lost : nil
    }
    /// A text the agent put in for its model: only
    /// reminders, or one beginning as Claude Code's notices do.
    static func agentText(_ words: String) -> Bool {
        let bare = words.replacingOccurrences(of: #"<system-reminder(?:\s[^>]*)?>.*?</system-reminder>"#, with: "",
                                              options: [.regularExpression]).trimmingCharacters(in: .whitespacesAndNewlines)
        if bare.isEmpty { return true }
        let leads = ["<system-reminder", "<task-notification>", "<subagent-notification>", "<plugin_reference>",
                     "[SYSTEM NOTIFICATION - NOT USER INPUT]",
                     "Available agent types for the Agent tool:", "New agent types are now available for the Agent tool:",
                     "The TodoWrite tool hasn't been used recently.", "The task tools haven't been used recently."]
        return leads.contains { bare.hasPrefix($0) }
    }

    /// A role's messages in a row, as the comparison runs them together.
    private static func runs(_ messages: [BridgeMessage]) -> [(role: String, parts: [WordPart])] {
        var out: [(role: String, parts: [WordPart])] = []
        for (index, parts) in parts(messages).enumerated() where !parts.isEmpty {
            if out.last?.role != messages[index].role { out.append((messages[index].role, [])) }
            out[out.count - 1].parts += parts
        }
        return out
    }
    /// How many images were taken out of `was` to make `now`, nil when anything else changed (lostFromRun).
    private static func lostFromRun(_ was: [WordPart], _ now: [WordPart]) -> Int? {
        var lost = 0, j = 0, grew = false
        func same(_ a: WordPart, _ b: WordPart) -> Bool { a.kind == b.kind && a.words == b.words }
        func grown(_ part: WordPart, _ words: String) -> Bool { words.utf8.count > part.words.utf8.count && words.utf8.starts(with: part.words.utf8) }
        func mediaAfter(_ i: Int) -> Bool {
            var k = i + 1
            while k < was.count && was[k].kind == .result { k += 1 }
            if k < was.count && was[k].kind == .text { k += 1 }
            return k < was.count && was[k].kind == .image
        }
        for (i, part) in was.enumerated() {
            if j < now.count && same(part, now[j]) {
                if part.kind != .result { grew = false }
                j += 1
            } else if part.kind == .image {
                // gone, or text in its place: up to the next part of `was` that is no image
                lost += 1
                var next = i + 1
                while next < was.count && was[next].kind == .image { next += 1 }
                while j < now.count && now[j].kind == .text && (next == was.count || !same(was[next], now[j])) { j += 1 }
            } else if part.kind == .result, j < now.count, now[j].kind == .result, part.media > now[j].media, grown(part, now[j].words) {
                lost += part.media - now[j].media; grew = true; j += 1
            } else if part.kind == .result, j < now.count, now[j].kind == .result, part.media == now[j].media, mediaAfter(i), grown(part, now[j].words) {
                grew = true; j += 1
            } else if part.kind == .text, grew, i > 0, was[i - 1].kind == .result, i + 1 < was.count, was[i + 1].kind == .image {
                continue // the line before the results' images, gone with them
            } else {
                return nil
            }
        }
        return j == now.count ? lost : nil
    }

    /// The digest of the conversation after each of its messages (hashMessages' `after`).
    static func prefixKeys(_ messages: [BridgeMessage]) -> [String] { Prefix(messages).keys }
    static func key(_ messages: [BridgeMessage]) -> String { Prefix(messages).key }

    /// A conversation's keys as it grows: after each message, the digest of the conversation so far.
    /// Each message is hashed as its role (when it changes) and its words, each followed by a space; a message
    /// without words leaves the digest as it was. `Prefix(m).keys` is `prefixKeys(m)`, and appending a message
    /// gives the key `prefixKeys` has for it after the messages before.
    struct Prefix: Sendable {
        private(set) var keys: [String] = []
        private var hasher = SHA256()
        private var role = ""
        private var calls = Calls()
        private var bytes: [UInt8] = []

        init(_ messages: [BridgeMessage]) {
            keys.reserveCapacity(messages.count)
            for message in messages { append(message) }
        }

        /// The conversation's key, `key(_:)`: the last message's, or the empty conversation's.
        var key: String { keys.last ?? ConversationWords.hex(SHA256().finalize()) }

        /// Takes the next message and gives the conversation's key after it.
        @discardableResult
        mutating func append(_ message: BridgeMessage) -> String {
            // Moved out while parts are read, so neither is copied.
            var words: [UInt8] = [], made = Calls()
            swap(&words, &bytes); swap(&made, &calls)
            words.removeAll(keepingCapacity: true)
            ConversationWords.eachPart(message, &made) { _, text, _ in ConversationWords.appendWords(text, to: &words) }
            if !words.isEmpty {
                if message.role != role { role = message.role; hasher.update(data: Data("\u{0}\(role):".utf8)) }
                words.withUnsafeBytes { hasher.update(bufferPointer: $0) }
            }
            swap(&words, &bytes); swap(&made, &calls)
            let key = ConversationWords.hex(hasher.finalize())
            keys.append(key)
            return key
        }
    }

    /// Whether `messages` go on from `history`: that conversation whole, then whatever came since.
    static func follows(_ messages: [BridgeMessage], history: [BridgeMessage]) -> Bool {
        let told = key(history)
        return history.isEmpty || prefixKeys(messages).contains(told)
    }

    static func callsTool(_ message: BridgeMessage) -> Bool {
        message.content.arrayValue?.contains { $0["type"]?.stringValue == "tool_use" } == true
    }
    static func carriesTools(_ message: BridgeMessage) -> Bool {
        message.content.arrayValue?.contains { ["tool_use", "tool_result"].contains($0["type"]?.stringValue ?? "") } == true
    }

    /// The conversation a request goes on from, after its last plain reply, and the
    /// messages since; nil when it is not a new turn after a reply (a first turn, or tool results for
    /// a call made before that reply).
    static func nextTurn(_ messages: [BridgeMessage]) -> (before: [BridgeMessage], since: [BridgeMessage])? {
        guard let last = messages.last, last.role != "assistant" else { return nil }
        guard let reply = messages.lastIndex(where: { $0.role == "assistant" && !callsTool($0) }) else { return nil }
        let since = Array(messages[(reply + 1)...])
        var calls: Set<String> = []
        for message in since {
            for block in message.content.arrayValue ?? [] {
                if block["type"]?.stringValue == "tool_use", let id = block["id"]?.stringValue { calls.insert(id) }
                if block["type"]?.stringValue == "tool_result", !calls.contains(block["tool_use_id"]?.stringValue ?? "") { return nil }
            }
        }
        return (Array(messages[...reply]), since)
    }

    /// `now` is the conversation `was` kept, as a client sends it back
    /// with its last turn rewritten: the same messages, calls and results, a user's message no more
    /// than cut (a part of it taken out, but not all), and the reply's start (its end taken out).
    /// Both end with a reply. Earlier turns must be as they were.
    static func rewrote(_ now: [BridgeMessage], was: [BridgeMessage]) -> Bool {
        guard let nowStart = lastTurnStart(now), let wasStart = lastTurnStart(was), nowStart == wasStart,
              now.count == was.count, key(Array(now[..<nowStart])) == key(Array(was[..<wasStart])) else { return false }
        let nowWords = words(now), wasWords = words(was)
        for index in nowStart..<now.count {
            let current = nowWords[index], previous = wasWords[index]
            let tools = carriesTools(now[index])
            guard now[index].role == was[index].role, tools == carriesTools(was[index]) else { return false }
            if current == previous { continue }
            if tools || current.isEmpty { return false }
            if index == now.count - 1 {
                guard previous.hasPrefix(current) else { return false }
            } else {
                guard now[index].role == "user", cutFrom(previous, current) else { return false }
            }
        }
        return true
    }

    /// Where a conversation's last turn starts: after the plain reply before its final message.
    private static func lastTurnStart(_ messages: [BridgeMessage]) -> Int? {
        guard !messages.isEmpty else { return nil }
        var index = messages.count - 2
        while index >= 0 {
            if messages[index].role == "assistant" && !callsTool(messages[index]) { return index + 1 }
            index -= 1
        }
        return 0
    }
    /// `s` is `was` with one part of it taken out: `was`'s start and end, which meet.
    private static func cutFrom(_ was: String, _ s: String) -> Bool {
        let a = Array(was.utf8), b = Array(s.utf8)
        guard b.count < a.count else { return false }
        var n = 0
        while n < b.count && b[n] == a[n] { n += 1 }
        return a.suffix(b.count - n).elementsEqual(b[n...])
    }
    private static func resultText(_ content: JSONValue?) -> String {
        guard let content else { return "" }
        if let text = content.stringValue { return text }
        return (content.arrayValue ?? []).compactMap { part -> String? in
            switch part["type"]?.stringValue {
            case "text": return part["text"]?.stringValue
            case "image": return nil // counted as the result's media
            default: return "\u{1}part \(part["type"]?.stringValue ?? "") " + digest(part) // whatever else the tool returned
            }
        }.joined(separator: "\n")
    }
    /// A block as it was sent, cache marks aside, in a few hex digits.
    private static func digest(_ block: JSONValue) -> String {
        var value = block
        if case .object(var fields) = block { fields.removeValue(forKey: "cache_control"); value = .object(fields) }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return String(hex(SHA256.hash(data: (try? encoder.encode(value)) ?? Data())).prefix(16))
    }
    private static let hexDigits = Array("0123456789abcdef".utf8)
    /// A digest in lowercase hex, two digits a byte.
    private static func hex(_ digest: SHA256.Digest) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(SHA256.Digest.byteCount * 2)
        for byte in digest {
            out.append(hexDigits[Int(byte >> 4)])
            out.append(hexDigits[Int(byte & 0x0F)])
        }
        return String(decoding: out, as: UTF8.self)
    }
}
