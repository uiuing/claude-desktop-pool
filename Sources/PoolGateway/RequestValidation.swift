import Foundation
import CryptoKit
import PoolCore

public enum GatewayRequestValidation {
    public static func decode(_ body: Data, models: [PoolModel] = PoolModel.defaults) throws -> BridgeRequest {
        try decodeRequest(body, models: models).request
    }
    /// The request as the pool serves it, the model id the client asked for, and the conversation
    /// shape (`conversationKey`) it belongs to.
    public static func decodeRequest(_ body: Data, models: [PoolModel] = PoolModel.defaults) throws -> (request: BridgeRequest, requested: String, shape: String) {
        let root: JSONValue
        do { root = try JSONDecoder().decode(JSONValue.self, from: body) }
        catch { throw BridgeFailure.invalidRequest("The message body is not valid JSON.") }
        guard let input = root.objectValue else { throw BridgeFailure.invalidRequest("A message object is required.") }
        let adapted = try ClientRequestShape.adapt(input)
        let object = adapted.object
        guard let requested = object["model"]?.stringValue, let model = PoolModel.resolve(requested, in: models) else {
            throw BridgeFailure.unsupported("Select a model listed by Claude Pool.")
        }
        guard let maxTokens = object["max_tokens"]?.doubleValue, maxTokens > 0, maxTokens <= 1_000_000,
              maxTokens.rounded() == maxTokens else { throw BridgeFailure.invalidRequest("A positive output budget is required.") }
        if let stream = object["stream"], stream.boolValue == nil { throw BridgeFailure.invalidRequest("The stream setting must be a boolean.") }
        if let system = object["system"] { try textContent(system) }
        // No count of messages or tools is capped: a long Claude Code session
        // is turned away only by the body's byte limit (`GatewayHTTPParser`), which already bounds
        // what one request holds.
        guard let messages = object["messages"]?.arrayValue, !messages.isEmpty else {
            throw BridgeFailure.invalidRequest("A message history is required.")
        }
        for message in messages {
            guard let m = message.objectValue, Set(m.keys) == ["role", "content"],
                  let role = m["role"]?.stringValue, ["user", "assistant"].contains(role), let content = m["content"] else {
                throw BridgeFailure.invalidRequest("Each message must have a role and content.")
            }
            if content.stringValue != nil { continue }
            guard let blocks = content.arrayValue, !blocks.isEmpty else { throw BridgeFailure.invalidRequest("Message content must contain text or tools.") }
            for block in blocks { try validateBlock(block, role: role) }
        }
        guard messages.last?["role"] == .string("user") else { throw BridgeFailure.unsupported("Assistant prefilling is not supported by the interactive Claude client.") }
        if let tools = object["tools"] {
            guard let list = tools.arrayValue else { throw BridgeFailure.invalidRequest("The tool list is malformed.") }
            var names = Set<String>()
            for tool in list {
                guard let t = tool.objectValue, let name = t["name"]?.stringValue, validName(name), names.insert(name).inserted,
                      t["input_schema"]?.objectValue != nil,
                      t["description"] == nil || t["description"]?.stringValue != nil else {
                    throw BridgeFailure.invalidRequest("Tools need unique names and object schemas.")
                }
            }
        }
        if let metadata = object["metadata"] {
            guard let fields = metadata.objectValue, Set(fields.keys).isSubset(of: ["user_id"]),
                  fields["user_id"] == nil || (fields["user_id"]?.stringValue.map { $0.utf8.count <= 8192 } ?? false) else {
                throw BridgeFailure.invalidRequest("The request metadata is not supported.")
            }
        }
        var request: BridgeRequest
        do { request = try JSONDecoder().decode(BridgeRequest.self, from: try JSONValue.object(object).encoded()) }
        catch { throw BridgeFailure.invalidRequest("The message body is malformed.") }
        request = normalized(request, model: model)
        request.toolChoice = adapted.toolChoice; request.answerSchema = adapted.answerSchema; request.webSearch = adapted.webSearch
        return (request, requested, shape(of: request, tools: adapted.standingTools))
    }

    /// Claude Desktop's check that a gateway answers, sent as it starts and from Test connection:
    /// one "." from the user for a single token, nothing else. Desktop gives it ten seconds, too
    /// short to start a Claude session, and reads only whether it was answered.
    public static func connectionCheck(_ body: Data, models: [PoolModel] = PoolModel.defaults) -> (model: PoolModel, requested: String, stream: Bool)? {
        guard body.count <= 4096, let object = (try? JSONDecoder().decode(JSONValue.self, from: body))?.objectValue,
              Set(object.keys).isSubset(of: ["model", "max_tokens", "messages", "stream", "metadata", "temperature"]),
              object["max_tokens"] == .number(1), object["stream"] == nil || object["stream"]?.boolValue != nil,
              let messages = object["messages"]?.arrayValue, messages.count == 1, let message = messages[0].objectValue,
              Set(message.keys) == ["role", "content"], message["role"] == .string("user"), isDot(message["content"]),
              let requested = object["model"]?.stringValue, let model = PoolModel.resolve(requested, in: models) else { return nil }
        return (model, requested, object["stream"]?.boolValue ?? false)
    }
    private static func isDot(_ content: JSONValue?) -> Bool {
        if content?.stringValue == "." { return true }
        guard let blocks = content?.arrayValue, blocks.count == 1, let block = blocks[0].objectValue,
              Set(block.keys).isSubset(of: ["type", "text", "cache_control"]) else { return false }
        return block["type"] == .string("text") && block["text"] == .string(".")
    }

    /// The same conversation must compare equal from turn to turn. Cache hints move each turn and
    /// Claude Code's per-request billing line changes each turn; neither is conversation content,
    /// and the billing line must not become the session's instructions.
    static func normalized(_ request: BridgeRequest, model: PoolModel) -> BridgeRequest {
        var request = request
        request.model = model.id
        request.messages = request.messages.map { BridgeMessage(role: $0.role, content: withoutHints($0.content)) }
        if let system = request.system {
            if let text = system.stringValue {
                let kept = text.components(separatedBy: "\n").filter { !$0.hasPrefix(billingPrefix) }.joined(separator: "\n")
                request.system = .string(kept)
            } else if let blocks = system.arrayValue {
                let kept = blocks.filter { !($0["text"]?.stringValue?.hasPrefix(billingPrefix) ?? false) }
                request.system = kept.isEmpty ? nil : withoutHints(.array(kept))
            }
        }
        return request
    }
    private static let billingPrefix = "x-anthropic-billing-header:"
    private static func withoutHints(_ content: JSONValue) -> JSONValue {
        guard let blocks = content.arrayValue else { return content }
        return .array(blocks.map { block in
            guard var fields = block.objectValue else { return block }
            fields.removeValue(forKey: "cache_control")
            if fields["type"] == .string("tool_result"), let inner = fields["content"] { fields["content"] = withoutHints(inner) }
            return .object(fields)
        })
    }

    /// A key for one conversation of a client session. Claude Code reuses its session id for side
    /// requests (titles, suggestions, compaction) with other instructions or tools; each shape is
    /// its own conversation, so a side request neither waits behind nor replaces the main one.
    /// Deferred tools load and unload within one conversation, so only the tools the client always
    /// offers, by name, tell its conversations apart.
    public static func conversationKey(session: String, request: BridgeRequest) -> String {
        conversationKey(session: session, shape: shape(of: request, tools: request.tools?.map(\.name) ?? []))
    }
    public static func conversationKey(session: String, shape: String) -> String { session + "#" + shape }
    /// How a turn is keyed: the model, instructions and
    /// tools, and what the turn may call, whether it searches and the schema of its answer, so a title or
    /// summary asked with tool_choice none of a long conversation is a conversation of its own.
    static func shape(of request: BridgeRequest, tools: [String]) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        var shape = Data(request.model.utf8)
        shape += (try? encoder.encode(request.system)) ?? Data()
        shape += (try? encoder.encode(tools)) ?? Data()
        if request.toolChoice != nil || request.webSearch || request.answerSchema != nil {
            shape += Data("\u{0}\(request.toolChoice ?? "")\u{0}\(request.webSearch)\u{0}".utf8)
            shape += (try? encoder.encode(request.answerSchema)) ?? Data()
        }
        return SHA256.hash(data: shape).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    public static func conversationID(headers: [String: String], request: BridgeRequest) throws -> String? {
        var values = ["x-claude-pool-session-id", "x-claude-session-id", "x-session-id"].compactMap { headers[$0] }
        if let user = request.metadata?["user_id"]?.stringValue, let data = user.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(JSONValue.self, from: data), let session = parsed["session_id"]?.stringValue {
            values.append(session)
        }
        guard values.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 && $0.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) } }),
              Set(values).count <= 1 else { throw BridgeFailure.invalidRequest("The conversation identity is ambiguous.") }
        return values.first
    }

    private static func validateBlock(_ block: JSONValue, role: String) throws {
        guard let value = block.objectValue, let type = value["type"]?.stringValue else {
            throw BridgeFailure.invalidRequest("A content block is malformed.")
        }
        switch type {
        case "text":
            guard Set(value.keys).isSubset(of: ["type", "text", "cache_control"]), value["text"]?.stringValue != nil else {
                throw BridgeFailure.invalidRequest("A text block is malformed.")
            }
        case "image":
            // an image is the person's whatever its source: one that is not bounded base64 data goes as it came
            guard role == "user" else { throw BridgeFailure.invalidRequest("An image block is malformed.") }
        case "tool_use":
            guard role == "assistant", Set(value.keys).isSubset(of: ["type", "id", "name", "input", "cache_control"]),
                  validID(value["id"]), let name = value["name"]?.stringValue, validName(name), value["input"]?.objectValue != nil else {
                throw BridgeFailure.invalidRequest("A tool call is malformed.")
            }
        case "tool_result":
            guard role == "user", Set(value.keys).isSubset(of: ["type", "tool_use_id", "content", "is_error", "cache_control"]),
                  validID(value["tool_use_id"]), value["is_error"] == nil || value["is_error"]?.boolValue != nil,
                  let content = value["content"] else { throw BridgeFailure.invalidRequest("A tool result is malformed.") }
            try toolResultContent(content)
        default:
            // A block the person sent, of any kind, goes as it came (ClientRequestShape)
            guard role == "user", value["type"]?.stringValue?.isEmpty == false else {
                throw BridgeFailure.unsupported("This content type needs a supported client adapter.")
            }
        }
        try cacheHint(value["cache_control"])
    }
    private static func textContent(_ content: JSONValue) throws {
        if content.stringValue != nil { return }
        guard let blocks = content.arrayValue else { throw BridgeFailure.invalidRequest("Text content is required.") }
        for block in blocks {
            guard let b = block.objectValue, b["type"] == .string("text"), b["text"]?.stringValue != nil,
                  Set(b.keys).isSubset(of: ["type", "text", "cache_control"]) else { throw BridgeFailure.unsupported("Only text content is supported here.") }
            try cacheHint(b["cache_control"])
        }
    }
    private static func toolResultContent(_ content: JSONValue) throws {
        if content.stringValue != nil { return }
        guard let blocks = content.arrayValue else { throw BridgeFailure.invalidRequest("A tool result needs content blocks.") }
        for block in blocks {
            if block["type"] == .string("text") { try textContent(.array([block])); continue }
            // a part of any other kind goes as the tool returned it
            guard block.objectValue?["type"]?.stringValue?.isEmpty == false else { throw BridgeFailure.invalidRequest("A tool result part is malformed.") }
            continue
        }
    }
    /// Cache hints are the client's own and are removed (`normalized`); none is refused.
    private static func cacheHint(_ hint: JSONValue?) throws {}
    /// The Messages API's own tool-name contract (`^[a-zA-Z0-9_-]{1,128}$`), which Claude Code's
    /// names already meet: the name becomes the one Pool's MCP helper offers the session.
    private static func validName(_ name: String) -> Bool {
        (1...128).contains(name.utf8.count) && name.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45 }
    }
    private static func validID(_ value: JSONValue?) -> Bool {
        guard let id = value?.stringValue else { return false }
        return (1...256).contains(id.utf8.count) && id.utf8.allSatisfy { $0 > 32 && $0 < 127 }
    }
}
