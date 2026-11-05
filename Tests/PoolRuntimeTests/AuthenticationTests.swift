import Foundation
import XCTest
import PoolCore
@testable import PoolRuntime

final class AuthenticationTests: XCTestCase {
    private let directory = URL(fileURLWithPath: "/synthetic/accounts/one/cli")
    private func status(_ changes: [String: Any] = [:]) throws -> Data {
        var value: [String: Any] = ["loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty",
            "configDirectory": directory.path, "subscriptionType": "max", "email": "mi•••ella@example.com", "accountId": "synthetic"]
        value.merge(changes) { _, next in next }
        return try JSONSerialization.data(withJSONObject: value)
    }

    func testOnlyVerifiedSubscriptionMetadataLeavesParser() throws {
        let result = try OfficialCLI.parseAuthStatus(status(), expectedDirectory: directory)
        XCTAssertEqual(result, AuthStatus(email: "mi•••ella@example.com", plan: "Max"))
        XCTAssertTrue(result.subscribed)
        XCTAssertThrowsError(try OfficialCLI.parseAuthStatus(status(["loggedIn": false]), expectedDirectory: directory)) {
            XCTAssertEqual($0 as? RuntimeError, .signedOut)
        }
        for method in ["oauth_token", "api_key", "api_key_helper", "third_party", "unknown"] {
            XCTAssertThrowsError(try OfficialCLI.parseAuthStatus(status(["authMethod": method]), expectedDirectory: directory)) {
                XCTAssertEqual($0 as? RuntimeError, .unsupportedAuthentication)
            }
        }
    }

    func testWrongOrMissingAccountDirectoryFails() throws {
        for wrong: Any in ["/synthetic/default/cli", NSNull(), "relative/cli"] {
            XCTAssertThrowsError(try OfficialCLI.parseAuthStatus(status(["configDirectory": wrong]), expectedDirectory: directory)) {
                XCTAssertEqual($0 as? RuntimeError, .invalidAuthentication)
            }
        }
        XCTAssertThrowsError(try OfficialCLI.parseAuthStatus(Data("not JSON".utf8), expectedDirectory: directory))
        XCTAssertThrowsError(try OfficialCLI.parseAuthStatus(status(["subscriptionType": ["invalid"]]), expectedDirectory: directory))
    }

    func testOfficialEmailAndOrganizationScopeAreValidatedWithoutPersistingVendorIDs() throws {
        let organization = "0a1b2c3d-1111-4aaa-8bbb-000000000001"
        let first = try OfficialCLI.parseAuthStatus(status(["orgId": organization]), expectedDirectory: directory)
        let same = try OfficialCLI.parseAuthStatus(status(["orgId": organization.uppercased(), "email": "MI•••ELLA@example.com"]), expectedDirectory: directory)
        XCTAssertEqual(first.identityFingerprint, same.identityFingerprint)
        XCTAssertEqual(first.identityFingerprint?.count, 64)
        XCTAssertFalse(first.identityFingerprint?.contains(organization) ?? true)
        let other = try OfficialCLI.parseAuthStatus(status(["orgId": "0a1b2c3d-2222-4aaa-8bbb-000000000002"]), expectedDirectory: directory)
        XCTAssertNotEqual(first.identityFingerprint, other.identityFingerprint)
        let absent = try OfficialCLI.parseAuthStatus(status(["orgId": NSNull()]), expectedDirectory: directory)
        XCTAssertNil(absent.identityFingerprint)
        for email in ["", "not-an-email", "first@@gmail.com", "a@example.com\n", String(repeating: "a", count: 330) + "@gmail.com"] {
            XCTAssertThrowsError(try OfficialCLI.parseAuthStatus(status(["email": email]), expectedDirectory: directory))
        }
        XCTAssertThrowsError(try OfficialCLI.parseAuthStatus(status(["orgId": "unexpected"]), expectedDirectory: directory))
        let future = try OfficialCLI.parseAuthStatus(status(["subscriptionType": "future_paid"]), expectedDirectory: directory)
        XCTAssertEqual(future.plan, "Plan unknown")
        XCTAssertEqual(future.subscription, .unknown)
        XCTAssertFalse(future.subscribed)
    }

    func testPlanChangesAreReportedWithoutTreatingFreeAsAnAuthenticationFailure() throws {
        let organization = "0a1b2c3d-1111-4aaa-8bbb-000000000001"
        let reported = try ["pro", "max", "free", "pro"].map {
            try OfficialCLI.parseAuthStatus(status(["subscriptionType": $0, "orgId": organization]), expectedDirectory: directory)
        }
        XCTAssertEqual(reported.map(\.plan), ["Pro", "Max", "Free", "Pro"])
        XCTAssertEqual(reported.map(\.subscription), [.subscribed, .subscribed, .required, .subscribed])
        XCTAssertEqual(Set(reported.compactMap(\.identityFingerprint)).count, 1)
        XCTAssertEqual(Set(reported.map(\.email)), ["mi•••ella@example.com"])
        XCTAssertFalse(reported[2].subscribed)
    }

    func testMissingAndUnknownPlanRemainDistinctFromFree() throws {
        for kind: Any in [NSNull(), "", "none", "unknown", "future_paid"] {
            let observed = try OfficialCLI.parseAuthStatus(status(["subscriptionType": kind]), expectedDirectory: directory)
            XCTAssertEqual(observed.subscription, .unknown)
            XCTAssertEqual(observed.plan, "Plan unknown")
            XCTAssertFalse(observed.subscribed)
        }
        var missing = try XCTUnwrap(JSONSerialization.jsonObject(with: status()) as? [String: Any])
        missing.removeValue(forKey: "subscriptionType")
        let absent = try OfficialCLI.parseAuthStatus(JSONSerialization.data(withJSONObject: missing), expectedDirectory: directory)
        XCTAssertEqual(absent.subscription, .unknown)
        for kind in ["pro", "free"] {
            XCTAssertThrowsError(try OfficialCLI.parseAuthStatus(status(["loggedIn": false, "subscriptionType": kind]), expectedDirectory: directory)) {
                XCTAssertEqual($0 as? RuntimeError, .signedOut)
            }
        }
    }

    func testEnvironmentKeepsOrdinaryOSAndProxySettingsWithoutRoutingOrInjection() {
        let original = ["HOME": "/synthetic/home", "PATH": "/usr/bin:/bin", "HTTPS_PROXY": "http://127.0.0.1:9000",
            "ANTHROPIC_API_KEY": "synthetic", "ANTHROPIC_BASE_URL": "http://127.0.0.1:9001",
            "CLAUDE_CODE_OAUTH_TOKEN": "synthetic", "CLAUDE_CONFIG_DIR": "/synthetic/other",
            "CLAUDE_CODE_ENTRYPOINT": "other", "BUN_OPTIONS": "--preload synthetic.js", "NODE_OPTIONS": "synthetic",
            "CLAUDE_CODE_SKIP_PERMISSION_PROMPTS": "1", "UNRELATED_SECRET": "synthetic"]
        let result = OfficialCLI.environment(for: directory, inherited: original)
        XCTAssertEqual(result["HOME"], original["HOME"])
        XCTAssertEqual(result["PATH"], original["PATH"])
        XCTAssertEqual(result["HTTPS_PROXY"], original["HTTPS_PROXY"])
        XCTAssertEqual(result["CLAUDE_CONFIG_DIR"], directory.path)
        XCTAssertEqual(Set(result.keys), ["HOME", "PATH", "HTTPS_PROXY", "CLAUDE_CONFIG_DIR", "TERM", "LANG", "DISABLE_AUTOUPDATER", "DISABLE_UPDATES"])
    }

    private func fixture(script: String) throws -> (OfficialCLI, UUID, URL) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/runtime-fixtures/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("fake-client")
        try Data(("#!/bin/sh\n" + script).utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let workspace = OwnedWorkspace(root: root.appendingPathComponent("app"))
        return (OfficialCLI(executable: executable, workspace: workspace), UUID(), root)
    }

    func testOfficialStatusCommandUsesTheIsolatedDirectory() async throws {
        let (cli, id, _) = try fixture(script: "test \"$1 $2\" = 'auth status' || exit 9\nprintf '{\"loggedIn\":true,\"authMethod\":\"claude.ai\",\"subscriptionType\":\"pro\",\"email\":\"mi•••ella@example.com\",\"configDirectory\":\"%s\"}\\n' \"$CLAUDE_CONFIG_DIR\"\n")
        let result = try await cli.authenticationStatus(accountID: id)
        XCTAssertEqual(result.plan, "Pro")
        XCTAssertNil(cli.activeProcess(accountID: id))
    }

    func testOfficialLogoutUsesOnlyTheIsolatedAccountAndLeavesMetadataToCaller() async throws {
        let (cli, id, _) = try fixture(script: "test \"$1 $2\" = 'auth logout' || exit 9\nprintf 'signed out' > \"$CLAUDE_CONFIG_DIR/logout-marker\"\n")
        let store = PoolStore(workspace: cli.workspace)
        let library = PoolLibrary(accounts: [PoolAccount(id: id, email: "mi•••ella@example.com", state: .ready)])
        try await store.save(library)
        try await cli.logout(accountID: id)
        let marker = try cli.workspace.accountDirectory(id).appendingPathComponent("logout-marker")
        XCTAssertEqual(try cli.workspace.read(marker), Data("signed out".utf8))
        let retained = try await store.load()
        XCTAssertEqual(retained, library)
        XCTAssertNil(cli.activeProcess(accountID: id))
    }

    func testFailedOfficialLogoutCannotRemoveCallerMetadata() async throws {
        let (cli, id, _) = try fixture(script: "test \"$1 $2\" = 'auth logout' || exit 9\nexit 4\n")
        let store = PoolStore(workspace: cli.workspace)
        let library = PoolLibrary(accounts: [PoolAccount(id: id, email: "mi•••ella@example.com", state: .ready)])
        try await store.save(library)
        do { try await cli.logout(accountID: id); XCTFail("Failed sign-out must not succeed") }
        catch { XCTAssertEqual(error as? RuntimeError, .signOutFailed) }
        let retained = try await store.load()
        XCTAssertEqual(retained, library)
        XCTAssertNil(cli.activeProcess(accountID: id))
    }

    func testFailedStatusDoesNotInventSignOutOrDowngrade() async throws {
        let (cli, id, _) = try fixture(script: "printf 'Connection unavailable\\n'\nexit 2\n")
        let store = PoolStore(workspace: cli.workspace)
        let library = PoolLibrary(accounts: [PoolAccount(id: id, email: "mi•••ella@example.com", plan: "Pro", state: .ready)])
        try await store.save(library)
        do { _ = try await cli.authenticationStatus(accountID: id); XCTFail("A failed check must remain unknown") }
        catch { XCTAssertEqual(error as? RuntimeError, .invalidAuthentication) }
        let preserved = try await store.load()
        XCTAssertEqual(preserved.accounts.first?.plan, "Pro")
        XCTAssertEqual(preserved, library)
    }

    func testExpiredAuthenticationUsesOnlyTheOfficialSignedOutResult() async throws {
        let (cli, id, _) = try fixture(script: "printf '{\"loggedIn\":false,\"authMethod\":\"none\"}\\n'\nexit 1\n")
        do { _ = try await cli.authenticationStatus(accountID: id); XCTFail("Expired official sign-in must not be usable") }
        catch { XCTAssertEqual(error as? RuntimeError, .signedOut) }
        XCTAssertNil(cli.activeProcess(accountID: id))
    }

    func testCancelledStatusPreservesAnAccessibleOwnedProcess() async throws {
        try await exerciseCancelledCommand(logout: false)
    }

    func testCancelledLogoutPreservesAnAccessibleOwnedProcess() async throws {
        try await exerciseCancelledCommand(logout: true)
    }

    private func exerciseCancelledCommand(logout: Bool) async throws {
        let (cli, id, _) = try fixture(script: "trap '' INT\nprintf 'ready' > \"$CLAUDE_CONFIG_DIR/ready\"\nwhile IFS= read -r -t 5 answer; do test \"$answer\" = 'finish' && break; done\nprintf 'finished' > \"$CLAUDE_CONFIG_DIR/finished\"\n")
        let attempt = Task {
            if logout { try await cli.logout(accountID: id) }
            else { _ = try await cli.authenticationStatus(accountID: id) }
        }
        var active: (any OwnedChild)?
        let deadline = Date().addingTimeInterval(5)
        func ready() -> Bool {
            guard let directory = try? cli.workspace.accountDirectory(id) else { return false }
            return FileManager.default.fileExists(atPath: directory.appendingPathComponent("ready").path)
        }
        while (active == nil || !ready()) && Date() < deadline {
            active = cli.activeProcess(accountID: id)
            try await Task.sleep(for: .milliseconds(10))
        }
        let process = try XCTUnwrap(active)
        let directory = try cli.workspace.accountDirectory(id)
        addTeardownBlock {
            if process.isRunning {
                try process.write(Data("finish\n".utf8))
                _ = try await process.waitForExit(timeout: 5)
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("ready").path))
        XCTAssertEqual(process is OwnedPipeProcess, !logout, "Machine-readable status must not run in a terminal")
        attempt.cancel()
        do { _ = try await attempt.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(process.isRunning)
        try process.write(Data("finish\n".utf8))
        _ = try await process.waitForExit(timeout: 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("finished").path))
        XCTAssertNil(cli.activeProcess(accountID: id))
    }

    /// The official client renders `auth status` for a terminal with cursor controls and hard wraps
    /// (observed from 2.1.317 in the no-network inspection sandbox). Only a pipe yields the JSON document.
    func testStatusReadsTheOfficialJSONDocumentRatherThanTerminalRendering() async throws {
        let (cli, id, _) = try fixture(script: """
        test "$1 $2 $3" = 'auth status --json' || exit 9
        if test -t 1; then
          printf '\\033[?25h{\\r\\r\\n\\033[3G"loggedIn":\\033[15Gtrue,\\r\\r\\n"configDirectory": "%s\\r\\r\\n"}\\r\\r\\n\\033[?2004l' "$CLAUDE_CONFIG_DIR"
          exit 0
        fi
        printf '{\\n  "loggedIn": true,\\n  "authMethod": "claude.ai",\\n  "apiProvider": "firstParty",\\n  "email": "mi•••ella@example.com",\\n  "orgId": "6f1f9d2e-0c4f-4a43-9d7e-2b7f6b9a1c11",\\n  "subscriptionType": "max",\\n  "configDirectory": "%s"\\n}\\n' "$CLAUDE_CONFIG_DIR"

        """)
        let result = try await cli.authenticationStatus(accountID: id)
        XCTAssertEqual(result.email, "mi•••ella@example.com")
        XCTAssertEqual(result.plan, "Max")
        XCTAssertNotNil(result.identityFingerprint)
        XCTAssertNil(cli.activeProcess(accountID: id))
    }

    func testLoginRequestsTheSubscriptionSignInExplicitly() async throws {
        let (cli, id, _) = try fixture(script: "printf '%s|' \"$@\" > \"$CLAUDE_CONFIG_DIR/arguments\"\n")
        let child = try cli.startLogin(accountID: id)
        _ = try await child.waitForExit()
        let recorded = try cli.workspace.read(cli.workspace.accountDirectory(id).appendingPathComponent("arguments"))
        XCTAssertEqual(String(decoding: recorded, as: UTF8.self), "auth|login|--claudeai|")
    }
}
