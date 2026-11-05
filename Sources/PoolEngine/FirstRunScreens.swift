import Foundation

/// Answers the official client's first-run screens in an app-owned account folder, as a person
/// would on first launch: the default text style, the security notes, skipping terminal setup and
/// browser tools, and trusting the app's own working folder. No other folder is ever run.
/// Sign-in, permission, usage-credit and every other prompt are never answered here.
/// Screen wording follows Claude Code 2.1.316 and later; a key is sent only after its screen has
/// stayed drawn briefly, because a key sent while a screen is first drawn can be lost.
public struct FirstRunScreens: Sendable {
    public enum Outcome: Equatable, Sendable {
        case none
        case send(Data)
        /// The client asks to sign in. Only the user can do that.
        case signInRequired
        /// A first-run screen kept returning after it was answered.
        case stuck
    }

    private static let settle: TimeInterval = 0.3
    private static let tries = 3
    private var shownAt: [String: Date] = [:]
    private var pressed: [String: Int] = [:]
    private var lastDown = Date.distantPast

    public init() {}

    /// Whether a first-run or sign-in screen is drawn: its own "❯" choice is not the input box
    /// (these are matched before the prompt).
    public static func isShowing(_ screen: String) -> Bool {
        let lower = screen.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        return ["select login method", "log in with your claude account", "claude.ai/oauth/authorize", "trust this folder",
                "keep browser tools off", "choose the text style"].contains(where: lower.contains) ||
            (lower.contains("security notes:") && lower.contains("press enter to continue")) ||
            (lower.contains("terminal setup?") && lower.contains("esc to skip"))
    }

    public mutating func respond(to screen: String, at now: Date) -> Outcome {
        let words = screen.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let lower = words.lowercased()
        if ["select login method", "log in with your claude account", "claude.ai/oauth/authorize"].contains(where: lower.contains) {
            return .signInRequired
        }
        if lower.contains("trust this folder") { return trust(words, at: now) }
        if lower.contains("security notes:"), lower.contains("press enter to continue") { return answer("notes", "\r", at: now) }
        if lower.contains("terminal setup?"), lower.contains("esc to skip") { return answer("terminal", "\u{1B}", at: now) }
        if lower.contains("keep browser tools off") { return answer("browser", "\u{1B}", at: now) }
        if lower.contains("choose the text style") { return answer("theme", "\r", at: now) }
        shownAt.removeAll()
        return .none
    }

    private mutating func answer(_ screen: String, _ key: String, at now: Date) -> Outcome {
        guard let shown = shownAt[screen] else { shownAt = [screen: now]; return .none }
        guard now.timeIntervalSince(shown) >= Self.settle else { return .none }
        guard pressed[screen, default: 0] < Self.tries else { return .stuck }
        pressed[screen, default: 0] += 1
        shownAt.removeValue(forKey: screen)
        return .send(Data(key.utf8))
    }

    /// Moves the selection to "Yes, I trust this folder" before pressing Return on it.
    private mutating func trust(_ words: String, at now: Date) -> Outcome {
        let yes = words.range(of: "❯ Yes, I trust", options: [.backwards, .caseInsensitive])?.lowerBound
        let no = words.range(of: "❯ No, exit", options: [.backwards, .caseInsensitive])?.lowerBound
        if let yes, no.map({ yes > $0 }) ?? true { return answer("trust", "\r", at: now) }
        shownAt.removeValue(forKey: "trust")
        guard no != nil, now.timeIntervalSince(lastDown) >= 1 else { return .none }
        lastDown = now
        return .send(Data("\u{1B}[B".utf8))
    }
}
