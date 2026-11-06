import XCTest
@testable import PoolCore

private final class Lines: @unchecked Sendable {
    private let lock = NSLock(); private var values: [String] = []
    func add(_ line: String) { lock.withLock { values.append(line) } }
    var all: [String] { lock.withLock { values } }
}

final class DiagnosticsTraceTests: XCTestCase {
    func testIdsAreWrittenOneWayEverywhere() {
        let id = UUID(uuidString: "ABCDEF12-3456-4789-ABCD-EF0123456789")!
        // As the account's folder and its client's session file are named.
        XCTAssertEqual(Diagnostics.id(id), "abcdef12")
    }

    func testATraceKeepsItsLatestStepsAndIsWrittenOnlyWhenDumped() {
        let start = Date(timeIntervalSince1970: 1_900_000_000)
        var trace = Diagnostics.Trace(capacity: 3, now: start)
        for (index, step) in ["reply.open:results=1", "results.delivered:1/held:0", "hook.toolCall", "stream.message_start"].enumerated() {
            trace.note(step, at: start.addingTimeInterval(Double(index)))
        }
        trace.touch(at: start.addingTimeInterval(10))
        XCTAssertEqual(trace.lastActivity, start.addingTimeInterval(10))
        let chunks = trace.chunks(now: start.addingTimeInterval(13))
        XCTAssertEqual(chunks, ["results.delivered:1/held:0@-12.0,hook.toolCall@-11.0,stream.message_start@-10.0"])

        let lines = Lines()
        Diagnostics.install { lines.add($0) }
        defer { Diagnostics.install(nil) }
        Diagnostics.dump("session", subject: ("run", "6a36a26f"), why: "stalled", trace: trace, now: start.addingTimeInterval(13))
        XCTAssertEqual(lines.all, ["event=session.trace run=6a36a26f why=stalled part=1/1 steps=" + chunks[0]])
    }

    func testALongTraceIsSplitIntoFieldsThatAreNeverCut() {
        let start = Date(timeIntervalSince1970: 1_900_000_000)
        var trace = Diagnostics.Trace(capacity: 64, now: start)
        for index in 0..<40 { trace.note("stream.block:tool_use", at: start.addingTimeInterval(Double(index))) }
        let chunks = trace.chunks(now: start.addingTimeInterval(40))
        XCTAssertGreaterThan(chunks.count, 1)
        // A field is cut at 160 characters: each part fits, and every step is in one part whole.
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 160 })
        XCTAssertEqual(chunks.joined(separator: ",").split(separator: ",").count, 40)
    }
}
