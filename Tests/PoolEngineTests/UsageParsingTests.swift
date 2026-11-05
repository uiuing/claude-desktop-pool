import Foundation
import XCTest
import PoolCore
@testable import PoolEngine

final class UsageParsingTests: XCTestCase {
    /// An assistant row's usage as Claude Code writes it with a one-hour prompt cache.
    func testOneHourCacheWritesAreReadFromClaudeCodeUsage() throws {
        let row = try JSONDecoder().decode(JSONValue.self, from: Data("""
        {"input_tokens":6,"output_tokens":412,"cache_read_input_tokens":48210,"cache_creation_input_tokens":1337,
         "cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":1337},"service_tier":"standard"}
        """.utf8))
        let usage = try XCTUnwrap(ClaudeTranscript.usage(row))
        XCTAssertEqual(usage.cacheCreationInputTokens, 1337)
        XCTAssertEqual(usage.oneHourCacheWrites, 1337)
    }

    func testUsageWithoutTheSplitHasNoOneHourWrites() throws {
        let row = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"input_tokens":3,"output_tokens":5,"cache_creation_input_tokens":40}"#.utf8))
        XCTAssertNil(try XCTUnwrap(ClaudeTranscript.usage(row)).oneHourCacheWrites)
    }
}
