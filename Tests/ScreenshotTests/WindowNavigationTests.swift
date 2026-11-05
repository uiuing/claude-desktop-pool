import AppKit
import SwiftUI
import XCTest
import ViewInspector
@testable import ClaudePool

@MainActor
final class WindowNavigationTests: XCTestCase {
    private let entries = ["Continue setup", "menu.open", "menu.settings"]

    func testMenuQuitDismissesPanelAndRequestsNormalTermination() throws {
        let model = PoolAppModel.demoModel()
        var events: [String] = []
        let panel = MenuPanel(model: model, navigator: PoolWindowNavigator(activate: {}),
                              dismissMenu: { events.append("dismiss") },
                              terminateApplication: { events.append("terminate") })
        try panel.inspect().find(ViewType.Button.self, where: {
            try $0.accessibilityIdentifier() == "menu.quit"
        }).tap()
        XCTAssertEqual(events, ["dismiss", "terminate"])
    }

    func testBundleDeclaresARegularDesktopApplication() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(info["LSUIElement"] as? Bool, false)
        XCTAssertNotEqual(info["LSBackgroundOnly"] as? Bool, true)
        XCTAssertFalse(PoolApplicationDelegate().applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared))
    }

    func testMenuRefreshReadsEveryAccountWithoutOpeningAWindow() throws {
        let model = PoolAppModel.demoModel()
        var actions: [UIAction] = [], opened = 0
        model.onAction = { actions.append($0) }
        let panel = MenuPanel(model: model, navigator: PoolWindowNavigator(activate: {}),
                              openMainWindow: { opened += 1 }, dismissMenu: {})
        try panel.inspect().find(ViewType.Button.self, where: { try $0.accessibilityIdentifier() == "menu.refresh" }).tap()
        XCTAssertEqual(actions, [.refreshQuota(nil)])
        XCTAssertEqual(opened, 0)
    }

    func testEveryMenuEntryDismissesActivatesAndCreatesTheMainWindow() async throws {
        for entry in entries {
            var events: [String] = []
            let navigator = PoolWindowNavigator(activate: { events.append("activate") })
            let model = PoolAppModel.demoModel(setup: entry == "Continue setup")
            model.page = .accounts
            var created: NavigationWindow?
            let panel = MenuPanel(model: model, navigator: navigator, openMainWindow: {
                events.append("open")
                let window = NavigationWindow(); created = window; navigator.register(window)
            }, dismissMenu: { events.append("dismiss") })
            try tap(entry, in: panel)
            await drainPresentation()
            XCTAssertEqual(events, ["dismiss", "activate", "open"], entry)
            XCTAssertEqual(model.page, entry == "menu.settings" ? .settings : .pool, entry)
            XCTAssertEqual(created?.frontCount, 1, entry)
            XCTAssertEqual(created?.identifier, PoolWindowNavigator.windowID, entry)
        }
    }

    func testEveryMenuEntryRestoresOnlyTheRegisteredMinimizedWindow() async throws {
        for entry in entries {
            var activations = 0, opens = 0
            let navigator = PoolWindowNavigator(activate: { activations += 1 })
            let main = NavigationWindow(), unrelatedPopup = NavigationWindow()
            main.minimized = true
            navigator.register(main)
            let panel = MenuPanel(model: .demoModel(setup: entry == "Continue setup"), navigator: navigator,
                                  openMainWindow: { opens += 1 }, dismissMenu: {})
            try tap(entry, in: panel)
            await drainPresentation()
            XCTAssertEqual(opens, 1, entry)
            XCTAssertEqual(activations, 1, entry)
            XCTAssertEqual(main.deminimizeCount, 1, entry)
            XCTAssertEqual(main.frontCount, 1, entry)
            XCTAssertEqual(unrelatedPopup.frontCount, 0, entry)
            XCTAssertNil(unrelatedPopup.identifier, entry)
        }
    }

    func testEveryMenuEntryRecreatesClosedWindowWithItsOwnSceneOpener() async throws {
        for entry in entries {
            let navigator = PoolWindowNavigator(activate: {})
            let old = NavigationWindow(); navigator.register(old); old.close()
            var staleOpens = 0, newOpens = 0
            navigator.configure { staleOpens += 1 }
            var replacement: NavigationWindow?
            let panel = MenuPanel(model: .demoModel(setup: entry == "Continue setup"), navigator: navigator, openMainWindow: {
                newOpens += 1
                let window = NavigationWindow(); replacement = window; navigator.register(window)
            }, dismissMenu: {})
            try tap(entry, in: panel)
            await drainPresentation()
            XCTAssertEqual(staleOpens, 0, entry)
            XCTAssertEqual(newOpens, 1, entry)
            XCTAssertEqual(old.frontCount, 0, entry)
            XCTAssertEqual(replacement?.frontCount, 1, entry)
        }
    }

    func testEveryMenuEntryCanReuseTheClosedSwiftUIWindow() async throws {
        for entry in entries {
            let navigator = PoolWindowNavigator(activate: {})
            let main = NavigationWindow(); navigator.register(main); main.close()
            var opens = 0
            let panel = MenuPanel(model: .demoModel(setup: entry == "Continue setup"), navigator: navigator, openMainWindow: {
                opens += 1
                main.shown = true
                navigator.register(main)
            }, dismissMenu: {})
            try tap(entry, in: panel)
            await drainPresentation()
            XCTAssertEqual(opens, 1, entry)
            XCTAssertEqual(main.frontCount, 1, entry)
        }
    }

    func testLateWindowRegistrationCompletesPendingPresentationOnce() async {
        var opens = 0, activations = 0
        let navigator = PoolWindowNavigator(activate: { activations += 1 })
        navigator.show(opener: { opens += 1 })
        await drainPresentation()
        let window = NavigationWindow()
        navigator.register(window)
        navigator.register(window)
        await drainPresentation()
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(activations, 1)
        XCTAssertEqual(window.frontCount, 1)
    }

    func testClosedWindowIsNotFrontedUntilTheSceneActuallyReopensIt() async {
        let navigator = PoolWindowNavigator(activate: {})
        let window = NavigationWindow(); navigator.register(window); window.close()
        navigator.show(opener: {})
        navigator.register(window)
        await drainPresentation()
        XCTAssertEqual(window.frontCount, 0)
        window.shown = true
        navigator.register(window)
        await drainPresentation()
        XCTAssertEqual(window.frontCount, 1)
    }

    func testClosingTheWindowLeavesTheDockAndOpeningItComesBack() async {
        var dock: [Bool] = [], events: [String] = []
        let navigator = PoolWindowNavigator(activate: { events.append("activate") },
                                            showInDock: { dock.append($0); events.append($0 ? "dock" : "undock") })
        let window = NavigationWindow(); window.shown = true
        navigator.register(window)
        XCTAssertEqual(dock, [], "An open window is already in the Dock")
        window.close()
        XCTAssertEqual(dock, [false], "Closed, Claude Pool stays in the menu bar only")
        navigator.register(window)
        XCTAssertEqual(dock, [false], "A SwiftUI update of the closed window does not bring it back")
        navigator.show(opener: { window.shown = true; navigator.register(window) })
        await drainPresentation()
        XCTAssertEqual(dock, [false, true])
        XCTAssertEqual(events, ["undock", "dock", "activate"], "Back in the Dock before coming forward")
        XCTAssertEqual(window.frontCount, 1)
        // Minimizing keeps it in the Dock; closing again leaves.
        window.minimized = true
        navigator.register(window)
        window.close()
        XCTAssertEqual(dock, [false, true, false])
    }

    func testWindowReaderRegistersIdentityWithoutActivatingOrShowing() async {
        var activations = 0
        let navigator = PoolWindowNavigator(activate: { activations += 1 })
        let window = NavigationWindow()
        let host = NSHostingView(rootView: PoolMainWindowReader(navigator: navigator))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(window.identifier, PoolWindowNavigator.windowID)
        XCTAssertEqual(activations, 0)
        XCTAssertEqual(window.frontCount, 0)
        navigator.show(opener: {})
        await drainPresentation()
        XCTAssertEqual(activations, 1)
        XCTAssertEqual(window.frontCount, 1)
    }

    func testMainWindowRegistrationDisablesImplicitHidingWithoutChangingFocus() {
        var activations = 0
        let navigator = PoolWindowNavigator(activate: { activations += 1 })
        for temporaryBehavior in [NSWindow.CollectionBehavior.transient, .stationary] {
            let window = NavigationWindow()
            window.hidesOnDeactivate = true; window.canHide = true
            let retained: NSWindow.CollectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
            window.collectionBehavior = retained.union(temporaryBehavior)
            navigator.register(window)
            navigator.register(window)
            XCTAssertFalse(window.hidesOnDeactivate)
            XCTAssertFalse(window.canHide)
            XCTAssertEqual(window.collectionBehavior, retained.union(.managed))
            XCTAssertEqual(window.level, .normal)
            XCTAssertEqual(window.frontCount, 0)
        }
        XCTAssertEqual(activations, 0)
    }

    func testTerminalSheetReaderKeepsPanelVisibleWithoutReplacingMainWindow() async {
        var activations = 0
        let navigator = PoolWindowNavigator(activate: { activations += 1 })
        let main = NavigationWindow(); navigator.register(main)
        let sheet = NavigationPanel(), unrelatedMenu = NavigationPanel()
        let sheetBehavior = sheet.collectionBehavior, sheetLevel = sheet.level
        let menuBehavior = unrelatedMenu.collectionBehavior
        let menuHidesOnDeactivate = unrelatedMenu.hidesOnDeactivate, menuCanHide = unrelatedMenu.canHide
        let host = NSHostingView(rootView: PoolSheetWindowReader())
        sheet.contentView = host
        host.layoutSubtreeIfNeeded()

        XCTAssertFalse(sheet.hidesOnDeactivate)
        XCTAssertFalse(sheet.canHide)
        XCTAssertEqual(sheet.collectionBehavior, sheetBehavior)
        XCTAssertEqual(sheet.level, sheetLevel)
        XCTAssertNil(sheet.identifier)
        XCTAssertEqual(unrelatedMenu.hidesOnDeactivate, menuHidesOnDeactivate)
        XCTAssertEqual(unrelatedMenu.canHide, menuCanHide)
        XCTAssertEqual(unrelatedMenu.collectionBehavior, menuBehavior)
        XCTAssertEqual(activations, 0)
        XCTAssertEqual(main.frontCount, 0)
        XCTAssertEqual(sheet.frontCount, 0)

        navigator.show(opener: {})
        await drainPresentation()
        XCTAssertEqual(activations, 1)
        XCTAssertEqual(main.frontCount, 1)
        XCTAssertEqual(sheet.frontCount, 0)
        XCTAssertEqual(unrelatedMenu.frontCount, 0)
    }

    func testServicePresentationUsesTheSameStoredSceneOpener() async {
        let navigator = PoolWindowNavigator(activate: {})
        let main = NavigationWindow(); navigator.register(main); main.close()
        var opens = 0
        navigator.configure { opens += 1; main.shown = true; navigator.register(main) }
        var dependencies = AppServiceDependencies()
        dependencies.showWindow = { navigator.show() }
        let model = PoolAppModel.demoModel(); model.page = .accounts
        let services = AppServices(model: model, dependencies: dependencies)
        services.showWindow()
        await drainPresentation()
        XCTAssertEqual(opens, 1)
        XCTAssertEqual(main.frontCount, 1)
        XCTAssertEqual(model.page, .accounts)
    }

    private func tap(_ entry: String, in panel: MenuPanel) throws {
        if entry.hasPrefix("menu.") {
            try panel.inspect().find(ViewType.Button.self, where: { try $0.accessibilityIdentifier() == entry }).tap()
        } else { try panel.inspect().find(button: entry).tap() }
    }
    private func drainPresentation() async { try? await Task.sleep(for: .milliseconds(20)) }
}

/// Native owned windows with presentation intercepted: tests never activate or order a window on the desktop.
@MainActor
private final class NavigationWindow: NSWindow {
    var shown = false
    var minimized = false
    var frontCount = 0
    var deminimizeCount = 0
    init() {
        _ = NSApplication.shared
        super.init(contentRect: NSRect(x: -10000, y: -10000, width: 680, height: 560),
                   styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
    }
    override var isVisible: Bool { shown }
    override var isMiniaturized: Bool { minimized }
    override func deminiaturize(_ sender: Any?) { deminimizeCount += 1; minimized = false; shown = true }
    override func makeKeyAndOrderFront(_ sender: Any?) { frontCount += 1; shown = true }
    override func close() {
        shown = false; minimized = false
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: self)
    }
}

@MainActor
private final class NavigationPanel: NSPanel {
    var frontCount = 0
    init() {
        _ = NSApplication.shared
        super.init(contentRect: NSRect(x: -10000, y: -10000, width: 680, height: 520),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        isReleasedWhenClosed = false
        hidesOnDeactivate = true; canHide = true
        collectionBehavior = [.transient, .fullScreenAuxiliary]
    }
    override func makeKeyAndOrderFront(_ sender: Any?) { frontCount += 1 }
}
