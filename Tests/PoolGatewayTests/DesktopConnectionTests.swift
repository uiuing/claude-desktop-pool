import XCTest
import PoolCore
@testable import PoolGateway

/// Every test works on a synthetic home in a temporary folder, never the user's Desktop settings.
final class DesktopConnectionTests: XCTestCase {
    private let token = String(repeating: "ab", count: 32)
    private let url = DesktopConnection.baseURL(port: 18473)
    private var home: URL!
    private var record: URL!
    private var support: URL { home.appendingPathComponent("Library/Application Support") }
    private var config: URL { support.appendingPathComponent("Claude/claude_desktop_config.json") }
    private var config3p: URL { support.appendingPathComponent("Claude-3p/claude_desktop_config.json") }
    private var meta: URL { support.appendingPathComponent("Claude-3p/configLibrary/_meta.json") }
    private var profile: URL { support.appendingPathComponent("Claude-3p/configLibrary/\(DesktopConnection.profileID).json") }

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-\(UUID().uuidString)", isDirectory: true)
        record = home.appendingPathComponent("pool/desktop-connection.json")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: home) }

    private var connection: DesktopConnection { DesktopConnection(home: home, record: record) }
    private func put(_ json: String, _ file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: file)
    }
    private func json(_ file: URL) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: file)) }

    func testConnectOnAFreshDesktopAndDisconnectLeavesNothingBehind() throws {
        XCTAssertEqual(connection.status(baseURL: url, token: token), .disconnected)
        XCTAssertTrue(try connection.connect(baseURL: url, token: token, now: Date()))
        XCTAssertEqual(connection.status(baseURL: url, token: token), .connected)
        XCTAssertEqual(try json(config3p)["deploymentMode"], .string("3p"))
        XCTAssertEqual(try json(config)["deploymentMode"], .string("3p"))
        XCTAssertEqual(try json(meta)["appliedId"], .string(DesktopConnection.profileID))
        let written = try json(profile)
        XCTAssertEqual(written["inferenceGatewayBaseUrl"], .string(url))
        XCTAssertEqual(written["inferenceGatewayApiKey"], .string(token))
        XCTAssertEqual(written["disableDeploymentModeChooser"], .bool(true))
        XCTAssertNil(written["coworkEgressAllowedHosts"])
        XCTAssertEqual(written["toolSearchEnabled"], .bool(true), "Desktop's Code tab loads MCP tools as they are needed")
        XCTAssertEqual(written["desktopHome"], .string("standard"), "Chat and Cowork both use the pool")
        let mode = try FileManager.default.attributesOfItem(atPath: profile.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)

        XCTAssertFalse(try connection.connect(baseURL: url, token: token, now: Date()), "a second connect changes nothing")
        XCTAssertTrue(try connection.disconnect())
        XCTAssertEqual(connection.status(baseURL: url, token: token), .disconnected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("Claude").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: support.appendingPathComponent("Claude-3p").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
    }

    func testDisconnectRestoresTheUsersOwnSettings() throws {
        try put(#"{"deploymentMode":"1p","mcpServers":{"notes":{"command":"notes"}}}"#, config)
        try put(#"{"deploymentMode":"1p","locale":"zh-CN"}"#, config3p)
        try put(#"{"appliedId":"their-gateway","entries":[{"id":"their-gateway","name":"Work"}]}"#, meta)
        try connection.connect(baseURL: url, token: token, now: Date())
        XCTAssertEqual(try json(config)["mcpServers"]?["notes"]?["command"], .string("notes"))
        XCTAssertEqual(try json(meta)["entries"]?.arrayValue?.count, 2)

        try connection.disconnect()
        XCTAssertEqual(try json(config)["deploymentMode"], .string("1p"))
        XCTAssertEqual(try json(config)["mcpServers"]?["notes"]?["command"], .string("notes"))
        XCTAssertEqual(try json(config3p)["deploymentMode"], .string("1p"))
        XCTAssertEqual(try json(config3p)["locale"], .string("zh-CN"))
        XCTAssertEqual(try json(meta)["appliedId"], .string("their-gateway"))
        XCTAssertEqual(try json(meta)["entries"]?.arrayValue?.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: profile.path))
    }

    func testAChangeMadeInDesktopIsReportedAndKeptOnDisconnect() throws {
        try connection.connect(baseURL: url, token: token, now: Date())
        try put(#"{"appliedId":"other","entries":[{"id":"other"},{"id":"\#(DesktopConnection.profileID)"}]}"#, meta)
        XCTAssertEqual(connection.status(baseURL: url, token: token), .changed)
        try connection.connect(baseURL: url, token: token, now: Date())
        XCTAssertEqual(connection.status(baseURL: url, token: token), .connected)

        // The user switched Desktop back to its own sign-in: Disconnect leaves that as it is.
        var three = try json(config3p).objectValue ?? [:]; three["deploymentMode"] = .string("1p")
        try JSONEncoder().encode(JSONValue.object(three)).write(to: config3p)
        try connection.disconnect()
        XCTAssertEqual(try json(config3p)["deploymentMode"], .string("1p"))
    }

    func testASealedKeyIsUnknownRatherThanChanged() throws {
        try connection.connect(baseURL: url, token: token, now: Date())
        var sealed = try json(profile).objectValue ?? [:]
        sealed["inferenceGatewayApiKey"] = .string("__sealed__:v1:c3ludGhldGlj")
        try JSONEncoder().encode(JSONValue.object(sealed)).write(to: profile)
        XCTAssertEqual(connection.status(baseURL: url, token: token), .connected)
        XCTAssertEqual(connection.status(baseURL: DesktopConnection.baseURL(port: 9), token: token), .changed)
    }

    func testAProfileImportedByHandCountsAsConnected() throws {
        try put(#"{"appliedId":"imported","entries":[{"id":"imported","name":"Claude Pool"}]}"#, meta)
        try put(#"{"inferenceProvider":"gateway","inferenceGatewayBaseUrl":"\#(url)","inferenceGatewayApiKey":"\#(token)","inferenceGatewayAuthScheme":"bearer"}"#,
                meta.deletingLastPathComponent().appendingPathComponent("imported.json"))
        XCTAssertEqual(connection.status(baseURL: url, token: token), .connected)
        XCTAssertFalse(try connection.disconnect(), "Pool did not write it, so it is not Pool's to remove")
    }

    func testNothingIsWrittenWhenAFileIsNotAnObject() throws {
        try put(#"{"deploymentMode":"1p"}"#, config3p)
        try put("[1, 2]", config)
        XCTAssertThrowsError(try connection.connect(baseURL: url, token: token, now: Date())) {
            XCTAssertEqual($0 as? DesktopConnectionError, .unreadable("claude_desktop_config.json"))
        }
        XCTAssertEqual(try json(config3p)["deploymentMode"], .string("1p"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: meta.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
    }

    func testASymlinkedSettingsFileIsRefused() throws {
        let elsewhere = home.appendingPathComponent("elsewhere.json")
        try put("{}", elsewhere)
        try FileManager.default.createDirectory(at: config3p.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: config3p, withDestinationURL: elsewhere)
        XCTAssertThrowsError(try connection.connect(baseURL: url, token: token, now: Date()))
        XCTAssertEqual(try Data(contentsOf: elsewhere), Data("{}".utf8))
    }

    func testConnectedAtMovesOnlyWhenDesktopsFilesChange() throws {
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        try connection.connect(baseURL: url, token: token, now: first)
        try connection.connect(baseURL: url, token: token, now: first.addingTimeInterval(60))
        XCTAssertEqual(connection.connectedAt, first)
        try connection.connect(baseURL: DesktopConnection.baseURL(port: 18474), token: token, now: first.addingTimeInterval(120))
        XCTAssertEqual(connection.connectedAt, first.addingTimeInterval(120))
    }

    /// A profile an earlier Pool wrote has no tool search: it reads as outdated until Connect
    /// writes it again. A value the user set in Desktop, false too, stays theirs.
    func testToolSearchIsSeededOnceAndAnOlderProfileAsksForAnUpdate() throws {
        try connection.connect(baseURL: url, token: token, now: Date())
        var written = try json(profile).objectValue!
        written.removeValue(forKey: "toolSearchEnabled")
        try put(String(decoding: try JSONValue.object(written).encoded(), as: UTF8.self), profile)
        XCTAssertEqual(connection.status(baseURL: url, token: token), .outdated)
        XCTAssertTrue(try connection.connect(baseURL: url, token: token, now: Date()))
        XCTAssertEqual(try json(profile)["toolSearchEnabled"], .bool(true))
        XCTAssertEqual(connection.status(baseURL: url, token: token), .connected)

        written["toolSearchEnabled"] = .bool(false)
        try put(String(decoding: try JSONValue.object(written).encoded(), as: UTF8.self), profile)
        XCTAssertFalse(try connection.connect(baseURL: url, token: token, now: Date()))
        XCTAssertEqual(try json(profile)["toolSearchEnabled"], .bool(false))
        XCTAssertEqual(connection.status(baseURL: url, token: token), .connected)
    }

    /// A profile written before Pool set Desktop's home leaves Chat off: it reads as outdated until
    /// Connect writes `standard`. A home the user chose in Desktop, `off` too, stays theirs.
    func testDesktopHomeIsSeededOnceAndAnOlderProfileAsksForAnUpdate() throws {
        try connection.connect(baseURL: url, token: token, now: Date())
        var written = try json(profile).objectValue!
        written.removeValue(forKey: "desktopHome")
        try put(String(decoding: try JSONValue.object(written).encoded(), as: UTF8.self), profile)
        XCTAssertEqual(connection.status(baseURL: url, token: token), .outdated)
        XCTAssertTrue(try connection.connect(baseURL: url, token: token, now: Date()))
        XCTAssertEqual(try json(profile)["desktopHome"], .string("standard"))
        XCTAssertEqual(connection.status(baseURL: url, token: token), .connected)

        written["desktopHome"] = .string("off")
        try put(String(decoding: try JSONValue.object(written).encoded(), as: UTF8.self), profile)
        XCTAssertFalse(try connection.connect(baseURL: url, token: token, now: Date()))
        XCTAssertEqual(try json(profile)["desktopHome"], .string("off"))
        XCTAssertEqual(connection.status(baseURL: url, token: token), .connected)
    }
}
