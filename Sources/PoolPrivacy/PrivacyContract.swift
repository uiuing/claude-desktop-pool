import Foundation

public enum PrivacyCategory: String, CaseIterable, Codable, Sendable {
    case privateKey = "PRIVATE_KEY", apiKey = "API_KEY", token = "TOKEN", password = "PASSWORD", secret = "SECRET"
    case email = "EMAIL", identityCard = "ID_CARD", phone = "PHONE", bankCard = "BANK_CARD"
    case ssn = "SSN", passport = "PASSPORT", iban = "IBAN", birthday = "BIRTHDAY", mac = "MAC", serial = "SERIAL"
    case username = "USERNAME", hostname = "HOSTNAME", ip = "IP", bucket = "BUCKET"
    case person = "PERSON", address = "ADDRESS", account = "ACCOUNT", date = "DATE", url = "URL"
}

/// Offsets use UTF-16 code units in the exact supplied text, never token indices.
public struct PrivacySpan: Equatable, Sendable {
    public let start: Int
    public let end: Int
    public let category: PrivacyCategory
    public let score: Double
    public init(start: Int, end: Int, category: PrivacyCategory, score: Double = 1) {
        self.start = start; self.end = end; self.category = category; self.score = score
    }
}

public protocol PrivacyEntityDetector: Sendable {
    /// A detector must throw when unavailable; returning no spans means it inspected the whole text.
    func detect(in text: String) async throws -> [PrivacySpan]
}

public enum PrivacyFailure: Error, Equatable, Sendable, LocalizedError {
    case notReady, modelFailed, installationFailed, invalidDetection, inputTooLarge, placeholderConflict, capacityReached, busy
    public var errorDescription: String? {
        switch self {
        case .notReady: return "The local redaction model is not ready. Rules alone redact requests until it is."
        case .modelFailed: return "The local redaction model stopped working. Rules alone redact requests until it recovers."
        case .installationFailed: return "The local model could not be installed. Try again."
        case .invalidDetection: return "The local redaction model returned an invalid result. Rules alone redact requests until it recovers."
        case .inputTooLarge: return "This request is too large for local redaction. Nothing was sent."
        case .placeholderConflict: return "This conversation contains a conflicting redaction placeholder. Continue in a new conversation."
        case .capacityReached: return "Local redaction memory is full. Finish a conversation before starting another."
        case .busy: return "Local redaction is busy. Try again shortly."
        }
    }
}

public struct PrivacyStatistics: Equatable, Sendable {
    public var protectedRequests: Int = 0
    public var maskedOccurrences: Int = 0
    public var restoredOccurrences: Int = 0
    public var categories: [PrivacyCategory: Int] = [:]
    public init() {}
}

public enum PrivacyUpdate: Sendable {
    case processing(active: Int)
    case requestState(conversationID: String, active: Bool)
    case protected(PrivacyStatistics)
    /// A request refused: nothing of it was sent.
    case blocked(PrivacyFailure)
    /// The local model stopped answering (its failure) or answers again (nil). Requests are not held for
    /// it: meanwhile the rules and known values redact them alone.
    case model(PrivacyFailure?)
    /// A request that had something replaced, as received and as sent.
    case reviewed(PrivacyReview)
    /// Values put back into the reply to the request `reviewID` so far.
    case restored(reviewID: UUID, count: Int)
}

/// One protected request as it was received and as it was sent, for the person to look over.
/// It lives in memory only: it is never written to disk, logs or diagnostics, and it is gone
/// when Claude Pool quits.
public struct PrivacyReview: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let at: Date
    /// The parts of this request that were new in it and had something replaced.
    public let fields: [PrivacyReviewField]
    /// Fields left out because the review reached `mostBytes`.
    public let omitted: Int
    /// What it holds, for `kept`.
    public let bytes: Int
    public let categories: [PrivacyCategory: Int]
    /// Values put back into the reply.
    public var restored: Int
    public init(id: UUID, at: Date, fields: [PrivacyReviewField], categories: [PrivacyCategory: Int], restored: Int = 0) {
        var kept: [PrivacyReviewField] = [], total = 0
        for field in fields.prefix(Self.mostFields) {
            if total + field.bytes > Self.mostBytes, !kept.isEmpty { break }
            kept.append(field); total += field.bytes
        }
        self.id = id; self.at = at; self.fields = kept; omitted = fields.count - kept.count; bytes = total
        self.categories = categories; self.restored = restored
    }
    public static let mostFields = 40
    public static let mostBytes = 256 * 1024
    public static let mostKept = 40
    public static let mostKeptBytes = 4 * 1024 * 1024
    /// `reviews`, newest first, cut to what is held in memory at once: the sheet is opened now and then,
    /// and what it shows should not grow with a long conversation.
    public static func kept(_ reviews: [PrivacyReview]) -> [PrivacyReview] {
        var total = 0
        var result: [PrivacyReview] = []
        for review in reviews.prefix(mostKept) {
            if total + review.bytes > mostKeptBytes, !result.isEmpty { break }
            result.append(review); total += review.bytes
        }
        return result
    }
    public var replacedCount: Int { fields.reduce(0) { $0 + $1.replacedCount } }
}

public struct PrivacyReviewField: Equatable, Sendable {
    /// Where in the request: "system/text", "messages/3/content/0/text", "tools/read/description".
    public let location: String
    public let segments: [PrivacyReviewSegment]
    public let bytes: Int
    /// Long text keeps only the context around each replacement, so a large file read in a
    /// tool result is not held whole.
    public init(location: String, segments: [PrivacyReviewSegment]) {
        self.location = location; self.segments = Self.folded(segments)
        bytes = self.segments.reduce(location.utf8.count) { total, segment in
            switch segment {
            case .text(let text): return total + text.utf8.count
            case .replaced(let original, let placeholder, _): return total + original.utf8.count + placeholder.utf8.count
            }
        }
    }
    public var replacedCount: Int { segments.filter { if case .replaced = $0 { return true }; return false }.count }

    public static let context = 240
    public static let mostSegments = 200
    public static let mostOriginal = 600
    static func folded(_ segments: [PrivacyReviewSegment]) -> [PrivacyReviewSegment] {
        let kept = Array(segments.prefix(mostSegments))
        return kept.enumerated().map { index, segment in
            switch segment {
            case .text(let text):
                let first = index == 0, last = index == kept.count - 1
                if first && last { return segment }
                if first, text.count > context { return .text("…" + text.suffix(context)) }
                if last, text.count > context { return .text(text.prefix(context) + "…") }
                if !first && !last, text.count > 2 * context + 3 { return .text(text.prefix(context) + " … " + text.suffix(context)) }
                return segment
            case .replaced(let original, let placeholder, let category):
                return original.count > mostOriginal ? .replaced(original: original.prefix(mostOriginal) + "…", placeholder: placeholder, category: category) : segment
            }
        }
    }
}

public enum PrivacyReviewSegment: Equatable, Sendable {
    case text(String)
    /// `original` as received, `placeholder` as sent.
    case replaced(original: String, placeholder: String, category: PrivacyCategory)
}

public struct PrivacyPreview: Equatable, Sendable {
    public let maskedText: String
    public let maskedOccurrences: Int
    public let categories: [PrivacyCategory: Int]
    public init(maskedText: String, maskedOccurrences: Int, categories: [PrivacyCategory: Int]) {
        self.maskedText = maskedText; self.maskedOccurrences = maskedOccurrences; self.categories = categories
    }
}
