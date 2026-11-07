import Foundation
import Darwin
import PoolCore

/// Writes the developer recording (`DevRecord`): one folder per channel under `root`, each a run of
/// JSON-lines files cut at `fileLimit`, the oldest removed once the channel passes its limit. Folders
/// are 0700 and files 0600. Writing happens on one background queue: a record waits for nothing,
/// and when the queue holds more than `backlogLimit` bytes, records are dropped and counted, never
/// slowing a request. A failed write stops the recording and says so in `pool.log`.
public final class DeveloperRecorder: @unchecked Sendable {
    public typealias Channel = DevRecord.Channel
    /// Default limit per channel; redaction keeps the most.
    public static let defaultLimits: [Channel: Int] = [.privacy: 4096 << 20, .http: 1024 << 20, .session: 1024 << 20, .events: 256 << 20]
    public static let fileLimit = 16 << 20
    public static let backlogLimit = 64 << 20

    public let root: URL
    public let limits: [Channel: Int]
    private let fileLimit: Int
    private let queue = DispatchQueue(label: "claude-pool.developer-recording", qos: .utility)
    private let lock = NSLock()
    private var backlog = 0
    private var dropped = 0
    private var stopped = false
    private var files: [Channel: (handle: FileHandle, size: Int)] = [:]
    private let stamp: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"; return f
    }()

    public init(root: URL, limits: [Channel: Int] = DeveloperRecorder.defaultLimits, fileLimit: Int = DeveloperRecorder.fileLimit) {
        self.root = root; self.fileLimit = max(1024, fileLimit)
        var merged = Self.defaultLimits
        for (channel, limit) in limits { merged[channel] = max(self.fileLimit, limit) }
        self.limits = merged
    }

    public func directory(_ channel: Channel) -> URL { root.appendingPathComponent(channel.rawValue, isDirectory: true) }

    /// Makes the folders and installs this recorder as `DevRecord`'s sink.
    public func install() throws {
        try Self.makePrivateDirectory(root)
        for channel in Channel.allCases { try Self.makePrivateDirectory(directory(channel)) }
        DevRecord.install { [weak self] entry in self?.take(entry) }
        Diagnostics.record("devrecord.started", ["limits_mb": Channel.allCases.map { "\($0.rawValue):\((limits[$0] ?? 0) >> 20)" }.joined(separator: ",")])
    }

    /// Stops recording; what is queued is still written.
    public func uninstall() {
        DevRecord.install(nil)
        queue.sync { closeAll() }
        Diagnostics.record("devrecord.stopped", ["why": "turned_off"])
    }

    /// Waits for what is queued to be written.
    public func flush() { queue.sync {} }

    /// Removes every recorded file. Recording, if on, goes on in new files.
    public func deleteAll() {
        queue.sync {
            closeAll()
            for channel in Channel.allCases {
                for file in recordFiles(channel) { unlink(file.path) }
            }
        }
    }

    /// What the recording holds on disk now, in bytes.
    public func totalBytes() -> Int {
        queue.sync { Channel.allCases.reduce(0) { total, channel in total + recordFiles(channel).reduce(0) { $0 + size($1) } } }
    }

    private func take(_ entry: DevRecord.Entry) {
        let count = entry.line.count
        let accepted: Bool = lock.withLock {
            guard !stopped else { return false }
            if backlog + count > Self.backlogLimit { dropped += 1; return false }
            backlog += count; return true
        }
        guard accepted else { return }
        queue.async { [self] in
            lock.withLock { backlog -= count }
            let lost = lock.withLock { () -> Int in defer { dropped = 0 }; return dropped }
            if lost > 0, let note = Self.droppedLine(lost) { write(note, to: .events) }
            write(entry.line, to: entry.channel)
        }
    }

    private func write(_ line: Data, to channel: Channel) {
        guard !lock.withLock({ stopped }) else { return }
        do {
            if let open = files[channel], open.size + line.count > fileLimit {
                try? open.handle.close(); files[channel] = nil
            }
            if files[channel] == nil { trim(channel); files[channel] = (try openFile(channel), 0) }
            try files[channel]!.handle.write(contentsOf: line)
            files[channel]!.size += line.count
        } catch {
            lock.withLock { stopped = true }
            closeAll()
            DevRecord.install(nil)
            Diagnostics.record("devrecord.stopped", ["why": "write_failed", "channel": channel.rawValue])
        }
    }

    private func openFile(_ channel: Channel) throws -> FileHandle {
        try Self.makePrivateDirectory(directory(channel))
        let name = channel.rawValue + "-" + stamp.string(from: Date()) + "-" + String(UUID().uuidString.prefix(4)).lowercased() + ".jsonl"
        let path = directory(channel).appendingPathComponent(name).path
        let fd = Darwin.open(path, O_WRONLY | O_APPEND | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RuntimeError.storageFailure }
        fchmod(fd, 0o600)
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Removes the oldest closed files until the channel is within its limit, keeping room for a new file.
    private func trim(_ channel: Channel) {
        let limit = limits[channel] ?? Self.defaultLimits[channel]!
        var present = recordFiles(channel).map { ($0, size($0)) }
        var total = present.reduce(0) { $0 + $1.1 }
        while total + fileLimit > limit, !present.isEmpty {
            let (oldest, bytes) = present.removeFirst()
            unlink(oldest.path); total -= bytes
        }
    }

    /// The channel's record files, oldest first (their names begin with the time they were opened).
    private func recordFiles(_ channel: Channel) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory(channel).path)) ?? []
        return names.filter { $0.hasPrefix(channel.rawValue + "-") && $0.hasSuffix(".jsonl") }.sorted()
            .map { directory(channel).appendingPathComponent($0) }
    }
    private func size(_ file: URL) -> Int {
        var info = stat()
        return lstat(file.path, &info) == 0 ? Int(info.st_size) : 0
    }
    private func closeAll() {
        for (_, open) in files { try? open.handle.close() }
        files = [:]
    }

    private static func droppedLine(_ count: Int) -> Data? {
        let object: JSONValue = .object(["v": .number(1), "kind": .string("record.dropped"), "data": .object(["records": .number(Double(count))])])
        guard var line = try? object.encoded() else { return nil }
        line.append(10); return line
    }

    public static func makePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { throw RuntimeError.storageFailure }
        chmod(url.path, 0o700)
    }
}
