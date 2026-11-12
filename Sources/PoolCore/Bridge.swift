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

    /// The value `JSONDecoder().decode(JSONValue.self, from:)` gives, read about three times faster
    /// through `JSONSerialization`. Where the two readers could differ (a sign or exponent on zero,
    /// a number beyond a double, keys Swift counts as equal, anything `JSONSerialization` refuses)
    /// the decoder reads it instead, so the result and its errors are the decoder's.
    public static func parse(_ data: Data) throws -> JSONValue {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return try JSONDecoder().decode(JSONValue.self, from: data)
        }
        var reader = FoundationReader()
        if let value = reader.value(object), !(reader.integerZero && Self.negativeZero(in: data)) { return value }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
    private struct FoundationReader {
        /// An integer zero was read; `JSONSerialization` reads `-0` as one and drops its sign.
        var integerZero = false
        mutating func value(_ object: Any) -> JSONValue? {
            switch object {
            case let text as String: return .string(text)
            case let number as NSNumber:
                if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
                // A decimal number holds more digits than a double, and rounds them differently.
                if number is NSDecimalNumber { return nil }
                let value = number.doubleValue, type = number.objCType.pointee
                if type == UInt8(ascii: "d") || type == UInt8(ascii: "f") {
                    // A zero written with an exponent, or a value beyond a double's range, is refused by the decoder.
                    guard value != 0, value.isFinite else { return nil }
                } else if value == 0 { integerZero = true }
                return .number(value)
            case let list as [Any]:
                var values = [JSONValue](); values.reserveCapacity(list.count)
                for element in list { guard let value = value(element) else { return nil }; values.append(value) }
                return .array(values)
            case let fields as NSDictionary:
                // Read as Foundation keeps it: bridged to a Swift dictionary first, keys Foundation
                // tells apart but Swift counts as equal would already be one, and which one the
                // decoder keeps depends on their order.
                var values = [String: JSONValue](minimumCapacity: fields.count)
                for (key, element) in fields {
                    guard let key = key as? String, let value = value(element) else { return nil }
                    values[key] = value
                }
                return values.count == fields.count ? .object(values) : nil
            case is NSNull: return .null
            default: return nil
            }
        }
    }
    /// Whether the bytes may hold a bare `-0`: a minus and zero followed by no digit, point or
    /// exponent. One inside a string only sends the body to the decoder.
    private static func negativeZero(in data: Data) -> Bool {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Bool in
            guard let base = bytes.baseAddress else { return false }
            var offset = 0
            while offset < bytes.count, let hit = memchr(base + offset, Int32(UInt8(ascii: "-")), bytes.count - offset) {
                let at = base.distance(to: UnsafeRawPointer(hit))
                if at + 1 < bytes.count, bytes[at + 1] == UInt8(ascii: "0") {
                    guard at + 2 < bytes.count else { return true }
                    switch bytes[at + 2] {
                    case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"): break
                    default: return true
                    }
                }
                offset = at + 1
            }
            return false
        }
    }
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
    /// The effort the client chose for this turn (`low`, `medium`, `high`, `xhigh`, `max`); nil when it
    /// did not say, which keeps the run's own. Set by the gateway, never decoded from a client.
    public var effort: String? = nil
    /// The JSON schema a structured answer must fit (`output_config.format`), answered through an answer
    /// tool in interactive mode.
    public var answerSchema: JSONValue? = nil
    /// The client offered Anthropic's web search: the session searches with Claude Code's own WebSearch,
    /// as the subscription does.
    public var webSearch = false
    /// The request comes from one of the client's subagents (`x-claude-code-agent-id`). Set by the gateway,
    /// never decoded from a client.
    public var subagent = false
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
    /// The reply's thinking as it streams: shown to the client, never what it was told.
    case thinking(String)
    /// The signature that closes a thinking block.
    case thinkingSignature(String)
    case toolUse(BridgeToolCall)
    case usage(BridgeUsage)
    case finished(BridgeStopReason)
}

public enum BridgeFailure: Error, Equatable, Sendable, LocalizedError {
    case invalidRequest(String), unsupported(String), unauthenticated, unavailable, paused, busy
    case rateLimited(Date?), permissionRequired, cancelled, compatibility, transport
    case quotaLimited([QuotaWindow])
    case accountUnavailable(AccountState), modelUnavailable
    /// Every account that could serve is at a limit, with when the first of them is back. Unlike
    /// `unavailable` it is no moment's wait: the client is told the limit and its reset, so one that
    /// waits for a reset waits for this one.
    case poolLimited(Date?)
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
        case .poolLimited(let back):
            guard let back else { return "Every account in Claude Pool is at its limit. Check their reset times in Claude Pool." }
            return "Every account in Claude Pool is at its limit. The first is back at \(Self.clock(back))."
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

extension BridgeFailure {
    /// A reset as an error message says it: the hour and minute here, with the weekday when it is not today.
    static func clock(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : "EEE HH:mm"
        return formatter.string(from: date)
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
        PoolModel(id: "claude-fable", name: "Fable", cliAlias: "fable", listedID: "claude-fable-5-2", listedName: "Fable 5.2")]
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
