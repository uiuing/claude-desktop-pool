import AppKit
import Darwin
import PoolCore
import PoolEngine
import SwiftUI

@main
enum ClaudePoolEntry {
    static func main() {
        if let status = EngineHelpers.dispatch(arguments: Array(CommandLine.arguments.dropFirst())) { exit(status) }
        ClaudePoolApplication.main()
    }
}

struct ClaudePoolApplication: App {
    @NSApplicationDelegateAdaptor(PoolApplicationDelegate.self) private var delegate
    @State private var model: PoolAppModel
    private let services: AppServices

    init() {
        let demo = CommandLine.arguments.contains("--demo")
        let model = demo ? PoolAppModel.demoModel() : PoolAppModel()
        _model = State(initialValue: model)
        var dependencies = AppServiceDependencies(); dependencies.desktop = .live
        services = AppServices(model: model, dependencies: dependencies)
        if !demo {
            model.onAction = { [services] action in Task { await services.handle(action) } }
            model.onSettingAction = { [services] action in await services.handle(action) }
            model.updates.start()
        }
    }

    var body: some Scene {
        Window("Claude Pool", id: PoolWindowNavigator.sceneID) {
            PoolMainWindowContent(model: model)
                .task {
                    delegate.services = services
                    await services.load()
                }
        }
        .defaultSize(width: 680, height: 560)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appSettings) {
                Button(model.t("Settings")) { model.page = .settings; services.showWindow() }
                    .keyboardShortcut(",")
            }
            CommandGroup(replacing: .help) {
                Button(model.t("Report an issue")) { ProjectLink.open(ProjectLink.issues) }
                Button(model.t("View latest version")) { ProjectLink.open(ProjectLink.releases) }
                Button(model.t("Check for updates")) {
                    Task { await model.updates.check(manual: true) }
                    model.showAbout(); services.showWindow()
                }.disabled(model.updates.isChecking)
            }
        }
        MenuBarExtra {
            MenuPanel(model: model).environment(\.locale, model.locale).preferredColorScheme(model.preferredColorScheme)
                .onAppear { Task { await services.checkRuntimeUpdateIfNeeded() } }
        } label: {
            PoolStatusLabel(model: model)
        }.menuBarExtraStyle(.window)
    }
}

private struct PoolStatusLabel: View {
    @Bindable var model: PoolAppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        // Claude's mark with the shown plan's 5-hour limit over its weekly one: a glance is enough.
        let figures = model.menuBarFigures
        Image(nsImage: MenuBarFigure.image(figures))
            .accessibilityLabel(figures.map { "Claude Pool, " + MenuBarFigure.accessibility($0, model: model) } ?? "Claude Pool")
            // Limits renew at their reset while the menu is closed too; a coarse clock keeps the figures current.
            .task { await model.updateClock(every: 20) }
            .onAppear {
                let action = openWindow
                PoolWindowNavigator.shared.configure { action(id: PoolWindowNavigator.sceneID) }
            }
    }
}

private struct PoolMainWindowContent: View {
    @Bindable var model: PoolAppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        // The title bar is hidden: the sidebar and page header run to the top edge, under the window buttons.
        MainWindow(model: model)
            .ignoresSafeArea(.container, edges: .top)
            .environment(\.locale, model.locale)
            .background(PoolMainWindowReader(navigator: .shared).frame(width: 0, height: 0))
            .onAppear {
                let action = openWindow
                PoolWindowNavigator.shared.configure { action(id: PoolWindowNavigator.sceneID) }
            }
    }
}

@MainActor
final class PoolApplicationDelegate: NSObject, NSApplicationDelegate {
    var services: AppServices?
    private var quitting = false
    private var quitIndicator: QuitIndicator?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        Task { await services?.checkRuntimeUpdateIfNeeded() }
        PoolWindowNavigator.shared.show(); return true
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        Task { await services?.checkRuntimeUpdateIfNeeded() }
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting else { return .terminateCancel }
        guard let services else { return .terminateNow }
        quitting = true
        // Quitting takes seconds and the menu has just closed: say so at once, wherever the person is.
        if !services.model.demo { quitIndicator = QuitIndicator(model: services.model) }
        Task {
            let allowed = await services.prepareToQuit()
            quitting = false
            if !allowed { quitIndicator?.close(); quitIndicator = nil }
            if allowed { services.model.updates.finishInstall() } else { services.model.updates.restartRefused() }
            sender.reply(toApplicationShouldTerminate: allowed)
        }
        return .terminateLater
    }
}
