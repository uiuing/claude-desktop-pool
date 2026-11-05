import Foundation

/// The pinned publisher tokenizer: precompiled SentencePiece normalization,
/// whitespace splitting, Metaspace and maximum-likelihood Unigram segmentation.
/// Original offsets are retained in UTF-16, including normalization expansions.
struct AstrLinkTokenizer: Sendable {
    struct Token: Equatable, Sendable { let id: Int; var start: Int; var end: Int }
    private struct Scalar { var value: Unicode.Scalar; var start: Int; var end: Int }
    private struct Special { let text: String; let id: Int; let trimLeft: Bool }
    private struct Entry { let id: Int; let score: Double }
    // Swift String keys merge canonically equivalent forms; token IDs must not.
    private let vocabulary: [Data: Entry]
    private let longestPiece: Int
    private let unknown: Int
    private let unknownScore: Double
    private let specials: [Special]
    private let normalizationTrie: [UInt32]
    private let replacements: [UInt8]

    init(data: Data) throws {
        guard data.count <= 2 * 1024 * 1024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let model = object["model"] as? [String: Any], model["type"] as? String == "Unigram",
              model["byte_fallback"] as? Bool == false,
              let rows = model["vocab"] as? [[Any]], !rows.isEmpty, rows.count <= 50_000,
              let unknown = model["unk_id"] as? Int, rows.indices.contains(unknown),
              let normalizer = object["normalizer"] as? [String: Any],
              normalizer["type"] as? String == "Sequence",
              let sequence = normalizer["normalizers"] as? [[String: Any]], sequence.count == 1,
              sequence[0]["type"] as? String == "Precompiled",
              let encoded = sequence[0]["precompiled_charsmap"] as? String,
              let normalized = Data(base64Encoded: encoded), normalized.count >= 4,
              let additions = object["added_tokens"] as? [[String: Any]] else { throw PrivacyFailure.modelFailed }
        var vocabulary: [Data: Entry] = [:], longest = 0, minimum = Double.infinity
        for (id, row) in rows.enumerated() {
            guard row.count == 2, let piece = row[0] as? String, !piece.isEmpty,
                  let score = row[1] as? Double, score.isFinite else { throw PrivacyFailure.modelFailed }
            vocabulary[Data(piece.utf8)] = Entry(id: id, score: score)
            longest = max(longest, piece.unicodeScalars.count); minimum = min(minimum, score)
        }
        self.vocabulary = vocabulary; longestPiece = longest
        self.unknown = unknown; unknownScore = minimum - 10
        specials = try additions.map { addition in
            guard let content = addition["content"] as? String, !content.isEmpty,
                  let id = addition["id"] as? Int, rows.indices.contains(id),
                  addition["special"] as? Bool == true,
                  let trim = addition["lstrip"] as? Bool else { throw PrivacyFailure.modelFailed }
            return Special(text: content, id: id, trimLeft: trim)
        }
        let bytes = Array(normalized)
        func word(_ at: Int) -> UInt32 {
            UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
        }
        let byteCount = Int(word(0))
        guard byteCount % 4 == 0, byteCount <= bytes.count - 4 else { throw PrivacyFailure.modelFailed }
        normalizationTrie = stride(from: 4, to: byteCount + 4, by: 4).map(word)
        replacements = Array(bytes.dropFirst(byteCount + 4))
    }

    func encode(_ text: String, tokenLimit: Int = 131_072) throws -> [Token] {
        guard text.utf8.count <= 1024 * 1024 else { throw PrivacyFailure.inputTooLarge }
        var result: [Token] = [], position = text.startIndex, offset = 0
        while position < text.endIndex {
            try Task.checkCancellation()
            var next: (range: Range<String.Index>, token: Special)?
            for token in specials {
                guard var range = text.range(of: token.text, options: .literal, range: position..<text.endIndex) else { continue }
                if token.trimLeft {
                    while range.lowerBound > position {
                        let before = text.unicodeScalars.index(before: range.lowerBound)
                        guard text.unicodeScalars[before].properties.isWhitespace else { break }
                        range = before..<range.upperBound
                    }
                }
                if next == nil || range.lowerBound < next!.range.lowerBound ||
                    (range.lowerBound == next!.range.lowerBound && range.upperBound > next!.range.upperBound) {
                    next = (range, token)
                }
            }
            let end = next?.range.lowerBound ?? text.endIndex
            let plain = String(text[position..<end])
            try encodePlain(plain, base: offset, into: &result, limit: tokenLimit)
            offset += plain.utf16.count
            guard let next else { break }
            let width = text[next.range].utf16.count
            result.append(Token(id: next.token.id, start: offset, end: offset + width))
            guard result.count <= tokenLimit else { throw PrivacyFailure.inputTooLarge }
            offset += width; position = next.range.upperBound
        }
        return result
    }

    private func encodePlain(_ text: String, base: Int, into output: inout [Token], limit: Int) throws {
        let scalars = try normalize(text, base: base)
        var index = 0
        while index < scalars.count {
            try Task.checkCancellation()
            let start = index
            if scalars[index].value.properties.isWhitespace {
                while index < scalars.count && scalars[index].value.properties.isWhitespace { index += 1 }
                if start > 0 && (48...57).contains(scalars[start - 1].value.value) {
                    for item in scalars[start..<index] { try segment([item], into: &output, limit: limit) }
                }
            } else {
                while index < scalars.count && !scalars[index].value.properties.isWhitespace { index += 1 }
                try segment(Array(scalars[start..<index]), into: &output, limit: limit)
            }
        }
    }

    private func normalize(_ text: String, base: Int) throws -> [Scalar] {
        var result: [Scalar] = [], offset = base
        for (index, character) in text.enumerated() {
            if index % 1024 == 0 { try Task.checkCancellation() }
            let value = String(character)
            let parts: [String]
            if value.utf8.count < 6, replacement(for: value) != nil { parts = [value] }
            else { parts = value.unicodeScalars.map(String.init) }
            for part in parts {
                var original: [(Int, Int)] = [], cursor = offset
                for scalar in part.unicodeScalars {
                    let width = scalar.utf16.count
                    original.append((cursor, cursor + width)); cursor += width
                }
                let mapped = Array((replacement(for: part) ?? part).unicodeScalars)
                if mapped.isEmpty, !result.isEmpty { result[result.count - 1].end = cursor }
                for (position, scalar) in mapped.enumerated() {
                    let source = original[min(position, original.count - 1)]
                    let end = position == mapped.count - 1 ? cursor : source.1
                    result.append(Scalar(value: scalar, start: source.0, end: end))
                }
                offset = cursor
            }
        }
        return result
    }

    /// SentencePiece serializes its normalization mapping as a Darts double-array.
    private func replacement(for text: String) -> String? {
        guard let root = normalizationTrie.first else { return nil }
        func offset(_ value: UInt32) -> UInt32 { (value >> 10) << ((value & 512) >> 6) }
        var node = offset(root)
        for byte in text.utf8 where byte != 0 {
            node ^= UInt32(byte)
            guard Int(node) < normalizationTrie.count else { return nil }
            let value = normalizationTrie[Int(node)]
            guard value & 0x800000ff == UInt32(byte) else { return nil }
            node ^= offset(value)
            if value & 256 != 0 {
                guard Int(node) < normalizationTrie.count else { return nil }
                let start = Int(normalizationTrie[Int(node)] & 0x7fffffff)
                guard start < replacements.count else { return nil }
                let end = replacements[start...].firstIndex(of: 0) ?? replacements.endIndex
                return String(bytes: replacements[start..<end], encoding: .utf8)
            }
        }
        return nil
    }

    private func segment(_ source: [Scalar], into output: inout [Token], limit: Int) throws {
        guard let first = source.first else { return }
        var prepared = source.map { scalar -> Scalar in
            var scalar = scalar
            if scalar.value == " " { scalar.value = "\u{2581}" }
            return scalar
        }
        if prepared[0].value != "\u{2581}" {
            prepared.insert(Scalar(value: "\u{2581}", start: first.start, end: first.end), at: 0)
        }
        var start = 0
        for index in 1...prepared.count where index == prepared.count || prepared[index].value == "\u{2581}" {
            try unigram(Array(prepared[start..<index]), into: &output, limit: limit)
            start = index
        }
    }

    private func unigram(_ word: [Scalar], into output: inout [Token], limit: Int) throws {
        struct Step { var score = -Double.infinity; var previous = 0; var id = 0 }
        var best = [Step](repeating: Step(), count: word.count + 1)
        best[0].score = 0
        for start in word.indices {
            if start % 1024 == 0 { try Task.checkCancellation() }
            var piece = Data(), single = false
            for end in (start + 1)...min(word.count, start + longestPiece) {
                piece.append(contentsOf: String(word[end - 1].value).utf8)
                guard let entry = vocabulary[piece] else { continue }
                if end == start + 1 { single = true }
                let score = best[start].score + entry.score
                if score > best[end].score { best[end] = Step(score: score, previous: start, id: entry.id) }
            }
            if !single {
                let score = best[start].score + unknownScore
                if score > best[start + 1].score { best[start + 1] = Step(score: score, previous: start, id: unknown) }
            }
        }
        var reverse: [Token] = [], end = word.count
        while end > 0 {
            let step = best[end]
            reverse.append(Token(id: step.id, start: word[step.previous].start, end: word[end - 1].end))
            end = step.previous
        }
        var previousUnknown = false
        for token in reverse.reversed() {
            if token.id == unknown, previousUnknown { output[output.count - 1].end = token.end }
            else { output.append(token) }
            previousUnknown = token.id == unknown
        }
        guard output.count <= limit else { throw PrivacyFailure.inputTooLarge }
    }
}
