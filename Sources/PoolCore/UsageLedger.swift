import Foundation

/// Tokens of replies Pool served, as the official client reported them, and what they would cost at
/// API list prices. Counts only: no content, no prompt, no conversation id. The token fields are in, out,
/// cache_read, cache_write and cache_write_1h; cost is priced per row at the tiers in `ModelPricing`.
public struct TokenTally: Codable, Equatable, Sendable {
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    /// Every cache write, the 1-hour ones included.
    public var cacheWrite = 0
    public var oneHourWrites = 0
    public var replies = 0
    /// USD at list price, of the priced replies.
    public var cost = 0.0
    /// The same replies with every cached token sent as plain input: `uncachedCost - cost` is what the cache saved.
    public var uncachedCost = 0.0
    /// Replies of a model the price table does not know; their tokens count, their cost does not.
    public var unpriced = 0
    /// Seconds the client spent generating the replies that report a time, and those replies' output tokens.
    /// Older rows have neither, so speed is `timedOutput / generationSeconds` and never `output / generationSeconds`.
    public var generationSeconds = 0.0
    public var timedOutput = 0

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, oneHourWrites: Int = 0, replies: Int = 0,
                cost: Double = 0, uncachedCost: Double = 0, unpriced: Int = 0, generationSeconds: Double = 0, timedOutput: Int = 0) {
        self.generationSeconds = generationSeconds; self.timedOutput = timedOutput
        self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
        self.oneHourWrites = oneHourWrites; self.replies = replies; self.cost = cost; self.uncachedCost = uncachedCost; self.unpriced = unpriced
    }
    public init(_ usage: BridgeUsage, price: ModelPrice?, seconds: TimeInterval? = nil) {
        input = max(0, usage.inputTokens); output = max(0, usage.outputTokens)
        cacheRead = max(0, usage.cacheReadInputTokens ?? 0); cacheWrite = max(0, usage.cacheCreationInputTokens ?? 0)
        oneHourWrites = min(cacheWrite, max(0, usage.oneHourCacheWrites ?? 0))
        replies = 1
        if let seconds, seconds.isFinite, seconds > 0, output > 0 { generationSeconds = seconds; timedOutput = output }
        if let price {
            let priced = price.cost(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite, oneHourWrites: oneHourWrites)
            cost = priced.actual; uncachedCost = priced.uncached
        } else { unpriced = 1 }
    }

    /// Input, output and both cache directions, as Claude's own activity statistics count them.
    public var total: Int { input + output + cacheRead + cacheWrite }
    public var prompt: Int { input + cacheRead + cacheWrite }
    /// The share of prompt tokens read from the cache; nil before any prompt.
    public var cacheHitRate: Double? { prompt > 0 ? Double(cacheRead) / Double(prompt) : nil }
    public var cacheSaving: Double { uncachedCost - cost }
    /// Output tokens per second of generation; nil before any reply reported a time.
    public var tokensPerSecond: Double? { generationSeconds > 0 && timedOutput > 0 ? Double(timedOutput) / generationSeconds : nil }
    public var fiveMinuteWrites: Int { cacheWrite - oneHourWrites }

    public func scaled(_ share: Double) -> Self {
        func part(_ value: Int) -> Int { Int((Double(value) * share).rounded()) }
        return .init(input: part(input), output: part(output), cacheRead: part(cacheRead), cacheWrite: part(cacheWrite),
                     oneHourWrites: part(oneHourWrites), replies: part(replies), cost: cost * share, uncachedCost: uncachedCost * share,
                     unpriced: part(unpriced), generationSeconds: generationSeconds * share, timedOutput: part(timedOutput))
    }
    public static func + (lhs: Self, rhs: Self) -> Self {
        .init(input: lhs.input + rhs.input, output: lhs.output + rhs.output, cacheRead: lhs.cacheRead + rhs.cacheRead,
              cacheWrite: lhs.cacheWrite + rhs.cacheWrite, oneHourWrites: lhs.oneHourWrites + rhs.oneHourWrites,
              replies: lhs.replies + rhs.replies, cost: lhs.cost + rhs.cost, uncachedCost: lhs.uncachedCost + rhs.uncachedCost,
              unpriced: lhs.unpriced + rhs.unpriced, generationSeconds: lhs.generationSeconds + rhs.generationSeconds,
              timedOutput: lhs.timedOutput + rhs.timedOutput)
    }
    public static func += (lhs: inout Self, rhs: Self) { lhs = lhs + rhs }

    // Short keys: a pool of a hundred accounts kept for a year writes these several hundred thousand times.
    private enum CodingKeys: String, CodingKey {
        case input = "i", output = "o", cacheRead = "r", cacheWrite = "w", oneHourWrites = "h", replies = "n"
        case cost = "c", uncachedCost = "u", unpriced = "x", generationSeconds = "s", timedOutput = "t"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input = try c.decodeIfPresent(Int.self, forKey: .input) ?? 0
        output = try c.decodeIfPresent(Int.self, forKey: .output) ?? 0
        cacheRead = try c.decodeIfPresent(Int.self, forKey: .cacheRead) ?? 0
        cacheWrite = try c.decodeIfPresent(Int.self, forKey: .cacheWrite) ?? 0
        oneHourWrites = try c.decodeIfPresent(Int.self, forKey: .oneHourWrites) ?? 0
        replies = try c.decodeIfPresent(Int.self, forKey: .replies) ?? 0
        cost = try c.decodeIfPresent(Double.self, forKey: .cost) ?? 0
        uncachedCost = try c.decodeIfPresent(Double.self, forKey: .uncachedCost) ?? 0
        unpriced = try c.decodeIfPresent(Int.self, forKey: .unpriced) ?? 0
        generationSeconds = try c.decodeIfPresent(Double.self, forKey: .generationSeconds) ?? 0
        timedOutput = try c.decodeIfPresent(Int.self, forKey: .timedOutput) ?? 0
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if input != 0 { try c.encode(input, forKey: .input) }
        if output != 0 { try c.encode(output, forKey: .output) }
        if cacheRead != 0 { try c.encode(cacheRead, forKey: .cacheRead) }
        if cacheWrite != 0 { try c.encode(cacheWrite, forKey: .cacheWrite) }
        if oneHourWrites != 0 { try c.encode(oneHourWrites, forKey: .oneHourWrites) }
        if replies != 0 { try c.encode(replies, forKey: .replies) }
        if cost != 0 { try c.encode((cost * 1e6).rounded() / 1e6, forKey: .cost) }
        if uncachedCost != 0 { try c.encode((uncachedCost * 1e6).rounded() / 1e6, forKey: .uncachedCost) }
        if unpriced != 0 { try c.encode(unpriced, forKey: .unpriced) }
        if generationSeconds != 0 { try c.encode((generationSeconds * 1000).rounded() / 1000, forKey: .generationSeconds) }
        if timedOutput != 0 { try c.encode(timedOutput, forKey: .timedOutput) }
    }
}

/// The effort a reply ran at, as the ledger keeps it: one of the official client's `--effort` levels,
/// `default` when the client named none and the run kept Claude Code's own, or `unrecorded` for rows
/// written before Pool kept the effort.
public enum UsageEffort {
    public static let levels = ["low", "medium", "high", "xhigh", "max"]
    public static let clientDefault = "default"
    public static let unrecorded = "unrecorded"
    /// What the ledger stores for a run's effort.
    public static func key(_ effort: String?) -> String {
        guard let effort = effort?.lowercased(), levels.contains(effort) else { return clientDefault }
        return effort
    }
    /// Low to max, then the client's default, then rows without one.
    public static func rank(_ key: String) -> Int {
        if let index = levels.firstIndex(of: key) { return index }
        return key == clientDefault ? levels.count : levels.count + 1
    }
}

/// One account, model and effort's replies on one day.
public struct UsageEntry: Codable, Equatable, Sendable {
    public var accountID: UUID
    /// The model id the official client reported (`claude-opus-5-5`); the key prices and filters use.
    public var model: String
    /// Its name as the client lists it (`Opus 5.5`).
    public var name: String
    /// The effort the run went at; nil in rows written before Pool kept it.
    public var effort: String?
    public var tally: TokenTally
    /// Tokens by local hour, 24 values; kept for today and yesterday only.
    public var hours: [Int]?
    public init(accountID: UUID, model: String, name: String, effort: String? = nil, tally: TokenTally = .init(),
                hours: [Int]? = Array(repeating: 0, count: 24)) {
        self.accountID = accountID; self.model = model; self.name = name; self.effort = effort; self.tally = tally; self.hours = hours
    }
    /// The effort as the page groups and filters it.
    public var effortKey: String { effort ?? UsageEffort.unrecorded }
    private enum CodingKeys: String, CodingKey { case accountID = "a", model = "m", name = "nm", effort = "ef", tally = "t", hours = "hr" }
}

public struct UsageDay: Codable, Equatable, Sendable {
    /// The local calendar day, `yyyy-MM-dd`.
    public var day: String
    public var entries: [UsageEntry]
    public init(day: String, entries: [UsageEntry] = []) { self.day = day; self.entries = entries }
    private enum CodingKeys: String, CodingKey { case day = "d", entries = "e" }
}

public enum UsageRange: String, CaseIterable, Codable, Sendable, Identifiable {
    case today, week, month, all
    public var id: String { rawValue }
    public var days: Int? { switch self { case .today: return 1; case .week: return 7; case .month: return 30; case .all: return nil } }
}

/// What the trend chart stacks.
public enum UsageGrouping: String, CaseIterable, Sendable, Identifiable {
    case model, effort, plan, account
    public var id: String { rawValue }
}

/// The accounts, model and effort the page is narrowed to; nil is all. The effort is a ledger key
/// (`UsageEffort`), so `unrecorded` narrows to rows written before Pool kept it.
public struct UsageFilter: Hashable, Sendable {
    public var accounts: Set<UUID>?
    public var model: String?
    public var effort: String?
    public init(accounts: Set<UUID>? = nil, model: String? = nil, effort: String? = nil) {
        self.accounts = accounts; self.model = model; self.effort = effort
    }
    public var isEmpty: Bool { accounts == nil && model == nil && effort == nil }
    func keeps(_ entry: UsageEntry) -> Bool {
        (accounts.map { $0.contains(entry.accountID) } ?? true) && (model.map { $0 == entry.model } ?? true)
            && (effort.map { $0 == entry.effortKey } ?? true)
    }
}

public struct UsageAmount: Equatable, Sendable {
    public var tokens = 0
    public var cost = 0.0
    public init(tokens: Int = 0, cost: Double = 0) { self.tokens = tokens; self.cost = cost }
    public static func += (lhs: inout Self, rhs: Self) { lhs.tokens += rhs.tokens; lhs.cost += rhs.cost }
}

/// One bar: an hour of today or a day, split by the grouping's series.
public struct UsageBucket: Equatable, Sendable, Identifiable {
    public var id: Int
    public var start: Date
    public var total = UsageAmount()
    public var parts: [String: UsageAmount] = [:]
}

/// A model, plan or account and what it used in the range.
public struct UsageShare: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var tally: TokenTally
    /// Tokens per bucket, for an account's trend line.
    public var trend: [Int] = []
}

public struct UsageSummary: Equatable, Sendable {
    /// The id the chart gives accounts, models or plans past its own colors.
    public static let other = "\u{0}other"
    public var range: UsageRange
    public var grouping: UsageGrouping
    public var totals = TokenTally()
    /// The same length of time just before, up to the same hour for today; nil for all time.
    public var previous: TokenTally?
    public var buckets: [UsageBucket] = []
    /// The chart's series, largest first, `other` last when there is one; ids as the buckets' parts.
    public var series: [UsageShare] = []
    /// Largest first. Model ids, plan names ("" when not reported), account UUID strings.
    public var models: [UsageShare] = []
    /// Each model's replies by effort, keyed by model id; low to max, then default and unrecorded.
    public var modelEfforts: [String: [UsageShare]] = [:]
    /// The range's replies by effort across the models shown, in the same order.
    public var efforts: [UsageShare] = []
    public var plans: [UsageShare] = []
    public var accounts: [UsageShare] = []
    public var activeDays = 0
    public var spanDays = 0
    /// The change against `previous`, when both have some.
    public var tokenChange: Double? { change(totals.total, previous?.total) }
    public var costChange: Double? { change(totals.cost, previous?.cost) }
    public var replyChange: Double? { change(totals.replies, previous?.replies) }
    private func change<V: BinaryInteger>(_ now: V, _ before: V?) -> Double? {
        guard let before, before > 0 else { return nil }
        return Double(now - before) / Double(before)
    }
    private func change(_ now: Double, _ before: Double?) -> Double? {
        guard let before, before > 0.005 else { return nil }
        return (now - before) / before
    }
}

/// Pool's own ledger of the replies it served, a row per day, account and model. It is written when
/// a reply reports its usage, one row per call, so nothing scans
/// transcripts, which Pool removes after a run.
public struct UsageLedger: Codable, Equatable, Sendable {
    public static let keptDays = 400
    /// How many accounts or plans the chart colors on its own; the rest are one series.
    public static let seriesLimit = 5
    public var version = 2
    /// Oldest first.
    public private(set) var days: [UsageDay] = []
    public init(days: [UsageDay] = []) { self.days = days.sorted { $0.day < $1.day } }
    private enum CodingKeys: String, CodingKey { case version, days }

    public var isEmpty: Bool { days.isEmpty }

    /// `effort` is the run's `--effort`, nil when the client named none and the run kept Claude Code's own.
    public mutating func record(_ usage: BridgeUsage, accountID: UUID, model: String, name: String, effort: String? = nil, at date: Date,
                                seconds: TimeInterval? = nil, calendar: Calendar = .current) {
        let effort = UsageEffort.key(effort)
        let tally = TokenTally(usage, price: ModelPricing.price(for: model), seconds: seconds)
        guard tally.total > 0 else { return }
        let key = Self.key(date, calendar: calendar), hour = calendar.component(.hour, from: date)
        let index: Int
        if let last = days.indices.last, days[last].day == key { index = last }
        else if let found = days.firstIndex(where: { $0.day == key }) { index = found }
        else {
            // A clock set back lands in its own day, kept in order.
            index = days.firstIndex { $0.day > key } ?? days.endIndex
            days.insert(UsageDay(day: key), at: index)
            compact(now: date, calendar: calendar)
            return record(usage, accountID: accountID, model: model, name: name, effort: effort, at: date, seconds: seconds, calendar: calendar)
        }
        if let entry = days[index].entries.firstIndex(where: { $0.accountID == accountID && $0.model == model && $0.effort == effort }) {
            days[index].entries[entry].tally += tally
            days[index].entries[entry].name = name
            if days[index].entries[entry].hours != nil { days[index].entries[entry].hours?[hour] += tally.total }
        } else {
            var entry = UsageEntry(accountID: accountID, model: model, name: name, effort: effort, tally: tally)
            entry.hours?[hour] = tally.total
            days[index].entries.append(entry)
        }
    }

    /// Days past `keptDays` are dropped; hours are let go once a day is older than yesterday.
    public mutating func compact(now: Date, calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        if let oldest = calendar.date(byAdding: .day, value: -Self.keptDays, to: today) {
            let cut = Self.key(oldest, calendar: calendar)
            if let first = days.first, first.day < cut { days.removeAll { $0.day < cut } }
        }
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return }
        let keep = Self.key(yesterday, calendar: calendar)
        for index in days.indices where days[index].day < keep && days[index].entries.contains(where: { $0.hours != nil }) {
            for entry in days[index].entries.indices { days[index].entries[entry].hours = nil }
        }
    }

    /// The models seen, by id, with their latest name: what the page's model filter offers.
    public var modelNames: [String: String] {
        var names: [String: String] = [:]
        for day in days { for entry in day.entries { names[entry.model] = entry.name } }
        return names
    }

    /// The efforts seen, ledger keys low to max then default and unrecorded: what the page's effort filter
    /// offers; only those of `model` when one is given.
    public func effortKeys(model: String? = nil) -> [String] {
        var keys = Set<String>()
        for day in days { for entry in day.entries where model == nil || entry.model == model { keys.insert(entry.effortKey) } }
        return keys.sorted { UsageEffort.rank($0) < UsageEffort.rank($1) }
    }

    public func summary(_ range: UsageRange, filter: UsageFilter = .init(), grouping: UsageGrouping = .model,
                        plans: [UUID: String] = [:], now: Date, calendar: Calendar = .current) -> UsageSummary {
        var summary = UsageSummary(range: range, grouping: grouping)
        let today = calendar.startOfDay(for: now)
        var byKey: [String: [UsageEntry]] = [:]
        for day in days { byKey[day.day] = day.entries.filter(filter.keeps) }
        var models: [String: TokenTally] = [:], names: [String: String] = [:]
        var planTotals: [String: TokenTally] = [:], accounts: [UUID: TokenTally] = [:], trends: [UUID: [Int]] = [:]
        var groups: [String: TokenTally] = [:], modelEfforts: [String: [String: TokenTally]] = [:], efforts: [String: TokenTally] = [:]
        func groupKey(_ entry: UsageEntry) -> String {
            switch grouping {
            case .model: return entry.model
            case .effort: return entry.effortKey
            case .plan: return plans[entry.accountID] ?? ""
            case .account: return entry.accountID.uuidString
            }
        }
        func take(_ entry: UsageEntry) {
            summary.totals += entry.tally
            models[entry.model, default: .init()] += entry.tally; names[entry.model] = entry.name
            modelEfforts[entry.model, default: [:]][entry.effortKey, default: .init()] += entry.tally
            efforts[entry.effortKey, default: .init()] += entry.tally
            planTotals[plans[entry.accountID] ?? "", default: .init()] += entry.tally
            accounts[entry.accountID, default: .init()] += entry.tally
            groups[groupKey(entry), default: .init()] += entry.tally
        }
        func amount(_ tally: TokenTally, tokens: Int? = nil) -> UsageAmount {
            let tokens = tokens ?? tally.total
            return UsageAmount(tokens: tokens, cost: tally.total > 0 ? tally.cost * Double(tokens) / Double(tally.total) : 0)
        }
        if range == .today {
            let entries = byKey[Self.key(today, calendar: calendar)] ?? []
            entries.forEach(take)
            summary.buckets = (0..<24).map { hour in
                var bucket = UsageBucket(id: hour, start: calendar.date(byAdding: .hour, value: hour, to: today) ?? today)
                for entry in entries {
                    let tokens = entry.hours?[hour] ?? 0
                    guard tokens > 0 else { continue }
                    let part = amount(entry.tally, tokens: tokens)
                    bucket.total += part; bucket.parts[groupKey(entry), default: .init()] += part
                    trends[entry.accountID, default: Array(repeating: 0, count: 24)][hour] += tokens
                }
                return bucket
            }
            summary.activeDays = entries.isEmpty ? 0 : 1; summary.spanDays = 1
            // Yesterday up to this hour, so a morning is not set against a whole day.
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: today) {
                let hour = calendar.component(.hour, from: now)
                var previous = TokenTally()
                for entry in byKey[Self.key(yesterday, calendar: calendar)] ?? [] {
                    let share = entry.tally.total > 0 ? Double((entry.hours ?? []).prefix(hour + 1).reduce(0, +)) / Double(entry.tally.total) : 0
                    previous += entry.tally.scaled(share)
                }
                summary.previous = previous
            }
        } else {
            let first: Date
            if let count = range.days { first = calendar.date(byAdding: .day, value: -(count - 1), to: today) ?? today }
            else { first = min(today, days.first.flatMap { Self.date($0.day, calendar: calendar) } ?? today) }
            let count = max(1, (calendar.dateComponents([.day], from: first, to: today).day ?? 0) + 1)
            summary.spanDays = count
            summary.buckets = (0..<count).map { offset in
                let date = calendar.date(byAdding: .day, value: offset, to: first) ?? first
                let entries = byKey[Self.key(date, calendar: calendar)] ?? []
                var bucket = UsageBucket(id: offset, start: date)
                for entry in entries {
                    take(entry)
                    let part = amount(entry.tally)
                    bucket.total += part; bucket.parts[groupKey(entry), default: .init()] += part
                    trends[entry.accountID, default: Array(repeating: 0, count: count)][offset] += entry.tally.total
                }
                if !entries.isEmpty { summary.activeDays += 1 }
                return bucket
            }
            if let count = range.days, let start = calendar.date(byAdding: .day, value: -count, to: first) {
                var previous = TokenTally()
                for offset in 0..<count {
                    guard let date = calendar.date(byAdding: .day, value: offset, to: start) else { continue }
                    for entry in byKey[Self.key(date, calendar: calendar)] ?? [] { previous += entry.tally }
                }
                summary.previous = previous
            }
        }
        func ranked(_ values: [String: TokenTally], name: (String) -> String) -> [UsageShare] {
            values.map { UsageShare(id: $0.key, name: name($0.key), tally: $0.value) }
                .sorted { ($0.tally.total, $1.id) > ($1.tally.total, $0.id) }
        }
        summary.models = ranked(models) { names[$0] ?? $0 }
        func byEffort(_ values: [String: TokenTally]) -> [UsageShare] {
            values.map { UsageShare(id: $0.key, name: $0.key, tally: $0.value) }.sorted { UsageEffort.rank($0.id) < UsageEffort.rank($1.id) }
        }
        summary.modelEfforts = modelEfforts.mapValues(byEffort)
        summary.efforts = byEffort(efforts)
        summary.plans = ranked(planTotals) { $0 }
        summary.accounts = accounts.map { UsageShare(id: $0.key.uuidString, name: "", tally: $0.value, trend: trends[$0.key] ?? []) }
            .sorted { ($0.tally.total, $1.id) > ($1.tally.total, $0.id) }
        // The chart colors the largest few series; the rest are stacked together as one.
        var series = ranked(groups) { grouping == .model ? names[$0] ?? $0 : $0 }
        // Efforts keep their order, low to max, whatever each used.
        if grouping == .effort { series.sort { UsageEffort.rank($0.id) < UsageEffort.rank($1.id) } }
        if series.count > Self.seriesLimit + 1 {
            let kept = Set(series.prefix(Self.seriesLimit).map(\.id))
            var other = UsageShare(id: UsageSummary.other, name: "", tally: .init())
            for share in series.dropFirst(Self.seriesLimit) { other.tally += share.tally }
            // How many series it holds, for the legend.
            other.trend = [series.count - Self.seriesLimit]
            summary.series = Array(series.prefix(Self.seriesLimit)) + [other]
            for index in summary.buckets.indices {
                var folded: [String: UsageAmount] = [:]
                for (key, value) in summary.buckets[index].parts { folded[kept.contains(key) ? key : UsageSummary.other, default: .init()] += value }
                summary.buckets[index].parts = folded
            }
        } else {
            summary.series = series
        }
        return summary
    }

    public static func key(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
    public static func date(_ key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}
