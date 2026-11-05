import Foundation
import XCTest
@testable import PoolCore

final class UsageLedgerTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return calendar
    }()
    private let alpha = UUID(uuidString: "0a1b2c3d-1111-4aaa-8bbb-000000000001")!
    private let beta = UUID(uuidString: "0a1b2c3d-1111-4aaa-8bbb-000000000002")!
    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }
    /// A Claude Code turn as its transcript reports it: little fresh input, most of the prompt from the
    /// cache, and the writes kept for an hour (Pool runs the client with a one-hour cache).
    private func turn(_ scale: Int = 1) -> BridgeUsage {
        BridgeUsage(inputTokens: 6 * scale, outputTokens: 412 * scale, cacheReadInputTokens: 48_210 * scale,
                    cacheCreationInputTokens: 1_337 * scale, oneHourCacheWrites: 1_337 * scale)
    }
    private func total(_ usage: BridgeUsage) -> Int { TokenTally(usage, price: nil).total }
    private func record(_ ledger: inout UsageLedger, _ usage: BridgeUsage, _ account: UUID, _ model: String = "claude-sonnet-5-5", at date: Date) {
        ledger.record(usage, accountID: account, model: model, name: model, at: date, calendar: calendar)
    }

    func testRecordsOneRowPerDayAccountAndModelWithHours() {
        var ledger = UsageLedger()
        record(&ledger, turn(), alpha, at: at(5, 9, 10))
        record(&ledger, turn(), alpha, at: at(5, 9, 40))
        record(&ledger, turn(), alpha, "claude-opus-5-5", at: at(5, 14))
        record(&ledger, turn(), beta, at: at(4, 23, 59))
        XCTAssertEqual(ledger.days.map(\.day), ["2026-11-04", "2026-11-05"], "Days stay in order whatever order replies arrive in.")
        let sonnet = ledger.days[1].entries.first { $0.model == "claude-sonnet-5-5" }!
        XCTAssertEqual(sonnet.tally.replies, 2)
        XCTAssertEqual(sonnet.tally.cacheRead, 96_420)
        XCTAssertEqual(sonnet.tally.oneHourWrites, 2_674)
        XCTAssertEqual(sonnet.hours?[9], 2 * total(turn()))
        XCTAssertEqual(ledger.days[1].entries.count, 2)
    }

    func testEmptyUsageAndNegativeCountsAddNothing() {
        var ledger = UsageLedger()
        record(&ledger, .init(inputTokens: 0, outputTokens: 0), alpha, at: at(5, 9))
        XCTAssertTrue(ledger.isEmpty)
        record(&ledger, .init(inputTokens: -5, outputTokens: 10, oneHourCacheWrites: 99), alpha, at: at(5, 9))
        let tally = ledger.days.first?.entries.first?.tally
        XCTAssertEqual(tally?.total, 10)
        XCTAssertEqual(tally?.oneHourWrites, 0, "One-hour writes never exceed the writes.")
    }

    func testCostFollowsListPricesAndOneHourWrites() {
        let price = ModelPricing.price(for: "claude-opus-5-5")!
        // 1M input $4, 1M output $20, 1M cache read $0.20, 1M 5-minute write $5, 1M 1-hour write $8.
        let cost = price.cost(input: 1_000_000, output: 1_000_000, cacheRead: 1_000_000, cacheWrite: 2_000_000, oneHourWrites: 1_000_000)
        XCTAssertEqual(cost.actual, 4 + 20 + 0.20 + 5 + 8, accuracy: 0.0001)
        XCTAssertEqual(cost.uncached, 4 * 4 + 20, accuracy: 0.0001)
        XCTAssertEqual(ModelPricing.price(for: "claude-opus-5-5[1m]"), price)
        XCTAssertNotEqual(ModelPricing.price(for: "claude-opus-5"), price, "The longer id wins.")
        XCTAssertEqual(ModelPricing.price(for: "claude-sonnet-4-5-20250929")?.input, 3)
        XCTAssertNil(ModelPricing.price(for: "claude-unknown-9"))
    }

    func testHaikuIsBilledWholeAtTheTierItsPromptReaches() {
        let price = ModelPricing.price(for: "claude-haiku-5-5")!
        XCTAssertEqual(price.cost(input: 100_000, output: 0, cacheRead: 0, cacheWrite: 0, oneHourWrites: 0).actual, 0.01, accuracy: 1e-9)
        XCTAssertEqual(price.cost(input: 100_001, output: 1_000, cacheRead: 0, cacheWrite: 0, oneHourWrites: 0).actual,
                       (100_001 * 0.50 + 1_000 * 2.50) / 1e6, accuracy: 1e-9)
    }

    func testUnknownModelCountsTokensButNotCost() {
        var ledger = UsageLedger()
        record(&ledger, turn(), alpha, "claude-unknown-9", at: at(5, 9))
        let summary = ledger.summary(.today, now: at(5, 10), calendar: calendar)
        XCTAssertEqual(summary.totals.total, total(turn()))
        XCTAssertEqual(summary.totals.cost, 0)
        XCTAssertEqual(summary.totals.unpriced, 1)
    }

    func testCacheSavingIsAgainstSendingTheCachedTokensAsInput() {
        let tally = TokenTally(turn(), price: ModelPricing.price(for: "claude-sonnet-5-5"))
        XCTAssertGreaterThan(tally.cacheSaving, 0)
        XCTAssertEqual(tally.cacheHitRate!, 48_210.0 / Double(6 + 48_210 + 1_337), accuracy: 0.0001)
        XCTAssertNil(TokenTally().cacheHitRate)
    }

    func testWeekSummaryComparesWithThePreviousSevenDays() {
        var ledger = UsageLedger()
        record(&ledger, turn(2), alpha, at: at(5, 10))
        record(&ledger, turn(), beta, "claude-opus-5-5", at: at(1, 10))
        record(&ledger, turn(), beta, "claude-opus-5-5", at: at(5, 10).addingTimeInterval(-8 * 86_400))
        let summary = ledger.summary(.week, now: at(5, 18), calendar: calendar)
        XCTAssertEqual(summary.buckets.count, 7)
        XCTAssertEqual(summary.buckets.last?.total.tokens, total(turn(2)))
        XCTAssertEqual(summary.totals.replies, 2)
        XCTAssertEqual(summary.previous?.replies, 1)
        XCTAssertEqual(summary.accounts.map(\.id), [alpha.uuidString, beta.uuidString], "Largest first.")
        XCTAssertEqual(summary.accounts.first?.trend.count, 7)
        XCTAssertEqual(summary.activeDays, 2)
        XCTAssertEqual(summary.tokenChange!, Double(3 * total(turn()) - total(turn())) / Double(total(turn())), accuracy: 0.0001)
        XCTAssertNotNil(summary.costChange)
    }

    func testTodayComparesWithYesterdayOnlyUpToThisHour() {
        var ledger = UsageLedger()
        record(&ledger, turn(), alpha, at: at(4, 8))
        record(&ledger, turn(5), alpha, at: at(4, 20))
        record(&ledger, turn(), alpha, at: at(5, 9))
        let summary = ledger.summary(.today, now: at(5, 10), calendar: calendar)
        XCTAssertEqual(summary.buckets.count, 24)
        XCTAssertEqual(summary.buckets[9].total.tokens, total(turn()))
        XCTAssertEqual(summary.tokenChange ?? -1, 0, accuracy: 0.001, "Yesterday's evening is not set against this morning.")
    }

    func testFilterNarrowsToAccountsAndModel() {
        var ledger = UsageLedger()
        record(&ledger, turn(), alpha, at: at(5, 9))
        record(&ledger, turn(), alpha, "claude-opus-5-5", at: at(5, 9))
        record(&ledger, turn(3), beta, at: at(5, 9))
        let accounts = ledger.summary(.today, filter: .init(accounts: [alpha]), now: at(5, 10), calendar: calendar)
        XCTAssertEqual(accounts.totals.replies, 2)
        XCTAssertEqual(accounts.accounts.map(\.id), [alpha.uuidString])
        let opus = ledger.summary(.today, filter: .init(model: "claude-opus-5-5"), now: at(5, 10), calendar: calendar)
        XCTAssertEqual(opus.models.map(\.id), ["claude-opus-5-5"])
        XCTAssertEqual(opus.totals.total, total(turn()))
    }

    /// A hundred accounts stack as five colored series and one for the rest, by plan or by account.
    func testLargePoolFoldsChartSeriesAndGroupsByPlan() {
        var ledger = UsageLedger()
        let ids = (0..<100).map { UUID(uuidString: String(format: "0a1b2c3d-2222-4aaa-8bbb-%012d", $0))! }
        var plans: [UUID: String] = [:]
        for (index, id) in ids.enumerated() {
            plans[id] = index % 2 == 0 ? "Max 20x" : "Pro"
            record(&ledger, turn(index + 1), id, at: at(5, 9))
        }
        let byAccount = ledger.summary(.today, grouping: .account, plans: plans, now: at(5, 10), calendar: calendar)
        XCTAssertEqual(byAccount.series.count, UsageLedger.seriesLimit + 1)
        XCTAssertEqual(byAccount.series.last?.id, UsageSummary.other)
        XCTAssertEqual(byAccount.series.first?.id, ids[99].uuidString)
        XCTAssertEqual(byAccount.buckets[9].parts.count, UsageLedger.seriesLimit + 1)
        XCTAssertEqual(byAccount.buckets[9].parts.values.map(\.tokens).reduce(0, +), byAccount.totals.total, "Folding loses nothing.")
        XCTAssertEqual(byAccount.accounts.count, 100)
        let byPlan = ledger.summary(.today, grouping: .plan, plans: plans, now: at(5, 10), calendar: calendar)
        XCTAssertEqual(Set(byPlan.series.map(\.id)), ["Max 20x", "Pro"])
        XCTAssertEqual(byPlan.plans.count, 2)
    }

    func testAllRunsFromTheFirstDayAndOldDaysAndHoursArePruned() {
        var ledger = UsageLedger()
        let old = at(5, 9).addingTimeInterval(-Double(UsageLedger.keptDays + 3) * 86_400)
        record(&ledger, turn(), alpha, at: old)
        record(&ledger, turn(), alpha, at: at(3, 9))
        record(&ledger, turn(), alpha, at: at(5, 9))
        XCTAssertEqual(ledger.days.map(\.day), ["2026-11-03", "2026-11-05"])
        XCTAssertNil(ledger.days[0].entries[0].hours, "Hours are kept for today and yesterday only.")
        XCTAssertNotNil(ledger.days[1].entries[0].hours)
        let all = ledger.summary(.all, now: at(5, 9), calendar: calendar)
        XCTAssertEqual(all.buckets.count, 3)
        XCTAssertNil(all.previous)
    }

    func testLedgerRoundTripsThroughJSONWithoutContent() throws {
        var ledger = UsageLedger()
        record(&ledger, turn(), alpha, at: at(5, 9))
        let data = try JSONEncoder().encode(ledger)
        XCTAssertEqual(try JSONDecoder().decode(UsageLedger.self, from: data), ledger)
        let keys = Set((try JSONSerialization.jsonObject(with: data) as? [String: Any])?.keys.map { $0 } ?? [])
        XCTAssertEqual(keys, ["version", "days"])
    }

    func testSpeedIsTimedOutputOverGenerationTimeAndIgnoresUntimedReplies() {
        var ledger = UsageLedger()
        // An older reply with no time: its tokens must not lift the speed.
        record(&ledger, turn(10), alpha, at: at(5, 9))
        XCTAssertNil(ledger.summary(.today, now: at(5, 12), calendar: calendar).totals.tokensPerSecond)
        // 412 tokens in 4s and 824 in 12s: 1236 / 16 = 77.25, not the mean of 103 and 68.67.
        ledger.record(turn(), accountID: alpha, model: "claude-sonnet-5-5", name: "Sonnet", at: at(5, 10), seconds: 4, calendar: calendar)
        ledger.record(turn(2), accountID: alpha, model: "claude-sonnet-5-5", name: "Sonnet", at: at(5, 11), seconds: 12, calendar: calendar)
        let totals = ledger.summary(.today, now: at(5, 12), calendar: calendar).totals
        XCTAssertEqual(totals.timedOutput, 1236)
        XCTAssertEqual(totals.tokensPerSecond ?? 0, 77.25, accuracy: 0.001)
        // Zero, negative or non-finite times are not recorded.
        for bad in [0, -3, Double.nan, Double.infinity] {
            XCTAssertNil(TokenTally(turn(), price: nil, seconds: bad).tokensPerSecond)
        }
    }

    func testSpeedSurvivesJSONAndOldRowsDecodeWithoutIt() throws {
        var ledger = UsageLedger()
        ledger.record(turn(), accountID: alpha, model: "claude-sonnet-5-5", name: "Sonnet", at: at(5, 9), seconds: 5, calendar: calendar)
        let decoded = try JSONDecoder().decode(UsageLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertEqual(decoded, ledger)
        let old = try JSONDecoder().decode(TokenTally.self, from: Data(#"{"i":6,"o":412,"n":1}"#.utf8))
        XCTAssertNil(old.tokensPerSecond)
        XCTAssertEqual(old.output, 412)
    }
}
