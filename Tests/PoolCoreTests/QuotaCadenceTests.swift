import XCTest
@testable import PoolCore

final class QuotaCadenceTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let preferences = QuotaRefreshPreferences()

    func testDormantAndRetainedIdleHaveNoAutomaticInterval() {
        var cadence = QuotaCadence()
        XCTAssertNil(cadence.snapshot(at: start, preferences: preferences).interval)
        let id = UUID()
        for second in 0..<100 { cadence.setState(.idle, sessionID: id, at: start.addingTimeInterval(Double(second))) }
        XCTAssertNil(cadence.snapshot(at: start.addingTimeInterval(100), preferences: preferences).interval)
    }
    func testConcurrentGenerationsContinuouslyIncreaseDemand() {
        var cadence = QuotaCadence()
        for count in 1...4 {
            cadence.setState(.generating, sessionID: UUID(), at: start)
            let snapshot = cadence.snapshot(at: start, preferences: preferences)
            XCTAssertEqual(snapshot.generatingSessions, count)
            XCTAssertEqual(snapshot.demand, Double(count))
            XCTAssertEqual(snapshot.interval!, preferences.interval(demand: Double(count)), accuracy: 0.001)
        }
        XCTAssertEqual(cadence.snapshot(at: start, preferences: preferences).interval!, 10, accuracy: 0.001)
    }
    func testFastSingleConversationReachesFastestRateWithoutParallelSessions() {
        var cadence = QuotaCadence(); let session = UUID()
        cadence.setState(.generating, sessionID: session, at: start)
        cadence.record(progress(characters: 1200, duration: 2, at: 2), sessionID: session)
        let fast = cadence.snapshot(at: start.addingTimeInterval(2), preferences: preferences)
        XCTAssertEqual(fast.generatingSessions, 1)
        XCTAssertEqual(fast.interval!, 10, accuracy: 0.001)
        let decayed = cadence.snapshot(at: start.addingTimeInterval(32), preferences: preferences)
        XCTAssertGreaterThan(decayed.interval!, 10)
        XCTAssertLessThan(decayed.interval!, preferences.generatingInterval)
    }
    func testOfficialTokensCanIncreaseDemandWithoutCharacterEstimates() {
        var cadence = QuotaCadence(); let session = UUID()
        cadence.setState(.generating, sessionID: session, at: start)
        cadence.record(progress(characters: 0, usage: .init(inputTokens: 800, outputTokens: 10), duration: 2, at: 2), sessionID: session)
        XCTAssertEqual(cadence.snapshot(at: start.addingTimeInterval(2), preferences: preferences).interval!, 10, accuracy: 0.001)
        var unknownDuration = QuotaCadence()
        unknownDuration.record(progress(characters: 0, usage: .init(inputTokens: 800, outputTokens: 10), duration: 0, at: 2), sessionID: session)
        XCTAssertGreaterThan(unknownDuration.snapshot(at: start.addingTimeInterval(2), preferences: preferences).interval!, 120)
    }
    func testIntermediateRatesInterpolateRatherThanChooseAnAnchor() {
        var cadence = QuotaCadence(); let session = UUID()
        cadence.setState(.generating, sessionID: session, at: start)
        cadence.record(progress(characters: 360, duration: 2, at: 2), sessionID: session)
        let value = cadence.snapshot(at: start.addingTimeInterval(2), preferences: preferences).interval!
        XCTAssertEqual(value, sqrt(45 * 20), accuracy: 0.001)
        XCTAssertFalse([300.0, 120, 45, 20, 10].contains(value))
    }
    func testWaitingAndRecentlyFinishedWorkDecayThenPauseWithoutNewObservations() {
        for state in [QuotaWorkState.waitingUser, .waitingTool, .idle, .ended] {
            var cadence = QuotaCadence(); let session = UUID()
            cadence.setState(.generating, sessionID: session, at: start)
            cadence.record(progress(characters: 240, duration: 2, at: 2), sessionID: session)
            cadence.setState(state, sessionID: session, at: start.addingTimeInterval(2))
            let first = cadence.snapshot(at: start.addingTimeInterval(2), preferences: preferences)
            XCTAssertEqual(first.generatingSessions, 0)
            XCTAssertEqual(first.interval!, 120, accuracy: 0.001)
            let later = cadence.snapshot(at: start.addingTimeInterval(20), preferences: preferences)
            XCTAssertGreaterThan(later.interval!, first.interval!)
            // Repeated lifecycle/UI observations cannot renew the actual activity tail.
            cadence.setState(state, sessionID: session, at: start.addingTimeInterval(500))
            XCTAssertNil(cadence.snapshot(at: start.addingTimeInterval(500), preferences: preferences).interval)
        }
    }
    func testDuplicateAndOutOfOrderProgressCannotInflateOrExtendDemand() {
        var cadence = QuotaCadence(); let session = UUID(), request = UUID()
        let sample = progress(id: request, characters: 240, duration: 2, at: 2)
        cadence.record(sample, sessionID: session)
        let original = cadence
        for _ in 0..<100 { cadence.record(sample, sessionID: session) }
        cadence.record(progress(id: request, characters: 10_000, duration: 2, at: 20), sessionID: session)
        XCTAssertEqual(cadence, original)
        XCTAssertNil(cadence.snapshot(at: start.addingTimeInterval(123), preferences: preferences).interval)
    }
    func testEWMAAndPassiveEvaluationAreDeterministic() {
        var cadence = QuotaCadence(); let session = UUID(), request = UUID()
        cadence.setState(.generating, sessionID: session, at: start)
        cadence.record(progress(id: request, characters: 1200, duration: 2, at: 2), sessionID: session)
        cadence.record(progress(id: request, sequence: 1, characters: 1320, duration: 4, at: 4), sessionID: session)
        let before = cadence
        for second in 5...500 { _ = cadence.snapshot(at: start.addingTimeInterval(Double(second)), preferences: preferences) }
        XCTAssertEqual(cadence, before)
        XCTAssertEqual(cadence.snapshot(at: start.addingTimeInterval(500), preferences: preferences).interval!, 45, accuracy: 0.001)
    }
    func testSustainedFastSingleSessionKeepsItsMeasuredRateAcrossManySamples() {
        var cadence = QuotaCadence(); let session = UUID(), request = UUID()
        cadence.setState(.generating, sessionID: session, at: start)
        for index in 1...100 {
            cadence.record(progress(id: request, sequence: index, characters: index * 1200,
                duration: Double(index * 2), at: Double(index * 2)), sessionID: session)
            let snapshot = cadence.snapshot(at: start.addingTimeInterval(Double(index * 2)), preferences: preferences)
            XCTAssertEqual(snapshot.demand, 5, accuracy: 0.001)
            XCTAssertEqual(snapshot.interval!, 10, accuracy: 0.001)
        }
    }
    func testFirstTinyProgressAfterLongIdleDoesNotReviveOldThroughput() {
        var cadence = QuotaCadence(); let session = UUID()
        cadence.setState(.generating, sessionID: session, at: start)
        cadence.record(progress(characters: 1200, duration: 2, at: 2), sessionID: session)
        XCTAssertEqual(cadence.snapshot(at: start.addingTimeInterval(2), preferences: preferences).interval!, 10, accuracy: 0.001)
        cadence.setState(.idle, sessionID: session, at: start.addingTimeInterval(2))
        XCTAssertNil(cadence.snapshot(at: start.addingTimeInterval(202), preferences: preferences).interval)

        cadence.setState(.generating, sessionID: session, at: start.addingTimeInterval(202))
        cadence.record(progress(characters: 1, duration: 1, at: 203), sessionID: session)
        let resumed = cadence.snapshot(at: start.addingTimeInterval(203), preferences: preferences)
        XCTAssertEqual(resumed.demand, 1, accuracy: 0.001)
        XCTAssertEqual(resumed.interval!, 45, accuracy: 0.001)
        cadence.setState(.idle, sessionID: session, at: start.addingTimeInterval(203))
        XCTAssertGreaterThan(cadence.snapshot(at: start.addingTimeInterval(203), preferences: preferences).interval!, 120)
    }
    func testGenuinelyFastFirstProgressAfterLongIdleUsesItsNewMeasuredRate() {
        var cadence = QuotaCadence(); let session = UUID()
        cadence.setState(.generating, sessionID: session, at: start)
        cadence.record(progress(characters: 1200, duration: 2, at: 2), sessionID: session)
        cadence.setState(.idle, sessionID: session, at: start.addingTimeInterval(2))
        cadence.setState(.generating, sessionID: session, at: start.addingTimeInterval(202))
        cadence.record(progress(characters: 2400, duration: 2, at: 204), sessionID: session)
        let resumed = cadence.snapshot(at: start.addingTimeInterval(204), preferences: preferences)
        XCTAssertEqual(resumed.demand, 10, accuracy: 0.001)
        XCTAssertEqual(resumed.interval!, 10, accuracy: 0.001)
    }
    func testTwoRapidTinyMeasuredResponsesReachFastestEvenWithoutTokenDuration() {
        var cadence = QuotaCadence(); let session = UUID()
        cadence.record(progress(characters: 0, usage: .init(inputTokens: 1, outputTokens: 1), duration: 0, at: 1), sessionID: session)
        let single = cadence.snapshot(at: start.addingTimeInterval(1), preferences: preferences)
        XCTAssertGreaterThan(single.interval!, 120)
        cadence.record(progress(characters: 0, usage: .init(inputTokens: 1, outputTokens: 1), duration: 0, at: 3), sessionID: session)
        let rapid = cadence.snapshot(at: start.addingTimeInterval(3), preferences: preferences)
        XCTAssertEqual(rapid.generatingSessions, 0)
        XCTAssertEqual(rapid.demand, 7.5, accuracy: 0.001)
        XCTAssertEqual(rapid.interval!, 10, accuracy: 0.001)
    }
    func testResponseFrequencyNormalizationUsesOnlyDistinctOfficialUsage() {
        for (gap, expected) in [(30.0, 1.0), (7.5, 4.0)] {
            var cadence = QuotaCadence(); let session = UUID()
            cadence.setState(.generating, sessionID: session, at: start)
            cadence.record(progress(characters: 0, usage: .init(inputTokens: 0, outputTokens: 1), duration: 0, at: 1), sessionID: session)
            cadence.record(progress(characters: 0, usage: .init(inputTokens: 0, outputTokens: 1), duration: 0, at: 1 + gap), sessionID: session)
            XCTAssertEqual(cadence.snapshot(at: start.addingTimeInterval(1 + gap), preferences: preferences).demand, expected, accuracy: 0.001)
        }
        var unmeasured = QuotaCadence(); let session = UUID()
        for second in 1...20 {
            unmeasured.record(progress(characters: 1, duration: 0, at: Double(second)), sessionID: session)
        }
        XCTAssertGreaterThan(unmeasured.snapshot(at: start.addingTimeInterval(20), preferences: preferences).interval!, 120)
    }
    func testDuplicateCompletedUsageCannotSpikeFrequencyOrRenewActivity() {
        var cadence = QuotaCadence(); let session = UUID(), first = UUID()
        cadence.record(progress(id: first, characters: 1, usage: .init(inputTokens: 1, outputTokens: 1), duration: 0, at: 1), sessionID: session)
        let once = cadence
        for sequence in 1...50 {
            cadence.record(progress(id: first, sequence: sequence, characters: 1, usage: .init(inputTokens: 1, outputTokens: 1), duration: 0, at: Double(sequence + 1)), sessionID: session)
        }
        XCTAssertEqual(cadence, once)
        cadence.record(progress(characters: 1, usage: .init(inputTokens: 1, outputTokens: 1), duration: 0, at: 3), sessionID: session)
        let twice = cadence
        cadence.record(progress(id: first, sequence: 99, characters: 1, usage: .init(inputTokens: 1, outputTokens: 1), duration: 0, at: 10), sessionID: session)
        XCTAssertEqual(cadence, twice)
        XCTAssertNil(cadence.snapshot(at: start.addingTimeInterval(124), preferences: preferences).interval)
    }
    func testRapidCompletionDemandDecaysAcrossWaitingAndDoesNotReviveOnResume() {
        for (state, horizon) in [(QuotaWorkState.waitingUser, 30.0), (.waitingTool, 60), (.idle, 120)] {
            var cadence = QuotaCadence(); let session = UUID()
            cadence.setState(.generating, sessionID: session, at: start)
            for second in [1.0, 3.0] {
                cadence.record(progress(characters: 0, usage: .init(inputTokens: 1, outputTokens: 1), duration: 0, at: second), sessionID: session)
            }
            cadence.setState(state, sessionID: session, at: start.addingTimeInterval(3))
            XCTAssertEqual(cadence.snapshot(at: start.addingTimeInterval(3), preferences: preferences).interval!, 10, accuracy: 0.001)
            let quieter = cadence.snapshot(at: start.addingTimeInterval(3 + horizon - 1), preferences: preferences)
            if let interval = quieter.interval { XCTAssertGreaterThan(interval, 10) }
            XCTAssertNil(cadence.snapshot(at: start.addingTimeInterval(3 + horizon), preferences: preferences).interval)
            cadence.setState(.generating, sessionID: session, at: start.addingTimeInterval(203))
            XCTAssertEqual(cadence.snapshot(at: start.addingTimeInterval(203), preferences: preferences).interval!, 45, accuracy: 0.001)
        }
    }
    func testBothPriorPreferenceFormatsMigrateWithoutLosingConfiguredFastestRate() throws {
        let decoder = JSONDecoder()
        let old = try decoder.decode(QuotaRefreshPreferences.self, from: Data("{\"activeInterval\":120,\"refreshInactive\":true}".utf8))
        XCTAssertEqual(old.quietInterval, 600); XCTAssertEqual(old.interactiveInterval, 240)
        XCTAssertEqual(old.burstInterval, 120)
        let three = try decoder.decode(QuotaRefreshPreferences.self, from: Data("{\"lowInterval\":400,\"mediumInterval\":150,\"highInterval\":45}".utf8))
        XCTAssertEqual(three.quietInterval, 400); XCTAssertEqual(three.interactiveInterval, 150); XCTAssertEqual(three.burstInterval, 45)
        XCTAssertEqual(three.generatingInterval, sqrt(150 * 45), accuracy: 0.001)
        XCTAssertTrue(three.isValid)
        let roundTrip = try JSONEncoder().encode(three)
        XCTAssertEqual(try decoder.decode(QuotaRefreshPreferences.self, from: roundTrip), three)
        XCTAssertFalse(String(decoding: roundTrip, as: UTF8.self).contains("highInterval"))
        let proposed = try decoder.decode(QuotaRefreshPreferences.self, from: Data("{\"quietInterval\":200,\"interactiveInterval\":90,\"burstInterval\":30}".utf8))
        XCTAssertEqual(proposed.burstInterval, 30); XCTAssertEqual(proposed.concurrentInterval, 30)
        XCTAssertTrue(proposed.isValid)
        XCTAssertThrowsError(try decoder.decode(QuotaRefreshPreferences.self, from: Data("{\"burstInterval\":9}".utf8)))
    }
    private func progress(id: UUID = UUID(), sequence: Int = 0, characters: Int, usage: BridgeUsage? = nil,
                          duration: TimeInterval, at seconds: TimeInterval) -> QuotaProgress {
        .init(requestID: id, sequence: sequence, outputCharacters: characters, usage: usage,
              activeDuration: duration, observedAt: start.addingTimeInterval(seconds))
    }

    func testBurnPaceBringsReadsForwardNearTheThresholdAndDefersThemFarFromIt() {
        let start = Date(timeIntervalSince1970: 1_900_000_000), reset = start.addingTimeInterval(4 * 3600)
        func reading(_ used: Double, after seconds: TimeInterval) -> QuotaWindow {
            .init(id: "five_hour", usedPercent: used, observedAt: start.addingTimeInterval(seconds), resetsAt: reset)
        }
        var pace = QuotaBurn()
        pace.record([reading(10, after: 0)])
        pace.record([reading(20, after: 600)])
        // 10% in ten minutes: 70% to the 10% threshold is 70 minutes away.
        var account = PoolAccount(email: "pace@example.invalid", state: .ready, windows: [reading(20, after: 600)])
        let now = start.addingTimeInterval(600)
        XCTAssertEqual(pace.secondsToReserve(account, reserve: 10, now: now) ?? 0, 4200, accuracy: 1)
        XCTAssertEqual(pace.interval(45, account: account, reserve: 10, now: now), 135, "Far from the threshold a read waits, at most three times longer")
        account.windows = [reading(86, after: 600)]
        pace.record([reading(86, after: 1200)])
        account.windows = [reading(86, after: 1200)]
        XCTAssertEqual(pace.interval(45, account: account, reserve: 10, now: start.addingTimeInterval(1200)), 15, "Close to it the read comes sooner")
        XCTAssertGreaterThanOrEqual(pace.interval(12, account: account, reserve: 10, now: start.addingTimeInterval(1200)), 10, "Never faster than ten seconds")
        // A new cycle forgets the pace instead of reading the reset as negative use.
        pace.record([.init(id: "five_hour", usedPercent: 1, observedAt: start.addingTimeInterval(1800), resetsAt: reset.addingTimeInterval(18000))])
        XCTAssertNil(pace.secondsToReserve(account, reserve: 10, now: start.addingTimeInterval(1800)))
    }
}
