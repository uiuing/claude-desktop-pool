import Foundation

public enum QuotaWorkState: String, Codable, Sendable { case generating, waitingTool, waitingUser, idle, ended }

/// Counts only. Progress is cumulative within one official worker attempt, so delivery
/// duplicates cannot increase demand and character/token measurements are not added twice.
public struct QuotaProgress: Equatable, Sendable {
    public var requestID: UUID
    public var sequence: Int
    public var outputCharacters: Int
    public var usage: BridgeUsage?
    public var activeDuration: TimeInterval
    public var observedAt: Date
    public init(requestID: UUID, sequence: Int, outputCharacters: Int, usage: BridgeUsage? = nil,
                activeDuration: TimeInterval, observedAt: Date) {
        self.requestID = requestID; self.sequence = sequence; self.outputCharacters = outputCharacters
        self.usage = usage; self.activeDuration = activeDuration; self.observedAt = observedAt
    }
}

public struct QuotaCadenceSnapshot: Codable, Equatable, Sendable {
    public var interval: TimeInterval?
    public var demand: Double
    public var generatingSessions: Int
    public init(interval: TimeInterval? = nil, demand: Double = 0, generatingSessions: Int = 0) {
        self.interval = interval; self.demand = demand; self.generatingSessions = generatingSessions
    }
}

/// A dimensionless refresh-demand signal, never an estimate of quota or reset time.
/// One generating session contributes one unit. Measured output at 120 characters/s
/// or official usage at 40 tokens/s contributes one unit. Two distinct measured
/// responses per minute also contribute one unit. Take the maximum of these overlapping
/// signals. Rates use a 15s EWMA and decay from their actual observation times.
/// Waiting and completed work contribute a bounded tail, not a busy baseline.
public struct QuotaCadence: Equatable, Sendable {
    private struct Work: Equatable, Sendable {
        var state: QuotaWorkState = .idle
        var stateAt: Date = .distantPast
        var lastActivity: Date = .distantPast
        var rate = 0.0
        var completionRate = 0.0
        var lastCompletionAt: Date?
        var completedRequests: [UUID] = []
        var progress: QuotaProgress?
    }
    private var sessions: [UUID: Work] = [:]
    public init() {}

    public mutating func setState(_ state: QuotaWorkState, sessionID: UUID, at date: Date) {
        guard state == .generating || sessions[sessionID] != nil else { return }
        var work = sessions[sessionID] ?? Work()
        guard date >= work.stateAt, state != work.state else { return }
        work.state = state; work.stateAt = date
        if state == .generating { work.lastActivity = max(date, work.lastActivity) }
        sessions[sessionID] = work
        prune(at: date)
    }

    public mutating func record(_ progress: QuotaProgress, sessionID: UUID) {
        guard progress.sequence >= 0, progress.outputCharacters >= 0, progress.activeDuration.isFinite,
              progress.activeDuration >= 0 else { return }
        var work = sessions[sessionID] ?? Work()
        let previous = work.progress
        guard progress.observedAt >= work.lastActivity else { return }
        let sameRequest = previous?.requestID == progress.requestID
        if sameRequest, let previous {
            guard progress.sequence > previous.sequence, progress.outputCharacters >= previous.outputCharacters,
                  progress.activeDuration >= previous.activeDuration else { return }
        }
        if !sameRequest, work.completedRequests.contains(progress.requestID) { return }
        let characters = progress.outputCharacters - (sameRequest ? previous?.outputCharacters ?? 0 : 0)
        let elapsed = max(0, progress.activeDuration - (sameRequest ? previous?.activeDuration ?? 0 : 0))
        let usage = progress.usage.flatMap { $0.inputTokens >= 0 && $0.outputTokens >= 0 ? $0 : nil }
        let completed = usage != nil && !work.completedRequests.contains(progress.requestID)
        guard characters > 0 || completed else { return }
        var measured = elapsed > 0 ? Double(characters) / max(0.1, elapsed) / 120 : 0
        if completed, let usage, progress.activeDuration > 0 {
            measured = max(measured, (Double(usage.inputTokens) + Double(usage.outputTokens)) / max(0.1, progress.activeDuration) / 40)
        }
        if completed {
            if let previousCompletion = work.lastCompletionAt {
                let gap = max(0, progress.observedAt.timeIntervalSince(previousCompletion))
                let frequency = min(16, 30 / max(0.1, gap))
                let weight = work.completionRate == 0 ? 1 : 1 - exp(-gap / 15)
                work.completionRate += (frequency - work.completionRate) * weight
            }
            work.lastCompletionAt = progress.observedAt
            work.completedRequests.append(progress.requestID)
            if work.completedRequests.count > 64 { work.completedRequests.removeFirst() }
        }
        // Limit the signal, not the reported measurement; beyond four units the user-set
        // fastest rate already applies. Keeping some headroom avoids a single burst latching.
        measured = min(16, measured)
        let measuredDuration = completed ? max(elapsed, progress.activeDuration) : elapsed
        let progressGap = previous.map { max(0, progress.observedAt.timeIntervalSince($0.observedAt)) } ?? elapsed
        let weight = previous == nil ? 1 : 1 - exp(-max(measuredDuration, progressGap) / 15)
        let quietGap = max(0, progressGap - elapsed)
        let decayed = work.rate * exp(-quietGap / 30)
        work.rate = decayed * (1 - weight) + measured * weight
        work.progress = progress; work.lastActivity = progress.observedAt
        sessions[sessionID] = work
        prune(at: progress.observedAt)
    }

    public func snapshot(at now: Date, preferences: QuotaRefreshPreferences) -> QuotaCadenceSnapshot {
        var demand = 0.0, generating = 0
        for work in sessions.values {
            let age = max(0, now.timeIntervalSince(work.lastActivity))
            let throughputAge = max(0, now.timeIntervalSince(work.progress?.observedAt ?? work.lastActivity))
            let completionAge = max(0, now.timeIntervalSince(work.lastCompletionAt ?? .distantPast))
            switch work.state {
            case .generating:
                generating += 1
                demand += max(1, work.rate * exp(-throughputAge / 30), work.completionRate * exp(-completionAge / 30))
            case .waitingTool, .waitingUser, .idle, .ended:
                let horizon: TimeInterval = work.state == .waitingUser ? 30 : work.state == .waitingTool ? 60 : 120
                guard age < horizon else { continue }
                let decay: TimeInterval = work.state == .waitingUser ? 10 : work.state == .waitingTool ? 20 : 30
                demand += 0.5 * max(0.25 * exp(-age / decay), work.rate * exp(-throughputAge / decay),
                                    work.completionRate * exp(-completionAge / decay))
            }
        }
        guard demand >= 0.01 else { return .init() }
        return .init(interval: preferences.interval(demand: demand), demand: demand, generatingSessions: generating)
    }
    private mutating func prune(at date: Date) {
        sessions = sessions.filter { $0.value.state == .generating || date.timeIntervalSince($0.value.lastActivity) < 120 }
    }
}

/// How fast each limit that applies to every model is being used, from successive official
/// readings of the same cycle. It never estimates quota; it only says how urgent the next read
/// is. Far from the switch threshold a read can wait, close to it the read comes sooner.
public struct QuotaBurn: Equatable, Sendable {
    private struct Reading: Equatable, Sendable { var used: Double; var at: Date; var reset: Date? }
    private var readings: [String: Reading] = [:]
    /// Percent of the limit per second, smoothed over about ten minutes of readings.
    private var rates: [String: Double] = [:]
    public init() {}

    public mutating func record(_ windows: [QuotaWindow]) {
        for window in windows where window.isGlobal && window.state == .reported {
            guard let used = window.usedPercent, used.isFinite, (0...100).contains(used) else { continue }
            let next = Reading(used: used, at: window.observedAt, reset: window.resetsAt)
            guard let previous = readings[window.id] else { readings[window.id] = next; continue }
            guard next.at > previous.at else { continue }
            readings[window.id] = next
            // A new cycle, or a figure that went down, says nothing about the pace of this one.
            guard previous.reset == next.reset, used >= previous.used else { rates.removeValue(forKey: window.id); continue }
            let elapsed = next.at.timeIntervalSince(previous.at)
            let measured = (used - previous.used) / elapsed
            let weight = 1 - exp(-elapsed / 600)
            rates[window.id] = rates[window.id].map { $0 + (measured - $0) * weight } ?? measured
        }
    }

    /// Seconds until the tightest limit reaches `reserve` percent left at the measured pace, or
    /// until it runs out once already below. Nil without a measured, positive pace.
    public func secondsToReserve(_ account: PoolAccount, reserve: Double, now: Date) -> TimeInterval? {
        account.windows.compactMap { window -> TimeInterval? in
            guard window.isGlobal, let rate = rates[window.id], rate > 0,
                  let left = PoolRouting.remaining(window, in: account, now: now) else { return nil }
            return (left > reserve ? left - reserve : left) / rate
        }.min()
    }

    /// Moves the activity-based interval by at most a factor of three toward a sixth of the time
    /// left before the threshold, within the 10-second floor and a 10-minute ceiling.
    public func interval(_ activity: TimeInterval, account: PoolAccount, reserve: Double, now: Date) -> TimeInterval {
        guard let time = secondsToReserve(account, reserve: reserve, now: now) else { return activity }
        let target = time / 6
        return min(max(600, activity), max(10, min(activity * 3, max(activity / 3, target))))
    }
}
