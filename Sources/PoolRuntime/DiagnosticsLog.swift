import Foundation
import Darwin
import PoolCore

/// Pool's app log: one private file in the
/// user's Logs folder, renamed to `pool.old.log` at 5 MiB so at most two files exist, folder 0700
/// and file 0600. It holds what Pool did — counts, sizes, timings, reasons — and never what was
/// said. A last scrub masks anything shaped like a credential.
public final class DiagnosticsLog: @unchecked Sendable {
    public static let limit = 5 << 20
    public let directory: URL
    public var file: URL { directory.appendingPathComponent("pool.log") }
    private var old: URL { directory.appendingPathComponent("pool.old.log") }
    private let lock = NSLock()
    private var handle: FileHandle?
    private var size = 0
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    public init(directory: URL) { self.directory = directory }

    /// `~/Library/Logs/Claude Pool`, where Console.app also finds it.
    public static func standardDirectory() throws -> URL {
        try FileManager.default.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("Logs/Claude Pool", isDirectory: true)
    }

    /// Opens the log and makes it the sink for `Diagnostics.record`.
    public func install(version: String) throws {
        try open()
        Diagnostics.install { [weak self] line in self?.write(line) }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        Diagnostics.record("app.started", ["version": version, "pid": String(getpid()),
                                           "macos": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"])
    }

    func write(_ line: String) {
        let text = formatter.string(from: Date()) + " " + Self.scrub(line) + "\n"
        lock.withLock {
            let data = Data(text.utf8)
            if size + data.count > Self.limit { try? rotate() }
            else if handle == nil { try? openFile() }
            guard let handle else { return }
            do { try handle.write(contentsOf: data); size += data.count } catch { self.handle = nil }
        }
    }

    private func open() throws {
        try lock.withLock {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            chmod(directory.path, 0o700)
            try openFile()
        }
    }
    private func openFile() throws {
        let fd = Darwin.open(file.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RuntimeError.storageFailure }
        fchmod(fd, 0o600)
        var info = stat()
        size = fstat(fd, &info) == 0 ? Int(info.st_size) : 0
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    /// The full file is renamed aside; when that fails it starts the file over instead.
    private func rotate() throws {
        try? handle?.close(); handle = nil
        _ = unlink(old.path)
        if rename(file.path, old.path) != 0 { _ = truncate(file.path, 0) }
        try openFile()
    }

    private static let secrets: [String] = [
        #"(?i)(bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}"#,
        #"sk-[A-Za-z0-9_-]{8,}"#,
        #"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#,
        #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#]
    static func scrub(_ line: String) -> String {
        var text = line
        for pattern in secrets {
            text = text.replacingOccurrences(of: pattern, with: "[hidden]", options: .regularExpression)
        }
        return text
    }
}
