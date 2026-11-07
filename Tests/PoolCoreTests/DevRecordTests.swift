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
}
