import Foundation
import XCTest
@testable import PoolCore

/// Collects what `DevRecord` hands its sink, for tests.
final class DevRecordCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [DevRecord.Entry] = []
    func take(_ entry: DevRecord.Entry) { lock.withLock { entries.append(entry) } }
    var records: [(channel: DevRecord.Channel, value: JSONValue)] {
        lock.withLock { entries.compactMap { entry in
            (try? JSONDecoder().decode(JSONValue.self, from: entry.line)).map { (entry.channel, $0) }
        } }
    }
}

final class DevRecordTests: XCTestCase {
    override func tearDown() { DevRecord.install(nil) }

    func testOffNothingIsEvaluated() {
        DevRecord.install(nil)
        var evaluated = false
        DevRecord.record(.privacy, "privacy.prepared") { evaluated = true; return [:] }
        XCTAssertFalse(evaluated)
        XCTAssertFalse(DevRecord.isOn)
    }

    func testRecordsCarryOrderIdsRequestAndData() async {
        let collector = DevRecordCollector()
        DevRecord.install { collector.take($0) }
        DevRecord.record(.http, "http.request", ["run": "0a1b2c3d"]) { ["body": DevRecord.bytes(Data("hello".utf8))] }
        await DevRecord.$request.withValue("7") {
            await Task { DevRecord.record(.session, "pty.out") { ["bytes": DevRecord.bytes(Data([0xff, 0x00]))] } }.value
        }
        Diagnostics.record("gateway.request", ["outcome": "ok"])
        let records = collector.records
        XCTAssertEqual(records.map(\.channel), [.http, .session, .events])
        XCTAssertEqual(records.map { $0.value["seq"]?.doubleValue ?? 0 }, records.map { $0.value["seq"]?.doubleValue ?? 0 }.sorted())
        XCTAssertEqual(records[0].value["run"], .string("0a1b2c3d"))
        XCTAssertEqual(records[0].value["data"]?["body"]?["text"], .string("hello"))
        XCTAssertNil(records[0].value["req"])
        XCTAssertEqual(records[1].value["req"], .string("7"))
        XCTAssertEqual(records[1].value["data"]?["bytes"]?["base64"], .string(Data([0xff, 0x00]).base64EncodedString()))
        XCTAssertEqual(records[2].value["kind"], .string("log.gateway.request"))
        XCTAssertEqual(records[2].value["data"]?["outcome"], .string("ok"))
    }

    /// A real full log (11-07): every request kept its conversation whole, so 283 turns of a few
    /// conversations took 540 MB. Each record keeps what changed since the thread's last one.
    func testAConversationIsKeptAsWhatChangedSinceItsLastRecord() {
        DevRecord.install { _ in }
        func text(_ value: String, cached: Bool = false) -> JSONValue {
            var block: [String: JSONValue] = ["type": .string("text"), "text": .string(value)]
            if cached { block["cache_control"] = .object(["type": .string("ephemeral")]) }
            return .object(["role": .string("user"), "content": .array([.object(block)])])
        }
        let system = JSONValue.string("Instructions"), tools = JSONValue.array([.object(["name": .string("Read")])])
        let first = DevRecord.conversation("session", messages: [text("one", cached: true)], system: system, tools: tools)
        XCTAssertEqual(first["kept"], .number(0))
        XCTAssertEqual(first["system"], system)
        // The next turn: the cache mark moved on, which is no change; only the new messages are kept.
        let next = DevRecord.conversation("session", messages: [text("one"), text("two"), text("three", cached: true)], system: system, tools: tools)
        XCTAssertEqual(next["kept"], .number(1))
        XCTAssertEqual(next["count"], .number(3))
        XCTAssertEqual(next["messages"]?.arrayValue?.count, 2)
        XCTAssertEqual(next["system"], .string("same")); XCTAssertEqual(next["tools"], .string("same"))
        // An edited turn keeps what came before it, and the rest from the edit on.
        let edited = DevRecord.conversation("session", messages: [text("one"), text("TWO")], system: system, tools: .array([]))
        XCTAssertEqual(edited["kept"], .number(1))
        XCTAssertEqual(edited["messages"]?.arrayValue, [text("TWO")])
        XCTAssertEqual(edited["tools"], .array([]))
        // Another thread starts whole, and so does every thread after the log is turned on again.
        XCTAssertEqual(DevRecord.conversation("other", messages: [text("one")], system: system, tools: tools)["kept"], .number(0))
        DevRecord.install { _ in }
        XCTAssertEqual(DevRecord.conversation("session", messages: [text("one")], system: system, tools: tools)["kept"], .number(0))
    }

    /// Desktop counts each tool's tokens in a request of its own and a resumed conversation comes again:
    /// an item of 1 KB or more is kept once in a recording and named after, in any thread.
    func testALargeItemIsKeptOnceAndNamedAfter() {
        DevRecord.install { _ in }
        let tool = JSONValue.object(["name": .string("Read"), "description": .string(String(repeating: "Reads a file. ", count: 100))])
        let first = DevRecord.conversation("count:1", messages: [], system: nil, tools: .array([tool]))
        let name = try? XCTUnwrap(first["tools"]?.arrayValue?.first?["as"]?.stringValue)
        XCTAssertEqual(first["tools"]?.arrayValue?.first?["item"], tool)
        let second = DevRecord.conversation("count:2", messages: [], system: nil, tools: .array([tool, .object(["name": .string("Small")])]))
        XCTAssertEqual(second["tools"]?.arrayValue?.first, .object(["same_as": .string(name ?? "")]))
        XCTAssertEqual(second["tools"]?.arrayValue?.last, .object(["name": .string("Small")]), "A small item is kept as it is")
        // The client's own transcript keeps its shape and short fields; its long words are named by length.
        let row = JSONValue.object(["type": .string("user"), "message": .object(["content": .string(String(repeating: "x", count: 500))])])
        let outlined = DevRecord.outline(row)
        XCTAssertEqual(outlined["type"], .string("user"))
        XCTAssertTrue(outlined["message"]?["content"]?.stringValue?.hasPrefix("<500 chars #") ?? false)
    }
}
