import Foundation

/// Tells the official client's usage-credits screens apart from a reply that merely talks about
/// them. Pool never answers such a screen: the caller closes it with Esc and treats the model's
/// weekly limit as used up on this account. Only the plain text of the drawn screen is read
/// (the client's escapes already taken out) and only two places of it count:
///
/// - the choice list, in the dialog area only (under the last rule): a selection row marked "❯" that is one of the list's own options, together
///   with a second option of the list, one of them only this list has ("Continue with {Model}",
///   "Yes, re-enable and continue", "No, keep my current model"), or with its header ("... uses usage credits", "... runs on usage
///   credits", "Usage credits are turned off", "You've used your included {Model} usage ...");
/// - the footer: the lines under the input box's last rule, where the client puts its notices
///   ("{Model} requires usage credits", "You've reached your {Model} limit", "{Model} is now using
///   usage credits instead of your plan limits").
///
/// A sentence in the reply's body (above the input box) is never enough.
enum UsageCreditsScreen {
    enum Finding: Equatable {
        /// The client asks whether to go on with usage credits.
        case choice(family: String?)
        /// The model cannot be used without usage credits.
        case required(family: String?)
        /// The reply already runs on usage credits.
        case spending(family: String?)
    }

    static let families = ["fable", "haiku", "mythos", "opus", "sonnet"]

    private static let marks: Set<Character> = ["❯"]
    private static let strongOptions = ["continue with ", "yes, re-enable and continue", "no, keep my current model"]
    private static let options = strongOptions + [
        "yes, buy usage credits", "buy usage credits", "set up usage credits on claude.ai", "manage usage credits on claude.ai",
        "request usage credits from your admin", "request more from your admin", "upgrade to max"]
    private static let headers = ["uses usage credits", "runs on usage credits", "usage credits are turned off",
                                  "don't have usage credits yet", "don’t have usage credits yet", "used your included"]

    static func look(at screen: String) -> Finding? {
        let lines = screen.components(separatedBy: "\n").map(squeeze)
        if let family = choice(in: lines) { return .choice(family: family.value) }
        let footer = footerText(lines).lowercased()
        guard !footer.isEmpty else { return nil }
        if let family = match(footer, #"\b(fable|haiku|mythos|opus|sonnet)\b[^·\n]{0,40}? is (?:now using|drawing from) usage credits"#) { return .spending(family: family.value) }
        if let family = match(footer, #"\b(fable|haiku|mythos|opus|sonnet)\b[^·\n]{0,40}? requires usage credits"#)
            ?? match(footer, #"only allows (fable|haiku|mythos|opus|sonnet), which requires usage credits"#)
            ?? match(footer, #"reached your (fable|haiku|mythos|opus|sonnet)\b[^·\n]{0,20}? limit"#)
            ?? match(footer, #"used your included (fable|haiku|mythos|opus|sonnet) usage"#) { return .required(family: family.value) }
        return nil
    }

    private static func squeeze(_ line: String) -> String {
        line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func isRule(_ line: String) -> Bool {
        line.count >= 3 && line.allSatisfy { $0 == "─" || $0 == "━" || $0 == "═" || $0 == "-" }
    }

    /// What is drawn under the input box's last rule, as one text (a notice may wrap).
    private static func footerText(_ lines: [String]) -> String { footerLines(lines).joined(separator: " ") }

    private static func footerLines(_ lines: [String]) -> [String] {
        guard let rule = lines.lastIndex(where: isRule) else { return [] }
        return lines[(rule + 1)...].filter { !$0.isEmpty }
    }

    /// The model family a choice list is about (nil inside when it names none), or nil when no choice list is drawn.
    private static func choice(in lines: [String]) -> Box? {
        // Only the dialog area counts: what is drawn under the last rule. A user's message ("> ...")
        // and a numbered list in the reply sit above the input box's rule and are never options.
        let tail = Array(footerLines(lines))
        var selected = false, strong = false, count = 0
        for line in tail {
            var text = Substring(line)
            var marked = false
            if let first = text.first, marks.contains(first) { marked = true; text = text.dropFirst().drop { $0 == " " } }
            if let dot = text.firstIndex(where: { $0 == "." || $0 == ")" }), text[text.startIndex..<dot].allSatisfy(\.isNumber), !text[text.startIndex..<dot].isEmpty {
                text = text[text.index(after: dot)...].drop { $0 == " " }
            }
            let lower = text.lowercased()
            guard options.contains(where: lower.hasPrefix) else { continue }
            count += 1
            if marked { selected = true }
            if strongOptions.contains(where: lower.hasPrefix) { strong = true }
        }
        let joined = tail.joined(separator: " ").lowercased()
        guard selected, (strong && count >= 2) || headers.contains(where: joined.contains) else { return nil }
        let family = match(joined, #"used your included (fable|haiku|mythos|opus|sonnet) usage"#)
            ?? match(joined, #"continuing on [^·\n]{0,40}?\b(fable|haiku|mythos|opus|sonnet)\b[^·\n]{0,20}? uses usage credits"#)
            ?? match(joined, #"\b(fable|haiku|mythos|opus|sonnet)\b[^·\n]{0,20}? runs on usage credits"#)
            ?? match(joined, #"continue with [^·\n]{0,20}?\b(fable|haiku|mythos|opus|sonnet)\b"#)
            ?? match(joined, #"re-enable to use [^·\n]{0,20}?\b(fable|haiku|mythos|opus|sonnet)\b"#)
        return Box(value: family?.value)
    }

    private struct Box { var value: String? }

    private static func match(_ text: String, _ pattern: String) -> Box? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(found.range(at: found.numberOfRanges - 1), in: text) else { return nil }
        return Box(value: String(text[range]))
    }
}
