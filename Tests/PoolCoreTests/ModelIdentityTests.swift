import Foundation
import XCTest
@testable import PoolCore

final class ModelIdentityTests: XCTestCase {
    func testOnlyAModelOfTheAliasFamilyIsRecorded() {
        XCTAssertEqual(ModelIdentity(alias: "opus", id: "claude-opus-5-5", name: "Opus")?.name, "Opus 5.5")
        XCTAssertEqual(ModelIdentity(alias: "opus", id: "claude-opus-5-5[1m]", name: "Opus 5.5 (1M context)")?.id, "claude-opus-5-5")
        XCTAssertEqual(ModelIdentity(alias: "haiku", id: "claude-haiku-4-5-20251001", name: nil)?.name, "Haiku 4.5")
        XCTAssertEqual(ModelIdentity(alias: "sonnet", id: "claude-3-5-sonnet-20241022", name: nil)?.name, "Sonnet 3.5")
        XCTAssertNil(ModelIdentity(alias: "opus", id: "claude-sonnet-5-5", name: "Sonnet 5.5"))
        XCTAssertNil(ModelIdentity(alias: "opus", id: "opus", name: "Opus"))
        XCTAssertNil(ModelIdentity(alias: "opus", id: "claude-opus-5-5\n", name: nil))
        XCTAssertNil(ModelIdentity(alias: "sonnet", id: "anthropic/claude-sonnet-5-5", name: nil))
    }

    func testLibraryRecordsWhatEachAliasRunsOnAndSurvivesOldOrStaleEntries() throws {
        var library = PoolLibrary()
        let opus = try XCTUnwrap(ModelIdentity(alias: "opus", id: "claude-opus-5-5", name: nil))
        XCTAssertTrue(library.record(opus))
        XCTAssertFalse(library.record(opus))
        let newer = try XCTUnwrap(ModelIdentity(alias: "opus", id: "claude-opus-6", name: nil))
        XCTAssertTrue(library.record(newer))
        XCTAssertEqual(library.reportedModels, [newer])

        // An entry this version would not record is ignored, never fatal to the library.
        let stored = #"{"version":1,"accounts":[],"preferences":{"port":18473,"language":"system"},"reportedModels":[{"alias":"opus","id":"../x","name":"X"},{"alias":"haiku","id":"claude-haiku-6","name":"Haiku 6"}]}"#
        let decoded = try JSONDecoder().decode(PoolLibrary.self, from: Data(stored.utf8))
        XCTAssertEqual(PoolModel.listing(decoded.reportedModels ?? []).map(\.listedID),
                       ["claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-6", "claude-fable-5-2"])
        let old = #"{"version":1,"accounts":[],"preferences":{"port":18473,"language":"system"}}"#
        XCTAssertNil(try JSONDecoder().decode(PoolLibrary.self, from: Data(old.utf8)).reportedModels)
    }
}
