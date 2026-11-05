import XCTest
@testable import PoolCore

final class AppearancePreferencesTests: XCTestCase {
    func testExistingPreferencesFollowSystemAndExplicitChoicesRoundTrip() throws {
        let decoder = JSONDecoder()
        let existing = try decoder.decode(PoolPreferences.self, from: Data(#"{"port":18473,"language":"en"}"#.utf8))
        XCTAssertEqual(existing.appearance, "system")
        for choice in ["system", "light", "dark"] {
            var preferences = existing; preferences.appearance = choice
            XCTAssertEqual(try decoder.decode(PoolPreferences.self, from: JSONEncoder().encode(preferences)), preferences)
        }
    }

    func testInvalidAppearanceInSavedPreferencesIsRejected() {
        XCTAssertThrowsError(try JSONDecoder().decode(PoolPreferences.self,
            from: Data(#"{"port":18473,"language":"en","appearance":"unknown"}"#.utf8)))
    }
}
