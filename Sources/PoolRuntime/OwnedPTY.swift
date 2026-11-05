import Foundation
import Darwin
import CPTY

public enum PTYEvent: Equatable, Sendable {
    case output(Data)
    case exited(Int32)
}

/// A terminal created by this app. Terminal output is a bounded UI feed; hooks carry protocol events.
public final class OwnedPTY: @unchecked Sendable {
    public let processID: Int32
    private let descriptor: Int32
    private let stateLock = NSLock()
    private let writeLock = NSLock()
    private var status: Int32?
    private var closed = false
    private var subscribers: [UUID: AsyncStream<PTYEvent>.Continuation] = [:]
    private var recentOutput = Data()
    private var byteCount = 0

    public var isRunning: Bool { stateLock.withLock { status == nil } }
    public var exitStatus: Int32? { stateLock.withLock { status } }
    public var outputBytesReceived: Int { stateLock.withLock { byteCount } }

    /// Each observer has its own lifetime, so cancelling an account check does not disconnect the UI.
    public var events: AsyncStream<PTYEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(128)) { sink in
            let id = UUID()
            let ended: Int32? = stateLock.withLock {
                if !recentOutput.isEmpty { sink.yield(.output(recentOutput)) }
                if closed { return status }
                subscribers[id] = sink
                return nil
            }
            sink.onTermination = { [weak self] _ in self?.removeObserver(id) }
            if let ended { sink.yield(.exited(ended)); sink.finish() }
        }
    }

    private init(child: pool_pty_child) {
        processID = child.pid; descriptor = child.master
        DispatchQueue(label: "pool.pty.wait.\(child.pid)", qos: .utility).async { [self] in
            var result: Int32 = 0
            let error = pool_pty_wait(processID, &result)
            stateLock.withLock { status = error == 0 ? result : 255 }
        }
        DispatchQueue(label: "pool.pty.read.\(child.pid)", qos: .utility).async { [self] in readOutput() }
    }

    public static func start(executable: URL, arguments: [String], environment: [String: String],
                             directory: URL) throws -> OwnedPTY {
        guard executable.isFileURL, executable.path.hasPrefix("/"), directory.isFileURL,
              !arguments.contains(where: { $0.contains("\0") }),
              !environment.contains(where: { $0.key.isEmpty || $0.key.contains("=") || $0.key.contains("\0") || $0.value.contains("\0") }),
              access(executable.path, X_OK) == 0 else { throw RuntimeError.invalidExecutable }
        var info = stat()
        guard stat(executable.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw RuntimeError.invalidExecutable }
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.keys.sorted().map { strdup("\($0)=\(environment[$0]!)") } + [nil]
        defer { for p in argv { free(p) }; for p in envp { free(p) } }
        var child = pool_pty_child()
        let result = argv.withUnsafeBufferPointer { arguments in
            envp.withUnsafeBufferPointer { environment in
                pool_pty_start(executable.path, arguments.baseAddress, environment.baseAddress, directory.path, 50, 180, &child)
            }
        }
        guard result == 0 else { throw RuntimeError.launchFailed(result) }
        return OwnedPTY(child: child)
    }

    public func write(_ data: Data) throws {
        guard data.count <= 4 * 1024 * 1024 else { throw RuntimeError.oversizedInput }
        try writeLock.withLock {
            guard stateLock.withLock({ !closed && status == nil }) else { throw RuntimeError.processExited }
            let deadline = Date().addingTimeInterval(10)
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count > 0 { offset += count; continue }
                    if count < 0 && errno == EINTR { continue }
                    if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK), Date() < deadline {
                        var pollfd = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                        let result = poll(&pollfd, 1, 100)
                        if result >= 0 || errno == EINTR { continue }
                    }
                    throw RuntimeError.writeFailed
                }
            }
        }
    }

    /// Enters one line as a terminal does. Text is wrapped only when the child has enabled
    /// bracketed paste, and Return is a separate keystroke after the text has been taken in:
    /// a Return that arrives with the paste can become part of it.
    public func submitLine(_ text: String, bracketed: Bool, settle: Duration = .milliseconds(150)) async throws {
        guard text.utf8.count <= 64 * 1024 else { throw RuntimeError.oversizedInput }
        guard !text.isEmpty, text.unicodeScalars.allSatisfy({ $0.value >= 32 || $0 == "\t" }),
              !text.unicodeScalars.contains(where: { $0.value == 127 || (128...159).contains($0.value) }) else {
            throw RuntimeError.invalidTerminalInput
        }
        try write(Data((bracketed ? "\u{1b}[200~" + text + "\u{1b}[201~" : text).utf8))
        try await Task.sleep(for: settle)
        try write(Data("\r".utf8))
    }

    public func interrupt() throws { try write(Data([3])) }

    /// The caller must establish that the session is idle before requesting its normal exit.
    public func exitWhenIdle() throws { try write(Data("/exit\r".utf8)) }

    public func waitForExit(timeout: TimeInterval = 5) async throws -> Int32 {
        let deadline = ContinuousClock.now.advanced(by: .seconds(max(0, timeout)))
        while true {
            if let status = exitStatus { return status }
            guard ContinuousClock.now < deadline else { throw RuntimeError.processUnresponsive }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func readOutput() {
        var bytes = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            // Output and hang-up return at once; the timeout only looks for the exit status.
            let ready = poll(&event, 1, 500)
            if ready < 0 && errno == EINTR { continue }
            if ready > 0 {
                while true {
                    let count = Darwin.read(descriptor, &bytes, bytes.count)
                    if count > 0 { publish(Data(bytes.prefix(count))); continue }
                    if count < 0 && errno == EINTR { continue }
                    break
                }
            }
            if let status = exitStatus {
                let sinks = writeLock.withLock {
                    let sinks = stateLock.withLock {
                        closed = true
                        let values = Array(subscribers.values); subscribers.removeAll()
                        return values
                    }
                    close(descriptor)
                    return sinks
                }
                for sink in sinks { sink.yield(.exited(status)); sink.finish() }
                return
            }
            if ready != 0 && event.revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
    }

    private func publish(_ bytes: Data) {
        let sinks = stateLock.withLock {
            byteCount += bytes.count
            recentOutput.append(bytes)
            if recentOutput.count > 256 * 1024 { recentOutput.removeFirst(recentOutput.count - 256 * 1024) }
            return Array(subscribers.values)
        }
        for sink in sinks { sink.yield(.output(bytes)) }
    }

    private func removeObserver(_ id: UUID) {
        stateLock.withLock { _ = subscribers.removeValue(forKey: id) }
    }
}
