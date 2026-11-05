import AppKit
import Foundation

/// Finds, quits and opens Claude Desktop. Desktop reads its connection only as it starts, so a
/// change takes effect after a restart; Pool restarts it only after asking, quits it as its own
/// Quit does and never force-quits. Tests use a synthetic home and fake app.
struct DesktopAppControl {
    static let bundleID = "com.anthropic.claudefordesktop"
    /// The home whose Library holds Desktop's settings.
    var home: URL
    var installedURL: @MainActor () -> URL?
    /// Launch times of running Desktop windows apps; the main process only.
    var launchDates: @MainActor () -> [Date]
    /// Whether any process of Desktop's bundle, its helpers included, still runs.
    var running: @MainActor () -> Bool
    var quit: @MainActor () -> Void
    var open: @MainActor (URL) async -> Bool
    var confirm: @MainActor (_ title: String, _ detail: String, _ accept: String, _ cancel: String) -> Bool
    var quitWait: TimeInterval = 30

    @MainActor static var live: DesktopAppControl {
        func apps() -> [NSRunningApplication] {
            NSWorkspace.shared.runningApplications.filter { !$0.isTerminated && $0.bundleIdentifier?.hasPrefix(bundleID) == true }
        }
        return .init(
            home: FileManager.default.homeDirectoryForCurrentUser,
            installedURL: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) },
            launchDates: { apps().filter { $0.bundleIdentifier == bundleID }.map { $0.launchDate ?? .distantPast } },
            running: { !apps().isEmpty },
            quit: { for app in apps() where app.bundleIdentifier == bundleID { app.terminate() } },
            open: { url in
                let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
                return (try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)) != nil
            },
            confirm: { title, detail, accept, cancel in
                let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
                alert.addButton(withTitle: accept); alert.addButton(withTitle: cancel)
                NSApp.activate(ignoringOtherApps: true)
                return alert.runModal() == .alertFirstButtonReturn
            })
    }
}
