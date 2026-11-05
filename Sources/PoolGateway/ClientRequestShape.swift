import Foundation
import PoolCore

/// Claude Desktop's Code tab runs Claude Code, whose requests carry more than the plain Messages
/// shape. What only steers how Claude's service runs a turn is taken and not applied; what the
/// pool can carry is put in the shape the official client is given:
///
/// - `thinking.display`, `safeguards` (auto mode), `speed`, sampling hints and the like are advisory.
/// - A `{"role":"system"}` message inside `messages` holds a turn's effort (`output_config`) and,
///   at times, text. The effort is advisory; the text joins the user turn it came with, so the
///   session's instructions stay the same from turn to turn.
/// - Thinking from earlier answers is the service's own record; the live session keeps its own.
/// - Deferred tools (`defer_loading`, tool search): a tool is offered to the session once it is
///   loaded — ToolSearch answered with a `tool_reference` naming it, or a `tool_addition` brought
///   it — and no longer after a `tool_removal`. ToolSearch's answer reaches the session as text
///   saying which tools are loaded.
///
/// Nothing a client sends is refused for being more than the interactive client can apply: a block
/// of a kind it does not know is left out, a server tool is not offered (web search is noted, so the
/// session searches with Claude Code's own; the advisor's instructions are said to be void), stop
/// sequences and the like are not applied, `tool_choice` is kept for the session to be told, and a
/// structured answer's schema is kept for the answer tool.
enum ClientRequestShape {
    struct Adapted {
        var object: [String: JSONValue]
        /// The names of the tools the client always offers, in order: deferred tools come and go
        /// within one conversation, so they do not make it another.
        var standingTools: [String]
        /// The tool choice: nil, "none", "required" or "name:<tool>".
        var toolChoice: String?
        var answerSchema: JSONValue?
        var webSearch = false
    }

    /// Tool search the service runs itself; the pool loads tools itself, as the client asks.
    static func isToolSearch(_ type: String) -> Bool { type.hasPrefix("tool_search_tool") }
    /// What Claude Code puts in a conversation for its advisor, and what Pool says in its place when
    /// the advisor is not there.
    static let advisorNote = "# Advisor Tool\n"
    static let advisorGone = "The advisor tool is no longer available; disregard the earlier advisor instructions."

    static func adapt(_ input: [String: JSONValue]) throws -> Adapted {
        var object = input
        // A structured answer (output_config.format, or the beta's output_format): its schema.
        var answerSchema: JSONValue?
        for format in [object["output_config"]?["format"], object["output_format"]] {
            if let format, format != .null, let schema = format["schema"], schema.objectValue != nil { answerSchema = schema; break }
        }
        // The tool_choice: auto and none as they are, any as required, a tool by name.
        var toolChoice: String?
        if let choice = object["tool_choice"]?.objectValue {
            switch choice["type"]?.stringValue {
            case "none": toolChoice = "none"
            case "any": toolChoice = "required"
            case "tool": toolChoice = choice["name"]?.stringValue.map { "name:" + $0 }
            default: toolChoice = nil
            }
        }
        // Reasoning, effort, sampling, stop sequences, context editing, auto mode's safeguards, speed and
        // the rest the client sets for itself: not applied.
        for key in object.keys where !["model", "messages", "system", "tools", "max_tokens", "stream", "metadata"].contains(key) {
            object.removeValue(forKey: key)
        }
        if let system = object["system"], let blocks = system.arrayValue {
            object["system"] = .array(blocks.compactMap { block in
                guard block["type"]?.stringValue == "text", let text = block["text"]?.stringValue else { return nil }
                return .object(["type": .string("text"), "text": .string(text)])
            })
        }
        if let metadata = object["metadata"]?.objectValue {
            // Only the session id is read; other client bookkeeping is not the conversation's.
            let kept = metadata.filter { $0.key == "user_id" }
            object["metadata"] = kept.isEmpty ? nil : .object(kept)
        }

        guard let messages = input["messages"]?.arrayValue else {
            return Adapted(object: object, standingTools: [], toolChoice: toolChoice, answerSchema: answerSchema)
        }
        var declared: [[String: JSONValue]] = []
        var webSearch = false, advisorLeftOut = false
        if let tools = input["tools"] {
            guard let list = tools.arrayValue, list.count <= 2048 else { throw BridgeFailure.invalidRequest("The tool list is too large.") }
            for tool in list {
                guard let fields = tool.objectValue else { throw BridgeFailure.invalidRequest("Tools need unique names and object schemas.") }
                if let type = fields["type"]?.stringValue, type != "custom", fields["input_schema"] == nil {
                    // A server tool means nothing to the interactive client (anthropic.go:1660-1690).
                    if type.hasPrefix("web_search") { webSearch = true }
                    if type.hasPrefix("advisor_") { advisorLeftOut = true }
                    continue
                }
                if fields["name"]?.stringValue == "DeferredToolPlaceholder" { continue } // only keeps deferred loading on
                declared.append(fields.filter { ["name", "description", "input_schema", "defer_loading"].contains($0.key) })
            }
        }
        func voidAdvisor(_ text: String) -> String {
            guard advisorLeftOut, let start = text.range(of: advisorNote) else { return text }
            let end = text.range(of: "</system-reminder>", range: start.lowerBound..<text.endIndex)?.lowerBound ?? text.endIndex
            let note = text[start.lowerBound..<end]
            let trail = String(note.reversed().prefix { $0.isWhitespace }.reversed())
            let before = String(text[..<start.lowerBound]), after = String(text[end...])
            return before + Self.advisorGone + trail + after
        }
        var loaded = Set<String>(), added: [[String: JSONValue]] = []
        let declaredNames = Set(declared.compactMap { $0["name"]?.stringValue })
        func load(_ name: String?) { if let name, !name.isEmpty { loaded.insert(name) } }

        var adapted: [JSONValue] = []
        var carried: [JSONValue] = [] // text of system messages, for the next user turn
        for message in messages {
            guard var m = message.objectValue, let role = m["role"]?.stringValue else {
                throw BridgeFailure.invalidRequest("Each message must have a role and content.")
            }
            m = m.filter { $0.key == "role" || $0.key == "content" }
            if role == "system" {
                carried += textBlocks(m["content"])
                continue
            }
            guard let content = m["content"] else { throw BridgeFailure.invalidRequest("Each message must have a role and content.") }
            var blocks: [JSONValue]
            if let text = content.stringValue {
                blocks = [.object(["type": .string("text"), "text": .string(voidAdvisor(text))])]
            } else if let list = content.arrayValue {
                blocks = []
                for block in list {
                    let type = block["type"]?.stringValue
                    switch type {
                    case "thinking", "redacted_thinking":
                        continue
                    case "tool_addition":
                        let tool = block["tool"]
                        if tool?["type"]?.stringValue == "tool_definition" {
                            let definition = tool?["definition"]?.objectValue ?? tool?.objectValue ?? [:]
                            guard let name = definition["name"]?.stringValue else { continue }
                            if !declaredNames.contains(name), !added.contains(where: { $0["name"]?.stringValue == name }) {
                                added.append(definition.filter { $0.key != "type" })
                            }
                            load(name)
                        } else { load(toolName(tool) ?? toolName(block)) }
                        continue
                    case "tool_removal":
                        if let name = toolName(block["tool"]) ?? toolName(block) { loaded.remove(name) }
                        continue
                    case "tool_reference":
                        load(toolName(block))
                        continue
                    case "tool_result":
                        guard var fields = block.objectValue?.filter({ ["type", "tool_use_id", "content", "is_error"].contains($0.key) }) else { continue }
                        if let parts = fields["content"]?.arrayValue {
                            // A result's words and images, as they are read;
                            // ToolSearch's references say which tools are loaded.
                            var said: [String] = [], kept: [JSONValue] = []
                            for part in parts {
                                switch part["type"]?.stringValue {
                                case "tool_reference": if let name = toolName(part) { load(name); said.append(toolLoadedText(name)) }
                                case "text": if let text = part["text"]?.stringValue { kept.append(.object(["type": .string("text"), "text": .string(text)])) }
                                case "image": if let source = part["source"] { kept.append(.object(["type": .string("image"), "source": source])) }
                                default: continue
                                }
                            }
                            if !said.isEmpty { kept.insert(.object(["type": .string("text"), "text": .string(said.joined(separator: "\n"))]), at: 0) }
                            fields["content"] = kept.isEmpty ? .string("") : .array(kept)
                        } else if fields["content"]?.stringValue == nil { fields["content"] = .string("") }
                        blocks.append(.object(fields))
                    case "text":
                        // Citations an answer carried are the client's record of it, not new content.
                        guard let text = block["text"]?.stringValue else { continue }
                        blocks.append(.object(["type": .string("text"), "text": .string(voidAdvisor(text))]))
                    case "image":
                        guard let source = block["source"] else { continue }
                        blocks.append(.object(["type": .string("image"), "source": source]))
                    case "tool_use":
                        guard let fields = block.objectValue else { continue }
                        blocks.append(.object(fields.filter { ["type", "id", "name", "input"].contains($0.key) }))
                    default:
                        continue // a kind the interactive client has no use for, so it is left out
                    }
                }
            } else { throw BridgeFailure.invalidRequest("Each message must have a role and content.") }
            if role == "user", !carried.isEmpty { blocks = carried + blocks; carried = [] }
            guard !blocks.isEmpty else { continue } // it only said that tools came or went
            m["content"] = content.stringValue != nil && blocks.count == 1 ? content : .array(blocks)
            adapted.append(.object(m))
        }
        // Text a system message carried after the last user turn goes with that turn.
        if !carried.isEmpty, let index = adapted.lastIndex(where: { $0["role"]?.stringValue == "user" }),
           var last = adapted[index].objectValue {
            let existing = last["content"]?.stringValue.map { [JSONValue.object(["type": .string("text"), "text": .string($0)])] } ?? last["content"]?.arrayValue ?? []
            last["content"] = .array(existing + carried); adapted[index] = .object(last)
        }
        object["messages"] = .array(adapted)

        var offered: [JSONValue] = []
        var standing: [String] = []
        for fields in declared {
            let deferred = fields["defer_loading"]?.boolValue == true
            let name = fields["name"]?.stringValue
            if !deferred, let name { standing.append(name) }
            guard !deferred || name.map(loaded.contains) == true else { continue }
            offered.append(.object(fields.filter { ["name", "description", "input_schema"].contains($0.key) }))
        }
        for fields in added where fields["name"]?.stringValue.map(loaded.contains) == true {
            offered.append(.object(fields.filter { ["name", "description", "input_schema"].contains($0.key) }))
        }
        if input["tools"] != nil { object["tools"] = .array(offered) }
        return Adapted(object: object, standingTools: standing, toolChoice: toolChoice, answerSchema: answerSchema, webSearch: webSearch)
    }

    /// What a session is told of a tool ToolSearch loaded.
    static func toolLoadedText(_ name: String) -> String { "Tool \(name) is loaded and can be called now." }

    private static func toolName(_ value: JSONValue?) -> String? {
        value?["tool_name"]?.stringValue ?? value?["name"]?.stringValue
    }
    private static func textBlocks(_ content: JSONValue?) -> [JSONValue] {
        if let text = content?.stringValue { return text.isEmpty ? [] : [.object(["type": .string("text"), "text": .string(text)])] }
        return (content?.arrayValue ?? []).compactMap { block in
            guard block["type"]?.stringValue == "text", let text = block["text"]?.stringValue, !text.isEmpty else { return nil }
            return .object(["type": .string("text"), "text": .string(text)])
        }
    }
}
