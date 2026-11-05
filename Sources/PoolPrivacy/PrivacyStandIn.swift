import Foundation
import PoolCore

/// What a value goes to the model as. Pool holds each conversation's values itself, so a stand-in is a
/// number within the conversation, not a hash: short,
/// and the same value is the same stand-in on every turn.
///
/// What the model acts on keeps its shape, because told `ssh {{IP_…}}` a model asks for the address
/// and a name reads as one. What it should only carry is a tag that says its kind.
enum PrivacyStandIn {
    static func text(for category: PrivacyCategory, number: Int) -> String {
        switch category {
        case .username: return "user-\(number)"
        case .hostname: return "host-\(number)"
        case .ip: return "public-ip-\(number)"
        case .bucket: return "bucket-\(number)"
        default: return "{{\(category.rawValue)_\(number)}}"
        }
    }

    /// A stand-in written like a name is one only as a whole word: `user-1` is not in `user-10` or `my-user-1`.
    static func bare(_ token: String) -> Bool { token.first?.isLetter == true }
    static func wordCharacter(_ character: Character?) -> Bool {
        guard let character, character.isASCII else { return false }
        return character.isLetter || character.isNumber || character == "_" || character == "-"
    }

    /// Each place `token` stands as a stand-in in `text`.
    static func ranges(of token: String, in text: NSString) -> [NSRange] {
        var found: [NSRange] = [], rest = NSRange(location: 0, length: text.length)
        let bare = bare(token)
        while rest.length > 0 {
            let range = text.range(of: token, options: .literal, range: rest)
            if range.location == NSNotFound { break }
            rest = NSRange(location: NSMaxRange(range), length: text.length - NSMaxRange(range))
            if bare {
                let before = range.location > 0 ? text.substring(with: NSRange(location: range.location - 1, length: 1)).first : nil
                let after = NSMaxRange(range) < text.length ? text.substring(with: NSRange(location: NSMaxRange(range), length: 1)).first : nil
                if wordCharacter(before) || before == "." || wordCharacter(after) { continue }
            }
            found.append(range)
        }
        return found
    }
}
