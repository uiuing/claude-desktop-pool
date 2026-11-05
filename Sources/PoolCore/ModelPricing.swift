import Foundation

/// Anthropic's first-party API list prices, USD per million tokens, used only to show what the tokens
/// Pool served would cost on the API. Subscriptions are not billed per token; this is an estimate.
/// The arithmetic: a call is billed
/// whole at the tier its prompt reaches, 1-hour cache writes at their own price (`OneHourFor`: 2x
/// input for a Claude model), the rest of the writes as 5-minute ones. Pool reads no price online.
public struct ModelPrice: Equatable, Sendable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    /// Above this many prompt tokens (input, cache read and cache write) the whole call is billed at `above`.
    public var tierAbove: Int?
    public var above: (input: Double, output: Double)?
    public init(input: Double, output: Double, cacheRead: Double? = nil, tierAbove: Int? = nil, above: (input: Double, output: Double)? = nil) {
        self.input = input; self.output = output; self.cacheRead = cacheRead ?? input * 0.1
        self.tierAbove = tierAbove; self.above = above
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.input == rhs.input && lhs.output == rhs.output && lhs.cacheRead == rhs.cacheRead && lhs.tierAbove == rhs.tierAbove
            && lhs.above?.input == rhs.above?.input && lhs.above?.output == rhs.above?.output
    }

    /// What a reply costs at this price, and what it would have cost with every cached token sent as input.
    public func cost(input: Int, output: Int, cacheRead: Int, cacheWrite: Int, oneHourWrites: Int) -> (actual: Double, uncached: Double) {
        let prompt = input + cacheRead + cacheWrite
        var inputPrice = self.input, outputPrice = self.output, readPrice = self.cacheRead
        if let tierAbove, let above, prompt > tierAbove {
            readPrice *= above.input / inputPrice
            inputPrice = above.input; outputPrice = above.output
        }
        let hour = min(max(oneHourWrites, 0), max(cacheWrite, 0))
        let actual = Double(input) * inputPrice + Double(output) * outputPrice + Double(cacheRead) * readPrice
            + Double(cacheWrite - hour) * inputPrice * 1.25 + Double(hour) * inputPrice * 2
        let uncached = Double(prompt) * inputPrice + Double(output) * outputPrice
        return (actual / 1_000_000, uncached / 1_000_000)
    }
}

public enum ModelPricing {
    /// When the table was last checked against Anthropic's pricing page.
    public static let asOf = "2026-10"

    /// The price of a model id as the official client names it (`claude-opus-5-5`, `claude-opus-5-5[1m]`,
    /// `claude-sonnet-4-5-20250929`); nil for a model this table does not know, which is then shown unpriced.
    public static func price(for id: String) -> ModelPrice? {
        let name = canonical(id)
        for (prefix, price) in table where name == prefix || name.hasPrefix(prefix + "-") { return price }
        return nil
    }

    /// Lower case, without a context suffix such as `[1m]` or a Bedrock/Vertex style prefix.
    public static func canonical(_ id: String) -> String {
        var name = id.lowercased()
        if let bracket = name.firstIndex(of: "[") { name = String(name[..<bracket]) }
        if let range = name.range(of: "claude-") { name = String(name[range.lowerBound...]) }
        if let at = name.firstIndex(of: "@") { name = String(name[..<at]) }
        return name
    }

    /// Longest prefixes first, so `claude-opus-5-5` is not read as `claude-opus-5`.
    private static let table: [(String, ModelPrice)] = [
        ("claude-fable-5-1", .init(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-fable-5", .init(input: 10, output: 50)),
        ("claude-mythos-5-1", .init(input: 10, output: 50, cacheRead: 0.25)),
        ("claude-opus-5-5", .init(input: 4, output: 20, cacheRead: 0.20)),
        ("claude-opus-5", .init(input: 5, output: 25)),
        ("claude-opus-4-8", .init(input: 5, output: 25)),
        ("claude-opus-4-7", .init(input: 5, output: 25)),
        ("claude-opus-4-6", .init(input: 5, output: 25)),
        ("claude-opus-4-5", .init(input: 5, output: 25)),
        ("claude-sonnet-5-5", .init(input: 2, output: 10, cacheRead: 0.20)),
        ("claude-sonnet-5", .init(input: 2, output: 10)),
        ("claude-sonnet-4-6", .init(input: 3, output: 15)),
        ("claude-sonnet-4-5", .init(input: 3, output: 15)),
        ("claude-haiku-5-5", .init(input: 0.10, output: 0.50, tierAbove: 100_000, above: (0.50, 2.50))),
        ("claude-haiku-4-5", .init(input: 1, output: 5)),
    ].sorted { $0.0.count > $1.0.count }
}
