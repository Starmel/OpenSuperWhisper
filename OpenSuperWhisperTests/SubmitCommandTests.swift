import XCTest
@testable import OpenSuperWhisper

/// `parseSubmitCommand` is the pure regex behind the opt-in "press enter" voice command
/// (#14): it strips a trailing "press enter" from a dictation and reports whether to submit.
/// The matching has real edge cases (anchoring, punctuation, false positives), so it's covered
/// directly here, independent of the `submitOnVoiceCommand` preference.
final class SubmitCommandTests: XCTestCase {

    private func parse(_ s: String) -> (text: String, submit: Bool) {
        AppPreferences.parseSubmitCommand(s)
    }

    func testStripsTrailingCommand() {
        let r = parse("Send this message press enter")
        XCTAssertTrue(r.submit)
        XCTAssertEqual(r.text, "Send this message")
    }

    func testCaseInsensitive() {
        let r = parse("ok PRESS ENTER")
        XCTAssertTrue(r.submit)
        XCTAssertEqual(r.text, "ok")
    }

    func testConsumesTrailingPunctuationAndComma() {
        let r = parse("Reply yes, press enter.")
        XCTAssertTrue(r.submit)
        XCTAssertEqual(r.text, "Reply yes")
    }

    func testKeepsPrecedingSentencePeriod() {
        // Only whitespace/commas are consumed before the command, so a finished
        // sentence's period survives.
        let r = parse("Send this. Press enter")
        XCTAssertTrue(r.submit)
        XCTAssertEqual(r.text, "Send this.")
    }

    func testNoCommandLeavesTextUnchanged() {
        let r = parse("just some regular text")
        XCTAssertFalse(r.submit)
        XCTAssertEqual(r.text, "just some regular text")
    }

    func testCommandMustBeAtEnd() {
        // "press enter" not at the end is content, not a command — anchoring must not match.
        let r = parse("press enter to continue reading")
        XCTAssertFalse(r.submit)
        XCTAssertEqual(r.text, "press enter to continue reading")
    }

    func testPressWithoutEnterIsNotACommand() {
        let r = parse("press the button")
        XCTAssertFalse(r.submit)
        XCTAssertEqual(r.text, "press the button")
    }

    func testCommandOnlyYieldsEmptyText() {
        // Saying just "press enter" submits whatever is already in the field.
        let r = parse("press enter")
        XCTAssertTrue(r.submit)
        XCTAssertEqual(r.text, "")
    }

    func testKnownFalsePositiveWhenSentenceEndsInCommand() {
        // Documented limitation: a sentence that genuinely ends in "press enter" is stripped.
        let r = parse("tell him to press enter")
        XCTAssertTrue(r.submit)
        XCTAssertEqual(r.text, "tell him to")
    }

    func testInstanceMethodIsNoOpWhenPreferenceOff() {
        let prefs = AppPreferences.shared
        let original = prefs.submitOnVoiceCommand
        defer { prefs.submitOnVoiceCommand = original }

        prefs.submitOnVoiceCommand = false
        let r = prefs.stripSubmitCommand("Send it press enter")
        XCTAssertFalse(r.submit)
        XCTAssertEqual(r.text, "Send it press enter")
    }
}
