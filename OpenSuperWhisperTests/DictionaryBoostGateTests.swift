import XCTest
@testable import OpenSuperWhisper

/// The custom dictionary now decouples two behaviors:
/// - **Replacement** (`shouldApplyCustomDictionary`) — exact text fix, on whenever the dictionary
///   is enabled and non-empty.
/// - **Recognition boosting** (`shouldBoostCustomDictionary`) — opt-in, gated by the separate
///   `customDictionaryBoostEnabled` flag, because fuzzy boosting over-corrects common terms (#over-boost).
/// This guards that boosting requires BOTH flags while replacement only needs the dictionary on.
final class DictionaryBoostGateTests: XCTestCase {

    private var saved: (enabled: Bool, boost: Bool, data: Data?)!

    override func setUp() {
        let p = AppPreferences.shared
        saved = (p.customDictionaryEnabled, p.customDictionaryBoostEnabled, UserDefaults.standard.data(forKey: "customDictionaryData"))
        p.customDictionaryEntries = [CustomDictionaryEntry(original: "git hub", replacement: "GitHub")]
    }

    override func tearDown() {
        let p = AppPreferences.shared
        p.customDictionaryEnabled = saved.enabled
        p.customDictionaryBoostEnabled = saved.boost
        if let d = saved.data { UserDefaults.standard.set(d, forKey: "customDictionaryData") }
        else { UserDefaults.standard.removeObject(forKey: "customDictionaryData") }
    }

    private func settings(enabled: Bool, boost: Bool) -> Settings {
        AppPreferences.shared.customDictionaryEnabled = enabled
        AppPreferences.shared.customDictionaryBoostEnabled = boost
        return Settings()
    }

    func testReplacementOnWhenEnabled_regardlessOfBoost() {
        XCTAssertTrue(settings(enabled: true, boost: false).shouldApplyCustomDictionary)
        XCTAssertTrue(settings(enabled: true, boost: true).shouldApplyCustomDictionary)
    }

    func testBoostRequiresBothFlags() {
        XCTAssertFalse(settings(enabled: true, boost: false).shouldBoostCustomDictionary,
                       "Dictionary on but boost off → replacement only, no recognition boost")
        XCTAssertTrue(settings(enabled: true, boost: true).shouldBoostCustomDictionary)
    }

    func testNothingWhenDictionaryDisabled() {
        let s = settings(enabled: false, boost: true)
        XCTAssertFalse(s.shouldApplyCustomDictionary)
        XCTAssertFalse(s.shouldBoostCustomDictionary, "Boost flag alone, with dictionary off, does nothing")
    }

    func testBoostOffByDefaultIsTheSafeDefault() {
        // The whole point of the fix: a user who just adds entries gets replacement, not boosting.
        XCTAssertFalse(settings(enabled: true, boost: false).shouldBoostCustomDictionary)
    }
}
