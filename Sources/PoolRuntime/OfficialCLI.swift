import Foundation
import CryptoKit
import PoolCore

public enum AuthSubscription: String, Equatable, Sendable { case subscribed, required, unknown }

public struct AuthStatus: Equatable, Sendable {
    public let email: String
    public let plan: String
    public let identityFingerprint: String?
    public let subscription: AuthSubscription
    public var subscribed: Bool { subscription == .subscribed }
    public init(email: String, plan: String, identityFingerprint: String? = nil,
                subscription: AuthSubscription = .subscribed) {
        self.email = email; self.plan = plan; self.identityFingerprint = identityFingerprint; self.subscription = subscription
    }
}

public final class OfficialCLI: @unchecked Sendable {
    public let executable: URL
    public let workspace: OwnedWorkspace
    private let lock = NSLock()
    private var accountProcesses: [UUID: any OwnedChild] = [:]

    public init(executable: URL, workspace: OwnedWorkspace) {
        self.executable = executable; self.workspace = workspace
    }

    public static func environment(for accountDirectory: URL,
                                   inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        let retained: Set<String> = [
            "HOME", "USER", "LOGNAME", "PATH", "SHELL", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "LC_MESSAGES", "TZ",
            "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "all_proxy", "no_proxy",
            "SSL_CERT_FILE", "SSL_CERT_DIR", "NODE_EXTRA_CA_CERTS"
        ]
        var result = inherited.filter { retained.contains($0.key) }
        result["CLAUDE_CONFIG_DIR"] = accountDirectory.path
        result["TERM"] = "xterm-256color"
        result["LANG"] = result["LANG"] ?? "en_US.UTF-8"
        result["DISABLE_AUTOUPDATER"] = "1"
        result["DISABLE_UPDATES"] = "1"
        return result
    }

    /// An inference session's environment: the account's, with the controls Pool gives
    /// every interactive run. What it blocks and what its helper strips from a child is already outside
    /// `environment(for:)`'s list of kept variables.
    public static func sessionEnvironment(for accountDirectory: URL,
                                          inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var result = environment(for: accountDirectory, inherited: inherited)
        result["ENABLE_CLAUDEAI_MCP_SERVERS"] = "0"
        result["DISABLE_AUTO_COMPACT"] = "1"
        result["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] = "1"
        // every run of an account works in one folder: a memory one conversation wrote there
        // would be in all the others' prompts
        result["CLAUDE_CODE_DISABLE_AUTO_MEMORY"] = "1"
        result["CLAUDE_CODE_DISABLE_GIT_INSTRUCTIONS"] = "1"
        // an hour's cache, as Claude Code writes it on a subscription within its limits
        result["CLAUDE_CODE_PROMPT_CACHE_TTL"] = "1h"
        // a call to the client's tools waits for the client's result: Claude Code would otherwise move
        // one running past two minutes to the background, end its turn, and leave the result Desktop
        // brings later with nothing waiting for it. Desktop's own Claude Code decides what runs in
        // the background.
        result["CLAUDE_CODE_MCP_AUTO_BACKGROUND_MS"] = "0"
        // the client's tool results come as sized by Desktop's own Claude Code: past 12,500 estimated
        // tokens the run would otherwise stop to count each one with an extra request, and cut one
        // past 25,000. Each mirrored tool also declares the highest result ceiling (OfficialSession).
        result["MAX_MCP_OUTPUT_TOKENS"] = "1000000"
        return result
    }

    /// The file an inference session's stream tap writes to.
    public static let tapVariable = "CLAUDE_POOL_TAP"

    /// What has one run's client load Pool's tap on its reply stream: Claude Code is a Bun program,
    /// and Bun loads what BUN_OPTIONS `--preload`s before it. Bun splits BUN_OPTIONS at whitespace with no
    /// quoting, so a script path with whitespace gives none. Only that run's environment has it,
    /// and the script takes both out of what the client hands on. A BUN_OPTIONS of Pool's own
    /// environment is never kept (`environment(for:)` keeps a fixed list), so this is the whole of it.
    public static func tapEnvironment(preload: String, output: String) -> [String: String]? {
        let blank = { (text: String) in text.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) } }
        guard preload.hasPrefix("/"), output.hasPrefix("/"), !blank(preload),
              !output.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { return nil }
        return ["BUN_OPTIONS": "--preload " + preload, tapVariable: output]
    }

    public func activeProcess(accountID: UUID) -> (any OwnedChild)? {
        lock.withLock {
            guard let process = accountProcesses[accountID], process.isRunning else {
                accountProcesses[accountID] = nil; return nil
            }
            return process
        }
    }

    public func startLogin(accountID: UUID) throws -> OwnedPTY {
        try start(accountID: accountID, arguments: ["auth", "login", "--claudeai"])
    }

    public func logout(accountID: UUID, timeout: TimeInterval = 15) async throws {
        let process = try start(accountID: accountID, arguments: ["auth", "logout"])
        defer {
            lock.withLock {
                if !process.isRunning, accountProcesses[accountID] === process { accountProcesses[accountID] = nil }
            }
        }
        do {
            guard try await process.waitForExit(timeout: timeout) == 0 else { throw RuntimeError.signOutFailed }
        } catch {
            if process.isRunning { try? process.interrupt() }
            throw error
        }
    }

    public func authenticationStatus(accountID: UUID, timeout: TimeInterval = 15) async throws -> AuthStatus {
        // A terminal renders this JSON with cursor controls and hard wraps; a pipe receives the document itself.
        let process = try start(accountID: accountID) { directory, environment in
            try OwnedPipeProcess.start(executable: executable, arguments: ["auth", "status", "--json"],
                                       environment: environment, directory: directory)
        }
        defer {
            lock.withLock {
                if !process.isRunning, accountProcesses[accountID] === process { accountProcesses[accountID] = nil }
            }
        }
        do {
            let result = try await process.waitForExit(timeout: timeout)
            guard process.outputBytesReceived <= 64 * 1024 else { throw RuntimeError.oversizedInput }
            let data = process.output
            if result != 0 {
                if let value = try? JSONDecoder().decode(JSONValue.self, from: data), value["loggedIn"]?.boolValue == false {
                    throw RuntimeError.signedOut
                }
                throw RuntimeError.invalidAuthentication
            }
            return try Self.parseAuthStatus(data, expectedDirectory: workspace.accountDirectory(accountID))
        } catch {
            if process.isRunning { try? process.interrupt() }
            throw error
        }
    }

    public static func parseAuthStatus(_ data: Data, expectedDirectory: URL) throws -> AuthStatus {
        guard data.count <= 64 * 1024 else { throw RuntimeError.oversizedInput }
        let value: JSONValue
        do { value = try JSONDecoder().decode(JSONValue.self, from: data) }
        catch { throw RuntimeError.invalidAuthentication }
        guard let loggedIn = value["loggedIn"]?.boolValue else { throw RuntimeError.invalidAuthentication }
        guard loggedIn else { throw RuntimeError.signedOut }
        guard value["authMethod"]?.stringValue == "claude.ai" else { throw RuntimeError.unsupportedAuthentication }
        if let provider = value["apiProvider"], provider != .null {
            guard let name = provider.stringValue else { throw RuntimeError.invalidAuthentication }
            guard name == "firstParty" else { throw RuntimeError.unsupportedAuthentication }
        }
        guard let directory = value["configDirectory"]?.stringValue, directory.hasPrefix("/"),
              URL(fileURLWithPath: directory).standardizedFileURL == expectedDirectory.standardizedFileURL else {
            throw RuntimeError.invalidAuthentication
        }
        let plans = ["pro": "Pro", "max": "Max", "max_5x": "Max 5x", "max_20x": "Max 20x",
                     "team": "Team", "enterprise": "Enterprise", "ultra": "Ultra"]
        var subscription = AuthSubscription.unknown
        var plan = "Plan unknown"
        if let raw = value["subscriptionType"], raw != .null {
            guard let kind = raw.stringValue?.lowercased(), kind.isEmpty ||
                  kind.range(of: #"\A[a-z0-9][a-z0-9_-]{0,63}\z"#, options: .regularExpression) != nil else {
                throw RuntimeError.invalidAuthentication
            }
            if kind == "free" { subscription = .required; plan = "Free" }
            else if let label = plans[kind] { subscription = .subscribed; plan = label }
        }
        guard let email = value["email"]?.stringValue, email.utf8.count <= 320,
              !email.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              email.split(separator: "@", omittingEmptySubsequences: false).count == 2,
              email.first != "@", email.last != "@" else { throw RuntimeError.invalidAuthentication }
        var fingerprint: String?
        if let organization = value["orgId"]?.stringValue {
            guard let id = UUID(uuidString: organization) else { throw RuntimeError.invalidAuthentication }
            let identity = email.precomposedStringWithCanonicalMapping.lowercased() + "\0" + id.uuidString.lowercased()
            fingerprint = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        } else if let organization = value["orgId"], organization != .null { throw RuntimeError.invalidAuthentication }
        return AuthStatus(email: email, plan: plan, identityFingerprint: fingerprint, subscription: subscription)
    }

    private func start(accountID: UUID, arguments: [String]) throws -> OwnedPTY {
        try start(accountID: accountID) { [executable] directory, environment in
            try OwnedPTY.start(executable: executable, arguments: arguments, environment: environment, directory: directory)
        }
    }

    private func start<Child: OwnedChild>(accountID: UUID,
                                          _ launch: (URL, [String: String]) throws -> Child) throws -> Child {
        try lock.withLock {
            guard accountProcesses[accountID]?.isRunning != true else { throw RuntimeError.processBusy }
            try workspace.prepare()
            let directory = try workspace.accountDirectory(accountID)
            let process = try launch(workspace.workDirectory(accountID), Self.environment(for: directory))
            accountProcesses[accountID] = process
            return process
        }
    }
}
