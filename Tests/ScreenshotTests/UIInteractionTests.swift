import SwiftUI
import XCTest
import ViewInspector
import PoolCore
@testable import ClaudePool

@MainActor
final class UIInteractionTests: XCTestCase {
    func testNavigationAndLiveSessionButtonUseActualViewCallbacks() throws {
        let model = PoolAppModel.demoModel()
        var actions: [UIAction] = []
        model.onAction = { actions.append($0) }
        let view = MainWindow(model: model)
        for page in [PoolPage.routing, .accounts, .settings, .pool] {
            try view.inspect().find(ViewType.Button.self, where: { try $0.accessibilityIdentifier() == "navigation.\(page.rawValue)" }).tap()
            XCTAssertEqual(model.page, page)
        }
        model.page = .routing
        // Claude sessions are the pool's own: the route offers nothing to open or switch by hand.
        XCTAssertThrowsError(try view.inspect().find(ViewType.Button.self, where: { try $0.accessibilityIdentifier() == "routing.openSession" }))
        XCTAssertThrowsError(try view.inspect().find(ViewType.Picker.self, where: { try $0.accessibilityIdentifier() == "routing.conversation" }))
        model.page = .accounts
        try view.inspect().find(ViewType.Button.self, where: { try $0.accessibilityIdentifier() == "accounts.add" }).tap()
        XCTAssertEqual(actions.last, .addAccount)
    }

    func testPendingLoginHasPrimarySignInActionAndNoQuotaAction() throws {
        let model = PoolAppModel.demoModel()
        let account = PoolAccount(state: .disabled)
        model.snapshot.accounts = [account]
        var actions: [UIAction] = []
        model.onAction = { actions.append($0) }
        let view = AccountsPage(model: model)
        XCTAssertFalse(model.hasSignedInAccount)
        XCTAssertNoThrow(try view.inspect().find(text: "Sign in needed"))
        XCTAssertThrowsError(try view.inspect().find(text: "Disabled"))
        try view.inspect().find(button: "Sign in").tap()
        XCTAssertEqual(actions.last, .signIn(account.id))
        XCTAssertTrue(try view.inspect().findAll(ViewType.Button.self, where: { try $0.accessibilityLabel().string() == "Refresh quota" }).isEmpty)
    }

    func testSettingsTogglesAndLanguageUseBindings() throws {
        let model = PoolAppModel.demoModel()
        let view = PoolSettingsPage(model: model)
        // Background reads are automatic; there is no switch for them.
        XCTAssertThrowsError(try view.inspect().find(ViewType.Toggle.self, where: { try $0.accessibilityIdentifier() == "settings.refreshInactive" }))
        XCTAssertEqual(model.preferences.quotaRefresh.burstInterval, 10)
        XCTAssertThrowsError(try view.inspect().find(ViewType.Toggle.self, where: { try $0.accessibilityIdentifier() == "settings.confirmReset" }))
        XCTAssertTrue(model.preferences.quotaRefresh.confirmAfterReset)
        try view.inspect().find(ViewType.Picker.self, where: { try $0.accessibilityIdentifier() == "settings.language" }).select(value: "zh-Hans")
        XCTAssertEqual(model.preferences.language, "zh-Hans")
    }

    func testSettingsExposeNoInternalRefreshTiming() throws {
        let model = PoolAppModel.demoModel()
        let view = PoolSettingsPage(model: model)
        XCTAssertTrue(try view.inspect().findAll(NumericSettingRow.self).isEmpty)
        XCTAssertThrowsError(try view.inspect().find(ViewType.DisclosureGroup.self))
    }

    func testRoutingPickerReserveAndAccountOrderCallbacks() async throws {
        let model = PoolAppModel.demoModel()
        let original = model.orderedRoutingAccounts.map(\.id)
        let view = RoutingPage(model: model)
        try view.inspect().find(ViewType.Picker.self, where: { try $0.accessibilityIdentifier() == "routing.strategy" }).select(value: RoutingStrategy.ordered)
        XCTAssertEqual(model.preferences.routingPolicy.strategy, .ordered)
        let row = try view.inspect().find(NumericSettingRow.self).actualView()
        try row.inspect().find(ViewType.TextField.self).setInput("11")
        XCTAssertEqual(model.preferences.routingPolicy.reservePercent, 10)
        try row.inspect().find(ViewType.TextField.self).callOnSubmit()
        await waitForSetting { model.preferences.routingPolicy.reservePercent == 11 }
        try view.inspect().find(ViewType.Button.self, where: { try $0.accessibilityIdentifier() == "routing.down.0" }).tap()
        XCTAssertEqual(model.orderedRoutingAccounts.map(\.id), [original[1], original[0], original[2], original[3]])
    }

    func testMenuShowsPlanQuotaNextAccountAndNoPause() throws {
        let model = PoolAppModel.demoModel()
        let menu = try MenuPanel(model: model).inspect()
        XCTAssertThrowsError(try menu.find(button: "Pause pool"))
        XCTAssertNoThrow(try menu.find(text: model.newConversationText))
        XCTAssertNoThrow(try menu.find(ViewType.Button.self, where: { try $0.accessibilityIdentifier() == "menu.open" }))
        XCTAssertNoThrow(try menu.find(text: model.limitName("five_hour")))
        try menu.find(ViewType.Picker.self, where: { try $0.accessibilityIdentifier() == "menu.plan" }).select(value: "plan:Ultra")
        XCTAssertEqual(model.preferences.menuBarPlan, "plan:Ultra")
    }

    func testRuntimeRecoveryAndSetupControlsDispatch() throws {
        let model = PoolAppModel.demoModel(setup: true)
        var actions: [UIAction] = []
        model.onAction = { actions.append($0) }
        try SetupCard(model: model).inspect().find(button: "Install Claude Code").tap()
        XCTAssertEqual(actions.last, .installRuntime)
        XCTAssertThrowsError(try SetupCard(model: model).inspect().find(button: "Add account").tap())
        model.snapshot.executableReady = true
        model.runtime = .init(phase: .ready, installedVersion: "2.1.301", previousVersion: "2.1.300")
        // Claude Code's controls are on the Services tab.
        XCTAssertThrowsError(try PoolSettingsPage(model: model).inspect().find(button: "Install Claude Code"))
        model.settingsTab = .services
        XCTAssertThrowsError(try PoolSettingsPage(model: model).inspect().find(button: "Use previous version"), "updates are automatic; going back is offered only after a failure")
        model.runtime.phase = .failed
        try PoolSettingsPage(model: model).inspect().find(button: "Use previous version").tap()
        XCTAssertEqual(actions.last, .rollbackRuntime)
        try PrivacyPreparationRow(model: model).inspect().find(button: "Prepare redaction").tap()
        XCTAssertEqual(actions.last, .installPrivacyModel)
    }

    func testPrivacyPreviewSubmissionAndDismissalCallbacks() throws {
        let model = PoolAppModel.demoModel()
        var actions: [UIAction] = []
        model.onAction = { actions.append($0) }
        let text = "Contact Taylor at mi•••ella@example.com."
        let view = PrivacyDetailsSheet(model: model, initialText: text)
        XCTAssertEqual(try view.inspect().find(PoolTextEditor.self).actualView().text, text)
        try view.inspect().find(button: "Preview locally").tap()
        XCTAssertEqual(actions.last, .previewPrivacy(text))
        try view.inspect().find(ViewType.VStack.self).callOnDisappear()
        XCTAssertEqual(actions.last, .clearPrivacyPreview)
    }

    func testIdleTerminalDisablesTextButKeepsNativeKeysAndExit() throws {
        let model = PoolAppModel.demoModel()
        let id = model.snapshot.sessions[0].id
        model.snapshot.sessions[0].state = .idle
        model.terminal = .init(id: id, title: "Synthetic session", output: "", textInputEnabled: false)
        var actions: [UIAction] = []
        model.onAction = { actions.append($0) }
        let view = TerminalSheet(model: model, terminalID: id)
        XCTAssertTrue(try view.inspect().find(ViewType.TextField.self).isDisabled())
        XCTAssertThrowsError(try view.inspect().find(button: "Send").tap())
        try view.inspect().find(button: "Enter").tap()
        XCTAssertEqual(actions.last, .sendTerminalKey("\r"))
        try view.inspect().find(button: "Exit session").tap()
        XCTAssertEqual(actions.last, .requestSessionExit(id))
        XCTAssertNoThrow(try view.inspect().find(text: "Continue this conversation in Claude Desktop."))
    }

    func testSerialControlsDisableWhileOperationRuns() throws {
        let model = PoolAppModel.demoModel()
        model.isWorking = true
        XCTAssertTrue(try PoolSettingsPage(model: model).inspect().find(ViewType.Picker.self, where: { try $0.accessibilityIdentifier() == "settings.language" }).isDisabled())
        XCTAssertThrowsError(try QuotaOverview(model: model).inspect().find(button: "Refresh all").tap())
        XCTAssertTrue(try AccountsPage(model: model).inspect().find(ViewType.Menu.self).isDisabled())
    }

    private func waitForSetting(_ predicate: () -> Bool) async {
        for _ in 0..<100 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(predicate(), "Setting did not finish saving")
    }
}
