import Foundation
import XCTest
@testable import PoolRuntime

final class TerminalScreenTests: XCTestCase {
    func testPromptRepaintReplacesPreviousMenu() {
        var screen = TerminalScreen(columns: 40, rows: 8)
        screen.feed(Data("Choose an account\r\n> First\r\n  Second".utf8))
        screen.feed(Data("\u{1b}[2A\r\u{1b}[JChoose an account\r\n  First\r\n> Second".utf8))
        XCTAssertEqual(screen.text, "Choose an account\n  First\n> Second")
    }
    func testCarriageReturnEraseAndBackspace() {
        var screen = TerminalScreen(columns: 30, rows: 4)
        screen.feed(Data("Waiting for sign in\rReady\u{1b}[K".utf8))
        XCTAssertEqual(screen.text, "Ready")
        screen.feed(Data("!\u{8}?".utf8))
        XCTAssertEqual(screen.text, "Ready?")
    }
    func testCursorAddressingAndDisplayEraseDoNotMoveCursor() {
        var screen = TerminalScreen(columns: 15, rows: 4)
        screen.feed(Data("Old\u{1b}[3;4HNew\u{1b}[2JX".utf8))
        XCTAssertEqual(screen.text, "\n\n      X")
        screen.feed(Data("\u{1b}[HHome".utf8))
        XCTAssertEqual(screen.text, "Home\n\n      X")
    }
    func testSplitUTF8AndSplitControlSequences() {
        var screen = TerminalScreen(columns: 12, rows: 3)
        let bytes = Data("\u{4e2d}\u{6587} e\u{301}".utf8)
        for byte in bytes { screen.feed(Data([byte])) }
        XCTAssertEqual(screen.text, "\u{4e2d}\u{6587} e\u{301}")
        for byte in Data("\u{1b}[1;1H\u{1b}[2KDone".utf8) { screen.feed(Data([byte])) }
        XCTAssertEqual(screen.text, "Done")
    }
    func testWideCharactersUseTwoColumnsAndEraseWholeCells() {
        var screen = TerminalScreen(columns: 6, rows: 3)
        screen.feed(Data("\u{4e2d}\u{6587}A".utf8))
        screen.feed(Data("\u{1b}[1;3HX".utf8))
        XCTAssertEqual(screen.text, "\u{4e2d}X A")
        screen.feed(Data("\u{1b}[1;2H\u{1b}[X".utf8))
        XCTAssertEqual(screen.text, "  X A")
    }
    func testCombiningAndEmojiSequencesKeepCursorPosition() {
        var screen = TerminalScreen(columns: 12, rows: 3)
        screen.feed(Data("e\u{301}X\r\u{1b}[CX".utf8))
        XCTAssertEqual(screen.text, "e\u{301}X")
        screen.feed(Data("\u{1b}[2J\u{1b}[H\u{1f469}\u{200d}\u{1f4bb}X\u{1b}[1;3HY".utf8))
        XCTAssertEqual(screen.text, "\u{1f469}\u{200d}\u{1f4bb}Y")
    }
    func testWrapAndScrollingPreserveBoundedHistory() {
        var screen = TerminalScreen(columns: 4, rows: 2)
        screen.feed(Data("abcdefghI".utf8))
        XCTAssertEqual(screen.text, "abcd\nefgh\nI")
        XCTAssertEqual(screen.visibleText, "efgh\nI")
        screen.feed(Data("\u{1b}[3J".utf8))
        XCTAssertEqual(screen.text, "efgh\nI")
    }
    func testAlternateScreenRestoresMainAndDropsItsScrollback() {
        var screen = TerminalScreen(columns: 20, rows: 2)
        screen.feed(Data("Original\u{1b}[?1049hMenu\r\nOption\r\nSelected".utf8))
        XCTAssertEqual(screen.text, "Option\nSelected")
        screen.feed(Data("\u{1b}[?1049l!".utf8))
        XCTAssertEqual(screen.text, "Original!")
    }
    func testOSCAndDCSAreIgnoredWithoutLeakingTheirPayload() {
        var screen = TerminalScreen(columns: 40, rows: 4)
        screen.feed(Data("\u{1b}]0;hidden-title\u{7}Open \u{1b}]8;;https://untrusted.invalid/path\u{1b}\\link\u{1b}]8;;\u{1b}\\".utf8))
        screen.feed(Data("\u{1b}Pignored-payload\u{1b}\\ done".utf8))
        XCTAssertEqual(screen.text, "Open link done")
        XCTAssertFalse(screen.text.contains("untrusted"))
    }
    func testColorsCursorVisibilityAndSynchronizedOutputDoNotPrint() {
        var screen = TerminalScreen()
        screen.feed(Data("\u{1b}[?25l\u{1b}[?2026h\u{1b}[38;2;200;100;50mReady\u{1b}[0m\u{1b}[?2026l\u{1b}[?25h".utf8))
        XCTAssertEqual(screen.text, "Ready")
    }
    func testInsertDeleteAndSavedCursor() {
        var screen = TerminalScreen(columns: 20, rows: 4)
        screen.feed(Data("ac\r\u{1b}[C\u{1b}[@b\u{1b}7\u{1b}[3;1HOther\u{1b}8!".utf8))
        XCTAssertEqual(screen.text, "ab!\n\nOther")
        screen.feed(Data("\r\u{1b}[P".utf8))
        XCTAssertEqual(screen.text, "b!\n\nOther")
    }
    func testScrollingRegionLeavesHeaderInPlace() {
        var screen = TerminalScreen(columns: 12, rows: 4)
        screen.feed(Data("Header\r\nOne\r\nTwo\r\nThree\u{1b}[2;4r\u{1b}[4;1H\nFour".utf8))
        XCTAssertEqual(screen.text, "Header\nTwo\nThree\nFour")
    }
    func testMalformedUTF8AndUnboundedControlInputRemainBounded() {
        var screen = TerminalScreen(columns: 20, rows: 2)
        screen.feed(Data([0xe4, 0x41]))
        XCTAssertEqual(screen.text, "\u{fffd}A")
        screen.feed(Data("\u{1b}]0;".utf8) + Data(repeating: 65, count: 100_000) + Data([7]))
        screen.feed(Data("\r\u{1b}[2KSafe".utf8))
        XCTAssertEqual(screen.text, "Safe")
        screen.feed(Data("\u{1b}[".utf8) + Data(repeating: 49, count: 100_000) + Data("m!".utf8))
        XCTAssertEqual(screen.text, "Safe!")
        for _ in 0..<1200 { screen.feed(Data("\r\nFixture".utf8)) }
        XCTAssertLessThanOrEqual(screen.text.split(separator: "\n", omittingEmptySubsequences: false).count, 1002)
        XCTAssertLessThan(screen.text.utf8.count, 20_100)
    }

    func testOrdinaryTerminalQueriesGetFixedAnswers() {
        XCTAssertEqual(TerminalScreen.replies(to: Data("text\u{1b}[6n".utf8)), Data("\u{1b}[1;1R".utf8))
        XCTAssertEqual(TerminalScreen.replies(to: Data("\u{1b}[c".utf8)), Data("\u{1b}[?62;c".utf8))
        XCTAssertNil(TerminalScreen.replies(to: Data("\u{1b}[31mplain".utf8)))
    }
}
