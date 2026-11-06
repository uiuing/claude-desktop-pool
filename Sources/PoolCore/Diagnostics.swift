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

    /// How an id Pool made itself (an account, a run) is written in every line: the first eight
    /// characters of its UUID in lower case, as its folder and its client's session file are named,
    /// so one run or account can be followed across all events and found on disk.
    public static func id(_ value: UUID) -> String { String(value.uuidString.lowercased().prefix(8)) }

    /// A thing's recent steps, kept in memory and written out only when it goes wrong (a failure,
    /// a stall, an unexpected end): the lead-up to a problem is in the log the first time it
    /// happens, without logging every step of every healthy run. Steps are fixed names and counts,
    /// never content.
    public struct Trace: Sendable {
        private var steps: [(at: Date, step: String)] = []
        private let capacity: Int
        /// When anything last happened, a step or not (a streamed delta touches without a step).
        public private(set) var lastActivity: Date
        public init(capacity: Int = 64, now: Date = Date()) { self.capacity = max(1, capacity); lastActivity = now }
        public mutating func note(_ step: String, at date: Date = Date()) {
            steps.append((date, step)); if steps.count > capacity { steps.removeFirst(steps.count - capacity) }
            lastActivity = max(lastActivity, date)
        }
        public mutating func touch(at date: Date = Date()) { lastActivity = max(lastActivity, date) }
        /// Steps oldest first, each as `name@-seconds` before `now`, in lines short enough for a field.
        public func chunks(now: Date = Date(), width: Int = 150) -> [String] {
            var lines: [String] = [], line = ""
            for (at, step) in steps {
                let item = token(step) + "@-" + String(format: "%.1f", max(0, now.timeIntervalSince(at)))
                if !line.isEmpty, line.count + item.count + 1 > width { lines.append(line); line = "" }
                line += (line.isEmpty ? "" : ",") + item
            }
            if !line.isEmpty { lines.append(line) }
            return lines
        }
    }
    /// Writes `trace` after an event that needs its lead-up: `<event>.trace` lines with the same
    /// `subject` field, numbered, so the steps sit right under the line that explains them.
    public static func dump(_ event: String, subject: (String, String), why: String, trace: Trace, now: Date = Date()) {
        let chunks = trace.chunks(now: now)
        for (index, chunk) in chunks.enumerated() {
            record(event + ".trace", [subject.0: subject.1, "why": why, "part": "\(index + 1)/\(chunks.count)", "steps": chunk])
        }
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
