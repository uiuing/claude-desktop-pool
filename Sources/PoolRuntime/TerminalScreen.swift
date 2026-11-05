import Foundation

/// A bounded, plain-text view of an owned PTY. Handles normal VT cursor movement, erase,
/// insert/delete, scrolling regions, saved cursors and alternate screens. SGR, device queries,
/// cursor visibility and string controls (including OSC links/titles) produce no visible text.
/// This observes a terminal and does not execute escape sequences. `replies(to:)` gives the
/// fixed answers an ordinary terminal sends to cursor-position and device-attribute queries.
public struct TerminalScreen: Sendable {
    /// What a plain VT terminal answers to the queries in this output, so a child that waits on
    /// them does not stall. The cursor answer is the fixed home position.
    public static func replies(to output: Data) -> Data? {
        var reply = Data()
        if output.range(of: Data("\u{1B}[6n".utf8)) != nil { reply += Data("\u{1B}[1;1R".utf8) }
        if output.range(of: Data("\u{1B}[c".utf8)) != nil || output.range(of: Data("\u{1B}[0c".utf8)) != nil {
            reply += Data("\u{1B}[?62;c".utf8)
        }
        return reply.isEmpty ? nil : reply
    }

    private struct Cell: Sendable {
        var text = " "
        var width = 1
        static let continuation = Cell(text: "", width: 0)
    }
    private struct Screen: Sendable {
        var cells: [[Cell]]
        var row = 0, column = 0
        var savedRow = 0, savedColumn = 0
        var top = 0, bottom: Int
        var wrap = true, wrapPending = false, origin = false
        init(columns: Int, rows: Int) {
            cells = Array(repeating: Array(repeating: Cell(), count: columns), count: rows)
            bottom = rows - 1
        }
    }
    private enum Parser: Sendable {
        case text, escape, charset, csi, discardCSI, string, stringEscape
    }
    private let columns: Int, rows: Int
    private var screen: Screen
    private var mainScreen: Screen?
    private var parser = Parser.text
    private var parameters = ""
    private var utf8: [UInt8] = []
    private var utf8Length = 0
    private var history: [String] = []
    private var historyBytes = 0
    /// Whether the child currently asks for pasted text to be wrapped (DECSET 2004).
    public private(set) var bracketedPaste = false

    public init(columns: Int = 180, rows: Int = 50) {
        self.columns = min(400, max(1, columns)); self.rows = min(200, max(1, rows))
        screen = Screen(columns: self.columns, rows: self.rows)
    }

    public mutating func feed(_ bytes: Data) {
        for byte in bytes { consume(byte) }
    }

    public var text: String {
        var lines = mainScreen == nil ? history : []
        lines += screen.cells.map(Self.render)
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    /// Current viewport alone, for observations that must not match an old prompt in scrollback.
    public var visibleText: String {
        var lines = screen.cells.map(Self.render)
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private mutating func consume(_ byte: UInt8) {
        switch parser {
        case .string:
            if byte == 7 { parser = .text }
            else if byte == 27 { parser = .stringEscape }
        case .stringEscape:
            parser = byte == 92 || byte == 7 ? .text : (byte == 27 ? .stringEscape : .string)
        case .charset: parser = .text
        case .discardCSI:
            if (64...126).contains(byte) { parser = .text }
            else if byte == 27 { parser = .escape }
        case .csi:
            if (64...126).contains(byte) {
                let command = parameters; parameters = ""; parser = .text
                control(command, final: byte)
            } else if (32...63).contains(byte), parameters.utf8.count < 128 {
                parameters.append(Character(UnicodeScalar(byte)))
            } else if byte == 27 { parameters = ""; parser = .escape }
            else { parameters = ""; parser = .discardCSI }
        case .escape:
            parser = .text
            switch byte {
            case 91: parameters = ""; parser = .csi
            case 93, 80, 88, 94, 95: parser = .string
            case 40, 41, 42, 43, 35: parser = .charset
            case 55: saveCursor()
            case 56: restoreCursor()
            case 68: lineFeed()
            case 69: screen.column = 0; lineFeed()
            case 77:
                if screen.row == screen.top { scrollDown(1) } else { screen.row = max(0, screen.row - 1) }
            case 99:
                screen = Screen(columns: columns, rows: rows); mainScreen = nil
                history.removeAll(); historyBytes = 0
            case 27: parser = .escape
            default: break
            }
        case .text: ordinary(byte)
        }
    }

    private mutating func ordinary(_ byte: UInt8) {
        if !utf8.isEmpty {
            if (128...191).contains(byte) {
                utf8.append(byte)
                if utf8.count == utf8Length {
                    let decoded = String(bytes: utf8, encoding: .utf8)
                    utf8.removeAll(keepingCapacity: true)
                    put(decoded?.unicodeScalars.first ?? "\u{fffd}")
                }
                return
            }
            utf8.removeAll(keepingCapacity: true); put("\u{fffd}")
        }
        switch byte {
        case 27: parser = .escape
        case 13: screen.column = 0; screen.wrapPending = false
        case 10, 11, 12: lineFeed()
        case 8: screen.column = max(0, screen.column - 1); screen.wrapPending = false
        case 9: screen.column = min(columns - 1, ((screen.column / 8) + 1) * 8); screen.wrapPending = false
        case 0...31, 127: break
        case 32...126: put(UnicodeScalar(byte))
        case 194...223: utf8 = [byte]; utf8Length = 2
        case 224...239: utf8 = [byte]; utf8Length = 3
        case 240...244: utf8 = [byte]; utf8Length = 4
        default: put("\u{fffd}")
        }
    }

    private mutating func put(_ scalar: UnicodeScalar) {
        if scalar.properties.generalCategory == .control { return }
        var previous = screen.wrapPending ? screen.column : screen.column - 1
        if previous >= 0 {
            if screen.cells[screen.row][previous].width == 0 { previous -= 1 }
            if previous >= 0 {
                let old = screen.cells[screen.row][previous]
                let joined = old.text + String(scalar)
                if joined.count == 1 {
                    // A malformed stream must not grow one combining cluster without a bound.
                    guard joined.utf8.count <= 128 else { return }
                    let width = min(Self.width(joined), columns - previous)
                    if width > old.width {
                        clearCell(row: screen.row, column: previous + 1)
                        screen.cells[screen.row][previous + 1] = .continuation
                        advance(from: previous, width: width)
                    }
                    screen.cells[screen.row][previous] = Cell(text: joined, width: width)
                    return
                }
            }
        }
        var value = String(scalar)
        if Self.isCombining(scalar) { value = " " + value }
        var width = min(Self.width(value), columns)
        if screen.wrapPending {
            if screen.wrap { screen.column = 0; lineFeed() }
            screen.wrapPending = false
        }
        if width == 2 && screen.column == columns - 1 {
            if screen.wrap { screen.column = 0; lineFeed() } else { width = 1 }
        }
        clearCell(row: screen.row, column: screen.column)
        if width == 2 { clearCell(row: screen.row, column: screen.column + 1) }
        let at = screen.column
        screen.cells[screen.row][at] = Cell(text: value, width: width)
        if width == 2 { screen.cells[screen.row][at + 1] = .continuation }
        advance(from: at, width: width)
    }
    private mutating func advance(from column: Int, width: Int) {
        screen.column = min(columns - 1, column + width)
        screen.wrapPending = column + width >= columns
    }
    private static func isCombining(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark, .format: return true
        default: return false
        }
    }
    private static func width(_ text: String) -> Int {
        if text.unicodeScalars.contains(where: { $0.value == 0xfe0f }), text.unicodeScalars.contains(where: { $0.properties.isEmoji }) { return 2 }
        for scalar in text.unicodeScalars {
            if scalar.properties.isEmojiPresentation { return 2 }
            switch scalar.value {
            case 0x1100...0x115f, 0x2329...0x232a, 0x2e80...0xa4cf, 0xac00...0xd7a3,
                 0xf900...0xfaff, 0xfe10...0xfe19, 0xfe30...0xfe6f, 0xff01...0xff60,
                 0xffe0...0xffe6, 0x20000...0x3fffd: return 2
            default: break
            }
        }
        return 1
    }

    private mutating func control(_ raw: String, final: UInt8) {
        // Color/style sequences need no parameter parsing in a plain-text view.
        if final == 109 { return }
        let privateMode = raw.first == "?"
        let numbers = privateMode ? String(raw.dropFirst()) : raw
        guard numbers.utf8.allSatisfy({ (48...57).contains($0) || $0 == 59 }) else { return }
        let values = numbers.split(separator: ";", omittingEmptySubsequences: false).map { min(10_000, Int($0) ?? 0) }
        let count = max(1, values.first ?? 0)
        let lower = screen.origin ? screen.top : 0, upper = screen.origin ? screen.bottom : rows - 1
        if privateMode {
            guard final == 104 || final == 108 else { return }
            for value in values { setMode(value, enabled: final == 104) }
            return
        }
        screen.wrapPending = false
        switch final {
        case 65: screen.row = max(lower, screen.row - count)
        case 66, 101: screen.row = min(upper, screen.row + count)
        case 67, 97: screen.column = min(columns - 1, screen.column + count)
        case 68: screen.column = max(0, screen.column - count)
        case 69: screen.row = min(upper, screen.row + count); screen.column = 0
        case 70: screen.row = max(lower, screen.row - count); screen.column = 0
        case 71, 96: screen.column = min(columns - 1, count - 1)
        case 100: screen.row = min(upper, lower + count - 1)
        case 72, 102:
            screen.row = min(upper, lower + count - 1)
            screen.column = min(columns - 1, max(1, values.count > 1 ? values[1] : 1) - 1)
        case 74: eraseDisplay(values.first ?? 0)
        case 75:
            switch values.first ?? 0 {
            case 0: erase(row: screen.row, from: screen.column, to: columns - 1)
            case 1: erase(row: screen.row, from: 0, to: screen.column)
            case 2: erase(row: screen.row, from: 0, to: columns - 1)
            default: break
            }
        case 88: erase(row: screen.row, from: screen.column, to: min(columns - 1, screen.column + count - 1))
        case 64, 80:
            let amount = min(count, columns - screen.column)
            if final == 64 {
                screen.cells[screen.row].insert(contentsOf: Array(repeating: Cell(), count: amount), at: screen.column)
                screen.cells[screen.row].removeLast(amount)
            } else {
                screen.cells[screen.row].removeSubrange(screen.column..<(screen.column + amount))
                screen.cells[screen.row] += Array(repeating: Cell(), count: amount)
            }
            normalize(row: screen.row)
        case 76, 77:
            guard (screen.top...screen.bottom).contains(screen.row) else { return }
            for _ in 0..<min(count, screen.bottom - screen.row + 1) {
                if final == 76 { screen.cells.remove(at: screen.bottom); screen.cells.insert(blankRow(), at: screen.row) }
                else { screen.cells.remove(at: screen.row); screen.cells.insert(blankRow(), at: screen.bottom) }
            }
        case 83: scrollUp(count)
        case 84: scrollDown(count)
        case 114:
            let top = max(1, values.first ?? 1) - 1
            let bottom = values.count > 1 && values[1] > 0 ? values[1] - 1 : rows - 1
            if top >= 0, top < bottom, bottom < rows {
                screen.top = top; screen.bottom = bottom
                screen.row = screen.origin ? top : 0; screen.column = 0
            }
        case 115: saveCursor()
        case 117: restoreCursor()
        default: break
        }
    }
    private mutating func setMode(_ value: Int, enabled: Bool) {
        switch value {
        case 47, 1047, 1049:
            if enabled, mainScreen == nil { mainScreen = screen; screen = Screen(columns: columns, rows: rows) }
            else if !enabled, let saved = mainScreen { screen = saved; mainScreen = nil }
        case 1048: if enabled { saveCursor() } else { restoreCursor() }
        case 2004: bracketedPaste = enabled
        case 7: screen.wrap = enabled; screen.wrapPending = false
        case 6: screen.origin = enabled; screen.row = enabled ? screen.top : 0; screen.column = 0; screen.wrapPending = false
        default: break
        }
    }
    private mutating func eraseDisplay(_ mode: Int) {
        switch mode {
        case 0:
            erase(row: screen.row, from: screen.column, to: columns - 1)
            if screen.row + 1 < rows { for row in (screen.row + 1)..<rows { screen.cells[row] = blankRow() } }
        case 1:
            if screen.row > 0 { for row in 0..<screen.row { screen.cells[row] = blankRow() } }
            erase(row: screen.row, from: 0, to: screen.column)
        case 2: screen.cells = Array(repeating: blankRow(), count: rows)
        case 3: if mainScreen == nil { history.removeAll(); historyBytes = 0 }
        default: break
        }
    }
    private mutating func erase(row: Int, from: Int, to: Int) {
        guard from <= to else { return }
        for column in from...to { clearCell(row: row, column: column) }
    }
    private mutating func clearCell(row: Int, column: Int) {
        let cell = screen.cells[row][column]
        if cell.width == 0, column > 0 { screen.cells[row][column - 1] = Cell() }
        if cell.width == 2, column + 1 < columns { screen.cells[row][column + 1] = Cell() }
        screen.cells[row][column] = Cell()
    }
    private mutating func normalize(row: Int) {
        for column in 0..<columns {
            if screen.cells[row][column].width == 0 {
                if column == 0 || screen.cells[row][column - 1].width != 2 { screen.cells[row][column] = Cell() }
            } else if screen.cells[row][column].width == 2 {
                if column + 1 == columns { screen.cells[row][column] = Cell() }
                else { screen.cells[row][column + 1] = .continuation }
            }
        }
    }
    private mutating func saveCursor() { screen.savedRow = screen.row; screen.savedColumn = screen.column }
    private mutating func restoreCursor() { screen.row = screen.savedRow; screen.column = screen.savedColumn; screen.wrapPending = false }
    private mutating func lineFeed() {
        screen.wrapPending = false
        if screen.row == screen.bottom { scrollUp(1) } else { screen.row = min(rows - 1, screen.row + 1) }
    }
    private mutating func scrollUp(_ count: Int) {
        for _ in 0..<min(count, screen.bottom - screen.top + 1) {
            let line = screen.cells.remove(at: screen.top)
            if mainScreen == nil, screen.top == 0, screen.bottom == rows - 1 { remember(Self.render(line)) }
            screen.cells.insert(blankRow(), at: screen.bottom)
        }
    }
    private mutating func scrollDown(_ count: Int) {
        for _ in 0..<min(count, screen.bottom - screen.top + 1) {
            screen.cells.remove(at: screen.bottom); screen.cells.insert(blankRow(), at: screen.top)
        }
    }
    private mutating func remember(_ line: String) {
        history.append(line); historyBytes += line.utf8.count
        while history.count > 1000 || historyBytes > 256 * 1024 { historyBytes -= history.removeFirst().utf8.count }
    }
    private func blankRow() -> [Cell] { Array(repeating: Cell(), count: columns) }
    private static func render(_ row: [Cell]) -> String {
        var end = row.count
        while end > 0, row[end - 1].width == 1, row[end - 1].text == " " { end -= 1 }
        return row.prefix(end).map(\.text).joined()
    }
}
