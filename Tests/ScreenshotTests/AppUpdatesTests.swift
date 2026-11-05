import XCTest
import PoolCore
import PoolRuntime
@testable import ClaudePool

@MainActor
final class AppUpdatesTests: XCTestCase {
    private func storage() -> UserDefaults {
        let name = "ClaudePoolUpdateTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
    func testDailyAutomaticChecksAndExplicitChecksRespectTheSwitch() async throws {
        let defaults = storage()
        var now = Date(timeIntervalSince1970: 1_800_000_000), reads = 0
        let updates = AppUpdates(demo: false, currentVersion: "0.1.5", defaults: defaults, now: { now }, fetch: {
            reads += 1; return ReleaseVersion("v0.1.6")!
        }, announce: { _, _ in })
        await updates.check(manual: false)
        XCTAssertEqual(reads, 1); XCTAssertTrue(updates.hasUpdate)
        XCTAssertEqual(updates.status, .available)
        now.addTimeInterval(3600)
        await updates.check(manual: false)
        XCTAssertEqual(reads, 1)
        now.addTimeInterval(86400)
        updates.setAutomatic(false)
        await updates.check(manual: false)
        XCTAssertEqual(reads, 1)
        await updates.check(manual: true)
        XCTAssertEqual(reads, 2)
        let restarted = AppUpdates(demo: false, currentVersion: "0.1.5", defaults: defaults, now: { now }, fetch: {
            XCTFail("A restart must preserve the daily limit"); return ReleaseVersion("0.1.6")!
        }, announce: { _, _ in })
        XCTAssertFalse(restarted.automatic); XCTAssertTrue(restarted.hasUpdate)
        restarted.setAutomatic(true)
        await restarted.check(manual: false)
    }
    func testEqualOlderAndUnknownVersionsAreNotReportedAsNew() async {
        for (current, latest, expected) in [("0.1.5", "0.1.5", AppUpdates.Status.current),
                                            ("0.2.0", "0.1.5", .current), ("unknown", "0.1.5", .unknownVersion)] {
            let updates = AppUpdates(demo: false, currentVersion: current, defaults: storage(), fetch: { ReleaseVersion(latest)! }, announce: { _, _ in })
            await updates.check(manual: true)
            XCTAssertEqual(updates.status, expected)
            XCTAssertFalse(updates.hasUpdate)
        }
    }
    func testFailureIsNotUpToDateAndServerCooldownSurvivesRestart() async {
        let defaults = storage()
        var now = Date(timeIntervalSince1970: 1_800_000_000), reads = 0
        let updates = AppUpdates(demo: false, currentVersion: "0.1.5", defaults: defaults, now: { now }, fetch: {
            reads += 1; throw ReleaseCheckError(retryAfter: now.addingTimeInterval(7200))
        }, announce: { _, _ in })
        await updates.check(manual: true)
        XCTAssertEqual(updates.status, .failed)
        now.addTimeInterval(3600)
        let restarted = AppUpdates(demo: false, currentVersion: "0.1.5", defaults: defaults, now: { now }, fetch: {
            reads += 1; return ReleaseVersion("0.1.5")!
        }, announce: { _, _ in })
        await restarted.check(manual: true)
        XCTAssertEqual(restarted.status, .cooldown); XCTAssertEqual(reads, 1)
        now.addTimeInterval(4000)
        await restarted.check(manual: true)
        XCTAssertEqual(restarted.status, .current); XCTAssertEqual(reads, 2)
    }
    func testConcurrentChecksShareOneRequest() async throws {
        var continuation: CheckedContinuation<ReleaseVersion, Error>?, reads = 0
        let updates = AppUpdates(demo: false, currentVersion: "0.1.5", defaults: storage(), fetch: {
            reads += 1
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }, announce: { _, _ in })
        let first = Task { await updates.check(manual: true) }
        for _ in 0..<20 { if continuation != nil { break }; await Task.yield() }
        guard let pending = continuation else { first.cancel(); XCTFail("Request did not start"); return }
        await updates.check(manual: true)
        await updates.check(manual: false)
        XCTAssertEqual(reads, 1); XCTAssertTrue(updates.isChecking)
        pending.resume(returning: ReleaseVersion("0.1.10")!)
        await first.value
        XCTAssertTrue(updates.hasUpdate)
    }
    func testDemoNeverFetchesOrStartsAutomaticChecks() async {
        let updates = AppUpdates(demo: true, currentVersion: "0.1.5", fetch: {
            XCTFail("Demo must not contact GitHub"); return ReleaseVersion("0.1.6")!
        })
        updates.start()
        await updates.check(manual: true)
        await updates.check(manual: false)
        XCTAssertEqual(updates.status, .idle)
    }
    func testRapidManualChecksDoNotSendRepeatedRequests() async {
        var reads = 0
        let updates = AppUpdates(demo: false, currentVersion: "0.1.5", defaults: storage(), fetch: {
            reads += 1; return ReleaseVersion("0.1.5")!
        }, announce: { _, _ in })
        await updates.check(manual: true)
        await updates.check(manual: true)
        XCTAssertEqual(reads, 1); XCTAssertEqual(updates.status, .current)
    }
    func testEachNewerVersionIsAnnouncedOnceInPoolsLanguage() async {
        let defaults = storage()
        var now = Date(timeIntervalSince1970: 1_800_000_000), latest = "0.1.1"
        var announced: [String] = []
        let updates = AppUpdates(demo: false, currentVersion: "0.1.0", defaults: defaults, now: { now },
                                 fetch: { ReleaseVersion(latest)! }, announce: { announced.append("\($0.description) \($1)") })
        updates.language = { "zh-Hans" }
        await updates.check(manual: false)
        now.addTimeInterval(86400); await updates.check(manual: false)
        XCTAssertEqual(announced, ["0.1.1 zh-Hans"])
        latest = "0.2.0"; now.addTimeInterval(86400); await updates.check(manual: false)
        XCTAssertEqual(announced, ["0.1.1 zh-Hans", "0.2.0 zh-Hans"])
        let restarted = AppUpdates(demo: false, currentVersion: "0.1.0", defaults: defaults, now: { now.addingTimeInterval(86400) },
                                   fetch: { ReleaseVersion("0.2.0")! }, announce: { _, _ in XCTFail("Announced twice") })
        await restarted.check(manual: false)
    }
    func testAnUnpackagedCopyNeverInstallsItself() {
        let updates = AppUpdates(demo: false, currentVersion: "0.1.0", defaults: storage(), announce: { _, _ in })
        XCTAssertFalse(updates.canInstall)
        XCTAssertFalse(AppUpdates(demo: true, currentVersion: "0.1.0").canInstall)
    }
    func testStatusTextFollowsPoolsLanguage() {
        let updates = AppUpdates(demo: false, currentVersion: "0.1.0", defaults: storage(), announce: { _, _ in })
        let model = PoolAppModel(preferences: .init(language: "en"))
        XCTAssertEqual(updates.statusText(model.t), "Check for a newer version on GitHub.")
        model.preferences.language = "zh-Hans"
        XCTAssertEqual(updates.statusText(model.t), "在 GitHub 上检查新版本。")
    }
}

@MainActor
final class EmailMaskPresentationTests: XCTestCase {
    func testTheSwitchMasksEveryAccountName() {
        let model = PoolAppModel.demoModel()
        let account = model.snapshot.accounts[0]
        let email = account.email!
        XCTAssertEqual(model.accountName(account.id), email)
        model.perform(.maskEmail(true))
        XCTAssertEqual(model.accountName(account.id), EmailMask.masked(email))
        XCTAssertFalse(model.accountName(account.id).hasPrefix(String(email.split(separator: "@")[0])))
        XCTAssertTrue(model.accountName(account.id).hasSuffix("@" + email.split(separator: "@")[1]))
        model.perform(.maskEmail(false))
        XCTAssertEqual(model.accountName(account.id), email)
    }
}
