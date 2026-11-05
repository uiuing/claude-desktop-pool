import Foundation

/// Collects links from the original owned PTY bytes, before viewport wrapping inserts newlines.
/// Tokens and escape sequences span chunks; links are kept in memory only, newest first.
public struct TerminalLinkCollector: Sendable {
    private enum Parser: Equatable, Sendable { case text, escape, csi, discardCSI, osc, oscEscape, string, stringEscape, charset }
    private static let maximumURLBytes = 16 * 1024
    private static let expression = try! NSRegularExpression(pattern: #"(?i)(?<![A-Za-z0-9_/:])https?://[^\s<>"'`]+"#)
    private var parser = Parser.text
    private var token = Data()
    private var tokenOverflow = false
    private var control = Data()
    private var controlOverflow = false
    private var hyperlink = false
    public private(set) var links: [URL] = []

    public init() {}

    public mutating func feed(_ data: Data) {
        for byte in data { consume(byte) }
    }

    /// Called only at actual stream EOF, so an arbitrary PTY chunk cannot publish a truncated URL.
    public mutating func finish() {
        if parser == .text { completeToken() } else { discardToken() }
        parser = .text; control = Data(); hyperlink = false; controlOverflow = false
    }

    private mutating func consume(_ byte: UInt8) {
        switch parser {
        case .text:
            switch byte {
            case 27: parser = .escape
            case 8: discardToken()
            case 9...13, 32, 34, 39, 60, 62, 96: completeToken()
            case 0...31, 127: break
            default:
                guard !hyperlink, !tokenOverflow else { return }
                if token.count < Self.maximumURLBytes { token.append(byte) }
                else { token.removeAll(keepingCapacity: true); tokenOverflow = true }
            }
        case .escape:
            switch byte {
            case 91: control.removeAll(keepingCapacity: true); parser = .csi
            case 93: control.removeAll(keepingCapacity: true); controlOverflow = false; parser = .osc
            case 80, 88, 94, 95: parser = .string
            case 40, 41, 42, 43, 35: parser = .charset
            case 27: break
            default: discardToken(); parser = .text
            }
        case .charset: discardToken(); parser = .text
        case .csi:
            if (64...126).contains(byte) {
                // SGR, terminal modes and cursor style do not split visible URL text.
                if ![UInt8(109), 104, 108, 113].contains(byte) { discardToken() }
                control.removeAll(keepingCapacity: true); parser = .text
            } else if (32...63).contains(byte), control.count < 128 { control.append(byte) }
            else { discardToken(); parser = byte == 27 ? .escape : .discardCSI }
        case .discardCSI:
            if (64...126).contains(byte) { parser = .text }
            else if byte == 27 { parser = .escape }
        case .osc:
            if byte == 7 { completeOSC(); parser = .text }
            else if byte == 27 { parser = .oscEscape }
            else if !controlOverflow {
                if control.count < Self.maximumURLBytes + 1024 { control.append(byte) }
                else { control.removeAll(keepingCapacity: true); controlOverflow = true }
            }
        case .oscEscape:
            if byte == 92 || byte == 7 { completeOSC(); parser = .text }
            else if byte == 27 { controlOverflow = true }
            else { controlOverflow = true; parser = .osc }
        case .string:
            if byte == 7 { parser = .text }
            else if byte == 27 { parser = .stringEscape }
        case .stringEscape:
            parser = byte == 92 || byte == 7 ? .text : (byte == 27 ? .stringEscape : .string)
        }
    }

    private mutating func completeToken() {
        defer { discardToken() }
        guard !hyperlink, !tokenOverflow, let text = String(data: token, encoding: .utf8) else { return }
        let source = text as NSString
        for match in Self.expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            var candidate = source.substring(with: match.range)
            for (opening, closing) in [("(", ")"), ("[", "]"), ("{", "}")] {
                var unmatched = candidate.filter({ String($0) == closing }).count - candidate.filter({ String($0) == opening }).count
                while candidate.hasSuffix(closing) && unmatched > 0 {
                    candidate.removeLast(); unmatched -= 1
                }
            }
            if !candidate.contains("?") && !candidate.contains("#") {
                while let last = candidate.last, ".,;:!".contains(last) { candidate.removeLast() }
            }
            append(candidate)
        }
    }

    private mutating func completeOSC() {
        defer { control.removeAll(keepingCapacity: true); controlOverflow = false }
        guard !controlOverflow, let text = String(data: control, encoding: .utf8), text.hasPrefix("8;"),
              let separator = text.dropFirst(2).firstIndex(of: ";") else { return }
        let destination = String(text[text.index(after: separator)...])
        discardToken()
        hyperlink = !destination.isEmpty
        if !destination.isEmpty { append(destination) }
    }

    private mutating func discardToken() { token.removeAll(keepingCapacity: true); tokenOverflow = false }

    private mutating func append(_ text: String) {
        guard text.utf8.count <= Self.maximumURLBytes,
              !text.contains("\\"),
              !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format || CharacterSet.whitespacesAndNewlines.contains($0) }),
              Self.validPercentEscapes(text), let url = URL(string: text),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true else { return }
        links.removeAll { $0.absoluteString == url.absoluteString }
        links.insert(url, at: 0)
        if links.count > 8 { links.removeLast(links.count - 8) }
    }

    private static func validPercentEscapes(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        func hex(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte) }
        var index = 0
        while index < bytes.count {
            if bytes[index] == 37 {
                guard index + 2 < bytes.count, hex(bytes[index + 1]), hex(bytes[index + 2]) else { return false }
                index += 3
            } else { index += 1 }
        }
        return true
    }
}
