import XCTest
import PoolCore
@testable import PoolPrivacy

final class PrivacyStandInTests: XCTestCase {
    /// Masked with the rules and known values; the model finds nothing (its own cases pass a detector).
    private func mask(_ text: String, in context: PrivacyConversation = PrivacyConversation()) throws -> String {
        try context.mask(text, model: []).text
    }

    func testStandInsAreShortAndKeepTheShapeOfWhatTheModelActsOn() async throws {
        let context = PrivacyConversation()
        XCTAssertEqual(try mask("/Users/quinnfixture/Documents/a.txt", in: context), "/Users/user-1/Documents/a.txt")
        XCTAssertEqual(try mask("ssh 93.184.216.34", in: context), "ssh public-ip-1")
        XCTAssertEqual(try mask("s3://quinn-data-7/a", in: context), "s3://bucket-1/a")
        XCTAssertEqual(try mask("mail quinn.fixture@gmail.com", in: context), "mail {{EMAIL_1}}")
        XCTAssertEqual(try mask("key sk-ant-" + String(repeating: "a", count: 40), in: context), "key {{API_KEY_1}}")
        // the same value is the same stand-in, the next one the next number
        XCTAssertEqual(try mask("again /Users/quinnfixture and /Users/averyfixture", in: context), "again /Users/user-1 and /Users/user-2")
    }

    func testAWordThatLooksLikeAStandInIsNeverTakenForOne() async throws {
        let context = PrivacyConversation()
        // said before any value: the number is skipped
        XCTAssertEqual(try mask("run as user-1 please", in: context), "run as user-1 please")
        XCTAssertEqual(try mask("/Users/quinnfixture/a", in: context), "/Users/user-2/a")
        // said after: it goes as a stand-in of its own and comes back as written
        let later = "compare user-2 with /Users/quinnfixture"
        let masked = try mask(later, in: context)
        XCTAssertFalse(masked.contains("user-2 with"))
        var restorer = PrivacyTextRestorer(values: context.values.mapValues(\.original))
        XCTAssertEqual(try restorer.append(masked, final: true), later)
    }

    func testBareStandInsAreRestoredOnlyAsWholeWordsAcrossAnySplit() throws {
        let values = ["user-1": "quinn", "user-10": "avery", "public-ip-1": "93.184.216.34"]
        let text = "/Users/user-1/a user-10 super-user-1 my.user-1 user-1的 ssh public-ip-1."
        let want = "/Users/quinn/a avery super-user-1 my.user-1 quinn的 ssh 93.184.216.34."
        for split in 0...text.count {
            var restorer = PrivacyTextRestorer(values: values)
            let head = try restorer.append(String(text.prefix(split)))
            XCTAssertEqual(head + (try restorer.append(String(text.dropFirst(split)), final: true)), want, "\(split)")
        }
    }

    func testCodeAndOrdinaryWordsAreLeftAsTheyAre() async throws {
        for text in ["let token = UUID()", "func f(tokens: [Tok])", "password = \"PASSWORD\"", "privateKey = \"PRIVATE_KEY\"",
                     "passport = \"PASSPORT\"", "serial = \"SERIAL\"", "=== passport\ninternal/redact", "\"passportnumber\"", "[:] and ::",
                     "max_tokens: 4096", "total_tokens = 12345", "let password: String", "login(password=pw)", "password = newValue",
                     "tokenizer_path = model2/tokenizer.json", "token: 0.15.0-rc1", "secret = process.env.API2_SECRET",
                     "cookie = getCookie(name)", "Authorization: Bearer $TOKEN", "192.168.1.20 and 127.0.0.1 and 10.0.0.1", "version 1.2.3.4",
                     "密码错误", "密码长度不够8位", "密钥为 2048 位", "/Users/Shared/a", "/home/linuxbrew/a", "/Users/$USER/a",
                     "git@github.com:a/b.git", "icon@2x.png", "user: root", "User: done"] {
            XCTAssertEqual(try mask(text), text)
        }
    }

    func testRealSecretsAreStillFound() async throws {
        for (text, value) in [("password = \"correcthorse\"", "correcthorse"), ("password=hunter", "hunter"), ("PASSWORD=hunter", "hunter"),
                              ("password: hunter\n", "hunter"), ("pin: 1234", "1234"), ("API_SECRET=abc123def456", "abc123def456"),
                              ("token = \"AbcdEfghIjklMnopQrstUvwx\"", "AbcdEfghIjklMnopQrstUvwx"),
                              (#"{\"password\":\"hunter22\"}"#, "hunter22"),
                              ("curl -H \"Authorization: Bearer abc123def456\" x", "abc123def456"), ("Cookie: session=abc123def", "session=abc123def"),
                              ("密码：hunter", "hunter"), ("密码是 hunter", "hunter"), ("密码 abc123", "abc123"), ("Passport: E12345678", "E12345678")] {
            XCTAssertFalse(try mask(text).contains(value), text)
        }
    }

    func testExamplePhonesAndPiecesOfLongerRunsAreLeft() throws {
        for text in ["mobile: 13800138000", "手机号 13800000000", "phone=13888888888", "tel: 12345678901",
                     "id 3ccb5f_13917264583", "build-13917264583-x"] {
            XCTAssertEqual(try mask(text), text)
        }
        for text in ["手机号 13917264583", "登录手机号：15820467391", "call me at +86 13917264583"] {
            XCTAssertNotEqual(try mask(text), text, text)
        }
    }

    func testFieldsAreMaskedByWhatTheyHold() throws {
        XCTAssertEqual(try PrivacyConversation().mask("${API_TOKEN}", field: "token", model: []).text, "${API_TOKEN}")
        XCTAssertEqual(try PrivacyConversation().mask("none", field: "email", model: []).text, "none")
        XCTAssertEqual(try PrivacyConversation().mask("abc123def456", field: "token", model: []).text, "{{SECRET_1}}")
    }

    func testTheModelCannotCallAWordOrANameASecretUnlessItIsGivenToOne() async throws {
        for (text, word, kept) in [("uses jsonwebtoken here", "jsonwebtoken", true), ("uses myVariableName here", "myVariableName", true),
                                   ("password=jsonwebtoken", "jsonwebtoken", false), ("uses Xk29dLq0pZ here", "Xk29dLq0pZ", false)] {
            let result = try await PrivacyConversation().mask(text, detector: StandInDetector(words: [word: .secret]))
            XCTAssertEqual(result.text == text, kept, text)
        }
    }

    func testAFalseFindDoesNotSpreadThroughTheConversation() async throws {
        let context = PrivacyConversation()
        let text = "=== passport\ninternal/redact/json.go\ninternal/pii/guard.go"
        XCTAssertEqual(try mask(text, in: context), text)
        XCTAssertEqual(try mask("see internal/masking", in: context), "see internal/masking")
    }

    func testReviewsAreHeldToABudget() {
        let long = String(repeating: "a", count: 3_000)
        func field() -> PrivacyReviewField {
            let parts: [PrivacyReviewSegment] = (0..<1_000).flatMap { [.text("x"), .replaced(original: long, placeholder: "{{SECRET_\($0)}}", category: .secret)] }
            return PrivacyReviewField(location: "messages/0/content/0/text", segments: parts)
        }
        XCTAssertLessThanOrEqual(field().segments.count, PrivacyReviewField.mostSegments)
        let review = PrivacyReview(id: UUID(), at: Date(), fields: (0..<500).map { _ in field() }, categories: [:])
        XCTAssertLessThanOrEqual(review.bytes, PrivacyReview.mostBytes)
        XCTAssertGreaterThan(review.omitted, 0)
        let kept = PrivacyReview.kept((0..<200).map { _ in PrivacyReview(id: UUID(), at: Date(), fields: [field(), field(), field(), field(), field(), field(), field(), field(), field()], categories: [:]) })
        XCTAssertLessThanOrEqual(kept.reduce(0) { $0 + $1.bytes }, PrivacyReview.mostKeptBytes)
        XCTAssertLessThanOrEqual(kept.count, PrivacyReview.mostKept)
        // one review larger than everything still shows
        XCTAssertEqual(PrivacyReview.kept([review]).count, 1)
    }

    func testATextSentAsReceivedIsKeptAsAMarkerAndComesBackWhole() async throws {
        let context = PrivacyConversation(), text = String(repeating: "plain words ", count: 2_000)
        try context.rememberResponse(masked: text, restored: text, location: "a")
        let again = try context.mask(text, location: "a", model: [])
        XCTAssertEqual(again.text, text)
        XCTAssertFalse(again.fresh)
    }
}

private struct StandInDetector: PrivacyEntityDetector {
    var words: [String: PrivacyCategory] = [:]
    func detect(in text: String) async throws -> [PrivacySpan] {
        let ns = text as NSString
        return words.compactMap { word, category in
            let range = ns.range(of: word)
            return range.location == NSNotFound ? nil : PrivacySpan(start: range.location, end: NSMaxRange(range), category: category)
        }
    }
}
