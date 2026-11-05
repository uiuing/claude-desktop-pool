import Foundation

/// What Pool did, one line per decision, never what was said: lines carry
/// counts, sizes, timings, ids Pool made itself and a stable reason, and never message, system or
/// tool text, tool names or inputs, terminal screens, emails, tokens or paths into a person's
/// projects. The app installs a private, rotated file sink at launch; without one nothing is kept.
public enum Diagnostics {
    public typealias Sink = @Sendable (String) -> Void
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sink: Sink?

    public static func install(_ newSink: Sink?) { lock.withLock { sink = newSink } }

    /// `event` is a short dotted name ("gateway.request", "session.failed"); field values are
    /// reduced to one bounded token each, so a value can never span lines or forge a field.
    public static func record(_ event: String, _ fields: KeyValuePairs<String, String> = [:]) {
        guard let sink = lock.withLock({ sink }) else { return }
        var line = "event=" + token(event)
        for (key, value) in fields { line += " " + token(key) + "=" + token(value) }
        sink(line)
    }

    /// A short, stable, non-reversible tag for an id that may carry client words (a conversation key).
    public static func tag(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(hash, radix: 16)
    }

    static func token(_ value: String) -> String {
        let cleaned = value.unicodeScalars.map { scalar -> Character in
            if scalar.value < 33 || scalar.value == 127 || scalar == "\"" || scalar == "=" { return "_" }
            return Character(scalar)
        }
        let text = String(cleaned.prefix(160))
        return text.isEmpty ? "-" : text
    }
}
