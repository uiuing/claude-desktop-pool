import Foundation
import Darwin

/// Wakes a timed wait as soon as a watched folder or file changes. Files the run's helper and
/// hooks write are renamed into their folder, so a folder is watched for its entries; a file
/// written by appending (the tap, the transcript) is watched itself. The wait still ends at its
/// time when nothing changes, so a change missed costs no more than the look it replaces.
/// A path that is not there yet is tried again on the next `watch`.
/// One waiter at a time: an event that comes with nobody waiting ends the next wait at once.
final class FileWake: @unchecked Sendable {
    private let lock = NSCondition()
    private let queue = DispatchQueue(label: "pool.filewake", qos: .utility)
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var timer: DispatchSourceTimer?
    private var waiter: (ticket: UInt64, due: DispatchTime, resume: CheckedContinuation<Bool, Never>)?
    private var tickets: UInt64 = 0
    private var pending = false
    private var closed = false
    private var wokenCount = 0
    private var polledCount = 0

    init(_ paths: [String] = []) { watch(paths) }
    deinit { close() }

    /// Waits ended early by a change, and waits that ran their full time.
    var woken: Int { lock.withLock { wokenCount } }
    var polled: Int { lock.withLock { polledCount } }
    var watching: Int { lock.withLock { sources.count } }

    /// Watches each path not watched yet; one that cannot be opened is left for a later call.
    func watch(_ paths: [String]) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        for path in paths where sources[path] == nil {
            let descriptor = open(path, O_EVTONLY | O_CLOEXEC)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                                   eventMask: [.write, .extend, .delete, .rename], queue: queue)
            source.setEventHandler { [weak self, weak source] in
                guard let self, let source else { return }
                // a file replaced or removed is watched again under its path at the next `watch`
                if !source.data.isDisjoint(with: [.delete, .rename]) { self.drop(path, source) }
                self.signal()
            }
            source.setCancelHandler { Darwin.close(descriptor) }
            sources[path] = source
            source.resume()
        }
    }

    /// Ends at the first change since the last wait, or after `duration`, or when the task is cancelled.
    func wait(upTo duration: Duration) async {
        let (seconds, attoseconds) = duration.components
        let nanoseconds = max(0, seconds * 1_000_000_000 + attoseconds / 1_000_000_000)
        let ticket: UInt64 = lock.withLock { tickets += 1; return tickets }
        _ = await withTaskCancellationHandler {
            await withCheckedContinuation { (resume: CheckedContinuation<Bool, Never>) in
                lock.lock()
                if pending { pending = false; wokenCount += 1; lock.unlock(); resume.resume(returning: true); return }
                if Task.isCancelled { lock.unlock(); resume.resume(returning: false); return }
                let due = DispatchTime.now() + .nanoseconds(Int(nanoseconds))
                waiter = (ticket, due, resume)
                (self.timer ?? makeTimer()).schedule(deadline: due)
                lock.unlock()
            }
        } onCancel: {
            finish(ticket, early: nil)
        }
    }

    /// The same wait for a thread that blocks; whether a change ended it.
    @discardableResult
    func waitBlocking(upTo seconds: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let until = Date().addingTimeInterval(seconds)
        while !pending {
            if !lock.wait(until: until) { polledCount += 1; return false }
        }
        pending = false; wokenCount += 1
        return true
    }

    /// Stops watching and closes every descriptor; later waits are only timed.
    func close() {
        lock.lock()
        closed = true
        let open = Array(sources.values); sources.removeAll()
        let timer = self.timer; self.timer = nil
        let waiting = waiter; waiter = nil
        lock.unlock()
        for source in open { source.cancel() }
        timer?.cancel()
        waiting?.resume.resume(returning: false)
    }

    private func makeTimer() -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.lock.lock()
            // a firing meant for an earlier wait leaves this one to its own time
            let resume = self.waiter.flatMap { $0.due <= .now() ? self.take($0.ticket, early: false) : nil }
            self.lock.unlock()
            resume?.resume(returning: false)
        }
        self.timer = timer
        timer.resume()
        return timer
    }

    private func signal() {
        lock.lock()
        if let ticket = waiter?.ticket, let resume = take(ticket, early: true) {
            lock.unlock(); resume.resume(returning: true)
            return
        }
        pending = true
        lock.broadcast()
        lock.unlock()
    }

    /// Resumes the wait holding `ticket` once: early by a change, at its time, or (nil) cancelled.
    private func finish(_ ticket: UInt64, early: Bool?) {
        lock.lock()
        let resume = take(ticket, early: early)
        lock.unlock()
        resume?.resume(returning: early == true)
    }

    /// Under the lock: the wait holding `ticket`, taken and counted.
    private func take(_ ticket: UInt64, early: Bool?) -> CheckedContinuation<Bool, Never>? {
        guard let waiting = waiter, waiting.ticket == ticket else { return nil }
        waiter = nil
        timer?.schedule(deadline: .distantFuture)
        if early == true { wokenCount += 1 } else if early == false { polledCount += 1 }
        return waiting.resume
    }

    private func drop(_ path: String, _ source: DispatchSourceFileSystemObject) {
        lock.lock()
        if sources[path] === source { sources[path] = nil }
        lock.unlock()
        source.cancel()
    }
}
