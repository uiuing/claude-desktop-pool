import Foundation
import XCTest
@testable import PoolGateway
import PoolCore

/// Requests as Claude Desktop's Code tab sends them: Claude Code with tool search on, auto mode,
/// adaptive thinking with a display, a turn's effort as a system message, ToolSearch answering
/// with tool references, and deferred-tool blocks. The shapes follow what Claude Code sends to a
/// gateway; the contents are synthetic.
final class ClaudeCodeShapeTests: XCTestCase {
    private let tools = #"""
    [{"name":"Bash","description":"Run a command","input_schema":{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]},"cache_control":{"type":"ephemeral"}},
     {"name":"ToolSearch","description":"Fetches full schema definitions for deferred tools","input_schema":{"type":"object","properties":{"query":{"type":"string"},"max_results":{"type":"number"}},"required":["query","max_results"]}},
     {"name":"DeferredToolPlaceholder","description":"","input_schema":{"type":"object"},"defer_loading":true},
     {"name":"mcp__probe__read_a","description":"Read A","input_schema":{"type":"object","properties":{"path":{"type":"string"}}},"defer_loading":true,"strict":true},
     {"name":"mcp__probe__read_b","description":"Read B","input_schema":{"type":"object","properties":{"path":{"type":"string"}}},"defer_loading":true},
     {"type":"tool_search_tool_regex_20251119","name":"tool_search_tool_regex"}]
    """#
    private let system = #"""
    [{"type":"text","text":"x-anthropic-billing-header: cc_version=2.1.318; cch=00000;"},
     {"type":"text","text":"You are Claude Code, a synthetic fixture.","cache_control":{"type":"ephemeral","ttl":"1h"}}]
    """#
    private let turn = #"""
    {"role":"system","content":"","output_config":{"effort":"high"}},
    {"role":"user","content":[{"type":"text","text":"<system-reminder>Synthetic reminder.</system-reminder>"},{"type":"text","text":"Read file a with the probe.","cache_control":{"type":"ephemeral"}}]}
    """#
    private let search = #"""
    {"role":"assistant","content":[{"type":"thinking","thinking":"Synthetic thought.","signature":"c2lnbmF0dXJl"},{"type":"text","text":"Loading the tool."},{"type":"tool_use","id":"toolu_01","name":"ToolSearch","input":{"query":"select:mcp__probe__read_a","max_results":1}}]},
    {"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_01","content":[{"type":"tool_reference","tool_name":"mcp__probe__read_a"}]}]}
    """#

    private func body(_ messages: String, tools: String? = nil) -> Data {
        Data(#"""
        {"model":"claude-opus-5-5","max_tokens":32000,"stream":true,"system":\#(system),"tools":\#(tools ?? self.tools),
         "messages":[\#(messages)],
         "metadata":{"user_id":"{\"device_id\":\"fixture\",\"session_id\":\"fixture-session\"}"},
         "thinking":{"type":"adaptive","display":"updates"},"output_config":{"effort":"high"},
         "context_management":{"edits":[{"type":"clear_thinking_20251015","keep":"all"}]},
         "safeguards":{"mode":"auto"},"speed":"fast","temperature":1}
        """#.utf8)
    }
    private func names(_ request: BridgeRequest) -> [String] { request.tools?.map(\.name) ?? [] }

    func testFirstTurnOffersOnlyTheToolsTheClientLoaded() throws {
        let (request, requested, _) = try GatewayRequestValidation.decodeRequest(body(turn))
        XCTAssertEqual(requested, "claude-opus-5-5")
        XCTAssertEqual(request.model, "claude-opus")
        // Deferred MCP tools wait for ToolSearch; the service's own tool search is not the session's.
        XCTAssertEqual(names(request), ["Bash", "ToolSearch"])
        XCTAssertEqual(request.system, .array([.object(["type": .string("text"), "text": .string("You are Claude Code, a synthetic fixture.")])]))
        // The effort-only system message goes; the user's turn is as sent, without cache hints.
        XCTAssertEqual(request.messages.count, 1)
        XCTAssertEqual(request.messages[0].role, "user")
        XCTAssertEqual(request.messages[0].content.arrayValue?.count, 2)
        XCTAssertNil(request.messages[0].content.arrayValue?[1]["cache_control"])
    }

    /// The effort goes to the run: the turn's system message over the request's, only levels the
    /// official client takes, and never part of the conversation's key.
    func testEffortIsTheTurnsOverTheRequestsAndNotPartOfTheConversation() throws {
        func decode(request: String, turn: String) throws -> (BridgeRequest, String) {
            let text = String(decoding: body(self.turn.replacingOccurrences(of: #"{"effort":"high"}"#, with: turn)), as: UTF8.self)
                .replacingOccurrences(of: #""output_config":{"effort":"high"}"#, with: #""output_config":"# + request)
            let (decoded, _, shape) = try GatewayRequestValidation.decodeRequest(Data(text.utf8))
            return (decoded, shape)
        }
        let (both, shape) = try decode(request: #"{"effort":"high"}"#, turn: #"{"effort":"low"}"#)
        XCTAssertEqual(both.effort, "low", "the turn's own")
        XCTAssertEqual(try decode(request: #"{"effort":"MAX"}"#, turn: "{}").0.effort, "max", "the request's, when the turn names none")
        XCTAssertEqual(try decode(request: #"{"effort":"high"}"#, turn: #"{"effort":"turbo"}"#).0.effort, "high")
        XCTAssertNil(try decode(request: #"{"effort":"extreme"}"#, turn: #"{"effort":7}"#).0.effort)
        let (none, unnamed) = try decode(request: "{}", turn: "{}")
        XCTAssertNil(none.effort)
        // the same conversation at any effort
        XCTAssertEqual(shape, unnamed)
        XCTAssertEqual(GatewayRequestValidation.conversationKey(session: "fixture-session", request: both),
                       GatewayRequestValidation.conversationKey(session: "fixture-session", request: none))
        // the effort-only system message still goes
        XCTAssertEqual(both.messages.map(\.role), ["user"])
    }

    func testToolSearchLoadsTheToolForTheSameConversation() throws {
        let first = try GatewayRequestValidation.decodeRequest(body(turn))
        let second = try GatewayRequestValidation.decodeRequest(body(turn + "," + search))
        XCTAssertEqual(names(second.request), ["Bash", "ToolSearch", "mcp__probe__read_a"])
        XCTAssertEqual(second.request.tools?.last?.inputSchema["properties"]?["path"], .object(["type": .string("string")]))
        // Loading a tool does not make the conversation another one.
        XCTAssertEqual(first.shape, second.shape)
        let result = try XCTUnwrap(second.request.messages.last?.content.arrayValue?.first)
        XCTAssertEqual(result["content"], .array([.object(["type": .string("text"),
            "text": .string("Tool mcp__probe__read_a is loaded and can be called now.")])]))
        // The answer's thinking is the service's record, not something to replay.
        let answer = try XCTUnwrap(second.request.messages[1].content.arrayValue)
        XCTAssertEqual(answer.compactMap { $0["type"]?.stringValue }, ["text", "tool_use"])
    }

    func testDeferredToolBlocksAddAndRemoveTools() throws {
        let call = #"""
        {"role":"assistant","content":[{"type":"tool_use","id":"toolu_02","name":"mcp__probe__read_a","input":{"path":"a"}}]},
        {"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_02","content":"A"}]},
        {"role":"assistant","content":[{"type":"text","text":"Done."}]},
        {"role":"user","content":[{"type":"tool_addition","tool":{"type":"tool_reference","name":"mcp__probe__read_b"}},
                                  {"type":"tool_addition","tool":{"type":"tool_definition","definition":{"name":"mcp__late__ping","description":"Ping","input_schema":{"type":"object"}}}},
                                  {"type":"tool_removal","tool":{"type":"tool_reference","name":"mcp__probe__read_a"}}]},
        {"role":"system","content":[{"type":"text","text":"Synthetic note from the client."}]},
        {"role":"user","content":"Now ping."}
        """#
        let decoded = try GatewayRequestValidation.decodeRequest(body(turn + "," + search + "," + call)).request
        XCTAssertEqual(names(decoded), ["Bash", "ToolSearch", "mcp__probe__read_b", "mcp__late__ping"])
        // The message that only moved tools goes; the system note joins the user's turn.
        XCTAssertEqual(decoded.messages.last?.role, "user")
        XCTAssertEqual(decoded.messages.last?.content, .array([
            .object(["type": .string("text"), "text": .string("Synthetic note from the client.")]),
            .object(["type": .string("text"), "text": .string("Now ping.")])]))
        XCTAssertFalse(decoded.messages.contains { $0.role == "system" })
        XCTAssertEqual(decoded.messages.filter { $0.role == "user" }.count, 4)
    }

    func testASystemNoteStaysWithTheUserTurnItFollowsAsTheConversationGoesOn() throws {
        // Claude Code puts a note as a system message after the turn it was made for; on the next
        // request a reply and a new user turn follow it. Each request must tell that turn the same.
        let results = #"""
        {"role":"assistant","content":[{"type":"tool_use","id":"toolu_03","name":"Bash","input":{"command":"true"}}]},
        {"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_03","content":"ok"}]},
        {"role":"system","content":[{"type":"text","text":"Synthetic note: the user waits for an update."}]}
        """#
        let next = #"""
        {"role":"assistant","content":[{"type":"text","text":"Done."}]},
        {"role":"user","content":"Next."}
        """#
        let first = try GatewayRequestValidation.decodeRequest(body(turn + "," + results)).request
        let second = try GatewayRequestValidation.decodeRequest(body(turn + "," + results + "," + next)).request
        let note = JSONValue.object(["type": .string("text"), "text": .string("Synthetic note: the user waits for an update.")])
        XCTAssertEqual(first.messages.last?.content.arrayValue?.last, note)
        XCTAssertEqual(Array(second.messages.prefix(first.messages.count)), first.messages)
        XCTAssertEqual(second.messages.last?.content, .string("Next."))
        XCTAssertFalse(second.messages.contains { $0.role == "system" })
    }

    func testRouterKeepsOneConversationAcrossToolSearch() throws {
        let router = try GatewayRouter(port: 18473, token: String(repeating: "ab", count: 32))
        let headers = ["host": "127.0.0.1:18473", "authorization": "Bearer " + String(repeating: "ab", count: 32),
                       "content-type": "application/json"]
        var ids: [String] = []
        for messages in [turn, turn + "," + search] {
            guard case .messages(_, let id, let requested) = try router.route(.init(method: "POST", path: "/v1/messages", headers: headers, body: body(messages))) else {
                return XCTFail("A Claude Code request was not served")
            }
            XCTAssertEqual(requested, "claude-opus-5-5"); ids.append(id)
        }
        XCTAssertEqual(ids[0], ids[1])
        XCTAssertTrue(ids[0].hasPrefix("fixture-session#"))
    }

    /// Claude Code names a subagent's requests with `x-claude-code-agent-id`; the main conversation's carry none.
    func testRouterMarksASubagentsRequests() throws {
        let router = try GatewayRouter(port: 18473, token: String(repeating: "ab", count: 32))
        let headers = ["host": "127.0.0.1:18473", "authorization": "Bearer " + String(repeating: "ab", count: 32),
                       "content-type": "application/json"]
        var marked: [Bool] = []
        for extra in [[:], ["x-claude-code-agent-id": "a1b2c3d4e5f60718"], ["x-claude-code-agent-id": ""]] {
            guard case .messages(let request, _, _) = try router.route(.init(method: "POST", path: "/v1/messages",
                    headers: headers.merging(extra) { $1 }, body: body(turn))) else { return XCTFail("A Claude Code request was not served") }
            marked.append(request.subagent)
        }
        XCTAssertEqual(marked, [false, true, false])
    }

    /// Subagents of one type, side by side in one Desktop session (a run of 11-12 had three such tasks,
    /// over 200 messages each): the same session id, model, instructions and tools, told apart only by
    /// `x-claude-code-agent-id`. Each is a conversation of its own, so one's turn never replaces the run
    /// that waits on another's calls; the session before the first "#" still names the conversation
    /// they work for, which keeps them off each other's account.
    func testRouterKeepsEachSubagentItsOwnConversation() throws {
        let router = try GatewayRouter(port: 18473, token: String(repeating: "ab", count: 32))
        let headers = ["host": "127.0.0.1:18473", "authorization": "Bearer " + String(repeating: "ab", count: 32),
                       "content-type": "application/json"]
        func id(_ extra: [String: String]) throws -> String {
            guard case .messages(_, let id, _) = try router.route(.init(method: "POST", path: "/v1/messages",
                    headers: headers.merging(extra) { $1 }, body: body(turn))) else { XCTFail("A Claude Code request was not served"); return "" }
            return id
        }
        let main = try id([:]), a = try id(["x-claude-code-agent-id": "a1b2c3d4e5f60718"])
        let again = try id(["x-claude-code-agent-id": "a1b2c3d4e5f60718"]), b = try id(["x-claude-code-agent-id": "f0e1d2c3b4a59687"])
        XCTAssertEqual(a, again, "A subagent's requests are one conversation")
        XCTAssertNotEqual(a, b, "Two subagents of one type are two conversations")
        XCTAssertNotEqual(a, main, "A subagent is not its conversation's own turns")
        XCTAssertEqual(try id(["x-claude-code-agent-id": "  "]), main, "A blank agent id is the conversation's own turn")
        XCTAssertEqual(Set([main, a, b].map { $0.split(separator: "#", maxSplits: 1).first.map(String.init) }), ["fixture-session"])
        XCTAssertFalse(a.contains("a1b2c3d4e5f60718"), "The header's value stays out of the key")
    }

    func testRequestsWithoutToolSearchAreUnchanged() throws {
        let plain = #"""
        [{"name":"Bash","description":"Run a command","input_schema":{"type":"object"}},
         {"name":"mcp__probe__read_a","description":"Read A","input_schema":{"type":"object"}}]
        """#
        let decoded = try GatewayRequestValidation.decodeRequest(body(turn, tools: plain)).request
        XCTAssertEqual(names(decoded), ["Bash", "mcp__probe__read_a"])
    }

    /// What the interactive client cannot apply is taken without being refused:
    /// server tools are not offered (web search noted, the advisor's instructions said to be void),
    /// stop sequences are not applied, tool_choice and a structured answer's schema are kept for the
    /// session. What the person and their tools sent is kept as it came, whatever its kind (a document
    /// here); an answer keeps its words and calls, the rest being the service's record of it.
    func testControlsTheClientCannotApplyAreTakenNotRefused() throws {
        let server = #"[{"name":"Bash","description":"Run","input_schema":{"type":"object"}},{"type":"web_search_20250305","name":"web_search","max_uses":5},{"type":"advisor_20260301","name":"advisor","model":"claude-opus-5-5"}]"#
        let history = #"""
        {"role":"user","content":[{"type":"text","text":"<system-reminder>\n# Advisor Tool\nCall advisor() when stuck.\n</system-reminder>"},{"type":"document","source":{"type":"base64","media_type":"application/pdf","data":"JVBERg=="}},{"type":"text","text":"Summarise the synthetic report."}]},
        {"role":"assistant","content":[{"type":"server_tool_use","id":"srvtoolu_01","name":"web_search","input":{"query":"synthetic"}},{"type":"web_search_tool_result","tool_use_id":"srvtoolu_01","content":[]},{"type":"text","text":"Found it.","citations":[]},{"type":"tool_use","id":"toolu_02","name":"Bash","input":{"command":"true"},"caller":{"type":"direct"}}]},
        {"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_02","content":[{"type":"text","text":"ok"},{"type":"document","source":{"type":"text","media_type":"text/plain","data":"synthetic"}}]}]}
        """#
        var object = try JSONDecoder().decode(JSONValue.self, from: body(history, tools: server)).objectValue!
        object["stop_sequences"] = .array([.string("END")])
        object["tool_choice"] = .object(["type": .string("tool"), "name": .string("Bash")])
        object["output_config"] = .object(["effort": .string("high"), "format": .object(["type": .string("json_schema"),
            "schema": .object(["type": .string("object"), "properties": .object(["title": .object(["type": .string("string")])])])])])
        object["mcp_servers"] = .array([]); object["container"] = .string("fixture")
        let decoded = try GatewayRequestValidation.decodeRequest(JSONValue.object(object).encoded()).request
        XCTAssertEqual(names(decoded), ["Bash"])
        XCTAssertTrue(decoded.webSearch)
        XCTAssertEqual(decoded.toolChoice, "name:Bash")
        XCTAssertEqual(decoded.answerSchema?["type"], .string("object"))
        let first = decoded.messages[0].content.arrayValue!
        XCTAssertEqual(first.count, 3, "The document is kept")
        XCTAssertEqual(first[1], .object(["type": .string("document"), "source": .object(["type": .string("base64"),
            "media_type": .string("application/pdf"), "data": .string("JVBERg==")])]))
        XCTAssertEqual(first[0]["text"]?.stringValue, "<system-reminder>\n" + ClientRequestShape.advisorGone + "\n</system-reminder>")
        let reply = decoded.messages[1].content.arrayValue!
        XCTAssertEqual(reply.map { $0["type"]?.stringValue }, ["text", "tool_use"])
        XCTAssertNil(reply[1]["caller"])
        XCTAssertEqual(decoded.messages[2].content.arrayValue![0]["content"], .array([.object(["type": .string("text"), "text": .string("ok")]),
            .object(["type": .string("document"), "source": .object(["type": .string("text"), "media_type": .string("text/plain"),
                                                                       "data": .string("synthetic")])])]), "What the tool returned is kept")
        // a turn told none of its tools (a title, a summary) is a conversation of its own
        var aside = object; aside["tool_choice"] = .object(["type": .string("none")])
        let main = try GatewayRequestValidation.decodeRequest(body(turn)).shape
        let other = try GatewayRequestValidation.decodeRequest(JSONValue.object(aside).encoded()).shape
        XCTAssertNotEqual(main, other)
    }

    /// The request is built from one reading of the body, and is the request the decoder built
    /// when the body was read, written out and read again: equal, and equal when written.
    func testOneReadingBuildsTheSameRequestAsTheDecoder() throws {
        let call = #"""
        {"role":"assistant","content":[{"type":"tool_use","id":"toolu_02","name":"mcp__probe__read_a","input":{"path":"a","offset":-0,"limit":2000,"ratio":1.5e300,"big":123456789012345678901234567890,"flag":true,"none":null,"empty":{},"list":[]}}]},
        {"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_02","content":"A","is_error":false},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"iVBORw=="}}],"cache_control":{"type":"ephemeral"}}
        """#
        let plain = #"[{"name":"Bash","input_schema":{"type":"object","properties":{}},"extra":1}]"#
        let bodies = [body(turn), body(turn + "," + search), body(turn + "," + search + "," + call), body(turn, tools: plain),
                      Data(#"{"model":"claude-sonnet","max_tokens":1e3,"system":"x-anthropic-billing-header: a\nSystem.","messages":[{"role":"user","content":"Hi"}],"metadata":{}}"#.utf8),
                      Data(#"{"model":"claude-haiku","max_tokens":5,"messages":[{"role":"user","content":"Hi"}],"model":"claude-opus-5-5"}"#.utf8)]
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        for (index, data) in bodies.enumerated() {
            let (request, requested, shape) = try GatewayRequestValidation.decodeRequest(data)
            let expected = try Self.decoderRequest(data)
            XCTAssertEqual(request, expected.request, "body \(index)")
            XCTAssertEqual(try encoder.encode(request), try encoder.encode(expected.request), "body \(index)")
            XCTAssertEqual(request.toolChoice, expected.request.toolChoice); XCTAssertEqual(request.webSearch, expected.request.webSearch)
            XCTAssertEqual(request.answerSchema, expected.request.answerSchema)
            XCTAssertEqual(requested, expected.requested); XCTAssertEqual(shape, expected.shape, "body \(index)")
            // a body the full log already read is not read again, and builds the same request
            let read = GatewayRequestValidation.Read(data)
            XCTAssertEqual(try GatewayRequestValidation.Read.$current.withValue(read) { try GatewayRequestValidation.decodeRequest(data).request }, request)
        }
        // a tree read from other bytes is never used
        let other = GatewayRequestValidation.Read(body(turn))
        let served = try GatewayRequestValidation.Read.$current.withValue(other) { try GatewayRequestValidation.decodeRequest(bodies[2]).request }
        XCTAssertEqual(served, try Self.decoderRequest(bodies[2]).request)
        XCTAssertThrowsError(try GatewayRequestValidation.Read.$current.withValue(GatewayRequestValidation.Read(Data("{".utf8))) {
            try GatewayRequestValidation.decodeRequest(Data("{".utf8))
        })
    }
    /// How a request was built before it was built from one reading: decoded, adapted, written out and decoded again.
    private static func decoderRequest(_ data: Data) throws -> (request: BridgeRequest, requested: String, shape: String) {
        let adapted = try ClientRequestShape.adapt(JSONDecoder().decode(JSONValue.self, from: data).objectValue!)
        let requested = adapted.object["model"]!.stringValue!
        var request = try JSONDecoder().decode(BridgeRequest.self, from: JSONValue.object(adapted.object).encoded())
        request = GatewayRequestValidation.normalized(request, model: PoolModel.resolve(requested, in: PoolModel.defaults)!)
        request.toolChoice = adapted.toolChoice; request.answerSchema = adapted.answerSchema; request.webSearch = adapted.webSearch
        request.effort = adapted.effort
        return (request, requested, GatewayRequestValidation.shape(of: request, tools: adapted.standingTools))
    }
}
