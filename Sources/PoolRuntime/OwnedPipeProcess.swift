import Foundation
import Darwin

/// An app-created child that is interrupted and awaited through the same narrow controls.
public protocol OwnedChild: AnyObject, Sendable {
    var processID: Int32 { get }
    var isRunning: Bool { get }
    func write(_ data: Data) throws
    func interrupt() throws
    func waitForExit(timeout: TimeInterval) async throws -> Int32
}

extension OwnedPTY: OwnedChild {}

/// A child whose standard output is a plain pipe. Machine-readable official commands use it,
/// because a terminal receives rendered output with cursor controls and hard line wraps.
public final class OwnedPipeProcess: OwnedChild, @unchecked Sendable {
    public let processID: Int32
    private let process: Process
    private let input: FileHandle
    private let limit: Int
    private let lock = NSLock()
    private var status: Int32?
    private var drained = false
    private var captured = Data()
    private var byteCount = 0

    public var isRunning: Bool { lock.withLock { status == nil } }
    public var outputBytesReceived: Int { lock.withLock { byteCount } }
    /// Standard output, bounded by `outputLimit`. Standard error is not retained.
    public var output: Data { lock.withLock { captured } }

    private init(process: Process, input: FileHandle, limit: Int) {
        self.process = process; self.input = input; self.limit = limit
        processID = process.processIdentifier
    }

    public static func start(executable: URL, arguments: [String], environment: [String: String],
                             directory: URL, outputLimit: Int = 64 * 1024) throws -> OwnedPipeProcess {
        guard executable.isFileURL, executable.path.hasPrefix("/"), directory.isFileURL,
              !arguments.contains(where: { $0.contains("\0") }),
              !environment.contains(where: { $0.key.isEmpty || $0.key.contains("=") || $0.key.contains("\0") || $0.value.contains("\0") }),
              access(executable.path, X_OK) == 0 else { throw RuntimeError.invalidExecutable }
        var info = stat()
        guard stat(executable.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw RuntimeError.invalidExecutable }
        let process = Process(), stdin = Pipe(), stdout = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        // A late write after the child exits must fail with an error rather than a process signal.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let exit = ExitBox()
        process.terminationHandler = { finished in
            let code = finished.terminationReason == .uncaughtSignal ? 128 + finished.terminationStatus : finished.terminationStatus
            exit.deliver(code)
        }
        do { try process.run() } catch { throw RuntimeError.launchFailed(-1) }
        let child = OwnedPipeProcess(process: process, input: stdin.fileHandleForWriting, limit: outputLimit)
        exit.attach { [child] code in
            child.lock.withLock { child.status = code }
            try? child.input.close()
        }
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        let reader = stdout.fileHandleForReading
        DispatchQueue(label: "pool.pipe.read.\(child.processID)", qos: .utility).async { [child] in
            while true {
                let bytes = reader.availableData
                if bytes.isEmpty { break }
                child.append(bytes)
            }
            try? reader.close()
            child.lock.withLock { child.drained = true }
        }
        return child
    }

    public func write(_ data: Data) throws {
        guard data.count <= 64 * 1024 else { throw RuntimeError.oversizedInput }
        guard isRunning else { throw RuntimeError.processExited }
        do { try input.write(contentsOf: data) } catch { throw RuntimeError.writeFailed }
    }

    /// The normal terminal interrupt. Pool never escalates to a forced termination.
    public func interrupt() throws {
        guard isRunning else { throw RuntimeError.processExited }
        guard kill(processID, SIGINT) == 0 else { throw RuntimeError.writeFailed }
    }

    /// Returns once the child has exited and its output pipe has been read to the end.
    public func waitForExit(timeout: TimeInterval = 5) async throws -> Int32 {
        let deadline = ContinuousClock.now.advanced(by: .seconds(max(0, timeout)))
        while true {
            let (result, complete) = lock.withLock { (status, drained) }
            if let result, complete { return result }
            if result != nil, ContinuousClock.now >= deadline.advanced(by: .seconds(2)) { return result! }
            guard ContinuousClock.now < deadline || result != nil else { throw RuntimeError.processUnresponsive }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private func append(_ bytes: Data) {
        lock.withLock {
            byteCount += bytes.count
            let room = max(0, limit - captured.count)
            if room > 0 { captured.append(bytes.prefix(room)) }
        }
    }
}

/// Holds an exit status that can arrive before the owning object exists.
private final class ExitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var code: Int32?
    private var receiver: ((Int32) -> Void)?

    func deliver(_ value: Int32) {
        let target: ((Int32) -> Void)? = lock.withLock {
            code = value
            return receiver
        }
        target?(value)
    }

    func attach(_ target: @escaping (Int32) -> Void) {
        let ready: Int32? = lock.withLock {
            receiver = target
            return code
        }
        if let ready { target(ready) }
    }
}
