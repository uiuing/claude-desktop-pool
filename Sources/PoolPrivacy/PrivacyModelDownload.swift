import Foundation

/// One file of a published release, with the size and SHA-256 its publisher recorded.
public struct PrivacyModelArtifact: Codable, Equatable, Sendable {
    public let filename: String
    public let bytes: Int
    public let sha256: String
    public let revision: String
    public init(filename: String, bytes: Int, sha256: String, revision: String = AstrLinkDetector.revision) {
        self.filename = filename; self.bytes = bytes; self.sha256 = sha256; self.revision = revision
    }
    public var url: URL { AstrLinkRelease.file("int8/\(filename)", revision: revision) }
}

public protocol PrivacyModelDownloader: Sendable {
    func download(_ artifact: PrivacyModelArtifact, progress: @escaping @Sendable (Double) -> Void) async throws -> Data
    /// A small public metadata file of at most `limit` bytes: release tags, checksums, labels.
    func metadata(_ url: URL, limit: Int) async throws -> Data
}

public extension PrivacyModelDownloader {
    func metadata(_ url: URL, limit: Int) async throws -> Data { throw PrivacyFailure.modelFailed }
}

public struct OfficialPrivacyModelDownloader: PrivacyModelDownloader {
    public init() {}
    public func download(_ artifact: PrivacyModelArtifact,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        try await run(PrivacyDownload(url: artifact.url, limit: artifact.bytes, exact: true, progress: progress))
    }
    public func metadata(_ url: URL, limit: Int) async throws -> Data {
        try await run(PrivacyDownload(url: url, limit: limit, exact: false, progress: { _ in }))
    }
    private func run(_ operation: PrivacyDownload) async throws -> Data {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await operation.start()
        } onCancel: { operation.cancel() }
    }
}

/// Only public model files and release metadata cross the network. No inference text enters this type.
private final class PrivacyDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let url: URL
    /// The exact size of a model file, or the most a metadata file may be.
    let limit: Int
    let exact: Bool
    let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var cancelled = false
    private var bytes = Data()
    private var redirects = 0

    init(url: URL, limit: Int, exact: Bool, progress: @escaping @Sendable (Double) -> Void) {
        self.url = url; self.limit = limit; self.exact = exact; self.progress = progress
    }

    func start() async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard !cancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
            self.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil; configuration.httpCookieStorage = nil
            configuration.urlCredentialStorage = nil; configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = 45; configuration.timeoutIntervalForResource = 300
            configuration.httpMaximumConnectionsPerHost = 1
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            var request = URLRequest(url: url)
            request.setValue(exact ? "application/octet-stream" : "application/json", forHTTPHeaderField: "Accept")
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            let task = session.dataTask(with: request)
            self.session = session; self.task = task
            lock.unlock(); task.resume()
        }
    }

    func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard redirects <= 5, let url = request.url, Self.allowed(url),
              request.value(forHTTPHeaderField: "Authorization") == nil else {
            completionHandler(nil); finish(.failure(PrivacyFailure.modelFailed)); return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              let url = response.url, Self.allowed(url),
              response.expectedContentLength == -1 || (exact ? response.expectedContentLength == limit : response.expectedContentLength <= limit) else {
            completionHandler(.cancel); finish(.failure(PrivacyFailure.modelFailed)); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard data.count <= limit - bytes.count else { finish(.failure(PrivacyFailure.modelFailed)); return }
        bytes.append(data); progress(Double(bytes.count) / Double(limit))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let cancelled = cancelled; lock.unlock()
        if cancelled { finish(.failure(CancellationError())) }
        else if error != nil || (exact && bytes.count != limit) { finish(.failure(PrivacyFailure.modelFailed)) }
        else { finish(.success(bytes)) }
    }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        let continuation = continuation; self.continuation = nil
        let session = session; self.session = nil; task = nil
        lock.unlock()
        session?.invalidateAndCancel(); continuation?.resume(with: result)
    }

    private static func allowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return host == "huggingface.co" || host == "cdn-lfs.huggingface.co" ||
            host == "cdn-lfs-us-1.hf.co" || host == "cdn-lfs-eu-1.hf.co" ||
            host == "cas-bridge.xethub.hf.co" || host == "us.aws.cdn.hf.co"
    }
}
