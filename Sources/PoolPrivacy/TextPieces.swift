import Foundation

/// A long text cut into pieces of
/// at most `size` bytes, each after the first beginning `overlap` before the one before ends. A piece
/// ends after a line's end in its second half, else after a space there (which one is the text's own
/// choice: the place whose preceding `landmarkLength` bytes hash least), else at a character's start;
/// the next begins after a line's end in the first half of the overlap, else after a space there, else
/// at a character's start. A text of `size` or less is one piece; an empty one none. The size is
/// AstrLink Guard's (the backend's `size()`): about 1,200 tokens, three of its
/// windows, so a request that stops waiting leaves the model only a short piece to finish.
enum TextPieces {
    static let size = 4 << 10
    static let overlap = 1 << 10
    static let landmarkLength = 48

    static func cut(_ t: [UInt8], size: Int = TextPieces.size) -> [Range<Int>] {
        guard !t.isEmpty else { return [] }
        guard t.count > size else { return [0..<t.count] }
        var out: [Range<Int>] = []
        var at = 0
        while true {
            var end = at + size
            if end >= t.count { out.append(at..<t.count); return out }
            let half = at + size / 2
            if let i = landmark(t, from: half, to: end, byte: 0x0A) { end = i }
            else if let i = landmark(t, from: half, to: end, byte: 0x20) { end = i }
            else { while end > half && !runeStart(t[end]) { end -= 1 } }
            out.append(at..<end)
            var next = max(at + 1, end - overlap)
            let window = next..<max(next, end - overlap / 2)
            if let i = t[window].firstIndex(of: 0x0A) { next = i + 1 }
            else if let i = t[window].firstIndex(of: 0x20) { next = i + 1 }
            else { while next < end && !runeStart(t[next]) { next += 1 } }
            at = next
        }
    }

    private static func landmark(_ t: [UInt8], from: Int, to: Int, byte: UInt8) -> Int? {
        var best: UInt64 = 0, found: Int?
        for i in from..<to where t[i] == byte {
            let e = i + 1
            var hash: UInt64 = 14695981039346656037 // FNV-1a
            for b in t[max(0, e - landmarkLength)..<e] { hash = (hash ^ UInt64(b)) &* 1099511628211 }
            if found == nil || hash < best { best = hash; found = e }
        }
        return found
    }
    private static func runeStart(_ byte: UInt8) -> Bool { byte & 0xC0 != 0x80 }
}
