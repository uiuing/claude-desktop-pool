import AppKit
import SwiftUI

@MainActor
final class PoolWindowNavigator {
    /// The app's own navigator: with the main window closed, Claude Pool lives in the menu bar
    /// alone and leaves the Dock; opening the window brings its Dock icon back.
    static let shared = PoolWindowNavigator(showInDock: { NSApp.setActivationPolicy($0 ? .regular : .accessory) })
    static let sceneID = "pool"
    static let windowID = NSUserInterfaceItemIdentifier("ClaudePool.MainWindow")

    private weak var mainWindow: NSWindow?
    private var openScene: (@MainActor () -> Void)?
    private var closeObserver: NSObjectProtocol?
    private var mainWindowClosed = false
    private var presentationRequested = false
    private let activate: @MainActor () -> Void
    private let showInDock: @MainActor (Bool) -> Void
    private var inDock = true

    init(activate: @escaping @MainActor () -> Void = { NSApp.activate(ignoringOtherApps: true) },
         showInDock: @escaping @MainActor (Bool) -> Void = { _ in }) {
        self.activate = activate; self.showInDock = showInDock
    }

    /// Whether Claude Pool shows in the Dock and the app switcher: while its main window is open.
    private func setInDock(_ shown: Bool) {
        guard inDock != shown else { return }
        inDock = shown; showInDock(shown)
    }

    deinit {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    }

    func configure(opener: @escaping @MainActor () -> Void) { openScene = opener }

    func register(_ window: NSWindow) {
        Self.configurePersistentVisibility(window)
        var behavior = window.collectionBehavior
        behavior.subtract([.transient, .stationary])
        behavior.insert(.managed)
        window.collectionBehavior = behavior
        window.identifier = Self.windowID
        if mainWindow !== window {
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            mainWindow = window
            mainWindowClosed = false
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.mainWindowClosed = true
                    // A window being reopened right now keeps the Dock icon.
                    if self?.presentationRequested != true { self?.setInDock(false) }
                }
            }
        }
        if window.isVisible || window.isMiniaturized { setInDock(true) }
        if presentationRequested { schedulePresentation() }
    }

    fileprivate static func configurePersistentVisibility(_ window: NSWindow) {
        // AppKit panels hide on deactivation by default. The main window and its
        // terminal sheet remain available while another application has focus.
        window.hidesOnDeactivate = false
        window.canHide = false
    }

    func show(opener: (@MainActor () -> Void)? = nil, dismiss: @MainActor () -> Void = {}) {
        if let opener { configure(opener: opener) }
        presentationRequested = true
        dismiss()
        // Back in the Dock before activating, so the app comes forward with its menu.
        setInDock(true)
        activate()
        // Ask SwiftUI on every navigation, including after it has closed the scene.
        openScene?()
        schedulePresentation()
    }

    private func schedulePresentation() {
        DispatchQueue.main.async { [weak self] in self?.presentRegisteredWindow() }
    }

    private func presentRegisteredWindow() {
        guard presentationRequested, let window = mainWindow, window.identifier == Self.windowID,
              !mainWindowClosed || window.isVisible || window.isMiniaturized else { return }
        presentationRequested = false
        mainWindowClosed = false
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }
}

/// A sheet keeps its native parent, level and collection behavior. It must never be
/// registered as the main scene or request activation when SwiftUI updates its content.
struct PoolSheetWindowReader: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowReader { WindowReader() }
    func updateNSView(_ view: WindowReader, context: Context) {
        if let window = view.window { PoolWindowNavigator.configurePersistentVisibility(window) }
    }

    final class WindowReader: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { PoolWindowNavigator.configurePersistentVisibility(window) }
        }
    }
}

struct PoolMainWindowReader: NSViewRepresentable {
    let navigator: PoolWindowNavigator
    func makeNSView(context: Context) -> WindowReader {
        let view = WindowReader()
        view.navigator = navigator
        return view
    }
    func updateNSView(_ view: WindowReader, context: Context) {
        view.navigator = navigator
        if let window = view.window { navigator.register(window) }
    }

    final class WindowReader: NSView {
        weak var navigator: PoolWindowNavigator?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { navigator?.register(window) }
        }
    }
}
