import Foundation
import XCTest
@testable import PoolRuntime

final class TerminalLinkCollectorTests: XCTestCase {
    private let authorization = "https://auth.synthetic.invalid/oauth/authorize?client_id=synthetic-client&redirect_uri=http%3A%2F%2Flocalhost%3A43123%2Fcallback&state=synthetic-state&code_challenge=synthetic_challenge-123"

    func testChunksDoNotPublishPartialAuthorizationURL() {
        var collector = TerminalLinkCollector()
        let split = authorization.index(authorization.startIndex, offsetBy: 65)
        collector.feed(Data(("Open this URL: " + String(authorization[..<split])).utf8))
        XCTAssertTrue(collector.links.isEmpty)
        collector.feed(Data(authorization[split...].utf8))
        XCTAssertTrue(collector.links.isEmpty)
        collector.feed(Data("\r\n".utf8))
        XCTAssertEqual(collector.links.map(\.absoluteString), [authorization])
    }

    func testEveryByteBoundaryIncludingUTF8AndPercentEscapes() {
        let destination = "https://auth.synthetic.invalid/caf%C3%A9?state=synthetic%2Fstate%3D"
        let output = Data(("\u{767b}\u{5f55}: " + destination + "\n").utf8)
        for index in 0...output.count {
            var collector = TerminalLinkCollector()
            collector.feed(Data(output.prefix(index))); collector.feed(Data(output.dropFirst(index)))
            XCTAssertEqual(collector.links.map(\.absoluteString), [destination])
        }
    }

    func testViewportWrapDoesNotSplitTheOriginalLongURL() {
        let destination = authorization + "&scope=" + String(repeating: "synthetic-scope_", count: 100)
        var collector = TerminalLinkCollector(), screen = TerminalScreen(columns: 30, rows: 6)
        let output = Data(destination.utf8)
        for offset in stride(from: 0, to: output.count, by: 17) {
            let part = Data(output[offset..<min(output.count, offset + 17)])
            collector.feed(part); screen.feed(part)
        }
        XCTAssertTrue(screen.text.contains("\n"))
        XCTAssertFalse(screen.text.contains(destination))
        XCTAssertTrue(collector.links.isEmpty)
        collector.feed(Data("\r\n".utf8))
        XCTAssertEqual(collector.links.first?.absoluteString, destination)
    }

    func testRealNewlinesAreNotGuessedAsURLContinuations() {
        var collector = TerminalLinkCollector()
        collector.feed(Data("https://auth.synthetic.invalid/oauth?state=first\r\nsecond-part\r\n".utf8))
        XCTAssertEqual(collector.links.map(\.absoluteString), ["https://auth.synthetic.invalid/oauth?state=first"])
    }

    func testSGRAndIgnoredControlsPreserveVisibleURLButRepaintDiscardsDraft() {
        var collector = TerminalLinkCollector()
        let output = "\u{1b}[32mhttps://auth.synthetic.invalid/\u{1b}[1m\u{7}oauth?state=synthetic\u{1b}[0m\r\n"
        for byte in Data(output.utf8) { collector.feed(Data([byte])) }
        XCTAssertEqual(collector.links.map(\.absoluteString), ["https://auth.synthetic.invalid/oauth?state=synthetic"])
        var repaint = TerminalLinkCollector()
        repaint.feed(Data("https://unfinished.synthetic.invalid/part\u{1b}[2KReplacement\n".utf8))
        repaint.feed(Data("https://unfinished.synthetic.invalid/typo\u{8}x\n".utf8))
        XCTAssertTrue(repaint.links.isEmpty)
    }

    func testOSC8UsesFullDestinationAndOtherControlStringsAreIgnored() {
        var collector = TerminalLinkCollector()
        let output = "\u{1b}]0;https://hidden.synthetic.invalid/title\u{7}" +
            "\u{1b}Phttps://hidden.synthetic.invalid/dcs\u{1b}\\" +
            "\u{1b}]8;id=synthetic;" + authorization + "\u{1b}\\Continue in browser\u{1b}]8;;\u{1b}\\\n"
        for byte in Data(output.utf8) { collector.feed(Data([byte])) }
        XCTAssertEqual(collector.links.map(\.absoluteString), [authorization])
    }

    func testOnlyValidHTTPLinksAreReturned() {
        var collector = TerminalLinkCollector()
        for text in ["file:///synthetic/private", "javascript:alert(1)", "mailto:synthetic@gmail.com", "ftp://files.synthetic.invalid/path",
                     "https://name:password@auth.synthetic.invalid/", "https://auth.synthetic.invalid/%GG", "https://auth.synthetic.invalid/%",
                     "https://auth.synthetic.invalid:99999/", "https://auth.synthetic.invalid/\u{202e}path"] {
            collector.feed(Data((text + "\n").utf8))
        }
        collector.feed(Data("\u{1b}]8;;file:///synthetic/private\u{7}https://deceptive.synthetic.invalid/\u{1b}]8;;\u{7}\n".utf8))
        XCTAssertTrue(collector.links.isEmpty)
        collector.feed(Data("(http://localhost:43123/callback) https://public.synthetic.invalid/page.\n".utf8))
        XCTAssertEqual(collector.links.map(\.absoluteString), ["https://public.synthetic.invalid/page", "http://localhost:43123/callback"])
    }

    func testEOFCompletesFinalTokenAndRetentionIsBounded() {
        var collector = TerminalLinkCollector()
        collector.feed(Data(authorization.utf8)); collector.finish()
        XCTAssertEqual(collector.links.map(\.absoluteString), [authorization])
        for index in 0..<12 { collector.feed(Data("https://auth.synthetic.invalid/\(index)\n".utf8)) }
        XCTAssertEqual(collector.links.count, 8)
        collector.feed(Data("https://auth.synthetic.invalid/9\n".utf8))
        XCTAssertEqual(collector.links.count, 8)
        XCTAssertEqual(collector.links.first?.absoluteString, "https://auth.synthetic.invalid/9")
        var oversized = TerminalLinkCollector()
        oversized.feed(Data(("https://auth.synthetic.invalid/" + String(repeating: "a", count: 20_000) + "\n").utf8))
        oversized.feed(Data(("\u{1b}]8;;https://auth.synthetic.invalid/" + String(repeating: "a", count: 20_000) + "\u{7}").utf8))
        XCTAssertTrue(oversized.links.isEmpty)
    }
}
