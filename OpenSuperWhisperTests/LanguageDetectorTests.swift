import XCTest
@testable import OpenSuperWhisper

/// Golden-table conformance for the fallback language heuristic.
///
/// The three tables below are the fixture sets of the design study
/// (`fm-20260923-04` §2.1) with the verdicts of its reference implementation
/// (`/tmp/fm04/heuristic.py`), which measured 22/22 on realistic sentences,
/// 16/16 on real whisper transcripts and 23/32 on the adversarial set. The
/// Swift detector is a port of that rule set, so it must agree row for row —
/// this is the test that catches a porting slip, not an opinion about how
/// short utterances *should* be classified.
final class LanguageDetectorTests: XCTestCase {

    private func assertTable(
        _ cases: [(text: String, expected: LanguageDetector.Verdict)],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for item in cases {
            XCTAssertEqual(
                LanguageDetector.detect(item.text),
                item.expected,
                "detect(\(item.text))",
                file: file,
                line: line
            )
        }
    }

    /// Realistic dictated sentences, 12 Polish + 10 English, including two
    /// diacritic-free Polish ones.
    func testRealisticSentences_areClassified() {
        assertTable([
            ("Dzisiaj muszę wysłać raport do klienta.", .polish),
            ("Nie wiem, czy zdążymy na czas.", .polish),
            ("Zrób to jutro.", .polish),
            ("Dziękuję bardzo.", .polish),
            ("Czy możesz mi pomóc z tym projektem?", .polish),
            ("Spotkanie jest o trzeciej po południu w piątek.", .polish),
            ("Wysłałem ci wczoraj wiadomość na WhatsAppie.", .polish),
            ("Muszę kupić chleb i mleko.", .polish),
            ("Zrob to jutro", .polish),
            ("Nie wiem czy zdazymy na czas", .polish),
            ("I need to send the report to the client today.", .english),
            ("I don't know if we'll make it in time.", .english),
            ("Do it tomorrow.", .english),
            ("Thank you very much.", .english),
            ("Can you help me with this project?", .english),
            ("The meeting is at three in the afternoon on Friday.", .english),
            ("I sent you a message yesterday on WhatsApp.", .english),
            ("I need to buy bread and milk.", .english),
            ("Send the report.", .english),
            ("Wyślij raport.", .polish),
            ("Yes, please.", .english),
            ("Tak, proszę.", .polish),
        ])
    }

    /// What whisper actually produced for the same 16 utterances, punctuation and
    /// all (numbers expanded) — the heuristic sees engine output, not clean
    /// prose.
    func testEngineTranscripts_areClassified() {
        assertTable([
            ("Dzisiaj muszę wysłać raport do klienta.", .polish),
            ("Nie wiem, czy zdążymy na czas.", .polish),
            ("Zrób to jutro.", .polish),
            ("Dziękuję bardzo.", .polish),
            ("Czy możesz mi pomóc z tym projektem?", .polish),
            ("Spotkanie jest o 3.00 po południu w piątek.", .polish),
            ("Wysłałem Ci wczoraj wiadomość na Whatsappie.", .polish),
            ("Muszę kupić chleb i mleko.", .polish),
            ("I need to send the report to the client today.", .english),
            ("I don't know if we'll make it in time.", .english),
            ("Do it tomorrow.", .english),
            ("Thank you very much.", .english),
            ("Can you help me with this project?", .english),
            ("The meeting is at 3 in the afternoon on Friday.", .english),
            ("I sent you a message yesterday on WhatsApp.", .english),
            ("I need to buy bread and milk.", .english),
        ])
    }

    /// 1–3 word Polish/English twins with no diacritics — the honest limit of a
    /// text heuristic (23/32). The nine rows marked as reference errors are kept
    /// on purpose: they are what the gate will really see for utterances this
    /// short, and every one of them fails safe — `unknown` (and the English twin
    /// misread as Polish, `"I know"`) only matters when an engine reported
    /// nothing, and short English that reads as Polish is what the tone switch's
    /// language-preservation guard discards again.
    func testAdversarialShortPhrases_matchTheMeasuredRuleSet() {
        assertTable([
            ("Ok", .unknown),                       // reference error (pl → unknown)
            ("Okay", .unknown),                     // reference error (en → unknown)
            ("Tak", .polish),
            ("Yes", .unknown),                      // reference error (en → unknown)
            ("Dobrze", .polish),
            ("Good", .unknown),                     // reference error (en → unknown)
            ("Raport gotowy", .polish),
            ("Report ready", .english),
            ("Wiem", .polish),
            ("I know", .polish),                    // reference error (en → pl)
            ("Jutro", .polish),
            ("Tomorrow", .english),
            ("Musimy isc", .unknown),               // reference error (pl → unknown)
            ("We have to go", .english),
            ("To jest ok", .polish),
            ("It is ok", .english),
            ("Kup chleb", .polish),
            ("Buy bread", .english),
            ("Dzisiaj", .polish),
            ("Today", .english),
            ("Projekt jest skonczony", .polish),
            ("The project is finished", .english),
            ("Wyslij maila do klienta", .polish),
            ("Send the email to the client", .english),
            ("Nie, dziekuje", .polish),
            ("No, thank you", .english),
            ("Spotkanie o trzeciej", .polish),
            ("Meeting at three", .english),
            ("Zrob to", .english),                  // reference error (pl → en)
            ("Do it", .unknown),                    // reference error (en → unknown)
            ("Chce nowy laptop", .unknown),         // reference error (pl → unknown)
            ("I want a new laptop", .english),
        ])
    }

    // MARK: - Boundaries

    func testNoSignal_isUnknown() {
        for text in ["", "   ", "\n", "123", "12345", "@#$%", "mmm hmm", "zzz"] {
            XCTAssertEqual(LanguageDetector.detect(text), .unknown, "detect(\(text)) must not guess")
        }
    }

    func testEqualScores_areUnknown() {
        // "Do it" scores 2.0 on both sides (weak Polish marker "do", English
        // words "do"/"it"): a tie must never be resolved by declaration order.
        XCTAssertEqual(LanguageDetector.detect("Do it"), .unknown)
    }

    func testPolishDiacritics_decideOnTheirOwn() {
        XCTAssertEqual(LanguageDetector.detect("ąćęłńóśźż"), .polish)
        XCTAssertEqual(LanguageDetector.detect("ŻÓŁĆ"), .polish)
    }

    /// The diacritic rule is Polish-specific by design: only `ąćęłńóśźż` score.
    /// A borrowed word carrying another Latin accent must not be read as Polish.
    func testNonPolishAccents_carryNoSignal() {
        XCTAssertEqual(LanguageDetector.detect("naïve"), .unknown)
        XCTAssertEqual(LanguageDetector.detect("café"), .unknown)
    }

    func testLanguageCode_isTheWhisperCodeOrNilWhenUnsure() {
        XCTAssertEqual(LanguageDetector.languageCode(for: "Cześć, jak się masz?"), "pl")
        XCTAssertEqual(LanguageDetector.languageCode(for: "Please send the report."), "en")
        XCTAssertNil(LanguageDetector.languageCode(for: "Do it"))
        XCTAssertNil(LanguageDetector.languageCode(for: ""))
    }

    func testVerdictRoundTripsThroughItsWhisperCode() {
        XCTAssertEqual(LanguageDetector.Verdict(languageCode: "pl"), .polish)
        XCTAssertEqual(LanguageDetector.Verdict(languageCode: "en"), .english)
        XCTAssertNil(LanguageDetector.Verdict(languageCode: "unknown"))
        // Any third language is not something this heuristic (or the gate) can
        // act on, so it must not silently map onto Polish or English.
        for code in ["de", "ru", "auto", "", "PL", "polish"] {
            XCTAssertNil(LanguageDetector.Verdict(languageCode: code), "code \(code)")
        }
        XCTAssertEqual(LanguageDetector.Verdict.polish.languageCode, "pl")
        XCTAssertEqual(LanguageDetector.Verdict.english.languageCode, "en")
        XCTAssertNil(LanguageDetector.Verdict.unknown.languageCode)
    }
}
