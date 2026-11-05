import Foundation
import XCTest
import PoolCore
@testable import PoolRuntime

final class AppUpdateInstallerTests: XCTestCase {
    private let repository = URL(string: "https://github.com/uiuing/claude-desktop-pool")!
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pool-update-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    /// A minimal bundle shaped like the packaged app, ad-hoc signed as `scripts/build.sh` signs a local build.
    private func bundle(in folder: URL, identifier: String = "io.github.uiuing.claude-desktop-pool", version: String = "0.2.0",
                        sign: Bool = true) throws -> URL {
        let app = folder.appendingPathComponent("Claude Pool.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleShortVersionString": version,
                                   "CFBundleExecutable": "ClaudePool", "CFBundlePackageType": "APPL", "LSMinimumSystemVersion": "14.0"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let executable = app.appendingPathComponent("Contents/MacOS/ClaudePool")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
        if sign {
            let codesign = Process()
            codesign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            codesign.arguments = ["--force", "--sign", "-", app.path]
            codesign.standardOutput = FileHandle.nullDevice; codesign.standardError = FileHandle.nullDevice
            try codesign.run(); codesign.waitUntilExit()
            XCTAssertEqual(codesign.terminationStatus, 0)
        }
        return app
    }

    func testReleaseAssetsUseThePackagedNameAndBothTagSpellings() {
        let installer = AppUpdateInstaller(repository: repository, currentApp: URL(fileURLWithPath: "/Applications/Claude Pool.app"),
                                           bundleIdentifier: "io.github.uiuing.claude-desktop-pool")
        let version = ReleaseVersion("0.2.0")!
        XCTAssertEqual(AppUpdateInstaller.assetName(version), "Claude-Pool-0.2.0-universal.zip")
        XCTAssertEqual(installer.downloadURLs(version, asset: "a.zip").map(\.absoluteString), [
            "https://github.com/uiuing/claude-desktop-pool/releases/download/v0.2.0/a.zip",
            "https://github.com/uiuing/claude-desktop-pool/releases/download/0.2.0/a.zip"])
    }
    func testChecksumLinesAsShasumWritesThem() {
        let hash = String(repeating: "ab", count: 32)
        let asset = "Claude-Pool-0.2.0-universal.zip"
        // scripts/package.sh runs shasum from the repository root, so the name carries "dist/".
        XCTAssertEqual(AppUpdateInstaller.checksum("\(hash)  dist/\(asset)\n", asset: asset), hash)
        XCTAssertEqual(AppUpdateInstaller.checksum("\(hash.uppercased()) *\(asset)", asset: asset), hash)
        XCTAssertNil(AppUpdateInstaller.checksum("\(hash)  dist/Claude-Pool-0.2.0-arm64.zip", asset: asset))
        XCTAssertNil(AppUpdateInstaller.checksum("abc  \(asset)", asset: asset))
        XCTAssertNil(AppUpdateInstaller.checksum(String(repeating: "x", count: 5000), asset: asset))
    }
    func testDownloadsStayOnGitHubOverHTTPS() {
        for url in ["https://github.com/a", "https://objects.githubusercontent.com/a", "https://release-assets.githubusercontent.com/a"] {
            XCTAssertTrue(AppUpdateInstaller.allowedHost(URL(string: url)), url)
        }
        for url in ["http://github.com/a", "https://github.com.invalid.test/a", "https://user:pw@github.com/a",
                    "https://github.com:8443/a", "https://invalid.test/a"] {
            XCTAssertFalse(AppUpdateInstaller.allowedHost(URL(string: url)), url)
        }
        XCTAssertFalse(AppUpdateInstaller.allowedHost(nil))
    }
    func testOnlyAWritableBundleOutsideTranslocationIsReplaced() throws {
        let root = try folder()
        let app = try bundle(in: root, sign: false)
        XCTAssertTrue(AppUpdateInstaller(repository: repository, currentApp: app, bundleIdentifier: "x").canReplace)
        XCTAssertFalse(AppUpdateInstaller(repository: repository, currentApp: root, bundleIdentifier: "x").canReplace)
        let translocated = URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/Claude Pool.app")
        XCTAssertFalse(AppUpdateInstaller(repository: repository, currentApp: translocated, bundleIdentifier: "x").canReplace)
    }
    func testStagedBundleMustBeThisAppAtTheAnnouncedVersionAndSigned() throws {
        let current = try bundle(in: try folder(), version: "0.1.0")
        let installer = AppUpdateInstaller(repository: repository, currentApp: current, bundleIdentifier: "io.github.uiuing.claude-desktop-pool")
        let version = ReleaseVersion("0.2.0")!
        XCTAssertNoThrow(try installer.validate(try bundle(in: try folder()), version: version))
        XCTAssertThrowsError(try installer.validate(try bundle(in: try folder(), identifier: "invalid.test.other"), version: version)) {
            XCTAssertEqual($0 as? AppUpdateError, .package)
        }
        XCTAssertThrowsError(try installer.validate(try bundle(in: try folder(), version: "0.1.9"), version: version)) {
            XCTAssertEqual($0 as? AppUpdateError, .package)
        }
        XCTAssertThrowsError(try installer.validate(try bundle(in: try folder(), sign: false), version: version)) {
            XCTAssertEqual($0 as? AppUpdateError, .signature)
        }
        // A bundle changed after signing is refused.
        let tampered = try bundle(in: try folder())
        try Data("x".utf8).write(to: tampered.appendingPathComponent("Contents/MacOS/ClaudePool"))
        XCTAssertThrowsError(try installer.validate(tampered, version: version)) { XCTAssertEqual($0 as? AppUpdateError, .signature) }
    }
    func testReplaceSwapsTheBundleInPlace() throws {
        let current = try bundle(in: try folder(), version: "0.1.0", sign: false)
        let staging = try folder()
        let extracted = staging.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        let staged = try bundle(in: extracted, sign: false)
        let installer = AppUpdateInstaller(repository: repository, currentApp: current, bundleIdentifier: "x")
        try installer.replace(with: staged)
        let info = NSDictionary(contentsOf: current.appendingPathComponent("Contents/Info.plist"))
        XCTAssertEqual(info?["CFBundleShortVersionString"] as? String, "0.2.0")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }
}
