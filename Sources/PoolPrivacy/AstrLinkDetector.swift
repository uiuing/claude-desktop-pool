import CryptoKit
import Foundation
import OnnxRuntimeBindings
import PoolRuntime

public enum AstrLinkStatus: Equatable, Sendable {
    case notInstalled, installing(Double), ready, failed
}

public protocol PrivacyModelManaging: PrivacyEntityDetector {
    func status() async -> AstrLinkStatus
    func install(progress: @escaping @Sendable (Double) -> Void) async throws
    func unload() async
    /// The version detection runs on now.
    func installedVersion() async -> String
    func checkForUpdate() async throws -> AstrLinkUpdate
    /// Installs `release` beside the one in use, which keeps detecting until the new one has loaded.
    func update(to release: AstrLinkRelease, progress: @escaping @Sendable (Double) -> Void) async throws
}

/// What detection needs from a loaded model; the native ONNX session in the app, a fake in tests.
protocol AstrLinkInference: AnyObject {
    func tokens(_ text: String) throws -> [AstrLinkTokenizer.Token]
    func logits(_ ids: [Int64]) throws -> [Float]
}
typealias AstrLinkSessionFactory = @Sendable (_ model: URL, _ tokenizer: Data) throws -> any AstrLinkInference

/// An app-owned copy of the publisher's INT8 model. Inference is local and serial;
/// a bounded 512-token native call is the cancellation boundary. The release built in is the
/// first install; a newer published release replaces it after it downloads, verifies and loads,
/// and the one before stays on disk until the next update.
public actor AstrLinkDetector: PrivacyModelManaging {
    public static let modelName = "AstrLink Guard"
    public static let modelVersion = "0.1.3"
    public static let revision = "7216b6a3b897ef903d4b1ba367ae6fb95b0fa5e4"
    public static let artifacts = [
        PrivacyModelArtifact(filename: "model_int8.onnx", bytes: 330_781,
                             sha256: "0a070d3113615e33ba3b84d6bd486f663a377c04c4b056e7381732179f51832a"),
        PrivacyModelArtifact(filename: "model_int8.onnx_data", bytes: 37_124_608,
                             sha256: "0ba34216ceead01e0ae2dfd8e46d52b67e7aee80b04f722d9b758613a91c0067"),
        PrivacyModelArtifact(filename: "tokenizer.json", bytes: 1_502_881,
                             sha256: "0cf3b235ef125658015a6c8026a5fe6f28088bf825101a990ec18a10200feef4"),
    ]
    public static let builtIn = AstrLinkRelease(version: modelVersion, revision: revision, artifacts: artifacts)
    private let workspace: OwnedWorkspace
    private let downloader: any PrivacyModelDownloader
    private let releases: any AstrLinkReleaseSource
    private let makeSession: AstrLinkSessionFactory
    private var reported: AstrLinkStatus?
    private var model: (any AstrLinkInference)?
    private var activeRelease: AstrLinkRelease?
    private var updating = false
    private var activeRequests = 0
    private struct WaitingDetection {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var waitingDetections: [WaitingDetection] = []
    private var idleTask: Task<Void, Never>?

    public init(workspace: OwnedWorkspace, downloader: any PrivacyModelDownloader = OfficialPrivacyModelDownloader(),
                releases: (any AstrLinkReleaseSource)? = nil) {
        self.init(workspace: workspace, downloader: downloader, releases: releases, session: { try AstrLinkSession(path: $0, tokenizer: $1) })
    }
    init(workspace: OwnedWorkspace, downloader: any PrivacyModelDownloader, releases: (any AstrLinkReleaseSource)?,
         session: @escaping AstrLinkSessionFactory) {
        self.workspace = workspace; self.downloader = downloader
        self.releases = releases ?? OfficialAstrLinkReleases(downloader: downloader); makeSession = session
    }

    /// The release in use: the one the last update activated, else the built-in one.
    private var active: AstrLinkRelease {
        if let activeRelease { return activeRelease }
        var release = Self.builtIn
        if let data = try? workspace.read(currentFile, limit: 64 * 1024),
           let saved = try? JSONDecoder().decode(AstrLinkRelease.self, from: data), saved.isWellFormed { release = saved }
        activeRelease = release
        return release
    }
    private var currentFile: URL { workspace.root.appendingPathComponent("privacy/current.json") }
    public func installedVersion() -> String { active.version }

    public func status() -> AstrLinkStatus {
        if let reported { return reported }
        do { try load(); reported = .ready; scheduleUnload() }
        catch RuntimeError.missingFile { reported = .notInstalled }
        catch { reported = .failed }
        return reported!
    }

    public func install(progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        if case .installing = reported { throw PrivacyFailure.notReady }
        reported = .installing(0); model = nil; idleTask?.cancel()
        let release = active
        do {
            try await download(release, progress: progress)
            try load(); reported = .ready
            scheduleUnload()
        } catch is CancellationError { reported = nil; throw CancellationError() }
        catch { reported = .failed; throw PrivacyFailure.modelFailed }
    }

    public func checkForUpdate() async throws -> AstrLinkUpdate {
        switch try await releases.latest() {
        case .available(let release) where AstrLinkRelease.newer(release.version, than: active.version): return .available(release)
        case .needsNewerApp(let version) where AstrLinkRelease.newer(version, than: active.version): return .needsNewerApp(version)
        default: return .none
        }
    }

    public func update(to release: AstrLinkRelease, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        guard release.isWellFormed, AstrLinkRelease.newer(release.version, than: active.version) else { return }
        if case .installing = reported { throw PrivacyFailure.notReady }
        guard !updating else { throw PrivacyFailure.notReady }
        updating = true; defer { updating = false }
        let previous = active
        do {
            try await download(release, progress: progress)
            // The new files must load and answer before anything switches to them.
            let candidate = try session(for: release)
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            try workspace.write(try encoder.encode(release), to: currentFile)
            activeRelease = release; model = candidate; reported = .ready
            scheduleUnload()
        } catch is CancellationError { throw CancellationError() }
        catch { throw PrivacyFailure.modelFailed }
        // Keep the release just replaced, so a broken update can be undone; remove older ones.
        let keep = Set([release.revision, previous.revision].map { "astrlink-\($0)" })
        let folder = workspace.root.appendingPathComponent("privacy", isDirectory: true)
        // The workspace removes files, not folders: an old release leaves an empty folder behind.
        for entry in (try? workspace.entries(in: folder)) ?? [] where entry.lastPathComponent.hasPrefix("astrlink-") && !keep.contains(entry.lastPathComponent) {
            for file in (try? workspace.entries(in: entry)) ?? [] { try? workspace.remove(file) }
        }
    }

    /// Downloads whatever of `release` is missing or wrong into its own folder.
    private func download(_ release: AstrLinkRelease, progress: @escaping @Sendable (Double) -> Void) async throws {
        let directory = directory(for: release), total = release.artifacts.reduce(0) { $0 + $1.bytes }
        try workspace.prepare(); try workspace.createDirectory(at: directory)
        var completed = 0
        for artifact in release.artifacts {
            try Task.checkCancellation()
            let url = directory.appendingPathComponent(artifact.filename)
            let existing: Data?
            do { existing = try workspace.read(url, limit: artifact.bytes) }
            catch RuntimeError.missingFile { existing = nil }
            catch RuntimeError.oversizedInput { existing = nil }
            if existing.map({ Self.valid($0, artifact: artifact) }) != true {
                let base = completed
                let data = try await downloader.download(artifact) { fraction in
                    progress((Double(base) + Double(artifact.bytes) * min(1, max(0, fraction))) / Double(total))
                }
                try Task.checkCancellation()
                guard Self.valid(data, artifact: artifact) else { throw PrivacyFailure.modelFailed }
                try workspace.write(data, to: url, limit: 64 * 1024 * 1024)
            }
            completed += artifact.bytes
            let fraction = Double(completed) / Double(total)
            if case .installing = reported { reported = .installing(fraction) }
            progress(fraction)
        }
    }

    public func unload() {
        idleTask?.cancel(); idleTask = nil; model = nil
        if case .ready = reported { reported = nil }
    }

    public func detect(in text: String) async throws -> [PrivacySpan] {
        try Task.checkCancellation()
        guard text.utf8.count <= 1024 * 1024 else { throw PrivacyFailure.inputTooLarge }
        if case .installing = reported { throw PrivacyFailure.notReady }
        try await acquireDetection()
        defer { releaseDetection() }
        try Task.checkCancellation()
        if case .installing = reported { throw PrivacyFailure.notReady }
        do {
            if model == nil { try load() }
            reported = .ready
            guard let model else { throw PrivacyFailure.notReady }
            let tokens = try model.tokens(text)
            if tokens.isEmpty { return [] }
            var labels = [Int](repeating: 0, count: tokens.count)
            var scores = [Double](repeating: 0, count: tokens.count)
            var margins = [Int](repeating: -1, count: tokens.count)
            let deadline = ContinuousClock.now.advanced(by: .seconds(120))
            var start = 0
            while start < tokens.count {
                try Task.checkCancellation()
                guard ContinuousClock.now < deadline else { throw PrivacyFailure.modelFailed }
                let end = min(tokens.count, start + Self.window)
                let ids = [Int64(0)] + tokens[start..<end].map { Int64($0.id) } + [Int64(2)]
                let logits = try model.logits(ids)
                try Task.checkCancellation()
                for local in 0..<(end - start) {
                    let margin = min(local, end - start - local - 1), index = start + local
                    guard margin > margins[index] else { continue }
                    let row = logits[((local + 1) * 21)..<((local + 2) * 21)]
                    guard let maximum = row.max(), maximum.isFinite,
                          let winner = row.firstIndex(of: maximum) else { throw PrivacyFailure.invalidDetection }
                    let sum = row.reduce(0.0) { $0 + exp(Double($1 - maximum)) }
                    guard sum.isFinite, sum >= 1 else { throw PrivacyFailure.invalidDetection }
                    labels[index] = winner - row.startIndex; scores[index] = 1 / sum; margins[index] = margin
                }
                if end == tokens.count { break }
                start += Self.window - Self.overlap
                await Task.yield()
            }
            try Task.checkCancellation()
            return Self.spans(tokens: tokens, labels: labels, scores: scores)
        } catch is CancellationError { throw CancellationError() }
        catch RuntimeError.missingFile { reported = .notInstalled; throw PrivacyFailure.notReady }
        catch let error as PrivacyFailure {
            if error == .modelFailed || error == .invalidDetection { reported = .failed; model = nil }
            throw error
        } catch { reported = .failed; model = nil; throw PrivacyFailure.modelFailed }
    }

    private func directory(for release: AstrLinkRelease) -> URL {
        workspace.root.appendingPathComponent("privacy/astrlink-\(release.revision)", isDirectory: true)
    }

    private func load() throws { model = try session(for: active) }

    /// Verifies every file of `release` and loads it; the model must answer a minimal input.
    private func session(for release: AstrLinkRelease) throws -> any AstrLinkInference {
        let directory = directory(for: release)
        var tokenizer: Data?
        for artifact in release.artifacts {
            let data = try workspace.read(directory.appendingPathComponent(artifact.filename), limit: artifact.bytes)
            guard Self.valid(data, artifact: artifact) else { throw PrivacyFailure.modelFailed }
            if artifact.filename == "tokenizer.json" { tokenizer = data }
        }
        guard let tokenizer else { throw PrivacyFailure.modelFailed }
        let session = try makeSession(directory.appendingPathComponent("model_int8.onnx"), tokenizer)
        guard try session.logits([0, 2]).count == 2 * 21 else { throw PrivacyFailure.modelFailed }
        return session
    }

    private static func valid(_ data: Data, artifact: PrivacyModelArtifact) -> Bool {
        data.count == artifact.bytes && SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == artifact.sha256
    }

    var detectionQueueState: (active: Int, waiting: Int) { (activeRequests, waitingDetections.count) }

    /// Two detections at once, the rest in the order they came. A request is never refused or timed out
    /// here: how long it waits for the model is its own (the bridge's `PrivacyReader`), and a caller that stops waiting cancels.
    func acquireDetection() async throws {
        try Task.checkCancellation()
        if activeRequests < 2, waitingDetections.isEmpty {
            activeRequests += 1; idleTask?.cancel(); return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                waitingDetections.append(WaitingDetection(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaitingDetection(id) }
        }
    }

    func releaseDetection() {
        activeRequests -= 1
        if !waitingDetections.isEmpty {
            let next = waitingDetections.removeFirst()
            // Reserve before resuming: cancellation after this transfer is released
            // by detect's defer, so neither a newcomer nor a cancelled waiter leaks a slot.
            activeRequests += 1
            next.continuation.resume()
        }
        scheduleUnload()
    }

    private func cancelWaitingDetection(_ id: UUID) {
        guard let index = waitingDetections.firstIndex(where: { $0.id == id }) else { return }
        waitingDetections.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func scheduleUnload() {
        guard activeRequests == 0, model != nil else { return }
        idleTask?.cancel()
        idleTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
            await self?.unload()
        }
    }

    /// Tokens the model reads at once, and how many of them the next window reads again: each token is
    /// labelled from the window it is furthest inside, so a name cut by one window's end has at least
    /// `overlap / 2` tokens around it in the other.
    static let window = 510
    static let overlap = 96
    static func threads(cores: Int) -> Int { max(1, min(4, cores / 2)) }

    static func spans(tokens: [AstrLinkTokenizer.Token], labels: [Int], scores: [Double]) -> [PrivacySpan] {
        let kinds: [PrivacyCategory] = [.email, .phone, .account, .bankCard, .ip, .url, .secret, .address, .date, .person]
        var result: [PrivacySpan] = [], current: PrivacySpan?
        func finish() {
            if let span = current, span.score >= 0.8 { result.append(span) }
            current = nil
        }
        for index in tokens.indices {
            let token = tokens[index], label = labels[index]
            guard token.end > token.start else { continue }
            guard (1...20).contains(label) else { finish(); continue }
            let category = kinds[(label - 1) / 2]
            if label % 2 == 1 || current?.category != category { finish() }
            if let prior = current {
                current = PrivacySpan(start: prior.start, end: max(prior.end, token.end), category: category,
                                      score: min(prior.score, scores[index]))
            } else { current = PrivacySpan(start: token.start, end: token.end, category: category, score: scores[index]) }
        }
        finish(); return result
    }
}

private final class AstrLinkSession: AstrLinkInference {
    let tokenizer: AstrLinkTokenizer
    private let environment: ORTEnv
    private let session: ORTSession

    init(path: URL, tokenizer: Data) throws {
        self.tokenizer = try AstrLinkTokenizer(data: tokenizer)
        environment = try ORTEnv(loggingLevel: .fatal)
        let options = try ORTSessionOptions()
        // Four threads read a window in about half the time two do; more add little. Half the cores at
        // most, so the Claude sessions beside it keep theirs.
        try options.setIntraOpNumThreads(Int32(AstrLinkDetector.threads(cores: ProcessInfo.processInfo.activeProcessorCount)))
        try options.setLogSeverityLevel(.fatal)
        try options.addConfigEntry(withKey: "session.intra_op.allow_spinning", value: "0")
        try options.setGraphOptimizationLevel(.all)
        session = try ORTSession(env: environment, modelPath: path.path, sessionOptions: options)
        guard Set(try session.inputNames()) == ["input_ids", "attention_mask", "token_type_ids"],
              try session.outputNames() == ["logits"] else { throw PrivacyFailure.modelFailed }
    }

    func tokens(_ text: String) throws -> [AstrLinkTokenizer.Token] { try tokenizer.encode(text) }

    func logits(_ ids: [Int64]) throws -> [Float] {
        func tensor(_ values: [Int64]) throws -> ORTValue {
            let data = values.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
            return try ORTValue(tensorData: data, elementType: .int64, shape: [1, NSNumber(value: ids.count)])
        }
        let input = try tensor(ids), attention = try tensor([Int64](repeating: 1, count: ids.count))
        let types = try tensor([Int64](repeating: 0, count: ids.count))
        let output = try session.run(withInputs: ["input_ids": input, "attention_mask": attention, "token_type_ids": types],
                                     outputNames: ["logits"], runOptions: nil)
        guard let value = output["logits"] else { throw PrivacyFailure.invalidDetection }
        let shape = try value.tensorTypeAndShapeInfo()
        guard shape.elementType == .float, shape.shape.map(\.intValue) == [1, ids.count, 21] else {
            throw PrivacyFailure.invalidDetection
        }
        let bytes = try value.tensorData()
        guard bytes.length == ids.count * 21 * MemoryLayout<Float>.size else { throw PrivacyFailure.invalidDetection }
        return Array(UnsafeBufferPointer(start: bytes.bytes.assumingMemoryBound(to: Float.self), count: ids.count * 21))
    }
}
