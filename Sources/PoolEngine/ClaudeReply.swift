import Foundation
import PoolCore

/// How a turn's reply is told to the client, in Claude Code's
/// interactive mode: from the
/// reply's stream where the tap copies it (ClaudeTap), else from the whole messages of the
/// session's transcript, and from the calls the MCP helper hands over, each under Claude Code's
/// own tool-use id. A message is told once: a streamed one's whole rows say nothing; its words go
/// as they stream and each call once its input is whole, in the message's order, all of one
/// message's calls in one reply.
///
/// Claude Code may write a message calling a client's tool only once the call is answered, which
/// only the client can do (3402-3414). A call the helper hands over that no stream or message
/// told within `callFirst` is then the reply itself, and the message written after it is left out,
/// its usage told with the reply it comes in.
///
/// It owns no I/O: its owner hands it each stream event, transcript message, helper call and
/// tick, says whether a reply is open (`listening`), and tells the client what comes back.
struct ClaudeReply {
    enum Output: Equatable {
        case text(String)
        case call(BridgeToolCall)
        /// The reply ends: its message called the client's tools.
        case finish(BridgeStopReason)
        case fail(BridgeFailure)
        /// What the reply's request read, as its stream began: told before anything of the reply, so
        /// the client's `message_start` says the conversation's size, as Anthropic's does. Not its total.
        case prompt(BridgeUsage)
    }

    /// How long a call the helper hands over waits for its message before it tells the client
    /// itself (callFirst, 3919-3925): a message written before its call was read 118 to 162 ms
    /// after the call came in.
    let callFirst: TimeInterval
    /// How long a message told whole is taken as whole once none of its rows come
    /// (unstreamedQuiet, 3914-3917): Claude Code writes them together.
    let quiet: TimeInterval
    /// The helper's tool names (`mcp__pool__<alias>`'s alias) to the client's.
    var names: [String: String] = [:]
    /// Whether a reply is open to tell things in. Its owner sets it before each step; a step that
    /// ends the reply clears it, so nothing after the end is taken as told.
    var listening = false

    init(callFirst: TimeInterval, quiet: TimeInterval) {
        self.callFirst = callFirst; self.quiet = quiet
    }

    // Calls, across the replies of a turn (3415-3420).
    /// The client's calls it was told.
    private var told = Recent()
    /// Calls told by themselves, their message not written yet.
    private var awaited: Set<String> = []
    /// Calls in a message left out, not made yet, with their input there (`.null` for none):
    /// told when they are made.
    private var written: [String: JSONValue] = [:]
    /// Calls held back: no reply to tell them in, or their input not written yet.
    private var unheard: Set<String> = []
    /// Calls the helper handed over that nothing told yet, with when they came.
    private var made: [String: Made] = [:]
    /// The message left out.
    private var lateID: String?
    private struct Made { var name: String; var input: JSONValue?; var at: Date }

    // Messages, across replies.
    private var streamed = Recent()
    private var answered = Recent()

    // The message being told.
    private var message: String?
    private var theirs = false, shown = false, stopped = false
    private var blocks: [Int: Block] = [:]
    private var unstreamed: String?
    private var quietUntil: Date?
    /// A stream was cut short before it showed anything: Claude Code asks again, and the reply
    /// goes on in the attempt that answers (3259-3269).
    private(set) var cut = false
    private struct Block {
        var id: String; var name: String; var json = ""; var start: JSONValue?
        /// The call's input once its block ends: what streamed, or what it began with.
        var input: JSONValue? {
            if json.isEmpty { return start?.objectValue != nil ? start : .object([:]) }
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)), value.objectValue != nil else { return nil }
            return value
        }
    }

    // The reply.
    private var usage: [String: BridgeUsage] = [:]
    /// A left-out message's usage that came while no reply was open: told with the next one.
    private var carried: [String: BridgeUsage] = [:]
    /// Why the reply's last message stopped, as its stream or its rows said.
    private(set) var lastStop: String?

    // MARK: Replies

    /// A reply opens.
    mutating func newReply() {
        usage = carried; carried = [:]; lastStop = nil
    }

    /// The reply's usage, its messages then answered: what more their rows say is not told.
    mutating func complete() -> BridgeUsage {
        var total = BridgeUsage(inputTokens: 0, outputTokens: 0)
        for value in usage.values {
            total.inputTokens += value.inputTokens; total.outputTokens += value.outputTokens
            if let read = value.cacheReadInputTokens { total.cacheReadInputTokens = (total.cacheReadInputTokens ?? 0) + read }
            if let write = value.cacheCreationInputTokens { total.cacheCreationInputTokens = (total.cacheCreationInputTokens ?? 0) + write }
            if let hour = value.oneHourCacheWrites { total.oneHourCacheWrites = (total.oneHourCacheWrites ?? 0) + hour }
        }
        for id in usage.keys { answered.insert(id) }
        usage = [:]
        return total
    }

    /// The turn ended (its turn_duration or the client's error): nothing of it waits any more.
    mutating func turnOver() {
        quietUntil = nil; unstreamed = nil; cut = false; blocks = [:]; message = nil
        made = [:]; awaited = []; written = [:]; unheard = []; lateID = nil
    }

    // MARK: The helper's calls

    /// Claude Code made a call through the helper. One a stream or message told already is the
    /// client's to answer; another waits `callFirst` for its message (onCall, 3423-3460), and one
    /// whose message was left out is due at once, as nothing more is to come for it.
    mutating func made(_ id: String, name: String, input: JSONValue?, now: Date) {
        guard !told.contains(id) else { return }
        let given = input?.objectValue != nil ? input : nil
        if let late = written[id] {
            made[id] = Made(name: name, input: given ?? (late.objectValue != nil ? late : nil), at: .distantPast)
        } else {
            made[id] = Made(name: name, input: given, at: now)
        }
    }

    /// What is due: a message told whole and quiet since is whole; a call whose message has not
    /// come within `callFirst` is the reply, with the other calls made beside it that have their
    /// input, in the order they were made. A call with no input yet, or with no reply to tell it
    /// in, is held: its message, or the next reply, tells it.
    mutating func tick(now: Date) -> [Output] {
        var out: [Output] = []
        if let quietUntil, now >= quietUntil { out += settle() }
        for id in Array(made.keys) where told.contains(id) { made[id] = nil }
        let due = made.filter { now.timeIntervalSince($0.value.at) >= callFirst }
        for (id, call) in due where call.input == nil || !listening { unheard.insert(id) }
        guard listening, due.values.contains(where: { $0.input != nil }) else { return out }
        out += settle()
        let ready = made.filter { $0.value.input != nil }.sorted { ($0.value.at, $0.key) < ($1.value.at, $1.key) }
        guard listening else { return out }
        for (id, call) in ready {
            // a message calling it that Claude Code has not written yet, unless it was left out
            if written.removeValue(forKey: id) == nil { awaited.insert(id) }
            tell(BridgeToolCall(id: id, name: call.name, input: call.input ?? .object([:])), into: &out)
        }
        out.append(finish(.toolUse))
        return out
    }

    // MARK: The stream

    /// One event of a reply as Anthropic streamed it (3814-3877).
    mutating func stream(_ event: JSONValue) -> [Output] {
        var out = settle()
        switch event["type"]?.stringValue {
        case "message_start":
            let id = event["message"]?["id"]?.stringValue ?? ""
            streamed.insert(id); begin(id)
            let read = ClaudeTranscript.usage(event["message"]?["usage"])
            if !id.isEmpty { note(id, read) }
            if listening, !shown, let read, read.inputTokens + (read.cacheReadInputTokens ?? 0) + (read.cacheCreationInputTokens ?? 0) > 0 {
                out.append(.prompt(read))
            }
        case "content_block_start":
            guard let index = Self.index(event["index"]), let block = event["content_block"] else { break }
            switch block["type"]?.stringValue {
            case "text": say(block["text"]?.stringValue ?? "", into: &out)
            case "tool_use":
                guard let id = block["id"]?.stringValue, !id.isEmpty, let called = block["name"]?.stringValue,
                      let name = clientName(called), !told.contains(id) else { break }
                blocks[index] = Block(id: id, name: name, start: block["input"])
            default: break
            }
        case "content_block_delta":
            let delta = event["delta"]
            switch delta?["type"]?.stringValue {
            case "text_delta": say(delta?["text"]?.stringValue ?? "", into: &out)
            case "input_json_delta":
                if let index = Self.index(event["index"]), blocks[index] != nil {
                    blocks[index]?.json += delta?["partial_json"]?.stringValue ?? ""
                }
            default: break
            }
        case "content_block_stop":
            // a call is told once its input is whole: the client gets each call whole
            guard let index = Self.index(event["index"]), let block = blocks.removeValue(forKey: index), let input = block.input else { break }
            awaited.remove(block.id); unheard.remove(block.id)
            tell(BridgeToolCall(id: block.id, name: block.name, input: input), into: &out)
        case "message_delta":
            if let message, !message.isEmpty { note(message, ClaudeTranscript.usage(event["usage"])) }
            if let reason = event["delta"]?["stop_reason"]?.stringValue, !reason.isEmpty { stopped = true; lastStop = reason }
        case "message_stop":
            if !stopped && shown && listening {
                // what the client was shown can't be taken back, nor the attempt's answer added
                // to it: the reply fails, and Claude Code's own request is the client's to make again
                out.append(failure("after the reply had begun"))
            } else if !stopped {
                cut = true
            } else if theirs && listening {
                out.append(finish(.toolUse))
            }
            message = nil; blocks = [:]
        default: break
        }
        return out
    }

    // MARK: The transcript

    /// A row of a message the transcript has whole (3694-3796). One streamed says nothing but its
    /// usage; the one written after a call that told the client itself is left out; any other is
    /// told block by block, whole once another line or `quiet` passes.
    mutating func message(_ id: String, blocks rows: [ClaudeTranscript.Block], usage value: BridgeUsage?, stop: String?, now: Date) -> [Output] {
        var out: [Output] = []
        if let unstreamed, unstreamed != id { out += settle() }
        guard !id.isEmpty, !answered.contains(id) else { return out }
        if streamed.contains(id) { note(id, value); return out }
        let anyUnheard = rows.contains { if case .toolUse(let call, _, _) = $0 { return unheard.contains(call) }; return false }
        if id != lateID && id != unstreamed {
            // calls told by themselves that the message after them did not have say nothing more
            if lateID != nil && !awaited.isEmpty { awaited.removeAll() }
            lateID = nil
            if !awaited.isEmpty && !anyUnheard { lateID = id }
        }
        if id == lateID && !anyUnheard {
            note(id, value, late: true)
            for case .toolUse(let call, _, let input) in rows {
                if awaited.remove(call) != nil || told.contains(call) { continue }
                written[call] = input ?? .null
                if var waiting = made[call] {
                    waiting.at = .distantPast
                    if waiting.input == nil, input?.objectValue != nil { waiting.input = input }
                    made[call] = waiting
                }
            }
            return out
        }
        if id != unstreamed { begin(id); unstreamed = id }
        if let stop, !stop.isEmpty { lastStop = stop }
        for row in rows {
            switch row {
            case .text(let text): say(text, into: &out)
            case .toolUse(let call, let called, let input):
                awaited.remove(call)
                guard !told.contains(call) else { continue }
                // a call held back is told here, whole (#4611)
                unheard.remove(call)
                guard let name = clientName(called), let whole = input?.objectValue != nil ? input : made[call]?.input else { continue }
                tell(BridgeToolCall(id: call, name: name, input: whole), into: &out)
            }
        }
        note(id, value)
        quietUntil = now.addingTimeInterval(quiet)
        return out
    }

    /// Another line came, or the turn is ending: a message told whole is whole, and the reply
    /// ends if it called the client's tools.
    mutating func settle() -> [Output] {
        quietUntil = nil
        guard unstreamed != nil else { return [] }
        unstreamed = nil
        return theirs && listening ? [finish(.toolUse)] : []
    }

    // MARK: Telling

    private mutating func begin(_ id: String) {
        message = id; theirs = false; shown = false; stopped = false; cut = false; blocks = [:]
    }

    private mutating func say(_ text: String, into out: inout [Output]) {
        guard listening, !text.isEmpty else { return }
        shown = true
        out.append(.text(text))
    }

    private mutating func tell(_ call: BridgeToolCall, into out: inout [Output]) {
        guard listening, !told.contains(call.id) else { return }
        told.insert(call.id); made[call.id] = nil; unheard.remove(call.id)
        theirs = true; shown = true
        out.append(.call(call))
    }

    private mutating func finish(_ reason: BridgeStopReason) -> Output {
        listening = false
        return .finish(reason)
    }

    private mutating func failure(_ why: String) -> Output {
        listening = false
        return .fail(.clientReported(status: 502, message: "Claude Code's stream from Anthropic was cut short " + why + "."))
    }

    /// A message's usage, in the open reply or, for a message left out while none is, the next.
    private mutating func note(_ id: String, _ value: BridgeUsage?, late: Bool = false) {
        if listening { usage[id] = Self.updated(usage[id], with: value) }
        else if late { carried[id] = Self.updated(carried[id], with: value) }
    }

    /// A message's usage as its rows and stream tell it: each count the latest that is more than
    /// zero.
    static func updated(_ old: BridgeUsage?, with new: BridgeUsage?) -> BridgeUsage {
        guard let new else { return old ?? BridgeUsage(inputTokens: 0, outputTokens: 0) }
        guard var usage = old else { return new }
        if new.inputTokens > 0 { usage.inputTokens = new.inputTokens }
        if new.outputTokens > 0 { usage.outputTokens = new.outputTokens }
        if let read = new.cacheReadInputTokens, read > 0 || usage.cacheReadInputTokens == nil { usage.cacheReadInputTokens = read }
        if let write = new.cacheCreationInputTokens, write > 0 || usage.cacheCreationInputTokens == nil { usage.cacheCreationInputTokens = write }
        if let hour = new.oneHourCacheWrites, hour > 0 || usage.oneHourCacheWrites == nil { usage.oneHourCacheWrites = hour }
        return usage
    }

    /// The client's name for a tool the session called: only the helper's own are the client's.
    private func clientName(_ called: String) -> String? {
        guard called.hasPrefix("mcp__pool__") else { return nil }
        return names[String(called.dropFirst("mcp__pool__".count))]
    }

    private static func index(_ value: JSONValue?) -> Int? {
        value?.doubleValue.flatMap { $0.isFinite && $0 >= 0 && $0 < 100_000 ? Int($0) : nil }
    }
}

/// A set of ids that keeps the latest few thousand, so a long session's memory stays bounded.
struct Recent {
    private var members: Set<String> = []
    private var order: [String] = []
    private let limit = 4096
    func contains(_ id: String) -> Bool { members.contains(id) }
    mutating func insert(_ id: String) {
        guard members.insert(id).inserted else { return }
        order.append(id)
        if order.count > limit { members.remove(order.removeFirst()) }
    }
}
