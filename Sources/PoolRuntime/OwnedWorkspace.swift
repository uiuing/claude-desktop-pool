import Foundation
import CryptoKit
import Darwin

struct ExecutableStamp: Equatable, Sendable {
    var inode: UInt64
    var size: Int64
    var seconds: Int64
    var nanoseconds: Int64
}

public struct OwnedWorkspace: Sendable {
    public let root: URL
    private static let marker = ".claude-pool-workspace"
    private static let signature = Data("Claude Pool workspace 1\n".utf8)

    public init(root: URL) { self.root = root }

    /// Holds the workspace for this process. Two copies of the app (an installed one and a
    /// development build) would otherwise sign accounts in and out under each other's sessions.
    public final class Claim: @unchecked Sendable {
        private let descriptor: Int32
        fileprivate init(_ descriptor: Int32) { self.descriptor = descriptor }
        deinit { flock(descriptor, LOCK_UN); close(descriptor) }
    }
    public func claim() throws -> Claim {
        let fd = try Self.directory(root, create: false)
        defer { close(fd) }
        let lock = openat(fd, ".lock", O_RDONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw RuntimeError.storageFailure }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            let busy = errno == EWOULDBLOCK
            close(lock)
            throw busy ? RuntimeError.workspaceInUse : RuntimeError.storageFailure
        }
        return Claim(lock)
    }

    public func prepare() throws {
        let fd = try Self.directory(root, create: true)
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid() else { throw RuntimeError.unsafePath }
        let marker = openat(fd, Self.marker, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if marker >= 0 {
            defer { close(marker) }
            guard try Self.readDescriptor(marker, limit: 128) == Self.signature else { throw RuntimeError.unsafePath }
        } else {
            guard errno == ENOENT, try Self.names(fd).isEmpty else { throw RuntimeError.unsafePath }
            let marker = openat(fd, Self.marker, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard marker >= 0 else { throw RuntimeError.storageFailure }
            defer { close(marker) }
            try Self.writeDescriptor(Self.signature, fd: marker)
            guard fsync(marker) == 0, fsync(fd) == 0 else { throw RuntimeError.storageFailure }
        }
        guard fchmod(fd, 0o700) == 0 else { throw RuntimeError.storageFailure }
    }

    public func accountDirectory(_ id: UUID) throws -> URL { try ownedDirectory("accounts/\(id.uuidString.lowercased())/cli") }
    public func workDirectory(_ id: UUID) throws -> URL { try ownedDirectory("accounts/\(id.uuidString.lowercased())/work") }
    public func runDirectory(_ id: UUID) throws -> URL { try ownedDirectory("runs/\(id.uuidString.lowercased())") }

    public func createDirectory(at url: URL) throws {
        let parts = try relativeComponents(url, file: false)
        let fd = try descendant(parts, create: true)
        close(fd)
    }

    public func read(_ url: URL, limit: Int = 4 * 1024 * 1024) throws -> Data {
        guard limit >= 0 else { throw RuntimeError.oversizedInput }
        let (parent, name) = try parent(of: url, create: false)
        defer { close(parent) }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw errno == ENOENT ? RuntimeError.missingFile : RuntimeError.unsafePath }
        defer { close(fd) }
        return try Self.readDescriptor(fd, limit: limit)
    }

    public func write(_ data: Data, to url: URL, limit: Int = 16 * 1024 * 1024) throws {
        guard limit >= 0, limit <= 64 * 1024 * 1024, data.count <= limit else { throw RuntimeError.oversizedInput }
        let (parent, name) = try parent(of: url, create: true)
        defer { close(parent) }
        var old = stat()
        if fstatat(parent, name, &old, AT_SYMLINK_NOFOLLOW) == 0 {
            guard old.st_mode & S_IFMT == S_IFREG else { throw RuntimeError.unsafePath }
        } else if errno != ENOENT { throw RuntimeError.storageFailure }
        let staged = ".pool-\(UUID().uuidString).tmp"
        let fd = openat(parent, staged, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RuntimeError.storageFailure }
        var installed = false
        defer { close(fd); if !installed { unlinkat(parent, staged, 0) } }
        try Self.writeDescriptor(data, fd: fd)
        guard fsync(fd) == 0, renameat(parent, staged, parent, name) == 0 else { throw RuntimeError.storageFailure }
        installed = true
        guard fsync(parent) == 0 else { throw RuntimeError.storageFailure }
    }

    public func entries(in url: URL) throws -> [URL] {
        let parts = try relativeComponents(url, file: false)
        let fd = try descendant(parts, create: false)
        defer { close(fd) }
        return try Self.names(fd).map { url.appendingPathComponent($0) }
    }

    public func remove(_ url: URL) throws {
        let (parent, name) = try parent(of: url, create: false)
        defer { close(parent) }
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw RuntimeError.storageFailure
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw RuntimeError.unsafePath }
        guard unlinkat(parent, name, 0) == 0, fsync(parent) == 0 else { throw RuntimeError.storageFailure }
    }

    /// Removes only a completed run's generated IPC. The caller must confirm that its owned child has exited.
    public func removeRun(_ id: UUID) throws {
        let parent: Int32
        do { parent = try descendant(["runs"], create: false) }
        catch RuntimeError.missingFile { return }
        defer { close(parent) }
        let name = id.uuidString.lowercased()
        let run = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard run >= 0 else {
            if errno == ENOENT { return }
            throw RuntimeError.unsafePath
        }
        defer { close(run) }
        var runInfo = stat()
        guard fstat(run, &runInfo) == 0, runInfo.st_uid == getuid() else { throw RuntimeError.unsafePath }
        let rootNames = try Self.names(run)
        if !rootNames.isEmpty {
            let marker = openat(run, "run.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard marker >= 0 else { throw RuntimeError.unsafePath }
            defer { close(marker) }
            struct RunMarker: Decodable { var session_id: String }
            guard let value = try? JSONDecoder().decode(RunMarker.self, from: Self.readDescriptor(marker, limit: 4096)),
                  UUID(uuidString: value.session_id) == id else { throw RuntimeError.unsafePath }
        }
        struct Entry { var parent: Int32; var name: String; var device: dev_t; var inode: ino_t }
        var files: [Entry] = [], directories: [(entry: Entry, descriptor: Int32)] = []
        defer { for directory in directories { close(directory.descriptor) } }
        func record(_ name: String, parent: Int32, scope: String) throws {
            guard files.count < 4096, Self.generatedRunFile(name, scope: scope) else { throw RuntimeError.unsafePath }
            var info = stat()
            guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else { throw RuntimeError.unsafePath }
            files.append(Entry(parent: parent, name: name, device: info.st_dev, inode: info.st_ino))
        }
        for child in rootNames {
            if ["events", "results", "work"].contains(child) {
                let directory = openat(run, child, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard directory >= 0 else { throw RuntimeError.unsafePath }
                var info = stat()
                guard fstat(directory, &info) == 0, info.st_uid == getuid() else { close(directory); throw RuntimeError.unsafePath }
                directories.append((Entry(parent: run, name: child, device: info.st_dev, inode: info.st_ino), directory))
                for file in try Self.names(directory) { try record(file, parent: directory, scope: child) }
            } else { try record(child, parent: run, scope: "") }
        }
        func remove(_ entry: Entry, directory: Bool = false) throws {
            var current = stat()
            guard fstatat(entry.parent, entry.name, &current, AT_SYMLINK_NOFOLLOW) == 0,
                  current.st_dev == entry.device, current.st_ino == entry.inode,
                  current.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG) else { throw RuntimeError.unsafePath }
            guard unlinkat(entry.parent, entry.name, directory ? AT_REMOVEDIR : 0) == 0 else { throw RuntimeError.storageFailure }
        }
        // Keep the ownership marker until every other entry has been removed, so an I/O failure can be retried.
        for entry in files where !(entry.parent == run && entry.name == "run.json") { try remove(entry) }
        for directory in directories { try remove(directory.entry, directory: true) }
        for entry in files where entry.parent == run && entry.name == "run.json" { try remove(entry) }
        try remove(Entry(parent: parent, name: name, device: runInfo.st_dev, inode: runInfo.st_ino), directory: true)
    }

    private static func generatedRunFile(_ name: String, scope: String) -> Bool {
        if name.hasPrefix("."), name.hasSuffix(".tmp") {
            var body = String(name.dropFirst().dropLast(4))
            if body.hasPrefix("pool-") { body = String(body.dropFirst(5)) }
            if UUID(uuidString: body) != nil { return true }
        }
        switch scope {
        case "": return ["run.json", "tools.json", "tools-listed.json", "settings.json", "mcp.json", "instructions.txt", "cancelled"].contains(name)
        case "results": return name.hasSuffix(".json") && UUID(uuidString: String(name.dropLast(5))) != nil
        case "events":
            guard name.hasSuffix(".json"), let separator = name.firstIndex(of: "-") else { return false }
            let instant = name[..<separator]
            let identity = name[name.index(after: separator)...].dropLast(5)
            return !instant.isEmpty && instant.count <= 20 && instant.allSatisfy { $0 >= "0" && $0 <= "9" } && UUID(uuidString: String(identity)) != nil
        case "work":
            guard name.hasPrefix("image-"), let dot = name.lastIndex(of: "."),
                  ["png", "jpg", "jpeg", "gif", "webp"].contains(String(name[name.index(after: dot)...])) else { return false }
            return UUID(uuidString: String(name[name.index(name.startIndex, offsetBy: 6)..<dot])) != nil
        default: return false
        }
    }

    func stagingFile(beside url: URL) throws -> (url: URL, descriptor: Int32) {
        let (parent, _) = try parent(of: url, create: true)
        defer { close(parent) }
        let name = ".download-\(UUID().uuidString).part"
        let descriptor = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw RuntimeError.storageFailure }
        return (url.deletingLastPathComponent().appendingPathComponent(name), descriptor)
    }

    func publishStagingFile(_ stage: URL, descriptor: Int32, to url: URL) throws {
        guard stage.deletingLastPathComponent().standardizedFileURL == url.deletingLastPathComponent().standardizedFileURL else {
            throw RuntimeError.unsafePath
        }
        let (parent, name) = try parent(of: url, create: false)
        defer { close(parent) }
        var opened = stat(), staged = stat(), previous = stat()
        guard fstat(descriptor, &opened) == 0,
              fstatat(parent, stage.lastPathComponent, &staged, AT_SYMLINK_NOFOLLOW) == 0,
              opened.st_ino == staged.st_ino, opened.st_dev == staged.st_dev,
              staged.st_mode & S_IFMT == S_IFREG else { throw RuntimeError.unsafePath }
        if fstatat(parent, name, &previous, AT_SYMLINK_NOFOLLOW) == 0 {
            guard previous.st_mode & S_IFMT == S_IFREG else { throw RuntimeError.unsafePath }
        } else if errno != ENOENT { throw RuntimeError.storageFailure }
        guard fchmod(descriptor, 0o500) == 0, fsync(descriptor) == 0,
              renameat(parent, stage.lastPathComponent, parent, name) == 0,
              fsync(parent) == 0 else { throw RuntimeError.storageFailure }
    }

    func inspectExecutable(_ url: URL, expectedSize: Int64) throws -> ExecutableStamp {
        let (fd, stamp) = try executableDescriptor(url, expectedSize: expectedSize)
        close(fd)
        return stamp
    }

    func hashExecutable(_ url: URL, expectedSize: Int64) throws -> (ExecutableStamp, String) {
        let (fd, stamp) = try executableDescriptor(url, expectedSize: expectedSize)
        defer { close(fd) }
        var hash = SHA256(), buffer = [UInt8](repeating: 0, count: 256 * 1024), total: Int64 = 0
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw RuntimeError.storageFailure }
            if count == 0 { break }
            total += Int64(count)
            guard total <= expectedSize else { throw RuntimeError.invalidExecutable }
            hash.update(data: Data(buffer.prefix(count)))
        }
        var info = stat()
        guard total == expectedSize, fstat(fd, &info) == 0, stamp == Self.executableStamp(info) else {
            throw RuntimeError.invalidExecutable
        }
        return (stamp, hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private func executableDescriptor(_ url: URL, expectedSize: Int64) throws -> (Int32, ExecutableStamp) {
        let (parent, name) = try parent(of: url, create: false)
        defer { close(parent) }
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw RuntimeError.invalidExecutable }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size == expectedSize,
              info.st_mode & 0o100 != 0 else { close(fd); throw RuntimeError.invalidExecutable }
        return (fd, Self.executableStamp(info))
    }

    private static func executableStamp(_ info: stat) -> ExecutableStamp {
        ExecutableStamp(inode: UInt64(info.st_ino), size: Int64(info.st_size),
                        seconds: Int64(info.st_mtimespec.tv_sec), nanoseconds: Int64(info.st_mtimespec.tv_nsec))
    }

    private func ownedDirectory(_ relative: String) throws -> URL {
        let parts = relative.split(separator: "/").map(String.init)
        let fd = try descendant(parts, create: true)
        defer { close(fd) }
        return root.appendingPathComponent(relative, isDirectory: true)
    }

    private func parent(of url: URL, create: Bool) throws -> (Int32, String) {
        let parts = try relativeComponents(url, file: true)
        let fd = try descendant(Array(parts.dropLast()), create: create)
        return (fd, parts.last!)
    }

    private func relativeComponents(_ url: URL, file: Bool) throws -> [String] {
        guard root.isFileURL, url.isFileURL, !url.pathComponents.contains(".."), !root.pathComponents.contains("..") else {
            throw RuntimeError.unsafePath
        }
        let base = root.standardizedFileURL.pathComponents, path = url.standardizedFileURL.pathComponents
        guard path.starts(with: base), path.count >= base.count + (file ? 1 : 0) else { throw RuntimeError.unsafePath }
        let parts = Array(path.dropFirst(base.count))
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.contains("\0") }) else {
            throw RuntimeError.unsafePath
        }
        guard !file || parts.first != Self.marker else { throw RuntimeError.unsafePath }
        return parts
    }

    private func descendant(_ parts: [String], create: Bool) throws -> Int32 {
        var fd = try Self.directory(root, create: false)
        do {
            let marker = openat(fd, Self.marker, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard marker >= 0 else { throw RuntimeError.unsafePath }
            defer { close(marker) }
            guard try Self.readDescriptor(marker, limit: 128) == Self.signature else { throw RuntimeError.unsafePath }
            for part in parts {
                let next = try Self.openDirectory(part, at: fd, create: create)
                close(fd); fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }

    private static func directory(_ url: URL, create: Bool) throws -> Int32 {
        guard url.isFileURL, url.path.hasPrefix("/"), url.path != "/", !url.pathComponents.contains("..") else {
            throw RuntimeError.unsafePath
        }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw RuntimeError.unsafePath }
        do {
            for part in url.pathComponents where part != "/" {
                let next = try openDirectory(part, at: fd, create: create)
                close(fd); fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }

    private static func openDirectory(_ name: String, at fd: Int32, create: Bool) throws -> Int32 {
        if create && mkdirat(fd, name, 0o700) != 0 && errno != EEXIST { throw RuntimeError.storageFailure }
        let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard child >= 0 else { throw errno == ENOENT ? RuntimeError.missingFile : RuntimeError.unsafePath }
        return child
    }

    private static func names(_ fd: Int32) throws -> [String] {
        let duplicate = dup(fd)
        guard duplicate >= 0 else { throw RuntimeError.storageFailure }
        guard let directory = fdopendir(duplicate) else { close(duplicate); throw RuntimeError.storageFailure }
        defer { closedir(directory) }
        var result: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != "." && name != ".." {
                guard result.count < 4096 else { throw RuntimeError.oversizedInput }
                result.append(name)
            }
            errno = 0
        }
        guard errno == 0 else { throw RuntimeError.storageFailure }
        return result.sorted()
    }

    private static func readDescriptor(_ fd: Int32, limit: Int) throws -> Data {
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { throw RuntimeError.unsafePath }
        guard before.st_size >= 0, before.st_size <= limit else { throw RuntimeError.oversizedInput }
        var result = Data(), buffer = [UInt8](repeating: 0, count: min(limit + 1, 64 * 1024))
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw RuntimeError.storageFailure }
            if count == 0 { break }
            guard result.count + count <= limit else { throw RuntimeError.oversizedInput }
            result.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw RuntimeError.storageFailure }
        return result
    }

    private static func writeDescriptor(_ data: Data, fd: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw RuntimeError.storageFailure }
                offset += count
            }
        }
    }
}
