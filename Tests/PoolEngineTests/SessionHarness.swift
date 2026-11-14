import Foundation
import ImageIO
import XCTest
import PoolCore
import PoolRuntime
@testable import PoolEngine

/// An owned fake of the official interactive client: it draws an input box, takes bracketed
/// pastes and Return as the terminal would, and writes the session transcript rows Claude Code
/// writes (user, assistant with message id/model/usage,
/// `<synthetic>` API errors, system turn_duration). All text is synthetic.
final class SessionHarness: @unchecked Sendable {
    let workspace: OwnedWorkspace
    let account = PoolAccount(email: "te•••sam@example.com", state: .ready)
    private let root: URL
    private let lock = NSLock()
    private var storedPlans: [SessionLaunch] = []
    private var inputs: [String] = []
    private var submitted = 0
    private var interrupts = 0
    private var processContinuation: AsyncStream<PTYEvent>.Continuation?
    private var didExit = false
    private var attachmentPaths: [String] = []
    private var attachmentBytes: [Data] = []
    private var pasted = ""
    private var draftImages = 0
    private var draftMarks: [String] = []
    private var typedTexts: [String] = []
    private var ignoredEnters = 0
    private var enters = 0
    private var exits = 0
    private var keys = ""
    private var firstRunStage = 0
    private var resumedFile: Data?
    var acknowledgeImages = true
    /// Draws the input as Claude Code does: each paste in its place, a text of many lines as
    /// "[Pasted text #n +k lines]" numbered with the images, a full row going on under a 3-space indent.
    var drawDraftLikeClient = false
    /// With `drawDraftLikeClient`, redraw only the cells that changed since the last frame, moving the
    /// cursor over the rest, as the official client does for a long input: an unchanged letter is never
    /// written again. As in a recorded session, each paste first redraws the conversation over the
    /// input's rows, so a mark can reach the output as "[Imag" and " #27]".
    var drawDraftAsDifferences = false
    private var lastFrame: [String] = []
    var acknowledgeText = true
    var acknowledgeInitialTools = true
    var exitNormally = true
    var exitOnResume = false
    var exitAfterInterrupts: Int?
    /// As a real child: its exit is known to the writer before the event reaches the session, so
    /// a later key fails with `processExited` while the session still thinks it is running.
    var exitEventLags = false
    var firstRun = false
    /// A screen drawn instead of the empty input box when the run starts.
    var startScreen: String?

    /// Where a run's tap goes: the fixture's root has a space in its path, which BUN_OPTIONS
    /// cannot carry, so the tap is made in this folder of the test's, as in the user's temporary
    /// folder in the app.
    let tapRoot: URL

    init() throws {
        root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/engine-fixtures/fixture space \(UUID().uuidString)")
        workspace = OwnedWorkspace(root: root); try workspace.prepare()
        tapRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/engine-taps/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tapRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
    var plan: SessionLaunch? { lock.withLock { storedPlans.last } }
    var plans: [SessionLaunch] { lock.withLock { storedPlans } }
    var sentCount: Int { lock.withLock { submitted } }
    var interruptCount: Int { lock.withLock { interrupts } }
    var allInputs: [String] { lock.withLock { inputs } }
    var imagePaths: [String] { lock.withLock { attachmentPaths } }
    var imageBytes: [Data] { lock.withLock { attachmentBytes } }
    /// The last message the client took, as it was pasted.
    var typed: String { lock.withLock { typedTexts.last ?? "" } }
    var enterCount: Int { lock.withLock { enters } }
    var exitCount: Int { lock.withLock { exits } }
    /// The saved session as the resumed run found it.
    var resumedTranscript: Data? { lock.withLock { resumedFile } }
    func ignoreNextEnters(_ count: Int) { lock.withLock { ignoredEnters = count } }
    func clean() {
        processContinuation?.finish()
        try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: tapRoot)
    }

    var model = PoolModel.defaults[0]
    /// Draws a whole screen as the client does, replacing what was there.
    func draw(_ text: String) {
        processContinuation?.yield(.output(Data(("\u{1b}[2J\u{1b}[H" + text.replacingOccurrences(of: "\n", with: "\r\n")).utf8)))
    }
    func session(timeout: TimeInterval = 10, imageTimeout: TimeInterval = 1, toolTimeout: TimeInterval = 1,
                 returnTimeout: TimeInterval = 3, readyTimeout: TimeInterval = 3,
                 tapWait: TimeInterval = 0.5, callFirst: TimeInterval = 0.3, messageQuiet: TimeInterval = 0.1,
                 limitedQuiet: TimeInterval = 0.2) -> OfficialSession {
        OfficialSession(workspace: workspace, account: account, model: model,
                        executable: URL(fileURLWithPath: "/fixture/claude"), helperExecutable: URL(fileURLWithPath: "/fixture/Claude Pool"),
                        timeout: timeout, imageAcknowledgementTimeout: imageTimeout, toolCatalogTimeout: toolTimeout,
                        returnReceiptTimeout: returnTimeout, readyTimeout: readyTimeout, commandSettle: 0.05,
                        tapWait: tapWait, callFirst: callFirst, messageQuiet: messageQuiet, tapDirectory: tapRoot, limitedQuiet: limitedQuiet,
                        launch: { try self.launch($0) })
    }

    var sessionKey: String { (plan?.sessionID.uuidString ?? "").lowercased() }
    var transcriptURL: URL {
        get throws {
            let plan = try XCTUnwrap(self.plan)
            let config = try workspace.accountDirectory(account.id)
            let folder = try XCTUnwrap(ClaudeReplay.projectDirectories(config: config, work: plan.directory).last)
            return folder.appendingPathComponent(sessionKey + ".jsonl")
        }
    }

    private func launch(_ plan: SessionLaunch) throws -> SessionTransport {
        lock.withLock { storedPlans.append(plan); didExit = false; keys = "" }
        let stream = AsyncStream<PTYEvent> { processContinuation = $0 }
        if plan.arguments.contains("--resume") {
            let saved = try? Data(contentsOf: try transcriptURL)
            lock.withLock { resumedFile = saved }
            if exitOnResume {
                // as the client does with a session it cannot load: it ends before its prompt
                processContinuation?.yield(.output(Data("No conversation found with session ID".utf8)))
                processContinuation?.yield(.exited(1)); processContinuation?.finish()
                return SessionTransport(events: stream, write: { _ in throw BridgeFailure.transport }, interrupt: {}, exit: {},
                                        waitForExit: { 1 })
            }
        }
        if acknowledgeInitialTools { try acknowledgeCatalog() }
        if firstRun {
            processContinuation?.yield(.output(Data("\u{1b}[2J\u{1b}[HChoose the text style that looks best with your terminal\n❯ 1. Dark mode".utf8)))
        } else if let startScreen { draw(startScreen) } else { renderPrompt("") }
        return SessionTransport(events: stream, write: { try self.write($0) }, interrupt: {
            let count = self.lock.withLock { self.interrupts += 1; self.draftImages = 0; self.draftMarks = []; self.pasted = ""; return self.interrupts }
            self.renderPrompt("")
            if let limit = self.exitAfterInterrupts, count >= limit {
                if !self.exitEventLags { self.exited() }
                else if count > limit { throw RuntimeError.processExited }
                else { self.lock.withLock { self.didExit = true } }
            }
        }, exit: {}, waitForExit: {
            guard self.lock.withLock({ self.didExit }) else { throw BridgeFailure.busy }
            return 0
        })
    }

    private func write(_ data: Data) throws {
        let text = String(decoding: data, as: UTF8.self)
        lock.withLock { inputs.append(text) }
        if firstRun, data == Data([13]) {
            let stage = lock.withLock { firstRunStage += 1; return firstRunStage }
            if stage == 1 {
                processContinuation?.yield(.output(Data("\u{1b}[2J\u{1b}[HDo you trust the files in this folder?\n❯ Yes, I trust this folder\n  No, exit".utf8)))
            } else {
                lock.withLock { firstRun = false }
                renderPrompt("")
            }
            return
        }
        if data == Data([13]) {
            let command = lock.withLock { () -> String in let k = keys; keys = ""; return k }
            if command == "/exit" {
                lock.withLock { exits += 1 }
                if exitNormally { exited() }
                return
            }
            // A real client can miss a Return, for example while it is still drawing the paste.
            if lock.withLock({ ignoredEnters > 0 ? { ignoredEnters -= 1; return true }() : false }) { return }
            if lock.withLock({ pasted.isEmpty && draftImages == 0 }) { return }
            try submitDraft(); return
        }
        guard let beginning = text.range(of: "\u{1b}[200~"), let end = text.range(of: "\u{1b}[201~") else {
            if data.count == 1 { lock.withLock { keys += text } }
            return
        }
        let body = String(text[beginning.upperBound..<end.lowerBound])
        if body.contains("/work/image-"), FileManager.default.fileExists(atPath: body) {
            let bytes = try Data(contentsOf: URL(fileURLWithPath: body))
            lock.withLock { attachmentPaths.append(body); attachmentBytes.append(bytes) }
            if acknowledgeImages {
                lock.withLock { draftImages += 1; draftMarks.append("[Image #\(draftMarks.count + 1)]") }
                renderPrompt(lock.withLock { pasted })
            } else { renderPrompt(body) }
        } else {
            lock.withLock {
                pasted += body
                let lines = body.components(separatedBy: "\n").count
                draftMarks.append(lines > 2 ? "[Pasted text #\(draftMarks.count + 1) +\(lines - 1) lines]" : body)
            }
            if acknowledgeText { renderPrompt(lock.withLock { pasted }) }
        }
        // As in the official client, a Return in the same write as a bracketed paste joins the paste.
    }

    /// The user row is written before the message counts as sent, so a test's answer rows follow it.
    private func submitDraft() throws {
        let sent = lock.withLock {
            let sent = pasted
            typedTexts.append(sent); pasted = ""; draftImages = 0; draftMarks = []; lastFrame = []; enters += 1
            return sent
        }
        renderPrompt("")
        try row(["type": .string("user"), "message": .object(["role": .string("user"), "content": .string(sent.isEmpty ? "[Image #1]" : sent)])])
        lock.withLock { submitted += 1 }
    }

    /// The official client's redraw: only the cells that differ from the last frame are written, the
    /// cursor moved over the others, and a row is cleared past its end when it got shorter.
    private static func differences(from old: [String], to new: [String]) -> String {
        var out = ""
        for (index, row) in new.enumerated() {
            let before = index < old.count ? Array(old[index]) : [], after = Array(row)
            var column = 0
            while column < after.count {
                guard column >= before.count || before[column] != after[column] else { column += 1; continue }
                var end = column
                while end < after.count, end >= before.count || before[end] != after[end] { end += 1 }
                out += "\u{1b}[\(index + 1);\(column + 1)H" + String(after[column..<end])
                column = end
            }
            if before.count > after.count { out += "\u{1b}[\(index + 1);\(after.count + 1)H\u{1b}[K" }
        }
        return out
    }

    /// Draws the input the way the terminal does: hard-wrapped at the 180-column width.
    private func renderPrompt(_ text: String) {
        if drawDraftLikeClient, !text.isEmpty || lock.withLock({ !draftMarks.isEmpty }) {
            var rest = Substring("❯ " + lock.withLock { draftMarks.joined() }), rows: [String] = []
            rows.append(String(rest.prefix(180))); rest = rest.dropFirst(180)
            while !rest.isEmpty { rows.append("   " + rest.prefix(177)); rest = rest.dropFirst(177) }
            if drawDraftAsDifferences {
                let frame = rows + ["---"]
                let previous = lock.withLock { lastFrame }
                lock.withLock { lastFrame = frame }
                if !previous.isEmpty {
                    // Each paste redraws the conversation over these rows and then the input again.
                    let filler = String(repeating: "⏺ The merchant pages are back: each one was opened and read, the screenshots are attached. ", count: 2)
                    let conversation = frame.map { _ in filler }
                    let out = Self.differences(from: previous, to: conversation) + Self.differences(from: conversation, to: frame)
                    processContinuation?.yield(.output(Data(out.utf8)))
                    return
                }
            }
            processContinuation?.yield(.output(Data(("\u{1b}[2J\u{1b}[H" + rows.joined(separator: "\r\n") + "\r\n---").utf8)))
            return
        }
        let images = lock.withLock { draftImages }
        let marks = images == 0 ? "" : (1...images).map { "[Image #\($0)]" }.joined(separator: " ") + " "
        let lines = ("❯ " + marks + text).components(separatedBy: "\n").flatMap { line -> [String] in
            var rows: [String] = [], rest = Substring(line)
            repeat { rows.append(String(rest.prefix(180))); rest = rest.dropFirst(180) } while !rest.isEmpty
            return rows
        }
        processContinuation?.yield(.output(Data(("\u{1b}[2J\u{1b}[H" + lines.joined(separator: "\r\n") + "\r\n---").utf8)))
    }

    // MARK: Transcript rows

    func row(_ fields: [String: JSONValue]) throws {
        let url = try transcriptURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        var line = try JSONValue.object(fields).encoded(); line.append(10)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: line)
    }

    /// One assistant content block, as Claude Code writes one row per block under the message id.
    func answer(_ text: String, message: String = "msg_" + UUID().uuidString, usage: [String: Double]? = nil,
                stop: String? = nil) throws {
        var body: [String: JSONValue] = ["id": .string(message), "model": .string("claude-sonnet-5-5"), "role": .string("assistant"),
            "content": .array([.object(["type": .string("text"), "text": .string(text)])])]
        if let usage { body["usage"] = .object(usage.mapValues { .number($0) }) }
        if let stop { body["stop_reason"] = .string(stop) }
        try row(["type": .string("assistant"), "requestId": .string("req_1"), "uuid": .string(UUID().uuidString), "message": .object(body)])
    }
    /// A row of calls, each `(Claude Code's tool-use id, the helper's tool name)`, as Claude Code
    /// writes a message's tool_use blocks under its id.
    func toolUseRow(_ calls: [(String, String)], message: String = "msg_" + UUID().uuidString, input: JSONValue = .object([:]),
                    usage: [String: Double]? = nil) throws {
        var body: [String: JSONValue] = ["id": .string(message), "model": .string("claude-sonnet-5-5"),
            "role": .string("assistant"), "stop_reason": .string("tool_use"),
            "content": .array(calls.map { .object(["type": .string("tool_use"), "id": .string($0.0), "name": .string("mcp__pool__" + $0.1), "input": input]) })]
        if let usage { body["usage"] = .object(usage.mapValues { .number($0) }) }
        try row(["type": .string("assistant"), "message": .object(body)])
    }
    func turnEnded() throws { try row(["type": .string("system"), "subtype": .string("turn_duration"), "durationMs": .number(1200)]) }
    func apiError(status: Int?, text: String, info: JSONValue? = nil, stop: String? = nil, apiError: String? = nil, code: String? = nil) throws {
        var message: [String: JSONValue] = ["id": .string("x"), "model": .string("<synthetic>"),
                                            "content": .array([.object(["type": .string("text"), "text": .string(text)])])]
        if let stop { message["stop_reason"] = .string(stop) }
        var fields: [String: JSONValue] = ["type": .string("assistant"), "isApiErrorMessage": .bool(true), "message": .object(message)]
        if let apiError { fields["apiError"] = .string(apiError) }
        if let code {
            // as Claude Code 2.1.325 writes a 403: the code, its short form and the error's type
            fields["apiErrorCode"] = .string(code); fields["error"] = .string("oauth_org_not_allowed")
            fields["apiErrorType"] = .string("permission_error"); fields["failedResponseHadNoToolCall"] = .bool(true)
        }
        if let status { fields["apiErrorStatus"] = .number(Double(status)) }
        if let info { fields["apiErrorParams"] = .object(["rate_limit_info": info]) }
        try row(fields)
    }

    // MARK: Helper spool

    /// Claude Code's call through the helper, under its tool-use id; `input` nil as when its input
    /// was not written yet.
    func tool(_ id: String, alias: String, input: JSONValue? = .object([:])) throws {
        var fields: [String: JSONValue] = ["event": .string("toolCall"), "id": .string(id), "name": .string(alias)]
        if let input { fields["input"] = input }
        try emit(fields)
    }
    func resultURL(_ id: String) throws -> URL { try XCTUnwrap(plan).runDirectory.appendingPathComponent("results/\(id).json") }

    // MARK: The tap

    /// Lines as the run's tap script writes them.
    func tap(_ lines: String...) throws { try tap(lines) }
    func tap(_ lines: [String]) throws {
        let path = try XCTUnwrap(plan?.environment[OfficialCLI.tapVariable])
        let handle = try XCTUnwrap(FileHandle(forWritingAtPath: path))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(lines.map { $0 + "\n" }.joined().utf8))
    }
    /// Stream `stream`'s events, each an Anthropic stream event.
    func stream(_ stream: Int, _ events: String...) throws { try tap(events.map { #"{"s":\#(stream),"e":\#($0)}"# }) }
    func emit(_ fields: [String: JSONValue]) throws {
        guard let plan else { throw BridgeFailure.transport }
        try EngineSpool.enqueue(.object(fields), directory: plan.runDirectory)
    }
    func catalog() throws -> JSONValue {
        try EngineSpool.read(XCTUnwrap(plan).runDirectory.appendingPathComponent("tools.json"))
    }
    func acknowledgeCatalog(revision: String? = nil) throws {
        let revision = try revision ?? XCTUnwrap(catalog()["revision"]?.stringValue)
        try EngineSpool.write(.object(["revision": .string(revision)]), to: XCTUnwrap(plan).runDirectory.appendingPathComponent("tools-listed.json"))
    }
    func exited() { lock.withLock { didExit = true }; processContinuation?.yield(.exited(0)); processContinuation?.finish() }
}

actor SessionObservations {
    var quotas: [QuotaWindow] = []
    var models: [ModelIdentity] = []
    var endedCount = 0
    var attentionCount = 0
    func add(_ observation: WorkerObservation) {
        switch observation {
        case .quota(let windows): quotas.append(contentsOf: windows)
        case .model(let identity): models.append(identity)
        case .ended: endedCount += 1
        case .attention: attentionCount += 1
        default: break
        }
    }
}

/// A reply's events as they come, for a test to look at before the reply ends.
actor EventLog {
    private(set) var events: [BridgeEvent] = []
    private(set) var failure: Error?
    private(set) var ended = false
    func add(_ event: BridgeEvent) { events.append(event) }
    func end(_ error: Error?) { failure = error; ended = true }
    var calls: [BridgeToolCall] { events.compactMap { if case .toolUse(let call) = $0 { call } else { nil } } }
    var text: String { events.joinedText }
    static func recording(_ stream: AsyncThrowingStream<BridgeEvent, Error>) -> EventLog {
        let log = EventLog()
        Task {
            do { for try await event in stream { await log.add(event) }; await log.end(nil) }
            catch { await log.end(error) }
        }
        return log
    }
}

func collectEvents(_ stream: AsyncThrowingStream<BridgeEvent, Error>) async throws -> [BridgeEvent] {
    var events: [BridgeEvent] = []
    for try await event in stream { events.append(event) }
    return events
}
extension Array where Element == BridgeEvent {
    var joinedText: String { compactMap { if case .text(let text) = $0 { text } else { nil } }.joined() }
}
func waitFor(_ predicate: () async -> Bool) async throws {
    let deadline = Date().addingTimeInterval(30)
    while !(await predicate()) {
        if Date() > deadline { throw BridgeFailure.transport }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}
func sessionFixtureImage(red: UInt8) throws -> JSONValue {
    let pixels = Data([red, 40, 80, 255])
    let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
    let image = try XCTUnwrap(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let data = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return .object(["type": .string("image"), "source": .object(["type": .string("base64"), "media_type": .string("image/png"),
        "data": .string((data as Data).base64EncodedString())])])
}
