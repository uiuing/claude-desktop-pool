import SwiftUI
import ViewInspector
import XCTest
@testable import ClaudePool

@MainActor
final class TerminalSheetTests: XCTestCase {
    func testLinkActionsReceiveTheCompleteSyntheticAuthorizationURL() throws {
        let model = PoolAppModel.demoModel(), id = UUID()
        let text = "https://auth.synthetic.invalid/oauth/authorize?client_id=synthetic-client&state=" + String(repeating: "synthetic-state_", count: 100)
        let url = try XCTUnwrap(URL(string: text))
        model.terminal = .init(id: id, title: "Synthetic sign-in", output: "", isPendingSignIn: true, links: [url])
        var opened: [URL] = [], copied: [URL] = []
        let view = TerminalSheet(model: model, terminalID: id, openLink: { opened.append($0) }, copyLink: { copied.append($0); return true })
        try view.inspect().find(ViewType.Button.self, where: { try $0.accessibilityIdentifier() == "terminal.link.open.0" }).tap()
        try view.inspect().find(ViewType.Button.self, where: { try $0.accessibilityIdentifier() == "terminal.link.copy.0" }).tap()
        XCTAssertEqual(opened.map(\.absoluteString), [text])
        XCTAssertEqual(copied.map(\.absoluteString), [text])
        XCTAssertNoThrow(try view.inspect().find(text: "auth.synthetic.invalid/oauth/authorize"))
        XCTAssertNoThrow(try view.inspect().find(text: "Finish in the browser, or paste the code it shows. Closing cancels this sign-in."))
    }

    func testCloseDelegatesToControllerAndEscapeRemainsANativeKey() throws {
        let model = PoolAppModel.demoModel(), id = UUID()
        model.terminal = .init(id: id, title: "Synthetic sign-in", output: "", isPendingSignIn: true)
        var actions: [UIAction] = []
        model.onAction = { actions.append($0) }
        let view = TerminalSheet(model: model, terminalID: id)
        try view.inspect().find(button: "Escape").tap()
        XCTAssertEqual(actions.last, .sendTerminalKey("\u{1b}"))
        XCTAssertNotNil(model.terminal)
        try view.inspect().find(button: "Close").tap()
        XCTAssertEqual(actions.last, .closeTerminal(id))
        XCTAssertNotNil(model.terminal, "Only the controller decides whether closing cancels sign-in")
    }

    func testEndedSignInExplainsTheFailureAndRetriesThroughTheController() throws {
        let model = PoolAppModel.demoModel(), id = UUID()
        var terminal = PoolTerminal(id: id, title: "Sign-in not completed", output: "Login failed", isRunning: false, inputEnabled: false)
        terminal.failure = "Synthetic failure reason"; terminal.retry = .addAccount
        model.terminal = terminal
        var actions: [UIAction] = []
        model.onAction = { actions.append($0) }
        let view = TerminalSheet(model: model, terminalID: id)
        XCTAssertNoThrow(try view.inspect().find(text: "Synthetic failure reason"))
        XCTAssertThrowsError(try view.inspect().find(text: "This session has ended."))
        XCTAssertThrowsError(try view.inspect().find(button: "Send"), "Ended sign-in keeps no dead reply controls")
        try view.inspect().find(ViewType.Button.self, where: { try $0.accessibilityIdentifier() == "terminal.retry" }).tap()
        XCTAssertEqual(actions, [.addAccount])
    }
}
