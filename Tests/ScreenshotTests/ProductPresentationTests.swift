import AppKit
import SwiftUI
import XCTest
import ViewInspector
@testable import ClaudePool

@MainActor
final class ProductPresentationTests: XCTestCase {
    private static var windows: [NSWindow] = []

    /// Three accounts in use drew the first lane onto the second: it alone was pushed down.
    func testRouteLanesNeverOverlap() {
        for count in 1...RoutingFlowView.laneLimit {
            let total = CGFloat(count) * RoutingFlowView.laneHeight + CGFloat(count - 1) * RoutingFlowView.laneGap
            let centers = RoutingFlowView.laneCenters(count: count, height: max(104, total))
            XCTAssertGreaterThanOrEqual(centers.first! - RoutingFlowView.laneHeight / 2, 0, "\(count) lanes")
            for (upper, lower) in zip(centers, centers.dropFirst()) {
                XCTAssertGreaterThanOrEqual(lower - upper, RoutingFlowView.laneHeight + RoutingFlowView.laneGap, "\(count) lanes")
            }
        }
    }

    func testAboutSaysWhatThePoolDoesInEveryLanguage() {
        for language in ["zh-Hans", "zh-Hant", "ja", "ko"] {
            let model = PoolAppModel.demoModel(language: language)
            for feature in AboutSettings.features {
                XCTAssertNotEqual(model.t(feature.text), feature.text, "\(language): \(feature.text)")
            }
        }
    }

    func testNativeEditorKeepsPlaceholderAndInputGeometryAndBinding() async throws {
        var text = ""
        let placeholder = "Paste sample text to preview locally."
        let view = PoolTextEditor(text: Binding(get: { text }, set: { text = $0 }), placeholder: placeholder,
                                  accessibilityLabel: "Text to inspect", identifier: "privacy.input")
        let host = makeHost(view, size: .init(width: 400, height: 74), dark: false)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(descendant(PoolPlaceholderTextView.self, in: host))
        let font = try XCTUnwrap(editor.font)
        let container = try XCTUnwrap(editor.textContainer)
        XCTAssertEqual(editor.placeholder, placeholder)
        XCTAssertEqual(editor.string, "")
        XCTAssertEqual(font.fontName, NSFont.monospacedSystemFont(ofSize: 11, weight: .regular).fontName)
        XCTAssertEqual(font.pointSize, 11)
        XCTAssertEqual(container.lineFragmentPadding, 0)
        XCTAssertEqual(editor.textContainerInset, NSSize(width: 10, height: 8))
        let origin = editor.textContainerOrigin
        let containerSize = container.containerSize
        XCTAssertEqual(origin, NSPoint(x: 10, y: 8))
        editor.string = placeholder
        editor.didChangeText()
        editor.layoutManager?.ensureLayout(for: container)
        XCTAssertEqual(text, placeholder)
        XCTAssertEqual(editor.font, font)
        XCTAssertEqual(editor.textContainerOrigin, origin)
        XCTAssertEqual(container.containerSize, containerSize)
        editor.string = ""
        editor.didChangeText()
        XCTAssertEqual(text, "")
        XCTAssertFalse(host.window?.isVisible ?? true)
    }

    func testAppearanceMappingAndPickerDispatch() throws {
        let model = PoolAppModel.demoModel()
        var actions: [UIAction] = []
        model.onAction = { actions.append($0) }
        let choices: [(String, ColorScheme?)] = [("system", nil), ("light", .light), ("dark", .dark)]
        for (value, scheme) in choices {
            model.preferences.appearance = value
            XCTAssertEqual(model.preferredColorScheme, scheme)
            try PoolSettingsPage(model: model).inspect().find(ViewType.Picker.self, where: {
                try $0.accessibilityIdentifier() == "settings.appearance"
            }).select(value: value)
            XCTAssertEqual(actions.last, .appearance(value))
        }
        model.isWorking = true
        XCTAssertTrue(try PoolSettingsPage(model: model).inspect().find(ViewType.Picker.self, where: {
            try $0.accessibilityIdentifier() == "settings.appearance"
        }).isDisabled())
    }

    func testRuntimeStagesVersionAndMeasuredProgress() throws {
        let model = PoolAppModel.demoModel(setup: true)
        model.runtime = .init(phase: .installing, progress: 0.42, stage: "Downloading…", targetVersion: "2.1.301",
                              downloadedBytes: 42_000_000, totalBytes: 100_000_000)
        let view = RuntimeInstallStatus(model: model)
        XCTAssertNoThrow(try view.inspect().find(text: "Version 2.1.301"))
        XCTAssertNoThrow(try view.inspect().find(text: "42.0 of 100.0 MB"))
        XCTAssertNoThrow(try view.inspect().find(text: "42%"))
        XCTAssertNoThrow(try view.inspect().find(ViewType.ProgressView.self))
        for stage in ["Checking release…", "Downloading…", "Verifying…", "Installing…"] {
            model.runtime.stage = stage
            XCTAssertNoThrow(try view.inspect().find(text: stage))
        }
        model.runtime.progress = nil
        model.runtime.downloadedBytes = nil
        model.runtime.totalBytes = nil
        XCTAssertThrowsError(try view.inspect().find(text: "42%"))
        XCTAssertThrowsError(try view.inspect().find(text: "42.0 of 100.0 MB"))
        XCTAssertNoThrow(try view.inspect().find(ViewType.ProgressView.self))
    }

    func testPendingSignInButtonsDoNotCreateAnAccount() throws {
        let model = PoolAppModel.demoModel(setup: true)
        model.snapshot.executableReady = true
        model.runtime = .init(phase: .ready, installedVersion: "2.1.301")
        model.pendingSignInID = UUID(uuidString: "0a1b2c3d-1111-4aaa-8bbb-000000000005")!
        var actions: [UIAction] = []
        model.onAction = { actions.append($0) }
        try SetupCard(model: model).inspect().find(button: "Continue sign-in").tap()
        try AccountsPage(model: model).inspect().find(button: "Continue sign-in").tap()
        XCTAssertEqual(actions, [.addAccount, .addAccount])
        XCTAssertTrue(model.snapshot.accounts.isEmpty)
        XCTAssertFalse(model.hasSignedInAccount)
    }

    func testRenderProductStates() async throws {
        guard let directory = ProcessInfo.processInfo.environment["CLAUDE_POOL_SCREENSHOTS"] else {
            throw XCTSkip("Use scripts/screenshots.sh to render inert demo screens.")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for language in ["en", "zh-Hans"] {
            for dark in [false, true] {
                let suffix = "\(language)-\(dark ? "dark" : "light")"
                let setup = PoolAppModel.demoModel(language: language, setup: true)
                setup.preferences.appearance = dark ? "dark" : "light"
                setup.runtime = .init(phase: .installing, progress: 0.42, stage: "Downloading…", targetVersion: "2.1.301",
                                      downloadedBytes: 42_000_000, totalBytes: 100_000_000)
                setup.isWorking = true
                try await capture(MainWindow(model: setup), size: .init(width: 680, height: 560), dark: dark,
                                  to: output.appendingPathComponent("product-install-\(suffix).png"))
                setup.page = .accounts
                try await capture(MainWindow(model: setup), size: .init(width: 640, height: 520), dark: dark,
                                  to: output.appendingPathComponent("product-install-accounts-\(suffix).png"))
                let model = PoolAppModel.demoModel(language: language)
                model.preferences.appearance = dark ? "dark" : "light"
                try await capture(ScrollView { PoolSettingsPage(model: model).padding(16) }, size: .init(width: 511, height: 600), dark: dark,
                                  to: output.appendingPathComponent("product-appearance-\(suffix).png"))
                model.runtime.availableVersion = "2.1.302"
                try await capture(MenuPanel(model: model), size: .init(width: 320, height: 440), dark: dark,
                                  to: output.appendingPathComponent("product-update-menu-\(suffix).png"))
                for (name, text) in [("empty", ""), ("input", "Contact Taylor at mi•••ella@example.com.")] {
                    try await capture(PrivacyDetailsSheet(model: model, initialText: text), size: .init(width: 500, height: 500), dark: dark,
                                      to: output.appendingPathComponent("product-preview-\(name)-\(suffix).png"))
                }
                let id = UUID(uuidString: "0a1b2c3d-1111-4aaa-8bbb-000000000005")!
                let url = try XCTUnwrap(URL(string: "https://auth.synthetic.invalid/oauth/authorize?client_id=synthetic-client&state=synthetic-state"))
                model.terminal = .init(id: id, title: model.t("Sign in with Claude"),
                    output: "Claude Code\n\nOpen the sign-in link to continue.\n\nWaiting for sign-in…", isPendingSignIn: true, links: [url])
                try await capture(TerminalSheet(model: model, terminalID: id, openLink: { _ in }, copyLink: { _ in true }),
                                  size: .init(width: 680, height: 520), dark: dark,
                                  to: output.appendingPathComponent("product-signin-link-\(suffix).png"))
            }
        }
    }

    private func descendant<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.descendant(type, in: $0) }.first
    }

    private func makeHost<Content: View>(_ content: Content, size: NSSize, dark: Bool) -> NSHostingView<some View> {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: ZStack(alignment: .topLeading) { PoolPalette.background; content }
            .frame(width: size.width, height: size.height).environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: .init(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.frame = .init(origin: .zero, size: size)
        Self.windows.append(window)
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func capture<Content: View>(_ content: Content, size: NSSize, dark: Bool, to url: URL) async throws {
        let host = makeHost(content, size: size, dark: dark)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: url)
        XCTAssertGreaterThan(png.count, 5000)
        XCTAssertFalse(host.window?.isVisible ?? true)
    }
}
