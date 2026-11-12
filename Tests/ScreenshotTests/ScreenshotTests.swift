import AppKit
import SwiftUI
import XCTest
import PoolCore
@testable import ClaudePool

@MainActor
final class ScreenshotTests: XCTestCase {
    private static var windows: [NSWindow] = []

    func testRenderDemoScreens() async throws {
        guard let directory = ProcessInfo.processInfo.environment["CLAUDE_POOL_SCREENSHOTS"] else {
            throw XCTSkip("Use scripts/screenshots.sh to render inert demo screens.")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        for language in L10n.languages.map(\.code) {
            for dark in [false, true] {
                let suffix = "\(language)-\(dark ? "dark" : "light")"
                let model = PoolAppModel.showcaseModel(language: language)
                for page in PoolPage.allCases.filter({ $0 != .pool && $0 != .settings }) {
                    model.page = page
                    try await capture(MainWindow(model: model), size: .init(width: 680, height: 560), dark: dark,
                                      to: output.appendingPathComponent("\(page.rawValue)-\(suffix).png"))
                    try await capture(MainWindow(model: model), size: .init(width: 640, height: 520), dark: dark,
                                      to: output.appendingPathComponent("\(page.rawValue)-narrow-\(suffix).png"))
                }
                let setup = PoolAppModel.demoModel(language: language, setup: true)
                try await capture(MainWindow(model: setup), size: .init(width: 680, height: 560), dark: dark,
                                  to: output.appendingPathComponent("setup-\(suffix).png"))
                try await capture(MainWindow(model: setup), size: .init(width: 640, height: 520), dark: dark,
                                  to: output.appendingPathComponent("setup-narrow-\(suffix).png"))
            }
        }
    }

    /// The Usage page at the pool sizes it is built for: a few accounts, a dozen or so, and a hundred.
    /// The README banner's window: a pool of a dozen accounts. It stays out of docs/images.
    func testRenderBannerScreens() async throws {
        guard let directory = ProcessInfo.processInfo.environment["CLAUDE_POOL_SCREENSHOTS"] else {
            throw XCTSkip("Use scripts/screenshots.sh to render inert demo screens.")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        let model = PoolAppModel.demoModel(language: "en")
        let date = model.now
        func limits(_ session: Double?, _ week: Double, weekly: Bool = false) -> [QuotaWindow] {
            let week = QuotaWindow(id: "seven_day", usedPercent: week, observedAt: date.addingTimeInterval(-90), resetsAt: date.addingTimeInterval(weekly ? 86_400 : 259_200))
            guard let session else { return [week] }
            return [.init(id: "five_hour", usedPercent: session, observedAt: date.addingTimeInterval(-90), resetsAt: date.addingTimeInterval(5_400)), week]
        }
        // Several accounts of every plan, in the states a real pool goes through: serving, low, at a 5-hour limit,
        // and a used-up week.
        let names = ["avery", "blake", "casey", "dana", "emery", "finley", "harper", "jordan", "kai", "logan", "morgan", "noah",
                     "parker", "quinn", "riley", "sage", "taylor", "uma", "val", "wren", "xavi", "yuki", "zane", "ari",
                     "bo", "cleo", "dev", "eli", "faye", "gus", "hana", "ivy"]
        let domains = ["example.com", "example.org", "example.net"]
        // With the four demo accounts: Pro 10, Max 5x 2, Ultra 1, as a pool is mostly Pro.
        let plans: [(String, Int)] = [("Pro", 9)]
        var next = 0
        for (plan, count) in plans {
            for index in 0..<count {
                let name = names[next % names.count], seed = next; next += 1
                let email = "\(name)@\(domains[seed % domains.count])"
                var state = AccountState.ready, cooldown: Date?
                var windows = limits(plan == "Ultra" ? nil : Double((seed * 29 + 7) % 88), Double((seed * 17 + 11) % 80))
                switch (plan, index) {
                case ("Pro", 5):
                    state = .limited; cooldown = date.addingTimeInterval(5_400); windows = limits(100, 46)
                case ("Pro", 1):
                    state = .limited; cooldown = date.addingTimeInterval(86_400); windows = limits(30, 100, weekly: true)
                default: break
                }
                model.snapshot.accounts.append(PoolAccount(email: email, plan: plan, state: state, windows: windows,
                                                           cooldownUntil: cooldown, createdAt: date))
            }
        }
        let serving = model.snapshot.accounts.filter { ["avery@example.com", "dana@example.com", "casey@example.net"].contains($0.email) }
        for (index, account) in serving.enumerated() {
            model.snapshot.sessions.append(.init(id: UUID(), accountID: account.id, name: ["Refactor the parser", "Draft the launch post", "Review open issues"][index],
                                                 model: ["Opus", "Sonnet", "Sonnet"][index], state: index == 0 ? .running : .waiting,
                                                 startedAt: date.addingTimeInterval(-Double(300 * (index + 1))), conversation: "banner-\(index)"))
        }
        for page in [PoolPage.accounts, .pool] {
            model.page = page
            try await capture(MainWindow(model: model), size: .init(width: 680, height: 900), dark: false,
                              to: output.appendingPathComponent("banner-\(page.rawValue)-en-light.png"))
        }
        try await capture(MenuPanel(model: model), size: .init(width: 320, height: 720), dark: false,
                          to: output.appendingPathComponent("banner-menu-en-light.png"))
        // The menu bar item the panel opens from, drawn as the menu bar draws it, at 4x.
        let figure = MenuBarFigure.image(model.menuBarFigures)
        let scale: CGFloat = 4
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(figure.size.width * scale), pixelsHigh: Int(figure.size.height * scale),
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        figure.draw(in: NSRect(x: 0, y: 0, width: figure.size.width * scale, height: figure.size.height * scale))
        NSGraphicsContext.restoreGraphicsState()
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("banner-status-en-light.png"))
    }

    func testRenderUsageScales() async throws {
        guard let directory = ProcessInfo.processInfo.environment["CLAUDE_POOL_SCREENSHOTS"] else {
            throw XCTSkip("Use scripts/screenshots.sh to render inert demo screens.")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        for language in ["en", "zh-Hans"] {
            for dark in [false, true] {
                let suffix = "\(language)-\(dark ? "dark" : "light")"
                for count in [4, 15, 100] {
                    let model = PoolAppModel.demoModel(language: language)
                    let date = model.now
                    if count > 4 {
                        model.snapshot.accounts = PoolAppModel.demoAccounts(count, at: date)
                        model.usage = PoolAppModel.demoUsage(ids: model.snapshot.accounts.map(\.id), now: date)
                    }
                    model.page = .usage
                    for (name, grouping, metric) in [("model", UsageGrouping.model, UsageMetric.tokens), ("account", .account, .cost), ("plan", .plan, .tokens)] {
                        if count == 4 && name == "plan" { continue }
                        model.usageGrouping = grouping; model.usageMetric = metric
                        try await capture(MainWindow(model: model), size: .init(width: 680, height: 1900), dark: dark,
                                          to: output.appendingPathComponent("usage-\(count)-\(name)-\(suffix).png"))
                    }
                }
            }
        }
    }

    func testRenderPoolScreens() async throws {
        guard let directory = ProcessInfo.processInfo.environment["CLAUDE_POOL_SCREENSHOTS"] else {
            throw XCTSkip("Use scripts/screenshots.sh to render inert demo screens.")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        for language in L10n.languages.map(\.code) {
            for dark in [false, true] {
                let model = PoolAppModel.showcaseModel(language: language)
                let suffix = "\(language)-\(dark ? "dark" : "light")"
                try await capture(MainWindow(model: model), size: .init(width: 680, height: 560), dark: dark,
                                  to: output.appendingPathComponent("pool-\(suffix).png"))
                try await capture(MainWindow(model: model), size: .init(width: 640, height: 520), dark: dark,
                                  to: output.appendingPathComponent("narrow-\(suffix).png"))
            }
        }
    }

    func testRenderMenuScreens() async throws {
        guard let directory = ProcessInfo.processInfo.environment["CLAUDE_POOL_SCREENSHOTS"] else {
            throw XCTSkip("Use scripts/screenshots.sh to render inert demo screens.")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        for language in L10n.languages.map(\.code) {
            for dark in [false, true] {
                let model = PoolAppModel.showcaseModel(language: language)
                try await capture(MenuPanel(model: model), size: .init(width: 340, height: 980), dark: dark,
                                  to: output.appendingPathComponent("menu-\(language)-\(dark ? "dark" : "light").png"))
                // The menu bar item at 4x: the usual two lines, and a model limit with less left than the week.
                if language == "en" || language == "zh-Hans" {
                    let suffix = (language == "en" ? "" : "-" + language) + "-\(dark ? "dark" : "light").png"
                    try renderMenuBar(model.menuBarFigures, dark: dark, to: output.appendingPathComponent("menubar" + suffix))
                    var tight = model.menuBarFigures
                    tight?.model = "Fable"; tight?.modelPercent = 12
                    try renderMenuBar(tight, dark: dark, to: output.appendingPathComponent("menubar-fable" + suffix))
                }
                try await capture(QuitIndicatorView(title: model.t("Quitting Claude Pool"),
                                                    detail: model.t("Ending Claude sessions. This takes a few seconds."))
                    .padding(16).environment(\.locale, model.locale), size: .init(width: 380, height: 92), dark: dark,
                                  to: output.appendingPathComponent("quit-\(language)-\(dark ? "dark" : "light").png"))
                // A large pool takes the lazily built list; this render stays out of docs/images.
                let large = PoolAppModel.demoModel(language: language)
                let base = large.snapshot.accounts[1]
                for index in 0..<30 {
                    var extra = base; extra.id = UUID(); extra.email = "pool\(index + 1)@example.invalid"
                    extra.windows = extra.windows.map { var window = $0; window.usedPercent = Double((index * 7) % 90); return window }
                    large.snapshot.accounts.append(extra)
                }
                try await capture(MenuPanel(model: large), size: .init(width: 320, height: 700), dark: dark,
                                  to: output.appendingPathComponent("menu-large-\(language)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    func testRenderTerminalScreens() async throws {
        guard let directory = ProcessInfo.processInfo.environment["CLAUDE_POOL_SCREENSHOTS"] else {
            throw XCTSkip("Use scripts/screenshots.sh to render inert demo screens.")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        for language in ["en", "zh-Hans"] {
            for dark in [false, true] {
                let model = PoolAppModel.demoModel(language: language)
                let id = model.snapshot.sessions[1].id
                model.terminal = .init(id: id, title: "Plan the next release", output: "Claude Code\n\nAllow this session to use the Desktop tools?\n\n> 1. Allow once\n  2. Always allow for this session\n  3. Deny\n\n    Left column                     Right column\n    Keep the spacing.               Keep the spacing.\n\n" + String(repeating: "0123456789", count: 18))
                try await capture(TerminalSheet(model: model, terminalID: id), size: .init(width: 680, height: 520), dark: dark,
                                  to: output.appendingPathComponent("terminal-\(language)-\(dark ? "dark" : "light").png"))
                model.terminal?.textInputEnabled = false
                model.snapshot.sessions[1].state = .idle
                try await capture(TerminalSheet(model: model, terminalID: id), size: .init(width: 680, height: 520), dark: dark,
                                  to: output.appendingPathComponent("terminal-idle-\(language)-\(dark ? "dark" : "light").png"))
                let signIn = UUID(), link = URL(string: "https://auth.synthetic.invalid/oauth/authorize?code=true&state=synthetic")!
                let prompt = "Opening browser to sign in…\nIf the browser didn't open, visit: \(link.absoluteString)\nPaste code here if prompted > "
                model.terminal = .init(id: signIn, title: model.t("Sign in with Claude"), output: prompt, canRequestExit: true,
                                       isPendingSignIn: true, links: [link])
                try await capture(TerminalSheet(model: model, terminalID: signIn), size: .init(width: 680, height: 520), dark: dark,
                                  to: output.appendingPathComponent("terminal-signin-\(language)-\(dark ? "dark" : "light").png"))
                model.terminal = .init(id: signIn, title: model.t("Sign-in not completed"),
                                       output: prompt + "Login failed: That code wasn't accepted.", isRunning: false, inputEnabled: false)
                model.terminal?.failure = model.t("Claude Code ended before the sign-in finished. Try again for a new sign-in link.")
                model.terminal?.retry = .addAccount
                try await capture(TerminalSheet(model: model, terminalID: signIn), size: .init(width: 680, height: 520), dark: dark,
                                  to: output.appendingPathComponent("terminal-signin-failed-\(language)-\(dark ? "dark" : "light").png"))
                try await capture(SignInRiskSheet(model: model), size: .init(width: 420, height: 190), dark: dark,
                                  to: output.appendingPathComponent("signin-risk-\(language)-\(dark ? "dark" : "light").png"))
            }
        }
    }

    func testRenderQuotaStates() async throws {
        guard let directory = ProcessInfo.processInfo.environment["CLAUDE_POOL_SCREENSHOTS"] else {
            throw XCTSkip("Use scripts/screenshots.sh to render inert demo screens.")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        for language in ["en", "zh-Hans"] {
            let model = PoolAppModel.demoModel(language: language)
            model.page = .accounts
            model.snapshot.accounts = Array(model.snapshot.accounts.prefix(2))
            model.snapshot.accounts[1].windows[0] = .init(id: "five_hour", observedAt: model.now, state: .unknown)
            model.quotaRefresh[model.snapshot.accounts[1].id] = .init(phase: .failed,
                updatedAt: model.now.addingTimeInterval(-600), message: "Quota could not be refreshed. Try again.")
            try await capture(MainWindow(model: model), size: .init(width: 680, height: 560), dark: false,
                              to: output.appendingPathComponent("quota-states-\(language)-light.png"))
            model.page = .pool
            try await capture(MainWindow(model: model), size: .init(width: 680, height: 560), dark: false,
                              to: output.appendingPathComponent("quota-unknown-pool-\(language)-light.png"))
            try await capture(MainWindow(model: model), size: .init(width: 640, height: 520), dark: false,
                              to: output.appendingPathComponent("quota-unknown-narrow-\(language)-light.png"))

            model.page = .accounts
            model.quotaRefresh = [:]
            let week = QuotaWindow(id: "seven_day", usedPercent: 0, observedAt: model.now, resetsAt: model.now.addingTimeInterval(3 * 86400))
            let session = QuotaWindow(id: "five_hour", usedPercent: 0, observedAt: model.now)
            let fable = QuotaWindow(id: "seven_day_overage_included", usedPercent: 0, observedAt: model.now, resetsAt: week.resetsAt)
            model.snapshot.accounts[0].windows = [session, week, fable]
            model.snapshot.accounts[1].windows = [session, week, fable]
            model.snapshot.accounts[1].windows[1].usedPercent = 100
            model.snapshot.accounts[1].state = .limited
            try await capture(MainWindow(model: model), size: .init(width: 680, height: 560), dark: true,
                              to: output.appendingPathComponent("quota-reset-\(language)-dark.png"))
        }
    }

    func testRenderSettingsScreens() async throws {
        guard let directory = ProcessInfo.processInfo.environment["CLAUDE_POOL_SCREENSHOTS"] else {
            throw XCTSkip("Use scripts/screenshots.sh to render inert demo screens.")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        for language in L10n.languages.map(\.code) {
            for dark in [false, true] {
                let model = PoolAppModel.showcaseModel(language: language)
                let suffix = "\(language)-\(dark ? "dark" : "light")"
                model.page = .settings
                model.runtime.previousVersion = "2.1.300"
                try await capture(MainWindow(model: model), size: .init(width: 680, height: 560), dark: dark,
                                  to: output.appendingPathComponent("settings-\(suffix).png"))
                try await capture(MainWindow(model: model), size: .init(width: 640, height: 520), dark: dark,
                                  to: output.appendingPathComponent("settings-narrow-\(suffix).png"))
                try await capture(MainWindow(model: model), size: .init(width: 640, height: 520), dark: dark,
                                  to: output.appendingPathComponent("refresh-settings-\(suffix).png"))
                try await capture(ScrollView { PoolSettingsPage(model: model).padding(16) }.background(PoolPalette.background), size: .init(width: 511, height: 520), dark: dark,
                                  to: output.appendingPathComponent("refresh-timing-\(suffix).png"))
                // Each Settings tab, the banner and the menu panel, with a newer Claude Pool announced and emails hidden.
                let announced = PoolAppModel.demoModel(language: language)
                announced.page = .settings
                announced.perform(.maskEmail(true))
                announced.updates.previewAvailable(ReleaseVersion("0.2.0")!)
                for tab in SettingsTab.allCases {
                    announced.settingsTab = tab
                    try await capture(MainWindow(model: announced), size: .init(width: 680, height: 560), dark: dark,
                                      to: output.appendingPathComponent("settings-tab-\(tab.rawValue)-\(suffix).png"))
                }
                announced.page = .pool
                try await capture(MainWindow(model: announced), size: .init(width: 680, height: 560), dark: dark,
                                  to: output.appendingPathComponent("update-banner-\(suffix).png"))
                try await capture(MenuPanel(model: announced), size: .init(width: 340, height: 980), dark: dark,
                                  to: output.appendingPathComponent("update-menu-\(suffix).png"))
            }
        }
    }

    func testRenderLifecycleScreens() async throws {
        guard let directory = ProcessInfo.processInfo.environment["CLAUDE_POOL_SCREENSHOTS"] else {
            throw XCTSkip("Use scripts/screenshots.sh to render inert demo screens.")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        for language in ["en", "zh-Hans"] {
            for dark in [false, true] {
                let model = PoolAppModel.demoModel(language: language)
                let suffix = "\(language)-\(dark ? "dark" : "light")"
                model.page = .accounts
                model.snapshot.accounts = Array(model.snapshot.accounts.prefix(2))
                model.snapshot.accounts[0].state = .subscriptionRequired
                model.snapshot.accounts[0].plan = "Free"
                model.snapshot.accounts[0].windows = []
                model.snapshot.accounts[1].windows[0] = .init(id: "five_hour", usedPercent: 96,
                    observedAt: model.now.addingTimeInterval(-3600), resetsAt: model.now.addingTimeInterval(-60))
                try await capture(MainWindow(model: model), size: .init(width: 640, height: 520), dark: dark,
                                  to: output.appendingPathComponent("free-expired-\(suffix).png"))
                model.snapshot.accounts = [.init(id: UUID(uuidString: "0a1b2c3d-1111-4aaa-8bbb-000000000005")!, state: .disabled)]
                model.snapshot.sessions = []
                try await capture(MainWindow(model: model), size: .init(width: 640, height: 520), dark: dark,
                                  to: output.appendingPathComponent("account-signin-pending-\(suffix).png"))
            }
        }
    }

    func testRenderPrivacyAndRoutingStates() async throws {
        guard let directory = ProcessInfo.processInfo.environment["CLAUDE_POOL_SCREENSHOTS"] else {
            throw XCTSkip("Use scripts/screenshots.sh to render inert demo screens.")
        }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        NSApplication.shared.setActivationPolicy(.accessory)
        for language in ["en", "zh-Hans"] {
            for dark in [false, true] {
                let suffix = "\(language)-\(dark ? "dark" : "light")"
                let model = PoolAppModel.demoModel(language: language)
                model.privacyPreview = .init(phase: .ready, text: "Contact {{PERSON_1}} at bob@acme.cn.", protectedCount: 2,
                    categories: [.init(id: "PERSON", title: "PERSON", count: 1), .init(id: "EMAIL", title: "EMAIL", count: 1)])
                try await capture(PrivacyDetailsSheet(model: model, initialText: "Contact Taylor at mi•••ella@example.com."), size: .init(width: 500, height: 500), dark: dark,
                                  to: output.appendingPathComponent("privacy-\(suffix).png"))
                let recording = PoolAppModel.demoModel(language: language)
                recording.fullLog = .init(on: true, storedBytes: 182 << 20, limitBytes: 6400 << 20)
                try await capture(PrivacyDetailsSheet(model: recording), size: .init(width: 640, height: 620), dark: dark,
                                  to: output.appendingPathComponent("privacy-recording-\(suffix).png"))
                recording.page = .settings
                try await capture(MainWindow(model: recording), size: .init(width: 680, height: 560), dark: dark,
                                  to: output.appendingPathComponent("settings-recording-\(suffix).png"))
                let unredacted = PoolAppModel.demoModel(language: language)
                unredacted.preferences.redaction = false
                try await capture(PrivacyDetailsSheet(model: unredacted), size: .init(width: 640, height: 620), dark: dark,
                                  to: output.appendingPathComponent("privacy-off-\(suffix).png"))
                unredacted.page = .settings; unredacted.settingsTab = .services
                try await capture(MainWindow(model: unredacted), size: .init(width: 680, height: 560), dark: dark,
                                  to: output.appendingPathComponent("settings-redaction-off-\(suffix).png"))
                let setup = PoolAppModel.demoModel(language: language, setup: true)
                setup.snapshot.executableReady = true
                setup.runtime = .init(phase: .ready, installedVersion: "2.1.301")
                setup.privacy = .init(phase: .installing, progress: 0.42)
                setup.isWorking = true
                try await capture(MainWindow(model: setup), size: .init(width: 640, height: 520), dark: dark,
                                  to: output.appendingPathComponent("privacy-setup-\(suffix).png"))
                model.page = .routing
                model.snapshot.sessions = [model.snapshot.sessions[0]]
                for state in ["idle", "attention", "masking", "ordered"] {
                    model.snapshot.mode = .running
                    model.snapshot.sessions[0].state = state == "attention" ? .attention : state == "idle" ? .idle : .running
                    model.privacy.isProcessing = state == "masking"
                    model.preferences.routingPolicy.strategy = state == "ordered" ? .ordered : .mostHeadroom
                    try await capture(MainWindow(model: model), size: .init(width: 640, height: 520), dark: dark,
                                      to: output.appendingPathComponent("routing-\(state)-\(suffix).png"))
                }
            }
        }
    }

    /// The template image as the menu bar tints it (black on light, white on dark), at 4x.
    private func renderMenuBar(_ figures: MenuBarFigures?, dark: Bool, to url: URL) throws {
        let figure = MenuBarFigure.image(figures)
        let scale: CGFloat = 4
        let size = NSSize(width: figure.size.width * scale + 24, height: figure.size.height * scale + 24)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
        NSRect(origin: .zero, size: size).fill()
        let tint = NSImage(size: figure.size, flipped: false) { rect in
            figure.draw(in: rect)
            (dark ? NSColor.white : NSColor.black).setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        tint.draw(in: NSRect(x: 12, y: 12, width: figure.size.width * scale, height: figure.size.height * scale))
        NSGraphicsContext.restoreGraphicsState()
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    private func capture<Content: View>(_ content: Content, size: NSSize, dark: Bool, to url: URL) async throws {
        let host = NSHostingView(rootView: content.environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: .init(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.frame = .init(origin: .zero, size: size)
        Self.windows.append(window)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: url)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        XCTAssertGreaterThan(png.count, 5000)
    }
}
