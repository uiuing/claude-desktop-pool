import AppKit
import Darwin
import Foundation
import Observation
import PoolCore
import PoolRuntime
@preconcurrency import UserNotifications

/// Claude Pool's own release check, as Claude Switch does it: the public latest-release redirect on
/// GitHub, at most once a day while the app is open, and a manual check at most once a minute.
/// A newer version is announced in the app; it is downloaded and installed by the user.
@MainActor
@Observable
final class AppUpdates {
    enum Status: Equatable { case idle, checking, current, available, failed, cooldown, unknownVersion }
    nonisolated static let bundleVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    let currentVersion: String
    private(set) var latestVersion: ReleaseVersion?
    private(set) var status = Status.idle
    private(set) var automatic: Bool
    var isChecking: Bool { status == .checking }
    var hasUpdate: Bool {
        guard let current = ReleaseVersion(currentVersion), let latestVersion else { return false }
        return latestVersion > current
    }
    @ObservationIgnored private let demo: Bool
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let fetch: () async throws -> ReleaseVersion
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let announce: @MainActor (ReleaseVersion, String) -> Void
    /// Pool's own language choice, read when a notification is posted.
    @ObservationIgnored var language: @MainActor () -> String = { "system" }
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var lastAttempt: Date?
    @ObservationIgnored private var retryAfter: Date?
    /// Downloading and swapping in a newer version, then opening it again.
    enum Install: Equatable { case idle, downloading, restarting, failed }
    private(set) var install = Install.idle
    @ObservationIgnored private let installer: AppUpdateInstaller?
    @ObservationIgnored private var staged: URL?
    /// Asks the app to quit; the delegate swaps the bundle in once quitting is agreed.
    @ObservationIgnored var restart: @MainActor () -> Void = { PoolQuit.request() }
    /// A packaged copy in a folder the user can write updates itself; otherwise the releases page opens.
    var canInstall: Bool { installer?.canReplace == true }
    /// The newer version whose banner was closed; a later version shows its own.
    private(set) var dismissedVersion: String?
    var showsBanner: Bool { hasUpdate && (install != .idle || dismissedVersion != latestVersion?.description) }
    func dismissBanner() {
        dismissedVersion = latestVersion?.description; defaults?.set(dismissedVersion, forKey: "updates.dismissedVersion")
    }

    init(demo: Bool, currentVersion: String = AppUpdates.bundleVersion,
         defaults: UserDefaults? = nil, now: @escaping () -> Date = Date.init,
         fetch: (() async throws -> ReleaseVersion)? = nil,
         announce: (@MainActor (ReleaseVersion, String) -> Void)? = nil) {
        self.demo = demo; self.currentVersion = currentVersion; self.now = now
        self.announce = announce ?? AppUpdates.postNotification
        let bundle = Bundle.main
        installer = demo || bundle.bundleURL.pathExtension != "app" ? nil : bundle.bundleIdentifier.map {
            AppUpdateInstaller(repository: ProjectLink.repository, currentApp: bundle.bundleURL, bundleIdentifier: $0)
        }
        let storage = demo ? nil : (defaults ?? .standard)
        self.defaults = storage
        automatic = storage?.object(forKey: "updates.automatic") as? Bool ?? true
        lastAttempt = storage?.object(forKey: "updates.releasePage.lastAttempt") as? Date
        retryAfter = storage?.object(forKey: "updates.releasePage.retryAfter") as? Date
        latestVersion = storage?.string(forKey: "updates.latestVersion").flatMap(ReleaseVersion.init)
        dismissedVersion = storage?.string(forKey: "updates.dismissedVersion")
        self.fetch = fetch ?? { try await GitHubReleaseClient(endpoint: ProjectLink.releases).fetch() }
        if hasUpdate { status = .available }
        else if latestVersion != nil, let success = storage?.object(forKey: "updates.releasePage.lastSuccess") as? Date,
                success == lastAttempt, (0..<86400).contains(now().timeIntervalSince(success)) {
            status = ReleaseVersion(currentVersion) == nil ? .unknownVersion : .current
        }
    }
    /// Checks now if a day has passed, then hourly looks again whether one has.
    func start() {
        guard !demo, timer == nil else { return }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check(manual: false)
                do { try await Task.sleep(for: .seconds(3600)) } catch { return }
                guard self != nil else { return }
            }
        }
    }
    func setAutomatic(_ value: Bool) {
        automatic = value; defaults?.set(value, forKey: "updates.automatic")
        if value, timer != nil { Task { await check(manual: false) } }
    }
    func check(manual: Bool) async {
        guard !demo, !isChecking, manual || automatic else { return }
        let date = now()
        if let retryAfter, date < retryAfter { if manual { status = .cooldown }; return }
        if let lastAttempt {
            let elapsed = date.timeIntervalSince(lastAttempt)
            if elapsed >= 0 && elapsed < (manual ? 60 : 86400) {
                if manual, status != .current && status != .available { status = .cooldown }
                return
            }
        }
        lastAttempt = date; defaults?.set(date, forKey: "updates.releasePage.lastAttempt")
        status = .checking
        do {
            let version = try await fetch()
            latestVersion = version; defaults?.set(version.description, forKey: "updates.latestVersion")
            defaults?.set(date, forKey: "updates.releasePage.lastSuccess")
            retryAfter = nil; defaults?.removeObject(forKey: "updates.releasePage.retryAfter")
            status = ReleaseVersion(currentVersion) == nil ? .unknownVersion : hasUpdate ? .available : .current
            // Each newer version is announced once, whichever check found it.
            if hasUpdate, defaults?.string(forKey: "updates.notifiedVersion") != version.description {
                defaults?.set(version.description, forKey: "updates.notifiedVersion")
                announce(version, language())
            }
            Diagnostics.record("update.checked", ["manual": String(manual), "latest": version.description, "newer": String(hasUpdate)])
        } catch {
            if let date = (error as? ReleaseCheckError)?.retryAfter {
                retryAfter = date; defaults?.set(date, forKey: "updates.releasePage.retryAfter")
            }
            Diagnostics.record("update.failed", ["manual": String(manual), "cooldown": String(retryAfter != nil)])
            status = .failed
        }
    }
    /// Downloads the newer version, checks it, and quits so it can take this copy's place.
    func installAndRestart() async {
        guard !demo, hasUpdate, let latestVersion, install != .downloading, install != .restarting else { return }
        guard let installer, installer.canReplace else { ProjectLink.open(ProjectLink.releases); return }
        if staged == nil {
            install = .downloading
            let started = Date()
            do {
                staged = try await installer.prepare(latestVersion)
                Diagnostics.record("update.prepared", ["version": latestVersion.description,
                                                       "seconds": String(Int(Date().timeIntervalSince(started)))])
            } catch {
                Diagnostics.record("update.prepareFailed", ["reason": String(describing: (error as? AppUpdateError) ?? .download)])
                install = .failed; return
            }
        }
        install = .restarting
        restart()
    }
    /// Previews show an announced version without reading GitHub.
    func previewAvailable(_ version: ReleaseVersion) {
        guard demo else { return }
        latestVersion = version; status = hasUpdate ? .available : .current
    }
    /// Quitting was refused; the downloaded version waits for the next click.
    func restartRefused() { if install == .restarting { install = .idle } }
    /// Called once the app has agreed to quit: swaps the new bundle in and opens it after this process exits.
    func finishInstall() {
        guard install == .restarting, let staged, let installer else { return }
        do { try installer.replace(with: staged); Diagnostics.record("update.installed", ["version": latestVersion?.description ?? "—"]) }
        catch { Diagnostics.record("update.replaceFailed", [:]) }
        self.staged = nil
        do { try installer.relaunch(after: getpid()) } catch { Diagnostics.record("update.relaunchFailed", [:]) }
    }
    /// A macOS notification; clicking it brings Pool forward. Only a packaged app can post one.
    static func postNotification(_ version: ReleaseVersion, language: String) {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let content = UNMutableNotificationContent()
        content.title = L10n.tr("Claude Pool {0} is available.", language: language, arguments: [version.description])
        content.body = L10n.tr("Open Claude Pool to update and restart.", language: language)
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            Diagnostics.record("update.notification", ["allowed": String(granted)])
            guard granted else { return }
            center.add(UNNotificationRequest(identifier: "update." + version.description, content: content, trigger: nil))
        }
    }
    func statusText(_ t: (String, String...) -> String) -> String {
        switch install {
        case .downloading: return t("Downloading Claude Pool {0}…", latestVersion?.description ?? "—")
        case .restarting: return t("Restarting to finish the update…")
        case .failed: return t("Could not install the update. Try again or download it from GitHub.")
        case .idle: break
        }
        switch status {
        case .idle: return t("Check for a newer version on GitHub.")
        case .checking: return t("Checking for updates…")
        case .current: return t("You're up to date.")
        case .available: return t("Claude Pool {0} is available.", latestVersion?.description ?? "—")
        case .failed: return t("Could not check for updates. Try again later or open the releases page.")
        case .cooldown: return t("Please wait before checking again. You can still open the releases page.")
        case .unknownVersion: return t("Could not compare versions. Open the releases page to check.")
        }
    }
}
