import Foundation
import XCTest
import PoolCore
@testable import PoolEngine

/// The tool choice and answer tool, as the session is told them.
final class TurnChoiceTests: XCTestCase {
    private let schema = JSONValue.object([
        "$schema": .string("https://json-schema.org/draft/2020-12/schema"), "type": .string("object"),
        "properties": .object(["title": .object(["type": .string("string"), "maxLength": .number(40)]),
                               "tags": .object(["type": .string("array"), "items": .object(["$ref": .string("#/$defs/tag")])])]),
        "required": .array([.string("title")]), "additionalProperties": .bool(false),
        "$defs": .object(["tag": .object(["enum": .array([.string("bug"), .string("feature")])])])])

    func testAnAnswerIsCheckedAgainstItsSchema() {
        XCTAssertNil(TurnChoice.schemaProblem(.object(["title": .string("Fix sign-in"), "tags": .array([.string("bug")])]), schema: schema))
        XCTAssertNotNil(TurnChoice.schemaProblem(.object(["tags": .array([])]), schema: schema), "title is required")
        XCTAssertNotNil(TurnChoice.schemaProblem(.object(["title": .string("x"), "extra": .bool(true)]), schema: schema))
        XCTAssertNotNil(TurnChoice.schemaProblem(.object(["title": .string("x"), "tags": .array([.string("chore")])]), schema: schema))
        XCTAssertNotNil(TurnChoice.schemaProblem(.object(["title": .string(String(repeating: "a", count: 41))]), schema: schema))
        XCTAssertNotNil(TurnChoice.schemaProblem(.string("words"), schema: schema))
        XCTAssertNil(TurnChoice.toolSchema(schema)["$schema"])
    }

    func testToolChoiceIsToldAndNarrowsWhatIsOffered() {
        let tools = [BridgeTool(name: "Read", inputSchema: .object([:])), BridgeTool(name: "Bash", inputSchema: .object([:]))]
        XCTAssertEqual(TurnChoice.offered(tools, toolChoice: "name:Bash").map(\.name), ["Bash"])
        XCTAssertEqual(TurnChoice.offered(tools, toolChoice: "none").map(\.name), ["Read", "Bash"])
        XCTAssertEqual(TurnChoice.ask("name:Bash") { "mcp__pool__" + $0 }, "\nYou must call the mcp__pool__Bash tool.")
        XCTAssertEqual(TurnChoice.ask("required") { $0 }, "\nYou must call at least one available tool before answering.")
        XCTAssertEqual(TurnChoice.ask("none") { $0 }, "")
        XCTAssertFalse(TurnChoice.allows("none")); XCTAssertTrue(TurnChoice.allows(nil))
        XCTAssertEqual(TurnChoice.answerName(avoiding: [BridgeTool(name: "StructuredOutput", inputSchema: .object([:]))]), "StructuredOutput2")
    }
}
