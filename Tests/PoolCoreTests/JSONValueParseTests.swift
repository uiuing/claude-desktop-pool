import Foundation
import XCTest
import PoolCore

/// `JSONValue.parse` must read every body exactly as `JSONDecoder` reads a `JSONValue`: the same
/// tree, the same bytes when written again, and an error where the decoder throws one.
final class JSONValueParseTests: XCTestCase {
    private func written(_ value: JSONValue) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }
    private func assertSame(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        assertSame(Data(text.utf8), label: text, file: file, line: line)
    }
    private func assertSame(_ data: Data, label: String, file: StaticString = #filePath, line: UInt = #line) {
        let decoded = Result { try JSONDecoder().decode(JSONValue.self, from: data) }
        let parsed = Result { try JSONValue.parse(data) }
        switch (decoded, parsed) {
        case (.success(let expected), .success(let actual)):
            XCTAssertEqual(actual, expected, label, file: file, line: line)
            XCTAssertEqual(try written(actual), try written(expected), label, file: file, line: line)
        case (.failure, .failure): break
        case (.success, .failure(let error)): XCTFail("\(label): the decoder reads it, parse throws \(error)", file: file, line: line)
        case (.failure, .success(let value)): XCTFail("\(label): the decoder throws, parse reads \(value)", file: file, line: line)
        }
    }

    func testEdgeCasesReadAsTheDecoderReadsThem() {
        let cases = [
            // booleans stay booleans, numbers stay numbers
            "true", "false", "[true,1,0,false]", #"{"a":true,"b":1}"#, "1", "0", "1.0", "-1",
            // zero in each spelling, including the ones the two readers disagree on
            "-0", "[-0]", #"{"a":-0}"#, "[0,-0]", "-0.0", "0.0", "0e1", "-0e5", "-0E-2", "-0.0e1", "0.0e1", "[0, -0 ]",
            #"["a-0,", 0]"#, #"["2026-01-05", 0]"#,
            // integers past Int64 and UInt64, long fractions, exponents, range limits
            "9223372036854775807", "9223372036854775808", "-9223372036854775809", "18446744073709551615",
            "12345678901234567890", "123456789012345678901234567890", "123456789012345678901234567890123456789012345",
            "3.141592653589793238462643383279", "0.0000000000000000000000000000000000000000001", "100000000000000000000000",
            "1e2", "1E2", "1e+2", "1.5e300", "1.7976931348623157e308", "5e-324", "4.9406564584124654e-324", "1e-320",
            "2.2250738585072014e-308", "1E400", "-1E400", "1e-400", "0.1", "1.00e1",
            // null, empty containers, nesting
            "null", "[]", "{}", "[[]]", #"{"a":{}}"#, "[null,{},[]]", #"{"a":null}"#,
            // duplicate keys, keys equal only to Swift
            #"{"a":1,"a":2}"#, #"{"a":{"x":1},"a":[2]}"#, #"{"é":1,"é":2}"#, #"{"é":2,"é":1}"#,
            #"{"e\u0301":1,"\u00e9":2}"#, #"{"\u00e9":2,"e\u0301":1}"#,
            // strings and escapes
            #""x""#, #""\u0000""#, #"["\/"]"#, #""😀""#, #""\ud800""#, #""\udc00\ud800""#, "\"\u{1}\"", "\"\t\"",
            // whitespace, byte order mark, trailing commas
            " {} ", "\u{FEFF}{}", "[1 ,2]", "[1,]", #"{"a":1,}"#,
            // not JSON
            "", " ", "1 2", "[01]", "[1.]", "[.5]", "[-]", "[NaN]", "[Infinity]", "/*c*/{}", "{a:1}", "{", "]", "nul",
        ]
        for text in cases { assertSame(text) }
        assertSame(Data([0x22, 0xff, 0x22]), label: "invalid UTF-8")
        assertSame("{\"a\":[1,true]}".data(using: .utf16)!, label: "UTF-16")
        assertSame(Data((String(repeating: "[", count: 600) + String(repeating: "]", count: 600)).utf8), label: "deep nesting")
    }

    func testBooleansAreNotNumbers() throws {
        XCTAssertEqual(try JSONValue.parse(Data("[true,false,1,0]".utf8)), .array([.bool(true), .bool(false), .number(1), .number(0)]))
        XCTAssertEqual(try written(JSONValue.parse(Data("-0".utf8))), Data("-0".utf8))
        XCTAssertEqual(try JSONValue.parse(Data(#"{"a":1,"a":2}"#.utf8)), .object(["a": .number(1)]))
    }

    func testRandomNumbersAndDocumentsReadAsTheDecoderReadsThem() {
        var random = SeededRandom(seed: 0x5eed)
        let alphabet = Array("0123456789-+.eE")
        for _ in 0..<4000 {
            let token = String((0..<Int.random(in: 1...8, using: &random)).map { _ in alphabet.randomElement(using: &random)! })
            assertSame(token); assertSame("[" + token + "]")
        }
        for _ in 0..<3000 {
            let digits = String((0..<Int.random(in: 1...25, using: &random)).map { _ in "0123456789".randomElement(using: &random)! })
            let fraction = Bool.random(using: &random) ? ".\(Int.random(in: 0...99999, using: &random))" : ""
            let exponent = Bool.random(using: &random) ? "e\(Int.random(in: -330...310, using: &random))" : ""
            assertSame((Bool.random(using: &random) ? "-" : "") + "1" + digits + fraction + exponent)
        }
        for _ in 0..<2000 {
            let value = Double(bitPattern: UInt64.random(in: 0...UInt64.max, using: &random))
            guard value.isFinite else { continue }
            assertSame("\(value)"); assertSame(String(format: "%.17g", value)); assertSame(String(format: "%.25e", value))
        }
        let tokens = ["{", "}", "[", "]", ",", ":", #""a""#, #""b""#, "1", "true", "null", "-0", " ", #""é""#,
                      #""é""#, #""\ud800""#, "\"\u{1}\"", "0e1", "1e-400", "2.5"]
        for _ in 0..<20000 {
            assertSame((0..<Int.random(in: 1...10, using: &random)).map { _ in tokens.randomElement(using: &random)! }.joined())
        }
    }

    /// A large Claude Code request is read no slower than by the decoder; measured against the
    /// decoder on the same machine, so a busy machine slows both.
    func testLargeBodyIsReadNoSlowerThanTheDecoder() throws {
        let body = Self.largeBody(megabytes: 8)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: body)
        XCTAssertEqual(try JSONValue.parse(body), decoded)
        func best(_ work: () throws -> Void) rethrows -> Duration {
            var fastest = Duration.seconds(3600)
            for _ in 0..<3 { let began = ContinuousClock.now; try work(); fastest = min(fastest, .now - began) }
            return fastest
        }
        let decoder = try best { _ = try JSONDecoder().decode(JSONValue.self, from: body) }
        let parse = try best { _ = try JSONValue.parse(body) }
        XCTAssertLessThanOrEqual(parse, decoder, "parse \(parse), decoder \(decoder)")
    }

    /// A body shaped like a long Claude Code conversation: text, tool calls and results, numbers and flags.
    static func largeBody(megabytes: Int) -> Data {
        var messages: [JSONValue] = []
        var size = 0, index = 0
        while size < megabytes * 1_000_000 {
            let text = String(repeating: "Synthetic line \(index) with some words and a path /tmp/example.invalid/file.swift\n", count: 40)
            messages.append(.object(["role": .string("assistant"), "content": .array([
                .object(["type": .string("text"), "text": .string("Reading the file.")]),
                .object(["type": .string("tool_use"), "id": .string("toolu_\(index)"), "name": .string("Read"),
                         "input": .object(["file_path": .string("/tmp/example.invalid/\(index).swift"), "offset": .number(0),
                                           "limit": .number(2000), "verbose": .bool(false)])]),
            ])]))
            messages.append(.object(["role": .string("user"), "content": .array([
                .object(["type": .string("tool_result"), "tool_use_id": .string("toolu_\(index)"), "is_error": .bool(false),
                         "content": .array([.object(["type": .string("text"), "text": .string(text)])])]),
            ])]))
            size += text.utf8.count + 400; index += 1
        }
        let request: JSONValue = .object(["model": .string("claude-opus-5-5"), "max_tokens": .number(32000), "stream": .bool(true),
                                          "temperature": .number(1), "top_p": .number(0.95), "messages": .array(messages)])
        return try! request.encoded()
    }
}

/// A repeatable generator, so a failure names the same inputs on every run.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
