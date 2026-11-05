import Foundation

public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public subscript(_ key: String) -> JSONValue? { if case .object(let o) = self { return o[key] }; return nil }
    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let a) = self { return a }; return nil }
    public var doubleValue: Double? { if case .number(let n) = self { return n }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public func encoded() throws -> Data { try JSONEncoder().encode(self) }
}

public struct BridgeMessage: Codable, Equatable, Sendable {
    public var role: String
    public var content: JSONValue
    public init(role: String, content: JSONValue) { self.role = role; self.content = content }
}

public struct BridgeTool: Codable, Equatable, Sendable {
    public var name: String
    public var description: String?
    public var inputSchema: JSONValue
    enum CodingKeys: String, CodingKey { case name, description; case inputSchema = "input_schema" }
    public init(name: String, description: String? = nil, inputSchema: JSONValue) {
        self.name = name; self.description = description; self.inputSchema = inputSchema
    }
}

public struct BridgeRequest: Codable, Equatable, Sendable {
    public var model: String
    public var messages: [BridgeMessage]
    public var system: JSONValue?
    public var tools: [BridgeTool]?
    public var maxTokens: Int
    public var stream: Bool?
    public var metadata: JSONValue?
    /// What the client's `tool_choice` lets the turn call, as Pool keeps it: nil for its own
    /// choice, "none", "required" (any), or "name:" and the one tool. Set by the gateway, never decoded from a client.
    public var toolChoice: String? = nil
    /// The JSON schema a structured answer must fit (`output_config.format`), answered through an answer
    /// tool in interactive mode.
    public var answerSchema: JSONValue? = nil
    /// The client offered Anthropic's web search: the session searches with Claude Code's own WebSearch,
    /// as the subscription does.
    public var webSearch = false
    enum CodingKeys: String, CodingKey {
        case model, messages, system, tools, stream, metadata; case maxTokens = "max_tokens"
    }
    public init(model: String, messages: [BridgeMessage], system: JSONValue? = nil, tools: [BridgeTool]? = nil,
                maxTokens: Int = 8192, stream: Bool = true, metadata: JSONValue? = nil) {
        self.model = model; self.messages = messages; self.system = system; self.tools = tools
        self.maxTokens = maxTokens; self.stream = stream; self.metadata = metadata
    }
}

public struct BridgeToolCall: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var input: JSONValue
    public init(id: String, name: String, input: JSONValue) { self.id = id; self.name = name; self.input = input }
}

public struct BridgeUsage: Codable, Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    /// Measured cached input, reported apart from `inputTokens` as the Messages API does.
    public var cacheReadInputTokens: Int?
    public var cacheCreationInputTokens: Int?
    /// How many of the cache writes were kept for an hour (`cache_creation.ephemeral_1h_input_tokens`),
    /// billed at 2x input where a 5-minute write is 1.25x; nil when the client did not say.
    public var oneHourCacheWrites: Int?
    public init(inputTokens: Int, outputTokens: Int, cacheReadInputTokens: Int? = nil, cacheCreationInputTokens: Int? = nil, oneHourCacheWrites: Int? = nil) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.cacheReadInputTokens = cacheReadInputTokens; self.cacheCreationInputTokens = cacheCreationInputTokens
        self.oneHourCacheWrites = oneHourCacheWrites
    }
}
public enum BridgeStopReason: String, Sendable { case endTurn = "end_turn", toolUse = "tool_use", maxTokens = "max_tokens", refusal }
public enum BridgeEvent: Sendable, Equatable {
    case text(String)
    case toolUse(BridgeToolCall)
    case usage(BridgeUsage)
    case finished(BridgeStopReason)
}

public enum BridgeFailure: Error, Equatable, Sendable, LocalizedError {
    case invalidRequest(String), unsupported(String), unauthenticated, unavailable, paused, busy
    case rateLimited(Date?), permissionRequired, cancelled, compatibility, transport
    case quotaLimited([QuotaWindow])
    case accountUnavailable(AccountState), modelUnavailable
    case privacyUnavailable, privacyBusy
    /// An error the official client itself reported for the turn, passed on as it is:
    /// the Anthropic status it got, or 0 when Claude Code's own check turned the
    /// turn away before asking (its "Prompt is too long"), and its words. Never account evidence.
    case clientReported(status: Int, message: String)
    public var errorDescription: String? {
        switch self {
        case .invalidRequest(let reason), .unsupported(let reason): return reason
        case .unauthenticated: return "Reconnect Claude Desktop in Claude Pool's settings."
        case .unavailable: return "No account is available. Check accounts in Claude Pool."
        case .paused: return "Claude Pool is quitting. Open it again to continue."
        case .busy: return "This conversation is still working. Wait for its current turn."
        case .rateLimited, .quotaLimited: return "This account has reached a limit. Check its reset time in Claude Pool."
        case .permissionRequired: return "Claude needs your attention. Open the session in Claude Pool."
        case .cancelled: return "The request was cancelled."
        case .compatibility: return "The installed Claude Code did not provide the required session events."
        case .transport: return "The local Claude session stopped responding. Check it in Claude Pool."
        case .accountUnavailable(let state):
            switch state {
            case .signedOut: return "Sign in to this account again to continue."
            case .subscriptionRequired: return "This account needs an eligible Claude subscription."
            case .suspended: return "Anthropic restricted this account. The pool uses your other accounts."
            default: return "Verify this account in Claude Pool before using it again."
            }
        case .modelUnavailable: return "This model is not available to the selected account."
        case .privacyUnavailable: return "Local redaction is not ready. Open Settings in Claude Pool. Nothing was sent."
        case .privacyBusy: return "Local redaction is busy. Try again shortly."
        case .clientReported(_, let message): return message
        }
    }
}

public protocol BridgeBackend: Sendable {
    func events(for request: BridgeRequest, conversationID: String?) async throws -> AsyncThrowingStream<BridgeEvent, Error>
    func cancel(conversationID: String) async
    /// Returns when a new request for `model` would be taken now, else throws why not. Nothing is
    /// started for it: Claude Desktop's connection check is answered from this.
    func checkAdmission(model: String) async throws
}
public extension BridgeBackend {
    func checkAdmission(model: String) async throws {}
}

public struct PoolModel: Equatable, Sendable {
    public var id: String
    public var name: String
    public var cliAlias: String
    /// The id and name clients are shown: the official client's own for the model its alias runs,
    /// so Claude Desktop names it from its own catalog and offers its reasoning levels.
    public var listedID: String
    public var listedName: String
    public init(id: String, name: String, cliAlias: String, listedID: String? = nil, listedName: String? = nil) {
        self.id = id; self.name = name; self.cliAlias = cliAlias
        self.listedID = listedID ?? id; self.listedName = listedName ?? name
    }
    /// Listed by the models the aliases ran on when this build was made, until a session reports
    /// what they run on now (`listing`).
    public static let defaults = [
        PoolModel(id: "claude-sonnet", name: "Sonnet", cliAlias: "sonnet", listedID: "claude-sonnet-5-5", listedName: "Sonnet 5.5"),
        PoolModel(id: "claude-opus", name: "Opus", cliAlias: "opus", listedID: "claude-opus-5-5", listedName: "Opus 5.5"),
        PoolModel(id: "claude-haiku", name: "Haiku", cliAlias: "haiku", listedID: "claude-haiku-5-5", listedName: "Haiku 5.5"),
        PoolModel(id: "claude-fable", name: "Fable", cliAlias: "fable", listedID: "claude-fable-5-1", listedName: "Fable 5.1")]
    /// The pool's models, each listed as the official client last reported the model its alias runs.
    public static func listing(_ reported: [ModelIdentity]) -> [PoolModel] {
        defaults.map { model in
            guard let identity = reported.compactMap(\.validated).last(where: { $0.alias == model.cliAlias }) else { return model }
            var listed = model
            listed.listedID = identity.id; listed.listedName = identity.name
            return listed
        }
    }
    /// A pool model for a client model id. Clients send full ids such as
    /// `claude-sonnet-4-5-20250929` or `claude-opus-4-1[1m]`; the family decides the model.
    public static func resolve(_ id: String, in models: [PoolModel] = defaults) -> PoolModel? {
        if let exact = models.first(where: { $0.id == id || $0.cliAlias == id || $0.listedID == id }) { return exact }
        let lower = id.lowercased()
        guard lower.hasPrefix("claude-") else { return nil }
        let words = lower.dropFirst("claude-".count).split(whereSeparator: { !$0.isLetter }).map(String.init)
        return models.first { model in words.contains(model.cliAlias) }
    }
}

/// The official client's own id and name for the model an alias runs, as a session on it reported
/// them (`claude-opus-5-5`, "Opus 5.5"). A context suffix is dropped: the alias decides the context.
public struct ModelIdentity: Codable, Equatable, Sendable {
    public let alias: String
    public let id: String
    public let name: String
    /// Nil unless `id` is a Claude model of `alias`'s family; a session the client moved to another
    /// model says nothing about `alias`.
    public init?(alias: String, id: String, name: String?) {
        var id = id.trimmingCharacters(in: .whitespaces).lowercased()
        if id.hasSuffix("[1m]") { id.removeLast(4) }
        let words = id.split(separator: "-").map(String.init)
        guard (8...64).contains(id.count), words.first == "claude", words.contains(alias),
              id.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "." }) else { return nil }
        // claude-opus-5-5 is Opus 5.5 and claude-haiku-4-5-20251001 Haiku 4.5; the client's own name
        // ("Opus", "Opus 5.5 (1M context)") stands in only when the id carries no version.
        let version = words.filter { $0.count <= 2 && $0.allSatisfy(\.isNumber) }
        let family = alias.prefix(1).uppercased() + alias.dropFirst()
        let shown = (name ?? "").split(separator: "(", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let valid = (1...40).contains(shown.count) && !shown.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        self.alias = alias; self.id = id
        self.name = !version.isEmpty ? family + " " + version.joined(separator: ".") : valid ? shown : family
    }
    /// This identity as it would be recorded now; nil when a stored one no longer qualifies, so a
    /// stale entry is ignored rather than failing the library it is kept in.
    public var validated: ModelIdentity? { ModelIdentity(alias: alias, id: id, name: name) }
}
