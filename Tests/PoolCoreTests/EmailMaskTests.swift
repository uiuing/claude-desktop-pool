import Foundation
import XCTest
@testable import PoolCore

final class EmailMaskTests: XCTestCase {
    func testOnlyTheNameBeforeAtIsMasked() {
        XCTAssertEqual(EmailMask.masked("ada.lovelace@example.com"), "a••••••••e@example.com")
        XCTAssertEqual(EmailMask.masked("bob@example.com"), "b•••b@example.com")
        XCTAssertEqual(EmailMask.masked("jo@example.com"), "•••@example.com")
        XCTAssertEqual(EmailMask.masked("a@example.com"), "•••@example.com")
        XCTAssertEqual(EmailMask.masked("not-an-email"), "not-an-email")
        XCTAssertEqual(EmailMask.masked("@example.com"), "@example.com")
    }
    func testMaskingIsOffUntilChosenAndSurvivesSaving() throws {
        let saved = #"{"port":18473,"language":"en"}"#
        XCTAssertFalse(try JSONDecoder().decode(PoolPreferences.self, from: Data(saved.utf8)).maskEmail)
        let masked = PoolPreferences(maskEmail: true)
        XCTAssertTrue(try JSONDecoder().decode(PoolPreferences.self, from: JSONEncoder().encode(masked)).maskEmail)
    }
}
