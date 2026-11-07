import Foundation
import PoolCore

/// Points Claude Desktop at the pool through Desktop's own third-party gateway settings, and puts
/// back what it had before. Desktop reads these files only as it starts:
///
///     Claude/claude_desktop_config.json      {"deploymentMode":"3p",…}
///     Claude-3p/claude_desktop_config.json   {"deploymentMode":"3p",…}
///     Claude-3p/configLibrary/<id>.json      {"inferenceProvider":"gateway","inferenceGatewayBaseUrl":…}
///     Claude-3p/configLibrary/_meta.json     {"appliedId":"<id>","entries":[…,{"id":"<id>","name":"Claude Pool"}]}
///
/// Nothing is written unless every file is a JSON object. Before the first write a private record
/// keeps what the files said, so Disconnect restores it; a value changed since, by Desktop or the
/// user, is theirs and stays. Only an explicit Connect or Disconnect writes these files.
public struct DesktopConnection: Sendable {
    /// Pool's profile in Desktop's configLibrary: a UUID like Desktop's own, its last part "clpool" in hex.
    public static let profileID = "00000000-0000-4000-8000-636c706f6f6c"
    public static let profileName = "Claude Pool"
    public enum Status: Equatable, Sendable {
        case disconnected, connected, changed
        /// Connected by an earlier Pool whose profile lacked what this one writes (tool search, Desktop home).
        case outdated
    }
    /// Desktop's own tool search, off by default in its gateway mode. Off, Desktop starts Claude
    /// Code with its experimental betas off, and every MCP tool's full schema goes with every
    /// request; on, the Code tab loads MCP tools through ToolSearch as they are needed.
    static let toolSearchKey = "toolSearchEnabled"
    /// Desktop's home in its gateway mode: `standard` shows Chat and Cowork in one view. Unset,
    /// Desktop decides from its older per-tab keys, which leave Chat off.
    static let desktopHomeKey = "desktopHome"
    static let addedKeys = [toolSearchKey, desktopHomeKey]

    let support, modeDirectory, threePDirectory, config, config3p, library, meta, profile, record: URL

    /// `record` is a private file in Pool's own workspace.
    public init(home: URL, record: URL) {
        support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        modeDirectory = support.appendingPathComponent("Claude", isDirectory: true)
        threePDirectory = support.appendingPathComponent("Claude-3p", isDirectory: true)
        config = modeDirectory.appendingPathComponent("claude_desktop_config.json")
        config3p = threePDirectory.appendingPathComponent("claude_desktop_config.json")
        library = threePDirectory.appendingPathComponent("configLibrary", isDirectory: true)
        meta = library.appendingPathComponent("_meta.json")
        profile = library.appendingPathComponent(Self.profileID + ".json")
        self.record = record
    }

    struct Record: Codable, Equatable {
        var mode: String?
        var mode3p: String?
        var appliedID: String?
        /// Files and folders that were not there before the first Connect.
        var made: [String]
        /// When Connect last changed what Desktop reads; a Desktop started before needs a restart.
        var connectedAt: Date
    }

    public static func baseURL(port: UInt16) -> String { "http://127.0.0.1:\(port)" }

    /// When Connect last changed what Desktop reads; nil when Pool did not connect it.
    public var connectedAt: Date? { (try? loadRecord())?.connectedAt }

    /// Whether Desktop, as its files say now, starts on the pool at `baseURL` with `token`.
    public func status(baseURL: String, token: String) -> Status {
        let meta = (try? object(self.meta)) ?? [:]
        let ours = (meta["entries"]?.arrayValue ?? []).contains(where: Self.isOurs)
        let applied = meta["appliedId"]?.stringValue.flatMap { id -> [String: JSONValue]? in
            guard Self.safeID(id) else { return nil }
            return try? object(library.appendingPathComponent(id + ".json"))
        }
        let reaches = applied.map { reachesPool($0, baseURL: baseURL, token: token) } ?? false
        guard ours || (try? loadRecord()) != nil else {
            // A profile imported by hand before Pool connected Desktop itself also reaches the pool.
            return reaches ? .connected : .disconnected
        }
        guard reaches else { return .changed }
        // A value the user set in Desktop, false too, is theirs; only a profile without one is old.
        let profile = (try? object(self.profile)) ?? [:]
        let missing = Self.addedKeys.contains { profile[$0] == nil }
        return meta["appliedId"] == .string(Self.profileID) && missing ? .outdated : .connected
    }

    /// Writes Pool's profile, applies it and starts Desktop in its gateway mode. Returns whether
    /// anything Desktop reads changed, in which case a running Desktop needs a restart.
    @discardableResult
    public func connect(baseURL: String, token: String, now: Date) throws -> Bool {
        var config = try object(self.config), config3p = try object(self.config3p)
        var profile = try object(self.profile), meta = try object(self.meta)
        guard meta["entries"] == nil || meta["entries"]?.arrayValue != nil else { throw DesktopConnectionError.unreadable(self.meta.lastPathComponent) }
        let earlier = try loadRecord()
        var record = earlier ?? {
            let made = [modeDirectory, self.config, threePDirectory, self.config3p, library, self.meta]
                .filter { !FileManager.default.fileExists(atPath: $0.path) }.map(\.path)
            return Record(mode: config["deploymentMode"]?.stringValue, mode3p: config3p["deploymentMode"]?.stringValue,
                          appliedID: meta["appliedId"]?.stringValue, made: made, connectedAt: now)
        }()
        try saveRecord(record)
        var written: [String: Bool] = [:]

        // Settings the user made in Desktop for this profile stay; the address and key are Pool's.
        profile["inferenceProvider"] = .string("gateway")
        profile["inferenceGatewayBaseUrl"] = .string(baseURL)
        profile["inferenceGatewayAuthScheme"] = .string("bearer")
        // A key Desktop sealed cannot be compared here; writing it in the clear again is harmless,
        // Desktop seals it at its next start.
        profile["inferenceGatewayApiKey"] = .string(token)
        if profile["disableDeploymentModeChooser"] == nil { profile["disableDeploymentModeChooser"] = .bool(true) }
        if profile[Self.toolSearchKey] == nil { profile[Self.toolSearchKey] = .bool(true) }
        if profile[Self.desktopHomeKey] == nil { profile[Self.desktopHomeKey] = .string("standard") }
        var changed = try write(profile, to: self.profile, privately: true)
        written[self.profile.lastPathComponent] = changed

        var entries = meta["entries"]?.arrayValue ?? []
        if !entries.contains(where: Self.isOurs) {
            entries.append(.object(["id": .string(Self.profileID), "name": .string(Self.profileName)]))
        }
        meta["entries"] = .array(entries); meta["appliedId"] = .string(Self.profileID)
        let metaChanged = try write(meta, to: self.meta); written["meta"] = metaChanged; changed = metaChanged || changed

        // The mode last: until here Desktop still starts as it did.
        config3p["deploymentMode"] = .string("3p"); let mode3pChanged = try write(config3p, to: self.config3p)
        config["deploymentMode"] = .string("3p"); let modeChanged = try write(config, to: self.config)
        written["config-3p"] = mode3pChanged; written["config"] = modeChanged
        changed = changed || mode3pChanged || modeChanged
        if changed { record.connectedAt = now; try saveRecord(record) }
        // What Desktop had and what Pool wrote, by file and key; the gateway key is never recorded.
        Diagnostics.record("desktop.connected", ["changed": changed ? "yes" : "no", "first": earlier == nil ? "yes" : "no",
                                                 "mode_was": record.mode ?? "-", "mode3p_was": record.mode3p ?? "-",
                                                 "files_changed": String(written.values.filter { $0 }.count)])
        DevRecord.record(.events, "desktop.connected") {
            ["kept_before": DevRecord.value(record), "written": .object(written.mapValues(JSONValue.bool)),
             "profile_keys": .array(profile.keys.sorted().map(JSONValue.string)), "base_url": .string(baseURL)]
        }
        return changed
    }

    /// Takes Pool out of Desktop's settings and puts back what was there before Connect. Returns
    /// whether anything Desktop reads changed.
    @discardableResult
    public func disconnect() throws -> Bool {
        let record = try loadRecord()
        var meta = try object(self.meta)
        var entries = meta["entries"]?.arrayValue ?? []
        let ours = entries.contains(where: Self.isOurs)
        guard record != nil || ours else { return false }
        var changed = false
        for (url, was) in [(config, record?.mode), (config3p, record?.mode3p)] {
            var object = try self.object(url)
            guard object["deploymentMode"] == .string("3p") else { continue } // changed since: theirs
            object["deploymentMode"] = was.map(JSONValue.string)
            changed = try write(object, to: url) || changed
        }
        if ours {
            entries.removeAll(where: Self.isOurs)
            meta["entries"] = entries.isEmpty && record?.made.contains(self.meta.path) == true ? nil : .array(entries)
        }
        if meta["appliedId"] == .string(Self.profileID) {
            // The profile applied before, if it is still there, else the first one left, else none.
            let ids = entries.compactMap { $0["id"]?.stringValue }
            if let was = record?.appliedID, was != Self.profileID, ids.contains(was) { meta["appliedId"] = .string(was) }
            else { meta["appliedId"] = ids.first.map(JSONValue.string) }
        }
        if FileManager.default.fileExists(atPath: self.meta.path) { changed = try write(meta, to: self.meta) || changed }
        if FileManager.default.fileExists(atPath: profile.path) { try FileManager.default.removeItem(at: profile); changed = true }
        // What Pool made, deepest first: a file only if it is an empty object now, a folder only if empty.
        for path in (record?.made ?? []).sorted(by: { $0.count > $1.count }) where path.hasPrefix(support.path + "/") {
            let url = URL(fileURLWithPath: path)
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &directory) else { continue }
            if directory.boolValue {
                if (try? FileManager.default.contentsOfDirectory(atPath: path))?.isEmpty == true { try? FileManager.default.removeItem(at: url) }
            } else if (try? object(url))?.isEmpty == true {
                try? FileManager.default.removeItem(at: url)
            }
        }
        if record != nil { try FileManager.default.removeItem(at: self.record) }
        Diagnostics.record("desktop.disconnected", ["changed": changed ? "yes" : "no", "had_record": record == nil ? "no" : "yes",
                                                    "mode_restored": record?.mode ?? "-", "mode3p_restored": record?.mode3p ?? "-"])
        DevRecord.record(.events, "desktop.disconnected") {
            ["restored_from": record.map { DevRecord.value($0) } ?? .null, "applied_now": meta["appliedId"] ?? .null,
             "profiles_left": .number(Double(entries.count))]
        }
        return changed
    }

    private func reachesPool(_ profile: [String: JSONValue], baseURL: String, token: String) -> Bool {
        func trimmed(_ url: String) -> String { url.hasSuffix("/") ? String(url.dropLast()) : url }
        guard profile["inferenceProvider"] == .string("gateway"),
              let url = profile["inferenceGatewayBaseUrl"]?.stringValue, trimmed(url) == trimmed(baseURL),
              let key = profile["inferenceGatewayApiKey"]?.stringValue,
              key == token || Self.sealed(key) else { return false }
        // Desktop starts in its gateway mode when the profile hides the chooser, otherwise unless
        // Claude-3p's own file says "1p".
        if profile["disableDeploymentModeChooser"] == .bool(true) { return true }
        return (try? object(config3p))?["deploymentMode"] != .string("1p")
    }

    /// Desktop seals profile secrets at rest with the user's keychain; Pool never opens them, so a
    /// sealed key is unknown rather than changed.
    private static func sealed(_ key: String) -> Bool { key.drop(while: \.isWhitespace).hasPrefix("__sealed__:") }
    private static func isOurs(_ entry: JSONValue) -> Bool { entry["id"]?.stringValue == profileID }
    private static func safeID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && !id.hasPrefix(".") && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }

    /// The object in a file, empty when the file is missing or blank. Anything else is not Pool's to rewrite.
    private func object(_ url: URL) throws -> [String: JSONValue] {
        guard let data = try read(url) else { return [:] }
        if data.allSatisfy({ [9, 10, 13, 32].contains($0) }) { return [:] }
        guard let object = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue else {
            throw DesktopConnectionError.unreadable(url.lastPathComponent)
        }
        return object
    }
    private func read(_ url: URL) throws -> Data? {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { throw DesktopConnectionError.unsafePath }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count <= 8 * 1024 * 1024 else { throw DesktopConnectionError.unreadable(url.lastPathComponent) }
        return data
    }
    /// Writes only when the content differs, keeping the file's permissions; returns whether it wrote.
    private func write(_ object: [String: JSONValue], to url: URL, privately: Bool = false) throws -> Bool {
        if let existing = try read(url), let old = try? JSONDecoder().decode(JSONValue.self, from: existing), old == .object(object) {
            return false
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(JSONValue.object(object)); data.append(10)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let mode = privately ? 0o600 : (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? 0o644
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        return true
    }
    private func loadRecord() throws -> Record? {
        guard let data = try read(record) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let value = try? decoder.decode(Record.self, from: data) else { throw DesktopConnectionError.unreadable(record.lastPathComponent) }
        return value
    }
    private func saveRecord(_ value: Record) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = .sortedKeys
        try FileManager.default.createDirectory(at: record.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: record, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: record.path)
    }
}

public enum DesktopConnectionError: Error, Equatable, Sendable {
    /// A Desktop settings file is not a JSON object; nothing was written.
    case unreadable(String)
    case unsafePath
}
