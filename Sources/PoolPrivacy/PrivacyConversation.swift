import Foundation
import CryptoKit
import PoolCore

struct MaskedText {
    var text: String
    var categories: [PrivacyCategory: Int]
    var placeholders: Set<String>
    var numbers: Set<UInt64> = []
    /// Inspected for this request, not taken from what an earlier request already sent.
    var fresh = true
    /// Went as received: `text` is left empty in the cache, since the request brings it again.
    var unchanged = false
    /// What a restart keeps of it: the digest of what went, and where in it each stand-in stands
    /// (UTF-16 offsets), so the same text masks to the same words again without its values kept.
    var sha = ""
    var at: [Int] = []
    var tokens: [String] = []
    /// Its stand-ins could be told apart from its words, so it can be kept across a restart.
    var keepable = true
    var count: Int { categories.values.reduce(0, +) }
}
struct MaskedNumber {
    var value: Double
    var category: PrivacyCategory?
    var fresh = true
}

/// Only occurrences read by this preparation can become sent history.
final class PrivacyPreparation {
    var textKeys: Set<String> = []
    var numberKeys: Set<String> = []
    /// While the outbound request is produced: the new parts that had something replaced.
    var review: [PrivacyReviewField]?
    /// While the request's texts are gathered for the model, before anything is masked.
    var collecting = false
    /// Where in the request gathering is: the higher, the newer (a later message), and read first.
    var section = 0
    /// Texts to be masked afresh, for the model to read, each once.
    private var wanted: [(text: String, key: String, order: Int)] = []
    /// Texts sent before without the model's reading, to look up what it has found in them since.
    private(set) var lookUps: [(text: String, key: String)] = []
    private var gathered: Set<String> = []
    /// What the model had found in a text by the end of the request's wait, and what the rules find
    /// in it, by `findsKey`; a text with no model entry goes with the rules and known values alone.
    var finds: [String: [PrivacySpan]] = [:]
    var rules: [String: [PrivacySpan]] = [:]
    /// Texts masked without the model's reading (cache keys): once sent, what it finds in them later
    /// becomes known (`learnLate`).
    var unreadKeys: Set<String> = []

    func want(_ text: String, key: String) {
        guard gathered.insert(key).inserted else { return }
        wanted.append((text, key, section << 32 | wanted.count))
    }
    func lookUp(_ text: String, key: String) {
        if gathered.insert("late\u{0}" + key).inserted { lookUps.append((text, key)) }
    }
    /// The texts to read, newest first (what is new in a request is at its end): a
    /// later message's before an earlier one's, the messages' before the system prompt's and the tools'.
    var newestFirst: [(text: String, key: String)] { wanted.sorted { $0.order > $1.order }.map { ($0.text, $0.key) } }
}

final class PrivacyConversation {
    struct Value {
        var original: String
        var category: PrivacyCategory
    }
    private let key: SymmetricKey
    private var byValue: [String: String] = [:]
    private var counters: [PrivacyCategory: Int] = [:]
    /// Words shaped like a stand-in in what the conversation has said, which no value may go as.
    private var reservedWords: Set<String> = []
    /// Keys of the texts `bytes` counts, oldest first, for letting go of when full.
    private var heldKeys: [String] = []
    private(set) var values: [String: Value] = [:]
    private var cache: [String: MaskedText] = [:]
    private var sentCacheKeys: Set<String> = []
    private var numberByOriginal: [UInt64: Double] = [:]
    private(set) var numbers: [UInt64: (original: Double, category: PrivacyCategory)] = [:]
    private var originalNumbers: Set<UInt64> = []
    private var numberCache: [String: MaskedNumber] = [:]
    private var sentNumberKeys: Set<String> = []
    /// Texts sent without the model's reading, by cache key, until what it found in them is known.
    private var sentUnread: Set<String> = []
    private var bytes = 0
    var busy = false
    var lastUsed = Date()
    var historyFingerprint: String?
    var pending: Set<String> = []
    var aliases: Set<String> = []
    var activeRequest: UUID?
    var backendReady = false
    var cancelled = false
    var backendCancellationRequested = false
    var allowed: [String: String] = [:]
    var allowedNumbers: [UInt64: Double] = [:]
    /// A key of the conversation's first exchange as its client wrote it, once it has one.
    var opening: String?
    /// The first exchanges of every task this context served, newest last: the parallel tasks of one
    /// conversation share its id, and a task's request is told apart by its opening. Not kept across a restart.
    private(set) var openings: [String] = []
    static let openingsMost = 16
    func served(opening key: String) {
        openings.removeAll { $0 == key }; openings.append(key)
        if openings.count > Self.openingsMost { openings.removeFirst(openings.count - Self.openingsMost) }
    }
    /// This Mac's account names, masked wherever they stand as a word: in a folder's name
    /// (`-Users-name-project`), a listing's owner column, a prompt. Short ones too, which `minKnown`
    /// would leave.
    var machineUsers: [String] = []
    /// The content-free tag of the conversation this context serves: its client session's, or for a
    /// fork or a new client session of a conversation, the one it was forked from.
    let conversationTag: String?
    /// The id the pool sees for this context. It carries `conversationTag` after "@", so the pool
    /// can tell a conversation's side requests and forks from other conversations.
    let backendID: String
    init(session: String? = nil, conversationTag: String? = nil) {
        key = SymmetricKey(size: .bits256)
        self.conversationTag = conversationTag ?? session.map { Diagnostics.tag($0) }
        backendID = "privacy:" + UUID().uuidString + (self.conversationTag.map { "@" + $0 } ?? "")
    }

    /// The context a spare was copied from (`spare(of:)`), let go of when the spare's request ends.
    var spareOf: UUID?
    /// A copy for one request that goes on from nothing this context answered — no reply, no tools —
    /// while this context still answers another: Claude Code's auto-mode check of each tool call comes this
    /// way, often two at once. It knows what this context learnt, so text sent before is not read again and
    /// goes with the same stand-ins; the pool sees it under an id of its own. None of this context's
    /// requests, results or tasks is its.
    func spare(of source: UUID) -> PrivacyConversation {
        let copy = PrivacyConversation(copying: self)
        copy.spareOf = source
        return copy
    }
    private init(copying other: PrivacyConversation) {
        key = other.key
        conversationTag = other.conversationTag
        backendID = "privacy:" + UUID().uuidString + (other.conversationTag.map { "@" + $0 } ?? "")
        byValue = other.byValue; counters = other.counters; reservedWords = other.reservedWords
        heldKeys = other.heldKeys; values = other.values; cache = other.cache; sentCacheKeys = other.sentCacheKeys
        numberByOriginal = other.numberByOriginal; numbers = other.numbers; originalNumbers = other.originalNumbers
        numberCache = other.numberCache; sentNumberKeys = other.sentNumberKeys; sentUnread = other.sentUnread
        bytes = other.bytes; places = other.places; numberPlaces = other.numberPlaces; restored = other.restored
        restoredNumbers = other.restoredNumbers; unbound = other.unbound; unboundNumbers = other.unboundNumbers
        machineUsers = other.machineUsers
    }

    // MARK: Across a restart

    /// What a restart keeps of a conversation: no value it masked, and nothing keyed by one. Each text
    /// it sent is kept by its place as the digest of what went and where each stand-in stood, with how long
    /// the value behind each stand-in is. After the restart the client sends the history again, values
    /// and all: where a text at its place, cut at those lengths and given those stand-ins, is what went,
    /// the values are read back from it, and it goes as it went. A text that is not is masked afresh.
    /// A place may have held several texts: the parallel tasks of one conversation share its context, each
    /// with its own words at the same place, so each place keeps up to `placeMost` of them.
    struct Saved: Codable {
        var tag: String?
        var backendID: String
        /// Each stand-in's kind and the UTF-16 length of the value behind it.
        var standIns: [String: SavedStandIn]
        var numbers: [SavedNumberStandIn]
        var counters: [String: Int]
        var reserved: [String]
        var texts: [String: [SavedText]]
        var numberPlaces: [String: SavedNumber]
        var lastUsed: Date
        var pending: [String]
        var aliases: [String]
    }
    struct SavedStandIn: Codable { var category: PrivacyCategory; var length: Int }
    struct SavedNumberStandIn: Codable { var standIn: UInt64; var category: PrivacyCategory; var length: Int }
    struct SavedText: Codable {
        var sha: String
        var at: [Int]
        var tokens: [String]
        var unchanged: Bool
        var unread: Bool
        var categories: [String: Int]
    }
    struct SavedNumber: Codable { var value: Double; var category: PrivacyCategory? }

    /// Each sent text's and number's place, by cache key, for what a restart keeps.
    private var places: [String: String] = [:]
    private var numberPlaces: [String: String] = [:]
    /// Kept from before the restart, by place, until the client sends the text there again.
    private var restored: [String: [SavedText]] = [:]
    /// Texts kept at one place across a restart, the latest sent first.
    static let placeMost = 8
    private var restoredNumbers: [String: SavedNumber] = [:]
    /// Stand-ins from before the restart whose values no text sent again has told yet: none is given
    /// to a new value.
    private var unbound: [String: SavedStandIn] = [:]
    private var unboundNumbers: [UInt64: SavedNumberStandIn] = [:]

    var saved: Saved {
        var standIns: [String: SavedStandIn] = unbound, numberStandIns = unboundNumbers
        for (token, value) in values { standIns[token] = .init(category: value.category, length: (value.original as NSString).length) }
        for (standIn, value) in numbers {
            numberStandIns[standIn] = .init(standIn: standIn, category: value.category, length: (Self.numberText(value.original) as NSString).length)
        }
        let numberTokens = Set(numberStandIns.keys.map { Self.numberText(Double(bitPattern: $0)) })
        var texts: [String: [SavedText]] = [:]
        // What is held now first, newest sent first; then what came from before the restart and was not sent again.
        let order = Dictionary(uniqueKeysWithValues: heldKeys.enumerated().map { ($1, $0) })
        let held = cache.filter { sentCacheKeys.contains($0.key) && $0.value.keepable && !$0.value.sha.isEmpty }
            .sorted { (order[$0.key] ?? -1) > (order[$1.key] ?? -1) }
        for (key, masked) in held {
            guard let place = places[key],
                  masked.tokens.allSatisfy({ standIns[$0] != nil || numberTokens.contains($0) }) else { continue }
            texts[place, default: []].append(SavedText(sha: masked.sha, at: masked.at, tokens: masked.tokens, unchanged: masked.unchanged,
                                     unread: sentUnread.contains(key),
                                     categories: Dictionary(uniqueKeysWithValues: masked.categories.map { ($0.key.rawValue, $0.value) })))
        }
        for (place, kept) in restored { texts[place, default: []] += kept }
        for (place, list) in texts {
            var seen = Set<String>()
            texts[place] = Array(list.filter { seen.insert($0.sha).inserted }.prefix(Self.placeMost))
        }
        var places = restoredNumbers
        for (key, masked) in numberCache where sentNumberKeys.contains(key) {
            if let place = numberPlaces[key] { places[place] = SavedNumber(value: masked.value, category: masked.category) }
        }
        return Saved(tag: conversationTag, backendID: backendID, standIns: standIns, numbers: Array(numberStandIns.values),
                     counters: Dictionary(uniqueKeysWithValues: counters.map { ($0.key.rawValue, $0.value) }),
                     reserved: reservedWords.sorted(), texts: texts, numberPlaces: places, lastUsed: lastUsed,
                     pending: pending.sorted(), aliases: aliases.filter { !$0.hasPrefix("request:") }.sorted())
    }

    /// A conversation as `saved` kept it, with a key of its own: nothing kept is keyed.
    init(saved: Saved) {
        key = SymmetricKey(size: .bits256)
        conversationTag = saved.tag; backendID = saved.backendID
        unbound = saved.standIns
        for number in saved.numbers { unboundNumbers[number.standIn] = number }
        for (name, count) in saved.counters { if let category = PrivacyCategory(rawValue: name) { counters[category] = count } }
        reservedWords = Set(saved.reserved).union(saved.standIns.keys)
        restored = saved.texts; restoredNumbers = saved.numberPlaces
        lastUsed = saved.lastUsed; pending = Set(saved.pending); aliases = Set(saved.aliases)
    }

    static func sha(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).lowercaseHex }
    private static func place(_ location: String, _ field: String?) -> String {
        location + "\u{0}" + (field.flatMap(PrivacyRules.fieldCategory)?.rawValue ?? "")
    }

    /// The text kept at `place` from before a restart, when `text` is what went there: cut at the kept
    /// stand-ins' places and lengths, given them, it reads as what went. Its values are then known again,
    /// and it goes as it went. Each text kept there is tried; the one taken is no longer kept, the others
    /// stay for the tasks they were sent for. False, and nothing learnt, otherwise.
    private func adopt(_ text: String, place: String, key: String) -> Bool {
        guard let kept = restored[place] else { return false }
        for (index, saved) in kept.enumerated() where adopt(text, saved, place: place, key: key) {
            restored[place]?.remove(at: index)
            if restored[place]?.isEmpty == true { restored[place] = nil }
            return true
        }
        return false
    }
    private func adopt(_ text: String, _ saved: SavedText, place: String, key: String) -> Bool {
        guard saved.at.count == saved.tokens.count else { return false }
        let ns = text as NSString
        var output = "", cursor = 0, shift = 0, told: [String: String] = [:]
        for (offset, token) in zip(saved.at, saved.tokens) {
            let tokenLength = (token as NSString).length
            guard let length = lengthOf(token), length > 0 else { return false }
            let start = offset + shift
            guard start >= cursor, start + length <= ns.length else { return false }
            output += ns.substring(with: NSRange(location: cursor, length: start - cursor)) + token
            let original = ns.substring(with: NSRange(location: start, length: length))
            if let earlier = told[token], earlier != original { return false }
            told[token] = original
            cursor = start + length; shift += length - tokenLength
        }
        output += ns.substring(from: cursor)
        guard Self.sha(output) == saved.sha, told.allSatisfy({ fits($0.key, $0.value) }) else { return false }
        for (token, original) in told { bind(token, original) }
        var categories: [PrivacyCategory: Int] = [:]
        for (name, count) in saved.categories { if let category = PrivacyCategory(rawValue: name) { categories[category] = count } }
        let numeric = Set(told.keys.compactMap { token in values[token] == nil ? Double(token)?.bitPattern : nil })
        var kept = MaskedText(text: saved.unchanged ? "" : output, categories: categories,
                              placeholders: Set(told.keys.filter { values[$0] != nil }), numbers: numeric, fresh: false, unchanged: saved.unchanged)
        kept.sha = saved.sha; kept.at = saved.at; kept.tokens = saved.tokens
        guard (try? remember(kept, for: key)) != nil else { return false }
        places[key] = place; sentCacheKeys.insert(key)
        if saved.unread { sentUnread.insert(key) }
        return true
    }
    private func lengthOf(_ token: String) -> Int? {
        if let value = values[token] { return (value.original as NSString).length }
        if let kept = unbound[token] { return kept.length }
        guard let number = Double(token) else { return nil }
        if let value = numbers[number.bitPattern] { return (Self.numberText(value.original) as NSString).length }
        return unboundNumbers[number.bitPattern]?.length
    }
    /// `original` can be what `token` stands for: the value it stands for already, or one not given
    /// another stand-in.
    private func fits(_ token: String, _ original: String) -> Bool {
        if let value = values[token] { return value.original == original }
        if unbound[token] != nil {
            let other = byValue[digest("value\u{0}" + original)]
            return other == nil || other == token
        }
        guard let standIn = Double(token)?.bitPattern else { return false }
        if let value = numbers[standIn] { return Self.numberText(value.original) == original }
        guard unboundNumbers[standIn] != nil, let number = Double(original), Self.numberText(number) == original else { return false }
        return numberByOriginal[number.bitPattern] == nil || numberByOriginal[number.bitPattern]?.bitPattern == standIn
    }
    private func bind(_ token: String, _ original: String) {
        if let kept = unbound.removeValue(forKey: token) {
            values[token] = Value(original: original, category: kept.category)
            byValue[digest("value\u{0}" + original)] = token
            bytes += original.utf8.count
        } else if let standIn = Double(token)?.bitPattern, let kept = unboundNumbers.removeValue(forKey: standIn), let number = Double(original) {
            numbers[standIn] = (number, kept.category)
            numberByOriginal[number.bitPattern] = Double(bitPattern: standIn)
            originalNumbers.insert(number.bitPattern)
        }
    }
    /// The number kept at `location` from before a restart, when `number` is what went there.
    private func adoptNumber(_ number: Double, location: String, key: String) -> MaskedNumber? {
        guard let saved = restoredNumbers.removeValue(forKey: location) else { return nil }
        if let category = saved.category {
            let standIn = saved.value.bitPattern, original = Self.numberText(number)
            if let value = numbers[standIn] { guard value.original == number else { return nil } }
            else {
                guard unboundNumbers[standIn] != nil, numberByOriginal[number.bitPattern] == nil else { return nil }
                unboundNumbers[standIn] = .init(standIn: standIn, category: category, length: (original as NSString).length)
                bind(Self.numberText(saved.value), original)
            }
        } else if saved.value != number { return nil }
        let result = MaskedNumber(value: saved.value, category: saved.category, fresh: false)
        numberCache[key] = result; sentNumberKeys.insert(key); numberPlaces[key] = location
        return result
    }

    func digest(_ text: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: key).lowercaseHex
    }

    /// The key the model's and the rules' finds for `text` are kept by in a preparation.
    func findsKey(_ text: String) -> String { digest("model\u{0}" + text) }
    private func textKey(_ text: String, field: String?, location: String) -> String {
        digest(location + "\u{0}" + (field.flatMap(PrivacyRules.fieldCategory)?.rawValue ?? "") + "\u{0}" + text)
    }

    enum Reading { case none, read, lookUp }
    /// What masking `text` at `location` asks of the model: a text masked afresh is read (within the
    /// request's wait); one sent before goes as it went, and is only looked up when it went without the
    /// model's reading, for what the model has found in it since. A text masking refuses is not read.
    func reading(_ text: String, field: String?, location: String) -> Reading {
        guard !text.isEmpty, text.utf8.count <= 8 * 1024 * 1024 else { return .none }
        let key = textKey(text, field: field, location: location)
        if !sentCacheKeys.contains(key), !restored.isEmpty { _ = adopt(text, place: Self.place(location, field), key: key) }
        guard cache[key] != nil, sentCacheKeys.contains(key) else { return .read }
        return sentUnread.contains(key) ? .lookUp : .none
    }
    /// The text of `number` for the model to read, when masking it afresh asks the model.
    func readingNumber(_ number: Double, location: String) -> String? {
        let key = digest(location + "\u{0}\(number.bitPattern)")
        if numberCache[key] != nil, sentNumberKeys.contains(key) { return nil }
        if restoredNumbers[location] != nil { return nil }
        guard number.isFinite, numberByOriginal[number.bitPattern] == nil, numbers[number.bitPattern] == nil else { return nil }
        return Self.numberText(number)
    }

    /// `text` masked with what the whole of it holds for the local model, read now; for a preview, and
    /// for tests. Throws what the detector throws.
    func mask(_ text: String, field: String? = nil, location: String = "text", preparation: PrivacyPreparation? = nil,
              detector: any PrivacyEntityDetector) async throws -> MaskedText {
        let model = try await PrivacyReader.readWhole(text, detector: detector)
        return try mask(text, field: field, location: location, preparation: preparation, model: model)
    }

    /// `text` masked by the rules, its field's kind, the model's finds and the values known: `model`, else
    /// what `preparation` has of the model's reading of it. A text the model has not read goes with the
    /// rest alone. A text sent before goes as it went,
    /// and what the model has found in it since becomes known for new text (`learnLate`).
    func mask(_ text: String, field: String? = nil, location: String = "text", preparation: PrivacyPreparation? = nil,
              model explicit: [PrivacySpan]? = nil) throws -> MaskedText {
        guard text.utf8.count <= 8 * 1024 * 1024 else { throw PrivacyFailure.inputTooLarge }
        let hint = field.flatMap(PrivacyRules.fieldCategory)
        let cacheKey = textKey(text, field: field, location: location)
        preparation?.textKeys.insert(cacheKey)
        let place = Self.place(location, field)
        if !sentCacheKeys.contains(cacheKey), !restored.isEmpty { _ = adopt(text, place: place, key: cacheKey) }
        let modelKey = explicit == nil && preparation != nil ? findsKey(text) : ""
        let model = explicit ?? preparation?.finds[modelKey]
        if var prior = cache[cacheKey], sentCacheKeys.contains(cacheKey) {
            if let model, sentUnread.contains(cacheKey) { learnLate(model, in: text); sentUnread.remove(cacheKey) }
            if prior.unchanged { prior.text = text }
            prior.fresh = false; return prior
        }
        if model == nil && !text.isEmpty { preparation?.unreadKeys.insert(cacheKey) } else { preparation?.unreadKeys.remove(cacheKey) }
        reserveWords(in: text)
        var found: [PrivacySpan]
        if !modelKey.isEmpty, let rules = preparation?.rules[modelKey] { found = rules }
        else {
            found = PrivacyRules.spans(in: text)
            if !modelKey.isEmpty { preparation?.rules[modelKey] = found }
        }
        if !text.isEmpty, let hint, PrivacyRules.fieldValue(text, category: hint) { found.append(.init(start: 0, end: text.utf16.count, category: hint)) }
        let ns = text as NSString
        for span in model ?? [] where span.score >= 0.6 {
            if let span = Self.modelSpan(span, in: ns) { found.append(span) }
        }
        let known = Array(values.values) + numbers.values.map { Value(original: Self.numberText($0.original), category: $0.category) }
        for value in known where value.original.utf8.count >= Self.minKnown {
            var remainder = NSRange(location: 0, length: ns.length)
            while remainder.length > 0 {
                let range = ns.range(of: value.original, options: .literal, range: remainder)
                if range.location == NSNotFound { break }
                if Self.standsAlone(value.category, range: range, in: ns) {
                    found.append(.init(start: range.location, end: NSMaxRange(range), category: value.category))
                }
                remainder = NSRange(location: NSMaxRange(range), length: ns.length - NSMaxRange(range))
            }
        }
        for name in machineUsers {
            var remainder = NSRange(location: 0, length: ns.length)
            while remainder.length > 0 {
                let range = ns.range(of: name, options: .literal, range: remainder)
                if range.location == NSNotFound { break }
                if Self.standsAlone(.username, range: range, in: ns) { found.append(.init(start: range.location, end: NSMaxRange(range), category: .username)) }
                remainder = NSRange(location: NSMaxRange(range), length: ns.length - NSMaxRange(range))
            }
        }
        // Nothing inside a placeholder already there.
        if text.contains("{{") {
            let shapes = Self.placeholderShape.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
            found.removeAll { span in shapes.contains { span.start < NSMaxRange($0) && span.end > $0.location } }
        }
        // This conversation's own stand-in written in a text is that text's words, not the value: it goes
        // as a stand-in of its own, so a reply that repeats it comes back as it was written.
        for (token, value) in values {
            found += PrivacyStandIn.ranges(of: token, in: ns).map { .init(start: $0.location, end: NSMaxRange($0), category: value.category) }
        }
        let spans = try merged(found, in: text)
        var output = "", cursor = 0, counts: [PrivacyCategory: Int] = [:], placeholders: Set<String> = []
        var offset = 0, at: [Int] = [], tokens: [String] = []
        for span in spans {
            output += ns.substring(with: NSRange(location: cursor, length: span.start - cursor))
            offset += span.start - cursor
            let original = ns.substring(with: NSRange(location: span.start, length: span.end - span.start))
            let token = placeholder(original, category: span.category)
            at.append(offset); tokens.append(token); offset += (token as NSString).length
            output += token; placeholders.insert(token)
            counts[values[token]!.category, default: 0] += 1
            cursor = span.end
        }
        output += ns.substring(from: cursor)
        var result = MaskedText(text: output, categories: counts, placeholders: placeholders)
        result.sha = Self.sha(output); result.at = at; result.tokens = tokens
        places[cacheKey] = place
        var kept = result
        if output == text { kept.text = ""; kept.unchanged = true }
        try remember(kept, for: cacheKey)
        return result
    }

    func rememberResponse(masked: String, restored: String, field: String? = nil, location: String) throws {
        reserveWords(in: masked)
        let text = masked as NSString
        let placeholders = Set(values.keys.filter { !PrivacyStandIn.ranges(of: $0, in: text).isEmpty })
        var categories: [PrivacyCategory: Int] = [:]
        for token in placeholders {
            categories[values[token]!.category, default: 0] += PrivacyStandIn.ranges(of: token, in: text).count
        }
        let numeric = Set(numbers.keys.filter { Self.numberOccurrences(Double(bitPattern: $0), in: masked) > 0 })
        for number in numeric {
            categories[numbers[number]!.category, default: 0] += Self.numberOccurrences(Double(bitPattern: number), in: masked)
        }
        let hint = field.flatMap(PrivacyRules.fieldCategory)
        var kept = MaskedText(text: masked == restored ? "" : masked, categories: categories, placeholders: placeholders, numbers: numeric,
                              unchanged: masked == restored)
        // Where the reply's stand-ins were put back, found again as its restorer put them back: kept across
        // a restart only when that gives the words the client got.
        var again = PrivacyTextRestorer(values: allowed, numericTokens: Set(numbers.keys.map { Self.numberText(Double(bitPattern: $0)) }))
        if let told = try? again.append(masked, final: true), told == restored {
            kept.sha = Self.sha(masked); kept.at = again.occurrences.map(\.offset); kept.tokens = again.occurrences.map(\.token)
        } else { kept.keepable = false }
        let key = digest(location + "\u{0}" + (hint?.rawValue ?? "") + "\u{0}" + restored)
        try remember(kept, for: key)
        sentCacheKeys.insert(key); places[key] = Self.place(location, field)
    }

    /// `number` masked as `mask` masks a text: by its field's kind, else by what the rules and the model's
    /// reading (`model`, else `preparation`'s) take its whole text for.
    func maskNumber(_ number: Double, field: String?, location: String, preparation: PrivacyPreparation? = nil,
                    model explicit: [PrivacySpan]? = nil) throws -> MaskedNumber {
        let cacheKey = digest(location + "\u{0}\(number.bitPattern)")
        preparation?.numberKeys.insert(cacheKey)
        if var prior = numberCache[cacheKey], sentNumberKeys.contains(cacheKey) { prior.fresh = false; return prior }
        if !restoredNumbers.isEmpty, let adopted = adoptNumber(number, location: location, key: cacheKey) { return adopted }
        numberPlaces[cacheKey] = location
        if numberCache.count >= 20_000 && numberCache[cacheKey] == nil {
            // full: what was masked and never sent goes first, as `remember` lets text go
            for key in numberCache.keys where !sentNumberKeys.contains(key) { numberCache.removeValue(forKey: key) }
        }
        if let prior = numberByOriginal[number.bitPattern] {
            let result = MaskedNumber(value: prior, category: numbers[prior.bitPattern]!.category)
            numberCache[cacheKey] = result; return result
        }
        // A number no stand-in can be made for goes as written,
        // never refused: one that is a stand-in already, or not finite.
        let unmasked = MaskedNumber(value: number, category: nil)
        guard numbers[number.bitPattern] == nil, number.isFinite else { numberCache[cacheKey] = unmasked; return unmasked }
        originalNumbers.insert(number.bitPattern)
        let text = Self.numberText(number)
        let detected = explicit ?? preparation?.finds[findsKey(text)] ?? []
        let taken = detected.filter { $0.score >= 0.6 }.compactMap { Self.modelSpan($0, in: text as NSString) }
        let whole = (PrivacyRules.spans(in: text) + taken).first { $0.start == 0 && $0.end == text.utf16.count }
        guard let category = field.flatMap(PrivacyRules.fieldCategory) ?? whole?.category else {
            let result = MaskedNumber(value: number, category: nil); numberCache[cacheKey] = result; return result
        }
        guard number.rounded() == number, abs(number) >= 10, abs(number) <= 9_000_000_000_000_000 else { numberCache[cacheKey] = unmasked; return unmasked }
        let digits = String(format: "%.0f", abs(number)).count
        let lower = UInt64(pow(10, Double(digits - 1))), upper = min(UInt64(pow(10, Double(digits))) - 1, 9_000_000_000_000_000)
        for attempt in 0..<128 {
            let hashed = digest("number\u{0}\(number.bitPattern)\u{0}\(attempt)")
            let magnitude = lower + UInt64(hashed.prefix(16), radix: 16)! % (upper - lower + 1)
            let replacement = Double(magnitude) * (number < 0 ? -1 : 1)
            if !originalNumbers.contains(replacement.bitPattern), numbers[replacement.bitPattern] == nil, unboundNumbers[replacement.bitPattern] == nil {
                numberByOriginal[number.bitPattern] = replacement
                numbers[replacement.bitPattern] = (number, category)
                let result = MaskedNumber(value: replacement, category: category); numberCache[cacheKey] = result; return result
            }
        }
        numberCache[cacheKey] = unmasked; return unmasked
    }
    static func numberText(_ number: Double) -> String {
        number.rounded() == number && abs(number) <= 9_000_000_000_000_000 ? String(format: "%.0f", number) : String(number)
    }
    private static func numberOccurrences(_ number: Double, in text: String) -> Int {
        let escaped = NSRegularExpression.escapedPattern(for: numberText(number))
        let expression = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_.])" + escaped + "(?![A-Za-z0-9_]|\\.[0-9])")
        return expression.numberOfMatches(in: text, range: NSRange(location: 0, length: text.utf16.count))
    }
    /// What `preparation` masked is now sent history: it goes as it went from now on. What of it went
    /// without the model's reading is looked up at the next request, for what the model found since.
    func commitPrepared(_ preparation: PrivacyPreparation) {
        sentCacheKeys.formUnion(preparation.textKeys); sentNumberKeys.formUnion(preparation.numberKeys)
        sentUnread.formUnion(preparation.unreadKeys)
    }
    /// What the model found in a text sent before
    /// without its reading becomes known, and is masked in new text; the text itself goes as it went.
    private func learnLate(_ model: [PrivacySpan], in text: String) {
        let ns = text as NSString
        for span in model where span.score >= 0.6 {
            guard let span = Self.modelSpan(span, in: ns), Self.valid(span, in: ns) else { continue }
            _ = placeholder(ns.substring(with: NSRange(location: span.start, length: span.end - span.start)), category: span.category)
        }
    }

    private func remember(_ value: MaskedText, for key: String) throws {
        var previousBytes = 0
        if let existing = cache[key] {
            if sentCacheKeys.contains(key) {
                guard existing.text == value.text else { throw PrivacyFailure.placeholderConflict }
                return
            }
            previousBytes = existing.text.utf8.count
        }
        if bytes - previousBytes + value.text.utf8.count > Self.mostBytes || cache.count >= 20_000 && cache[key] == nil {
            // Full: what was masked and never sent goes first, so room is made by letting go of what can go
            // instead of refusing; it is masked again if it comes back.
            for (unsent, masked) in cache where !sentCacheKeys.contains(unsent) && unsent != key {
                cache.removeValue(forKey: unsent); bytes -= masked.text.utf8.count
            }
            // Then the oldest of what was sent: the values stay, so it is masked again with the same stand-ins.
            heldKeys.removeAll { cache[$0] == nil }
            var dropped = 0
            for held in heldKeys where held != key {
                guard bytes - previousBytes + value.text.utf8.count > Self.mostBytes else { break }
                if let masked = cache.removeValue(forKey: held) { bytes -= masked.text.utf8.count }
                sentCacheKeys.remove(held); sentUnread.remove(held); dropped += 1
            }
            if dropped > 0 { heldKeys.removeAll { cache[$0] == nil } }
        }
        if cache[key] == nil, !value.text.isEmpty { heldKeys.append(key) }
        bytes += value.text.utf8.count - previousBytes; cache[key] = value
    }

    /// `masked` split at its stand-ins, each with the value it stands for.
    func reviewSegments(_ masked: String) -> [PrivacyReviewSegment] {
        let text = masked as NSString
        var found: [(range: NSRange, token: String)] = []
        for token in values.keys { found += PrivacyStandIn.ranges(of: token, in: text).map { ($0, token) } }
        var segments: [PrivacyReviewSegment] = [], cursor = 0
        for (range, token) in found.sorted(by: { $0.range.location < $1.range.location }) where range.location >= cursor {
            if range.location > cursor { segments.append(.text(text.substring(with: NSRange(location: cursor, length: range.location - cursor)))) }
            let value = values[token]!
            segments.append(.replaced(original: value.original, placeholder: token, category: value.category))
            cursor = NSMaxRange(range)
        }
        if cursor < text.length { segments.append(.text(text.substring(from: cursor))) }
        return segments
    }

    /// What the masked texts of one conversation may hold; each is one conversation's whole history at most.
    static let mostBytes = 16 * 1024 * 1024
    private static let standInShape = try! NSRegularExpression(pattern: #"\b(?:user|host|public-ip|bucket)-[0-9]+\b|\{\{[A-Z][A-Z_]*_[0-9]+\}\}"#)
    private func reserveWords(in text: String) {
        guard text.contains("-") || text.contains("{{") else { return }
        let ns = text as NSString
        for match in Self.standInShape.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            reservedWords.insert(ns.substring(with: match.range))
        }
    }

    /// The next number of `category` that no text of this conversation has said, so a stand-in is never
    /// words that went to the model as they were.
    private func placeholder(_ original: String, category: PrivacyCategory) -> String {
        let identity = digest("value\u{0}" + original)
        if let token = byValue[identity] { return token }
        var number = counters[category, default: 0], token = ""
        repeat {
            number += 1; token = PrivacyStandIn.text(for: category, number: number)
        } while values[token] != nil || unbound[token] != nil || reservedWords.contains(token)
        counters[category] = number
        // never refused for how many values the conversation holds: its replies need each one put back
        values[token] = Value(original: original, category: category); byValue[identity] = token
        bytes += original.utf8.count
        return token
    }

    static func valid(_ span: PrivacySpan, in text: NSString) -> Bool {
        guard span.start >= 0, span.end > span.start, span.end <= text.length else { return false }
        func splitsSurrogate(_ offset: Int) -> Bool {
            offset > 0 && offset < text.length && (0xD800...0xDBFF).contains(text.character(at: offset - 1)) &&
                (0xDC00...0xDFFF).contains(text.character(at: offset))
        }
        return !splitsSurrogate(span.start) && !splitsSurrogate(span.end)
    }
    /// A placeholder as a tag is written, Pool's or another masker's.
    static let placeholderShape = try! NSRegularExpression(pattern: #"\{\{[A-Z][A-Z0-9_]*_[A-Za-z0-9]+\}\}"#)

    private func merged(_ spans: [PrivacySpan], in text: String) throws -> [PrivacySpan] {
        var result: [PrivacySpan] = []
        for span in spans.sorted(by: { $0.start == $1.start ? $0.end > $1.end : $0.start < $1.start }) {
            guard Self.valid(span, in: text as NSString) else { throw PrivacyFailure.invalidDetection }
            if let last = result.last, span.start < last.end {
                let priority: [PrivacyCategory] = [.privateKey, .apiKey, .token, .password, .secret]
                let category = priority.first(where: { $0 == last.category || $0 == span.category }) ?? last.category
                result[result.count - 1] = .init(start: last.start, end: max(last.end, span.end), category: category)
            } else { result.append(span) }
        }
        return result
    }
    /// The model's labels that are masked: its date and URL labels are left out
    /// (a date in a request is nearly always a log's or a version's, a URL the agent's own), and card
    /// numbers and IP addresses are the rules'.
    static let modelCategories: Set<PrivacyCategory> = [.person, .address, .phone, .email, .account, .secret]

    /// The shortest value masked again wherever it appears: shorter ones would turn
    /// up all over ordinary text.
    static let minKnown = 8

    private static let alnum = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".utf16)
    private static let digits = Set("0123456789".utf16)
    private static func units(_ text: String) -> Set<unichar> { Set(text.utf16) }

    /// A model span is taken trimmed of the spaces the model takes in with a value (and, but for a
    /// secret, of the quotes and separators between JSON or CSV values), and left out when it is a piece cut out of a longer word or not what its kind says (`modelTakes`, the shape checks of `modelFits`).
    static func modelSpan(_ span: PrivacySpan, in text: NSString) -> PrivacySpan? {
        guard modelCategories.contains(span.category) else { return nil }
        func space(_ c: unichar) -> Bool { c == 32 || c == 9 || c == 10 || c == 13 }
        let delimiters = units("\"',;:")
        func edge(_ c: unichar) -> Bool { space(c) || span.category != .secret && delimiters.contains(c) }
        func word(_ c: unichar) -> Bool { alnum.contains(c) || c == 95 }
        var a = span.start, b = span.end
        while a < b, edge(text.character(at: a)) { a += 1 }
        while b > a, edge(text.character(at: b - 1)) { b -= 1 }
        guard a < b else { return nil }
        if a > 0 && word(text.character(at: a - 1)) && word(text.character(at: a)) { return nil }
        if b < text.length && word(text.character(at: b - 1)) && word(text.character(at: b)) { return nil }
        let value = text.substring(with: NSRange(location: a, length: b - a))
        let fits: Bool
        switch span.category {
        case .secret: fits = PrivacyRules.modelSecret(value, at: a, in: text)
        case .person: fits = value.count >= 2 && value.contains(where: \.isLetter) && !snakeWord(value)
        case .email: fits = value.contains("@")
        case .phone: fits = numberLike(value) && value.utf16.filter(digits.contains).count >= 7
        case .address: fits = value.contains(where: \.isLetter)
        case .account: fits = PrivacyRules.modelAccount(value, at: a, in: text)
        default: fits = true
        }
        return fits ? PrivacySpan(start: a, end: b, category: span.category, score: span.score) : nil
    }

    /// ASCII letters and digits joined by underscores (sequential_cutoff): a program's word, not a name.
    private static func snakeWord(_ value: String) -> Bool {
        value.contains("_") && value.contains { $0 != "_" } && value.utf16.allSatisfy { alnum.contains($0) || $0 == 95 }
    }

    /// Written as a number is: digits, and the spaces, dashes, dots, brackets and + that group them, with
    /// four letters at most.
    private static func numberLike(_ value: String) -> Bool {
        guard !value.contains("..") else { return false }
        let grouping = units(" -.()+/")
        var letters = 0, count = 0
        for scalar in value.unicodeScalars {
            count += 1
            if scalar.isASCII, digits.contains(UInt16(scalar.value)) || grouping.contains(UInt16(scalar.value)) { continue }
            guard scalar.properties.isAlphabetic else { return false }
            letters += 1
        }
        return letters <= 4 && value.utf16.filter(digits.contains).count * 2 > count
    }

    /// The known value at `range` is the value itself, not a piece of a longer one.
    static func standsAlone(_ category: PrivacyCategory, range: NSRange, in text: NSString) -> Bool {
        let a = range.location, b = NSMaxRange(range)
        let before: unichar? = a > 0 ? text.character(at: a - 1) : nil
        let after: unichar? = b < text.length ? text.character(at: b) : nil
        let next: unichar? = b + 1 < text.length ? text.character(at: b + 1) : nil
        func among(_ c: unichar?, _ set: Set<unichar>) -> Bool { c.map(set.contains) ?? false }
        switch category {
        case .phone, .bankCard, .identityCard, .iban, .ssn, .passport, .serial:
            return !among(before, alnum) && !among(after, alnum)
        case .ip, .mac:
            // not a piece of a longer address or a version: 1.2.3.45, 1.2.3.4.5
            if among(before, alnum.union(units(".:"))) || among(after, alnum.union(units(":"))) { return false }
            return after != 46 || !among(next, digits)
        case .email:
            if among(before, alnum.union(units("._%+-"))) || among(after, alnum.union(units("_%+"))) { return false }
            // a full stop may end the sentence after it
            return !among(after, units(".-")) || !among(next, alnum)
        default:
            let first = text.character(at: a), last = text.character(at: b - 1)
            return !(among(before, alnum) && alnum.contains(first)) && !(among(after, alnum) && alnum.contains(last))
        }
    }
}

/// Puts back the stand-ins a request carried, as they come out of a stream: only those, so anything else
/// is the model's own words, and a piece of one is held until the next fragment says.
struct PrivacyTextRestorer {
    private var values: [String: String]
    private var numericTokens: Set<String>
    private var tokens: [String] = []
    private var prefixes: Set<String> = []
    private var longest = 0
    private var pending = ""
    private var preceding: Character?
    private(set) var count = 0
    /// Where in what came in each stand-in was put back (UTF-16 offsets), and which.
    private(set) var occurrences: [(offset: Int, token: String)] = []
    private var consumed = 0
    init(values: [String: String], numericTokens: Set<String> = []) {
        self.values = values; self.numericTokens = numericTokens; refresh()
    }
    mutating func allow(_ values: [String: String]) { self.values.merge(values) { existing, _ in existing }; refresh() }
    mutating func reserveNumbers(_ values: Set<String>) { numericTokens.formUnion(values); refresh() }

    private mutating func refresh() {
        let all = Set(values.keys).union(numericTokens)
        guard all.count != tokens.count else { return }
        tokens = Array(all); longest = tokens.map(\.count).max() ?? 0
        prefixes = Set(tokens.flatMap { token in (1...max(token.count, 1)).map { String(token.prefix($0)) } })
    }

    /// The first place in `pending` a stand-in stands.
    private func nextToken() -> (token: String, range: Range<String.Index>)? {
        var first: (token: String, range: Range<String.Index>)?
        for token in tokens {
            var search = pending.startIndex..<(first?.range.lowerBound ?? pending.endIndex)
            while let range = pending.range(of: token, range: search) {
                let before = range.lowerBound == pending.startIndex ? preceding : pending[pending.index(before: range.lowerBound)]
                if stands(token, before: before, at: range.upperBound) { first = (token, range); break }
                search = range.upperBound..<search.upperBound
            }
        }
        return first
    }

    private func stands(_ token: String, before: Character?, at end: String.Index) -> Bool {
        if token.hasPrefix("{{") { return true }
        let after = end == pending.endIndex ? nil : pending[end]
        if PrivacyStandIn.bare(token) {
            return PrivacyStandIn.standsAsName(before: before, after: after)
        }
        let afterDecimal = after == "." && pending.index(after: end) < pending.endIndex && pending[pending.index(after: end)].isNumber
        return !numberCharacter(before) && !(after != "." ? numberCharacter(after) : afterDecimal)
    }

    mutating func append(_ text: String, final: Bool = false) throws -> String {
        pending += text
        var output = ""
        while let found = nextToken() {
            let head = pending[..<found.range.lowerBound]
            output += head
            if let last = head.last { preceding = last }
            consumed += head.utf16.count
            // what comes next may make it a longer word
            if found.range.upperBound == pending.endIndex && !final && !found.token.hasPrefix("{{") {
                pending = String(pending[found.range.lowerBound...]); return output
            }
            // a stand-in this request did not send is the model's own words, passed on as it is
            if let original = values[found.token] {
                output += original; count += 1; occurrences.append((consumed, found.token))
            } else { output += found.token }
            consumed += found.token.utf16.count
            preceding = found.token.last
            pending = String(pending[found.range.upperBound...])
        }
        if final { output += pending; consumed += pending.utf16.count; preceding = pending.last ?? preceding; pending = ""; return output }
        var held = 0
        for size in stride(from: min(longest, pending.count), to: 0, by: -1) where prefixes.contains(String(pending.suffix(size))) {
            held = size; break
        }
        output += pending.dropLast(held)
        consumed += pending.dropLast(held).utf16.count
        preceding = pending.dropLast(held).last ?? preceding
        pending = String(pending.suffix(held))
        return output
    }

    private func numberCharacter(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isNumber || character.isLetter || character == "." || character == "_"
    }
}
