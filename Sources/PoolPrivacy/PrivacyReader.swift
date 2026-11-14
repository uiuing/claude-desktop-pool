import CryptoKit
import Foundation
import PoolCore

/// The local model's reading of requests, with AstrLink Guard on by default.
///
/// A request waits `wait` (2 s by default) for the model to read what of it is new; past
/// that it goes with what the model found by then and the rules for the rest. What
/// the model reads is kept by its text's digest, for every conversation, so a later request finds it.
/// Once a request stops waiting, only the chunk being read for it is finished; the rest is left.
/// Of what was sent before without the model's reading, a request leaves `backlogCap` at
/// most to be read once no request waits, one chunk at a time, so a long unread history is read a
/// little a request instead of keeping the CPU busy for as long as requests come, and no request
/// waits for it: it went before, and what is found in it serves later requests. A model
/// that fails is not asked again for a while (`retryAfter`), and the rules mask
/// alone meanwhile: nothing is held back for it. Texts are read newest first, joined into chunks,
/// a long one a piece at a time (`TextPieces`); of the requests waiting, the one
/// with the fewest bytes left is read next.
actor PrivacyReader {
    /// How long a request waits for the model on by default.
    static let defaultWait: Duration = .seconds(2)
    /// How long a chunk of joined texts grows, and a long text's piece is at most.
    static let chunkSize = TextPieces.size
    /// A paragraph's end, so the model reads each joined text as one of its own.
    static let separator = "\n\n"
    /// Chunks read at once: one. The model reads one window at a time however many are asked of it, so a
    /// second chunk only slows the first; the threads it has go to that one.
    static let turns = 1
    /// How much of what was sent unread before a
    /// request leaves to be read in the background: one chunk.
    static let backlogCap = chunkSize

    /// 30 s after a failure, doubled for each in a row, 10 minutes at most.
    static func retryAfter(_ fails: Int) -> Duration {
        var delay: Duration = .seconds(30)
        var count = 1
        while count < fails && delay < .seconds(600) { delay *= 2; count += 1 }
        return min(delay, .seconds(600))
    }

    struct Reading: Sendable {
        /// What the model found in each text asked to be read; nil for one it had not read in time.
        var read: [[PrivacySpan]?]
        /// What it has found in each text only looked up; nil for one it has not read yet.
        var lookedUp: [[PrivacySpan]?]
    }

    nonisolated let wait: Duration
    private let detector: any PrivacyEntityDetector
    private let turns: Int
    private let retryAfter: @Sendable (Int) -> Duration
    private let onModel: @Sendable (PrivacyFailure?) -> Void
    private let key = SymmetricKey(size: .bits256)
    private var cache = SpanCache()
    private var jobs: [Int: Job] = [:]
    private var reading: Set<String> = []
    private var active = 0
    private var sequence = 0
    private var stopped = false
    private var failure: (error: PrivacyFailure, fails: Int, retryAt: ContinuousClock.Instant)?
    /// Counts failures, so only a chunk asked after the last one tells that the model reads again.
    private var epoch = 0
    private var partialNoted: ContinuousClock.Instant?
    /// Requests that went with only part read since the last `privacy.partial` line.
    private var partialsUnnoted = 0
    /// The backlog chunk being read, given up when a request comes: a window is a tenth of a second,
    /// so the request waits that long for it at most, not the whole chunk.
    private var backgroundRead: Task<Void, Never>?

    init(detector: any PrivacyEntityDetector, wait: Duration = PrivacyReader.defaultWait, turns: Int = PrivacyReader.turns,
         retryAfter: @escaping @Sendable (Int) -> Duration = { PrivacyReader.retryAfter($0) },
         onModel: @escaping @Sendable (PrivacyFailure?) -> Void = { _ in }) {
        self.detector = detector; self.wait = wait; self.turns = max(1, turns)
        self.retryAfter = retryAfter; self.onModel = onModel
    }

    /// Reads `texts` (newest first) until `deadline`, and of `late`, texts sent before without the
    /// model's reading, `backlogCap` after them. `token` lets `stopWaiting` end the wait early.
    func read(_ texts: [String], lookUp late: [String] = [], until deadline: ContinuousClock.Instant,
              token: UUID? = nil) async -> Reading {
        let plans = texts.map(plan), latePlans = late.map(plan)
        var result = Reading(read: plans.map(known), lookedUp: latePlans.map(known))
        guard !stopped, !heldBack else { return result }
        let units = missing(plans)
        let taken = Set(units.map(\.digest))
        var backlog: [Unit] = [], backlogBytes = 0
        for unit in missing(latePlans) where !taken.contains(unit.digest) && backlogBytes < Self.backlogCap {
            backlog.append(unit); backlogBytes += unit.bytes
        }
        if !backlog.isEmpty { queueBacklog(backlog) }
        guard !units.isEmpty, let job = enqueue(units, token: token) else { pump(); return result }
        if ContinuousClock.now < deadline, !Task.isCancelled { await wait(for: job, until: deadline) }
        stoppedWaiting(job)
        result.read = plans.map(known)
        result.lookedUp = latePlans.map(known)
        let unread = result.read.filter { $0 == nil }.count
        if unread > 0, failure == nil {
            let bytes = texts.map(\.utf8.count)
            let unreadBytes = zip(result.read, bytes).reduce(0) { $0 + ($1.0 == nil ? $1.1 : 0) }
            notePartial(read: texts.count - unread, of: texts.count, bytes: bytes.reduce(0, +), unreadBytes: unreadBytes)
        }
        return result
    }

    /// Ends the wait of the request `token` now; what it went without is still read.
    func stopWaiting(_ token: UUID) {
        for job in jobs.values where job.token == token { wake(job.id) }
    }

    /// No more reading: the bridge is gone.
    func stop() {
        stopped = true
        backgroundRead?.cancel()
        for job in jobs.values where job.live { wake(job.id) }
        jobs = jobs.filter { $0.value.live }
    }

    /// Jobs kept and chunks being read, for tests.
    var state: (jobs: Int, active: Int) { (jobs.count, active) }

    // MARK: Strict reading, for a preview

    /// What the model finds in the whole of `text`, read a piece at a time
    /// (pieces of `chunkSize`, each after the first reading 1 KB of the one before again, so a
    /// name cut by one piece's end is whole in the next), in the text's UTF-16 offsets. Waits for every
    /// piece, and throws what the detector throws.
    static func readWhole(_ text: String, detector: any PrivacyEntityDetector) async throws -> [PrivacySpan] {
        var spans: [PrivacySpan] = []
        for piece in pieces(of: text) {
            try Task.checkCancellation()
            let found = try await detector.detect(in: piece.text)
            guard valid(found, in: piece.text as NSString) else { throw PrivacyFailure.invalidDetection }
            spans += found.map { .init(start: $0.start + piece.offset, end: $0.end + piece.offset, category: $0.category, score: $0.score) }
        }
        return spans
    }

    /// `text` cut into pieces (`TextPieces.cut`), each with its UTF-16 offset in the text; a text of a
    /// chunk or less is one piece, an empty one none.
    static func pieces(of text: String) -> [(text: String, offset: Int)] {
        guard text.utf8.count > chunkSize else { return text.isEmpty ? [] : [(text, 0)] }
        var out: [(text: String, offset: Int)] = []
        var previous = text.startIndex, previousByte = 0, offset = 0
        for piece in TextPieces.cut(Array(text.utf8), size: chunkSize) {
            // Pieces only move forward: each offset is counted from the piece before, not the text's start.
            let start = text.utf8.index(previous, offsetBy: piece.lowerBound - previousByte)
            let end = text.utf8.index(start, offsetBy: piece.count)
            offset += text.utf16.distance(from: previous, to: start)
            previous = start; previousByte = piece.lowerBound
            out.append((String(text[start..<end]), offset))
        }
        return out
    }

    /// Spans the detector may return for `text`: inside it, not splitting a surrogate pair, scored 0...1.
    static func valid(_ spans: [PrivacySpan], in text: NSString) -> Bool {
        spans.count <= 50_000 && spans.allSatisfy {
            $0.score.isFinite && (0...1).contains($0.score) && PrivacyConversation.valid($0, in: text)
        }
    }

    // MARK: What is known

    private struct Piece { let digest: String; let text: String; let offset: Int }
    private struct Plan { let whole: String; let pieces: [Piece] }
    private struct Unit { let digest: String; let text: String; let bytes: Int }

    private func digest(_ text: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: key).lowercaseHex
    }
    private func plan(_ text: String) -> Plan {
        let whole = digest(text)
        guard text.utf8.count > Self.chunkSize else {
            return Plan(whole: whole, pieces: text.isEmpty ? [] : [Piece(digest: whole, text: text, offset: 0)])
        }
        return Plan(whole: whole, pieces: Self.pieces(of: text).map { Piece(digest: digest($0.text), text: $0.text, offset: $0.offset) })
    }
    /// What is known of a text: kept whole, or put together from its pieces once all are known,
    /// and kept whole then too.
    private func known(_ plan: Plan) -> [PrivacySpan]? {
        if plan.pieces.isEmpty { return [] }
        if let spans = cache.get(plan.whole) { return spans }
        guard plan.pieces.count > 1 else { return nil }
        var all: [PrivacySpan] = []
        for piece in plan.pieces {
            guard let spans = cache.get(piece.digest) else { return nil }
            all += spans.map { .init(start: $0.start + piece.offset, end: $0.end + piece.offset, category: $0.category, score: $0.score) }
        }
        cache.put(plan.whole, all)
        return all
    }
    /// What of `plans` the model has not read, each once: the last text's first, and of a long text
    /// its last piece first (what is new in a request is at its end).
    private func missing(_ plans: [Plan]) -> [Unit] {
        var seen = Set<String>(), units: [Unit] = []
        for plan in plans where known(plan) == nil {
            for piece in plan.pieces.reversed() where seen.insert(piece.digest).inserted && !cache.contains(piece.digest) {
                units.append(Unit(digest: piece.digest, text: piece.text, bytes: piece.text.utf8.count))
            }
        }
        return units
    }

    // MARK: The queue

    private final class Job {
        let id: Int
        let token: UUID?
        /// What is left to read, newest first.
        var units: [Unit]
        /// A request still waits for it.
        var live: Bool
        /// Read only while no request waits: what went before without the model's reading.
        var background = false
        var inFlight = false
        var waiter: CheckedContinuation<Void, Never>?
        var timer: Task<Void, Never>?
        init(id: Int, token: UUID?, units: [Unit], live: Bool) { self.id = id; self.token = token; self.units = units; self.live = live }
        var left: Int { units.reduce(0) { $0 + $1.bytes } }
    }
    private struct Chunk { let job: Int; let epoch: Int; let text: String; let parts: [(digest: String, offset: Int, length: Int)] }

    private var heldBack: Bool { failure.map { ContinuousClock.now < $0.retryAt } ?? false }

    private func enqueue(_ units: [Unit], token: UUID?) -> Job? {
        sequence += 1
        let job = Job(id: sequence, token: token, units: units, live: true)
        jobs[job.id] = job
        backgroundRead?.cancel()
        return job
    }

    /// What went unread before, read once no request waits; it takes the place of the backlog an
    /// earlier request left, since each request names all of it again.
    private func queueBacklog(_ units: [Unit]) {
        for job in jobs.values where job.background && !job.inFlight { jobs[job.id] = nil }
        sequence += 1
        let job = Job(id: sequence, token: nil, units: units, live: false)
        job.background = true
        jobs[job.id] = job
    }

    private func wait(for job: Job, until deadline: ContinuousClock.Instant) async {
        let id = job.id
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                guard jobs[id] != nil, !job.units.isEmpty, !Task.isCancelled else { continuation.resume(); return }
                job.waiter = continuation
                job.timer = Task { [weak self] in
                    do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
                    await self?.wake(id)
                }
                pump()
            }
        } onCancel: {
            Task { await self.wake(id) }
        }
    }

    private func wake(_ id: Int) {
        guard let job = jobs[id], let waiter = job.waiter else { return }
        job.waiter = nil; job.timer?.cancel(); job.timer = nil
        waiter.resume()
    }

    /// The request stopped waiting: the chunk being read for it is finished and kept for the next
    /// request; what it had left is not read.
    private func stoppedWaiting(_ job: Job) {
        job.live = false; job.timer?.cancel(); job.timer = nil
        job.units = []
        if !job.inFlight { jobs[job.id] = nil }
        pump()
    }

    private func prune(_ job: Job) {
        job.units.removeAll { cache.contains($0.digest) }
    }

    /// The job read next: of those a request waits for, the one with the fewest bytes left, the first
    /// to come of those with as few. A job reads one chunk at a time, and leaves
    /// what another reads now to that read.
    private func nextJob() -> Job? {
        var best: (job: Job, left: Int)?
        for job in jobs.values where !job.inFlight && job.live {
            prune(job)
            guard job.units.contains(where: { !reading.contains($0.digest) }) else { continue }
            let left = job.left
            if let current = best, left > current.left || left == current.left && job.id > current.job.id { continue }
            best = (job, left)
        }
        if let best { return best.job }
        // Nothing waits: the backlog, one chunk at a time.
        guard active == 0 else { return nil }
        for job in jobs.values.sorted(by: { $0.id < $1.id }) where job.background && !job.inFlight {
            prune(job)
            if job.units.contains(where: { !reading.contains($0.digest) }) { return job }
        }
        return nil
    }

    private func pump() {
        guard !stopped, !heldBack else { return }
        while active < turns, let job = nextJob() {
            let chunk = take(job)
            active += 1; job.inFlight = true
            let task = Task { await self.run(chunk) }
            if job.background { backgroundRead = task }
        }
    }

    /// The job's next chunk: its first units not read elsewhere now, joined up to `chunkSize`.
    private func take(_ job: Job) -> Chunk {
        var text = "", parts: [(digest: String, offset: Int, length: Int)] = [], bytes = 0, offset = 0
        for unit in job.units where !reading.contains(unit.digest) {
            if !parts.isEmpty {
                if bytes + Self.separator.utf8.count + unit.bytes > Self.chunkSize { break }
                text += Self.separator; bytes += Self.separator.utf8.count; offset += Self.separator.utf16.count
            }
            let length = unit.text.utf16.count
            parts.append((unit.digest, offset, length))
            text += unit.text; bytes += unit.bytes; offset += length
            reading.insert(unit.digest)
        }
        return Chunk(job: job.id, epoch: epoch, text: text, parts: parts)
    }

    private func run(_ chunk: Chunk) async {
        let outcome: Result<[PrivacySpan], Error>
        do { outcome = .success(try await detector.detect(in: chunk.text)) }
        catch { outcome = .failure(error) }
        finish(chunk, outcome)
    }

    private func finish(_ chunk: Chunk, _ outcome: Result<[PrivacySpan], Error>) {
        active -= 1
        for part in chunk.parts { reading.remove(part.digest) }
        let background = jobs[chunk.job]?.background == true
        jobs[chunk.job]?.inFlight = false
        if background { backgroundRead = nil }
        switch outcome {
        case .failure(let error) where background && (error is CancellationError || Task.isCancelled):
            // Given up for a request: the backlog is read again once nothing waits.
            break
        case .success(let spans) where Self.valid(spans, in: chunk.text as NSString):
            for part in chunk.parts {
                // A span over into the text beside it is cut at the end.
                let end = part.offset + part.length
                cache.put(part.digest, spans.compactMap { span in
                    let a = max(span.start, part.offset), b = min(span.end, end)
                    return a < b ? PrivacySpan(start: a - part.offset, end: b - part.offset, category: span.category, score: span.score) : nil
                })
            }
            if failure != nil, chunk.epoch == epoch {
                failure = nil
                Diagnostics.record("privacy.model", ["state": "reading"])
                onModel(nil)
            }
        case .success: fail(.invalidDetection)
        case .failure(let error): fail(error as? PrivacyFailure ?? .modelFailed)
        }
        settle()
        pump()
    }

    /// A model that fails finds nothing, and the rules mask alone. It is not asked
    /// again until `retryAfter`, so those waiting don't each try it again; one not
    /// ready yet (installing, not on disk) or busy is asked again at the next
    /// request. Logged, and told, once a streak.
    private func fail(_ error: PrivacyFailure) {
        epoch += 1
        let fails = (failure?.fails ?? 0) + 1
        let delay: Duration = error == .notReady || error == .busy ? .zero : retryAfter(fails)
        if failure == nil {
            Diagnostics.record("privacy.model", ["state": "failed", "reason": String(describing: error),
                                                 "retry_ms": String(Int(delay / .milliseconds(1)))])
            if error != .busy { onModel(error) }
        }
        failure = (error, fails, ContinuousClock.now.advanced(by: delay))
        // Those waiting go on with what is known, and nothing they had left is read on this failure.
        for job in jobs.values {
            job.units = []
            if job.live { wake(job.id) }
        }
        jobs = jobs.filter { $0.value.live }
    }

    /// Jobs with nothing left: the request waiting for one goes on, one it stopped waiting for is done.
    private func settle() {
        for job in Array(jobs.values) {
            prune(job)
            guard job.units.isEmpty, !job.inFlight else { continue }
            if job.live { wake(job.id) } else { jobs[job.id] = nil }
        }
    }

    /// At most once a minute, that a request went with the model's finds for
    /// only part of it: its texts and their bytes, how many of those the model had not read, and how
    /// many such requests went unlogged since the last line. Counts only.
    private func notePartial(read: Int, of total: Int, bytes: Int, unreadBytes: Int) {
        let now = ContinuousClock.now
        if let last = partialNoted, now - last < .seconds(60) { partialsUnnoted += 1; return }
        partialNoted = now
        Diagnostics.record("privacy.partial", ["read": String(read), "texts": String(total),
                                               "bytes": String(bytes), "unread_bytes": String(unreadBytes),
                                               "since_last": String(partialsUnnoted),
                                               "wait_ms": String(Int(wait / .milliseconds(1)))])
        partialsUnnoted = 0
    }
}

/// What the model found, by text digest, with no text kept: two generations, the newer becoming the
/// older when full, and an entry still in use kept past the turnover.
private struct SpanCache {
    static let generation = 10_000
    static let generationBytes = 4 << 20
    private var current: [String: [PrivacySpan]] = [:], previous: [String: [PrivacySpan]] = [:]
    private var bytes = 0

    func contains(_ key: String) -> Bool { current[key] != nil || previous[key] != nil }
    mutating func get(_ key: String) -> [PrivacySpan]? {
        if let spans = current[key] { return spans }
        guard let spans = previous[key] else { return nil }
        put(key, spans)
        return spans
    }
    mutating func put(_ key: String, _ spans: [PrivacySpan]) {
        let cost = 64 + spans.count * MemoryLayout<PrivacySpan>.stride
        if current[key] == nil, current.count >= Self.generation || bytes + cost > Self.generationBytes {
            previous = current; current = [:]; bytes = 0
        }
        if current[key] == nil { bytes += cost }
        current[key] = spans
    }
}
