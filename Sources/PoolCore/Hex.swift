import Foundation

public extension Sequence where Element == UInt8 {
    /// The bytes as lowercase hexadecimal, as `String(format: "%02x")` joined writes them, without a
    /// formatted string per byte: redaction keys every text of a request this way, more than once.
    var lowercaseHex: String {
        let digits: [UInt8] = Array("0123456789abcdef".utf8)
        var out: [UInt8] = []
        out.reserveCapacity(underestimatedCount * 2)
        for byte in self { out.append(digits[Int(byte >> 4)]); out.append(digits[Int(byte & 0x0f)]) }
        return String(decoding: out, as: UTF8.self)
    }
}
