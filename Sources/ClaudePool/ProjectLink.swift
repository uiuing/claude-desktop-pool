import AppKit

/// The project's public home, linked from the sidebar, the menu bar panel, Settings and the Help menu.
enum ProjectLink {
    static let repository = URL(string: "https://github.com/uiuing/claude-desktop-pool")!
    static let issues = repository.appendingPathComponent("issues")
    static let releases = repository.appendingPathComponent("releases/latest")
    static let symbol = "chevron.left.forwardslash.chevron.right"
    static func open(_ url: URL = repository) { NSWorkspace.shared.open(url) }
}
