import XCTest
@testable import OpenSuperWhisper

final class AppPreferencesMigrationTests: XCTestCase {
    func testMigrateLegacyRightOptionSeedsSingleKey() {
        let triggers = AppPreferences.migratedSingleKeyTriggers(
            legacyModifierOnly: "rightOption",
            existingData: nil
        )
        XCTAssertEqual(triggers, [TriggerKey(modifierKey: .rightOption)])
    }

    func testMigrateLegacyNoneIsEmpty() {
        let triggers = AppPreferences.migratedSingleKeyTriggers(
            legacyModifierOnly: "none",
            existingData: nil
        )
        XCTAssertEqual(triggers, [])
    }

    func testExistingDataWins() throws {
        let existing = [TriggerKey(modifierKey: .fn)]
        let data = try JSONEncoder().encode(existing)
        let triggers = AppPreferences.migratedSingleKeyTriggers(
            legacyModifierOnly: "rightOption",
            existingData: data
        )
        XCTAssertEqual(triggers, existing)
    }
}
