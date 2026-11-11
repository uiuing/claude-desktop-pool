import XCTest
@testable import PoolCore

final class QuotaScopeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func account(_ windows: [QuotaWindow]) -> PoolAccount {
        .init(email: "user@example.com", plan: "Pro", state: .ready, windows: windows, createdAt: now)
    }
    private func week(_ used: Double) -> QuotaWindow {
        .init(id: "seven_day", usedPercent: used, observedAt: now, resetsAt: now.addingTimeInterval(4 * 86400))
    }
    private func fable(_ used: Double, at date: Date? = nil, resets: TimeInterval = 4 * 86400) -> QuotaWindow {
        .init(id: "seven_day_overage_included", usedPercent: used, observedAt: date ?? now, resetsAt: now.addingTimeInterval(resets))
    }

    func testKnownIdsGetTheirScopeAndEverythingElseIsOther() {
        XCTAssertEqual(QuotaWindow(id: "five_hour", observedAt: now).scope, .all)
        XCTAssertEqual(QuotaWindow(id: "seven_day", observedAt: now).scope, .all)
        for family in ["opus", "sonnet", "haiku", "mythos"] {
            XCTAssertEqual(QuotaWindow(id: "seven_day_\(family)", observedAt: now).scope, .models([family]))
        }
        XCTAssertEqual(QuotaWindow(id: "seven_day_overage_included", observedAt: now).scope, .models(["fable"]))
        for id in ["overage", "seven_day_oauth_apps", "seven_day_cowork", "seven_day_omelette", "something_new"] {
            XCTAssertEqual(QuotaWindow(id: id, usedPercent: 100, observedAt: now).scope, .other, id)
        }
    }

    /// library.json written before scopes: a model family for a model-scoped window, none for a global one.
    func testOldSavedWindowsMigrate() throws {
        let json = """
        {"id":"8B1E8F5C-0F0B-4A4E-9C55-2F6C7C1E0A11","email":"user@example.com","state":"ready","createdAt":0,
        "windows":[
        {"id":"seven_day_fable","usedPercent":40,"observedAt":0,"resetsAt":600000,"state":"reported","modelFamily":"fable","startsOnNextUse":false},
        {"id":"seven_day","usedPercent":10,"observedAt":0},
        {"id":"seven_day_sonnet","usedPercent":10,"observedAt":0,"modelFamily":"sonnet"},
        {"id":"seven_day_cowork","usedPercent":100,"observedAt":0},
        {"id":"vendor_window","usedPercent":100,"observedAt":0,"modelFamily":"opus"}]}
        """
        let saved = try JSONDecoder().decode(PoolAccount.self, from: Data(json.utf8))
        let windows = saved.windows
        XCTAssertEqual(windows.map(\.id), ["seven_day_overage_included", "seven_day", "seven_day_sonnet", "seven_day_cowork", "vendor_window"])
        XCTAssertEqual(windows.map(\.scope), [.models(["fable"]), .all, .models(["sonnet"]), .other, .models(["opus"])])
        XCTAssertEqual(windows[0].usedPercent, 40)
        // and it round-trips in the new form
        let again = try JSONDecoder().decode(PoolAccount.self, from: try JSONEncoder().encode(saved))
        XCTAssertEqual(again.windows, windows)
    }

    /// A library saved by a build that kept reset cards still reads: the fields it wrote are ignored.
    func testALibraryWithRetiredResetFieldsStillReads() throws {
        let json = """
        {"id":"8B1E8F5C-0F0B-4A4E-9C55-2F6C7C1E0A12","email":"user@example.com","state":"ready","createdAt":0,
        "windows":[{"id":"seven_day","usedPercent":10,"observedAt":0}],
        "resetGrants":[{"kind":"fable","left":1,"total":3,"observedAt":0}],
        "lastResetUse":{"kind":"session","outcome":"used","left":1,"at":0}}
        """
        let account = try JSONDecoder().decode(PoolAccount.self, from: Data(json.utf8))
        XCTAssertEqual(account.email, "user@example.com")
        XCTAssertEqual(account.windows.map(\.id), ["seven_day"])
        let saved = String(decoding: try JSONEncoder().encode(account), as: UTF8.self)
        XCTAssertFalse(saved.contains("resetGrants") || saved.contains("lastResetUse"))
    }

    func testAFableRefusalBlocksOnlyFableAndNotTheAccount() {
        var a = account([QuotaWindow(id: "five_hour", usedPercent: 5, observedAt: now, resetsAt: now.addingTimeInterval(3600)), week(10)])
        let refused = fable(98).refused()
        a.absorb([refused], at: now)
        XCTAssertEqual(a.effectiveState(at: now), .ready)
        XCTAssertFalse(a.isWeekUsedUp(at: now))
        XCTAssertTrue(PoolRouting.candidates([a], model: "claude-fable-5", now: now).isEmpty)
        for model in ["claude-sonnet-5", "claude-opus-5"] {
            XCTAssertFalse(PoolRouting.candidates([a], model: model, now: now).isEmpty, model)
        }
    }

    func testAPanelReadingCannotLiftARefusalBeforeItsResetAndTheResetDoes() {
        var a = account([week(10)])
        let refused = fable(100, resets: 3600).refused()
        XCTAssertEqual(refused.refusedUntil, now.addingTimeInterval(3600))
        a.absorb([refused], at: now)
        // the panel later reads 98%: still used up
        let later = now.addingTimeInterval(600)
        a.absorb([fable(98, at: later, resets: 3600)], replacingSnapshot: true, at: later)
        var held = a.windows.first { $0.id == "seven_day_overage_included" }!
        XCTAssertEqual(held.usedPercent, 100)
        XCTAssertTrue(held.isExhausted(at: later))
        XCTAssertTrue(PoolRouting.candidates([a], model: "claude-fable-5", now: later).isEmpty)
        // a snapshot without the window keeps it as well
        a.absorb([week(10)], replacingSnapshot: true, at: later)
        XCTAssertNotNil(a.windows.first { $0.id == "seven_day_overage_included" })
        // after the reset the account serves Fable again, and a new-cycle reading replaces the refusal
        let after = now.addingTimeInterval(3601)
        XCTAssertFalse(a.windows.first { $0.id == "seven_day_overage_included" }!.isExhausted(at: after))
        XCTAssertFalse(PoolRouting.candidates([a], model: "claude-fable-5", now: after).isEmpty)
        let fresh = QuotaWindow(id: "seven_day_overage_included", usedPercent: 2, observedAt: after, resetsAt: after.addingTimeInterval(7 * 86400))
        a.absorb([fresh], at: after)
        held = a.windows.first { $0.id == "seven_day_overage_included" }!
        XCTAssertEqual(held.usedPercent, 2)
        // a reading of a later cycle also lifts a refusal still standing
        var b = account([week(10)])
        b.absorb([fable(100, resets: 3600).refused()], at: now)
        b.absorb([QuotaWindow(id: "seven_day_overage_included", usedPercent: 0, observedAt: later, resetsAt: now.addingTimeInterval(7 * 86400))], at: later)
        XCTAssertEqual(b.windows.first { $0.id == "seven_day_overage_included" }?.usedPercent, 0)
    }

    func testARefusalWithoutAResetIsShortenedByTheResetALaterReadingStates() throws {
        // a new session's first request met the credits box: no reset known, a cycle guessed
        let bare = QuotaWindow(id: "seven_day_overage_included", usedPercent: 100, observedAt: now, scope: .models(["fable"])).refused()
        XCTAssertEqual(bare.refusedUntil, now.addingTimeInterval(7 * 86400))
        XCTAssertEqual(bare.refusalStatedReset, false)
        var a = account([week(10)])
        a.absorb([bare], at: now)
        let later = now.addingTimeInterval(600)
        a.absorb([fable(40, at: later, resets: 2 * 86400)], at: later)
        var held = try XCTUnwrap(a.windows.first { $0.id == "seven_day_overage_included" })
        XCTAssertEqual(held.refusedUntil, now.addingTimeInterval(2 * 86400), "The window's own reset ends the guess")
        XCTAssertEqual(held.usedPercent, 100)
        XCTAssertTrue(held.isExhausted(at: later))
        XCTAssertTrue(PoolRouting.candidates([a], model: "claude-fable-5", now: later).isEmpty)
        XCTAssertFalse(PoolRouting.candidates([a], model: "claude-fable-5", now: now.addingTimeInterval(2 * 86400 + 5)).isEmpty)
        // a reading whose reset already passed lifts it
        var b = account([week(10)])
        b.absorb([bare], at: now)
        let past = now.addingTimeInterval(86400)
        b.absorb([QuotaWindow(id: "seven_day_overage_included", usedPercent: 3, observedAt: past, resetsAt: now.addingTimeInterval(3600))], at: past)
        held = try XCTUnwrap(b.windows.first { $0.id == "seven_day_overage_included" })
        XCTAssertEqual(held.usedPercent, 3)
        XCTAssertFalse(held.isExhausted(at: past))
        // a refusal that stated its reset keeps the old behaviour
        var c = account([week(10)])
        c.absorb([fable(100, resets: 3 * 86400).refused()], at: now)
        c.absorb([fable(40, at: later, resets: 2 * 86400)], at: later)
        XCTAssertEqual(c.windows.first { $0.id == "seven_day_overage_included" }?.refusedUntil, now.addingTimeInterval(3 * 86400))
        // saved windows round-trip, and an older one without the field reads as stated
        XCTAssertEqual(try JSONDecoder().decode(QuotaWindow.self, from: try JSONEncoder().encode(bare)), bare)
        let old = try JSONDecoder().decode(QuotaWindow.self, from: Data(#"{"id":"seven_day_overage_included","usedPercent":100,"observedAt":0,"refusedUntil":1000}"#.utf8))
        XCTAssertNil(old.refusalStatedReset)
        XCTAssertEqual(old.refusedUntil, Date(timeIntervalSinceReferenceDate: 1000))
    }

    func testALegacyWholeAccountCooldownFromAModelRefusalIsLiftedToThatModel() {
        let reset = now.addingTimeInterval(3 * 86400)
        let fableWindow = QuotaWindow(id: "seven_day_overage_included", usedPercent: 100, observedAt: now, resetsAt: reset)
        var library = PoolLibrary(accounts: [account([week(10), fableWindow])])
        library.accounts[0].state = .limited
        library.accounts[0].cooldownUntil = reset.addingTimeInterval(20)
        XCTAssertTrue(library.liftModelCooldowns(at: now))
        let lifted = library.accounts[0]
        XCTAssertNil(lifted.cooldownUntil)
        XCTAssertEqual(lifted.effectiveState(at: now), .ready)
        XCTAssertEqual(lifted.windows.first { $0.id == "seven_day_overage_included" }?.refusedUntil, reset.addingTimeInterval(20))
        XCTAssertTrue(PoolRouting.candidates([lifted], model: "claude-fable-5", now: now).isEmpty)
        XCTAssertFalse(PoolRouting.candidates([lifted], model: "claude-sonnet-5", now: now).isEmpty)
        // a cooldown that belongs to a global window stays
        var global = PoolLibrary(accounts: [account([QuotaWindow(id: "seven_day", usedPercent: 100, observedAt: now, resetsAt: reset), fableWindow])])
        global.accounts[0].state = .limited; global.accounts[0].cooldownUntil = reset
        XCTAssertFalse(global.liftModelCooldowns(at: now))
        XCTAssertEqual(global.accounts[0].cooldownUntil, reset)
        // so does one that matches no model window
        var other = PoolLibrary(accounts: [account([week(10), fableWindow])])
        other.accounts[0].cooldownUntil = now.addingTimeInterval(3600)
        XCTAssertFalse(other.liftModelCooldowns(at: now))
    }

    func testAGlobalRefusalKeepsItsCooldownBehaviour() {
        let window = QuotaWindow(id: "five_hour", usedPercent: 100, observedAt: now, resetsAt: now.addingTimeInterval(3600))
        XCTAssertEqual(window.refused(), window)
        XCTAssertNil(window.refused().refusedUntil)
    }

    func testARefilledSessionClearsADetachedCooldownButDoesNotRefillTheWeek() {
        let oldSession = QuotaWindow(id: "five_hour", usedPercent: 0, observedAt: now.addingTimeInterval(-60))
        var a = account([oldSession, week(100)])
        a.state = .limited
        a.cooldownUntil = now.addingTimeInterval(3600)
        let session = QuotaWindow(id: "five_hour", usedPercent: 0, observedAt: now)

        a.absorbUsagePanel([session, week(100)], at: now)

        XCTAssertNil(a.cooldownUntil)
        XCTAssertEqual(a.standing(at: now), .weekUsed)
        XCTAssertTrue(PoolRouting.candidates([a], model: "claude-sonnet-5", now: now).isEmpty)
    }

    func testAFableResetCanRestoreWeeklyHeadroomWithoutChangingTheResetDate() {
        let previous = now.addingTimeInterval(-600)
        let reset = now.addingTimeInterval(4 * 86400)
        let spentWeek = QuotaWindow(id: "seven_day", usedPercent: 100, observedAt: previous, resetsAt: reset)
        var a = account([spentWeek, fable(100, at: previous).refused()])
        a.state = .limited
        a.cooldownUntil = reset
        let restoredWeek = week(60)

        a.absorbUsagePanel([restoredWeek, fable(0)], at: now)

        XCTAssertEqual(a.windows.first { $0.id == "seven_day" }, restoredWeek)
        XCTAssertNil(a.cooldownUntil)
        XCTAssertEqual(a.standing(at: now), .usable)
        XCTAssertEqual(PoolRouting.candidates([a], model: "claude-fable-5", now: now).map(\.id), [a.id])
    }

    func testAnOlderOrPartialReadingWithoutResetEvidenceKeepsTheWeeklyRefusal() {
        let reset = now.addingTimeInterval(4 * 86400)
        var a = account([week(100)])
        a.state = .limited
        a.cooldownUntil = reset
        let stale = QuotaWindow(id: "seven_day", usedPercent: 0, observedAt: now.addingTimeInterval(-60), resetsAt: reset)
        a.absorbUsagePanel([stale], at: now)
        XCTAssertEqual(a.windows.first?.usedPercent, 100)
        XCTAssertEqual(a.cooldownUntil, reset)
        let later = now.addingTimeInterval(60)
        let partial = QuotaWindow(id: "seven_day", usedPercent: 98, observedAt: later, resetsAt: reset)
        a.absorbUsagePanel([partial], at: later)
        XCTAssertEqual(a.cooldownUntil, reset)
        XCTAssertEqual(a.standing(at: later), .weekUsed)
    }

    func testAFullUsagePanelDoesNotClearARefusalAtAnUnplacedLimit() {
        let limit = QuotaWindow(id: "overage", usedPercent: 100, observedAt: now, resetsAt: now.addingTimeInterval(3600)).refused()
        var a = account([limit])
        a.state = .limited
        a.cooldownUntil = limit.resetsAt
        a.absorbUsagePanel([.init(id: "five_hour", usedPercent: 0, observedAt: now), week(0)], at: now)
        XCTAssertEqual(a.cooldownUntil, limit.resetsAt)
        XCTAssertEqual(a.windows.first { $0.id == limit.id }, limit)
    }

    func testOtherWindowsNeverHoldAnythingBack() {
        let windows = [QuotaWindow(id: "five_hour", usedPercent: 5, observedAt: now, resetsAt: now.addingTimeInterval(3600)), week(10),
                       QuotaWindow(id: "seven_day_cowork", usedPercent: 100, observedAt: now, resetsAt: now.addingTimeInterval(86400)),
                       QuotaWindow(id: "overage", usedPercent: 100, observedAt: now, resetsAt: now.addingTimeInterval(86400))]
        var a = account(windows)
        a.state = .limited
        XCTAssertEqual(a.effectiveState(at: now), .ready)
        XCTAssertFalse(a.isWeekUsedUp(at: now))
        XCTAssertEqual(a.standing(at: now), .usable)
        for model in ["claude-opus-5", "claude-fable-5", PoolRouting.anyModel] {
            XCTAssertFalse(PoolRouting.candidates([a], model: model, now: now).isEmpty, model)
        }
        let summary = QuotaPoolSummary.evaluate([a], model: PoolRouting.anyModel, now: now)
        XCTAssertEqual(summary.usableAccounts, 1)
        XCTAssertEqual(summary.groups.first { $0.windowID == "seven_day_cowork" }?.scope, .other)
    }
}
