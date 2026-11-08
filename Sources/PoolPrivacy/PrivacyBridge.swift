import Foundation
import CryptoKit
import PoolCore

public actor PrivacyBridge: BridgeBackend {
    private let backend: any BridgeBackend
    private let detector: any PrivacyEntityDetector
    private let onUpdate: @Sendable (PrivacyUpdate) -> Void
    private let fingerprintKey = SymmetricKey(size: .bits256)
    private var contexts: [UUID: PrivacyConversation] = [:]
    private var aliases: [String: UUID] = [:]
    private var toolOwners: [String: UUID] = [:]
    private var totals = PrivacyStatistics()
    private var processing = 0
    private var enabled = true
    private let reader: PrivacyReader
    /// This Mac's account names, masked in every conversation wherever they stand as a word.
    private let machineUsers: [String]
    /// The account name of the person running Pool, when it is one worth masking.
    public static var currentMachineUsers: [String] { [NSUserName()].filter(PrivacyRules.machineUser) }

    public init(backend: any BridgeBackend, detector: any PrivacyEntityDetector,
                onUpdate: @escaping @Sendable (PrivacyUpdate) -> Void = { _ in }) {
        self.init(backend: backend, detector: detector, wait: PrivacyReader.defaultWait, machineUsers: Self.currentMachineUsers, onUpdate: onUpdate)
    }
    /// `wait`: how long a request waits for the local model; `retryAfter`: how
    /// long a failed model rests before it is asked again.
    init(backend: any BridgeBackend, detector: any PrivacyEntityDetector, wait: Duration,
         retryAfter: @escaping @Sendable (Int) -> Duration = { PrivacyReader.retryAfter($0) }, machineUsers: [String] = [],
         onUpdate: @escaping @Sendable (PrivacyUpdate) -> Void = { _ in }) {
        self.backend = backend; self.detector = detector; self.onUpdate = onUpdate; self.machineUsers = machineUsers
        reader = PrivacyReader(detector: detector, wait: wait, retryAfter: retryAfter, onModel: { onUpdate(.model($0)) })
    }
    deinit {
        let reader = self.reader
        Task { await reader.stop() }
    }
    public func statistics() -> PrivacyStatistics { totals }

    /// How long a conversation's redaction is kept across a restart after its last request.
    static let keptFor: TimeInterval = 24 * 3600
    private struct Saved: Codable { var contexts: [PrivacyConversation.Saved] }

    /// The redaction of recent conversations, so after a restart their history is masked as it went
    /// and they go on from their sessions and prompt cache: compressed, `limit` bytes at most, the
    /// conversations used longest ago left out first. It holds no value masked and nothing keyed by one
    /// (`PrivacyConversation.Saved`); it goes only to the app's private folder. Nil with none to keep.
    public func savedContexts(limit: Int = 48 << 20, now: Date = Date()) -> Data? {
        var kept = contexts.values.filter { now.timeIntervalSince($0.lastUsed) < Self.keptFor && !$0.cancelled }
            .sorted { $0.lastUsed > $1.lastUsed }.map(\.saved)
        while !kept.isEmpty {
            if let json = try? JSONEncoder().encode(Saved(contexts: kept)),
               let packed = try? (json as NSData).compressed(using: .lzfse) as Data, packed.count <= limit {
                Diagnostics.record("privacy.saved", ["conversations": String(kept.count), "bytes": String(packed.count)])
                return packed
            }
            kept.removeLast(max(1, kept.count / 4))
        }
        return nil
    }

    /// Takes back what `savedContexts` kept, before the first request: conversations last used within
    /// `keptFor`. Anything that does not read back is left out.
    public func restoreContexts(_ data: Data, now: Date = Date()) {
        guard contexts.isEmpty, let json = try? (data as NSData).decompressed(using: .lzfse) as Data,
              let saved = try? JSONDecoder().decode(Saved.self, from: json) else {
            Diagnostics.record("privacy.restored", ["conversations": "0", "outcome": "unreadable"]); return
        }
        for kept in saved.contexts where now.timeIntervalSince(kept.lastUsed) < Self.keptFor && contexts.count < 32 {
            let context = PrivacyConversation(saved: kept)
            context.machineUsers = machineUsers
            let id = UUID(); contexts[id] = context
            for alias in context.aliases where aliases[alias] == nil { aliases[alias] = id }
            for call in context.pending where toolOwners[call] == nil { toolOwners[call] = id }
        }
        Diagnostics.record("privacy.restored", ["conversations": String(contexts.count), "outcome": "ok"])
    }
    /// Off, requests go to the pool as Desktop sent them. Conversations redacted before keep their own
    /// runs; the first request after a switch, either way, is served in a new run with its whole history.
    public func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value
        Diagnostics.record("privacy.switched", ["on": value ? "1" : "0"])
    }
    public func canAcceptManualInput(conversationID: String) -> Bool {
        contexts.values.contains { $0.backendID == conversationID && $0.busy && $0.backendReady && !$0.cancelled && $0.activeRequest != nil }
    }

    /// Redaction was ready when the pool started; whether a request would be taken is the pool's.
    public func checkAdmission(model: String) async throws {
        try await backend.checkAdmission(model: model)
    }

    public func preview(_ text: String) async throws -> PrivacyPreview {
        try await Self.preview(text, detector: detector)
    }
    public static func preview(_ text: String, detector: any PrivacyEntityDetector) async throws -> PrivacyPreview {
        let context = PrivacyConversation()
        do {
            _ = try await detector.detect(in: "")
            let result = try await context.mask(text, detector: detector)
            return PrivacyPreview(maskedText: result.text, maskedOccurrences: result.count, categories: result.categories)
        } catch { throw error as? PrivacyFailure ?? .modelFailed }
    }

    public func events(for request: BridgeRequest, conversationID: String?) async throws -> AsyncThrowingStream<BridgeEvent, Error> {
        guard enabled else {
            Diagnostics.record("privacy.bypassed", ["messages": String(request.messages.count)])
            return try await backend.events(for: request, conversationID: conversationID)
        }
        let alias = conversationID ?? "request:" + UUID().uuidString
        let ids = try resultIDs(request)
        let id: UUID
        do { id = try await contextID(request, alias: alias, results: ids) }
        catch { throw report(error) }
        let context = contexts[id]!
        guard !context.busy else { throw BridgeFailure.busy }
        context.busy = true; context.cancelled = false; context.backendCancellationRequested = false
        context.backendReady = false
        context.allowed = [:]; context.allowedNumbers = [:]
        let token = UUID(); context.activeRequest = token
        let prepared = PrivacyPreparation()
        aliases[alias] = id; context.aliases.insert(alias)
        processing += 1; onUpdate(.processing(active: processing))
        var preprocessing = true
        do {
            let began = ContinuousClock.now
            // What is new in the request goes to the local model, which has the request's wait to read it.
            var gathered: [PrivacyCategory: Int] = [:]
            prepared.collecting = true
            _ = try maskRequest(request, context: context, preparation: prepared, counts: &gathered)
            prepared.collecting = false
            let read = await readModel(prepared, token: token)
            let readMS = Self.milliseconds(since: began)
            try Task.checkCancellation()
            guard !context.cancelled, context.activeRequest == token else { throw BridgeFailure.cancelled }
            // Learn across every new field before producing the final outbound request.
            var discovered: [PrivacyCategory: Int] = [:]
            _ = try maskRequest(request, context: context, preparation: prepared, counts: &discovered)
            context.allowed = [:]; context.allowedNumbers = [:]
            var counts: [PrivacyCategory: Int] = [:]
            prepared.review = []
            let masked = try maskRequest(request, context: context, preparation: prepared, counts: &counts)
            let reviewed = prepared.review ?? []; prepared.review = nil
            try Task.checkCancellation()
            guard !context.cancelled, context.activeRequest == token else { throw BridgeFailure.cancelled }
            Diagnostics.record("privacy.prepared", ["texts": String(read.texts), "read": String(read.read),
                                                    "late": String(read.late), "read_ms": String(readMS),
                                                    "total_ms": String(Self.milliseconds(since: began))])
            DevRecord.record(.privacy, "privacy.prepared", ["review": token.uuidString.lowercased(), "context": Diagnostics.id(id),
                                                            "conversation": Diagnostics.tag(alias)]) {
                Self.recorded(request: request, alias: alias, backend: context.backendID, prepared: prepared,
                              read: read, readMS: readMS, totalMS: Self.milliseconds(since: began), counts: counts, reviewed: reviewed)
            }
            processing -= 1; preprocessing = false; onUpdate(.processing(active: processing))
            totals.protectedRequests += 1; addCounts(counts); onUpdate(.protected(totals))
            if !reviewed.isEmpty { onUpdate(.reviewed(PrivacyReview(id: token, at: Date(), fields: reviewed, categories: counts))) }
            let source = try await backend.events(for: masked, conversationID: context.backendID)
            try Task.checkCancellation()
            guard !context.cancelled, context.activeRequest == token else {
                await cancelBackend(context); throw BridgeFailure.cancelled
            }
            context.backendReady = true
            onUpdate(.requestState(conversationID: context.backendID, active: true))
            return AsyncThrowingStream { continuation in
                let task = Task { await self.relay(source, request: request, contextID: id, token: token,
                                                   alias: alias, completedResults: ids, prepared: prepared, continuation: continuation) }
                continuation.onTermination = { [weak self] reason in
                    if case .cancelled = reason {
                        task.cancel()
                        Task { await self?.cancelRequest(id, token: token) }
                    }
                }
            }
        } catch {
            if preprocessing { processing -= 1; onUpdate(.processing(active: processing)) }
            if !preprocessing && (Task.isCancelled || context.cancelled) { await cancelBackend(context) }
            if context.activeRequest == token && context.busy {
                finishRequest(context, id: id, alias: alias, token: token)
            }
            throw report(error, modelBoundary: preprocessing)
        }
    }

    public func maskManualInput(_ text: String, conversationID: String) async throws -> String {
        guard let context = contexts.values.first(where: { $0.backendID == conversationID }),
              context.busy, context.backendReady, !context.cancelled, let token = context.activeRequest else {
            throw BridgeFailure.unsupported("Continue this conversation in Claude Desktop. Use the session controls to answer permission prompts.")
        }
        processing += 1; onUpdate(.processing(active: processing))
        defer { processing -= 1; onUpdate(.processing(active: processing)) }
        do {
            let prepared = PrivacyPreparation(), location = "manual/" + UUID().uuidString
            if context.reading(text, field: nil, location: location) == .read { prepared.want(text, key: context.findsKey(text)) }
            _ = await readModel(prepared, token: token)
            guard context.activeRequest == token, !context.cancelled else { throw BridgeFailure.cancelled }
            let result = try context.mask(text, location: location, preparation: prepared)
            context.commitPrepared(prepared)
            enroll(result, context: context); addCounts(result.categories); onUpdate(.protected(totals))
            return result.text
        } catch { throw report(error) }
    }

    public func cancel(conversationID: String) async {
        // A conversation served while redaction was off is the pool's own.
        guard let id = aliases[conversationID] else { return await backend.cancel(conversationID: conversationID) }
        guard let token = contexts[id]?.activeRequest else { return }
        await cancelRequest(id, token: token)
    }
    public func cancelSession(conversationID: String) async -> Bool {
        guard let entry = contexts.first(where: { $0.value.backendID == conversationID }),
              let token = entry.value.activeRequest, !entry.value.cancelled else { return false }
        entry.value.cancelled = true
        onUpdate(.requestState(conversationID: conversationID, active: false))
        await cancelRequest(entry.key, token: token)
        return true
    }
    public func forget(conversationID: String) async {
        guard let id = aliases[conversationID], let context = contexts[id] else { return }
        context.cancelled = true; context.activeRequest = nil; context.busy = false; context.backendReady = false
        context.allowed = [:]; context.allowedNumbers = [:]
        onUpdate(.requestState(conversationID: context.backendID, active: false))
        await cancelBackend(context)
        remove(id)
    }

    /// The protected conversation a request belongs to. Tool results go to the context that restored
    /// their calls while it still has them, and the context served this conversation before: parallel
    /// tasks of one conversation share its alias, each in a context of its own, and each task's results
    /// go back to its own. When the context is gone (evicted, forgotten) or another conversation
    /// holds the alias, the request is matched as any other: by alias, then by its history, else a new
    /// context masks the whole history afresh and the pool replays it in a new run, never a refusal.
    /// A request for a context still answering waits briefly for it, then
    /// gets a context of its own.
    private func contextID(_ request: BridgeRequest, alias: String, results: Set<String>) async throws -> UUID {
        var renewed: String?
        if !results.isEmpty {
            let owners = Set(results.compactMap { toolOwners[$0] })
            if owners.count == 1, results.allSatisfy({ toolOwners[$0] != nil }), let id = owners.first, let owner = contexts[id],
               aliases[alias] == nil || aliases[alias] == id || owner.aliases.contains(alias) {
                if await settled(id) { return id }
                renewed = "answered_elsewhere"
            } else {
                renewed = owners.isEmpty ? "no_owner" : owners.count > 1 ? "ambiguous" : contexts[owners.first!] == nil ? "no_owner" : "alias_changed"
            }
        }
        if !alias.hasPrefix("request:"), let id = aliases[alias], contexts[id] != nil, renewed != "answered_elsewhere" {
            if await settled(id) { return id }
            renewed = "busy"
        }
        if request.messages.count > 1 {
            let fingerprint = try historyFingerprint(Array(request.messages.dropLast()))
            let matching = contexts.filter { !$0.value.busy && $0.value.pending.isEmpty && $0.value.historyFingerprint == fingerprint }
            if matching.count == 1, let id = matching.keys.first { return id }
        }
        if contexts.count >= 32 {
            // A context whose calls nobody answered for parkLongest no longer holds its place.
            let idle = contexts.filter { !$0.value.busy && ($0.value.pending.isEmpty || Date().timeIntervalSince($0.value.lastUsed) >= 300) }
            guard let oldest = idle.min(by: { $0.value.lastUsed < $1.value.lastUsed }) else { throw PrivacyFailure.capacityReached }
            remove(oldest.key)
        }
        if let renewed {
            Diagnostics.record("privacy.route", ["decision": "privacy_context_renewed", "why": renewed,
                                                 "conversation": Diagnostics.tag(alias), "results": String(results.count)])
        }
        // The client session is the part of the conversation key before its shape.
        let session = alias.hasPrefix("request:") ? nil : alias.split(separator: "#", maxSplits: 1).first.map(String.init)
        // A fork, or a new client session of a conversation, opens with that conversation's first exchange.
        // Masked afresh, its text need not read as the conversation's did, so it is matched here by what the
        // client wrote, and stays in that conversation for the pool: on its account and prompt cache.
        var forkedFrom: String?
        if session != nil, request.messages.count >= 3, let opening = Self.openingKey(request.messages, fingerprint: historyFingerprint),
           let parent = contexts.values.filter({ $0.opening == opening && $0.conversationTag != nil }).max(by: { $0.lastUsed < $1.lastUsed }) {
            forkedFrom = parent.conversationTag
            Diagnostics.record("privacy.route", ["decision": "opening_matched", "conversation": Diagnostics.tag(alias),
                                                 "joins": forkedFrom ?? "-"])
        }
        let context = PrivacyConversation(session: session, conversationTag: forkedFrom)
        context.machineUsers = machineUsers
        let id = UUID(); contexts[id] = context; return id
    }
    /// A key of a conversation's first exchange as its client wrote it, cache marks left out, as they
    /// move from turn to turn. Nil before a reply, so two conversations that open alike stay apart.
    static func openingKey(_ messages: [BridgeMessage], fingerprint: ([BridgeMessage]) throws -> String) -> String? {
        guard messages.count >= 2, messages[0].role == "user", messages[1].role == "assistant" else { return nil }
        func uncached(_ value: JSONValue) -> JSONValue {
            switch value {
            case .object(let fields): return .object(fields.filter { $0.key != "cache_control" }.mapValues(uncached))
            case .array(let items): return .array(items.map(uncached))
            default: return value
            }
        }
        return try? fingerprint(messages.prefix(2).map { BridgeMessage(role: $0.role, content: uncached($0.content)) })
    }
    /// Waits up to 1.5 s for a context's request to end; whether the context is free now.
    private func settled(_ id: UUID) async -> Bool {
        let deadline = Date().addingTimeInterval(1.5)
        while let context = contexts[id], context.busy {
            if Date() >= deadline || Task.isCancelled { return false }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return contexts[id] != nil
    }

    private func resultIDs(_ request: BridgeRequest) throws -> Set<String> {
        let calls = request.messages.last?.content.arrayValue?.filter { $0["type"] == .string("tool_result") } ?? []
        let ids = calls.compactMap { $0["tool_use_id"]?.stringValue }
        guard ids.count == calls.count, Set(ids).count == ids.count else { throw BridgeFailure.invalidRequest("A tool result must identify one original call.") }
        return Set(ids)
    }

    /// The local model's reading of what `preparation` gathered: the request
    /// waits at most the reader's wait, then goes with what the model found by then and the rules for the rest. A model that fails leaves the
    /// rules alone. What it had not read is read on, and kept for the requests after this one. The rules
    /// read the new texts meanwhile, so a long first turn costs the longer of the two, not both.
    private func readModel(_ preparation: PrivacyPreparation, token: UUID) async -> (texts: Int, read: Int, late: Int) {
        let wanted = preparation.newestFirst, late = preparation.lookUps
        guard !wanted.isEmpty || !late.isEmpty else { return (0, 0, 0) }
        let texts = wanted.map(\.text)
        let rules = Task.detached(priority: .userInitiated) { texts.map { PrivacyRules.spans(in: $0) } }
        let reading = await reader.read(texts, lookUp: late.map(\.text),
                                        until: ContinuousClock.now.advanced(by: reader.wait), token: token)
        for (entry, spans) in zip(wanted, await rules.value) { preparation.rules[entry.key] = spans }
        var read = 0
        for (entry, spans) in zip(wanted, reading.read) {
            guard let spans else { continue }
            preparation.finds[entry.key] = spans; read += 1
        }
        for (entry, spans) in zip(late, reading.lookedUp) {
            if let spans { preparation.finds[entry.key] = spans }
        }
        return (wanted.count, read, late.count)
    }
    /// The full log of one prepared request, as the app's review shows it: each replacement with the
    /// words around it, and for every text the model was given, what it and the rules found (the found
    /// words only). The request itself is the gateway's record; what was sent is it with these replacements.
    private static func recorded(request: BridgeRequest, alias: String, backend: String,
                                 prepared: PrivacyPreparation, read: (texts: Int, read: Int, late: Int), readMS: Int, totalMS: Int,
                                 counts: [PrivacyCategory: Int], reviewed: [PrivacyReviewField]) -> [String: JSONValue] {
        func spans(_ list: [PrivacySpan]?, in text: String) -> JSONValue {
            guard let list else { return .null }
            let ns = text as NSString
            return .array(list.map { span in
                let found = PrivacyConversation.valid(span, in: ns) ? ns.substring(with: NSRange(location: span.start, length: span.end - span.start)) : ""
                return .object(["start": .number(Double(span.start)), "end": .number(Double(span.end)), "text": .string(found),
                                "category": .string(span.category.rawValue), "score": .number(span.score)])
            })
        }
        let texts: [JSONValue] = prepared.newestFirst.map { entry in
            .object(["key": .string(String(entry.key.prefix(16))), "chars": .number(Double(entry.text.utf16.count)),
                     "model": spans(prepared.finds[entry.key], in: entry.text), "rules": spans(prepared.rules[entry.key], in: entry.text)])
        }
        let lookedUp: [JSONValue] = prepared.lookUps.map { entry in
            .object(["key": .string(String(entry.key.prefix(16))), "chars": .number(Double(entry.text.utf16.count)),
                     "model": spans(prepared.finds[entry.key], in: entry.text)])
        }
        let review: [JSONValue] = reviewed.map { field in
            .object(["location": .string(field.location), "segments": .array(field.segments.map { segment in
                switch segment {
                case .text(let text): return .object(["text": .string(text)])
                case .replaced(let original, let placeholder, let category):
                    return .object(["original": .string(original), "placeholder": .string(placeholder), "category": .string(category.rawValue)])
                }
            })])
        }
        return ["alias": .string(alias), "backend_conversation": .string(backend),
                "messages": .number(Double(request.messages.count)),
                "model_texts": .array(texts), "looked_up": .array(lookedUp),
                "read": .object(["texts": .number(Double(read.texts)), "read": .number(Double(read.read)), "late": .number(Double(read.late)),
                                 "partial": .bool(read.read < read.texts), "read_ms": .number(Double(readMS)), "total_ms": .number(Double(totalMS))]),
                "categories": .object(Dictionary(uniqueKeysWithValues: counts.map { ($0.key.rawValue, JSONValue.number(Double($0.value))) })),
                "review": .array(review)]
    }
    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        Int((ContinuousClock.now - start) / .milliseconds(1))
    }

    private func maskRequest(_ request: BridgeRequest, context: PrivacyConversation, preparation: PrivacyPreparation,
                             counts: inout [PrivacyCategory: Int]) throws -> BridgeRequest {
        var masked = request
        preparation.section = 1
        if let system = request.system { masked.system = try maskContent(system, location: "system", context: context, preparation: preparation, counts: &counts) }
        masked.messages = []
        for (index, message) in request.messages.enumerated() {
            preparation.section = index + 2
            masked.messages.append(.init(role: message.role, content: try maskContent(message.content, location: "messages/\(index)/content", context: context, preparation: preparation, counts: &counts)))
        }
        if let tools = request.tools {
            preparation.section = 0
            masked.tools = []
            for tool in tools {
                var description: String?
                let location = "tools/" + component(tool.name)
                if let text = tool.description { description = try maskText(text, location: location + "/description", context: context, preparation: preparation, counts: &counts) }
                masked.tools?.append(.init(name: tool.name, description: description,
                    inputSchema: try maskSchema(tool.inputSchema, location: location + "/schema", context: context, preparation: preparation, counts: &counts)))
            }
        }
        return masked
    }

    private func maskContent(_ content: JSONValue, location: String, context: PrivacyConversation, preparation: PrivacyPreparation,
                             counts: inout [PrivacyCategory: Int]) throws -> JSONValue {
        if let text = content.stringValue { return .string(try maskText(text, location: location + "/text", context: context, preparation: preparation, counts: &counts)) }
        guard let blocks = content.arrayValue else { throw BridgeFailure.invalidRequest("Unsupported protected message content.") }
        var result: [JSONValue] = []
        for (index, block) in blocks.enumerated() {
            let path = location + "/\(index)"
            guard var fields = block.objectValue else { throw BridgeFailure.invalidRequest("Unsupported protected message block.") }
            switch fields["type"]?.stringValue {
            case "text":
                guard let text = fields["text"]?.stringValue else { throw BridgeFailure.invalidRequest("Missing text content.") }
                fields["text"] = .string(try maskText(text, location: path + "/text", context: context, preparation: preparation, counts: &counts))
            case "tool_use":
                fields["input"] = try maskData(fields["input"] ?? .object([:]), location: path + "/input", context: context, preparation: preparation, counts: &counts)
            case "tool_result":
                fields["content"] = try maskContent(fields["content"] ?? .string(""), location: path + "/content", context: context, preparation: preparation, counts: &counts)
            case "image": break // Image pixels and their encoded bytes are outside text detection.
            default:
                // A block of another kind (ToolSearch's `tool_reference`) is walked like
                // every block: its protocol fields
                // stay as they are, its other values are masked; never refused.
                for key in fields.keys.sorted() where !Self.keptKey(key) {
                    fields[key] = try maskData(fields[key]!, field: key, location: path + "/" + component(key), context: context,
                                               preparation: preparation, counts: &counts)
                }
            }
            result.append(.object(fields))
        }
        return .array(result)
    }

    private func maskData(_ value: JSONValue, field: String? = nil, location: String, context: PrivacyConversation, preparation: PrivacyPreparation,
                          counts: inout [PrivacyCategory: Int]) throws -> JSONValue {
        switch value {
        case .string(let text): return .string(try maskText(text, field: field, location: location, context: context, preparation: preparation, counts: &counts))
        case .number(let number):
            if preparation.collecting {
                if let text = context.readingNumber(number, location: location) { preparation.want(text, key: context.findsKey(text)) }
                return value
            }
            let masked = try context.maskNumber(number, field: field, location: location, preparation: preparation)
            if let category = masked.category {
                counts[category, default: 0] += 1
                enrollNumber(masked.value.bitPattern, context: context)
                if masked.fresh, (preparation.review?.count ?? 100) < PrivacyReview.mostFields {
                    preparation.review?.append(PrivacyReviewField(location: location, segments: [.replaced(
                        original: PrivacyConversation.numberText(number), placeholder: PrivacyConversation.numberText(masked.value), category: category)]))
                }
            }
            return .number(masked.value)
        case .array(let values):
            var result: [JSONValue] = []
            for (index, value) in values.enumerated() { result.append(try maskData(value, field: field, location: location + "/\(index)", context: context, preparation: preparation, counts: &counts)) }
            return .array(result)
        case .object(let fields):
            var result: [String: JSONValue] = [:]
            for key in fields.keys.sorted() { result[key] = try maskData(fields[key]!, field: key, location: location + "/" + component(key), context: context, preparation: preparation, counts: &counts) }
            return .object(result)
        default: return value
        }
    }
    private func maskSchema(_ value: JSONValue, field: String? = nil, location: String, context: PrivacyConversation, preparation: PrivacyPreparation,
                            counts: inout [PrivacyCategory: Int]) throws -> JSONValue {
        switch value {
        case .object(let fields):
            var result = fields
            for key in fields.keys.sorted() {
                let path = location + "/" + component(key)
                if ["description", "title", "$comment"].contains(key), let text = fields[key]?.stringValue {
                    result[key] = .string(try maskText(text, location: path, context: context, preparation: preparation, counts: &counts))
                } else if ["enum", "const", "default", "examples"].contains(key) {
                    result[key] = try maskData(fields[key]!, field: field, location: path, context: context, preparation: preparation, counts: &counts)
                } else if key == "properties", let properties = fields[key]?.objectValue {
                    var masked: [String: JSONValue] = [:]
                    for name in properties.keys.sorted() {
                        masked[name] = try maskSchema(properties[name]!, field: name, location: path + "/" + component(name), context: context, preparation: preparation, counts: &counts)
                    }
                    result[key] = .object(masked)
                } else { result[key] = try maskSchema(fields[key]!, field: field, location: path, context: context, preparation: preparation, counts: &counts) }
            }
            return .object(result)
        case .array(let values):
            var result: [JSONValue] = []
            for (index, value) in values.enumerated() { result.append(try maskSchema(value, field: field, location: location + "/\(index)", context: context, preparation: preparation, counts: &counts)) }
            return .array(result)
        default: return value
        }
    }
    private func maskText(_ text: String, field: String? = nil, location: String, context: PrivacyConversation, preparation: PrivacyPreparation,
                          counts: inout [PrivacyCategory: Int]) throws -> String {
        if preparation.collecting {
            switch context.reading(text, field: field, location: location) {
            case .read: preparation.want(text, key: context.findsKey(text))
            case .lookUp: preparation.lookUp(text, key: context.findsKey(text))
            case .none: break
            }
            return text
        }
        let result = try context.mask(text, field: field, location: location, preparation: preparation)
        if result.fresh, result.text != text, (preparation.review?.count ?? 100) < PrivacyReview.mostFields {
            preparation.review?.append(PrivacyReviewField(location: location, segments: context.reviewSegments(result.text)))
        }
        enroll(result, context: context)
        for (category, count) in result.categories { counts[category, default: 0] += count }
        return result.text
    }
    private func enroll(_ result: MaskedText, context: PrivacyConversation) {
        for token in result.placeholders { context.allowed[token] = context.values[token]?.original }
        for number in result.numbers { enrollNumber(number, context: context) }
    }
    private func enrollNumber(_ number: UInt64, context: PrivacyConversation) {
        guard let value = context.numbers[number] else { return }
        context.allowedNumbers[number] = value.original
        context.allowed[PrivacyConversation.numberText(Double(bitPattern: number))] = PrivacyConversation.numberText(value.original)
    }

    private func relay(_ source: AsyncThrowingStream<BridgeEvent, Error>, request: BridgeRequest, contextID: UUID, token: UUID,
                       alias: String, completedResults: Set<String>, prepared: PrivacyPreparation,
                       continuation: AsyncThrowingStream<BridgeEvent, Error>.Continuation) async {
        guard let context = contexts[contextID] else { continuation.finish(throwing: BridgeFailure.cancelled); return }
        defer { finishRequest(context, id: contextID, alias: alias, token: token) }
        var restorer = PrivacyTextRestorer(values: context.allowed, numericTokens: Set(context.numbers.keys.map { PrivacyConversation.numberText(Double(bitPattern: $0)) }))
        var maskedText = "", restoredText = "", history: [JSONValue] = [], counted = 0, toolRestored = 0, reported = 0
        do {
            var finished = false, committed = false
            for try await event in source {
                try Task.checkCancellation()
                guard !context.cancelled, context.activeRequest == token else { throw BridgeFailure.cancelled }
                if !committed { context.commitPrepared(prepared); committed = true }
                restorer.allow(context.allowed)
                restorer.reserveNumbers(Set(context.numbers.keys.map { PrivacyConversation.numberText(Double(bitPattern: $0)) }))
                switch event {
                case .text(let text):
                    maskedText += text
                    let restored = try restorer.append(text)
                    restoredText += restored
                    DevRecord.record(.privacy, "privacy.reply_text", ["review": token.uuidString.lowercased()]) {
                        ["from_model": .string(text), "to_client": .string(restored), "held": .bool(restored.isEmpty && !text.isEmpty)]
                    }
                    if !restored.isEmpty { continuation.yield(.text(restored)) }
                case .toolUse(var call):
                    let tail = try restorer.append("", final: true)
                    restoredText += tail
                    if !tail.isEmpty { continuation.yield(.text(tail)) }
                    try saveText(context, messageIndex: request.messages.count, masked: &maskedText, restored: &restoredText, history: &history)
                    guard toolOwners[call.id] == nil else { throw BridgeFailure.compatibility }
                    let before = totals.restoredOccurrences, fromModel = call.input
                    call.input = try restoreData(call.input, location: "messages/\(request.messages.count)/content/\(history.count)/input", context: context)
                    toolRestored += totals.restoredOccurrences - before
                    DevRecord.record(.privacy, "privacy.reply_tool", ["review": token.uuidString.lowercased()]) { [call] in
                        ["id": .string(call.id), "name": .string(call.name), "from_model": fromModel, "to_client": call.input,
                         "restored": .number(Double(totals.restoredOccurrences - before))]
                    }
                    toolOwners[call.id] = contextID; context.pending.insert(call.id)
                    history.append(.object(["type": .string("tool_use"), "id": .string(call.id), "name": .string(call.name), "input": call.input]))
                    continuation.yield(.toolUse(call))
                case .usage: continuation.yield(event)
                case .finished:
                    let tail = try restorer.append("", final: true)
                    restoredText += tail
                    if !tail.isEmpty { continuation.yield(.text(tail)) }
                    DevRecord.record(.privacy, "privacy.reply_finished", ["review": token.uuidString.lowercased()]) {
                        ["tail": .string(tail), "restored_text": .number(Double(restorer.count)), "restored_tools": .number(Double(toolRestored)),
                         "unrestored_placeholders": .array(Self.placeholders(in: restoredText).map(JSONValue.string))]
                    }
                    try saveText(context, messageIndex: request.messages.count, masked: &maskedText, restored: &restoredText, history: &history)
                    // Results answered here leave whichever context restored their calls, so calls answered
                    // in a renewed context never keep the old one from being evicted.
                    for id in completedResults {
                        context.pending.remove(id)
                        if let owner = toolOwners.removeValue(forKey: id) { contexts[owner]?.pending.remove(id) }
                    }
                    let told = request.messages + [.init(role: "assistant", content: .array(history))]
                    context.historyFingerprint = try historyFingerprint(told)
                    // Renewed each turn: from the second on, the reply is as the client keeps it.
                    if let opening = Self.openingKey(Array(told.prefix(2)), fingerprint: historyFingerprint) { context.opening = opening }
                    continuation.yield(event); finished = true
                }
                if restorer.count > counted {
                    totals.restoredOccurrences += restorer.count - counted; counted = restorer.count
                    onUpdate(.protected(totals))
                }
                if counted + toolRestored > reported {
                    reported = counted + toolRestored
                    onUpdate(.restored(reviewID: token, count: reported))
                }
                if finished { break }
            }
            guard finished else { throw BridgeFailure.transport }
            continuation.finish()
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError || context.cancelled
            if error is PrivacyFailure || cancelled {
                context.cancelled = true
                await cancelBackend(context)
            }
            continuation.finish(throwing: cancelled ? BridgeFailure.cancelled : report(error, modelBoundary: false))
        }
    }
    /// Tag-shaped stand-ins (`{{EMAIL_3}}`) left in what the client got: one this request did not carry, or one cut.
    static func placeholders(in text: String) -> [String] {
        guard let pattern = try? NSRegularExpression(pattern: #"\{\{[A-Z_]{2,24}_[0-9]{1,9}\}\}"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).prefix(200).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }
    private func saveText(_ context: PrivacyConversation, messageIndex: Int, masked: inout String, restored: inout String, history: inout [JSONValue]) throws {
        if !masked.isEmpty || !restored.isEmpty {
            try context.rememberResponse(masked: masked, restored: restored, location: "messages/\(messageIndex)/content/\(history.count)/text")
            history.append(.object(["type": .string("text"), "text": .string(restored)]))
            masked = ""; restored = ""
        }
    }
    private func restoreData(_ value: JSONValue, field: String? = nil, location: String, context: PrivacyConversation) throws -> JSONValue {
        switch value {
        case .string(let text):
            var restorer = PrivacyTextRestorer(values: context.allowed, numericTokens: Set(context.numbers.keys.map { PrivacyConversation.numberText(Double(bitPattern: $0)) }))
            let restored = try restorer.append(text, final: true)
            try context.rememberResponse(masked: text, restored: restored, field: field, location: location)
            totals.restoredOccurrences += restorer.count
            if restorer.count > 0 { onUpdate(.protected(totals)) }
            return .string(restored)
        case .number(let number):
            if let restored = context.allowedNumbers[number.bitPattern] {
                totals.restoredOccurrences += 1; onUpdate(.protected(totals)); return .number(restored)
            }
            // Only what is known is put back: a stand-in this request did not
            // carry is left as the model wrote it.
            return value
        case .array(let values): return .array(try values.enumerated().map { try restoreData($0.element, field: field, location: location + "/\($0.offset)", context: context) })
        case .object(let fields):
            var restored: [String: JSONValue] = [:]
            for key in fields.keys.sorted() { restored[key] = try restoreData(fields[key]!, field: key, location: location + "/" + component(key), context: context) }
            return .object(restored)
        default: return value
        }
    }
    private func cancelRequest(_ id: UUID, token: UUID) async {
        guard let context = contexts[id], context.activeRequest == token else { return }
        context.cancelled = true
        await reader.stopWaiting(token)
        await cancelBackend(context)
    }
    private func cancelBackend(_ context: PrivacyConversation) async {
        guard !context.backendCancellationRequested else { return }
        context.backendCancellationRequested = true
        await backend.cancel(conversationID: context.backendID)
    }
    private func finishRequest(_ context: PrivacyConversation, id: UUID, alias: String, token: UUID) {
        guard context.activeRequest == token else { return }
        context.busy = false; context.activeRequest = nil; context.backendReady = false
        context.allowed = [:]; context.allowedNumbers = [:]; context.lastUsed = Date()
        onUpdate(.requestState(conversationID: context.backendID, active: false))
        if alias.hasPrefix("request:") { aliases.removeValue(forKey: alias); context.aliases.remove(alias) }
    }
    private func remove(_ id: UUID) {
        guard let context = contexts.removeValue(forKey: id) else { return }
        for alias in context.aliases { aliases.removeValue(forKey: alias) }
        for call in context.pending { toolOwners.removeValue(forKey: call) }
    }
    private func historyFingerprint(_ history: [BridgeMessage]) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(history)
        return HMAC<SHA256>.authenticationCode(for: data, using: fingerprintKey).map { String(format: "%02x", $0) }.joined()
    }
    private func component(_ key: String) -> String { key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1") }
    /// The keys a block's protocol reads.
    private static let kept: Set<String> = ["type", "role", "name", "tool_name", "model", "media_type", "mime_type", "signature",
                                            "data", "url", "status", "object", "event"]
    static func keptKey(_ key: String) -> Bool {
        kept.contains(key) || key == "id" || key == "ids" || key.hasSuffix("_id") || key.hasSuffix("_ids") || key.hasSuffix("Id") || key.hasSuffix("Ids")
    }
    private func addCounts(_ categories: [PrivacyCategory: Int]) {
        for (category, count) in categories { totals.categories[category, default: 0] += count; totals.maskedOccurrences += count }
    }
    private func safeFailure(_ error: Error) -> PrivacyFailure { error as? PrivacyFailure ?? .modelFailed }
    private func report(_ error: Error, modelBoundary: Bool = true) -> Error {
        if error is CancellationError { return BridgeFailure.cancelled }
        if let error = error as? BridgeFailure { return error }
        if !(error is PrivacyFailure) && !modelBoundary { return BridgeFailure.transport }
        let failure = safeFailure(error); onUpdate(.blocked(failure))
        switch failure {
        case .busy: return BridgeFailure.privacyBusy
        case .inputTooLarge, .placeholderConflict, .capacityReached: return BridgeFailure.unsupported(failure.errorDescription!)
        default: return BridgeFailure.privacyUnavailable
        }
    }
}
