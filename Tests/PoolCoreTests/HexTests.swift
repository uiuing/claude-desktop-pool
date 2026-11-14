import CryptoKit
import Foundation
import XCTest
@testable import PoolCore

final class HexTests: XCTestCase {
    /// Keys a restart keeps (redaction's text keys, digests of what went) were written with
    /// `String(format: "%02x")`: the faster writing gives the same text, so they still match.
    func testHexIsWhatFormattingEachByteWrote() {
        func formatted<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 { bytes.map { String(format: "%02x", $0) }.joined() }
        let every = (0...255).map(UInt8.init)
        XCTAssertEqual(every.lowercaseHex, formatted(every))
        XCTAssertEqual([UInt8]().lowercaseHex, "")
        let digest = SHA256.hash(data: Data("A synthetic text.".utf8))
        XCTAssertEqual(digest.lowercaseHex, formatted(digest))
        XCTAssertEqual(digest.prefix(8).lowercaseHex, formatted(digest.prefix(8)))
        let code = HMAC<SHA256>.authenticationCode(for: Data("A synthetic text.".utf8), using: SymmetricKey(size: .bits256))
        XCTAssertEqual(code.lowercaseHex, formatted(code))
    }
}
