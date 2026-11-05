import Foundation

/// A limit starts on an account's first request after it resets. The pool can start it itself:
/// one short request through the official client starts every limit that isn't running, so the
/// next one is back sooner (on reset), or the 5-hour limits follow the day (at set times).
public struct WarmUpPreferences: Codable, Equatable, Sendable {
    public enum Reset: String, Codable, CaseIterable, Sendable {
        /// Limits start on their own first use.
        case off
        /// The weekly limit starts at its reset: once a week per account.
        case week
        /// The weekly and 5-hour limits start at their resets, so they run back to back.
        case all
    }
    public var onReset: Reset
    /// Local times ("06:00") at which each account's 5-hour limit starts if it isn't running.
    public private(set) var dailyTimes: [String]
    public init(onReset: Reset = .off, dailyTimes: [String] = []) {
        self.onReset = onReset; self.dailyTimes = Self.normalized(dailyTimes)
    }
    public var isOn: Bool { onReset != .off || !dailyTimes.isEmpty }

    /// Valid times of day as "HH:mm", in order, without repeats, at most six.
    public static func normalized(_ times: [String]) -> [String] {
        Array(Set(times.compactMap(minutes)).sorted().prefix(6)).map { String(format: "%02d:%02d", $0 / 60, $0 % 60) }
    }
    /// Minutes past midnight of "HH:mm"; nil unless it is a time of day.
    public static func minutes(_ text: String) -> Int? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ (1...2).contains($0.count) && $0.unicodeScalars.allSatisfy { ("0"..."9").contains($0) } }),
              let hour = Int(parts[0]), let minute = Int(parts[1]), (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return hour * 60 + minute
    }

    enum CodingKeys: String, CodingKey { case onReset, dailyTimes }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // A setting a later version wrote is read as the default rather than failing the library.
        self.init(onReset: (try? values.decodeIfPresent(Reset.self, forKey: .onReset)) ?? .off,
                  dailyTimes: (try? values.decodeIfPresent([String].self, forKey: .dailyTimes)) ?? [])
    }
}

/// What the pool did to start an account's limits: a stretch of not running is warmed until a
/// request starts it, a request that did not is tried again later rather than at every look,
/// and each set time is served once.
public struct WarmUpState: Codable, Equatable, Sendable {
    /// When the limits being started stopped running: the reset they came back at, or when the
    /// pool first found them not running.
    public var since: Date?
    /// Requests sent for that stretch, and when the next may go.
    public var tries = 0
    public var retryAt: Date?
    /// The set time last served, as "2026-11-05 06:00" in local time.
    public var daily: String?
    /// When a warm-up last went through.
    public var warmedAt: Date?
    public init(since: Date? = nil, tries: Int = 0, retryAt: Date? = nil, daily: String? = nil, warmedAt: Date? = nil) {
        self.since = since; self.tries = tries; self.retryAt = retryAt; self.daily = daily; self.warmedAt = warmedAt
    }
}

/// A warm-up that is due: the limits it starts, the stretch it is for and the set time it serves.
public struct WarmUpPlan: Equatable, Sendable {
    public var windows: [String]
    public var since: Date
    public var daily: String?
    public init(windows: [String], since: Date, daily: String? = nil) { self.windows = windows; self.since = since; self.daily = daily }
}

public enum WarmUpPlanner {
    /// The request: the shortest exchange the client has, with nothing of the person's in it.
    public static let prompt = "Reply with OK."
    /// The limits a warm-up starts; a model's own weekly limit starts with its first use of that model.
    public static let limits: Set<String> = ["five_hour", "seven_day"]
    /// A reset is left to settle this long before it is warmed.
    public static let settle: TimeInterval = 60
    /// A set time missed while the Mac slept is served up to this late.
    public static let lateness: TimeInterval = 3600
    /// A limit that reads 0% with this much of its span or more still ahead has not really begun:
    /// Claude can report a limit nobody has used as starting now.
    public static let fresh: TimeInterval = 600
    /// Requests sent for one stretch before it is given up; the next reset begins a new one.
    public static let maximumTries = 6

    /// After a request, the next for the same stretch waits 15 minutes, then twice as long each
    /// time, up to four hours.
    public static func retryDelay(tries: Int) -> TimeInterval { min(4 * 3600, 900 * pow(2, Double(max(0, tries - 1)))) }

    /// Whether `window` is a limit a warm-up starts that is not running now: its reset passed a
    /// moment ago or longer, or it reads 0% used with no reset or with its whole span ahead.
    public static func idle(_ window: QuotaWindow, at now: Date) -> Bool {
        guard limits.contains(window.id), window.modelFamily == nil, window.state == .reported, window.observedAt <= now else { return false }
        if let reset = window.resetsAt {
            if reset <= now.addingTimeInterval(-settle) { return true }
            return window.usedPercent == 0 && reset.timeIntervalSince(now) >= window.span - fresh
        }
        return window.usedPercent == 0 || now.timeIntervalSince(window.observedAt) >= window.span
    }

    /// The warm-up due on `account` now, if any.
    public static func plan(_ account: PoolAccount, preferences: WarmUpPreferences, state: WarmUpState?,
                            now: Date, calendar: Calendar) -> WarmUpPlan? {
        // Only an account that can serve: never one whose week is used up or that is at a limit.
        guard preferences.isOn, account.standing(at: now) == .usable else { return nil }
        let idle = account.windows.filter { Self.idle($0, at: now) }
        guard !idle.isEmpty else { return nil }
        // A stretch begins at the latest reset that passed, else when the pool found the limit idle.
        var since = state?.since ?? now
        if let passed = idle.compactMap(\.resetsAt).filter({ $0 <= now }).max(), state?.since == nil || passed > since { since = passed }
        if state?.since == since {
            if (state?.tries ?? 0) >= maximumTries { return nil }
            if let retry = state?.retryAt, retry > now { return nil }
        }
        let fiveHour = idle.contains { $0.id == "five_hour" }
        if fiveHour, let key = dueDaily(preferences.dailyTimes, served: state?.daily, now: now, calendar: calendar) {
            return WarmUpPlan(windows: idle.map(\.id).sorted(), since: since, daily: key)
        }
        // A request starts every limit that isn't running. While a set time is under five hours
        // away, an idle 5-hour limit waits for it, and anything else due waits with it.
        if fiveHour, let next = nextDaily(preferences.dailyTimes, after: now, calendar: calendar),
           next.timeIntervalSince(now) < 5 * 3600 { return nil }
        guard idle.contains(where: { $0.id == "seven_day" ? preferences.onReset != .off : preferences.onReset == .all }) else { return nil }
        return WarmUpPlan(windows: idle.map(\.id).sorted(), since: since)
    }

    /// The latest set time that came within the last hour and was not served yet, as its key.
    static func dueDaily(_ times: [String], served: String?, now: Date, calendar: Calendar) -> String? {
        let due = occurrences(times, around: now, calendar: calendar)
            .filter { $0 <= now && now.timeIntervalSince($0) < lateness }.max()
        guard let due else { return nil }
        let key = Self.key(due, calendar: calendar)
        return key == served ? nil : key
    }
    /// The next set time after `now`.
    public static func nextDaily(_ times: [String], after now: Date, calendar: Calendar) -> Date? {
        occurrences(times, around: now, calendar: calendar).filter { $0 > now }.min()
    }
    private static func occurrences(_ times: [String], around now: Date, calendar: Calendar) -> [Date] {
        let today = calendar.startOfDay(for: now)
        return [-1, 0, 1].compactMap { calendar.date(byAdding: .day, value: $0, to: today) }.flatMap { day in
            times.compactMap(WarmUpPreferences.minutes).compactMap {
                calendar.date(bySettingHour: $0 / 60, minute: $0 % 60, second: 0, of: day)
            }
        }
    }
    static func key(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "%04d-%02d-%02d %02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }
}
