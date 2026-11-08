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
    /// session, and blocks of kinds the session has no use for are left out.
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
        XCTAssertEqual(first.count, 2, "The document is left out.")
        XCTAssertEqual(first[0]["text"]?.stringValue, "<system-reminder>\n" + ClientRequestShape.advisorGone + "\n</system-reminder>")
        let reply = decoded.messages[1].content.arrayValue!
        XCTAssertEqual(reply.map { $0["type"]?.stringValue }, ["text", "tool_use"])
        XCTAssertNil(reply[1]["caller"])
        XCTAssertEqual(decoded.messages[2].content.arrayValue![0]["content"], .array([.object(["type": .string("text"), "text": .string("ok")])]))
        // a turn told none of its tools (a title, a summary) is a conversation of its own
        var aside = object; aside["tool_choice"] = .object(["type": .string("none")])
        let main = try GatewayRequestValidation.decodeRequest(body(turn)).shape
        let other = try GatewayRequestValidation.decodeRequest(JSONValue.object(aside).encoded()).shape
        XCTAssertNotEqual(main, other)
    }
}
