import CryptoKit
import Darwin
import Foundation
import PoolCore
import Security

public enum AppUpdateError: Error, Equatable {
    /// The app cannot replace itself where it runs (a read-only or translocated copy).
    case notReplaceable
    case download
    case checksum
    case package
    case signature
    case unsupportedSystem
}

/// Downloads a published release, checks it, and swaps it in for the running bundle once the app quits.
/// The archive and its checksum come from the project's GitHub release over HTTPS, redirects stay on
/// GitHub's own hosts, and the bundle must carry this app's identifier, the announced version and an
/// intact signature (the same team when this copy is Developer ID signed).
public struct AppUpdateInstaller: Sendable {
    public static let archiveLimit = 256 << 20
    public let repository: URL
    public let currentApp: URL
    public let bundleIdentifier: String

    public init(repository: URL, currentApp: URL, bundleIdentifier: String) {
        self.repository = repository; self.currentApp = currentApp; self.bundleIdentifier = bundleIdentifier
    }

    public static func assetName(_ version: ReleaseVersion) -> String { "Claude-Pool-\(version.description)-universal.zip" }

    /// Release tags are `v1.2.3`; a bare `1.2.3` tag is tried after it.
    public func downloadURLs(_ version: ReleaseVersion, asset: String) -> [URL] {
        ["v" + version.description, version.description].map {
            repository.appendingPathComponent("releases/download").appendingPathComponent($0).appendingPathComponent(asset)
        }
    }

    /// Whether this copy can be replaced in place: a real bundle in a folder the user can write.
    public var canReplace: Bool {
        guard currentApp.pathExtension == "app", !currentApp.path.contains("/AppTranslocation/") else { return false }
        let parent = currentApp.deletingLastPathComponent().path
        return access(parent, W_OK) == 0 && access(currentApp.path, W_OK) == 0
    }

    /// Downloads and checks `version`, and returns the staged bundle on the same volume as the app.
    public func prepare(_ version: ReleaseVersion) async throws -> URL {
        guard canReplace else { throw AppUpdateError.notReplaceable }
        let staging = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                  appropriateFor: currentApp, create: true)
        do {
            let asset = Self.assetName(version)
            let (checksumData, archive) = try await download(version, asset: asset, into: staging)
            guard let expected = Self.checksum(String(decoding: checksumData, as: UTF8.self), asset: asset),
                  try Self.sha256(of: archive) == expected else { throw AppUpdateError.checksum }
            let extracted = staging.appendingPathComponent("extracted", isDirectory: true)
            try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let ditto = try OwnedPipeProcess.start(executable: URL(fileURLWithPath: "/usr/bin/ditto"),
                                                   arguments: ["-x", "-k", archive.path, extracted.path],
                                                   environment: [:], directory: staging, outputLimit: 4096)
            guard try await ditto.waitForExit(timeout: 120) == 0 else { throw AppUpdateError.package }
            try? FileManager.default.removeItem(at: archive)
            let items = try FileManager.default.contentsOfDirectory(atPath: extracted.path).filter { !$0.hasPrefix(".") }
            guard items == [currentApp.lastPathComponent] || items == ["Claude Pool.app"] else { throw AppUpdateError.package }
            let app = extracted.appendingPathComponent(items[0], isDirectory: true)
            try validate(app, version: version)
            return app
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    /// Puts the staged bundle where the app is. Run only once the app has agreed to quit.
    public func replace(with staged: URL) throws {
        _ = try FileManager.default.replaceItemAt(currentApp, withItemAt: staged, backupItemName: nil, options: [])
        try? FileManager.default.removeItem(at: staged.deletingLastPathComponent().deletingLastPathComponent())
    }

    /// Starts a small waiter that opens the app again after `processID` has exited, for up to five minutes.
    public func relaunch(after processID: Int32) throws {
        let script = #"i=0; while kill -0 "$1" 2>/dev/null && [ "$i" -lt 600 ]; do sleep 0.5; i=$((i+1)); done; kill -0 "$1" 2>/dev/null || /usr/bin/open "$2""#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(processID), currentApp.path]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    public func validate(_ app: URL, version: ReleaseVersion) throws {
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              info["CFBundleIdentifier"] as? String == bundleIdentifier,
              (info["CFBundleShortVersionString"] as? String).flatMap(ReleaseVersion.init) == version else {
            throw AppUpdateError.package
        }
        if let minimum = info["LSMinimumSystemVersion"] as? String {
            let parts = minimum.split(separator: ".").compactMap { Int($0) }
            let wanted = OperatingSystemVersion(majorVersion: parts.first ?? 0, minorVersion: parts.dropFirst().first ?? 0,
                                                patchVersion: parts.dropFirst(2).first ?? 0)
            guard ProcessInfo.processInfo.isOperatingSystemAtLeast(wanted) else { throw AppUpdateError.unsupportedSystem }
        }
        guard let staged = Self.staticCode(app),
              SecStaticCodeCheckValidity(staged, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode), nil) == errSecSuccess
        else { throw AppUpdateError.signature }
        if let team = Self.team(currentApp), Self.team(app) != team { throw AppUpdateError.signature }
    }

    /// The hash for `asset` in a `shasum -a 256` line; the file name may carry a folder prefix.
    public static func checksum(_ text: String, asset: String) -> String? {
        guard text.utf8.count <= 4096 else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 1, fields[0].count == 64, fields[0].allSatisfy(\.isHexDigit) else { continue }
            let name = fields.count > 1 ? String(fields[1]).trimmingCharacters(in: CharacterSet(charactersIn: "*")) : asset
            if name == asset || name.hasSuffix("/" + asset) { return fields[0].lowercased() }
        }
        return nil
    }

    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func staticCode(_ url: URL) -> SecStaticCode? {
        var code: SecStaticCode?
        return SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess ? code : nil
    }

    private static func team(_ url: URL) -> String? {
        var information: CFDictionary?
        guard let code = staticCode(url),
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any] else { return nil }
        return values[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private func download(_ version: ReleaseVersion, asset: String, into staging: URL) async throws -> (Data, URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
        configuration.urlCache = nil; configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 900
        let session = URLSession(configuration: configuration, delegate: GitHubRedirectsOnly(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        for (archiveURL, checksumURL) in zip(downloadURLs(version, asset: asset), downloadURLs(version, asset: asset + ".sha256")) {
            guard let checksum = try await fetch(checksumURL, session: session, limit: 4096) else { continue }
            let archive = staging.appendingPathComponent(asset)
            guard try await save(archiveURL, to: archive, session: session) else { throw AppUpdateError.download }
            return (checksum, archive)
        }
        throw AppUpdateError.download
    }

    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("ClaudePool-Update", forHTTPHeaderField: "User-Agent")
        return request
    }

    /// Nil for a missing asset, so the other tag spelling can be tried.
    private func fetch(_ url: URL, session: URLSession, limit: Int) async throws -> Data? {
        let (bytes, response) = try await session.bytes(for: request(url))
        guard let response = response as? HTTPURLResponse, Self.allowedHost(response.url) else { throw AppUpdateError.download }
        if response.statusCode == 404 { return nil }
        guard response.statusCode == 200 else { throw AppUpdateError.download }
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
            if data.count > limit { throw AppUpdateError.download }
        }
        return data
    }

    private func save(_ url: URL, to file: URL, session: URLSession) async throws -> Bool {
        let (temporary, response) = try await session.download(for: request(url))
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, Self.allowedHost(response.url),
              let size = (try? FileManager.default.attributesOfItem(atPath: temporary.path))?[.size] as? Int,
              size > 0, size <= Self.archiveLimit else { return false }
        try FileManager.default.moveItem(at: temporary, to: file)
        return true
    }

    static func allowedHost(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else { return false }
        return ["github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"].contains(host)
    }
}

/// Release downloads redirect to GitHub's asset storage; nothing else is followed.
private final class GitHubRedirectsOnly: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(AppUpdateInstaller.allowedHost(request.url) ? request : nil)
    }
}
