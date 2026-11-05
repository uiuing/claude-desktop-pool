import Foundation
import XCTest
@testable import PoolCore

final class WarmUpTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!; return calendar
    }()
    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 5) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }
    private func account(_ windows: [QuotaWindow]) -> PoolAccount {
        PoolAccount(email: "warm@example.invalid", plan: "Max 5x", state: .ready, windows: windows)
    }
    private func window(_ id: String, used: Double, read: Date, resets: Date?) -> QuotaWindow {
        QuotaWindow(id: id, usedPercent: used, observedAt: read, resetsAt: resets)
    }

    func testWeeklyLimitIsStartedOnceItsResetHasSettled() {
        let now = at(3)
        let running = window("five_hour", used: 30, read: now.addingTimeInterval(-600), resets: now.addingTimeInterval(7200))
        let week = window("seven_day", used: 60, read: now.addingTimeInterval(-86400), resets: now.addingTimeInterval(-300))
        let plan = WarmUpPlanner.plan(account([running, week]), preferences: .init(onReset: .week), state: nil, now: now, calendar: calendar)
        XCTAssertEqual(plan, WarmUpPlan(windows: ["seven_day"], since: now.addingTimeInterval(-300)))
        // A reset a moment ago is left to settle.
        let fresh = window("seven_day", used: 60, read: now.addingTimeInterval(-86400), resets: now.addingTimeInterval(-30))
        XCTAssertNil(WarmUpPlanner.plan(account([running, fresh]), preferences: .init(), state: nil, now: now, calendar: calendar))
        XCTAssertNil(WarmUpPlanner.plan(account([running, week]), preferences: .init(onReset: .off), state: nil, now: now, calendar: calendar))
    }

    func testFiveHourLimitIsStartedOnlyWhenAsked() {
        let now = at(3)
        let idle = window("five_hour", used: 0, read: now.addingTimeInterval(-60), resets: nil)
        let week = window("seven_day", used: 10, read: now.addingTimeInterval(-60), resets: now.addingTimeInterval(86400))
        XCTAssertNil(WarmUpPlanner.plan(account([idle, week]), preferences: .init(onReset: .week), state: nil, now: now, calendar: calendar))
        XCTAssertEqual(WarmUpPlanner.plan(account([idle, week]), preferences: .init(onReset: .all), state: nil, now: now, calendar: calendar)?.windows,
                       ["five_hour"])
        // 0% with a reset to come is a limit that already runs.
        let started = window("five_hour", used: 0, read: now.addingTimeInterval(-60), resets: now.addingTimeInterval(17000))
        XCTAssertFalse(WarmUpPlanner.idle(started, at: now))
    }

    func testALimitReadingZeroWithItsWholeSpanAheadHasNotBegun() {
        let now = at(3)
        let reported = window("five_hour", used: 0, read: now.addingTimeInterval(-60), resets: now.addingTimeInterval(5 * 3600 - 120))
        XCTAssertTrue(WarmUpPlanner.idle(reported, at: now))
        // Its reset is still ahead, so the stretch begins when the pool found it, not at that reset.
        XCTAssertEqual(WarmUpPlanner.plan(account([reported]), preferences: .init(onReset: .all), state: nil, now: now, calendar: calendar)?.since, now)
        let begun = window("five_hour", used: 1, read: now.addingTimeInterval(-60), resets: now.addingTimeInterval(5 * 3600 - 120))
        XCTAssertFalse(WarmUpPlanner.idle(begun, at: now))
    }

    func testAStretchIsGivenUpAfterItsLastTryUntilTheNextReset() {
        let now = at(3), reset = now.addingTimeInterval(-3600)
        let idle = account([window("five_hour", used: 40, read: reset.addingTimeInterval(-3600), resets: reset)])
        let spent = WarmUpState(since: reset, tries: WarmUpPlanner.maximumTries, retryAt: now.addingTimeInterval(-1))
        XCTAssertNil(WarmUpPlanner.plan(idle, preferences: .init(onReset: .all), state: spent, now: now, calendar: calendar))
        let later = account([window("five_hour", used: 40, read: now.addingTimeInterval(-600), resets: now.addingTimeInterval(-120))])
        XCTAssertEqual(WarmUpPlanner.plan(later, preferences: .init(onReset: .all), state: spent, now: now, calendar: calendar)?.since,
                       now.addingTimeInterval(-120))
    }

    func testAnAccountThatCannotServeIsNeverWarmed() {
        let now = at(3)
        let idle = window("five_hour", used: 40, read: now.addingTimeInterval(-20000), resets: now.addingTimeInterval(-2000))
        let weekUsed = window("seven_day", used: 100, read: now.addingTimeInterval(-600), resets: now.addingTimeInterval(86400))
        XCTAssertNil(WarmUpPlanner.plan(account([idle, weekUsed]), preferences: .init(onReset: .all), state: nil, now: now, calendar: calendar))
        var signedOut = account([idle]); signedOut.state = .signedOut
        XCTAssertNil(WarmUpPlanner.plan(signedOut, preferences: .init(onReset: .all), state: nil, now: now, calendar: calendar))
        XCTAssertNil(WarmUpPlanner.plan(account([]), preferences: .init(onReset: .all), state: nil, now: now, calendar: calendar))
    }

    func testARequestThatDidNotStartTheLimitWaitsLongerEachTimeUntilANewReset() {
        let now = at(3), reset = now.addingTimeInterval(-3600)
        let idle = account([window("five_hour", used: 40, read: reset.addingTimeInterval(-3600), resets: reset)])
        let tried = WarmUpState(since: reset, tries: 1, retryAt: now.addingTimeInterval(600))
        XCTAssertNil(WarmUpPlanner.plan(idle, preferences: .init(onReset: .all), state: tried, now: now, calendar: calendar))
        XCTAssertNotNil(WarmUpPlanner.plan(idle, preferences: .init(onReset: .all), state: tried, now: now.addingTimeInterval(601), calendar: calendar))
        // A later reset begins a new stretch, whatever the last one waits for.
        let older = WarmUpState(since: reset.addingTimeInterval(-18000), tries: 4, retryAt: now.addingTimeInterval(9000))
        XCTAssertEqual(WarmUpPlanner.plan(idle, preferences: .init(onReset: .all), state: older, now: now, calendar: calendar)?.since, reset)
        XCTAssertEqual((1...6).map(WarmUpPlanner.retryDelay), [900, 1800, 3600, 7200, 14400, 14400])
    }

    func testSetTimesStartTheFiveHourLimitOnceWithinTheHour() {
        let preferences = WarmUpPreferences(onReset: .off, dailyTimes: ["06:00", "11:00"])
        let idle = account([window("five_hour", used: 0, read: at(5), resets: nil)])
        XCTAssertNil(WarmUpPlanner.plan(idle, preferences: preferences, state: nil, now: at(5, 50), calendar: calendar))
        let plan = WarmUpPlanner.plan(idle, preferences: preferences, state: nil, now: at(6, 20), calendar: calendar)
        XCTAssertEqual(plan?.daily, "2026-11-05 06:00")
        XCTAssertNil(WarmUpPlanner.plan(idle, preferences: preferences, state: .init(daily: "2026-11-05 06:00"), now: at(6, 30), calendar: calendar))
        XCTAssertNil(WarmUpPlanner.plan(idle, preferences: preferences, state: nil, now: at(7, 5), calendar: calendar), "An hour late at most")
        // Just after midnight, the evening's time is still yesterday's.
        let late = WarmUpPreferences(onReset: .off, dailyTimes: ["23:40"])
        XCTAssertEqual(WarmUpPlanner.plan(idle, preferences: late, state: nil, now: at(0, 10, day: 6), calendar: calendar)?.daily, "2026-11-05 23:40")
    }

    func testIdleLimitsWaitForASetTimeUnderFiveHoursAway() {
        let preferences = WarmUpPreferences(onReset: .all, dailyTimes: ["06:00"])
        let idle = account([window("five_hour", used: 0, read: at(0), resets: nil),
                            window("seven_day", used: 20, read: at(0), resets: at(0).addingTimeInterval(-600))])
        XCTAssertNil(WarmUpPlanner.plan(idle, preferences: preferences, state: nil, now: at(3), calendar: calendar))
        XCTAssertNotNil(WarmUpPlanner.plan(idle, preferences: preferences, state: nil, now: at(0, 30), calendar: calendar))
        XCTAssertEqual(WarmUpPlanner.nextDaily(["06:00"], after: at(7), calendar: calendar), at(6, day: 6))
    }

    func testSettingsKeepOnlyTimesOfDayAndReadOldOrNewerFilesSafely() throws {
        XCTAssertEqual(WarmUpPreferences(dailyTimes: ["6:5", "25:00", "06:05", "23:59", "x", "06:05"]).dailyTimes, ["06:05", "23:59"])
        let newer = try JSONDecoder().decode(WarmUpPreferences.self, from: Data(#"{"onReset":"sometimes","dailyTimes":["07:30"]}"#.utf8))
        XCTAssertEqual(newer, WarmUpPreferences(onReset: .off, dailyTimes: ["07:30"]))
        let old = try JSONDecoder().decode(PoolPreferences.self, from: Data(#"{"port":18473,"language":"system"}"#.utf8))
        XCTAssertEqual(old.warmUp, WarmUpPreferences())
        XCTAssertEqual(old.warmUp.onReset, .off)
    }
}

final class WarmUpDefaultTests: XCTestCase {
    func testStartingLimitsAtResetIsOffUntilChosen() throws {
        XCTAssertEqual(WarmUpPreferences().onReset, .off)
        XCTAssertFalse(WarmUpPreferences().isOn)
        XCTAssertEqual(try JSONDecoder().decode(WarmUpPreferences.self, from: Data("{}".utf8)).onReset, .off)
        XCTAssertEqual(PoolPreferences().warmUp.onReset, .off)
    }
}
