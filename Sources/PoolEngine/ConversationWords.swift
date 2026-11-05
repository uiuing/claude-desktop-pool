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
        var calls: [String: Int] = [:], count = 0
        return messages.map { message in
            var parts: [WordPart] = []
            func add(_ kind: WordPart.Kind, _ text: String, media: Int = 0) {
                let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
                if !words.isEmpty { parts.append(WordPart(kind: kind, words: words, media: media)) }
            }
            if let text = message.content.stringValue { add(.text, text) }
            for block in message.content.arrayValue ?? [] {
                switch block["type"]?.stringValue {
                case "text": add(.text, block["text"]?.stringValue ?? "")
                case "tool_use":
                    count += 1
                    if let id = block["id"]?.stringValue { calls[id] = count }
                    add(.call, "\u{1}call \(block["name"]?.stringValue ?? "") #\(count)")
                case "tool_result":
                    let place = block["tool_use_id"]?.stringValue.flatMap { calls[$0] }.map(String.init) ?? "?"
                    let images = block["content"]?.arrayValue?.filter { $0["type"]?.stringValue == "image" }.count ?? 0
                    add(.result, "\u{1}result #\(place) " + resultText(block["content"]), media: images)
                case "image":
                    add(.image, "\u{1}image \(block["source"]?["data"]?.stringValue?.utf8.count ?? 0)")
                default: continue // thinking and the service's own records are not the conversation's words
                }
            }
            return parts
        }
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
    static func prefixKeys(_ messages: [BridgeMessage]) -> [String] {
        var hasher = SHA256(), role = "", keys: [String] = []
        for (index, words) in words(messages).enumerated() {
            if !words.isEmpty {
                if messages[index].role != role { role = messages[index].role; hasher.update(data: Data("\u{0}\(role):".utf8)) }
                hasher.update(data: Data((words + " ").utf8))
            }
            keys.append(hex(hasher))
        }
        return keys
    }
    static func key(_ messages: [BridgeMessage]) -> String { prefixKeys(messages).last ?? hex(SHA256()) }

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
        return (content.arrayValue ?? []).compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }.joined(separator: "\n")
    }
    private static func hex(_ hasher: SHA256) -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
