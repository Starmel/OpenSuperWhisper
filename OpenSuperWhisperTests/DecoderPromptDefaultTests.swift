import XCTest

@testable import OpenSuperWhisper

/// The two defaults the pairing measurement changed: the switch, and the decoder
/// prompt that is chosen by the language spoken.
///
/// These are the cases that make flipping a default a deliberate act. The
/// measurement they rest on is `WhisperPauseBoundaryPairingTests` (his own
/// recordings, the app's own decode path) and its tables are in
/// `fleet/data/fm-20260925-14/report.md`.
final class DecoderPromptDefaultTests: XCTestCase {

    // MARK: - The rule

    /// A prompt the user set is a decision, and nothing overrides it.
    func testTheUsersOwnPromptWinsInEveryLanguageAndOnEitherSwitch() {
        let theirs = "Zażółć gęślą jaźń."
        XCTAssertEqual(
            WhisperEngine.decoderPrompt(
                userPrompt: theirs,
                longPausesEndSentences: true,
                showsTimestamps: false,
                spokenLanguage: "pl"
            ),
            theirs
        )
        XCTAssertEqual(
            WhisperEngine.decoderPrompt(
                userPrompt: theirs,
                longPausesEndSentences: false,
                showsTimestamps: false,
                spokenLanguage: "en"
            ),
            theirs
        )
        XCTAssertEqual(
            WhisperEngine.decoderPrompt(
                userPrompt: theirs,
                longPausesEndSentences: true,
                showsTimestamps: false,
                spokenLanguage: nil
            ),
            theirs,
            "a language the engine could not measure must not replace what the user set"
        )
    }

    /// With the switch off the app is upstream byte for byte: no default prompt
    /// may reach the decoder. Without this, an install that never turned the
    /// switch on would get a file that changed for no measured reason.
    func testTheSwitchOffSendsNoDefaultEvenWithNoPromptOfTheUsersOwn() {
        for language in ["pl", "en", "de", nil] as [String?] {
            XCTAssertEqual(
                WhisperEngine.decoderPrompt(
                    userPrompt: "",
                    longPausesEndSentences: false,
                    showsTimestamps: false,
                    spokenLanguage: language
                ),
                "",
                "language \(language ?? "none")"
            )
        }
    }

    /// The default is chosen by the language spoken: the two measured languages
    /// get the two measured prompts, and nothing else gets anything.
    func testTheDefaultIsTheOneItsLanguageHas() {
        XCTAssertEqual(
            WhisperEngine.decoderPrompt(
                userPrompt: "", longPausesEndSentences: true, showsTimestamps: false, spokenLanguage: "pl"
            ),
            WhisperEngine.polishDefaultDecoderPrompt
        )
        XCTAssertEqual(
            WhisperEngine.decoderPrompt(
                userPrompt: "", longPausesEndSentences: true, showsTimestamps: false, spokenLanguage: "en"
            ),
            WhisperEngine.englishDefaultDecoderPrompt
        )
        for language in ["de", "fr", "es", "zh", "auto", "", "PL", "polish", nil] as [String?] {
            XCTAssertEqual(
                WhisperEngine.decoderPrompt(
                    userPrompt: "", longPausesEndSentences: true, showsTimestamps: false, spokenLanguage: language
                ),
                "",
                "unmeasured language \(language ?? "none") must send no prompt"
            )
        }
    }

    /// The table is the measurement's, not a preference: each entry is ordinary
    /// dictation in that language, with no instruction in it. The
    /// instruction-shaped string the earlier brief attributed to his preferences
    /// is deliberately absent — this project documented that shape as a
    /// hallucination trigger, and the brief forbids shipping it as a default.
    func testTheDefaultsAreDictationAndNotInstruction() {
        let defaults = [
            "pl": WhisperEngine.polishDefaultDecoderPrompt,
            "en": WhisperEngine.englishDefaultDecoderPrompt,
        ]
        for (language, prompt) in defaults {
            XCTAssertFalse(prompt.isEmpty, language)
            XCTAssertFalse(
                prompt.lowercased().contains("you are") || prompt.lowercased().contains("your role"),
                "\(language): an instruction is not a decoder prompt — \(prompt)"
            )
            XCTAssertFalse(
                prompt.lowercased().contains("transcri") || prompt.lowercased().contains("do not change"),
                "\(language): meta-commentary leaked into the default — \(prompt)"
            )
        }
        XCTAssertEqual(
            WhisperEngine.defaultDecoderPrompt(forLanguage: "pl"),
            "Zrobiłem to wczoraj. Sprawdzę to jutro. Możesz na to spojrzeć? Nie ma problemu."
        )
        XCTAssertEqual(
            WhisperEngine.defaultDecoderPrompt(forLanguage: "en"),
            "Okay, one more time: I sent the report on Monday, but Anna hasn't replied. Can you check?"
        )
    }

    // MARK: - The switch, as it ships

    /// A new install gets the switch **on**, and that is the captain's decision
    /// on a measurement rather than a preference: paired with the language-aware
    /// default prompt the switch keeps the Polish win, and what it costs the
    /// English control is exactly the two words he accepted on 2026-09-25
    /// (`WhisperPauseBoundaryPairingTests.acceptedEnglishChange`); off it leaves
    /// the Polish complaint in place.
    func testANewInstallGetsTheSwitchOn() {
        let suite = AppPreferences.defaults
        let key = "longPausesEndSentences"
        let saved = suite.object(forKey: key)
        suite.removeObject(forKey: key)
        defer {
            if let saved {
                suite.set(saved, forKey: key)
            } else {
                suite.removeObject(forKey: key)
            }
        }

        XCTAssertTrue(Settings().longPausesEndSentences, "the shipped default is on")
        XCTAssertEqual(
            WhisperEngine.PauseBoundaryPolicy.from(settings: Settings()),
            .restored,
            "…and the policy it produces is the fix"
        )
    }

    /// A new install gets **no** stored prompt: the language-aware default is a
    /// default, not a value written into anyone's preferences. The captain's own
    /// domain is never touched by the app for it.
    func testANewInstallGetsNoStoredPrompt() {
        let suite = AppPreferences.defaults
        let key = "initialPrompt"
        let saved = suite.object(forKey: key)
        suite.removeObject(forKey: key)
        defer {
            if let saved {
                suite.set(saved, forKey: key)
            } else {
                suite.removeObject(forKey: key)
            }
        }

        XCTAssertEqual(AppPreferences.shared.initialPrompt, "", "the stored prompt stays empty")
        XCTAssertEqual(Settings().initialPrompt, "", "…and the dictation reads that empty value")
        XCTAssertEqual(
            WhisperEngine.decoderPrompt(
                userPrompt: Settings().initialPrompt,
                longPausesEndSentences: Settings().longPausesEndSentences,
                showsTimestamps: false,
                spokenLanguage: "pl"
            ),
            WhisperEngine.polishDefaultDecoderPrompt,
            "the prompt a new install actually sends comes from the table, not from its domain"
        )
    }

    /// Reading the value must not write it: a default that stores itself would
    /// take the captain's own install from "never opened Settings" to "has a
    /// preference", and then his Settings field would show text he never typed.
    func testReadingThePromptDoesNotWriteItIntoTheDomain() {
        let suite = AppPreferences.defaults
        let key = "initialPrompt"
        let saved = suite.object(forKey: key)
        suite.removeObject(forKey: key)
        defer {
            if let saved {
                suite.set(saved, forKey: key)
            } else {
                suite.removeObject(forKey: key)
            }
        }

        _ = Settings().initialPrompt
        _ = AppPreferences.shared.initialPrompt
        XCTAssertNil(
            suite.object(forKey: key),
            "nothing may have been written to the user's preferences"
        )
    }

    /// Timestamp mode hands the decoder the untrimmed audio and measures no pause,
    /// so the switch has nothing to serve there: no default prompt is sent, and
    /// the mode is byte for byte what it always was.
    func testTimestampModeSendsNoDefault() {
        for language in ["pl", "en"] {
            XCTAssertEqual(
                WhisperEngine.decoderPrompt(
                    userPrompt: "",
                    longPausesEndSentences: true,
                    showsTimestamps: true,
                    spokenLanguage: language
                ),
                "",
                "language \(language)"
            )
        }
    }
}
