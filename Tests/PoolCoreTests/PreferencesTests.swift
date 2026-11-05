import Foundation
import XCTest
@testable import PoolCore

final class PreferencesTests: XCTestCase {
    /// A library saved while Pool still bounded its Claude Code processes keeps opening; the bound is gone.
    func testALibraryWithTheOldProcessLimitStillOpens() throws {
        let earlier = Data(#"{"port":18473,"language":"system","runsMost":9}"#.utf8)
        let preferences = try JSONDecoder().decode(PoolPreferences.self, from: earlier)
        XCTAssertEqual(preferences.port, 18473)
        let saved = String(decoding: try JSONEncoder().encode(preferences), as: UTF8.self)
        XCTAssertFalse(saved.contains("runsMost"))
    }
}
