import XCTest
@testable import PoolCore

final class QuotaDisplayTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func window(_ id: String, _ used: Double) -> QuotaWindow {
        .init(id: id, usedPercent: used, observedAt: now, resetsAt: now.addingTimeInterval(4 * 86400))
    }
    private func account(_ windows: [QuotaWindow], plan: String = "Pro") -> PoolAccount {
        .init(email: "user@example.com", plan: plan, state: .ready, windows: windows, createdAt: now)
    }
    private func group(_ summary: QuotaPoolSummary, _ id: String) -> QuotaPoolGroup? { summary.groups.first { $0.windowID == id } }

    /// A panel that was read and has no Fable row is held by the global limits alone: not unknown for Fable.
    func testReadAccountWithoutAModelWindowIsNotUnknownThere() {
        let fable = QuotaWindow.overageIncludedID
        let accounts = [account([window("seven_day", 10), window(fable, 28)]), account([window("five_hour", 5), window("seven_day", 40)])]
        let summary = QuotaPoolSummary.evaluate(accounts, model: PoolRouting.anyModel, now: now)
        let g = group(summary, fable)!
        XCTAssertEqual(g.knownCount, 1)
        XCTAssertEqual(g.unknownCount, 0)
        XCTAssertEqual(g.averageRemainingPercent, 72)
        XCTAssertEqual(group(summary, "seven_day")!.knownCount, 2)
    }

    func testNeverReadAccountStaysUnknownForAModelWindow() {
        let fable = QuotaWindow.overageIncludedID
        let unread = account([])
        let notReported = account([.init(id: "seven_day", observedAt: now, state: .unknown)])
        let summary = QuotaPoolSummary.evaluate([account([window(fable, 28)]), unread, notReported], model: PoolRouting.anyModel, now: now)
        XCTAssertEqual(group(summary, fable)!.knownCount, 1)
        XCTAssertEqual(group(summary, fable)!.unknownCount, 2)
    }

    func testGlobalWindowsStillCountAMissingRowAsUnknown() {
        let summary = QuotaPoolSummary.evaluate([account([window("seven_day", 10), window("five_hour", 10)]), account([window("seven_day", 10)])],
                                                model: PoolRouting.anyModel, now: now)
        XCTAssertEqual(group(summary, "five_hour")!.unknownCount, 1)
    }

    func testWindowsAreListedFiveHourWeekThenModelsThenOther() {
        let ids = ["seven_day_mythos", "something_new", "seven_day_haiku", "seven_day_sonnet", "seven_day", "seven_day_opus",
                   QuotaWindow.overageIncludedID, "five_hour"]
        let summary = QuotaPoolSummary.evaluate([account(ids.map { window($0, 10) })], model: PoolRouting.anyModel, now: now)
        XCTAssertEqual(summary.groups.map(\.windowID), ["five_hour", "seven_day", QuotaWindow.overageIncludedID, "seven_day_opus",
                                                         "seven_day_sonnet", "seven_day_haiku", "seven_day_mythos", "something_new"])
        XCTAssertEqual(summary.groups.last?.scope, .other)
    }

    func testModelNames() {
        XCTAssertEqual(QuotaWindow(id: QuotaWindow.overageIncludedID, observedAt: now).modelName, "Fable")
        XCTAssertEqual(QuotaWindow(id: "seven_day_opus", observedAt: now).modelName, "Opus")
        XCTAssertEqual(QuotaWindow(id: "seven_day_mythos", observedAt: now).modelName, "Mythos")
        XCTAssertNil(QuotaWindow(id: "seven_day", observedAt: now).modelName)
        XCTAssertNil(QuotaWindow(id: "overage", observedAt: now).modelName)
    }
}
