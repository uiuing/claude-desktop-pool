import Foundation

/// The developer recording: everything Pool received and sent at its boundaries, with what it
/// decided and why, for the developer to follow one run end to end on their own Mac. It is off
/// unless the person turns it on in Settings › General (the full log); with no sink installed every call returns at once and
/// its payload closure never runs. Records hold conversation words, so they go only to the app's
/// private recording folder, never into `pool.log`, diagnostics or anything sent anywhere. Pool's
/// own credentials (the gateway key, request headers that carry it) are never recorded.
public enum DevRecord {
    /// Where a record is kept: each channel has its own folder and size limit.
    public enum Channel: String, CaseIterable, Sendable {
        /// Redaction: what was found in each request and by what, each replacement in its context, put back.
        case privacy
        /// The gateway's bytes: requests from the client and every byte written back.
        case http
        /// Each official session: terminal bytes both ways, the reply stream, transcript and hook files.
        case session
        /// Decisions and states: every `Diagnostics` line, and decisions with their inputs.
        case events
    }
    public struct Entry: Sendable {
        public let channel: Channel
        public let line: Data
    }
    public typealias Sink = @Sendable (Entry) -> Void
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sink: Sink?
    nonisolated(unsafe) private static var sequence: UInt64 = 0
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    /// The gateway request a record was made for, carried down the tasks serving it, so the
    /// redaction, routing and session records of one request carry its number.
    @TaskLocal public static var request: String?
    /// This launch: request numbers and `seq` start again at each launch, so a record names its launch.
    public static let launch = String(UUID().uuidString.lowercased().prefix(8))

    public static func install(_ newSink: Sink?) { lock.withLock { sink = newSink }; forgetThreads() }
    public static var isOn: Bool { lock.withLock { sink != nil } }

    /// One record: `kind` names it ("http.request", "privacy.prepared"), `ids` are the ids that
    /// join it to other records (run, account, conversation), and `data` is what happened. `data`
    /// is evaluated only while recording is on.
    public static func record(_ channel: Channel, _ kind: String, _ ids: KeyValuePairs<String, String> = [:],
                              _ data: () -> [String: JSONValue] = { [:] }) {
        guard let sink = lock.withLock({ sink }) else { return }
        var object: [String: JSONValue] = [
            "v": .number(1), "launch": .string(launch), "kind": .string(kind), "t": .string(formatter.string(from: Date())),
            "mono_ns": .number(Double(DispatchTime.now().uptimeNanoseconds)),
        ]
        if let request { object["req"] = .string(request) }
        for (key, value) in ids { object[key] = .string(value) }
        let body = data()
        if !body.isEmpty { object["data"] = .object(body) }
        // The number is taken last and under the lock, so it orders records as they were made.
        lock.withLock {
            sequence += 1
            object["seq"] = .number(Double(sequence))
            guard var line = try? JSONEncoder().encode(JSONValue.object(object)) else { return }
            line.append(10)
            sink(Entry(channel: channel, line: line))
        }
    }

    /// Bytes as they were: text when they are UTF-8, else base64, so a record can be replayed.
    public static func bytes(_ data: Data) -> JSONValue {
        if let text = String(data: data, encoding: .utf8) { return .object(["text": .string(text)]) }
        return .object(["base64": .string(data.base64EncodedString())])
    }
    /// Any encodable value as JSON, or a note that it could not be encoded.
    public static func value<T: Encodable>(_ value: T) -> JSONValue {
        guard let data = try? JSONEncoder().encode(value), let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .string("<unencodable \(String(describing: T.self))>")
        }
        return json
    }
    /// What each conversation thread's last record held: a digest per message, and of its instructions and tools.
    private struct Thread { var messages: [UInt64]; var system: UInt64; var tools: UInt64; var used: UInt64 }
    private static let threadLock = NSLock()
    nonisolated(unsafe) private static var threads: [String: Thread] = [:]
    nonisolated(unsafe) private static var threadUse: UInt64 = 0
    private static let threadsMost = 512
    /// A conversation as a change from the last record of the same `thread` (a client session's requests
    /// of one shape, or what one run was told), so a long conversation is not kept again at every turn:
    /// `kept` is how many leading messages are the thread's last record's, `messages` the rest, and
    /// instructions and tools are `"same"` while they have not changed. Cache marks, which move from
    /// turn to turn, are not compared. `scripts/dev-timeline.py` rebuilds each whole request.
    public static func conversation(_ thread: String, messages: [JSONValue], system: JSONValue?, tools: JSONValue?) -> JSONValue {
        let digests = messages.map(digest), systemDigest = digest(system ?? .null), toolsDigest = digest(tools ?? .null)
        let previous: Thread? = threadLock.withLock {
            let last = threads[thread]
            threadUse += 1
            threads[thread] = Thread(messages: digests, system: systemDigest, tools: toolsDigest, used: threadUse)
            if threads.count > threadsMost, let oldest = threads.min(by: { $0.value.used < $1.value.used }) { threads.removeValue(forKey: oldest.key) }
            return last
        }
        var kept = 0
        if let previous { while kept < min(previous.messages.count, digests.count), previous.messages[kept] == digests[kept] { kept += 1 } }
        var object: [String: JSONValue] = ["thread": .string(Diagnostics.tag(thread)), "count": .number(Double(messages.count)), "kept": .number(Double(kept)),
                                           "messages": shared(Array(messages[kept...]), digests: Array(digests[kept...])),
                                           "system": previous?.system == systemDigest ? .string("same") : system ?? .null]
        if previous?.tools == toolsDigest { object["tools"] = .string("same") }
        else if case .array(let list)? = tools { object["tools"] = shared(list, digests: list.map(digest)) }
        else { object["tools"] = tools ?? .null }
        return .object(object)
    }
    /// Large items already recorded in this recording, by digest: a resumed conversation, or the tool
    /// definitions Desktop counts one request at a time, are kept once and named after.
    nonisolated(unsafe) private static var recordedItems: Set<UInt64> = []
    private static let sharedFrom = 1024, recordedItemsMost = 1 << 16
    /// An item of 1 KB or more recorded before is `{"same_as": "<digest>"}`; one recorded for the first
    /// time is kept with `{"as": "<digest>", "item": ...}`, so a reader can put the later ones back.
    private static func shared(_ items: [JSONValue], digests: [UInt64]) -> JSONValue {
        .array(zip(items, digests).map { item, digest in
            let size = (try? JSONEncoder().encode(item).count) ?? 0
            guard size >= sharedFrom else { return item }
            let name = String(digest, radix: 16)
            let seen = threadLock.withLock { () -> Bool in
                if recordedItems.contains(digest) { return true }
                if recordedItems.count >= recordedItemsMost { recordedItems = [] }
                recordedItems.insert(digest); return false
            }
            return seen ? .object(["same_as": .string(name)]) : .object(["as": .string(name), "item": item])
        })
    }
    /// Forgets every thread and recorded item, so the next record of each holds it whole (a new recording, or a test).
    public static func forgetThreads() { threadLock.withLock { threads = [:]; recordedItems = [] } }
    private static func digest(_ value: JSONValue) -> UInt64 {
        func uncached(_ value: JSONValue) -> JSONValue {
            switch value {
            case .object(let fields): return .object(fields.filter { $0.key != "cache_control" }.mapValues(uncached))
            case .array(let items): return .array(items.map(uncached))
            default: return value
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in (try? encoder.encode(uncached(value))) ?? Data() { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return hash
    }
    /// `value` with each string longer than `longest` characters replaced by `"<N chars #digest>"`: its
    /// shape and short fields, for a record whose words another record already keeps.
    public static func outline(_ value: JSONValue, longest: Int = 200) -> JSONValue {
        switch value {
        case .object(let fields): return .object(fields.mapValues { outline($0, longest: longest) })
        case .array(let items): return .array(items.map { outline($0, longest: longest) })
        case .string(let text) where text.count > longest: return .string("<\(text.count) chars #\(String(digest(value), radix: 16))>")
        default: return value
        }
    }
    public static func string(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
    public static func number(_ value: Int?) -> JSONValue { value.map { .number(Double($0)) } ?? .null }
}
