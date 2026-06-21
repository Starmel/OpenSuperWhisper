import XCTest
@testable import OpenSuperWhisper

/// `boostTerms` is the single source of the words boosted on BOTH engines
/// (Whisper prompt-boost + Parakeet decode vocabulary), so its contract is
/// covered directly here.
final class CustomDictionaryBoostTermsTests: XCTestCase {

    private func entry(_ original: String, _ replacement: String) -> CustomDictionaryEntry {
        CustomDictionaryEntry(original: original, replacement: replacement)
    }

    func testUsesReplacementsAndIgnoresOriginal() {
        let terms = CustomDictionary.boostTerms(entries: [entry("my monkey", "My-Monkey")])
        XCTAssertEqual(terms, ["My-Monkey"])
    }

    func testIncludesBoostOnlyEntriesWithEmptyOriginal() {
        // An entry with no "heard as" still boosts its replacement term.
        let terms = CustomDictionary.boostTerms(entries: [entry("", "Kubernetes")])
        XCTAssertEqual(terms, ["Kubernetes"])
    }

    func testDeduplicatesCaseInsensitivelyPreservingOrder() {
        let terms = CustomDictionary.boostTerms(entries: [
            entry("", "Swift"),
            entry("swiftui", "SwiftUI"),
            entry("", "swift"),   // duplicate of "Swift" (case-insensitive) → dropped
            entry("", "Xcode"),
        ])
        XCTAssertEqual(terms, ["Swift", "SwiftUI", "Xcode"])
    }

    func testFiltersEmptyAndWhitespaceReplacements() {
        let terms = CustomDictionary.boostTerms(entries: [
            entry("", "   "),
            entry("heard", ""),
            entry("", "Valid"),
        ])
        XCTAssertEqual(terms, ["Valid"])
    }

    func testPromptBoostJoinsBoostTermsWithCommas() {
        let entries = [entry("", "Alpha"), entry("", "Beta")]
        XCTAssertEqual(CustomDictionary.promptBoost(entries: entries), "Alpha, Beta")
    }
}
