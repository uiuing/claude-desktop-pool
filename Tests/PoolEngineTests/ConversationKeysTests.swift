import Foundation
import CryptoKit
import XCTest
import PoolCore
@testable import PoolEngine

/// The conversation keys are kept on disk (a set-aside conversation is found by a key's first 16 hex digits),
/// so the bytes they are made of must never change. These pin them for representative conversations, check the
/// incremental form against the whole one, and keep the faster computation faster than the plain one it replaced.
final class ConversationKeysTests: XCTestCase {
    // MARK: Fixtures

    private static func user(_ content: JSONValue) -> BridgeMessage { BridgeMessage(role: "user", content: content) }
    private static func assistant(_ content: JSONValue) -> BridgeMessage { BridgeMessage(role: "assistant", content: content) }
    private static func text(_ s: String, cache: Bool = false) -> JSONValue {
        var fields: [String: JSONValue] = ["type": .string("text"), "text": .string(s)]
        if cache { fields["cache_control"] = .object(["type": .string("ephemeral")]) }
        return .object(fields)
    }
    private static func toolUse(_ id: String, _ name: String, input: JSONValue = .object([:])) -> JSONValue {
        .object(["type": .string("tool_use"), "id": .string(id), "name": .string(name), "input": input])
    }
    private static func toolResult(_ id: String, _ content: JSONValue?, cache: Bool = false) -> JSONValue {
        var fields: [String: JSONValue] = ["type": .string("tool_result"), "tool_use_id": .string(id)]
        if let content { fields["content"] = content }
        if cache { fields["cache_control"] = .object(["type": .string("ephemeral")]) }
        return .object(fields)
    }
    private static func image(_ data: String) -> JSONValue {
        .object(["type": .string("image"), "source": .object(["type": .string("base64"), "media_type": .string("image/png"),
                                                                "data": .string(data)])])
    }

    static let plain: [BridgeMessage] = [
        user(.string("Hello there, how are you?")),
        assistant(.string("  Fine,\tthanks.\n\nAnd you?  ")),
        user(.string("Good.")),
    ]

    static let blocks: [BridgeMessage] = [
        user(.array([text("Read the file\r\nplease", cache: true), text("   "), text("and\u{0B}then\u{0C}summarise")])),
        assistant(.array([
            .object(["type": .string("thinking"), "thinking": .string("hidden"), "signature": .string("sig")]),
            text("Reading it."),
            toolUse("toolu_01AAA", "Read", input: .object(["file_path": .string("/tmp/example.invalid/a.txt")])),
            toolUse("toolu_01BBB", "Grep tool", input: .object(["pattern": .string("x"), "n": .number(3)])),
        ])),
        user(.array([
            toolResult("toolu_01AAA", .string("line one\nline two")),
            toolResult("toolu_01BBB", .array([text("found"), image("iVBORw0KGgo="),
                                              .object(["type": .string("search_result"), "title": .string("t")])]), cache: true),
            toolResult("toolu_unknown", nil),
            text("<system-reminder>note</system-reminder>"),
        ])),
        assistant(.array([.object(["type": .string("redacted_thinking"), "data": .string("x")]), text("Done.")])),
        user(.array([image("AAAA"), image(""), text("what is this?", cache: true)])),
        user(.array([
            .object(["type": .string("document"), "source": .object(["type": .string("text"), "data": .string("doc body")]),
                     "cache_control": .object(["type": .string("ephemeral")])]),
            .object(["title": .string("no type")]),
        ])),
        assistant(.array([text("It is a picture."), toolUse("toolu_01CCC", "Bash")])),
        user(.array([toolResult("toolu_01CCC", .array([image("abc"), image("defg")]))])),
    ]

    static let unicode: [BridgeMessage] = [
        user(.string("你好，世界！ 这是中文　测试\u{3000}全角空格")),
        assistant(.string("👨‍👩‍👧‍👦 family 🇹🇼 flag 👍🏽 thumbs ❤️ heart")),
        user(.string("combining after space: a \u{301}b and e\u{301} and \u{0600} x prepend")),
        user(.string("nbsp\u{A0}here, line\u{2028}sep, para\u{2029}sep, nel\u{85}end, ogham\u{1680}x, thin\u{2009}x")),
        assistant(.string("zwj after space \u{200D}x, vs16 after space \u{FE0F}y, mark \u{93F} z, 中 \u{300} 文")),
        user(.array([text("emoji 🧑🏻‍💻 at work"), toolUse("toolu_z", "名字 工具")])),
        user(.array([toolResult("toolu_z", .string("结果：成功 ✅\r\n第二行"))])),
        assistant(.string("\u{1}control \u{0}nul and trailing\u{3000}")),
    ]

    static let empty: [BridgeMessage] = [
        user(.string("")),
        assistant(.array([])),
        user(.string(" \n\t ")),
        assistant(.array([text(""), .object(["type": .string("thinking"), "thinking": .string("x")])])),
        user(.string("first words")),
        user(.string("same role again")),
        assistant(.string("reply")),
        assistant(.null),
        user(.number(3)),
    ]

    /// A long conversation: 3000 messages of words, calls, results, images and Chinese, made the same each time.
    static let long: [BridgeMessage] = {
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Int { seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407; return Int(seed >> 33) }
        let vocabulary = ["the", "file", "function", "returns", "error", "value", "测试", "对话", "键值", "🙂", "résumé",
                          "naïve", "x", "{", "}", "let", "var", "=", "==", "->", "\"quoted\"", "path/to/thing.swift"]
        let spaces = [" ", " ", " ", "  ", "\n", "\n\n", "\t", " \n "]
        func words(_ count: Int) -> String {
            var out = ""
            for _ in 0..<count { out += vocabulary[next() % vocabulary.count]; out += spaces[next() % spaces.count] }
            return out
        }
        var messages: [BridgeMessage] = [], call = 0
        for index in 0..<3000 {
            if index % 2 == 0 {
                switch next() % 4 {
                case 0 where call > 0:
                    messages.append(user(.array([toolResult("toolu_\(call)", .string(words(80 + next() % 120)))])))
                case 1 where call > 0:
                    messages.append(user(.array([toolResult("toolu_\(call)", .array([text(words(60)), image("QUJD")])),
                                                 text(words(10))])))
                default:
                    messages.append(user(.string(words(40 + next() % 160))))
                }
            } else if next() % 3 == 0 {
                call += 1
                messages.append(assistant(.array([text(words(30)), toolUse("toolu_\(call)", "Read")])))
            } else {
                messages.append(assistant(.array([text(words(50 + next() % 150), cache: next() % 5 == 0)])))
            }
        }
        return messages
    }()

    // MARK: Pinned keys

    func testPinnedKeys() {
        XCTAssertEqual(ConversationWords.prefixKeys(Self.plain), Self.plainKeys)
        XCTAssertEqual(ConversationWords.prefixKeys(Self.blocks), Self.blocksKeys)
        XCTAssertEqual(ConversationWords.prefixKeys(Self.unicode), Self.unicodeKeys)
        XCTAssertEqual(ConversationWords.prefixKeys(Self.empty), Self.emptyKeys)
        XCTAssertEqual(ConversationWords.prefixKeys([]), [])
        XCTAssertEqual(ConversationWords.key([]), Self.emptyConversationKey)
        for (messages, keys) in [(Self.plain, Self.plainKeys), (Self.blocks, Self.blocksKeys),
                                 (Self.unicode, Self.unicodeKeys), (Self.empty, Self.emptyKeys)] {
            XCTAssertEqual(ConversationWords.key(messages), keys.last)
        }
        let long = ConversationWords.prefixKeys(Self.long)
        XCTAssertEqual(long.count, 3000)
        XCTAssertEqual(long[0], Self.longKey0)
        XCTAssertEqual(long[1499], Self.longKey1499)
        XCTAssertEqual(ConversationWords.key(Self.long), Self.longKeyLast)
        XCTAssertEqual(Self.digest(long), Self.longKeysDigest)
    }

    func testMatchesThePlainComputation() {
        for messages in [Self.plain, Self.blocks, Self.unicode, Self.empty, Self.long, []] {
            XCTAssertEqual(ConversationWords.prefixKeys(messages), PlainWords.prefixKeys(messages))
            XCTAssertEqual(ConversationWords.key(messages), PlainWords.key(messages))
            XCTAssertEqual(ConversationWords.words(messages), PlainWords.words(messages))
            XCTAssertEqual(ConversationWords.parts(messages), PlainWords.parts(messages))
        }
    }

    /// Words built from every kind of space, mark and joiner next to each other, as the plain computation splits them.
    func testMixedScalarsMatchThePlainComputation() {
        let pieces = [" ", "\n", "\r", "\r\n", "\t", "\u{0B}", "\u{0C}", "\u{85}", "\u{A0}", "\u{1680}", "\u{2000}", "\u{200A}",
                      "\u{2028}", "\u{2029}", "\u{202F}", "\u{205F}", "\u{3000}", "\u{301}", "\u{300}", "\u{200D}", "\u{200C}",
                      "\u{FE0F}", "\u{93F}", "\u{903}", "\u{600}", "\u{605}", "\u{D4E}", "\u{110BD}", "\u{1F3FD}", "\u{E0020}",
                      "\u{FF9E}", "\u{1100}", "\u{1161}", "\u{11A8}", "\u{1F1F9}", "\u{1F1FC}", "👍", "中", "a", "Z", "\u{1}",
                      "\u{0}", "é", "\u{915}", "\u{94D}", "\u{200B}", "\u{180E}", "\u{FEFF}", "\u{1D173}"]
        var seed: UInt64 = 42
        func next() -> Int { seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407; return Int(seed >> 33) }
        var messages: [BridgeMessage] = []
        for index in 0..<3000 {
            var s = ""
            for _ in 0..<(next() % 12) { s += pieces[next() % pieces.count] }
            let content: JSONValue = index % 3 == 0 ? .string(s)
                : .array([Self.text(s), Self.toolUse("t\(index)", s), Self.toolResult("t\(index - 1)", .string(s))])
            messages.append(BridgeMessage(role: index % 2 == 0 ? "user" : "assistant", content: content))
        }
        XCTAssertEqual(ConversationWords.parts(messages), PlainWords.parts(messages))
        XCTAssertEqual(ConversationWords.prefixKeys(messages), PlainWords.prefixKeys(messages))
    }

    /// Every scalar the plain computation splits at, alone, is one the faster one splits at.
    func testWhitespaceScalarsMatchCharacters() {
        for value in UInt32(0)...0x10FFFF {
            guard let scalar = Unicode.Scalar(value) else { continue }
            let character = Character(scalar)
            XCTAssertEqual(ConversationWords.isSpace(value), character.isWhitespace || character.isNewline, "U+\(String(value, radix: 16))")
        }
    }

    // MARK: Incremental

    func testPrefixGrowsAsTheWholeComputation() {
        for messages in [Self.plain, Self.blocks, Self.unicode, Self.empty, Array(Self.long.prefix(120))] {
            let whole = ConversationWords.prefixKeys(messages)
            for n in 0...messages.count {
                var prefix = ConversationWords.Prefix(Array(messages[..<n]))
                XCTAssertEqual(prefix.keys, Array(whole[..<n]))
                XCTAssertEqual(prefix.key, ConversationWords.key(Array(messages[..<n])))
                if n < messages.count {
                    XCTAssertEqual(prefix.append(messages[n]), whole[n])
                    XCTAssertEqual(prefix.keys, Array(whole[...n]))
                    XCTAssertEqual(prefix.key, whole[n])
                }
            }
        }
        var prefix = ConversationWords.Prefix([])
        for message in Self.long { prefix.append(message) }
        XCTAssertEqual(prefix.keys, ConversationWords.prefixKeys(Self.long))
        XCTAssertEqual(prefix.key, Self.longKeyLast)
    }

    // MARK: Speed

    /// The faster computation against the plain one on the same long conversation, best of a few runs each.
    func testFasterThanThePlainComputation() {
        let messages = Self.long
        func best(_ body: () -> Void) -> TimeInterval {
            (0..<3).map { _ in let start = Date(); body(); return Date().timeIntervalSince(start) }.min()!
        }
        let plain = best { _ = PlainWords.prefixKeys(messages) }
        let fast = best { _ = ConversationWords.prefixKeys(messages) }
        let bytes = messages.reduce(0) { $0 + (((try? $1.content.encoded()) ?? Data()).count) }
        print("conversation keys: \(bytes) bytes, plain \(Int(plain * 1000)) ms, fast \(Int(fast * 1000)) ms")
        // About a third of the plain time in a debug build and a twelfth optimized; the margin is for a busy machine.
        XCTAssertLessThan(fast, plain * 0.75, "The conversation keys should take well under the plain computation's time.")
    }

    // MARK: Pinned values

    static func digest(_ keys: [String]) -> String {
        SHA256.hash(data: Data(keys.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static let plainKeys: [String] = [
        "80555e45f72cee86704af8757da7de6e1b7cf5d67521be58763666de328a5303",
        "b7b4175c310377e643048f89dabbd7aeff54d51206996178a3fe1d9bb96c4530",
        "a2e83a80e165c0c1cf3e582f6bb661d89707ce616df40eba32d1e8428dc3f25d",
    ]
    static let blocksKeys: [String] = [
        "b08ac0efb0e91d7093649f7f44c70a6a125390e9c5e6b21d42625ca8bee854c8",
        "ddde4b3e1fe86c1181a46c7b038ad86c1e10433679ceeefd8efecc7047ebc8c0",
        "c99d3aeef737f26b88e360d6135a861aaa8b471dea625f63d32ba8dd1fa7f838",
        "1bde27b752f8fff2d58f6870691e7bb1b6a5cafcf1d0721e55aed398a19af177",
        "ba15b6316c9835315746f64a2d136f36cadb94e5a01e0e0fee3433d82b65f9c4",
        "2194217420758415a249988231556455497b91470b4b2aca6adf8cbfcfdf5e5f",
        "4ff0d92ca801058e09f4d3d4791674f42954823c57b5c035dd0766bc24a74058",
        "6dbc78afcba5ffa8d6e44a6638cb9b817d25407bb5d5f0c8cbe96b7b209b33c5",
    ]
    static let unicodeKeys: [String] = [
        "e86d9ef0978a6fbc0f029936481fc39a3962b8371e870140d178ab0ca80e149d",
        "0bd632bd695da75d8e75bc4727bd66018f3d6b12ab8872792f3f8f2e203881eb",
        "6f6c89bf8e7c55f4b8354f5c0064c7f08066062117ffff4a9e6285ca04066384",
        "0928100297d5a61f108f543411696b8092a31e3b975c12f6dcdb2f4a95912664",
        "b4eec52b1552a154e1a619623f5ed320619a79efe475acc5a4ede6e85ddc8268",
        "f5e764103a18f2b2b60645e393d13350bb6c146dfb72becd21fdb0647b7bbd83",
        "130caa18651682bb2e25f6a9bc1f2d99a1f839f09c4e8073e9463b967d5a1ae9",
        "e2265ab196642450c7a43d95afd9cdb02bceb31f2c5fee9cc64b75d7aa8432f7",
    ]
    static let emptyKeys: [String] = [
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "0b7c647e2e4312dfa6443f3482a69bd0b9a741e7bf1f130703d600be066ed2b5",
        "c2efd645cebe2a2c96d52ffe96cd0f758120408f6a56f3dc0af7da9e5b8dfbdc",
        "0f5cb6be33b63f1530cd33285ace807b0714a39c4e1212ecea1bc1b227f84d1b",
        "0f5cb6be33b63f1530cd33285ace807b0714a39c4e1212ecea1bc1b227f84d1b",
        "0f5cb6be33b63f1530cd33285ace807b0714a39c4e1212ecea1bc1b227f84d1b",
    ]
    static let emptyConversationKey = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    static let longKey0 = "5d0dd5bc0e03fd3ce57e22f220b0168d8544be2743bd720dccb934c881dfa393"
    static let longKey1499 = "5d9ffd5b9c932c742e02682581142072b4cf4fa33aca804c17fade734961271e"
    static let longKeyLast = "1995757228a86a37d863710e2c8f7a357e5a086f40cbe80e388235818ef85f92"
    static let longKeysDigest = "4eacfb6f10c7b88140b92dbb77bbac11a62d152fdd3bedc763445563105d3c83"

    func testPrintPinnedValues() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["PRINT_KEYS"] != nil)
        func show(_ name: String, _ keys: [String]) { print("static let \(name): [String] = [\n" + keys.map { "    \"\($0)\",\n" }.joined() + "]") }
        show("plainKeys", PlainWords.prefixKeys(Self.plain))
        show("blocksKeys", PlainWords.prefixKeys(Self.blocks))
        show("unicodeKeys", PlainWords.prefixKeys(Self.unicode))
        show("emptyKeys", PlainWords.prefixKeys(Self.empty))
        let long = PlainWords.prefixKeys(Self.long)
        print("static let emptyConversationKey = \"\(PlainWords.key([]))\"")
        print("static let longKey0 = \"\(long[0])\"")
        print("static let longKey1499 = \"\(long[1499])\"")
        print("static let longKeyLast = \"\(long.last!)\"")
        print("static let longKeysDigest = \"\(Self.digest(long))\"")
    }
}

/// The conversation keys as they were first computed, kept to check the faster computation against.
private enum PlainWords {
    static func parts(_ messages: [BridgeMessage]) -> [[ConversationWords.WordPart]] {
        var calls: [String: Int] = [:], count = 0
        return messages.map { message in
            var parts: [ConversationWords.WordPart] = []
            func add(_ kind: ConversationWords.WordPart.Kind, _ text: String, media: Int = 0) {
                let words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
                if !words.isEmpty { parts.append(ConversationWords.WordPart(kind: kind, words: words, media: media)) }
            }
            if let text = message.content.stringValue { add(.text, text) }
            for block in message.content.arrayValue ?? [] {
                switch block["type"]?.stringValue {
                case "text": add(.text, block["text"]?.stringValue ?? "")
                case "tool_use":
                    count += 1
                    if let id = block["id"]?.stringValue { calls[id] = count }
                    add(.call, "\u{1}call \(block["name"]?.stringValue ?? "") #\(count)")
                case "tool_result":
                    let place = block["tool_use_id"]?.stringValue.flatMap { calls[$0] }.map(String.init) ?? "?"
                    let images = block["content"]?.arrayValue?.filter { $0["type"]?.stringValue == "image" }.count ?? 0
                    add(.result, "\u{1}result #\(place) " + resultText(block["content"]), media: images)
                case "image":
                    add(.image, "\u{1}image \(block["source"]?["data"]?.stringValue?.utf8.count ?? 0)")
                case "thinking", "redacted_thinking", nil: continue
                default:
                    add(.text, "\u{1}block \(block["type"]?.stringValue ?? "") " + digest(block))
                }
            }
            return parts
        }
    }
    static func words(_ messages: [BridgeMessage]) -> [String] {
        parts(messages).map { $0.map(\.words).joined(separator: " ") }
    }
    static func prefixKeys(_ messages: [BridgeMessage]) -> [String] {
        var hasher = SHA256(), role = "", keys: [String] = []
        for (index, words) in words(messages).enumerated() {
            if !words.isEmpty {
                if messages[index].role != role { role = messages[index].role; hasher.update(data: Data("\u{0}\(role):".utf8)) }
                hasher.update(data: Data((words + " ").utf8))
            }
            keys.append(hex(hasher))
        }
        return keys
    }
    static func key(_ messages: [BridgeMessage]) -> String { prefixKeys(messages).last ?? hex(SHA256()) }
    private static func resultText(_ content: JSONValue?) -> String {
        guard let content else { return "" }
        if let text = content.stringValue { return text }
        return (content.arrayValue ?? []).compactMap { part -> String? in
            switch part["type"]?.stringValue {
            case "text": return part["text"]?.stringValue
            case "image": return nil
            default: return "\u{1}part \(part["type"]?.stringValue ?? "") " + digest(part)
            }
        }.joined(separator: "\n")
    }
    private static func digest(_ block: JSONValue) -> String {
        var value = block
        if case .object(var fields) = block { fields.removeValue(forKey: "cache_control"); value = .object(fields) }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return String(SHA256.hash(data: (try? encoder.encode(value)) ?? Data()).map { String(format: "%02x", $0) }.joined().prefix(16))
    }
    private static func hex(_ hasher: SHA256) -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
