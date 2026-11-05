import Foundation
import XCTest
import PoolCore
import PoolRuntime
@testable import PoolEngine

final class EngineHelpersTests: XCTestCase {
    func testHookSpoolsOnlyOwnedSessionFieldsAndNoDecision() throws {
        let fixture = try HelperFixture(); defer { fixture.clean() }
        let body = JSONValue.object(["session_id": .string(fixture.id.uuidString), "prompt_id": .string("prompt"),
            "hook_event_name": .string("MessageDisplay"), "message_id": .string("message"), "turn_id": .string("turn"),
            "index": .number(0), "final": .bool(true), "delta": .string("Synthetic response"),
            "cwd": .string("/synthetic/private/path"), "unrelated": .string("must not persist")])
        try fixture.hook(body, event: "MessageDisplay")
        let paths = try fixture.events()
        XCTAssertEqual(paths.count, 1)
        let stored = try EngineSpool.read(paths[0])
        XCTAssertEqual(stored["event"]?.stringValue, "MessageDisplay")
        XCTAssertEqual(stored["delta"]?.stringValue, "Synthetic response")
        XCTAssertNil(stored["cwd"])
        XCTAssertNil(stored["unrelated"])
        XCTAssertNil(stored["permissionDecision"])
        XCTAssertThrowsError(try fixture.hook(.object(["session_id": .string(UUID().uuidString)]), event: "Stop"))
        XCTAssertEqual(try fixture.events().count, 1)
    }

    func testHelpersRejectSymlinkInputAndBroadDirectoryPermissions() throws {
        let fixture = try HelperFixture(); defer { fixture.clean() }
        let source = fixture.directory.appendingPathComponent("source.json")
        try EngineSpool.write(.object([:]), to: source)
        let link = fixture.directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertThrowsError(try EngineSpool.read(link))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.directory.path)
        XCTAssertThrowsError(try EngineSpool.validate(fixture.directory))
    }

    func testMCPUsesStandardCallsAndReturnsParallelResultsToTheirIDs() async throws {
        let fixture = try HelperFixture(); defer { fixture.clean() }
        _ = try fixture.setTools([.object(["name": .string("tool_0"), "inputSchema": .object(["type": .string("object")])])])
        let input = Pipe()
        defer { try? input.fileHandleForWriting.close() }
        let outputURL = fixture.directory.appendingPathComponent("mcp-output.jsonl")
        FileManager.default.createFile(atPath: outputURL.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: outputURL)
        let run = Task.detached {
            defer { try? output.close() }
            try EngineHelpers.mcp(directory: fixture.directory, input: input.fileHandleForReading, output: output)
        }
        try sendRPC(.object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("initialize"),
            "params": .object(["protocolVersion": .string("2024-11-05")])]), into: input)
        try sendRPC(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")]), into: input)
        try sendRPC(.object(["jsonrpc": .string("2.0"), "id": .number(10), "method": .string("tools/list")]), into: input)
        for id in [2, 3] {
            try sendRPC(.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string("tools/call"),
                "params": .object(["name": .string("tool_0"), "arguments": .object(["request": .number(Double(id))])])]), into: input)
        }
        try await waitUntil { (try? fixture.events().count) == 2 }
        let calls = try fixture.events().map { try EngineSpool.read($0) }
        for call in calls.reversed() {
            let callID = try XCTUnwrap(call["id"]?.stringValue)
            let number = try XCTUnwrap(call["input"]?["request"]?.doubleValue)
            try EngineSpool.write(.object(["content": .array([.object(["type": .string("text"), "text": .string("result-\(Int(number))")])]), "isError": .bool(false)]),
                                  to: fixture.directory.appendingPathComponent("results/\(callID).json"))
        }
        try await waitUntil { ((try? Data(contentsOf: outputURL))?.filter { $0 == 10 }.count ?? 0) == 4 }
        try input.fileHandleForWriting.close()
        try await run.value
        let replies = try String(decoding: Data(contentsOf: outputURL), as: UTF8.self).split(separator: "\n").map {
            try JSONDecoder().decode(JSONValue.self, from: Data($0.utf8))
        }
        for id in [2, 3] {
            let reply = try XCTUnwrap(replies.first { $0["id"]?.doubleValue == Double(id) })
            XCTAssertEqual(reply["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue, "result-\(id)")
        }
    }

    func testChangedCatalogNotifiesRereadsAndKeepsAlreadyPendingCalls() async throws {
        let fixture = try HelperFixture(); defer { fixture.clean() }
        let schema = JSONValue.object(["type": .string("object")])
        let original = try fixture.setTools([.object(["name": .string("removed"), "inputSchema": schema]),
                                             .object(["name": .string("kept"), "inputSchema": schema])])
        let input = Pipe(); defer { try? input.fileHandleForWriting.close() }
        let outputURL = fixture.directory.appendingPathComponent("mcp-output.jsonl")
        FileManager.default.createFile(atPath: outputURL.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: outputURL)
        let run = Task.detached {
            defer { try? output.close() }
            try EngineHelpers.mcp(directory: fixture.directory, input: input.fileHandleForReading, output: output)
        }
        func rpc(_ id: Int, _ method: String, _ params: JSONValue = .object([:])) throws {
            try sendRPC(.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": params]), into: input)
        }
        func replies() -> [JSONValue] {
            guard let data = try? Data(contentsOf: outputURL) else { return [] }
            return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        }
        try rpc(1, "initialize")
        try sendRPC(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")]), into: input)
        try rpc(2, "tools/list")
        let receipt = fixture.directory.appendingPathComponent("tools-listed.json")
        try await waitUntil { (try? EngineSpool.read(receipt)["revision"]?.stringValue) == original }
        try rpc(3, "tools/call", .object(["name": .string("removed"), "arguments": .object([:])]))
        try rpc(4, "tools/call", .object(["name": .string("kept"), "arguments": .object([:])]))
        try await waitUntil { (try? fixture.events().count) == 2 }
        let pending = try fixture.events().map { try EngineSpool.read($0) }
        let newSchema = JSONValue.object(["type": .string("object"), "required": .array([.string("value")])])
        let revised = try fixture.setTools([.object(["name": .string("added"), "inputSchema": schema]),
                                            .object(["name": .string("kept"), "inputSchema": newSchema])])
        try await waitUntil { replies().contains { $0["method"]?.stringValue == "notifications/tools/list_changed" } }
        XCTAssertEqual(try EngineSpool.read(receipt)["revision"]?.stringValue, original)
        // A call made while the list is being taken up again is forwarded, not refused.
        try rpc(5, "tools/call", .object(["name": .string("added")]))
        try await waitUntil { (try? fixture.events().count) == 3 }
        XCTAssertFalse(replies().contains { $0["id"]?.doubleValue == 5 })
        try rpc(6, "tools/list")
        try await waitUntil { (try? EngineSpool.read(receipt)["revision"]?.stringValue) == revised }
        let tools = try XCTUnwrap(replies().first { $0["id"]?.doubleValue == 6 }?["result"]?["tools"]?.arrayValue)
        XCTAssertEqual(tools.map { $0["name"]?.stringValue }, ["added", "kept"])
        XCTAssertEqual(tools[1]["inputSchema"], newSchema)
        try rpc(7, "tools/call", .object(["name": .string("removed")]))
        try await waitUntil { replies().contains { $0["id"]?.doubleValue == 7 } }
        XCTAssertEqual(replies().first { $0["id"]?.doubleValue == 7 }?["error"]?["code"]?.doubleValue, -32602)
        XCTAssertEqual(try fixture.events().count, 3, "A name in neither the listed nor the current catalog is never forwarded")
        for call in pending.reversed() {
            let id = try XCTUnwrap(call["id"]?.stringValue)
            try EngineSpool.write(.object(["content": .array([.object(["type": .string("text"), "text": call["name"]!])])]),
                                  to: fixture.directory.appendingPathComponent("results/\(id).json"))
        }
        try await waitUntil { replies().filter { [3.0, 4.0].contains($0["id"]?.doubleValue ?? 0) }.count == 2 }
        XCTAssertEqual(replies().first { $0["id"]?.doubleValue == 3 }?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue, "removed")
        XCTAssertEqual(replies().first { $0["id"]?.doubleValue == 4 }?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue, "kept")
        XCTAssertEqual(replies().first { $0["id"]?.doubleValue == 1 }?["result"]?["capabilities"]?["tools"]?["listChanged"]?.boolValue, true)
        try input.fileHandleForWriting.close()
        try await run.value
    }

    /// Claude Code names each call by its own tool-use id (`_meta["claudecode/toolUseId"]`), which
    /// its stream and transcript tell the call by: the helper hands it over, and answers it, under
    /// that id. A call made before its input is written comes
    /// without arguments and is handed over with none; one under an id already waiting, or no
    /// usable id, gets one of the helper's.
    func testMCPCallsGoUnderClaudeCodesToolUseID() async throws {
        let fixture = try HelperFixture(); defer { fixture.clean() }
        _ = try fixture.setTools([.object(["name": .string("tool_0"), "inputSchema": .object(["type": .string("object")])])])
        let input = Pipe()
        defer { try? input.fileHandleForWriting.close() }
        let outputURL = fixture.directory.appendingPathComponent("mcp-output.jsonl")
        FileManager.default.createFile(atPath: outputURL.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: outputURL)
        let run = Task.detached {
            defer { try? output.close() }
            try EngineHelpers.mcp(directory: fixture.directory, input: input.fileHandleForReading, output: output)
        }
        try sendRPC(.object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("initialize")]), into: input)
        try sendRPC(.object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")]), into: input)
        func call(_ id: Int, meta: String?, arguments: JSONValue?) throws {
            var params: [String: JSONValue] = ["name": .string("tool_0")]
            if let arguments { params["arguments"] = arguments }
            if let meta { params["_meta"] = .object(["claudecode/toolUseId": .string(meta)]) }
            try sendRPC(.object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string("tools/call"), "params": .object(params)]), into: input)
        }
        try call(2, meta: "toolu_01abc", arguments: .object(["p": .number(1)]))
        try await waitUntil { (try? fixture.events().count) == 1 }
        try call(3, meta: "toolu_01abc", arguments: nil)
        try call(4, meta: "../escape", arguments: .null)
        try await waitUntil { (try? fixture.events().count) == 3 }
        let calls = try fixture.events().map { try EngineSpool.read($0) }
        let named = try XCTUnwrap(calls.first { $0["input"]?["p"] != nil })
        XCTAssertEqual(named["id"]?.stringValue, "toolu_01abc")
        let others = calls.filter { $0["input"]?["p"] == nil }
        XCTAssertEqual(others.count, 2)
        XCTAssertTrue(others.allSatisfy { $0["input"] == nil && UUID(uuidString: $0["id"]?.stringValue ?? "") != nil },
                      "A call with no arguments has no input, and one without a usable id of its own gets the helper's")
        for call in calls {
            let id = try XCTUnwrap(call["id"]?.stringValue)
            try EngineSpool.write(.object(["content": .array([.object(["type": .string("text"), "text": .string(id)])])]),
                                  to: fixture.directory.appendingPathComponent("results/\(id).json"))
        }
        func replies() -> [JSONValue] {
            guard let data = try? Data(contentsOf: outputURL) else { return [] }
            return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { try? JSONDecoder().decode(JSONValue.self, from: Data($0.utf8)) }
        }
        try await waitUntil { replies().filter { [2.0, 3.0, 4.0].contains($0["id"]?.doubleValue ?? 0) }.count == 3 }
        XCTAssertEqual(replies().first { $0["id"]?.doubleValue == 2 }?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue, "toolu_01abc")
        try input.fileHandleForWriting.close()
        try await run.value
    }

    func testUnknownHelperInvocationLeavesOrdinaryLaunchAlone() {
        XCTAssertNil(EngineHelpers.dispatch(arguments: ["--demo"]))
        XCTAssertEqual(EngineHelpers.dispatch(arguments: ["--bridge-hook"]), 64)
    }

    func testExecutableEntryDispatchesHookWithoutLaunchingApplicationServices() async throws {
        let fixture = try HelperFixture(); defer { fixture.clean() }
        let executable = Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("ClaudePool")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
        let process = Process(), input = Pipe(), output = Pipe(), error = Pipe()
        process.executableURL = executable
        process.arguments = ["--bridge-hook", fixture.directory.path, "SessionStart"]
        process.standardInput = input; process.standardOutput = output; process.standardError = error
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: JSONValue.object(["session_id": .string(fixture.id.uuidString)]).encoded())
        try input.fileHandleForWriting.close()
        try await waitUntil { !process.isRunning }
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(try fixture.events().count, 1)
        XCTAssertTrue(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
        XCTAssertTrue(error.fileHandleForReading.readDataToEndOfFile().isEmpty)
    }

    private func sendRPC(_ value: JSONValue, into input: Pipe) throws {
        var bytes = try value.encoded(); bytes.append(10)
        try input.fileHandleForWriting.write(contentsOf: bytes)
    }
}

private final class HelperFixture: @unchecked Sendable {
    let root: URL
    let directory: URL
    let id = UUID()
    init() throws {
        root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/helper-fixtures/\(UUID().uuidString)")
        let workspace = OwnedWorkspace(root: root); try workspace.prepare()
        directory = try workspace.runDirectory(id)
        for part in ["events", "results"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(part), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        try EngineSpool.write(.object(["session_id": .string(id.uuidString)]), to: directory.appendingPathComponent("run.json"))
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
    func hook(_ body: JSONValue, event: String) throws {
        let input = Pipe()
        try input.fileHandleForWriting.write(contentsOf: body.encoded())
        try input.fileHandleForWriting.close()
        try EngineHelpers.hook(directory: directory, event: event, input: input.fileHandleForReading)
    }
    func events() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("events"), includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
    }
    func setTools(_ tools: [JSONValue]) throws -> String {
        let revision = UUID().uuidString
        try EngineSpool.write(.object(["revision": .string(revision), "tools": .array(tools)]), to: directory.appendingPathComponent("tools.json"))
        return revision
    }
}
private func waitUntil(_ predicate: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(30)
    while !predicate() {
        if Date() > deadline { throw BridgeFailure.transport }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}
