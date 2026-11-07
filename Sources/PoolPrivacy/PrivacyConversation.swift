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
    private let key = SymmetricKey(size: .bits256)
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
    /// The content-free tag of the conversation this context serves: its client session's, or for a
    /// fork or a new client session of a conversation, the one it was forked from.
    let conversationTag: String?
    /// The id the pool sees for this context. It carries `conversationTag` after "@", so the pool
    /// can tell a conversation's side requests and forks from other conversations.
    let backendID: String
    init(session: String? = nil, conversationTag: String? = nil) {
        self.conversationTag = conversationTag ?? session.map { Diagnostics.tag($0) }
        backendID = "privacy:" + UUID().uuidString + (self.conversationTag.map { "@" + $0 } ?? "")
    }

    func digest(_ text: String) -> String {
        HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: key).map { String(format: "%02x", $0) }.joined()
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
        guard cache[key] != nil, sentCacheKeys.contains(key) else { return .read }
        return sentUnread.contains(key) ? .lookUp : .none
    }
    /// The text of `number` for the model to read, when masking it afresh asks the model.
    func readingNumber(_ number: Double, location: String) -> String? {
        let key = digest(location + "\u{0}\(number.bitPattern)")
        if numberCache[key] != nil, sentNumberKeys.contains(key) { return nil }
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
        for span in spans {
            output += ns.substring(with: NSRange(location: cursor, length: span.start - cursor))
            let original = ns.substring(with: NSRange(location: span.start, length: span.end - span.start))
            let token = placeholder(original, category: span.category)
            output += token; placeholders.insert(token)
            counts[values[token]!.category, default: 0] += 1
            cursor = span.end
        }
        output += ns.substring(from: cursor)
        let result = MaskedText(text: output, categories: counts, placeholders: placeholders)
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
        try remember(MaskedText(text: masked == restored ? "" : masked, categories: categories, placeholders: placeholders, numbers: numeric,
                                unchanged: masked == restored),
                     for: digest(location + "\u{0}" + (hint?.rawValue ?? "") + "\u{0}" + restored))
        sentCacheKeys.insert(digest(location + "\u{0}" + (hint?.rawValue ?? "") + "\u{0}" + restored))
    }

    /// `number` masked as `mask` masks a text: by its field's kind, else by what the rules and the model's
    /// reading (`model`, else `preparation`'s) take its whole text for.
    func maskNumber(_ number: Double, field: String?, location: String, preparation: PrivacyPreparation? = nil,
                    model explicit: [PrivacySpan]? = nil) throws -> MaskedNumber {
        let cacheKey = digest(location + "\u{0}\(number.bitPattern)")
        preparation?.numberKeys.insert(cacheKey)
        if var prior = numberCache[cacheKey], sentNumberKeys.contains(cacheKey) { prior.fresh = false; return prior }
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
            if !originalNumbers.contains(replacement.bitPattern), numbers[replacement.bitPattern] == nil {
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
        } while values[token] != nil || reservedWords.contains(token)
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
            return !PrivacyStandIn.wordCharacter(before) && before != "." && !PrivacyStandIn.wordCharacter(after)
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
            // what comes next may make it a longer word
            if found.range.upperBound == pending.endIndex && !final && !found.token.hasPrefix("{{") {
                pending = String(pending[found.range.lowerBound...]); return output
            }
            // a stand-in this request did not send is the model's own words, passed on as it is
            if let original = values[found.token] { output += original; count += 1 } else { output += found.token }
            preceding = found.token.last
            pending = String(pending[found.range.upperBound...])
        }
        if final { output += pending; preceding = pending.last ?? preceding; pending = ""; return output }
        var held = 0
        for size in stride(from: min(longest, pending.count), to: 0, by: -1) where prefixes.contains(String(pending.suffix(size))) {
            held = size; break
        }
        output += pending.dropLast(held)
        preceding = pending.dropLast(held).last ?? preceding
        pending = String(pending.suffix(held))
        return output
    }

    private func numberCharacter(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isNumber || character.isLetter || character == "." || character == "_"
    }
}
