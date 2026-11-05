import SwiftUI
import XCTest
import ViewInspector
@testable import ClaudePool

@MainActor
final class NumericSettingTests: XCTestCase {
    func testInvalidPercentDraftsNeverSubmitAndShowRange() throws {
        let model = PoolAppModel.demoModel()
        var writes = 0
        model.onSettingAction = { _ in writes += 1 }
        let row = try RoutingPage(model: model).inspect().find(NumericSettingRow.self).actualView()
        for invalid in ["", "abc", "-1", "26", "12.5", "NaN"] {
            try row.inspect().find(ViewType.TextField.self).setInput(invalid)
            try row.inspect().find(ViewType.TextField.self).callOnSubmit()
            XCTAssertEqual(writes, 0)
            XCTAssertEqual(model.preferences.routingPolicy.reservePercent, 10)
            XCTAssertNoThrow(try row.inspect().find(text: model.t("Whole number: {0}–{1}", "0", "25")))
        }
    }

    func testEscapeCancelsDraftToLatestExternalSavedValue() throws {
        let model = PoolAppModel.demoModel()
        var writes = 0
        model.onSettingAction = { _ in writes += 1 }
        let row = try RoutingPage(model: model).inspect().find(NumericSettingRow.self).actualView()
        try row.inspect().find(ViewType.TextField.self).setInput("23")
        model.preferences.routingPolicy.reservePercent = 18
        try row.inspect().find(ViewType.VStack.self).callOnChange(oldValue: 10.0, newValue: 18.0)
        XCTAssertEqual(try row.inspect().find(ViewType.TextField.self).input(), "23")
        try row.inspect().find(ViewType.VStack.self).callOnExitCommand()
        XCTAssertEqual(try row.inspect().find(ViewType.TextField.self).input(), "18")
        XCTAssertTrue(try row.inspect().find(button: "Save").isDisabled())
        XCTAssertEqual(writes, 0)
    }

    func testCleanFieldTracksExternalSavedChanges() throws {
        let model = PoolAppModel.demoModel()
        let row = try RoutingPage(model: model).inspect().find(NumericSettingRow.self).actualView()
        model.preferences.routingPolicy.reservePercent = 20
        try row.inspect().find(ViewType.VStack.self).callOnChange(oldValue: 10.0, newValue: 20.0)
        XCTAssertEqual(try row.inspect().find(ViewType.TextField.self).input(), "20")
        XCTAssertTrue(try row.inspect().find(button: "Save").isDisabled())
    }

    func testFailedAsyncSaveRollsBackToModelWithoutLosingFailureNotice() async throws {
        let model = PoolAppModel.demoModel()
        let gate = AsyncStream<Void>.makeStream()
        var writes = 0
        model.onSettingAction = { _ in
            writes += 1
            model.isWorking = true
            for await _ in gate.stream { break }
            model.notice = "Synthetic save failure"
            model.isWorking = false
        }
        defer { gate.continuation.finish() }
        let row = try RoutingPage(model: model).inspect().find(NumericSettingRow.self).actualView()
        try row.inspect().find(ViewType.TextField.self).setInput("17")
        try row.inspect().find(button: "Save").tap()
        XCTAssertTrue(try row.inspect().find(ViewType.TextField.self).isDisabled())
        XCTAssertThrowsError(try row.inspect().find(button: "Save").tap())
        await wait { writes == 1 }
        gate.continuation.yield(())
        await wait { (try? row.inspect().find(ViewType.TextField.self).input()) == "10" }
        XCTAssertEqual(model.preferences.routingPolicy.reservePercent, 10)
        XCTAssertEqual(model.notice, "Synthetic save failure")
        XCTAssertFalse(try row.inspect().find(ViewType.TextField.self).isDisabled())
        XCTAssertTrue(try row.inspect().find(button: "Save").isDisabled())
    }

    func testFastFailureDoesNotDependOnBusyTransition() async throws {
        let model = PoolAppModel.demoModel()
        var writes = 0
        model.onSettingAction = { _ in writes += 1; model.notice = "Synthetic save failure" }
        let row = try RoutingPage(model: model).inspect().find(NumericSettingRow.self).actualView()
        try row.inspect().find(ViewType.TextField.self).setInput("16")
        try row.inspect().find(ViewType.TextField.self).callOnSubmit()
        await wait { writes == 1 && (try? row.inspect().find(ViewType.TextField.self).input()) == "10" }
        XCTAssertFalse(model.isWorking)
        XCTAssertEqual(model.preferences.routingPolicy.reservePercent, 10)
    }

    func testBusyDisablesInputAndSubmissionWhileKeepingDraft() throws {
        let model = PoolAppModel.demoModel()
        let row = try RoutingPage(model: model).inspect().find(NumericSettingRow.self).actualView()
        try row.inspect().find(ViewType.TextField.self).setInput("19")
        model.isWorking = true
        XCTAssertTrue(try row.inspect().find(ViewType.TextField.self).isDisabled())
        XCTAssertThrowsError(try row.inspect().find(button: "Save").tap())
        try row.inspect().find(ViewType.TextField.self).callOnSubmit()
        XCTAssertEqual(model.preferences.routingPolicy.reservePercent, 10)
        XCTAssertEqual(try row.inspect().find(ViewType.TextField.self).input(), "19")
    }

    private func wait(_ predicate: () -> Bool) async {
        for _ in 0..<100 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(predicate(), "Numeric setting did not finish")
    }
}
