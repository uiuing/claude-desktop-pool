import Foundation
@testable import PoolPrivacy
import XCTest

/// The bridge's reading of requests by the local model, as the masking runs it by default.
final class PrivacyReaderTests: XCTestCase {
    /// Of the requests waiting, the one with the fewest bytes left is read next,
    /// and a request's newest text first (`missing`).
    func testFewestBytesLeftIsReadNextAndNewestTextFirst() async throws {
        let detector = GatedDetector(), reader = PrivacyReader(detector: detector, wait: .seconds(30), turns: 1)
        let long = (0..<900).map { "alpha line \($0) of a long synthetic log\n" }.joined() // many pieces, none alike
        let olderMedium = "bravo-older " + String(repeating: "b", count: 3_000)
        let newerMedium = "bravo-newer " + String(repeating: "b", count: 3_000)
        let short = "charlie short synthetic note"
        let far = ContinuousClock.now.advanced(by: .seconds(30))
        let a = Task { await reader.read([long], until: far) }
        try await privacyQueueEventually { await detector.texts.count == 1 }
        let b = Task { await reader.read([newerMedium, olderMedium], until: far) }
        try await privacyQueueEventually { await reader.state.jobs == 2 }
        let c = Task { await reader.read([short], until: far) }
        try await privacyQueueEventually { await reader.state.jobs == 3 }
        await detector.release()
        for reading in [await a.value, await b.value, await c.value] { XCTAssertTrue(reading.read.allSatisfy { $0 != nil }) }
        let texts = await detector.texts
        XCTAssertTrue(texts[0].hasPrefix("alpha"), "The long text's chunk already being read is finished")
        XCTAssertEqual(texts[1], short, "The request with the fewest bytes left goes next")
        XCTAssertTrue(texts[2].hasPrefix("bravo-newer"), "Then the next fewest, its newest text first")
        XCTAssertTrue(texts[3].hasPrefix("bravo-older"))
        XCTAssertTrue(texts[4...].allSatisfy { $0.hasPrefix("alpha") })
        XCTAssertEqual(texts.count, PrivacyReader.pieces(of: long).count + 3, "Every piece read once")
    }

    /// Past its wait a request goes with what is known (nil for what the model had not read). The chunks
    /// being read for it are finished and kept for the next request; the rest is left.
    func testOnlyTheChunksBeingReadAreFinishedAfterTheWait() async throws {
        let detector = GatedDetector(gated: false, delay: .milliseconds(60))
        let reader = PrivacyReader(detector: detector, wait: .milliseconds(10))
        let texts = (1...4).map { "delta text \($0) " + String(repeating: "d", count: 3_000) }
        let first = await reader.read(texts, until: ContinuousClock.now.advanced(by: .milliseconds(10)))
        XCTAssertTrue(first.read.contains { $0 == nil }, "Not read within the wait")
        try await privacyQueueEventually { await reader.state == (0, 0) }
        let asked = await detector.texts.count
        XCTAssertEqual(asked, 1, "Only the chunk in flight was finished: a request reads one at a time")
        let next = await reader.read(texts, until: ContinuousClock.now)
        XCTAssertEqual(next.read.filter { $0 != nil }.count, 1, "What was finished is kept")
    }

    /// Of what was sent before unread, a request reads backlogCap at most, after what is new in it.
    func testABacklogIsReadALittleARequest() async throws {
        let detector = GatedDetector(gated: false)
        let reader = PrivacyReader(detector: detector, wait: .seconds(5))
        let late = (1...5).map { "echo history \($0) " + String(repeating: "e", count: 3_000) }
        let reading = await reader.read(["foxtrot new turn"], lookUp: late, until: ContinuousClock.now.advanced(by: .seconds(5)))
        XCTAssertNotNil(reading.read[0])
        let readLate = reading.lookedUp.filter { $0 != nil }.count
        XCTAssertGreaterThan(readLate, 0)
        XCTAssertLessThan(readLate, late.count, "The rest of the backlog is left for later requests")
    }

    /// Short texts are read together, joined by a paragraph's end, each given only its own spans.
    func testShortTextsAreReadJoinedAndEachKeepsItsOwnSpans() async throws {
        let detector = FixtureDetector(words: ["Synthetic Person": .person])
        let reader = PrivacyReader(detector: detector)
        let texts = ["first note", "ask Synthetic Person", "Synthetic Person replied"]
        let reading = await reader.read(texts, until: ContinuousClock.now.advanced(by: .seconds(5)))
        let inspected = await detector.inspected
        XCTAssertEqual(inspected.count, 1, "One chunk")
        XCTAssertEqual(inspected.keys.first, texts.joined(separator: "\n\n"))
        XCTAssertEqual(reading.read[0]?.count, 0)
        XCTAssertEqual(reading.read[1]?.map { [$0.start, $0.end] }, [[4, 20]])
        XCTAssertEqual(reading.read[2]?.map { [$0.start, $0.end] }, [[0, 16]])
    }

    func testFailedModelRestsBeforeRetry() {
        XCTAssertEqual((1...7).map { PrivacyReader.retryAfter($0) },
                       [.seconds(30), .seconds(60), .seconds(120), .seconds(240), .seconds(480), .seconds(600), .seconds(600)])
    }
}

private actor GatedDetector: PrivacyEntityDetector {
    private(set) var texts: [String] = []
    private var gated: Bool
    private let delay: Duration
    private var gate: CheckedContinuation<Void, Never>?
    init(gated: Bool = true, delay: Duration = .zero) { self.gated = gated; self.delay = delay }
    func detect(in text: String) async throws -> [PrivacySpan] {
        texts.append(text)
        if gated { await withCheckedContinuation { gate = $0 } }
        if delay > .zero { try await Task.sleep(for: delay) }
        return []
    }
    func release() { gated = false; gate?.resume(); gate = nil }
}
