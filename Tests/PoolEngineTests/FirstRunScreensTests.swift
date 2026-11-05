import Foundation
import XCTest
@testable import PoolEngine

final class FirstRunScreensTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    func testOnboardingScreensAreAnsweredOnlyAfterTheyStayDrawn() {
        var screens = FirstRunScreens()
        let theme = "Let's get started.\n\nChoose the text style that looks best with your terminal\n❯ 1. Dark mode"
        XCTAssertEqual(screens.respond(to: theme, at: at(0)), .none)
        XCTAssertEqual(screens.respond(to: theme, at: at(0.1)), .none)
        XCTAssertEqual(screens.respond(to: theme, at: at(0.4)), .send(Data("\r".utf8)))
        let notes = "Security notes:\n 1. Claude can make mistakes\n\nPress Enter to continue…"
        XCTAssertEqual(screens.respond(to: notes, at: at(0.5)), .none)
        XCTAssertEqual(screens.respond(to: notes, at: at(0.9)), .send(Data("\r".utf8)))
        let setup = "Use Claude Code's terminal setup?\n Enter to confirm · Esc to skip"
        XCTAssertEqual(screens.respond(to: setup, at: at(1)), .none)
        XCTAssertEqual(screens.respond(to: setup, at: at(1.4)), .send(Data("\u{1B}".utf8)))
        XCTAssertEqual(screens.respond(to: "❯ ", at: at(2)), .none)
    }

    func testTrustMovesToYesBeforePressingReturn() {
        var screens = FirstRunScreens()
        let no = "Do you trust the files in this folder?\n  Yes, I trust this folder\n❯ No, exit"
        XCTAssertEqual(screens.respond(to: no, at: at(0)), .send(Data("\u{1B}[B".utf8)))
        XCTAssertEqual(screens.respond(to: no, at: at(0.5)), .none, "Down is not repeated while the screen redraws")
        let yes = "Do you trust the files in this folder?\n❯ Yes, I trust this folder\n  No, exit"
        XCTAssertEqual(screens.respond(to: yes, at: at(0.6)), .none)
        XCTAssertEqual(screens.respond(to: yes, at: at(1)), .send(Data("\r".utf8)))
    }

    func testSignInIsNeverAnsweredAndRepeatedScreensStop() {
        var screens = FirstRunScreens()
        XCTAssertEqual(screens.respond(to: "Select login method:\n❯ 1. Claude account with subscription", at: at(0)), .signInRequired)
        let theme = "Choose the text style that looks best with your terminal"
        var sent = 0, time = 0.0
        while true {
            time += 0.4
            let outcome = screens.respond(to: theme, at: at(time))
            if outcome == .stuck { break }
            if case .send = outcome { sent += 1 }
            XCTAssertLessThan(time, 10)
        }
        XCTAssertEqual(sent, 3)
    }

    func testOrdinaryPromptsAreLeftToTheUser() {
        var screens = FirstRunScreens()
        for text in ["Allow this session to use the Desktop tools?\n❯ 1. Allow once", "You're now using usage credits. Continue?\n❯ Yes"] {
            XCTAssertEqual(screens.respond(to: text, at: at(0)), .none)
            XCTAssertEqual(screens.respond(to: text, at: at(5)), .none)
        }
    }
}
