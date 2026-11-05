import Foundation
import PoolRuntime
@testable import PoolPrivacy
import XCTest

final class AstrLinkTokenizerTests: XCTestCase {
    private func tokenizer() throws -> AstrLinkTokenizer {
        let vocabulary: [[Any]] = [["<unk>", 0.0], ["<s>", 0.0], ["\u{2581}", -2.0],
                                  ["a", -2.0], ["b", -2.0], ["\u{2581}ab", -1.0],
                                  ["\u{2581}1", -1.0], ["\u{1f600}", -1.0],
                                  ["e", -2.0], ["\u{e9}", -1.0], ["\u{301}", -2.0]]
        return try AstrLinkTokenizer(data: JSONSerialization.data(withJSONObject: [
            "model": ["type": "Unigram", "byte_fallback": false, "unk_id": 0, "vocab": vocabulary],
            "normalizer": ["type": "Sequence", "normalizers": [["type": "Precompiled", "precompiled_charsmap": "AAAAAA=="]]],
            "added_tokens": [["content": "<s>", "id": 1, "special": true, "lstrip": false]],
        ]))
    }

    func testUnigramChoosesWholePieceAndPreservesOffsets() throws {
        let result = try tokenizer().encode("ab ab")
        XCTAssertEqual(result, [.init(id: 5, start: 0, end: 2), .init(id: 5, start: 3, end: 5)])
    }

    func testUnknownRunsUnicodeAndSpecialTokens() throws {
        let result = try tokenizer().encode("<s>ab \u{1f600}xy")
        XCTAssertEqual(result, [.init(id: 1, start: 0, end: 3), .init(id: 5, start: 3, end: 5),
                                .init(id: 2, start: 6, end: 8), .init(id: 7, start: 6, end: 8),
                                .init(id: 0, start: 8, end: 10)])
    }

    func testWhitespaceFollowingDigitsRemainsInTokenStream() throws {
        XCTAssertEqual(try tokenizer().encode("1  ab").map(\.id), [6, 2, 2, 5])
        XCTAssertEqual(try tokenizer().encode("ab  ab").map(\.id), [5, 5])
    }

    func testVocabularyAndSpecialTokensUseLiteralScalarSequences() throws {
        XCTAssertEqual(try tokenizer().encode("e\u{301}").map(\.id), [2, 8, 10])
        XCTAssertEqual(try tokenizer().encode("<s>\u{301}").map(\.id), [1, 2, 10])
    }

    func testTokenLimitRejectsWholeInput() throws {
        XCTAssertThrowsError(try tokenizer().encode("ab ab", tokenLimit: 1)) {
            XCTAssertEqual($0 as? PrivacyFailure, .inputTooLarge)
        }
    }

    func testBIOOffsetsConfidenceAndEveryPublisherKind() {
        let tokens = (0..<21).map { AstrLinkTokenizer.Token(id: 1, start: $0 * 2, end: $0 * 2 + 2) }
        let labels = Array(0..<21), scores = [Double](repeating: 0.9, count: 21)
        let spans = AstrLinkDetector.spans(tokens: tokens, labels: labels, scores: scores)
        XCTAssertEqual(spans.count, 10)
        XCTAssertEqual(Set(spans.map(\.category)), [.email, .phone, .account, .bankCard, .ip, .url, .secret, .address, .date, .person])
        XCTAssertEqual(spans[0], PrivacySpan(start: 2, end: 6, category: .email, score: 0.9))
        XCTAssertTrue(AstrLinkDetector.spans(tokens: [.init(id: 1, start: 0, end: 1)], labels: [1], scores: [0.799]).isEmpty)
    }

    func testEmptyReadinessNeverSkipsMissingModel() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/privacy-fixtures/\(UUID().uuidString)")
        let model = AstrLinkDetector(workspace: OwnedWorkspace(root: root))
        let status = await model.status()
        XCTAssertEqual(status, .notInstalled)
        do { _ = try await model.detect(in: ""); XCTFail("Missing model must block even empty input") }
        catch { XCTAssertEqual(error as? PrivacyFailure, .notReady) }
    }
}
