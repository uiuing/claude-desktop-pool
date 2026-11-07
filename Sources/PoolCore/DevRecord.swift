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
        /// Redaction: each request as received and as sent, what was found and by what, put back.
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

    public static func install(_ newSink: Sink?) { lock.withLock { sink = newSink } }
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
    public static func string(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
    public static func number(_ value: Int?) -> JSONValue { value.map { .number(Double($0)) } ?? .null }
}
