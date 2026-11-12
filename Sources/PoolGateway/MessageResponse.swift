import Foundation
import PoolCore

/// A reply in the Messages shape, rendered as its events come:
/// `message_start` carries the usage seen so far (zero until the official client reports any) and
/// `message_delta` the usage at the end. Usage is never required: a finished reply without it is
/// whole with zero counts, not a failure.
public struct MessageResponseEncoder {
    public let id: String
    public let model: String
    public private(set) var finished = false
    /// Whether anything of the reply has been rendered: the stream's headers wait for this.
    public private(set) var started = false
    private var index = 0
    private var textOpen = false
    private var text = ""
    private var thinkingOpen = false
    private var thinkingText = ""
    private var thinkingSignature = ""
    private var content: [JSONValue] = []
    private var usage: BridgeUsage?
    private var reason: BridgeStopReason?
    private var contentBytes = 0
    public init(model: String, id: String = "msg_pool_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")) {
        self.model = model; self.id = id
    }

    /// The events of `event`. Usage alone renders nothing: it is said at the start, if it came
    /// first, and at the end.
    public mutating func encode(_ event: BridgeEvent) throws -> [Data] {
        guard !finished else { throw BridgeFailure.transport }
        if case .usage(let value) = event {
            guard value.inputTokens >= 0, value.outputTokens >= 0 else { throw BridgeFailure.transport }
            usage = value
            return []
        }
        switch event {
        case .text(let delta), .thinking(let delta), .thinkingSignature(let delta): if delta.isEmpty { return [] }
        default: break
        }
        var output: [Data] = []
        if !started {
            output.append(sse("message_start", ["type": .string("message_start"), "message": .object(message(empty: true))]))
            started = true
        }
        switch event {
        case .thinking(let delta):
            try reserve(delta.utf8.count)
            // a signed block is whole: more thinking is a block of its own
            if thinkingOpen, !thinkingSignature.isEmpty { closeThinking(into: &output) }
            openThinking(into: &output)
            thinkingText += delta
            output.append(sse("content_block_delta", ["type": .string("content_block_delta"), "index": .number(Double(index)),
                "delta": .object(["type": .string("thinking_delta"), "thinking": .string(delta)])]))
        case .thinkingSignature(let signature):
            try reserve(signature.utf8.count)
            if thinkingOpen, !thinkingSignature.isEmpty { closeThinking(into: &output) }
            openThinking(into: &output)
            thinkingSignature += signature
            output.append(sse("content_block_delta", ["type": .string("content_block_delta"), "index": .number(Double(index)),
                "delta": .object(["type": .string("signature_delta"), "signature": .string(signature)])]))
        case .text(let delta):
            try reserve(delta.utf8.count)
            closeThinking(into: &output)
            if !textOpen {
                output.append(sse("content_block_start", ["type": .string("content_block_start"), "index": .number(Double(index)),
                    "content_block": .object(["type": .string("text"), "text": .string("")])]))
                textOpen = true
            }
            text += delta
            output.append(sse("content_block_delta", ["type": .string("content_block_delta"), "index": .number(Double(index)),
                "delta": .object(["type": .string("text_delta"), "text": .string(delta)])]))
        case .toolUse(let call):
            let input = String(decoding: try call.input.encoded(), as: UTF8.self)
            try reserve(input.utf8.count + call.id.utf8.count + call.name.utf8.count)
            closeThinking(into: &output); closeText(into: &output)
            output.append(sse("content_block_start", ["type": .string("content_block_start"), "index": .number(Double(index)),
                "content_block": .object(["type": .string("tool_use"), "id": .string(call.id), "name": .string(call.name), "input": .object([:])])]))
            output.append(sse("content_block_delta", ["type": .string("content_block_delta"), "index": .number(Double(index)),
                "delta": .object(["type": .string("input_json_delta"), "partial_json": .string(input)])]))
            output.append(sse("content_block_stop", ["type": .string("content_block_stop"), "index": .number(Double(index))]))
            content.append(.object(["type": .string("tool_use"), "id": .string(call.id), "name": .string(call.name), "input": call.input]))
            index += 1
        case .finished(let stop):
            closeThinking(into: &output); closeText(into: &output); reason = stop; finished = true
            output.append(sse("message_delta", ["type": .string("message_delta"),
                "delta": .object(["stop_reason": .string(stop.rawValue), "stop_sequence": .null]),
                "usage": .object(usageFields())]))
            output.append(sse("message_stop", ["type": .string("message_stop")]))
        case .usage: break
        }
        return output
    }

    public var stopReason: BridgeStopReason? { reason }

    /// The whole reply as one Messages body, once it finished.
    public func completeBody() throws -> Data {
        guard finished else { throw BridgeFailure.transport }
        return GatewayJSON.data(message(empty: false))
    }
    /// A reply that fails after its stream began ends on an `error` event and nothing after it
    /// (no `message_stop` follows).
    public static func errorEvent(_ error: Error) -> Data {
        let response = GatewayJSON.failure(error)
        return Data("event: error\ndata: ".utf8) + response.body + Data("\n\n".utf8)
    }
    private mutating func openThinking(into output: inout [Data]) {
        guard !thinkingOpen else { return }
        closeText(into: &output)
        output.append(sse("content_block_start", ["type": .string("content_block_start"), "index": .number(Double(index)),
            "content_block": .object(["type": .string("thinking"), "thinking": .string(""), "signature": .string("")])]))
        thinkingOpen = true
    }
    /// A thinking block ends before anything after it opens. Only a signed one is kept in the
    /// whole body, so a client never sends back thinking without its signature.
    private mutating func closeThinking(into output: inout [Data]) {
        guard thinkingOpen else { return }
        output.append(sse("content_block_stop", ["type": .string("content_block_stop"), "index": .number(Double(index))]))
        if !thinkingSignature.isEmpty {
            content.append(.object(["type": .string("thinking"), "thinking": .string(thinkingText), "signature": .string(thinkingSignature)]))
        }
        thinkingText = ""; thinkingSignature = ""; thinkingOpen = false; index += 1
    }
    private mutating func closeText(into output: inout [Data]) {
        guard textOpen else { return }
        output.append(sse("content_block_stop", ["type": .string("content_block_stop"), "index": .number(Double(index))]))
        content.append(.object(["type": .string("text"), "text": .string(text)]))
        text = ""; textOpen = false; index += 1
    }
    private mutating func reserve(_ count: Int) throws {
        guard count <= 8 * 1024 * 1024 - contentBytes else {
            throw BridgeFailure.unsupported("The reply exceeded the local response limit.")
        }
        contentBytes += count
    }
    private func usageFields() -> [String: JSONValue] {
        let seen = usage ?? BridgeUsage(inputTokens: 0, outputTokens: 0)
        var fields: [String: JSONValue] = ["input_tokens": .number(Double(seen.inputTokens)), "output_tokens": .number(Double(seen.outputTokens))]
        if let read = seen.cacheReadInputTokens { fields["cache_read_input_tokens"] = .number(Double(read)) }
        if let created = seen.cacheCreationInputTokens { fields["cache_creation_input_tokens"] = .number(Double(created)) }
        return fields
    }
    private func message(empty: Bool) -> [String: JSONValue] {
        ["id": .string(id), "type": .string("message"), "role": .string("assistant"),
         "model": .string(model), "content": .array(empty ? [] : content),
         "stop_reason": empty ? .null : reason.map { .string($0.rawValue) } ?? .null, "stop_sequence": .null,
         "usage": .object(usageFields())]
    }
    private func sse(_ event: String, _ value: [String: JSONValue]) -> Data {
        Data("event: \(event)\ndata: ".utf8) + GatewayJSON.data(value) + Data("\n\n".utf8)
    }
}
