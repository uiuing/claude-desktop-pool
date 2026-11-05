import Foundation
import ImageIO
import PoolCore

/// How a conversation is told to the official client, by these mechanisms: the whole
/// conversation as one labeled text, the turn after a reply a live or resumed session already has,
/// past calls and results as bracketed lines closed by a note that such lines call nothing. Images stay
/// image blocks in place. The client's instructions are never part of it: they follow the
/// client's own system prompt (`--append-system-prompt-file`).
enum ClaudePrompt {
    /// Messages per history block, so blocks end at the same messages in every telling (4228).
    static let historyChunk = 16
    static let historyOpen = "<conversation_history>\nThe conversation so far, each turn of it answered already. " +
        "Images and files in it were sent with those earlier messages: none of them is new, and none needs answering again.\n\n"
    static let historyClose = "</conversation_history>\n\n<current_turn>\nThe turn to answer now:\n\n"
    static let pastCallsNote = "(The \"[tool call …]\" and \"[tool result …]\" lines above record calls made earlier. " +
        "Writing such a line calls nothing: call a tool only with the tool itself.)"
    /// Marks the person's words after a tool's result, or sent while a turn is going (tui.go:1131).
    static let userMark = "[user message]\n"

    enum Part: Equatable {
        case text(String)
        case image(JSONValue)
        case call(id: String, name: String, input: JSONValue)
        case result(id: String, text: String, images: [JSONValue], error: Bool)
    }
    struct Message: Equatable {
        var role: String
        var parts: [Part]
    }

    static func messages(_ messages: [BridgeMessage]) throws -> [Message] {
        try messages.map { message in
            guard ["user", "assistant"].contains(message.role) else { throw BridgeFailure.invalidRequest("Unsupported message role.") }
            return Message(role: message.role, parts: try parts(message.content))
        }
    }

    private static func parts(_ content: JSONValue) throws -> [Part] {
        if let text = content.stringValue { return [.text(text)] }
        guard let blocks = content.arrayValue else { throw BridgeFailure.invalidRequest("Invalid message content.") }
        var parts: [Part] = []
        for block in blocks {
            switch block["type"]?.stringValue {
            case "text":
                guard let text = block["text"]?.stringValue else { throw BridgeFailure.invalidRequest("Invalid text block.") }
                parts.append(.text(text))
            case "image": parts.append(.image(try image(block)))
            case "tool_use":
                guard let id = block["id"]?.stringValue, let name = block["name"]?.stringValue else {
                    throw BridgeFailure.invalidRequest("Invalid historical tool call.")
                }
                parts.append(.call(id: id, name: name, input: block["input"] ?? .object([:])))
            case "tool_result":
                guard let id = block["tool_use_id"]?.stringValue else { throw BridgeFailure.invalidRequest("Invalid historical tool result.") }
                var texts: [String] = [], images: [JSONValue] = []
                let content = block["content"] ?? .string("")
                if let text = content.stringValue { texts.append(text) }
                for inner in content.arrayValue ?? [] {
                    switch inner["type"]?.stringValue {
                    case "text": if let text = inner["text"]?.stringValue { texts.append(text) }
                    case "image": images.append(try image(inner))
                    default: continue // what the client's result holds beyond words and images is its own
                    }
                }
                parts.append(.result(id: id, text: texts.joined(separator: "\n"), images: images, error: block["is_error"]?.boolValue ?? false))
            case "thinking", "redacted_thinking":
                continue // the service's record of an earlier answer, not words of it
            default: throw BridgeFailure.unsupported("This Claude connection accepts text, attached images and client tools.")
            }
        }
        return parts
    }

    /// An image block as Claude Code keeps a pasted one: base64 with its media type.
    private static func image(_ block: JSONValue) throws -> JSONValue {
        let payload = try ImagePayload(block: block)
        guard let data = block["source"]?["data"]?.stringValue else { throw BridgeFailure.invalidRequest("Invalid image block.") }
        return .object(["type": .string("image"), "source": .object([
            "type": .string("base64"), "media_type": .string(payload.mediaType), "data": .string(data)])])
    }

    static func callsTool(_ message: Message) -> Bool {
        message.parts.contains { if case .call = $0 { true } else { false } }
    }

    /// Where the turn to answer begins: the message after the last reply that calls no tool; 0
    /// when there is none, or nothing after it (claude_subscription.go:4366-4376).
    static func historyEnd(_ messages: [Message]) -> Int {
        for index in messages.indices.reversed() where messages[index].role == "assistant" && !callsTool(messages[index]) {
            return index == messages.count - 1 ? 0 : index + 1
        }
        return 0
    }

    /// What a reply says (claude_replay.go:96-104).
    static func replyWords(_ message: Message) -> String {
        message.parts.compactMap { part -> String? in
            guard case .text(let text) = part, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return text
        }.joined(separator: "\n\n")
    }

    static func countImages(_ messages: some Collection<Message>) -> Int {
        messages.reduce(0) { total, message in
            total + message.parts.reduce(0) { count, part in
                switch part {
                case .image: return count + 1
                case .result(_, _, let images, _): return count + images.count
                default: return count
                }
            }
        }
    }

    /// The conversation told whole, each message labeled, the turn to answer marked when there is
    /// a history (renderClaudePrompt without instructions or cache marks).
    static func whole(_ messages: [Message], name: (String) -> String) -> [JSONValue] {
        var blocks: [JSONValue] = [], text = ""
        let split = historyEnd(messages)
        let chunked = split > 0 ? split : messages.count - 1
        for (index, message) in messages.enumerated() {
            if split > 0 && index == 0 { text += historyOpen }
            if split > 0 && index == split { text += currentTurnOpen(messages, split: split) }
            text += (message.role == "assistant" ? "Assistant" : "Human") + ": "
            render(message.parts, text: &text, blocks: &blocks, name: name)
            text += "\n\n"
            if index + 1 <= chunked && (index + 1) % historyChunk == 0 {
                blocks.append(textBlock(text)); text = ""
            }
        }
        if messages.contains(where: callsTool) { text += pastCallsNote + "\n\n" }
        if split > 0 { text += "</current_turn>" }
        return close(blocks, text)
    }

    /// The messages after a reply the session already has: the person's alone go as they are;
    /// with calls among them each is labeled (renderClaudeTurn).
    static func turn(_ messages: [Message], name: (String) -> String) -> [JSONValue] {
        var blocks: [JSONValue] = [], text = ""
        let labeled = messages.contains { $0.role == "assistant" }
        for (index, message) in messages.enumerated() {
            if index > 0 { text += "\n\n" }
            if labeled { text += (message.role == "assistant" ? "Assistant" : "Human") + ": " }
            render(message.parts, text: &text, blocks: &blocks, name: name)
        }
        if messages.contains(where: callsTool) { text += "\n\n" + pastCallsNote }
        return close(blocks, text)
    }

    /// The pieces a prompt is pasted in: its words one after another, each image apart
    /// (tui.go userPieces, 836-884).
    enum Piece: Equatable { case text(String), image(JSONValue) }
    static func pieces(_ blocks: [JSONValue]) -> [Piece] {
        var out: [Piece] = [], text = ""
        for block in blocks {
            if block["type"]?.stringValue == "image" {
                if !text.isEmpty { text += "\n\n"; out.append(.text(text)); text = "" }
                out.append(.image(block))
            } else if let words = block["text"]?.stringValue, !words.isEmpty {
                if !text.isEmpty || !out.isEmpty { text += "\n\n" }
                text += words
            }
        }
        if !text.isEmpty || out.isEmpty { out.append(.text(text)) }
        return out
    }

    /// An image about to be pasted must decode within the supported size.
    static func validatePasted(_ pieces: [Piece]) throws {
        for case .image(let block) in pieces {
            let image = try ImagePayload(block: block)
            guard let source = CGImageSourceCreateWithData(image.data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetCount(source) > 0,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 25_000_000 / height,
                  CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) != nil,
                  CGImageSourceGetStatus(source) == .statusComplete else {
                throw BridgeFailure.invalidRequest("The attached image could not be decoded within the supported size.")
            }
        }
    }

    private static func currentTurnOpen(_ messages: [Message], split: Int) -> String {
        let earlier = countImages(messages[..<split]), now = countImages(messages[split...])
        if earlier == 0 { return historyClose }
        if now == 0 {
            return "</conversation_history>\n\n<current_turn>\nThe turn to answer now. Any \"[Image: …]\" notes after it are about " +
                "the images in the conversation history above, not images sent with this turn.\n\n"
        }
        return "</conversation_history>\n\n<current_turn>\nThe turn to answer now. Any \"[Image: …]\" notes after it are about " +
            "the images above in their order: the conversation history's first, then this turn's.\n\n"
    }

    private static func render(_ parts: [Part], text: inout String, blocks: inout [JSONValue], name: (String) -> String) {
        var open = "" // the tool result told last, not closed yet
        for part in parts {
            if !open.isEmpty, case .text(let words) = part {
                // the person's words after a result are theirs, not the tool's; an agent's notice is neither
                text += "\n[end of tool result id=\(open)]\n\n" + (agentNotice(words) ? "" : userMark)
                open = ""
            }
            switch part {
            case .text(let words): text += words
            case .image(let block): image(block, text: &text, blocks: &blocks)
            case .call(let id, let tool, let input): text += "\n[tool call \(name(tool)) id=\(id) args=\(arguments(input))]"
            case .result(let id, let words, let images, let error):
                text += "\n[tool result id=\(id)\(error ? " error" : "")]\n\(words)"
                open = id
                for block in images { image(block, text: &text, blocks: &blocks) }
            }
        }
    }

    private static func image(_ block: JSONValue, text: inout String, blocks: inout [JSONValue]) {
        if !text.isEmpty { blocks.append(textBlock(text)); text = "" }
        blocks.append(block)
    }

    private static func close(_ blocks: [JSONValue], _ text: String) -> [JSONValue] {
        var blocks = blocks
        if !text.isEmpty { blocks.append(textBlock(text)) }
        if blocks.isEmpty { blocks.append(textBlock("[continue]")) }
        return blocks
    }

    private static func textBlock(_ text: String) -> JSONValue { .object(["type": .string("text"), "text": .string(text)]) }

    /// Text after a tool's results that is the agent's own, not the person's: empty inside its
    /// reminder tags (claude_subscription.go agentNotice, 4991).
    private static func agentNotice(_ text: String) -> Bool {
        let stripped = text.replacingOccurrences(of: #"<system-reminder>[\s\S]*?</system-reminder>"#, with: "", options: .regularExpression)
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func arguments(_ input: JSONValue) -> String {
        if case .object(let fields) = input, fields.isEmpty { return "{}" }
        guard let data = try? canonical(input) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func canonical(_ value: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    /// The client's instructions without Claude Code's per-request billing line, whose last part
    /// hashes the request's first message (claude_subscription.go:4465-4471).
    static func withoutBillingHeader(_ system: String) -> String {
        system.replacingOccurrences(of: #"^x-anthropic-billing-header:(\s*[A-Za-z_]+=[^;\s]*;)*\s*"#, with: "", options: .regularExpression)
    }

    /// What follows the client's instructions about where its tools run (claude_subscription.go
    /// envNote, 4139-4186): the session works in the account's own folder, while the client names
    /// the person's. Named in a turn (Claude Code 2.1.296 and later give their environment as a
    /// system message, which joins the user turn here) the folder identifies it.
    static func environmentNote(system: String, messages: [BridgeMessage]) -> String {
        let pattern = #"(?m)^\s*(?:-\s*)?(?:Primary working directory|Working directory|Current working directory|CWD): *([^\r\n]+)$|<cwd>([^<\r\n]+)</cwd>"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return "" }
        func named(_ text: String) -> String? {
            var found: String?
            let string = text as NSString
            for match in expression.matches(in: text, range: NSRange(location: 0, length: string.length)) {
                for group in 1..<match.numberOfRanges where match.range(at: group).location != NSNotFound {
                    var dir = string.substring(with: match.range(at: group)).trimmingCharacters(in: .whitespaces)
                    dir = dir.trimmingCharacters(in: CharacterSet(charactersIn: "`'\""))
                    dir = dir.replacingOccurrences(of: #"\s*\(was [^)]*\)$"#, with: "", options: .regularExpression)
                    if !dir.isEmpty { found = dir }
                }
            }
            return found
        }
        if let dir = named(system), dir.hasPrefix("/") {
            return "\n\nThe environment these instructions describe (working directory, platform, OS, shell, git status) is the one every tool runs in. " +
                "Where an environment given elsewhere in this conversation differs, go by these instructions; nothing has changed and there is no need to check."
        }
        var dir: String?
        for message in messages where message.role == "user" {
            let texts = message.content.stringValue.map { [$0] } ??
                (message.content.arrayValue ?? []).compactMap { $0["type"]?.stringValue == "text" ? $0["text"]?.stringValue : nil }
            for text in texts { if let found = named(text) { dir = found } }
        }
        guard let dir, dir.hasPrefix("/") else { return "" }
        return "\n\nOf the environments given in this conversation (working directory, platform, OS, shell, git status), the one whose working directory is " + dir +
            " is the one every tool runs in. Any other one describes a computer no tool runs on: don't take a platform, shell or path for a tool call from it. " +
            "Nothing has changed and there is no need to check."
    }
}
