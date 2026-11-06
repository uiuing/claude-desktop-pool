import Foundation
import PoolCore
import PoolRuntime

/// One official interactive Claude Code run for one conversation, driven in its
/// interactive mode: the message is pasted and sent as a person sends it, and the turn —
/// taken, its usage, its end or the client's own error — is read from the session's transcript
/// (ClaudeTranscript). The reply is told as Anthropic streams it where the client loads Pool's
/// tap (ClaudeTap), else a whole message at a time from the transcript, and its calls in the
/// message's order under Claude Code's own tool-use ids (ClaudeReply). Hooks are hints only (a
/// dialog, the client's end); the status line gives quota windows and the model. No turn fails
/// because a hook is missing or shaped otherwise. Pool never signals or force-ends the process:
/// it leaves with `/exit` or the client's own interrupt keys.
public actor OfficialSession: SessionWorker {
    public nonisolated let id: UUID
    public nonisolated let accountSnapshot: PoolAccount?
    private let workspace: OwnedWorkspace
    private let account: PoolAccount
    private let model: PoolModel
    private let executable: URL
    private let helperExecutable: URL
    private let launch: @Sendable (SessionLaunch) throws -> SessionTransport
    private let timeout: TimeInterval
    private let pasteTimeout: TimeInterval
    private let toolCatalogTimeout: TimeInterval
    private let returnReceiptTimeout: TimeInterval
    private let readyTimeout: TimeInterval
    private let commandSettle: TimeInterval
    private let tapWait: TimeInterval
    private let tapRoot: URL
    /// Claude Code's session the run writes: its own, or the shelved one it goes on from.
    private var sessionKey: String
    private nonisolated var runTag: String { String(ClaudeReplay.sessionKey(id).prefix(8)) }
    /// The shelved session this run goes on from (`--resume` on it, its id the
    /// run's), and whether the run's session outlives it (shelve).
    private var resumeFrom: String?
    private var keepSession = false
    /// What the turn may call and its answer tool: the
    /// answer a call gave, the turn's words held back meanwhile, and whether it was asked for one.
    private var turnChoice: String?
    private var answerName: String?
    private var answerSchema: JSONValue?
    private var answer: JSONValue?
    private var answerAsked = false
    private var heldWords = ""

    private var transport: SessionTransport?
    private var plan: SessionLaunch?
    private var directory: URL?
    private var accountDirectory: URL?
    private var workDirectory: URL?
    private var transcript: ClaudeTranscript?
    private var resumed = false
    private var retriedWhole = false
    private var exitedBeforeReady = false
    private var launchedAt = Date()
    private var firstPieces: [ClaudePrompt.Piece] = []
    private var wholePieces: [ClaudePrompt.Piece] = []

    private var response: AsyncThrowingStream<BridgeEvent, Error>.Continuation?
    private var responseID: UUID?
    private var observer: AsyncStream<WorkerObservation>.Continuation?
    private var observationStream: AsyncStream<WorkerObservation>?
    private var pollTask: Task<Void, Never>?
    private var processTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var deadline: Date?
    private var ready = false
    private var submitted = false
    private var ended = false
    private var nativeSessionEnded = false
    private var endedPublished = false
    private var invalidated = false
    private var requestingExit = false
    private var officialIdle = false
    private var screen = TerminalScreen()
    private var firstRun = FirstRunScreens()
    private var outputRevision = 0
    /// What the client drew since the last paste, as a terminal stream.
    private var drawn = Data()
    private enum Draft { case none, owned, submitted, uncertain }
    private var draft = Draft.none
    private var manualInputRevision = 0
    private var attachmentFiles: [URL] = []
    private var originalTools: [BridgeTool] = []
    private var originalSystem: JSONValue?
    private var toolNames: [String: String] = [:]
    private var toolAliases: [String: String] = [:]
    private var knownQuota: [String: QuotaWindow] = [:]
    private var reportedModel: ModelIdentity?
    private var quotaGenerations: [String: Int] = [:]
    private var observedInference = false
    private var acceptedRows = 0
    private var awaitingAccept = false
    private var turnFailed = false

    /// The turn's reply, told from the stream, the transcript and the helper's calls.
    private var reply: ClaudeReply
    private var tap: ClaudeTap?
    private var tapReported: String?
    /// This run's recent steps, written out when it fails, stalls or ends unexpectedly.
    private var trace = Diagnostics.Trace()
    /// When a reply open since then stopped hearing anything from the client, once logged.
    private var stalledSince: Date?
    /// A reply open this long with nothing from the client at all (no hook, stream event or
    /// transcript row) is logged as stalled, with its steps. Only logged: nothing is ended for it.
    static let stallAfter: TimeInterval = 90
    /// Stream events read and not yet told: they wait while a message typed in is not yet taken.
    private var streamQueue: [JSONValue] = []
    /// Transcript rows read and not yet handled: the first waits while its message's stream may
    /// still begin, or a turn's end while its streams end (tap.go before and settle), and the
    /// rest wait behind it.
    private var rows: [ClaudeTranscript.Row] = []
    private var holdUntil: Date?
    /// The calls the client was told and has not answered.
    private var outstanding: Set<String> = []
    /// The calls Claude Code made through the helper and waits on.
    private var waiting: Set<String> = []
    /// Results of calls the client answered before Claude Code made them: each goes on as its call
    /// is made, as Claude Code makes them one at a time.
    private var heldResults: [String: JSONValue] = [:]
    private var replyCalls = 0

    /// `imageAcknowledgementTimeout` is how long a paste may take to show;
    /// `readyTimeout` the one wait for the input box and the tool list (ReadyWait);
    /// `commandSettle` the pause before Return on a typed command (commandSettle); `tapWait` how
    /// long a transcript message waits for its stream, and a turn's end for its streams to end
    /// (tapWait); `callFirst` how long a call waits for its message before it tells the client
    /// itself (callFirst); `messageQuiet` how long a message told whole waits for more of its rows
    /// (unstreamedQuiet); `tapDirectory` where a tap goes when the run's folder has whitespace in
    /// its path, the user's temporary folder unless given.
    public init(id: UUID = UUID(), workspace: OwnedWorkspace, account: PoolAccount, model: PoolModel,
                executable: URL, helperExecutable: URL, timeout: TimeInterval = 600, imageAcknowledgementTimeout: TimeInterval = 10,
                toolCatalogTimeout: TimeInterval = 5, returnReceiptTimeout: TimeInterval = 3, readyTimeout: TimeInterval = 45,
                commandSettle: TimeInterval = 1, tapWait: TimeInterval = 1, callFirst: TimeInterval = 0.5,
                messageQuiet: TimeInterval = 0.3, tapDirectory: URL? = nil,
                launch: @escaping @Sendable (SessionLaunch) throws -> SessionTransport = { try SessionTransport.launch($0) }) {
        self.id = id; self.workspace = workspace; self.account = account; self.model = model
        accountSnapshot = account; sessionKey = ClaudeReplay.sessionKey(id)
        self.executable = executable; self.helperExecutable = helperExecutable; self.timeout = timeout
        pasteTimeout = imageAcknowledgementTimeout; self.launch = launch
        self.toolCatalogTimeout = toolCatalogTimeout; self.returnReceiptTimeout = returnReceiptTimeout
        self.readyTimeout = readyTimeout; self.commandSettle = commandSettle
        self.tapWait = tapWait
        tapRoot = tapDirectory ?? FileManager.default.temporaryDirectory
        reply = ClaudeReply(callFirst: callFirst, quiet: messageQuiet)
    }

    public func observations() -> AsyncStream<WorkerObservation> {
        if let observationStream { return observationStream }
        let stream = AsyncStream<WorkerObservation> { observer = $0 }
        observationStream = stream
        return stream
    }

    public func events(for request: BridgeRequest) async throws -> AsyncThrowingStream<BridgeEvent, Error> {
        try await begin(request, replayingCompletedTools: false)
    }

    /// Completed tool history whose run is gone: a new run goes on from the conversation's saved
    /// session, typed the turn since its last reply with the calls and results in it.
    public func events(replaying replay: VerifiedToolReplay) async throws -> AsyncThrowingStream<BridgeEvent, Error> {
        guard transport == nil, !submitted else { throw BridgeFailure.invalidRequest("Completed tool history needs a new session.") }
        return try await begin(replay.request, replayingCompletedTools: true)
    }

    private func begin(_ request: BridgeRequest, replayingCompletedTools: Bool) async throws -> AsyncThrowingStream<BridgeEvent, Error> {
        guard !ended, !invalidated else { throw BridgeFailure.transport }
        guard response == nil else { throw BridgeFailure.busy }
        let results = replayingCompletedTools ? [] : try RequestContent.toolResults(request)
        guard Set(results.map(\.0)).count == results.count else { throw BridgeFailure.invalidRequest("A tool result was supplied more than once.") }
        if submitted {
            if results.isEmpty && request.tools ?? [] != originalTools { throw BridgeFailure.unsupported("The tools changed. Start a new conversation to use the new tool set.") }
            guard request.system == originalSystem else { throw BridgeFailure.unsupported("The instructions changed. Start a new conversation to use the new instructions.") }
            if results.isEmpty && !outstanding.isEmpty { throw BridgeFailure.busy }
            for (callID, _) in results {
                guard outstanding.contains(callID) else { throw BridgeFailure.invalidRequest("This tool result has no pending call in this conversation.") }
            }
        } else if !results.isEmpty {
            throw BridgeFailure.invalidRequest("This tool result has no live Claude session.")
        }
        guard let last = request.messages.last, last.role == "user" else { throw BridgeFailure.invalidRequest("The last message must be from the user.") }
        if !results.isEmpty, last.content.arrayValue?.contains(where: { $0["type"]?.stringValue == "image" }) == true {
            throw BridgeFailure.unsupported("Send additional images after the current tools finish.")
        }
        let extraBlocks = results.isEmpty ? [] : last.content.arrayValue?.filter { $0["type"]?.stringValue == "text" } ?? []
        let extraText = extraBlocks.isEmpty ? nil : try RequestContent.text(.array(extraBlocks))
        var pieces: [ClaudePrompt.Piece]?
        if transport == nil {
            do { try start(request) } catch { invalidated = true; throw error }
            pieces = firstPieces
        } else if results.isEmpty {
            // a live session has the conversation: it is typed the messages since its last reply
            let since = (request.messages.lastIndex { $0.role == "assistant" }).map { $0 + 1 } ?? 0
            let turn = try ClaudePrompt.messages(Array(request.messages[since...]))
            pieces = ClaudePrompt.pieces(ClaudePrompt.turn(turn, name: callableName))
            try ClaudePrompt.validatePasted(pieces ?? [])
        }
        if !results.isEmpty, request.tools ?? [] != originalTools {
            // the list is taken up again before the results go on, at most toolCatalogTimeout,
            // then they go on anyway
            do {
                let revision = try publishTools(offered(request))
                originalTools = request.tools ?? []
                if !(try await awaitToolCatalog(revision)) {
                    Diagnostics.record("session.catalog_late", ["run": runTag, "tools": String(originalTools.count)])
                }
            } catch {
                invalidated = true; observer?.yield(.attention)
                throw error
            }
        }
        let token = UUID()
        let stream = AsyncThrowingStream<BridgeEvent, Error> { continuation in
            response = continuation
            continuation.onTermination = { [weak self] reason in
                if case .cancelled = reason { Task { await self?.cancelResponse(token) } }
            }
        }
        responseID = token; deadline = results.isEmpty ? nil : Date().addingTimeInterval(timeout)
        trace.note("reply.open:results=\(results.count)"); stalledSince = nil
        if pollTask != nil { startPolling() }
        reply.newReply(); replyCalls = 0
        // the turn may call what this request lets it, set at each continuation
        turnChoice = request.toolChoice
        if results.isEmpty { answer = nil; answerAsked = false; heldWords = "" }
        if let pieces {
            inputTask = Task { [weak self] in await self?.send(pieces, responseToken: token) }
        } else if let directory {
            if let extraText {
                inputTask = Task { [weak self] in await self?.deliver(results, extraText: extraText, to: directory, responseToken: token) }
            } else {
                do { try deliver(results, to: directory) } catch { fail(error) }
            }
        }
        return stream
    }

    /// The tools the session is offered for a request: the client's, less those a named tool choice rules
    /// out, and the answer tool when the answer has a schema.
    private func offered(_ request: BridgeRequest) -> [BridgeTool] {
        var tools = TurnChoice.offered(request.tools ?? [], toolChoice: request.toolChoice)
        if let answerName, let answerSchema {
            tools.append(BridgeTool(name: answerName, description: TurnChoice.answerToolDescription, inputSchema: answerSchema))
        }
        return tools
    }

    /// The name the session calls a client tool by: the MCP helper's, under its server.
    private func callableName(_ name: String) -> String {
        toolAliases[name].map { "mcp__pool__" + $0 } ?? name
    }

    private func start(_ request: BridgeRequest) throws {
        try workspace.prepare()
        let directory = try workspace.runDirectory(id)
        self.directory = directory
        for name in ["events", "results", "work"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(name), withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        try EngineSpool.write(.object(["session_id": .string(id.uuidString)]), to: directory.appendingPathComponent("run.json"))
        originalTools = request.tools ?? []
        originalSystem = request.system
        answerSchema = request.answerSchema.map(TurnChoice.toolSchema)
        answerName = answerSchema == nil ? nil : TurnChoice.answerName(avoiding: originalTools)
        _ = try publishTools(offered(request))
        if resumeFrom != nil, ClaudePrompt.historyEnd(try ClaudePrompt.messages(request.messages)) == 0 {
            // nothing the shelved session holds is this conversation's: the run is its own
            resumeFrom = nil; sessionKey = ClaudeReplay.sessionKey(id)
        }
        let config = try workspace.accountDirectory(account.id), work = try workspace.workDirectory(account.id)
        accountDirectory = config; workDirectory = work

        // What is typed, and the saved session it goes on from (claude_replay.go:31-93): a
        // conversation with a reply in it is given to the client as its own transcript, and only
        // the turn after the reply is typed. Told whole otherwise, or when that cannot be.
        let messages = try ClaudePrompt.messages(request.messages)
        let whole = ClaudePrompt.pieces(ClaudePrompt.whole(messages, name: callableName))
        wholePieces = whole
        let split = ClaudePrompt.historyEnd(messages)
        var replay: (data: Data, pieces: [ClaudePrompt.Piece])?
        if split >= 2, case let reply = ClaudePrompt.replyWords(messages[split - 1]), !reply.isEmpty {
            let user = ClaudePrompt.whole(Array(messages[..<(split - 1)]), name: callableName)
            let data = try ClaudeReplay.lines(user: user, reply: reply, session: sessionKey, work: work.path,
                                              model: model.listedID, at: Date())
            replay = (data, ClaudePrompt.pieces(ClaudePrompt.turn(Array(messages[split...]), name: callableName)))
        }
        try ClaudePrompt.validatePasted(replay?.pieces ?? whole)
        firstPieces = whole

        let helper = shellQuote(helperExecutable.path), run = shellQuote(directory.path)
        var hooks: [String: JSONValue] = [:]
        // hints only: a dialog the person must answer, and the client's own end
        for event in ["PermissionRequest", "Notification", "SessionEnd"] {
            hooks[event] = .array([.object(["hooks": .array([.object([
                "type": .string("command"), "command": .string("\(helper) --bridge-hook \(run) \(event)"), "timeout": .number(10)
            ])])])])
        }
        let settings = JSONValue.object([
            "disableDeepLinkRegistration": .string("disable"),
            "hooks": .object(hooks),
            "statusLine": .object(["type": .string("command"), "command": .string("\(helper) --bridge-hook \(run) statusLine")])])
        let settingsURL = directory.appendingPathComponent("settings.json")
        try EngineSpool.write(settings, to: settingsURL)
        let mcpURL = directory.appendingPathComponent("mcp.json")
        let mcp = JSONValue.object(["mcpServers": .object(["pool": .object([
            "command": .string(helperExecutable.path), "args": .array([.string("--mcp-helper"), .string(directory.path)])
        ])])])
        try EngineSpool.write(mcp, to: mcpURL)
        // Claude Code's own WebSearch where the client offered Anthropic's
        var arguments = ["--session-id", sessionKey, "--model", model.cliAlias,
                         "--tools", request.webSearch ? "WebSearch" : "", "--strict-mcp-config", "--mcp-config", mcpURL.path,
                         "--setting-sources", "", "--settings", settingsURL.path]
        // The client's instructions follow Claude Code's own system prompt, never replace it:
        // Anthropic refused interactive turns whose system prompt was a client's.
        let system = try request.system.map { ClaudePrompt.withoutBillingHeader(try RequestContent.text($0)) } ?? ""
        // and what the client's tool choice asks, appended with the instructions
        let appended = (system + ClaudePrompt.environmentNote(system: system, messages: request.messages) +
                        TurnChoice.ask(request.toolChoice, callable: callableName))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !appended.isEmpty {
            let systemURL = directory.appendingPathComponent("instructions.txt")
            try workspace.write(Data(appended.utf8), to: systemURL)
            arguments += ["--append-system-prompt-file", systemURL.path]
        }
        arguments += ["--permission-mode", "default", "--allowedTools", "mcp__pool"] + (request.webSearch ? ["WebSearch"] : []) + ["--no-chrome"]
        var environment = OfficialCLI.sessionEnvironment(for: config, inherited: ProcessInfo.processInfo.environment)
        // Kept for the reason docs/architecture.md gives: forwarded client
        // text must not read host files through @-mentions or import CLAUDE.md files from the
        // folders above the account's, and the client already chose which of its tools are
        // loaded, so the session offers exactly those rather than a search of its own.
        environment["CLAUDE_CODE_DISABLE_FILE_MENTIONS"] = "1"
        environment["CLAUDE_CODE_DISABLE_CLAUDE_MDS"] = "1"
        environment["ENABLE_TOOL_SEARCH"] = "false"
        // The reply's stream: the run's Claude Code loads Pool's tap. Only this run's child is
        // given it, and the script takes it out of what the client hands on. Without one the reply is told a whole message at a time.
        tap = ClaudeTap.make(run: directory, temporary: tapRoot)
        if let tap { for (key, value) in tap.environment { environment[key] = value } }
        else { Diagnostics.record("session.tap", ["run": runTag, "state": "unavailable"]) }
        // CLAUDE_CODE_SKIP_PROMPT_HISTORY is not set: the turn is read from the session's own
        // transcript, which that control would put at risk; cleanRun removes the file instead.
        // The saved session is written last, just before the run that takes it; a run that never
        // starts removes it.
        if resumeFrom != nil {
            // The run's own session holds the conversation up to its last reply
            firstPieces = ClaudePrompt.pieces(ClaudePrompt.turn(Array(messages[split...]), name: callableName))
            try ClaudePrompt.validatePasted(firstPieces)
            resumed = true; arguments[0] = "--resume"
        } else if let replay {
            do {
                _ = try ClaudeReplay.write(replay.data, config: config, work: work, session: sessionKey)
                firstPieces = replay.pieces; resumed = true
                arguments[0] = "--resume"
            } catch {
                Diagnostics.record("session.failed", ["run": runTag, "reason": "replay_unwritten", "history_messages": String(split)])
            }
        }
        let plan = SessionLaunch(executable: executable, arguments: arguments, environment: environment,
                                 directory: work, runDirectory: directory, sessionID: id)
        self.plan = plan
        transcript = ClaudeTranscript(config: config, work: work, session: sessionKey)
        do { try launchChild(plan, history: resumed ? split : 0, bytes: resumed ? replay?.data.count ?? 0 : 0) }
        catch {
            if resumed { ClaudeReplay.remove(config: config, work: work, session: sessionKey) }
            tap?.remove(); tap = nil
            throw error
        }
        startPolling()
    }

    /// Looks at what the run wrote, at the pace `poll` returns. Started again when a reply opens, so
    /// a run resting between turns looks at once instead of after its idle pause.
    private func startPolling() {
        guard !ended, !nativeSessionEnded else { return }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = await self?.poll() else { return }
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    private func launchChild(_ plan: SessionLaunch, history: Int, bytes: Int) throws {
        let child = try launch(plan)
        transport = child; launchedAt = Date()
        Diagnostics.record("session.started", ["run": runTag, "model": model.cliAlias, "resumed": resumed ? "yes" : "no",
                                               "history_messages": String(history), "transcript_bytes": String(bytes)])
        processTask = Task { [weak self] in
            for await event in child.events { await self?.process(event) }
        }
    }

    /// A resumed start the client ended at once (it can refuse a session it cannot load) is
    /// started again once, told the conversation whole (claude_subscription.go:857-863).
    private func relaunchWhole() throws {
        guard let plan, let accountDirectory, let workDirectory, let directory else { throw BridgeFailure.transport }
        Diagnostics.record("session.failed", ["run": runTag, "reason": "replay_failed",
                                              "ms": String(Int(Date().timeIntervalSince(launchedAt) * 1000))])
        retriedWhole = true; exitedBeforeReady = false; resumed = false
        try ClaudePrompt.validatePasted(wholePieces)
        ClaudeReplay.remove(config: accountDirectory, work: workDirectory, session: sessionKey)
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("tools-listed.json"))
        screen = TerminalScreen(); firstRun = FirstRunScreens(); drawn = Data()
        var next = plan
        if let index = next.arguments.firstIndex(of: "--resume") { next.arguments[index] = "--session-id" }
        self.plan = next
        firstPieces = wholePieces
        transcript = ClaudeTranscript(config: accountDirectory, work: workDirectory, session: sessionKey)
        tap?.restart(); streamQueue = []; rows = []; holdUntil = nil
        try launchChild(next, history: 0, bytes: 0)
    }

    private func publishTools(_ definitions: [BridgeTool]) throws -> String {
        guard let directory, definitions.count <= 256,
              Set(definitions.map(\.name)).count == definitions.count else { throw BridgeFailure.invalidRequest("Invalid tool catalog.") }
        var tools: [JSONValue] = []
        var aliases = toolAliases, names = toolNames
        var usedToolNames = Set(aliases.values)
        for tool in definitions {
            let nativeName = !tool.name.isEmpty && tool.name.utf8.count <= 48 &&
                tool.name.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
            let alias: String
            if let existing = aliases[tool.name] { alias = existing }
            else {
                var next = nativeName ? tool.name : "tool_\(aliases.count)"
                var suffix = aliases.count
                while !usedToolNames.insert(next).inserted { suffix += 1; next = "tool_\(suffix)" }
                alias = next; aliases[tool.name] = alias; names[alias] = tool.name
            }
            guard names.count <= 4096, tool.inputSchema.objectValue != nil else { throw BridgeFailure.invalidRequest("Invalid tool catalog.") }
            var definition: [String: JSONValue] = ["name": .string(alias), "inputSchema": tool.inputSchema]
            definition["description"] = .string(tool.name + (tool.description.map { ": " + $0 } ?? ""))
            tools.append(.object(definition))
        }
        let revision = UUID().uuidString
        try EngineSpool.write(.object(["revision": .string(revision), "tools": .array(tools)]), to: directory.appendingPathComponent("tools.json"))
        toolAliases = aliases; toolNames = names
        // the answer tool's calls are the bridge's own, never told to the client
        reply.names = names.filter { $0.value != answerName }
        return revision
    }

    /// Whether the helper listed this revision within the wait; false once the wait is over.
    private func awaitToolCatalog(_ revision: String) async throws -> Bool {
        guard let directory else { throw BridgeFailure.transport }
        let receipt = directory.appendingPathComponent("tools-listed.json"), until = Date().addingTimeInterval(toolCatalogTimeout)
        while Date() < until {
            try Task.checkCancellation()
            guard !invalidated, !ended else { throw BridgeFailure.cancelled }
            if FileManager.default.fileExists(atPath: receipt.path),
               (try? EngineSpool.read(receipt))?["revision"]?.stringValue == revision { return true }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    private func send(_ pieces: [ClaudePrompt.Piece], responseToken: UUID) async {
        do {
            guard responseID == responseToken, !invalidated else { return }
            var pieces = pieces
            if !ready {
                try await awaitReady(responseToken)
                pieces = firstPieces
            }
            try await type(pieces, busy: false, responseToken: responseToken)
        } catch { inputFailed(error) }
    }

    private func inputFailed(_ error: Error) {
        invalidated = true
        if draft == .submitted { draft = .uncertain }
        observer?.yield(.attention); fail(error is CancellationError ? BridgeFailure.cancelled : error)
    }

    private func failed(_ reason: String) {
        trace.note("failed:" + reason)
        Diagnostics.record("session.failed", ["run": runTag, "reason": reason, "ms": String(Int(Date().timeIntervalSince(launchedAt) * 1000))])
        Diagnostics.dump("session", subject: ("run", runTag), why: reason, trace: trace)
    }

    /// Waits once, at most readyTimeout, for the input box and the helper's tool list, answering
    /// first-run screens on the way (tui.go ready, 438-564): a message sent before the tools are
    /// listed is answered without them.
    private func awaitReady(_ token: UUID) async throws {
        var until = Date().addingTimeInterval(readyTimeout)
        var prompted = false
        while true {
            try Task.checkCancellation()
            guard !invalidated, responseID == token else { throw BridgeFailure.cancelled }
            if exitedBeforeReady {
                try relaunchWhole()
                until = Date().addingTimeInterval(readyTimeout); prompted = false
                continue
            }
            if ended { failed("process_exited"); throw BridgeFailure.transport }
            let text = screen.visibleText
            switch firstRun.respond(to: text, at: Date()) {
            case .send(let key):
                do { try transport?.write(key) } catch { failed("process_exited"); throw BridgeFailure.transport }
            case .signInRequired:
                failed("sign_in_required"); observer?.yield(.accountState(.signedOut))
                throw BridgeFailure.accountUnavailable(.signedOut)
            case .stuck:
                failed("first_run_stuck"); throw BridgeFailure.compatibility
            case .none: break
            }
            // the input box's "❯ " (a drawn row may lose its trailing space), on no first-run screen
            if !FirstRunScreens.isShowing(text), !promptArea().isEmpty {
                if let directory, FileManager.default.fileExists(atPath: directory.appendingPathComponent("tools-listed.json").path) {
                    // drawn: a moment for its input to be listened to and the tools to be taken up
                    try await Task.sleep(nanoseconds: 300_000_000)
                    guard !ended, !exitedBeforeReady else { continue }
                    ready = true; officialIdle = true
                    return
                }
                prompted = true
            }
            if Date() >= until {
                failed(prompted ? "catalog_ack_timeout" : "ready_timeout")
                throw BridgeFailure.compatibility
            }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
    }

    /// Pastes a message's pieces as a person would and sends it (tui.go send, 949-1118): each
    /// image once the input shows the one before, the words in one bracketed paste, Return on its
    /// own once the paste shows (or its wait is over), again while the transcript has not taken
    /// the message, at most four times.
    private func type(_ pieces: [ClaudePrompt.Piece], busy: Bool, responseToken: UUID) async throws {
        var lastText = "", image = 0
        trace.note("input.typing:\(pieces.count)")
        draft = .owned
        for (index, piece) in pieces.enumerated() {
            try checkInput(responseToken)
            switch piece {
            case .image(let block):
                guard let directory else { throw BridgeFailure.transport }
                let payload = try ImagePayload(block: block)
                let file = directory.appendingPathComponent("work/image-\(UUID().uuidString).\(payload.fileExtension)")
                try validatePath(file.path)
                try workspace.write(payload.data, to: file)
                attachmentFiles.append(file)
                drawn = Data()
                try transport?.write(Data(("\u{1B}[200~" + file.path + "\u{1B}[201~").utf8))
                image = try await awaitImage(after: image, responseToken: responseToken)
            case .text(var text):
                text = index == 0 ? Self.pasteable(text, busy: busy) : Self.typeable(text)
                if index == 0 && pieces.count == 1 && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { text = "." }
                drawn = Data()
                try transport?.write(Data(("\u{1B}[200~" + text + "\u{1B}[201~").utf8))
                lastText = text
            }
        }
        await awaitShown(lastText, responseToken: responseToken)
        try await Task.sleep(nanoseconds: 150_000_000)
        try checkInput(responseToken)
        let before = acceptedRows
        awaitingAccept = true; draft = .submitted; submitted = true; officialIdle = false
        for _ in 0..<4 {
            try transport?.write(Data([13]))
            let until = Date().addingTimeInterval(returnReceiptTimeout)
            while acceptedRows <= before, Date() < until {
                try Task.checkCancellation()
                guard !ended, !invalidated, responseID == responseToken else { throw BridgeFailure.cancelled }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            if acceptedRows > before { return }
        }
        failed("submit_not_taken")
        throw BridgeFailure.compatibility
    }

    private func awaitImage(after: Int, responseToken: UUID) async throws -> Int {
        let until = Date().addingTimeInterval(pasteTimeout)
        while Date() < until {
            try checkInput(responseToken)
            if let number = imageNumbers(in: drawnText()).filter({ $0 > after }).min() { return number }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        failed("image_not_shown")
        throw BridgeFailure.compatibility
    }

    /// Waits for the input to show the paste: "Pasted text", or its last line's last 16
    /// characters, in what was drawn since. A long paste takes a second more per 64 KB. The wait
    /// ending is not a failure: Return is pressed anyway (tui.go shown, 1081-1118). Whitespace is
    /// left out of the comparison, since the terminal wraps the input wherever a line is full.
    private func awaitShown(_ text: String, responseToken: UUID) async {
        guard !text.isEmpty else { return }
        var tail = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let newline = tail.lastIndex(of: "\n") { tail = String(tail[tail.index(after: newline)...]).trimmingCharacters(in: .whitespaces) }
        tail = String(String.UnicodeScalarView(tail.unicodeScalars.suffix(16)))
        let wanted = Self.compact(tail)
        let until = Date().addingTimeInterval(pasteTimeout + Double(text.utf8.count / 65_536))
        while Date() < until {
            guard (try? checkInput(responseToken)) != nil else { return }
            let seen = drawnText()
            if seen.contains("Pasted text") || (!wanted.isEmpty && Self.compact(seen).contains(wanted)) { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        Diagnostics.record("session.paste_not_shown", ["run": runTag, "bytes": String(text.utf8.count)])
    }

    private static func compact(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) && $0 != "│" }))
    }

    /// Tool results that come with more words from the client: the words are sent first, as a
    /// message Claude Code queues mid-turn, then the parked calls are released.
    private func deliver(_ results: [(String, JSONValue)], extraText: String, to directory: URL, responseToken: UUID) async {
        do {
            try await type([.text(extraText)], busy: true, responseToken: responseToken)
            try deliver(results, to: directory)
        } catch { inputFailed(error) }
    }
    /// Each result goes to its call as Claude Code makes it: at once for a call it is waiting on,
    /// held for one it has not made yet, since it makes a message's calls one at a time.
    private func deliver(_ results: [(String, JSONValue)], to directory: URL) throws {
        let parked = results.filter { waiting.contains($0.0) }.count
        trace.note("results.delivered:\(parked)/held:\(results.count - parked)")
        for (callID, value) in results {
            outstanding.remove(callID)
            if waiting.remove(callID) != nil {
                try EngineSpool.write(value, to: directory.appendingPathComponent("results/\(callID).json"))
            } else {
                heldResults[callID] = value
            }
        }
    }

    private func checkInput(_ token: UUID) throws {
        try Task.checkCancellation()
        guard !ended, !invalidated, responseID == token, draft == .owned else { throw BridgeFailure.cancelled }
    }

    private func promptArea() -> String {
        let lines = screen.visibleText.components(separatedBy: "\n")
        guard let index = lines.lastIndex(where: {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return line.hasPrefix("❯") || line == ">" || line.hasPrefix("> ")
        }) else { return "" }
        var input: [String] = []
        for line in lines[index...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !input.isEmpty && trimmed.count >= 3 && trimmed.allSatisfy({ $0 == "─" || $0 == "━" || $0 == "-" }) { break }
            input.append(line)
        }
        return input.joined(separator: "\n")
    }

    private static let ansi = try! NSRegularExpression(pattern:
        #"\x1b\[[0-9;?<>=]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[P^_][^\x1b]*\x1b\\|\x1b."#)
    /// An image's mark with the spaces taken out: a long input wraps wherever its row is full, so
    /// "[Image #10]" can be drawn as "[Image" and "#10]" on two rows.
    private static let imageMark = try! NSRegularExpression(pattern: "\\[Image#([0-9]+)\\]")

    /// What the client drew since the last paste, its escapes taken out (tui.go plain).
    private func drawnText() -> String {
        let text = String(decoding: drawn, as: UTF8.self)
        return Self.ansi.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
    }

    private func imageNumbers(in text: String) -> Set<Int> {
        let text = Self.compact(text), string = text as NSString
        return Set(Self.imageMark.matches(in: text, range: NSRange(location: 0, length: string.length)).compactMap {
            Int(string.substring(with: $0.range(at: 1)))
        })
    }

    /// Client text as it can be typed: line endings become new lines and other terminal controls
    /// are removed, which also keeps the text from ending the paste early (tui.go pasteClean).
    static func typeable(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return String(String.UnicodeScalarView(lines.unicodeScalars.filter {
            !(($0.value < 32 && $0 != "\n" && $0 != "\t") || (127...159).contains($0.value))
        }))
    }

    /// Typeable text that does not open as what the input takes for a command (/), a shell line
    /// (!), a memory (#) or a background task (&): a new line before it, or, while a turn is going
    /// (the client queues it and trims it), the person's mark (tui.go pasteable, 949-964).
    static func pasteable(_ text: String, busy: Bool) -> String {
        let text = typeable(text)
        let trimmed = text.drop { $0 == " " || $0 == "\t" || $0 == "\n" }
        guard let first = trimmed.first, "/!#&".contains(first) else { return text }
        return busy ? ClaudePrompt.userMark + trimmed : "\n" + trimmed
    }

    private func validatePath(_ text: String) throws {
        guard !text.unicodeScalars.contains(where: { ($0.value < 32 && $0 != "\n" && $0 != "\t") || (127...159).contains($0.value) }) else {
            throw BridgeFailure.invalidRequest("A message contains unsupported terminal control characters.")
        }
    }

    public func sendInput(_ data: Data) throws {
        guard let transport, !ended, data.count <= 64 * 1024 else { throw BridgeFailure.transport }
        manualInputRevision += 1
        if draft == .owned { inputTask?.cancel(); invalidated = true; fail(BridgeFailure.permissionRequired) }
        draft = .uncertain
        officialIdle = false
        try transport.write(data)
    }

    private func process(_ event: PTYEvent) {
        switch event {
        case .output(let data):
            if let reply = TerminalScreen.replies(to: data) { try? transport?.write(reply) }
            screen.feed(data); outputRevision += 1
            drawn.append(data)
            if drawn.count > 256 * 1024 { drawn = drawn.suffix(128 * 1024) }
            // The run's screen is read here only: no sheet shows a pool run, so its bytes are not sent on
            // to be parsed again on the main actor at the client's redraw rate.
        case .exited(let status):
            if resumed, !ready, !retriedWhole, response != nil, !invalidated {
                // the client ended before its prompt on a saved session it was to go on from
                exitedBeforeReady = true; transport = nil; processTask = nil
                Diagnostics.record("session.ended", ["run": runTag, "ms": String(Int(Date().timeIntervalSince(launchedAt) * 1000)),
                                                     "status": String(status)])
                return
            }
            Diagnostics.record("session.ended", ["run": runTag, "ms": String(Int(Date().timeIntervalSince(launchedAt) * 1000)),
                                                 "status": String(status)])
            if response != nil { failed("process_exited") }
            _ = confirmExit()
        }
    }

    /// One look at what the run wrote: the helper's calls and hooks' hints, the tap's stream and
    /// the transcript's rows, told in the order they were written;
    /// then what is due. Returns how long until the next look: sooner while a stream
    /// goes on or a row waits for one (tapPoll).
    private func poll() -> UInt64 {
        guard !ended, let directory else { return 40_000_000 }
        let events = ((try? FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("events"), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for path in events.prefix(2048) {
            if let event = try? EngineSpool.read(path) { handleSpool(event) }
            try? FileManager.default.removeItem(at: path)
            if nativeSessionEnded || ended { return 40_000_000 }
        }
        if var tap {
            streamQueue += tap.read()
            self.tap = tap
            if let state = tap.state, state != tapReported {
                tapReported = state; trace.note("tap." + state)
                Diagnostics.record("session.tap", ["run": runTag, "state": state])
            }
        }
        if var transcript {
            rows += transcript.read()
            self.transcript = transcript
        }
        drain()
        if ended { return 40_000_000 }
        reply.listening = canTell
        apply(reply.tick(now: Date()))
        watchForStall()
        if let deadline, deadline < Date(), response != nil {
            failed("reply_timeout")
            observer?.yield(.attention)
            invalidated = true
            fail(BridgeFailure.transport)
            try? transport?.interrupt()
        }
        if tap?.going(bare: false) == true || holdUntil != nil { return 10_000_000 }
        return response != nil || awaitingAccept ? 40_000_000 : Self.restingLook
    }
    /// A reply that has heard nothing from its client for `stallAfter` is logged once, with what
    /// it waits on and its steps; when the client is heard again, how long it was quiet.
    private func watchForStall() {
        let now = Date(), quiet = now.timeIntervalSince(trace.lastActivity)
        if let since = stalledSince {
            guard trace.lastActivity > since else { return }
            Diagnostics.record("session.resumed", ["run": runTag, "quiet_s": String(Int(trace.lastActivity.timeIntervalSince(since)))])
            stalledSince = nil
            return
        }
        guard response != nil, quiet >= Self.stallAfter else { return }
        stalledSince = trace.lastActivity
        let on = awaitingAccept ? "accept" : !waiting.isEmpty ? "results" : !outstanding.isEmpty ? "calls" : "model"
        Diagnostics.record("session.stalled", ["run": runTag, "quiet_s": String(Int(quiet)), "waits_on": on,
            "calls_waiting": String(waiting.count), "outstanding": String(outstanding.count), "held": String(heldResults.count),
            "tap": tapReported ?? "-", "idle": officialIdle ? "yes" : "no"])
        Diagnostics.dump("session", subject: ("run", runTag), why: "stalled", trace: trace, now: now)
    }
    /// How often a run with no reply open looks: a resting run has nothing it waits for, and a reply opening
    /// starts the looks again at once (`startPolling`). This keeps idle runs from waking
    /// the Mac 25 times a second each.
    static let restingLook: UInt64 = 500_000_000

    /// Whether what is read may be told in the open reply: a reply is open, and the message typed
    /// for it was taken.
    private var canTell: Bool { response != nil && !awaitingAccept }

    /// Tells the stream's events and the transcript's rows read so far. A stream's events wait
    /// while a message typed in is not taken yet: they are its reply's. An answer's row waits,
    /// at most tapWait, while a stream with no message yet is open, for its stream to begin, and
    /// is told whole once it does not (tap.go before, 208-229); a turn's end waits for its streams
    /// to end, and ends one still going then (settle, 231-245). The rows after a waiting one wait.
    private func drain() {
        while !ended {
            if !awaitingAccept, !streamQueue.isEmpty {
                let events = streamQueue; streamQueue = []
                for event in events {
                    streamEvent(event)
                    if ended { return }
                }
                continue
            }
            guard let row = rows.first else { return }
            if var tap, tap.on {
                var hold = false, ending = false
                switch row {
                case .assistant(let message, _, _, _) where !message.isEmpty && tap.waits(for: message):
                    if tap.going(bare: true) && holding() { hold = true } else { tap.drop(message) }
                case .turnEnded, .apiError:
                    if tap.going(bare: false) {
                        if holding() { hold = true } else { streamQueue += tap.endAll(); ending = true }
                    }
                default: break
                }
                self.tap = tap
                if hold { return }
                if ending && !awaitingAccept { continue }
            }
            holdUntil = nil
            rows.removeFirst()
            handle(row)
        }
    }

    private func holding() -> Bool {
        let now = Date()
        if holdUntil == nil { holdUntil = now.addingTimeInterval(tapWait) }
        return now < holdUntil!
    }

    private func streamEvent(_ event: JSONValue) {
        observedInference = true
        switch event["type"]?.stringValue {
        case "message_start", "message_stop", "error": trace.note("stream." + (event["type"]?.stringValue ?? "-"))
        case "content_block_start": trace.note("stream.block:" + (event["content_block"]?["type"]?.stringValue ?? "-"))
        case "message_delta": trace.note("stream.stop:" + (event["delta"]?["stop_reason"]?.stringValue ?? "-"))
        default: trace.touch()
        }
        if canTell {
            refreshProgressDeadline()
            if event["type"]?.stringValue == "message_start" { observer?.yield(.working) }
        }
        reply.listening = canTell
        apply(reply.stream(event))
    }

    /// What the reply says, told to the client.
    private func apply(_ outputs: [ClaudeReply.Output]) {
        for output in outputs {
            switch output {
            case .text(let text):
                // a structured answer is its answer tool's call alone; the turn's words wait
                if answerSchema != nil { heldWords += text } else { response?.yield(.text(text)) }
            case .call(let call):
                guard response != nil else { continue }
                outstanding.insert(call.id); replyCalls += 1
                response?.yield(.toolUse(call))
            case .finish(let reason): finish(reason)
            case .fail(let failure):
                guard response != nil else { continue }
                invalidated = true; failed("stream_cut"); observer?.yield(.attention)
                fail(failure)
            }
        }
    }

    // MARK: The transcript

    private func handle(_ row: ClaudeTranscript.Row) {
        switch row {
        case .accepted: trace.note("row.accepted")
        case .assistant(_, let blocks, _, let stop): trace.note("row.assistant:\(blocks.count):" + (stop ?? "-"))
        case .apiError(let status, _, _): trace.note("row.api_error:" + (status.map(String.init) ?? "-"))
        case .turnEnded: trace.note("row.turn_ended")
        }
        switch row {
        case .accepted:
            acceptedRows += 1
            turnFailed = false
            guard awaitingAccept else { return }
            awaitingAccept = false; officialIdle = false; draft = .none
            // the client has the images it was pasted
            removeAttachmentFiles()
            // entering the message has its own limits; the reply deadline starts once it is taken
            if response != nil { deadline = Date().addingTimeInterval(timeout) }
            observer?.yield(.working)
        case .assistant(let message, let blocks, let usage, let stop):
            observedInference = true
            if canTell { refreshProgressDeadline(); observer?.yield(.working) }
            // read even with no reply open: a message left out, or calls in it, shape the next
            reply.listening = canTell
            apply(reply.message(message, blocks: blocks, usage: usage, stop: stop, now: Date()))
        case .apiError(let status, let text, let rateLimits):
            officialIdle = true; turnFailed = true; invalidated = true
            removeAttachmentFiles()
            endTurn()
            if let rateLimits { forwardQuota(ClientErrorWords.windows(rateLimits, at: Date())) }
            guard response != nil else { return }
            failed("api_error:\(status ?? 0)")
            observer?.yield(.attention)
            fail(classify(status: status ?? 0, text: text))
        case .turnEnded:
            officialIdle = true
            removeAttachmentFiles()
            reply.listening = canTell
            apply(reply.settle())
            let cut = reply.cut, stop = reply.lastStop
            endTurn()
            if tap != nil, tap?.state == nil, tapReported == nil {
                tapReported = "silent"
                Diagnostics.record("session.tap", ["run": runTag, "state": "silent"])
            }
            guard response != nil, !awaitingAccept, !turnFailed, outstanding.isEmpty else {
                if !turnFailed { observer?.yield(.idle) }
                return
            }
            if cut {
                // an attempt cut short that Claude Code did not ask again (claude_subscription.go:3682)
                invalidated = true; failed("stream_cut"); observer?.yield(.attention)
                fail(BridgeFailure.clientReported(status: 502, message: "Claude Code's stream from Anthropic was cut short, and Claude Code ended the turn without asking again."))
                return
            }
            if answerSchema != nil {
                if let answer, let words = try? String(decoding: ClaudePrompt.canonical(answer), as: UTF8.self) {
                    response?.yield(.text(words))
                } else if !answerAsked, let token = responseID, let answerName {
                    // a turn that ended without the answer tool is asked for its call once (answerAsk)
                    answerAsked = true
                    let ask = ClaudePrompt.pieces([.object(["type": .string("text"), "text": .string(TurnChoice.answerAsk(callableName(answerName)))])])
                    inputTask = Task { [weak self] in await self?.send(ask, responseToken: token) }
                    return
                } else if !heldWords.isEmpty { response?.yield(.text(heldWords)) }
                heldWords = ""
            }
            finish(stop == "max_tokens" ? .maxTokens : stop == "refusal" ? .refusal : .endTurn)
            observer?.yield(.idle)
        }
    }

    /// The turn is over: Claude Code waits on none of its calls, and the tap's copy of it is let go.
    private func endTurn() {
        reply.turnOver()
        waiting.removeAll(); heldResults.removeAll()
        if tap?.going(bare: false) == false { tap?.compact() }
    }

    /// The client's error for a turn, as Pool tells it on: an account's limit or sign-in is account evidence;
    /// anything else is the client's own words and status, 0 when it never asked Anthropic.
    private func classify(status: Int, text: String) -> BridgeFailure {
        if status == 429 || (status < 400 && ClientErrorWords.quotaSaid(text)) {
            let limits = knownQuota.values.filter { $0.applies(to: model.cliAlias) && $0.isExhausted(at: Date()) }.sorted { $0.id < $1.id }
            return limits.isEmpty ? .rateLimited(nil) : .quotaLimited(limits)
        }
        if status == 401 || (status < 400 && text.lowercased().contains("authentication")) {
            return .accountUnavailable(.signedOut)
        }
        return .clientReported(status: status, message: text)
    }

    // MARK: Hints

    private func handleSpool(_ event: JSONValue) {
        let name = event["event"]?.stringValue ?? "-"
        trace.note("hook." + name + (event["notification_type"]?.stringValue.map { ":" + $0 } ?? ""))
        switch event["event"]?.stringValue {
        case "toolCall":
            // under Claude Code's own tool-use id, which the stream and the transcript tell it by;
            // with no input while Claude Code has not written it yet
            guard let callID = event["id"]?.stringValue, EngineSpool.isCallID(callID) else { return }
            let input = event["input"]
            guard let alias = event["name"]?.stringValue, let name = toolNames[alias],
                  input == nil || input?.objectValue != nil, !invalidated else {
                // the call is answered, never left waiting: the session goes on without it
                if let directory {
                    try? EngineSpool.write(.object(["content": .array([.object(["type": .string("text"), "text": .string("This tool is not available.")])]),
                                                    "isError": .bool(true)]), to: directory.appendingPathComponent("results/\(callID).json"))
                }
                Diagnostics.record("session.tool_refused", ["run": runTag])
                return
            }
            observedInference = true
            refreshProgressDeadline()
            observer?.yield(.working)
            if let answerName, name == answerName {
                // A call that fits is the answer
                let why = answerSchema.flatMap { TurnChoice.schemaProblem(input ?? .object([:]), schema: $0) }
                if why == nil { answer = input ?? .object([:]) }
                let said = why.map { "The input doesn't fit the schema: \($0)\nCall the tool again with input that fits." } ?? TurnChoice.answerReceived
                answerResult(callID, said, error: why != nil)
                return
            }
            if !TurnChoice.allows(turnChoice) {
                // the client chose no tool for this reply: answered here, and Claude Code goes on in words
                answerResult(callID, TurnChoice.noToolsAnswer, error: true)
                return
            }
            if let result = heldResults.removeValue(forKey: callID) {
                // the client answered it with the other calls of its message
                guard let directory else { return }
                do { try EngineSpool.write(result, to: directory.appendingPathComponent("results/\(callID).json")) }
                catch { invalidated = true; failed("result_unwritten"); observer?.yield(.attention); fail(BridgeFailure.transport) }
                return
            }
            waiting.insert(callID)
            reply.made(callID, name: name, input: input, now: Date())
        case "PermissionRequest": awaitUser()
        case "Notification":
            if ["permission_prompt", "elicitation_dialog"].contains(event["notification_type"]?.stringValue ?? "") { awaitUser() }
        case "statusLine": statusLine(event)
        case "SessionEnd":
            nativeSessionEnded = true; invalidated = true; inputTask?.cancel(); pollTask?.cancel()
            if response != nil { failed("session_end") }
            fail(BridgeFailure.transport); observer?.yield(.attention)
        default: return // anything else a hook says changes nothing
        }
    }

    /// A call the bridge answers itself, never the client's.
    private func answerResult(_ callID: String, _ text: String, error: Bool) {
        guard let directory else { return }
        try? EngineSpool.write(.object(["content": .array([.object(["type": .string("text"), "text": .string(text)])]),
                                        "isError": .bool(error)]), to: directory.appendingPathComponent("results/\(callID).json"))
    }

    /// Quota windows and the model the alias runs on: the status line's, for Pool's quota view.
    private func statusLine(_ event: JSONValue) {
        // Which model the alias runs on now names it to clients; a session moved to another
        // model says nothing about this alias.
        if let reported = event["model"], let id = reported["id"]?.stringValue,
           let identity = ModelIdentity(alias: model.cliAlias, id: id, name: reported["display_name"]?.stringValue),
           identity != reportedModel {
            reportedModel = identity; observer?.yield(.model(identity))
        }
        // a startup redraw is not a reading taken after model activity
        guard observedInference else { return }
        let generation = tokenCount(event["prompt_cache"]?["requests"])
        var windows: [QuotaWindow] = []
        for (key, raw) in (event["rate_limits"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard !key.isEmpty, key.utf8.count <= 96,
                  key.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }),
                  raw == .null || raw.objectValue != nil else { continue }
            let reset = raw["resets_at"]?.doubleValue.flatMap { $0.isFinite && $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            let used = raw["used_percentage"]?.doubleValue.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
            let state: QuotaWindowState
            if raw["applicable"]?.boolValue == false || raw["state"]?.stringValue == "not_applicable" { state = .notApplicable }
            else { state = used == nil ? .unknown : .reported }
            let previous = knownQuota[key]
            let newResponse = generation.map { $0 > quotaGenerations[key, default: 0] } ?? false
            let measured = !newResponse && previous?.usedPercent == used && previous?.resetsAt == reset && previous?.state == state ? previous!.observedAt : Date()
            let window = QuotaWindow(id: key, usedPercent: used, observedAt: measured, resetsAt: reset, state: state,
                                     modelFamily: raw["model_family"]?.stringValue)
            knownQuota[key] = window
            if let generation { quotaGenerations[key] = max(generation, quotaGenerations[key, default: 0]) }
            windows.append(window)
        }
        if !windows.isEmpty { observer?.yield(.quota(windows)) }
    }

    /// A refusal's rate-limit info, forwarded to the caller.
    private func forwardQuota(_ windows: [QuotaWindow]) {
        guard !windows.isEmpty else { return }
        for window in windows { knownQuota[window.id] = window }
        observer?.yield(.quota(windows))
    }

    /// The client asks the person at the session window. Pool never answers for them, and the
    /// caller learns at once instead of waiting out the reply deadline.
    private func awaitUser() {
        trace.note("await_user")
        observer?.yield(.attention)
        guard response != nil else { return }
        invalidated = true
        failed("dialog")
        fail(BridgeFailure.permissionRequired)
    }

    /// Ends the reply with the usage its messages told, by their stream or their rows. Usage is
    /// never required: a reply ends with the usage seen, or zero (anthropic.go:1415-1421, 1734-1751).
    private func finish(_ reason: BridgeStopReason) {
        guard response != nil else { return }
        trace.note("finish." + reason.rawValue)
        let usage = reply.complete()
        reply.listening = false
        if reason == .toolUse { Diagnostics.record("session.calls", ["run": runTag, "calls": String(replyCalls)]) }
        response?.yield(.usage(usage)); response?.yield(.finished(reason)); response?.finish()
        response = nil; responseID = nil; deadline = nil
    }
    private func fail(_ error: Error) {
        if response != nil { trace.note("reply.failed") }
        response?.finish(throwing: error)
        response = nil; responseID = nil; deadline = nil
        reply.listening = false
    }
    private func cancelResponse(_ token: UUID) async { if responseID == token { await cancel() } }
    public func cancel() async {
        inputTask?.cancel()
        if let directory { try? workspace.write(Data(), to: directory.appendingPathComponent("cancelled")) }
        if requestingExit { fail(BridgeFailure.cancelled); return }
        let ownedDraft = draft == .owned
        let cleared = ownedDraft ? await clearOwnedDraft() : false
        if !ownedDraft { try? transport?.interrupt() }
        fail(BridgeFailure.cancelled); observer?.yield(.attention)
        invalidated = true; officialIdle = cleared
    }
    /// The idle run ends normally and its session
    /// stays for the conversation's next turn, which a new run resumes.
    public func shelve() async -> ShelvedSession? {
        guard submitted, !ended, !invalidated, response == nil, outstanding.isEmpty, waiting.isEmpty,
              let config = accountDirectory, let work = workDirectory else { return nil }
        keepSession = true
        guard await close() else { keepSession = false; return nil }
        let session = sessionKey
        return ShelvedSession(session: session, accountID: account.id, discard: {
            ClaudeReplay.remove(config: config, work: work, session: session)
        })
    }
    /// Before its first request, the run goes on from a session of its account.
    public func resume(from saved: ShelvedSession) async -> Bool {
        guard transport == nil, !submitted, saved.accountID == account.id, UUID(uuidString: saved.session) != nil else { return false }
        resumeFrom = saved.session; sessionKey = saved.session
        return true
    }

    public func close() async -> Bool {
        if ended { return cleanRun() }
        if nativeSessionEnded, let transport {
            do { _ = try await transport.waitForExit(); return confirmExit() }
            catch { observer?.yield(.attention); return false }
        }
        // Why a close did not go through, by name only: which of the run's own conditions held it.
        func held(_ why: String) -> Bool {
            Diagnostics.record("session.close_held", ["run": runTag, "why": why])
            Diagnostics.dump("session", subject: ("run", runTag), why: "close_held", trace: trace); return false
        }
        if draft == .owned, !(await clearOwnedDraft()) { return held("draft_not_cleared") }
        if ended { return cleanRun() }
        guard draft == .none else { return held(draft == .submitted ? "draft_submitted" : "draft_uncertain") }
        guard let transport else { return cleanRun() }
        if response != nil { return held("reply_open") }
        if !outstanding.isEmpty { return held("calls_outstanding") }
        if !waiting.isEmpty { return held("results_waiting") }
        if !officialIdle { return held("client_not_idle") }
        do {
            try await typeExit(transport)
            _ = try await transport.waitForExit()
            return confirmExit()
        } catch {
            Diagnostics.record("session.close_held", ["run": runTag, "why": "exit_wait:" + String(describing: Swift.type(of: error))])
            observer?.yield(.attention); return false
        }
    }
    /// `/exit` typed as a command: a character every
    /// 20 ms, a settle for the command menu, then Return on its own.
    private func typeExit(_ transport: SessionTransport) async throws {
        for character in "/exit" {
            try transport.write(Data(String(character).utf8))
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await Task.sleep(nanoseconds: UInt64(commandSettle * 1_000_000_000))
        try transport.write(Data([13]))
    }
    /// An explicit user exit may discard terminal input, using only the client's normal keyboard behavior.
    public func requestExit() async -> Bool {
        if ended { return cleanRun() }
        guard !requestingExit, let transport else { return self.transport == nil ? cleanRun() : false }
        requestingExit = true
        defer { requestingExit = false }
        inputTask?.cancel(); invalidated = true; draft = .uncertain; officialIdle = false
        if let directory { try? workspace.write(Data(), to: directory.appendingPathComponent("cancelled")) }
        fail(BridgeFailure.cancelled)
        do {
            for _ in 0..<3 {
                if ended { return cleanRun() }
                // An earlier key may have ended it already, its exit still on the way here.
                do { try transport.interrupt() } catch RuntimeError.processExited { break }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            if !ended { _ = try await transport.waitForExit() }
            return confirmExit()
        } catch { observer?.yield(.attention); return false }
    }
    private func confirmExit() -> Bool {
        ended = true; invalidated = true
        inputTask?.cancel(); pollTask?.cancel(); processTask?.cancel()
        fail(BridgeFailure.transport)
        return cleanRun()
    }
    /// The client has ended, so the run has too, whatever its files do: a folder that cannot be
    /// removed stays behind and is logged, and never keeps the run alive or holds up quitting.
    private func cleanRun() -> Bool {
        if directory != nil {
            // the session's own record goes with its run: Pool never goes on from it later
            if let accountDirectory, let workDirectory, plan != nil, !keepSession {
                ClaudeReplay.remove(config: accountDirectory, work: workDirectory, session: sessionKey)
            }
            tap?.remove(); tap = nil
            do { try workspace.removeRun(id); directory = nil; attachmentFiles = [] }
            catch { Diagnostics.record("session.cleanup_failed", ["run": runTag, "error": (error as? RuntimeError).map { "\($0)" } ?? "error"]) }
        }
        if !endedPublished { endedPublished = true; observer?.yield(.ended); observer?.finish() }
        return true
    }
    private func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    private func clearOwnedDraft() async -> Bool {
        guard draft == .owned, let transport else { return draft == .none }
        inputTask?.cancel()
        let revision = outputRevision
        let manualRevision = manualInputRevision
        draft = .uncertain
        do { try transport.interrupt() } catch { return false }
        let until = Date().addingTimeInterval(pasteTimeout)
        while Date() < until, !ended {
            guard manualInputRevision == manualRevision else { return false }
            let area = promptArea()
            if outputRevision > revision, !area.isEmpty, imageNumbers(in: area).isEmpty,
               !area.contains("[Pasted text"), !area.contains("/") {
                draft = .none; officialIdle = true; removeAttachmentFiles(); return true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return ended
    }
    private func removeAttachmentFiles() {
        attachmentFiles.removeAll { file in
            do { try workspace.remove(file); return true } catch { return false }
        }
    }
    private func refreshProgressDeadline() {
        if response != nil && !invalidated && !awaitingAccept { deadline = Date().addingTimeInterval(timeout) }
    }
    private func tokenCount(_ value: JSONValue?) -> Int? {
        guard let number = value?.doubleValue, number.isFinite, number >= 0, number <= Double(Int32.max), number.rounded() == number else { return nil }
        return Int(number)
    }
}
