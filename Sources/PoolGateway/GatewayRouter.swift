import Foundation
import PoolCore

public enum GatewayRoute: Sendable {
    case response(GatewayHTTPResponse)
    /// `requestedModel` is the id the client asked for, which its reply names.
    case messages(BridgeRequest, conversationID: String, requestedModel: String)
    /// Claude Desktop's connection check, answered once the pool could take a request for `model`.
    case check(model: PoolModel, requestedModel: String, stream: Bool)
}

public struct GatewayRouter: Sendable {
    public let port: UInt16
    public let models: [PoolModel]
    private let token: String
    public init(port: UInt16, token: String, models: [PoolModel] = PoolModel.defaults) throws {
        guard token.utf8.count >= 32, token.utf8.count <= 256,
              token.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
            throw GatewayHTTPError(status: 500, message: "The local connection credential is invalid.")
        }
        self.port = port; self.token = token; self.models = models
    }

    public func route(_ request: GatewayHTTPRequest) throws -> GatewayRoute {
        guard request.headers["origin"] == nil else { throw GatewayHTTPError(status: 403, message: "Browser requests are not accepted.") }
        guard request.headers["host"] == "127.0.0.1:\(port)" else { throw GatewayHTTPError(status: 403, message: "Use the local connection profile from Claude Pool.") }
        guard let auth = request.headers["authorization"], auth.prefix(7).lowercased() == "bearer ",
              equalToken(String(auth.dropFirst(7))) else { throw BridgeFailure.unauthenticated }
        switch (request.method, request.path) {
        case ("GET", "/health"):
            return .response(.init(status: 200, body: GatewayJSON.data(["status": .string("ready")])) )
        case ("GET", "/v1/models"):
            // The official client's own ids: Claude Desktop names each from its catalog and offers
            // its reasoning levels. Each model stands for its tier, so Desktop's Claude Code asks
            // for these ids when it means a tier.
            let rows = models.map { model in JSONValue.object([
                "id": .string(model.listedID), "type": .string("model"), "display_name": .string(model.listedName),
                "created_at": .string("2025-01-01T00:00:00Z"),
                "anthropic_family_tier": .string(model.cliAlias), "is_family_default": .bool(true)
            ]) }
            return .response(.init(status: 200, body: GatewayJSON.data([
                "data": .array(rows), "has_more": .bool(false),
                "first_id": models.first.map { .string($0.listedID) } ?? .null,
                "last_id": models.last.map { .string($0.listedID) } ?? .null
            ])))
        case ("POST", "/v1/messages"):
            guard let type = request.headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased(),
                  type == "application/json" else { throw GatewayHTTPError(status: 415, message: "Send the message as JSON.") }
            if let check = GatewayRequestValidation.connectionCheck(request.body, models: models) {
                return .check(model: check.model, requestedModel: check.requested, stream: check.stream)
            }
            var (body, requested, shape) = try GatewayRequestValidation.decodeRequest(request.body, models: models)
            let agent = request.headers["x-claude-code-agent-id"]
            body.subagent = GatewayRequestValidation.agentKey(agent) != nil
            let id = try GatewayRequestValidation.conversationID(headers: request.headers, request: body)
                .map { GatewayRequestValidation.conversationKey(session: $0, shape: shape, agent: agent) } ?? "request:\(UUID().uuidString)"
            return .messages(body, conversationID: id, requestedModel: requested)
        default: throw GatewayHTTPError(status: 404, message: "This local route is not supported.")
        }
    }
    private func equalToken(_ candidate: String) -> Bool {
        let a = Array(token.utf8), b = Array(candidate.utf8)
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for i in a.indices { difference |= a[i] ^ b[i] }
        return difference == 0
    }
}
