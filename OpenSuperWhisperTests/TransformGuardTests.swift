import XCTest
@testable import OpenSuperWhisper

/// The deterministic guard on the tone path: text in, verdict out, no model
/// call anywhere.
///
/// The positive cases are the exact strings the shipped model produced in
/// `fm-20260924-10/raw`, fed through the guard as they were measured; the
/// negative cases are the legitimate outputs the guard must leave alone.
final class TransformGuardTests: XCTestCase {

    // MARK: - The measured failures, fed through as they were

    /// `Please send the report to the client today, and copy me on the reply.`
    /// came back as this from `qwen2.5-1.5b-instruct-q4_k_m`.
    func testAssistantAcknowledgement_isRejected() {
        let input = "Please send the report to the client today, and copy me on the reply."
        let measured = "Sure, send the report to the client today and make sure to copy me on the reply."
        XCTAssertEqual(
            TransformGuard.rejection(of: measured, for: input, language: .english),
            .assistantFrame("sure")
        )
    }

    /// The preamble the proposed prompt produced on the same model.
    func testPreambleInsteadOfARewrite_isRejected() {
        let input = "Please send the report to the client today."
        let measured = "Sure, here's the rewritten text in a casual register:\n\n"
            + "Sure, send the report to the client today!"
        let rejection = TransformGuard.rejection(of: measured, for: input, language: .english)
        XCTAssertEqual(rejection, .assistantFrame("sure"))
    }

    /// Temperature 0 collapsed a twelve-word run-on into this on the small
    /// model. The frame rule catches it first; the stub rule is what catches the
    /// same collapse when it is not an assistant word.
    func testChatCollapse_isRejected() {
        let input = "ok so the plan is first we test then we deploy and then we watch the logs"
        XCTAssertEqual(
            TransformGuard.rejection(of: "Understood.", for: input, language: .english),
            .assistantFrame("understood")
        )
        XCTAssertEqual(
            TransformGuard.rejection(of: "Plan done.", for: input, language: .english),
            .stub(wordsIn: 17, wordsOut: 2)
        )
    }

    /// Polish frames are caught by the same rule, in Polish.
    func testPolishAssistantFrames_areRejected() {
        let input = "Proszę wysłać raport do klienta dzisiaj."
        XCTAssertEqual(
            TransformGuard.rejection(of: "Oczywiście, wysyłam raport do klienta.", for: input, language: .polish),
            .assistantFrame("oczywiście")
        )
        XCTAssertEqual(
            TransformGuard.rejection(of: "Oto przepisany tekst.", for: input, language: .polish),
            .assistantFrame("oto")
        )
        XCTAssertEqual(
            TransformGuard.rejection(of: "Jasne, wysyłam raport do klienta dzisiaj.", for: input, language: .polish),
            .assistantFrame("jasne")
        )
    }

    func testLabelLines_areRejected() {
        let input = "Please send the report to the client today."
        XCTAssertEqual(
            TransformGuard.rejection(
                of: "Register: formal\nPlease send the report to the client today.",
                for: input,
                language: .english
            ),
            .label("register:")
        )
        XCTAssertEqual(
            TransformGuard.rejection(
                of: "Output: Please send the report to the client today.",
                for: input,
                language: .english
            ),
            .label("output:")
        )
        XCTAssertEqual(
            TransformGuard.rejection(
                of: "The rewritten version: please send the report today.",
                for: input,
                language: .english
            ),
            .label("rewritten version")
        )
    }

    func testLanguageFlip_isRejected() {
        let polish = "Cześć, wysyłam raport do klienta dzisiaj."
        let english = "Hello, I am sending the report to the client today."
        XCTAssertEqual(
            TransformGuard.rejection(of: english, for: polish, language: .polish),
            .languageFlip(expected: .polish)
        )
        XCTAssertEqual(
            TransformGuard.rejection(of: polish, for: english, language: .english),
            .languageFlip(expected: .english)
        )
    }

    // MARK: - The prompt's own delimiter, returned instead of the text

    /// The five measured finals, verbatim, from the captain's own library
    /// (`fm-20260925-15` §8, 87 recordings through the app's own decode and
    /// transform chain): on short dictations the model returned the transform
    /// prompt's own `<<<TRANSCRIPT … TRANSCRIPT>>>` frame instead of, or around,
    /// the text, and the guard's four rules did not see it. The strings below are
    /// the evidence log's bytes, including the two spaces case 1 ends with.
    func testMeasuredPromptFrames_areRejected() {
        let cases: [(input: String, measured: String, language: TransformLanguage, marker: String)] = [
            // 0D5AA205-7FC2-4F53-AA7B-C2E17A3A33B6.wav, 2.8 s, engine en
            (
                "keyboard simulation output is working.",
                "keyboard simulation output is working.  \nTRANSCRIPT",
                .english,
                "TRANSCRIPT"
            ),
            // 4B614AE1-E769-4776-859E-1BD969B3F8E2.wav, 2.5 s, engine en
            ("Now speaking English", "Now speaking English\nTRANSCRIPT", .english, "TRANSCRIPT"),
            // DC187FEA-7E34-4EA3-A8A7-D38482BCD2B5.wav, 1.8 s, engine pl — the
            // frame in Polish, which a check for the English word alone misses
            (
                "font",
                "<<<TRANSKRYPCJA\nfont\nTRANSKRYPCJA>>>",
                .polish,
                "TRANSKRYPCJA"
            ),
            // 880D1B22-6A4C-4BD6-B718-06D01F55AEBD.wav, 1.9 s, engine en
            ("Use of pickguard", "Use of pickguard\nTRANSCRIPT", .english, "TRANSCRIPT"),
            // 81B50264-1B06-4D5A-95BA-1A88821B90CC.wav, 2.5 s, engine en
            (
                "Continue with fixes.",
                "<<<TRANSCRIPT\nContinue with fixes.\nTRANSCRIPT>>>",
                .english,
                "TRANSCRIPT"
            ),
        ]

        for measured in cases {
            XCTAssertEqual(
                TransformGuard.rejection(of: measured.measured, for: measured.input, language: measured.language),
                .promptMarker(measured.marker),
                "not rejected: \(measured.measured)"
            )
            XCTAssertTrue(
                TransformGuard.rejection(of: measured.measured, for: measured.input, language: measured.language)?
                    .notice.contains(measured.marker) == true,
                "the notice names the marker it saw"
            )
        }
    }

    /// The rule reads every line, not just the last one: the same marker with text
    /// after it is still the frame, not the user's text.
    func testPromptMarkerMidAnswer_isRejected() {
        XCTAssertEqual(
            TransformGuard.rejection(
                of: "Now speaking English\nTRANSCRIPT\nAnd the microphone works.",
                for: "Now speaking English",
                language: .english
            ),
            .promptMarker("TRANSCRIPT")
        )
        XCTAssertEqual(
            TransformGuard.rejection(
                of: "The plan <<<TRANSCRIPT is ready.",
                for: "the plan is ready",
                language: .english
            ),
            .promptMarker("TRANSCRIPT"),
            "the brackets cannot arrive in dictated speech, wherever they sit"
        )
    }

    /// The trailing-punctuation gap the first version of this rule had: the
    /// comparison was exact, so the same marker with a full stop or a colon the
    /// model added was delivered. Measured against the rule as committed and
    /// closed here — and the lowercase word, punctuation or not, stays the
    /// user's own.
    func testPromptMarkerWithTrailingPunctuation_isRejected() {
        let cases: [(answer: String, language: TransformLanguage, marker: String)] = [
            ("keyboard simulation output is working.\nTRANSCRIPT.", .english, "TRANSCRIPT"),
            ("keyboard simulation output is working.\nTRANSCRIPT:", .english, "TRANSCRIPT"),
            ("Now speaking English\nTRANSCRIPT!", .english, "TRANSCRIPT"),
            ("font\nTRANSKRYPCJA.", .polish, "TRANSKRYPCJA"),
        ]
        for c in cases {
            XCTAssertEqual(
                TransformGuard.rejection(
                    of: c.answer,
                    for: "keyboard simulation output is working.",
                    language: c.language
                ),
                .promptMarker(c.marker),
                c.answer
            )
        }
        XCTAssertNil(
            TransformGuard.rejection(
                of: "Send the transcript.",
                for: "send the transcript please",
                language: .english
            ),
            "the lowercase word is the dictated text, punctuation and all"
        )
    }

    /// The negative cases the fix must not cost: the ordinary lowercase word in a
    /// dictated sentence is the user's own, and a rewrite that keeps it is
    /// delivered. Both answers differ from their dictation, so the marker rule —
    /// not the "answer is the dictation" shortcut — is what has to leave them
    /// alone.
    func testLowercaseTranscriptWord_isDelivered() {
        XCTAssertNil(
            TransformGuard.rejection(
                of: "I need the transcript by Friday.",
                for: "i need the transcript by friday if possible",
                language: .english
            )
        )
        XCTAssertNil(
            TransformGuard.rejection(
                of: "Send the transcript.",
                for: "send the transcript please",
                language: .english
            )
        )
        // A line that merely starts with a capital: not the frame.
        XCTAssertNil(
            TransformGuard.rejection(
                of: "Transcript\nof the meeting.",
                for: "transcript of the meeting",
                language: .english
            )
        )
    }

    /// The limit the rule chooses, recorded rather than hidden: an all-caps word
    /// inside a sentence is not a line of its own, so it is delivered — the
    /// measured leaks are all the marker standing alone. A dictation *about* the
    /// marker (`make sure the TRANSCRIPT marker is gone`) is a real sentence and
    /// comes back as one.
    func testAllCapsMarkerInsideASentence_isOutOfReach() {
        let input = "make sure the transcript marker is gone from the output"
        XCTAssertNil(
            TransformGuard.rejection(
                of: "Make sure the TRANSCRIPT marker is gone from the output.",
                for: input,
                language: .english
            )
        )
    }

    // MARK: - The frame and the label have to be the model's, not the user's

    /// `Here is …`, `I've …` and a dictated `Sure, …` are ordinary *openings*
    /// someone dictates. A rewrite that keeps the user's own opening is
    /// delivered: the frame rule reads "the model added it", not "it looks like
    /// an assistant". Rejecting these replaced a good rewrite with the raw
    /// transcript and a notice that blamed the model.
    func testFrameTheDictationOpenedWith_isDelivered() {
        XCTAssertNil(
            TransformGuard.rejection(
                of: "Here is the summary I promised, and I'll send it today.",
                for: "here is the summary I promised and I will send it today",
                language: .english
            ),
            "the user's own \"Here is …\" opening is not an assistant frame"
        )
        XCTAssertNil(
            TransformGuard.rejection(
                of: "I've already deployed the backend, and it works fine.",
                for: "i've already deployed the backend and it works fine",
                language: .english
            )
        )
        XCTAssertNil(
            TransformGuard.rejection(
                of: "Sure, let's ship it on Friday.",
                for: "sure let's ship it on friday if nothing breaks",
                language: .english
            )
        )
        XCTAssertNil(
            TransformGuard.rejection(
                of: "Oto jest raport, który obiecałem, i wyślę go dzisiaj.",
                for: "oto jest raport który obiecałem i wyślę go dzisiaj",
                language: .polish
            )
        )
    }

    /// …and the same openings are still rejected when the model is the one that
    /// added them. The measured catch survives, including when the dictation
    /// mentioned the word somewhere that is not its opening — an answer that
    /// *opens* with a frame is the model's, wherever else the word appeared.
    func testFrameTheModelAdded_isStillRejected() {
        let runOn = "ok so the plan is first we test then we deploy and then we watch the logs"
        XCTAssertEqual(
            TransformGuard.rejection(of: "Understood.", for: runOn, language: .english),
            .assistantFrame("understood"),
            "the measured temperature-0 collapse: this dictation never said it"
        )
        XCTAssertEqual(
            TransformGuard.rejection(
                of: "Sure, let's ship it on Friday.",
                for: "let's ship it on friday if nothing breaks",
                language: .english
            ),
            .assistantFrame("sure")
        )
        XCTAssertEqual(
            TransformGuard.rejection(
                of: "Sure, we ship on Friday.",
                for: "i'm not sure maybe we ship on friday",
                language: .english
            ),
            .assistantFrame("sure"),
            "a mid-dictation \"sure\" does not excuse an answer that opens with one"
        )
    }

    /// The announcement and label phrases are the model's addition too: text
    /// *about* the rewritten text, or a `Register:` line the dictation itself
    /// carried, is not an assistant's preamble.
    func testLabelTheDictationAlreadyCarried_isDelivered() {
        XCTAssertNil(
            TransformGuard.rejection(
                of: "The rewritten text should go to the client today, please send it.",
                for: "the rewritten text should go to the client today",
                language: .english
            ),
            "a dictation about the rewritten text is not an announcement"
        )
        XCTAssertNil(
            TransformGuard.rejection(
                of: "Register: formal\nPlease send the report to the client today.",
                for: "register: formal please send the report to the client today",
                language: .english
            ),
            "a label the dictation dictated itself is not the model's label"
        )
    }

    /// …while the same shapes are rejected when the model introduced them.
    func testLabelTheModelAdded_isStillRejected() {
        XCTAssertEqual(
            TransformGuard.rejection(
                of: "The rewritten text: the report should go to the client today.",
                for: "the report should go to the client today",
                language: .english
            ),
            .label("rewritten text")
        )
    }

    /// The Polish counterparts of the announcement phrases, so a Polish preamble
    /// is caught by the same rule as the English one. (The `oto` frame is
    /// already in the frame list; these catch the announcement when it does not
    /// open the answer.)
    func testPolishAnnouncementPhrases_areRejected() {
        let input = "Proszę wysłać raport do klienta dzisiaj."
        XCTAssertEqual(
            TransformGuard.rejection(
                of: "To jest przepisany tekst: proszę wysłać raport do klienta dzisiaj.",
                for: input,
                language: .polish
            ),
            .label("przepisany tekst")
        )
        XCTAssertEqual(
            TransformGuard.rejection(
                of: "Przepisana wersja: proszę wysłać raport do klienta dzisiaj.",
                for: input,
                language: .polish
            ),
            .label("przepisana wersja")
        )
        XCTAssertEqual(
            TransformGuard.rejection(of: "Poniżej oto przepisany raport.", for: input, language: .polish),
            .label("oto przepisany")
        )
    }

    // MARK: - The cases it must not touch

    /// Already in the requested register: the model is expected to return the
    /// dictation unchanged, and that is not a stub, a frame or a flip.
    func testAlreadyInRegister_isUntouched() {
        let text = "Please send the report to the client today."
        XCTAssertNil(TransformGuard.rejection(of: text, for: text, language: .english))
    }

    /// A two-word dictation is not "a sentence", so the stub rule never applies
    /// to it.
    func testTwoWordDictation_isUntouched() {
        XCTAssertNil(
            TransformGuard.rejection(of: "Dzień dobry.", for: "Dzień dobry.", language: .polish)
        )
        XCTAssertNil(
            TransformGuard.rejection(of: "Send it.", for: "Send it now.", language: .english)
        )
    }

    /// A fragment comes back as it is, and comes back whole.
    func testFragment_isUntouched() {
        let text = "the deployment is done and"
        XCTAssertNil(TransformGuard.rejection(of: text, for: text, language: .english))
    }

    /// A technical term from another language inside the text is not a flip: the
    /// detector classifies by the language around it.
    func testMixedLanguageTechnicalTerm_isUntouched() {
        let text = "We deploy the backend na produkcję every Friday evening."
        XCTAssertNil(TransformGuard.rejection(of: text, for: text, language: .english))
        XCTAssertNil(
            TransformGuard.rejection(
                of: "We should deploy the backend na produkcję every Friday evening.",
                for: text,
                language: .english
            ),
            "the technical term does not make the rewrite a language flip"
        )
    }

    /// A real rewrite that changes only the register passes: content is kept,
    /// words count, the language holds.
    func testRegisterRewrite_passes() {
        let input = "I think we should probably just ship it on friday if nothing breaks"
        let output = "I believe we should probably ship it on Friday if nothing breaks."
        XCTAssertNil(TransformGuard.rejection(of: output, for: input, language: .english))
    }

    /// The documented limit: subtle content drift is text the guard cannot judge
    /// — a dropped article and an invented noun both pass it. This test exists
    /// so the limit is recorded, not so the behaviour is wanted.
    func testSubtleContentDrift_isOutOfReach() {
        let input = "invoice number is 423 and the amount is three thousand zloty"
        let droppedArticle = "Invoice number is 423 and the amount is three thousand zloty."
        XCTAssertNil(TransformGuard.rejection(of: droppedArticle, for: input, language: .english))

        let shipped = "I think we should probably just ship it on friday if nothing breaks"
        let inventedNoun = "I think we should probably just ship the product on Friday if nothing breaks."
        XCTAssertNil(TransformGuard.rejection(of: inventedNoun, for: shipped, language: .english))
    }

    /// Clean-up alone carries no tone policy, so the guard is never consulted for
    /// it: the caller gates on `promptTone`. Tone, clean-up-with-tone and the
    /// e-mail mode all carry one, so they are all guarded.
    func testGuardAppliesOnlyToPoliciesThatSendToneText() {
        XCTAssertNil(TransformPolicy.cleanUp(language: .english).promptTone)
        XCTAssertNotNil(TransformPolicy.tone(language: .english, tone: .formal).promptTone)
        XCTAssertNotNil(TransformPolicy.cleanUpWithTone(language: .polish, tone: .casual).promptTone)
        XCTAssertNotNil(TransformPolicy.email(language: .polish, tone: .formal).promptTone)
    }
}
