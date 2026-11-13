import XCTest
@testable import OpenSuperWhisper

/// The deterministic clean-up, on fixed inputs and with no model anywhere near
/// it. This is the layer the captain asked for by hand — "scrub all the
/// 'hmmmm', 'aaaaa' and other artifacts" — so what it removes, what it must
/// leave alone, and what it reports are all pinned here.
///
/// Every expectation is a literal transcript in and a literal transcript out:
/// the point of this pass is that it can be reasoned about without audio, and
/// the tests are only worth anything if they show the exact text.
final class DictationScrubberTests: XCTestCase {

    // MARK: - Fillers

    /// The captain's own example. A transcript that was nothing but noise comes
    /// back empty, which the dictation path reads as "nothing was said".
    func testATranscriptOfNothingButFillersIsEmptied() {
        let result = DictationScrubber.scrub("hmmmm aaaaa yyy eee")

        XCTAssertEqual(result.text, "")
        XCTAssertEqual(result.removedFillers, 4)
        XCTAssertTrue(result.removedAnything)
    }

    /// Fillers go wherever they stand, and the words around them survive in
    /// order. "hmm"/"hmmmm"/"aaaaa" is the captain's recording; the rest of the
    /// sentence is the meaning that must not move.
    func testFillersAreRemovedFromAroundTheWordsThatCarryMeaning() {
        XCTAssertEqual(
            DictationScrubber.scrub("So hmm hmmmm aaaaa the translation is bad.").text,
            "So the translation is bad."
        )
        XCTAssertEqual(
            DictationScrubber.scrub("I was uh thinking about um adding a feature.").text,
            "I was thinking about adding a feature."
        )
        XCTAssertEqual(
            DictationScrubber.scrub("Send it to him, uhh.").text,
            "Send it to him."
        )
    }

    /// Polish fillers are the same sounds spelled the Polish way, and they are
    /// removed with the same rule — the pass is not an English-only feature.
    func testPolishFillersAreRemovedToo() {
        XCTAssertEqual(
            DictationScrubber.scrub("To yyy jest aaa test, wiesz.").text,
            "To jest test, wiesz."
        )
        XCTAssertEqual(
            DictationScrubber.scrub("No yyy wiesz co, aaa to jest test.").text,
            "No wiesz co, to jest test."
        )
    }

    /// A plain transcript is returned untouched, so the pass is invisible when
    /// there is nothing to remove.
    func testACleanTranscriptIsUnchanged() {
        for text in [
            "Cześć, jak się masz?",
            "Please send the report to the client today.",
            "Do it tomorrow.",
        ] {
            let result = DictationScrubber.scrub(text)
            XCTAssertEqual(result.text, text)
            XCTAssertFalse(result.removedAnything, text)
        }
    }

    // MARK: - What must not be deleted

    /// The conservative rule the scrub has to obey: a token is never dropped
    /// because it *looks* like filler. These all answer something, so deleting
    /// one would delete meaning.
    func testWordsThatLookLikeFillerButCarryMeaningAreKept() {
        XCTAssertEqual(DictationScrubber.scrub("Uh-huh, that is right.").text, "Uh-huh, that is right.")
        XCTAssertEqual(DictationScrubber.scrub("It was, like, really good.").text, "It was, like, really good.")
        XCTAssertEqual(DictationScrubber.scrub("That is fine, eh?").text, "That is fine, eh?")
    }

    /// A bracket the speaker meant is an aside; only the recogniser's own
    /// descriptions of the audio are annotations.
    func testTheSpeakersOwnAsideSurvives() {
        XCTAssertEqual(DictationScrubber.scrub("Send it (tomorrow) please.").text, "Send it (tomorrow) please.")
    }

    /// A repeated number is a score or an amount, not a stutter.
    func testARepeatedNumberIsNotAStutter() {
        XCTAssertEqual(DictationScrubber.scrub("The score is 3 3 3 today.").text, "The score is 3 3 3 today.")
    }

    // MARK: - Repetition and false starts

    /// The decoder's loop on the page: an immediately repeated word is one word.
    func testImmediatelyRepeatedWordsCollapseToTheirFirstCopy() {
        let result = DictationScrubber.scrub("We need to to the the report.")

        XCTAssertEqual(result.text, "We need to the report.")
        XCTAssertEqual(result.removedRepetitions, 2)
    }

    /// Both spellings of a stutter. The hyphen is the stutter's own mark, so it
    /// leaves with the fragment instead of being pasted as a stray "-".
    func testAFalseStartLeavesNeitherTheFragmentNorItsHyphen() {
        XCTAssertEqual(DictationScrubber.scrub("The p-problem is here.").text, "The problem is here.")
        XCTAssertEqual(DictationScrubber.scrub("The pro- problem is here.").text, "The problem is here.")
    }

    /// A dash the speaker meant is punctuation, not a false start, and it is not
    /// touched by the stutter rule.
    func testASeparatedDashIsNotAFalseStart() {
        let text = "The cost - twenty zloty - is high."
        XCTAssertEqual(DictationScrubber.scrub(text).text, text)
    }

    /// The 56-second recording that repeated one sentence seven times: the
    /// duplicate utterances go and the first one stays.
    func testAWholeRepeatedSentenceKeepsItsFirstCopy() {
        let text = "First test of translation. First test of translation. First test of translation."
        let result = DictationScrubber.scrub(text)

        XCTAssertEqual(result.text, "First test of translation.")
        XCTAssertGreaterThan(result.removedRepetitions, 0)
    }

    // MARK: - Recogniser annotations

    /// The model talking about the audio, not the user's words.
    func testRecogniserAnnotationsAreRemovedAndCounted() {
        let result = DictationScrubber.scrub("Hello there. (speaking in foreign language) How are you?")

        XCTAssertEqual(result.text, "Hello there. How are you?")
        XCTAssertEqual(result.removedAnnotations, 1)
        XCTAssertTrue(result.removedAnything)

        XCTAssertEqual(DictationScrubber.scrub("[Music] Let us begin.").text, "Let us begin.")

        // A transcript of nothing but an annotation is as empty as silence.
        XCTAssertEqual(DictationScrubber.scrub("(music)").text, "")
    }

    // MARK: - Shape

    func testAnEmptyTranscriptStaysEmpty() {
        for text in ["", "   "] {
            let result = DictationScrubber.scrub(text)
            XCTAssertEqual(result.text, "")
            XCTAssertEqual(result.removedFillers, 0)
            XCTAssertEqual(result.removedRepetitions, 0)
            XCTAssertEqual(result.removedAnnotations, 0)
        }
    }

    /// `cleaned` is the text-only door onto the same pass.
    func testCleanedMatchesScrub() {
        XCTAssertEqual(
            DictationScrubber.cleaned("So hmm hmmmm aaaaa the translation is bad."),
            DictationScrubber.scrub("So hmm hmmmm aaaaa the translation is bad.").text
        )
    }
}
