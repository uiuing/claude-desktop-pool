import Foundation
import XCTest
@testable import PoolPrivacy

final class PrivacyRulesTests: XCTestCase {
    func testEveryRuleCategoryIsEnabledWithoutSettings() throws {
        let samples: [(PrivacyCategory, String, String)] = [
            (.privateKey, "-----BEGIN PRIVATE KEY-----\nsynthetic\n-----END PRIVATE KEY-----", "synthetic"),
            (.apiKey, "sk-ant-" + String(repeating: "a", count: 40), "sk-ant-"),
            (.token, "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJmaXh0dXJlIn0.c3ludGhldGljc2lnbmF0dXJl", "eyJ"),
            (.password, "https://someone:fixture-password@host.invalid", "fixture-password"),
            (.secret, "client_secret = 'fixture-secret-123'", "fixture-secret-123"),
            (.email, "Contact synthetic.user@gmail.com", "synthetic.user@gmail.com"),
            (.identityCard, "Card: " + syntheticID(), syntheticID()),
            (.phone, "Call +1 (202) 555-0186", "+1 (202) 555-0186"),
            (.bankCard, "Card 4111 1111 1111 1111", "4111 1111 1111 1111"),
            (.ssn, "SSN 321-54-6789", "321-54-6789"),
            (.passport, "Passport: E12345678", "E12345678"),
            (.iban, "IBAN: GB82 WEST 1234 5698 7654 32", "GB82 WEST 1234 5698 7654 32"),
            (.birthday, "DOB: 1992-03-14", "1992-03-14"),
            (.mac, "Device 3c:22:fb:11:a0:5e", "3c:22:fb:11:a0:5e"),
            (.serial, "Serial number: FIXTURE-93742", "FIXTURE-93742"),
            (.username, "/Users/synthetic-user/Documents/report.txt", "synthetic-user"),
            (.hostname, "ssh testuser@synthetic-host.internal", "synthetic-host.internal"),
            (.ip, "Host 93.184.216.34", "93.184.216.34"),
            (.bucket, "s3://private-fixture-bucket/report", "private-fixture-bucket")
        ]
        for (category, text, value) in samples {
            let spans = PrivacyRules.spans(in: text).filter { $0.category == category }
            XCTAssertTrue(spans.contains { (text as NSString).substring(with: NSRange(location: $0.start, length: $0.end - $0.start)).contains(value) }, category.rawValue)
        }
    }

    func testContextSensitiveValuesAndInternationalFormats() {
        for text in ["phone: 090-1726-4583", "+44 20 7946 0958", "13817264583", "(415) 555-2671"] {
            XCTAssertTrue(PrivacyRules.spans(in: text).contains { $0.category == .phone })
        }
        for text in ["93.184.216.34", "2606:2800:220:1:248:1893:25c8:1946", "47.96.0.1"] {
            XCTAssertTrue(PrivacyRules.spans(in: text).contains { $0.category == .ip })
        }
        XCTAssertEqual(PrivacyRules.fieldCategory("access_token"), .secret)
        XCTAssertEqual(PrivacyRules.fieldCategory("password"), .password)
        XCTAssertNil(PrivacyRules.fieldCategory("type"))
        XCTAssertFalse(PrivacyRules.spans(in: "999.999.999.999").contains { $0.category == .ip })
        XCTAssertFalse(PrivacyRules.spans(in: "4111111111111112").contains { $0.category == .bankCard })
    }

    func testNamedCredentialsAndQuotedValuesAreWholeSecrets() async throws {
        let context = PrivacyConversation(), detector = FixtureDetector()
        for field in ["access_key", "client_key", "DB_PASS", "SERVICE_X_KEY", "pin_code"] {
            let result = try await context.mask("fixture credential with spaces", field: field, location: field, detector: detector)
            XCTAssertFalse(result.text.contains("fixture"))
            XCTAssertEqual(result.count, 1)
        }
        for source in ["password=\"fixture password with spaces\"", "client_secret='fixture secret with spaces'", "DB_PASS='fixture password with spaces'", "SERVICE_X_KEY=\"fixture key with spaces\"", "DB_PASS=fixture-password", "pin_code=1234"] {
            let result = try await context.mask(source, location: source, detector: detector)
            XCTAssertFalse(result.text.contains("with spaces"))
            XCTAssertFalse(result.text.contains("fixture-password"))
            XCTAssertFalse(result.text.contains("1234"))
        }
        XCTAssertNil(PrivacyRules.fieldCategory("max_tokens"))
        XCTAssertNil(PrivacyRules.fieldCategory("token_count"))
    }

    func testUnicodeSpansModelCategoriesAndStableKnownValues() async throws {
        let context = PrivacyConversation()
        let detector = FixtureDetector(words: ["\u{5f20}\u{6653}\u{660e}": .person, "42 Fixture Road": .address, "ACCT-7491": .account])
        let source = "\u{1f680} cafe\u{301} \u{5f20}\u{6653}\u{660e} lives at 42 Fixture Road. Account ACCT-7491"
        let masked = try await context.mask(source, detector: detector)
        XCTAssertFalse(masked.text.contains("\u{5f20}\u{6653}\u{660e}"))
        XCTAssertEqual(Set(masked.categories.keys), [.person, .address, .account])
        let again = try await context.mask(source, detector: detector)
        XCTAssertEqual(masked.text, again.text)
        let known = try await context.mask("Remember ACCT-7491", detector: FixtureDetector())
        XCTAssertTrue(known.text.contains(try XCTUnwrap(masked.placeholders.first { $0.contains("ACCOUNT") })))
        var restorer = PrivacyTextRestorer(values: context.values.mapValues(\.original))
        var restored = ""
        for scalar in masked.text.unicodeScalars { restored += try restorer.append(String(scalar)) }
        restored += try restorer.append("", final: true)
        XCTAssertEqual(restored, source)
        XCTAssertEqual(Data(restored.utf8), Data(source.utf8))
        XCTAssertEqual(restorer.count, 3)
    }

    func testModelSpansAndKnownValues() async throws {
        // The model's date and URL labels are not masked.
        let dated = PrivacyConversation()
        let dates = FixtureDetector(words: ["2024-01-01": .date, "https://example.org/a": .url, "-": .date])
        let release = "Released 2024-01-01 - see https://example.org/a"
        let kept = try await dated.mask(release, detector: dates)
        XCTAssertEqual(kept.text, release); XCTAssertEqual(kept.count, 0)

        // A short value the model took is masked where it was found, and goes nowhere else.
        let context = PrivacyConversation()
        let dash = try await context.mask("- first item", detector: FixtureDetector(words: ["-": .account]))
        XCTAssertEqual(dash.count, 1)
        let later = "- second item, run --verbose, a-b"
        let next = try await context.mask(later, detector: FixtureDetector())
        XCTAssertEqual(next.text, later)

        // Spaces, quotes and separators the model took in stay as written; a piece of a word or a value
        // that is not what its kind says is left.
        let json = #"{"name":"Avery Quinn","x":1}"#
        let trimmed = try await context.mask(json, detector: FixtureDetector(words: [#""Avery Quinn","#: .person]))
        XCTAssertTrue(trimmed.text.hasPrefix(#"{"name":"{{PERSON_"#), trimmed.text)
        XCTAssertTrue(trimmed.text.hasSuffix(#"}}","x":1}"#), trimmed.text)
        for (text, word, category) in [("Averyquinn", "quinn", PrivacyCategory.person), ("Code 12-34", "12-34", .phone),
                                       ("Room 42", "42", .address), ("short abc123", "abc123", .secret)] {
            let result = try await PrivacyConversation().mask(text, detector: FixtureDetector(words: [word: category]))
            XCTAssertEqual(result.text, text, "\(category) \(word)")
        }

        // A known value is masked again only where it stands alone.
        let names = PrivacyConversation()
        _ = try await names.mask("Ask Avery Quinn", detector: FixtureDetector(words: ["Avery Quinn": .person]))
        let alone = try await names.mask("Thanks, Avery Quinn.", detector: FixtureDetector())
        XCTAssertFalse(alone.text.contains("Avery Quinn"))
        let inside = "See Avery Quinnley"
        let piece = try await names.mask(inside, detector: FixtureDetector())
        XCTAssertEqual(piece.text, inside)
    }

    func testRestorationCannotResolveOtherScopesOrSpoofedPlaceholders() async throws {
        let first = PrivacyConversation(), second = PrivacyConversation(), detector = FixtureDetector()
        let value = "synthetic.user@gmail.com"
        let a = try await first.mask(value, detector: detector)
        // Numbers are each conversation's own: the same stand-in elsewhere is that conversation's value, never this one's.
        let other = "Other Fixture <other.fixture@gmail.com>"
        _ = try await second.mask(other, detector: detector)
        var cross = PrivacyTextRestorer(values: second.values.mapValues(\.original))
        XCTAssertFalse(try cross.append(a.text, final: true).contains(value))
        // Nothing inside a placeholder already there is masked, and this conversation's own stand-in in a
        // text is the text's words: it goes as another, and comes back as written.
        let spoof = try await first.mask("See " + a.text + " in the source.", detector: detector)
        XCTAssertNotEqual(spoof.text, "See " + a.text + " in the source.")
        var written = PrivacyTextRestorer(values: first.values.mapValues(\.original))
        XCTAssertEqual(try written.append(spoof.text, final: true), "See " + a.text + " in the source.")
        var malformed = PrivacyTextRestorer(values: first.values.mapValues(\.original))
        XCTAssertEqual(try malformed.append(String(a.text.dropLast()), final: true), String(a.text.dropLast()))
    }

    func testEveryPlaceholderSplitAndOrdinaryBracesRestoreExactly() async throws {
        let context = PrivacyConversation()
        let masked = try await context.mask("synthetic.user@gmail.com", detector: FixtureDetector())
        for split in 0...masked.text.count {
            var restorer = PrivacyTextRestorer(values: context.values.mapValues(\.original))
            let first = try restorer.append(String(masked.text.prefix(split)))
            let second = try restorer.append(String(masked.text.dropFirst(split)), final: true)
            XCTAssertEqual(first + second, "synthetic.user@gmail.com")
        }
        var ordinary = PrivacyTextRestorer(values: ["{{EMAIL_1}}": "x"])
        XCTAssertEqual(try ordinary.append("{ \u{1f469}\u{200d}\u{1f4bb} {{"), "{ \u{1f469}\u{200d}\u{1f4bb} ")
        XCTAssertEqual(try ordinary.append("Code}}", final: true), "{{Code}}")
    }

    func testNumericStandinsRespectChunkAndNumberBoundaries() throws {
        let standin = "987654321", original = "123456789"
        for split in 0...standin.count {
            var restorer = PrivacyTextRestorer(values: [standin: original])
            let a = try restorer.append("Account " + String(standin.prefix(split)))
            let b = try restorer.append(String(standin.dropFirst(split)) + ".", final: true)
            XCTAssertEqual(a + b, "Account " + original + ".")
        }
        var longer = PrivacyTextRestorer(values: [standin: original])
        let a = try longer.append("11987")
        let b = try longer.append("65432188", final: true)
        XCTAssertEqual(a + b, "1198765432188")
        // a stand-in this request did not send is put back as nothing: the model's words as written
        var unknown = PrivacyTextRestorer(values: [:], numericTokens: [standin])
        XCTAssertEqual(try unknown.append(standin, final: true), standin)
    }

    private func syntheticID() -> String {
        let prefix = "11010520010314001", weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
        let sum = zip(prefix, weights).reduce(0) { $0 + ($1.0.wholeNumberValue ?? 0) * $1.1 }
        return prefix + String(Array("10X98765432")[sum % 11])
    }
}

actor FixtureDetector: PrivacyEntityDetector {
    var words: [String: PrivacyCategory]
    var failure: PrivacyFailure?
    var invalid = false
    var delay: UInt64 = 0
    var inspected: [String: Int] = [:]
    init(words: [String: PrivacyCategory] = [:]) { self.words = words }
    func configure(failure: PrivacyFailure? = nil, invalid: Bool = false, delay: UInt64 = 0) {
        self.failure = failure; self.invalid = invalid; self.delay = delay
    }
    func detect(in text: String) async throws -> [PrivacySpan] {
        inspected[text, default: 0] += 1
        if let failure { throw failure }
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if invalid && !text.isEmpty { return [.init(start: -1, end: 2, category: .person)] }
        // Every occurrence: the bridge's reader joins several texts into one chunk.
        let ns = text as NSString
        return words.flatMap { word, category in
            var spans: [PrivacySpan] = [], rest = NSRange(location: 0, length: ns.length)
            while rest.length > 0 {
                let range = ns.range(of: word, range: rest)
                guard range.location != NSNotFound else { break }
                spans.append(PrivacySpan(start: range.location, end: NSMaxRange(range), category: category, score: 0.95))
                rest = NSRange(location: NSMaxRange(range), length: ns.length - NSMaxRange(range))
            }
            return spans
        }
    }
}
