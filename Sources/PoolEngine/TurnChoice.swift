import Foundation
import PoolCore

/// What a turn may call and how it answers, as the interactive client is told:
/// `tool_choice` and a structured answer through an answer tool of the bridge's own.
/// Claude Code's interactive mode does nothing with `--json-schema`, so a
/// request with a schema is given the answer tool through the MCP helper like the client's tools; a
/// call that fits the schema is the answer, one that doesn't is told why and made again, and a turn
/// that ends without one is asked for it once.
enum TurnChoice {
    static let answerToolName = "StructuredOutput"
    static let answerToolDescription = "Use this tool to give your final answer, as its input, in the shape its input schema asks. " +
        "Call it once, at the end of your work, instead of answering in words."
    /// The answer to a call of a client's tool when the client chose none for this turn.
    static let noToolsAnswer = "No tool can be used for this reply. Answer without tools."
    static let answerReceived = "Answer received."

    /// The answer tool's name, apart from the client's tools (answerTool).
    static func answerName(avoiding tools: [BridgeTool]) -> String {
        var name = answerToolName, next = 2
        while tools.contains(where: { $0.name == name }) { name = answerToolName + String(next); next += 1 }
        return name
    }
    /// Asks a turn that ended without the answer tool for its call (answerAsk).
    static func answerAsk(_ callable: String) -> String {
        "Give your final answer now by calling the \(callable) tool, with the answer as its input."
    }
    /// What the session's instructions add for the client's tool choice (toolChoiceAsk).
    static func ask(_ toolChoice: String?, callable: (String) -> String) -> String {
        guard let toolChoice else { return "" }
        if toolChoice == "required" { return "\nYou must call at least one available tool before answering." }
        if toolChoice.hasPrefix("name:") { return "\nYou must call the \(callable(String(toolChoice.dropFirst(5)))) tool." }
        return ""
    }
    /// The client's tools the session is offered: all of them, less those a named choice rules out. A
    /// choice of none keeps them all, as the prompt cache keys on them; its calls are refused instead.
    static func offered(_ tools: [BridgeTool], toolChoice: String?) -> [BridgeTool] {
        guard let toolChoice, toolChoice.hasPrefix("name:") else { return tools }
        let name = String(toolChoice.dropFirst(5))
        return tools.filter { $0.name == name }
    }
    /// Whether a turn may call a client's tool by this name.
    static func allows(_ toolChoice: String?) -> Bool { toolChoice != "none" }
    /// The schema as the answer tool takes it: without its root `$schema` (cliSchema).
    static func toolSchema(_ schema: JSONValue) -> JSONValue {
        guard var root = schema.objectValue else { return schema }
        root.removeValue(forKey: "$schema")
        return .object(root)
    }

    /// Why `value` does not fit `schema`, nil when it does: the JSON Schema keywords an answer's shape
    /// uses (type, properties, required, additionalProperties, items, enum, const, bounds, the
    /// combinators and local `$ref`s). A full validator would check more.
    static func schemaProblem(_ value: JSONValue, schema: JSONValue) -> String? {
        problem(value, schema, root: schema, path: "$", depth: 0)
    }
    private static func problem(_ value: JSONValue, _ schema: JSONValue, root: JSONValue, path: String, depth: Int) -> String? {
        guard depth < 64 else { return nil }
        if case .bool(let allowed) = schema { return allowed ? nil : "\(path) is not allowed" }
        guard let s = schema.objectValue else { return nil }
        if let ref = s["$ref"]?.stringValue {
            guard let target = resolve(ref, in: root) else { return nil }
            return problem(value, target, root: root, path: path, depth: depth + 1)
        }
        if let types = s["type"] {
            let names = types.stringValue.map { [$0] } ?? types.arrayValue?.compactMap(\.stringValue) ?? []
            if !names.isEmpty && !names.contains(where: { fits(value, type: $0) }) {
                return "\(path) must be \(names.joined(separator: " or "))"
            }
        }
        if let options = s["enum"]?.arrayValue, !options.contains(value) { return "\(path) must be one of the listed values" }
        if let constant = s["const"], constant != value { return "\(path) must be \(describe(constant))" }
        for (key, combine) in [("allOf", 0), ("anyOf", 1), ("oneOf", 2)] {
            guard let list = s[key]?.arrayValue else { continue }
            let fitting = list.filter { problem(value, $0, root: root, path: path, depth: depth + 1) == nil }.count
            if combine == 0, fitting != list.count { return list.lazy.compactMap { problem(value, $0, root: root, path: path, depth: depth + 1) }.first }
            if combine == 1, fitting == 0 { return "\(path) fits none of its allowed shapes" }
            if combine == 2, fitting != 1 { return "\(path) must fit exactly one of its allowed shapes" }
        }
        switch value {
        case .object(let fields):
            for name in s["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where fields[name] == nil {
                return "\(path).\(name) is required"
            }
            let properties = s["properties"]?.objectValue ?? [:]
            for (name, field) in fields.sorted(by: { $0.key < $1.key }) {
                if let sub = properties[name] {
                    if let why = problem(field, sub, root: root, path: path + "." + name, depth: depth + 1) { return why }
                } else if let extra = s["additionalProperties"] {
                    if let why = problem(field, extra, root: root, path: path + "." + name, depth: depth + 1) {
                        return extra == .bool(false) ? "\(path).\(name) is not one of its properties" : why
                    }
                }
            }
        case .array(let items):
            if let least = s["minItems"]?.doubleValue, Double(items.count) < least { return "\(path) needs at least \(Int(least)) items" }
            if let most = s["maxItems"]?.doubleValue, Double(items.count) > most { return "\(path) takes at most \(Int(most)) items" }
            if let sub = s["items"], sub.objectValue != nil || sub.boolValue != nil {
                for (index, item) in items.enumerated() {
                    if let why = problem(item, sub, root: root, path: path + "[\(index)]", depth: depth + 1) { return why }
                }
            }
        case .string(let text):
            if let least = s["minLength"]?.doubleValue, Double(text.count) < least { return "\(path) is shorter than \(Int(least))" }
            if let most = s["maxLength"]?.doubleValue, Double(text.count) > most { return "\(path) is longer than \(Int(most))" }
        case .number(let number):
            if let least = s["minimum"]?.doubleValue, number < least { return "\(path) is below \(describe(.number(least)))" }
            if let most = s["maximum"]?.doubleValue, number > most { return "\(path) is above \(describe(.number(most)))" }
            if let least = s["exclusiveMinimum"]?.doubleValue, number <= least { return "\(path) must be above \(describe(.number(least)))" }
            if let most = s["exclusiveMaximum"]?.doubleValue, number >= most { return "\(path) must be below \(describe(.number(most)))" }
        default: break
        }
        return nil
    }
    private static func fits(_ value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("object", .object), ("array", .array), ("string", .string), ("boolean", .bool), ("null", .null), ("number", .number): return true
        case ("integer", .number(let n)): return n.rounded() == n
        default: return false
        }
    }
    /// A `$ref` inside the schema itself; nothing outside it is fetched or read (noSchemaLoads).
    private static func resolve(_ ref: String, in root: JSONValue) -> JSONValue? {
        guard ref.hasPrefix("#") else { return nil }
        var node: JSONValue? = root
        for raw in ref.dropFirst().split(separator: "/") {
            let key = raw.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            if let index = Int(key), let list = node?.arrayValue { node = index < list.count ? list[index] : nil }
            else { node = node?[key] }
        }
        return node
    }
    private static func describe(_ value: JSONValue) -> String {
        (try? String(decoding: value.encoded(), as: UTF8.self)) ?? "the given value"
    }
}
