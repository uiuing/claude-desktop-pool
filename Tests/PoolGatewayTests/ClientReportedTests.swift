import Foundation
import XCTest
@testable import PoolGateway
import PoolCore

/// Errors the official client reports, answered with the status and message the client reported
/// (too-long prompts, token counting and rate limits).
final class ClientReportedTests: XCTestCase {
    private func answer(_ status: Int, _ message: String) throws -> (Int, String, String) {
        let response = GatewayJSON.failure(BridgeFailure.clientReported(status: status, message: message))
        let error = try XCTUnwrap(JSONDecoder().decode(JSONValue.self, from: response.body)["error"])
        return (response.status, error["type"]?.stringValue ?? "", error["message"]?.stringValue ?? "")
    }

    func testClaudeCodesOwnTooLongIsA400TheClientCompactsOn() throws {
        let (status, type, message) = try answer(0, "Prompt is too long")
        XCTAssertEqual(status, 400)
        XCTAssertEqual(type, "invalid_request_error")
        XCTAssertTrue(message.hasPrefix("Prompt is too long"))
        XCTAssertTrue(message.contains("Compact the conversation"))
    }

    func testOverflowWordsAreTooLongInEitherLanguage() throws {
        for words in ["prompt is too long: 220000 tokens > 200000 maximum", "input length exceeds the model's maximum context",
                      "输入内容超过模型最大上下文长度"] {
            let (status, type, message) = try answer(400, words)
            XCTAssertEqual(status, 400, words); XCTAssertEqual(type, "invalid_request_error", words)
            XCTAssertTrue(message.lowercased().contains("prompt is too long"), words)
        }
    }

    func testRateLimitsAndOutputCapsAreNotOverflows() throws {
        for words in ["Too many tokens, please wait before trying again.", "Tokens per minute limit exceeded - too many tokens processed."] {
            let (status, type, message) = try answer(429, words)
            XCTAssertEqual(status, 429); XCTAssertEqual(type, "rate_limit_error"); XCTAssertEqual(message, words)
        }
        let (status, _, message) = try answer(400, "max_tokens: 64000 > 32000, which is the maximum allowed")
        XCTAssertEqual(status, 400)
        XCTAssertFalse(message.lowercased().hasPrefix("prompt is too long"))
    }

    func testKnownStatusesPassThroughAndUnknownIs502() throws {
        XCTAssertEqual(try answer(401, "OAuth token has expired").1, "authentication_error")
        XCTAssertEqual(try answer(403, "Third-party apps now draw from your extra usage").0, 403)
        XCTAssertEqual(try answer(529, "Overloaded").1, "overloaded_error")
        let unknown = try answer(0, "Something odd happened")
        XCTAssertEqual(unknown.0, 502); XCTAssertEqual(unknown.1, "api_error")
    }

    func testDiagnosticLinesStayOneLineAndCarryNoFieldForgery() {
        final class Lines: @unchecked Sendable { var all: [String] = [] }
        let lines = Lines()
        Diagnostics.install { lines.all.append($0) }
        defer { Diagnostics.install(nil) }
        Diagnostics.record("session.failed", ["reason": "input_box_timeout\nevent=forged", "ms": "12 34"])
        XCTAssertEqual(lines.all, ["event=session.failed reason=input_box_timeout_event_forged ms=12_34"])
        XCTAssertEqual(Diagnostics.tag("fixture-session#abc"), Diagnostics.tag("fixture-session#abc"))
        XCTAssertNotEqual(Diagnostics.tag("a"), Diagnostics.tag("b"))
    }
}
