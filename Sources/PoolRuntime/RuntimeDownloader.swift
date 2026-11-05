import Foundation

public protocol RuntimeDownloader: Sendable {
    func fetch(_ url: URL, maximumBytes: Int64,
               receive: @escaping @Sendable (Data) throws -> Void) async throws
}

public struct OfficialRuntimeDownloader: RuntimeDownloader {
    private let configuration: @Sendable () -> URLSessionConfiguration
    public init() { configuration = { .ephemeral } }
    init(configuration: @escaping @Sendable () -> URLSessionConfiguration) { self.configuration = configuration }
    public func fetch(_ url: URL, maximumBytes: Int64,
                      receive: @escaping @Sendable (Data) throws -> Void) async throws {
        guard Self.isOfficialURL(url), maximumBytes > 0 else { throw RuntimeInstallError.invalidRelease }
        let transfer = RuntimeTransfer(url: url, limit: maximumBytes, configuration: configuration(), receive: receive)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await transfer.start()
        } onCancel: { transfer.cancel() }
    }

    public static func isOfficialURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "downloads.claude.ai" && (url.port == nil || url.port == 443) &&
            url.user == nil && url.password == nil && url.query == nil && url.fragment == nil &&
            url.path.hasPrefix("/claude-code-releases/") && !url.pathComponents.contains("..")
    }
}

private final class RuntimeTransfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let limit: Int64
    private let configuration: URLSessionConfiguration
    private let receive: @Sendable (Data) throws -> Void
    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private var cancelled = false
    private var received: Int64 = 0

    init(url: URL, limit: Int64, configuration: URLSessionConfiguration, receive: @escaping @Sendable (Data) throws -> Void) {
        self.url = url; self.limit = limit; self.configuration = configuration; self.receive = receive
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
            self.continuation = continuation
            let config = configuration
            config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCache = nil; config.urlCredentialStorage = nil
            config.timeoutIntervalForRequest = 45; config.timeoutIntervalForResource = 1800
            let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
            self.session = session
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            let task = session.dataTask(with: request); self.task = task
            lock.unlock()
            task.resume()
        }
    }

    func cancel() {
        let task = lock.withLock { cancelled = true; return self.task }
        task?.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        lock.withLock { failure = RuntimeInstallError.downloadFailed }
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, response.url == url,
              response.expectedContentLength <= limit else {
            lock.withLock { failure = RuntimeInstallError.downloadFailed }
            completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let accepted = lock.withLock {
            received += Int64(data.count)
            if received > limit { failure = RuntimeInstallError.verificationFailed; return false }
            return failure == nil && !cancelled
        }
        guard accepted else { dataTask.cancel(); return }
        do { try receive(data) }
        catch { lock.withLock { failure = error }; dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result = lock.withLock { () -> (CheckedContinuation<Void, Error>?, Error?) in
            let continuation = self.continuation; self.continuation = nil
            let failure = cancelled ? CancellationError() : (self.failure ?? (error == nil ? nil : RuntimeInstallError.downloadFailed))
            self.task = nil; self.session = nil
            return (continuation, failure)
        }
        session.finishTasksAndInvalidate()
        if let failure = result.1 { result.0?.resume(throwing: failure) }
        else { result.0?.resume() }
    }
}
