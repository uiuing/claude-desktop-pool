import Foundation
import CryptoKit
import Darwin

public enum RuntimePlatform: String, Codable, Sendable {
    case macOSArm64 = "darwin-arm64", macOSIntel = "darwin-x64"
    public static var current: RuntimePlatform {
        #if arch(arm64)
        return .macOSArm64
        #else
        return .macOSIntel
        #endif
    }
    var cpuType: UInt32 { self == .macOSArm64 ? 0x0100000c : 0x01000007 }
}

public struct RuntimeRelease: Codable, Equatable, Sendable {
    public let version: String
    public let platform: RuntimePlatform
    public let checksum: String
    public let size: Int64
    var binaryURL: URL {
        ManagedRuntime.base.appendingPathComponent(version).appendingPathComponent(platform.rawValue).appendingPathComponent("claude")
    }
}

public struct ManagedRuntimeInstallation: Equatable, Sendable {
    public let version: String
    public let executable: URL
    public let platform: RuntimePlatform
}

public enum RuntimeInstallProgress: Equatable, Sendable {
    case resolving
    case downloading(version: String, receivedBytes: Int64, totalBytes: Int64)
    case verifying(version: String)
    case activating(version: String)
    case completed(version: String)

    public var version: String? {
        switch self {
        case .resolving: return nil
        case .downloading(let version, _, _), .verifying(let version), .activating(let version), .completed(let version): return version
        }
    }

    /// Download completion; the phase distinguishes verification from activation.
    public var fractionCompleted: Double? {
        switch self {
        case .resolving: return nil
        case .downloading(_, let received, let total): return Double(received) / Double(total)
        case .verifying, .activating, .completed: return 1
        }
    }

    public var receivedBytes: Int64? {
        if case .downloading(_, let received, _) = self { return received }
        return nil
    }

    public var totalBytes: Int64? {
        if case .downloading(_, _, let total) = self { return total }
        return nil
    }
}

public enum RuntimeInstallError: Error, Equatable, Sendable, LocalizedError {
    case invalidRelease, downloadFailed, verificationFailed, noPreviousVersion, unsupportedVersion, busy
    public var errorDescription: String? {
        switch self {
        case .invalidRelease: return "The official release information could not be verified. Try again later."
        case .downloadFailed: return "Claude Code could not be downloaded. Check your connection and try again."
        case .verificationFailed: return "The Claude Code download did not pass verification. Your current version is unchanged."
        case .noPreviousVersion: return "There is no previous Claude Code version to restore."
        case .unsupportedVersion: return "This Claude Code version is too old for Claude Pool. Update it in Settings."
        case .busy: return "Claude Code is already being installed. Wait for it to finish."
        }
    }
}

public actor ManagedRuntime {
    /// The official file-mention control used by the bridge starts with this release.
    public static let minimumVersion = "2.1.299"
    static let base = URL(string: "https://downloads.claude.ai/claude-code-releases")!
    private let workspace: OwnedWorkspace
    private let platform: RuntimePlatform
    private let downloader: any RuntimeDownloader
    private var installing = false
    private var verified: [String: (checksum: String, stamp: ExecutableStamp)] = [:]
    private struct Selection: Codable { var version: String; var previous: String?; var platform: RuntimePlatform }

    public init(workspace: OwnedWorkspace, platform: RuntimePlatform = .current,
                downloader: any RuntimeDownloader = OfficialRuntimeDownloader()) {
        self.workspace = workspace; self.platform = platform; self.downloader = downloader
    }

    public func current() throws -> ManagedRuntimeInstallation? {
        try workspace.prepare()
        guard let selection = try selection() else { return nil }
        guard selection.platform == platform else { throw RuntimeInstallError.invalidRelease }
        return try installed(selection.version)
    }

    public func checkForUpdate() async throws -> RuntimeRelease? {
        let release = try await latest()
        let selected: ManagedRuntimeInstallation?
        do { selected = try current() }
        catch RuntimeInstallError.unsupportedVersion { return release }
        guard let current = selected else { return release }
        return Self.isNewer(release.version, than: current.version) ? release : nil
    }

    public func previousInstallation() throws -> ManagedRuntimeInstallation? {
        guard let selection = try selection() else { return nil }
        guard selection.platform == platform else { throw RuntimeInstallError.invalidRelease }
        guard let previous = selection.previous else { return nil }
        return try installed(previous)
    }

    public func installLatest(progress: @escaping @Sendable (RuntimeInstallProgress) -> Void = { _ in }) async throws -> ManagedRuntimeInstallation {
        guard !installing else { throw RuntimeInstallError.busy }
        installing = true; defer { installing = false }
        progress(.resolving)
        let release = try await latest()
        try workspace.prepare()
        if let current = try unchangedInstallation(for: release) {
            progress(.completed(version: current.version)); return current
        }
        return try await performInstall(release, progress: progress)
    }

    public func install(_ release: RuntimeRelease, progress: @escaping @Sendable (RuntimeInstallProgress) -> Void = { _ in }) async throws -> ManagedRuntimeInstallation {
        guard !installing else { throw RuntimeInstallError.busy }
        installing = true; defer { installing = false }
        progress(.resolving)
        try Self.validate(release)
        guard release.platform == platform else { throw RuntimeInstallError.invalidRelease }
        let verified = try await manifest(version: release.version)
        guard verified == release else { throw RuntimeInstallError.invalidRelease }
        try workspace.prepare()
        if let current = try unchangedInstallation(for: release) {
            progress(.completed(version: current.version)); return current
        }
        return try await performInstall(release, progress: progress)
    }

    public func rollback() throws -> ManagedRuntimeInstallation {
        guard !installing else { throw RuntimeInstallError.busy }
        guard let selection = try selection(), let previous = selection.previous else { throw RuntimeInstallError.noPreviousVersion }
        guard selection.platform == platform else { throw RuntimeInstallError.invalidRelease }
        let result = try installed(previous)
        try saveSelection(Selection(version: previous, previous: selection.version, platform: platform))
        return result
    }

    private func latest() async throws -> RuntimeRelease {
        let bytes = try await metadata(Self.base.appendingPathComponent("latest"), limit: 256)
        guard let text = String(data: bytes, encoding: .utf8) else { throw RuntimeInstallError.invalidRelease }
        let version = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validVersion(version) else { throw RuntimeInstallError.invalidRelease }
        return try await manifest(version: version)
    }

    private func manifest(version: String) async throws -> RuntimeRelease {
        guard Self.validVersion(version) else { throw RuntimeInstallError.invalidRelease }
        try Self.requireSupportedVersion(version)
        let bytes = try await metadata(Self.base.appendingPathComponent(version).appendingPathComponent("manifest.json"), limit: 1024 * 1024)
        struct Manifest: Decodable {
            struct Binary: Decodable { var binary: String; var checksum: String; var size: Int64 }
            var version: String?
            var platforms: [String: Binary]
        }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: bytes),
              manifest.version.map({ $0 == version }) ?? true,
              let binary = manifest.platforms[platform.rawValue], binary.binary == "claude" else {
            throw RuntimeInstallError.invalidRelease
        }
        let result = RuntimeRelease(version: version, platform: platform, checksum: binary.checksum, size: binary.size)
        try Self.validate(result)
        return result
    }

    private func performInstall(_ release: RuntimeRelease, progress: @escaping @Sendable (RuntimeInstallProgress) -> Void) async throws -> ManagedRuntimeInstallation {
        try workspace.prepare()
        let previous = try selection()
        let executable = executableURL(release.version)
        let stage = try workspace.stagingFile(beside: executable)
        let writer = RuntimeBinaryWriter(descriptor: stage.descriptor, release: release, progress: progress)
        defer { close(stage.descriptor); try? workspace.remove(stage.url) }
        progress(.downloading(version: release.version, receivedBytes: 0, totalBytes: release.size))
        try await downloader.fetch(release.binaryURL, maximumBytes: release.size) { bytes in try writer.append(bytes) }
        try Task.checkCancellation()
        progress(.verifying(version: release.version))
        try writer.verify()
        progress(.activating(version: release.version))
        try workspace.publishStagingFile(stage.url, descriptor: stage.descriptor, to: executable)
        verified[release.version] = (release.checksum, try workspace.inspectExecutable(executable, expectedSize: release.size))
        try workspace.write(JSONEncoder().encode(release), to: receiptURL(release.version))
        let keepPrevious = previous?.version == release.version ? previous?.previous : previous?.version
        try saveSelection(Selection(version: release.version, previous: keepPrevious, platform: platform))
        progress(.completed(version: release.version))
        return ManagedRuntimeInstallation(version: release.version, executable: executable, platform: platform)
    }

    private func installed(_ version: String) throws -> ManagedRuntimeInstallation {
        guard Self.validVersion(version) else { throw RuntimeInstallError.invalidRelease }
        try Self.requireSupportedVersion(version)
        let bytes = try workspace.read(receiptURL(version), limit: 4096)
        guard let receipt = try? JSONDecoder().decode(RuntimeRelease.self, from: bytes),
              receipt.version == version, receipt.platform == platform else { throw RuntimeInstallError.invalidRelease }
        try Self.validate(receipt)
        let executable = executableURL(version)
        let stamp = try workspace.inspectExecutable(executable, expectedSize: receipt.size)
        if verified[version]?.checksum != receipt.checksum || verified[version]?.stamp != stamp {
            let (observed, checksum) = try workspace.hashExecutable(executable, expectedSize: receipt.size)
            guard checksum == receipt.checksum else { throw RuntimeInstallError.verificationFailed }
            verified[version] = (checksum, observed)
        }
        return ManagedRuntimeInstallation(version: version, executable: executable, platform: platform)
    }

    private func unchangedInstallation(for release: RuntimeRelease) throws -> ManagedRuntimeInstallation? {
        guard let selected = try selection() else { return nil }
        guard selected.platform == platform else { throw RuntimeInstallError.invalidRelease }
        if Self.isNewer(release.version, than: selected.version) { return nil }
        do { return try installed(selected.version) }
        catch RuntimeInstallError.verificationFailed where selected.version == release.version { return nil }
        catch RuntimeError.invalidExecutable where selected.version == release.version { return nil }
        catch RuntimeError.missingFile where selected.version == release.version { return nil }
    }

    private func selection() throws -> Selection? {
        let bytes: Data
        do { bytes = try workspace.read(selectionURL, limit: 4096) }
        catch RuntimeError.missingFile { return nil }
        guard let selection = try? JSONDecoder().decode(Selection.self, from: bytes),
              Self.validVersion(selection.version), selection.previous.map(Self.validVersion) ?? true else {
            throw RuntimeInstallError.invalidRelease
        }
        return selection
    }
    private func saveSelection(_ selection: Selection) throws {
        try workspace.write(JSONEncoder().encode(selection), to: selectionURL)
    }
    private var selectionURL: URL { workspace.root.appendingPathComponent("runtime/current.json") }
    private func executableURL(_ version: String) -> URL {
        workspace.root.appendingPathComponent("runtime/versions/\(version)/\(platform.rawValue)/claude")
    }
    private func receiptURL(_ version: String) -> URL { executableURL(version).deletingLastPathComponent().appendingPathComponent("receipt.json") }

    private func metadata(_ url: URL, limit: Int64) async throws -> Data {
        let buffer = RuntimeMetadataBuffer(limit: limit)
        try await downloader.fetch(url, maximumBytes: limit) { data in try buffer.append(data) }
        return buffer.value
    }
    private static func validate(_ release: RuntimeRelease) throws {
        guard validVersion(release.version), release.size >= 8, release.size <= 1024 * 1024 * 1024,
              release.checksum.count == 64, release.checksum.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw RuntimeInstallError.invalidRelease
        }
        try requireSupportedVersion(release.version)
    }
    private static func requireSupportedVersion(_ version: String) throws {
        guard version == minimumVersion || isNewer(version, than: minimumVersion) else { throw RuntimeInstallError.unsupportedVersion }
    }
    private static func validVersion(_ value: String) -> Bool {
        value.range(of: #"\A(?:0|[1-9][0-9]{0,5})\.(?:0|[1-9][0-9]{0,5})\.(?:0|[1-9][0-9]{0,5})\z"#, options: .regularExpression) != nil
    }
    private static func isNewer(_ left: String, than right: String) -> Bool {
        left.split(separator: ".").compactMap { Int($0) }.lexicographicallyPrecedes(
            right.split(separator: ".").compactMap { Int($0) }) == false && left != right
    }
}

private final class RuntimeMetadataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int64
    private var data = Data()
    init(limit: Int64) { self.limit = limit }
    var value: Data { lock.withLock { data } }
    func append(_ bytes: Data) throws {
        try lock.withLock {
            guard Int64(data.count) + Int64(bytes.count) <= limit else { throw RuntimeInstallError.invalidRelease }
            data.append(bytes)
        }
    }
}

private final class RuntimeBinaryWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let descriptor: Int32
    private let release: RuntimeRelease
    private let progress: @Sendable (RuntimeInstallProgress) -> Void
    private var digest = SHA256()
    private var count: Int64 = 0
    private var header = Data()
    init(descriptor: Int32, release: RuntimeRelease, progress: @escaping @Sendable (RuntimeInstallProgress) -> Void) {
        self.descriptor = descriptor; self.release = release; self.progress = progress
    }
    func append(_ bytes: Data) throws {
        let done = try lock.withLock { () throws -> Int64 in
            guard count + Int64(bytes.count) <= release.size else { throw RuntimeInstallError.verificationFailed }
            if header.count < 8 { header.append(bytes.prefix(8 - header.count)) }
            try bytes.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let written = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                    if written < 0 && errno == EINTR { continue }
                    guard written > 0 else { throw RuntimeError.storageFailure }
                    offset += written
                }
            }
            digest.update(data: bytes); count += Int64(bytes.count)
            return count
        }
        progress(.downloading(version: release.version, receivedBytes: done, totalBytes: release.size))
    }
    func verify() throws {
        try lock.withLock {
            let checksum = digest.finalize().map { String(format: "%02x", $0) }.joined()
            guard count == release.size, checksum == release.checksum, header.count == 8,
                  Array(header.prefix(4)) == [0xcf, 0xfa, 0xed, 0xfe] else { throw RuntimeInstallError.verificationFailed }
            let cpu = header.dropFirst(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8 * $1.offset) }
            guard cpu == release.platform.cpuType else { throw RuntimeInstallError.verificationFailed }
        }
    }
}
