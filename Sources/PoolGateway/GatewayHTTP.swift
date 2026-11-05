import Foundation
import PoolCore

public struct GatewayHTTPRequest: Sendable {
    public var method: String
    public var path: String
    public var headers: [String: String]
    public var body: Data
    public init(method: String, path: String, headers: [String: String], body: Data = Data()) {
        self.method = method; self.path = path; self.headers = headers; self.body = body
    }
}

public struct GatewayHTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status; self.headers = headers; self.body = body
    }
}

/// One bounded HTTP/1.1 request per connection. Ambiguous framing is rejected before dispatch.
public struct GatewayHTTPParser {
    public static let maximumHeaderBytes = 16 * 1024
    /// The Messages API's own request limit (32 MB), which Claude Code already holds itself to:
    /// Pool takes whatever the service would and no more, which bounds what one request holds.
    public static let maximumBodyBytes = 32 * 1024 * 1024
    private var bytes = Data()
    public init() {}
    public mutating func append(_ data: Data) throws -> GatewayHTTPRequest? {
        guard bytes.count + data.count <= Self.maximumHeaderBytes + Self.maximumBodyBytes else {
            throw GatewayHTTPError.tooLarge
        }
        bytes.append(data)
        guard let split = bytes.range(of: Data("\r\n\r\n".utf8)) else {
            guard bytes.count <= Self.maximumHeaderBytes else { throw GatewayHTTPError.badRequest }
            return nil
        }
        guard split.upperBound <= Self.maximumHeaderBytes,
              let head = String(data: bytes[..<split.lowerBound], encoding: .ascii) else { throw GatewayHTTPError.badRequest }
        let lines = head.components(separatedBy: "\r\n")
        guard let first = lines.first else { throw GatewayHTTPError.badRequest }
        let words = first.split(separator: " ", omittingEmptySubsequences: false)
        guard words.count == 3, words[2] == "HTTP/1.1", ["GET", "POST"].contains(String(words[0])),
              words[1].first == "/", !words[1].contains("#"),
              words[1].utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { throw GatewayHTTPError.badRequest }
        // Claude Code adds `?beta=true` to its message requests. Routing uses the path alone.
        let path = words[1].split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "" 
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { throw GatewayHTTPError.badRequest }
            let key = String(line[..<colon]).lowercased()
            guard key.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  headers[key] == nil else { throw GatewayHTTPError.badRequest }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard value.utf8.allSatisfy({ $0 == 9 || ($0 >= 32 && $0 < 127) }) else { throw GatewayHTTPError.badRequest }
            headers[key] = value
        }
        guard headers["transfer-encoding"] == nil, headers["expect"] == nil else { throw GatewayHTTPError.badRequest }
        let length: Int
        if let value = headers["content-length"] {
            guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let n = Int(value) else { throw GatewayHTTPError.badRequest }
            length = n
        } else {
            guard words[0] != "POST" else { throw GatewayHTTPError(status: 411, message: "A request length is required.") }
            length = 0
        }
        guard length <= Self.maximumBodyBytes else { throw GatewayHTTPError.tooLarge }
        guard words[0] != "GET" || length == 0 else { throw GatewayHTTPError.badRequest }
        let expected = split.upperBound + length
        guard bytes.count <= expected else { throw GatewayHTTPError.badRequest }
        guard bytes.count == expected else { return nil }
        return GatewayHTTPRequest(method: String(words[0]), path: path, headers: headers,
                                  body: Data(bytes[split.upperBound..<expected]))
    }
}

public struct GatewayHTTPError: Error, Sendable {
    public let status: Int
    public let message: String
    public init(status: Int, message: String) { self.status = status; self.message = message }
    static let badRequest = GatewayHTTPError(status: 400, message: "The local request is malformed.")
    /// A 413 with a hint: whose limit it is and what lowers it.
    static let tooLarge = GatewayHTTPError(status: 413, message: "The request body is over Claude Pool's limit of 32 MB; Claude was not asked. "
        + "This is a request-body byte limit, not the model's context: compact the conversation (/compact in Claude Code), "
        + "or start a new one with a short summary; fewer images or smaller tool results also help.")
}

enum GatewayJSON {
    static func data(_ object: [String: JSONValue]) -> Data {
        // All callers construct finite values and valid JSON; encoding failure remains an internal error.
        (try? JSONValue.object(object).encoded()) ?? Data("{\"type\":\"error\",\"error\":{\"type\":\"api_error\",\"message\":\"Local response encoding failed.\"}}".utf8)
    }
    static func failure(_ error: Error) -> GatewayHTTPResponse {
        let answer = classify(error)
        var headers = ["Content-Type": "application/json"]
        if let wait = retryAfter(error) { headers["Retry-After"] = String(wait) }
        return GatewayHTTPResponse(status: answer.status, headers: headers, body: data([
            "type": .string("error"), "error": .object(["type": .string(answer.type), "message": .string(answer.message)])
        ]))
    }
    /// The status, Anthropic error type and words a failure is answered with. A failure that would be the same on the
    /// next try is never a retryable 5xx: the request's own fault is a 4xx, a session that ended
    /// without an answer is 502, and only a moment's lack of
    /// room is 503, so the client asks again then and only then.
    static func classify(_ error: Error) -> (status: Int, type: String, message: String) {
        if let e = error as? GatewayHTTPError { return (e.status, type(status: e.status), e.message) }
        guard let e = error as? BridgeFailure else {
            if error is CancellationError { return classify(BridgeFailure.cancelled) }
            return (502, "api_error", "The local request failed. Open Claude Pool for help.")
        }
        let message = e.errorDescription ?? "The local request failed."
        switch e {
        case .invalidRequest, .unsupported, .modelUnavailable: return (400, "invalid_request_error", message)
        // Local redaction that is not ready refuses the same request on every account until the
        // person acts: the request's answer, not something to ask again.
        case .privacyUnavailable: return (400, "invalid_request_error", message)
        case .unauthenticated: return (401, "authentication_error", message)
        // A pool account that must sign in again is not the gateway's own credential: a 401
        // here would make the client ask for a new gateway key.
        case .accountUnavailable, .permissionRequired: return (403, "permission_error", message)
        case .rateLimited, .quotaLimited: return (429, "rate_limit_error", message)
        case .cancelled: return (499, "api_error", message)
        case .paused, .unavailable, .busy, .privacyBusy: return (503, "overloaded_error", message)
        case .compatibility, .transport: return (502, "api_error", message)
        case .clientReported(let said, let words): return clientReported(status: said, message: words)
        }
    }
    /// The Anthropic error type for a status.
    static func type(status: Int) -> String {
        switch status {
        case 400, 411, 415: return "invalid_request_error"
        case 401: return "authentication_error"
        case 403: return "permission_error"
        case 404: return "not_found_error"
        case 413: return "request_too_large"
        case 429: return "rate_limit_error"
        case 529: return "overloaded_error"
        default: return "api_error"
        }
    }
    /// The first words of one of Pool's fixed refusals as a tag, letters only.
    static func rule(_ words: String) -> String {
        words.split(whereSeparator: { !$0.isLetter }).prefix(5).map { $0.lowercased() }.joined(separator: "_").prefix(48).description
    }
    /// A failure's name for diagnostics: its case, never its words.
    static func reason(_ error: Error) -> String {
        if let e = error as? GatewayHTTPError { return "http_\(e.status)" }
        guard let e = error as? BridgeFailure else { return error is CancellationError ? "cancelled" : "other" }
        switch e {
        // which of Pool's own refusals it was, by the first words of its fixed text: never the client's
        case .invalidRequest(let words): return "invalidRequest:" + rule(words)
        case .unsupported(let words): return "unsupported:" + rule(words)
        case .unauthenticated: return "unauthenticated"
        case .unavailable: return "unavailable"
        case .paused: return "paused"
        case .busy: return "busy"
        case .rateLimited: return "rateLimited"
        case .permissionRequired: return "permissionRequired"
        case .cancelled: return "cancelled"
        case .compatibility: return "compatibility"
        case .transport: return "transport"
        case .quotaLimited: return "quotaLimited"
        case .accountUnavailable: return "accountUnavailable"
        case .modelUnavailable: return "modelUnavailable"
        case .privacyUnavailable: return "privacyUnavailable"
        case .privacyBusy: return "privacyBusy"
        case .clientReported(let status, _): return "clientReported_\(status)"
        }
    }
    /// How an error the official client reported reaches the caller. A known Anthropic status passes through. Claude Code's own
    /// "Prompt is too long" (status 0: its check, before Anthropic was asked) and any overflow are
    /// a 400 the client compacts on, never a retried 5xx. Anything else is 502.
    static func clientReported(status: Int, message: String) -> (status: Int, type: String, message: String) {
        var code = status >= 400 && status < 600 ? status : 502
        if status == 0, tooLong(status: 400, message) { code = 400 }
        if tooLong(status: code, message) {
            var said = message.lowercased().contains("prompt is too long") ? message : "prompt is too long: " + message
            if status == 0 {
                said += " (Claude Code's own check, before Anthropic was asked: it holds a conversation to its own limit for the account. Compact the conversation to continue.)"
            }
            return (400, "invalid_request_error", said)
        }
        return (code, type(status: code), message)
    }
    /// Whether the conversation no longer fits. Not a reply allowance
    /// (max_tokens) and not a rate limit however it counts, which compacting would not help.
    static func tooLong(status: Int, _ message: String) -> Bool {
        guard status >= 400, status < 500, status != 429 else { return false }
        let lower = message.lowercased()
        if ["max_tokens", "max_output_tokens", "max_completion_tokens"].contains(where: lower.contains) { return false }
        if message.range(of: paceWords, options: [.regularExpression, .caseInsensitive]) != nil { return false }
        return tooLongPatterns.contains { message.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }
    // Words in Chinese too, written as code points: these match client
    // errors and are never shown.
    private static let paceWords = #"rate.?limit|per (minute|hour|day)|\bTP[MD]\b|please wait|try again later|throttl|\x{901F}\x{7387}|\x{9891}\x{7E41}|\x{9891}\x{7387}|\x{9650}\x{6D41}|\x{5E76}\x{53D1}|\x{6BCF}(\x{79D2}|\x{5206}\x{949F}|\x{5C0F}\x{65F6}|\x{5929}|\x{65E5})|\x{7A0D}\x{540E}(\x{518D}\x{8BD5}|\x{91CD}\x{8BD5})"#
    private static let tooLongPatterns = [
        #"context_length_exceeded|prompt is too long|input is too long|(exceeds?|exceeded|over|beyond)( the)?( model'?s?)?( maximum)? context|context (length|limit|window) (exceeded|is exceeded)|context (window )?(is )?full\b|maximum context length|too many (input |prompt )?tokens|\x{4E0A}\x{4E0B}\x{6587}(\x{957F}\x{5EA6})?(\x{8D85}|\x{8FC7}\x{957F})|\x{8D85}(\x{8FC7}|\x{51FA})(\x{4E86})?(\x{6A21}\x{578B})?(\x{7684})?(\x{6700}\x{5927})?\x{4E0A}\x{4E0B}\x{6587}"#,
        #"input token count.*exceeds the maximum|maximum prompt length is \d|reduce the length of the messages|maximum allowed input length|longer than the model'?s context length|available context size|greater than the context length|prompt token count of [\d,]+ exceeds the limit|context window exceeds limit|exceeded model token limit|configured context size|prompt too long|prompt exceeds max length|context_window_exceeded|exceeded (max |maximum )?context length|range of input length should be|token limit exceeded|input tokens? (count )?(exceeds?|exceeded) (the )?(max(imum)? )?limit"#,
        #"(\x{5185}\x{5BB9}|\x{8F93}\x{5165}|\x{6587}\x{672C}|\x{63D0}\x{793A}\x{8BCD}?|prompt|\x{95EE}\x{9898}|\x{5BF9}\x{8BDD}|\x{6D88}\x{606F})(\x{5185}\x{5BB9}|\x{6587}\x{672C})?(\x{957F}\x{5EA6})?\s*(\x{592A}\x{957F}|\x{8FC7}\x{957F}|\x{8D85}\x{957F})|\x{5B57}\x{6570}(\x{592A}\x{591A}|\x{8FC7}\x{591A})"#,
        #"(\x{5185}\x{5BB9}|\x{8F93}\x{5165}|\x{6587}\x{672C}|\x{63D0}\x{793A}\x{8BCD}?|prompt|\x{95EE}\x{9898}|\x{5BF9}\x{8BDD}|\x{6D88}\x{606F})[^\x{FF0C}\x{3002},.;\x{FF1B}!\x{FF01}]{0,12}\x{8D85}(\x{8FC7}|\x{51FA})[^\x{FF0C}\x{3002},.;\x{FF1B}!\x{FF01}]{0,12}(\x{957F}\x{5EA6}|token|\x{4EE4}\x{724C}|\x{5B57}\x{6570})"#,
        #"(\x{8F93}\x{5165}|\x{63D0}\x{793A}\x{8BCD}?|prompt)\s*\x{7684}?\s*(\x{957F}\x{5EA6}|token|\x{4EE4}\x{724C}|\x{5B57}\x{6570})[^\x{FF0C}\x{3002},.;\x{FF1B}!\x{FF01}]{0,8}\x{8D85}(\x{8FC7}|\x{51FA})"#]
    /// Seconds until an official reset, only when the refusal carries one.
    static func retryAfter(_ error: Error, now: Date = Date()) -> Int? {
        let reset: Date?
        switch error as? BridgeFailure {
        case .rateLimited(let date): reset = date
        case .quotaLimited(let windows): reset = windows.compactMap(\.resetsAt).filter { $0 > now }.min()
        default: reset = nil
        }
        return reset.map { max(1, Int($0.timeIntervalSince(now).rounded(.up))) }
    }
}
