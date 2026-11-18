import XCTest
@testable import OpenSuperWhisper

/// The spoken e-mail trigger: what it must catch, what it must leave alone, and
/// the spellings the engines actually produce.
final class DictationTriggerTests: XCTestCase {

    func testThePhraseTheUserSays_picksTheModeAndIsTakenOffTheFront() throws {
        let match = try XCTUnwrap(DictationTrigger.email(in: "dyktuję maila musimy przesunąć wdrożenie na poniedziałek"))
        XCTAssertEqual(match.spoken, "dyktuję maila")
        XCTAssertEqual(match.body, "musimy przesunąć wdrożenie na poniedziałek")
    }

    /// The engines' own spellings: no diacritics, no capitals, `mejl` for `mail`,
    /// a dropped letter — each of these is still the trigger, and none of them may
    /// leave the phrase in the body.
    func testEngineSpellingsStillTrigger() throws {
        let spellings = [
            "Dyktuję maila, wyślij raport do piątku",
            "dyktuje maila wyślij raport do piątku",
            "Dyktuje mejla wyślij raport do piątku",
            "dyktuj meila wyślij raport do piątku",
            "napisz maila wyślij raport do piątku",
            "napisz email: wyślij raport do piątku",
            "write an email send the report by Friday",
            "draft a mail send the report by Friday",
            // Spoken at the top of a dictation, which is rarely clean: one filler
            // in front of the verb, or one between the verb and its noun.
            "no dobra, dyktuję maila, wyślij raport do piątku",
            "dyktuję teraz maila wyślij raport do piątku",
            "napisz mi maila do klienta i wyślij raport do piątku",
            "przygotuj maila wyślij raport do piątku",
            "zrób maila wyślij raport do piątku",
            "utwórz e-mail: wyślij raport do piątku",
            "make a mail send the report by Friday",
        ]
        for spelling in spellings {
            let match = try XCTUnwrap(DictationTrigger.email(in: spelling), spelling)
            XCTAssertFalse(
                match.body.lowercased().contains("mail") || match.body.lowercased().contains("mejl"),
                "the trigger must not survive into the body: \(spelling) -> \(match.body)"
            )
            XCTAssertTrue(match.body.lowercased().contains("raport") || match.body.lowercased().contains("report"),
                          spelling)
        }
    }

    /// Ordinary sentences about a mail are content, not a mode change — including
    /// the one that made the verb window stop at three words.
    func testSentencesAboutAMailAreNotTriggers() {
        for sentence in [
            "no więc słuchaj, napisz maila do klienta",
            "wyślij mi tego maila jeszcze dzisiaj, dobrze",
            "przygotuj nowy plan na jutro",
            "ten mail od klienta wymaga odpowiedzi",
            "please, when you have a moment, write an email to the client",
        ] {
            XCTAssertNil(DictationTrigger.email(in: sentence), sentence)
        }
    }

    /// A body that mentions a mail is content, not a mode change: only the
    /// opening counts.
    func testAMentionInsideTheBodyIsNotATrigger() {
        XCTAssertNil(DictationTrigger.email(in: "musimy wysłać tego maila do klienta, więc przygotuj raport"))
        XCTAssertNil(DictationTrigger.email(in: "I will send you an email about the meeting tomorrow"))
    }

    /// A phrase that starts after the verb window is a mention, not a trigger.
    func testAWordTooFarInDoesNotTrigger() {
        XCTAssertNil(DictationTrigger.email(in: "no więc słuchaj, napisz maila do klienta"))
        XCTAssertNil(DictationTrigger.email(in: "please, when you have a moment, write an email to the client"))
    }

    /// The trigger alone leaves an empty body for the caller to treat as "nothing
    /// dictated" rather than an e-mail about nothing.
    func testTheTriggerAloneLeavesAnEmptyBody() throws {
        let match = try XCTUnwrap(DictationTrigger.email(in: "dyktuję maila"))
        XCTAssertEqual(match.body, "")
    }

    func testAnOrdinaryDictationIsUntouched() {
        XCTAssertNil(DictationTrigger.email(in: "no kurwa, ten plik jest do dupy, musimy to ogarnąć na dziś"))
        XCTAssertNil(DictationTrigger.email(in: "yeah so I mean we kinda need that file today"))
        XCTAssertNil(DictationTrigger.email(in: ""))
        XCTAssertNil(DictationTrigger.email(in: "maila"))
    }
}
