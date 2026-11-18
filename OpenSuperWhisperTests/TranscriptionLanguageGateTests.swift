import XCTest
@testable import OpenSuperWhisper

/// A whisper engine that answers with a canned transcript and a canned language
/// instead of running a model, so the plumbing from the engine's own
/// `fullLangId` through `TranscriptionService` and into the transform gate can
/// be tested without a model on disk. Also the engine
/// `SpeechModelLanguageGateTests` pairs with an English-only model path, because
/// the guard decides on the transcript the engine produced.
final class StubLanguageWhisperEngine: WhisperEngine {
    private let cannedText: String
    private let cannedLanguage: String?
    private let declaresMultilingual: Bool?
    private let cannedSpeechPresence: SpeechPresence?
    private let cannedSecondReading: String?

    /// `multilingual` is what a loaded context would report. A test that hands
    /// this engine a transcript the *engine* could really have heard stands for
    /// a multilingual model and says so: `TranscriptionService` otherwise falls
    /// back to the machine's selected model when checking for the English-only
    /// conflict, and a leftover selection in the preference domain would refuse
    /// the dictation as an invention. The tests that pin the refusal leave it
    /// `nil`, so the model path they hand the service stays the whole evidence.
    ///
    /// `speechPresence` is what the engine measured about the audio. It defaults
    /// to `nil` — nothing measured — because that is the field's own default and
    /// the answer an engine with no measurement gives; no test that predates it
    /// is refused by it. The tests of the no-speech refusal set it.
    ///
    /// `secondReading` is what the engine's second decode of the same audio
    /// produced, the evidence the corroboration refusal rests on
    /// (`SpeechCorroborationConflict`). It defaults to `nil` for the same
    /// reason: no second reading refuses nothing, and every test that predates
    /// it goes on exactly as it did.
    init(
        text: String,
        language: String?,
        multilingual: Bool? = nil,
        speechPresence: SpeechPresence? = nil,
        secondReading: String? = nil
    ) {
        self.cannedText = text
        self.cannedLanguage = language
        self.declaresMultilingual = multilingual
        self.cannedSpeechPresence = speechPresence
        self.cannedSecondReading = secondReading
        super.init(modelPath: "/stub-model-not-on-disk")
    }

    override var isModelMultilingual: Bool? {
        declaresMultilingual ?? super.isModelMultilingual
    }

    override func transcribeAudioDetailed(url: URL, settings: Settings) async throws -> DetailedTranscription {
        DetailedTranscription(
            text: cannedText,
            segments: [],
            language: cannedLanguage,
            speechPresence: cannedSpeechPresence,
            secondReading: cannedSecondReading
        )
    }

    override func transcribeSamplesDetailed(_ samples: [Float], settings: Settings) async throws -> DetailedTranscription {
        DetailedTranscription(
            text: cannedText,
            segments: [],
            language: cannedLanguage,
            speechPresence: cannedSpeechPresence,
            secondReading: cannedSecondReading
        )
    }
}

/// An engine with no language signal at all (Parakeet/FluidAudio), to pin the
/// `nil` fallback.
private final class LanguageLessEngine: TranscriptionEngine {
    let text: String

    init(text: String) {
        self.text = text
    }

    var isModelLoaded: Bool { true }
    var engineName: String { "LanguageLess" }
    func initialize() async throws {}
    func transcribeAudio(url: URL, settings: Settings) async throws -> String { text }
    func cancelTranscription() {}
    func getSupportedLanguages() -> [String] { ["en"] }
}

/// The wiring that carries the spoken language with the text: the language the
/// engine measured, together with the switches, decides which transform runs —
/// English clean-up alone runs on S1-mini, tone and the e-mail mode run on the
/// instruction model in either language, and a Polish clean-up alone is the
/// deterministic scrub and reaches no model. It is also what the guard refuses
/// on when the model cannot have heard the speech.
@MainActor
final class TranscriptionLanguageGateTests: XCTestCase {

    private let polishText = "Cześć, jak się masz?"
    private let englishText = "Please send the report."

    // MARK: - Helpers

    private func transcribe(
        engine: TranscriptionEngine,
        pcmSamples: [Float]?
    ) async throws -> TranscriptionService.TranscriptionOutput {
        try await TranscriptionService(engine: engine).transcribeAudio(
            url: URL(fileURLWithPath: "/unused-dictation.wav"),
            settings: Settings(),
            operationID: UUID(),
            pcmSamples: pcmSamples
        )
    }

    // MARK: - Engine language reaches the output

    func testWhisperLanguageReachesTheTranscriptionOutput_forFilesAndSamples() async throws {
        let engine = StubLanguageWhisperEngine(text: polishText, language: "pl", multilingual: true)

        let fromFile = try await transcribe(engine: engine, pcmSamples: nil)
        XCTAssertEqual(fromFile.text, polishText)
        XCTAssertEqual(fromFile.language, "pl")

        let fromSamples = try await transcribe(engine: engine, pcmSamples: [0.1, 0.2, 0.3])
        XCTAssertEqual(fromSamples.text, polishText)
        XCTAssertEqual(fromSamples.language, "pl")
    }

    func testSpeechlessEngineReportsNoLanguage() async throws {
        let output = try await transcribe(
            engine: LanguageLessEngine(text: polishText),
            pcmSamples: nil
        )

        XCTAssertEqual(output.text, polishText)
        XCTAssertNil(output.language, "Only whisper reports a language")
    }

    // MARK: - The language drives the transform

    /// The language drives the transform within each job: a tone rewrite happens
    /// in English and in Polish alike, each framed in its own language, while a
    /// Polish clean-up alone — which is the deterministic scrub, not a model call
    /// — is delivered exactly as it was transcribed.
    func testBothLanguagesAreRewrittenInTheirOwnLanguage() async throws {
        final class Recorder {
            var prompts: [String] = []
            var texts: [String] = []
        }
        let recorder = Recorder()
        let service = TransformService(
            localTransform: { prompt, text, _ in
                recorder.prompts.append(prompt)
                recorder.texts.append(text)
                return text
            },
            // The instruction model's route is the one these assertions describe,
            // so the test does not read what is installed on the machine running
            // the suite. Injected, so no weights load.
            modelForPolicy: { _ in TransformModelStandIn.instruct },
            gateSettings: { GateSettings(tone: true, cleanUp: false, toneMode: .formal) }
        )

        let polish = try await transcribe(
            engine: StubLanguageWhisperEngine(text: polishText, language: "pl", multilingual: true),
            pcmSamples: [0.1, 0.2]
        )
        let english = try await transcribe(
            engine: StubLanguageWhisperEngine(text: englishText, language: "en", multilingual: true),
            pcmSamples: [0.1, 0.2]
        )

        let polishOutcome = await service.transformDetailed(polish.text, sourceLanguage: polish.language)
        let englishOutcome = await service.transformDetailed(english.text, sourceLanguage: english.language)

        // Tone is a same-language rewrite in both languages now: each dictation
        // resolves its own tone policy and reaches the model. (The injected model
        // echoes its framed user turn, which the guard rejects as the prompt's own
        // marker, so the transcript is what is delivered; the routing is what this
        // test is about.)
        XCTAssertEqual(polishOutcome.policy, .tone(language: .polish, tone: .formal))
        XCTAssertTrue(polishOutcome.didRunModel)
        XCTAssertEqual(englishOutcome.policy, .tone(language: .english, tone: .formal))
        XCTAssertTrue(englishOutcome.didRunModel)

        XCTAssertEqual(recorder.prompts.count, 2, "both dictations are rewritten")
        XCTAssertEqual(recorder.texts.count, 2)

        // Each turn carries its own transcript inside the frame, and each prompt
        // is written in the language it will rewrite.
        let polishTurn = try XCTUnwrap(recorder.texts.first)
        let englishTurn = try XCTUnwrap(recorder.texts.last)
        XCTAssertTrue(polishTurn.contains("<<<TRANSCRIPT\n\(polishText)\nTRANSCRIPT>>>"), polishTurn)
        XCTAssertTrue(polishTurn.contains("(polski)"), polishTurn)
        XCTAssertFalse(polishTurn.contains("(English)"), "a Polish turn is not framed as English: \(polishTurn)")
        XCTAssertTrue(englishTurn.contains("<<<TRANSCRIPT\n\(englishText)\nTRANSCRIPT>>>"), englishTurn)
        XCTAssertTrue(englishTurn.contains("(English)"), englishTurn)
        XCTAssertFalse(englishTurn.contains("(polski)"), "an English turn is never framed as Polish: \(englishTurn)")

        let polishPrompt = try XCTUnwrap(recorder.prompts.first)
        let englishPrompt = try XCTUnwrap(recorder.prompts.last)
        XCTAssertTrue(polishPrompt.contains("po polsku"), polishPrompt)
        XCTAssertTrue(englishPrompt.contains("English text"), englishPrompt)
    }

    /// An engine that reports nothing leaves the transcript itself as the signal,
    /// which is the Parakeet path — and, with clean-up alone switched on, the
    /// heuristic's verdict decides exactly what the engine's does: Polish text is
    /// the deterministic scrub and reaches no model, English text is cleaned up.
    func testEngineWithNoLanguageSignal_fallsBackToTheTranscriptText() async throws {
        final class Recorder {
            var prompts: [String] = []
        }
        let recorder = Recorder()
        let service = TransformService(
            localTransform: { prompt, text, _ in
                recorder.prompts.append(prompt)
                return text
            },
            // Same pin as in the tone gate above: the instruction model's route
            // is the one these assertions describe, and the default resolution
            // would take the normalizer's route on a machine that has S1-mini
            // installed.
            modelForPolicy: { _ in TransformModelStandIn.instruct },
            gateSettings: { GateSettings(tone: false, cleanUp: true, toneMode: .formal) }
        )

        let polish = try await transcribe(engine: LanguageLessEngine(text: polishText), pcmSamples: nil)
        XCTAssertNil(polish.language)
        let polishOutcome = await service.transformDetailed(polish.text, sourceLanguage: polish.language)
        XCTAssertEqual(polishOutcome.text, polish.text, "the Polish text is placed, and then left alone")
        XCTAssertNil(polishOutcome.policy)
        XCTAssertFalse(polishOutcome.didRunModel)
        XCTAssertEqual(recorder.prompts.count, 0,
                       "Polish clean-up alone is the deterministic scrub, so no model is asked")

        let english = try await transcribe(engine: LanguageLessEngine(text: englishText), pcmSamples: nil)
        let englishOutcome = await service.transformDetailed(english.text, sourceLanguage: english.language)
        XCTAssertEqual(recorder.prompts.count, 1, "English text is placed by the heuristic and cleaned up")
        let englishPrompt = try XCTUnwrap(recorder.prompts.first)
        XCTAssertTrue(englishPrompt.contains("English text"), englishPrompt)
        XCTAssertEqual(englishOutcome.text, english.text)
    }
}

/// The English-only-model guard, re-keyed to the transcript.
///
/// The captain's combination — `ggml-tiny.en.bin` writing English over Polish
/// speech — must be refused, named, and offered a fix. With the manual language
/// picker gone there is no setting left to compare against, and an `.en` model
/// cannot detect anything, so the evidence is the text the model produced: the
/// `LanguageDetector` heuristic decides, and English dictation can never be
/// caught by it.
///
/// The rule is asserted with no model at all (`SpeechModelLanguageGate.conflict`
/// takes the model's verdict, its path and the transcript as inputs), and the
/// refusal is then driven through the real `TranscriptionService`, because
/// "surfaced" is only true if nothing was transcribed.
@MainActor
final class SpeechModelLanguageGateTests: XCTestCase {

    private var temporaryDirectory: URL!
    private var modelsDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osw-language-gate-\(UUID().uuidString)")
        modelsDirectory = temporaryDirectory
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        // What is on a real machine: the English-only model the app ships, the
        // multilingual one the app recommends, and the VAD weights that sit
        // beside the weights but are not a speech model.
        for name in ["ggml-tiny.en.bin", "ggml-large-v3-turbo.bin", "ggml-silero-v5.1.2.bin"] {
            try Data([0]).write(to: modelsDirectory.appendingPathComponent(name))
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        try super.tearDownWithError()
    }

    // MARK: - The rule

    /// The exact failure, and the story the user is told: the model, what the
    /// dictation looks like, what whisper did instead, and the model already on
    /// this machine that fixes it.
    func testEnglishOnlyModelWritingOverPolishIsRefusedWithBothNamed() throws {
        let conflict = try XCTUnwrap(SpeechModelLanguageGate.conflict(
            modelPath: "/models/ggml-tiny.en.bin",
            isMultilingual: false,
            transcript: "Cześć, jak się masz? Chciałbym wysłać raport do klienta.",
            modelsDirectory: modelsDirectory
        ))

        XCTAssertEqual(conflict.modelName, "ggml-tiny.en.bin")
        XCTAssertEqual(conflict.detectedLanguageCode, "pl")
        XCTAssertEqual(conflict.detectedLanguageName, "Polish")
        XCTAssertEqual(conflict.remedyModelName, "ggml-large-v3-turbo.bin")
        XCTAssertEqual(conflict.remedyButtonTitle, "Use ggml-large-v3-turbo.bin")
        XCTAssertTrue(conflict.message.contains("ggml-tiny.en.bin"))
        XCTAssertTrue(conflict.message.contains("Polish"))
        XCTAssertTrue(conflict.message.contains("ggml-large-v3-turbo.bin"))
    }

    /// English is what an English-only model is for: the guard must never stand
    /// between the user and plain English dictation.
    func testEnglishIsNeverRefused() throws {
        for transcript in [
            "Please send the report to the client today.",
            "The meeting is at three.",
            "I sent it yesterday.",
        ] {
            XCTAssertNil(SpeechModelLanguageGate.conflict(
                modelPath: "/models/ggml-tiny.en.bin",
                isMultilingual: false,
                transcript: transcript,
                modelsDirectory: modelsDirectory
            ), transcript)
        }
    }

    /// Nothing to read is not a conflict: with no transcript yet, or text too
    /// short for the heuristic to place, there is no evidence of anything.
    func testNoTranscriptOrUnplaceableTextIsNotRefused() throws {
        for transcript in [nil, "", "   \n ", "Do it", "Ok"] as [String?] {
            XCTAssertNil(SpeechModelLanguageGate.conflict(
                modelPath: "/models/ggml-tiny.en.bin",
                isMultilingual: false,
                transcript: transcript,
                modelsDirectory: modelsDirectory
            ), transcript ?? "nil")
        }
    }

    /// The floor on this gate: **one, two and three words are never refused**,
    /// however the heuristic reads them.
    ///
    /// Each of these is English and each is read as Polish by the heuristic —
    /// the verdicts are asserted, not assumed, because that is what makes the
    /// floor the thing doing the work here. Refusing on that verdict is the
    /// defect this pins: an English dictation told it is Polish, and blocked
    /// behind a model the user does not need. The three one-word cases are the
    /// traps the measurement named; the two- and three-word ones are the same
    /// coin flip one word longer. Above the floor the same reading is a
    /// refusal — see the next test.
    func testAShortEnglishTranscriptThatReadsAsPolishIsNeverRefused() throws {
        for transcript in [
            "Miami",                 // 1 word
            "nowadays",              // 1 word
            "brownie",               // 1 word
            "nowadays Miami",        // 2 words
            "good brownie",          // 2 words
            "nowadays Miami brownie",// 3 words
        ] {
            XCTAssertEqual(
                SpeechModelLanguageGate.contentWords(of: transcript).count,
                transcript.split(separator: " ").count,
                "the word counts below are the app's own: \(transcript)"
            )
            XCTAssertEqual(
                LanguageDetector.detect(transcript).languageCode,
                "pl",
                "this case only means something while the heuristic really does read it as Polish: \(transcript)"
            )
            XCTAssertNil(
                SpeechModelLanguageGate.conflict(
                    modelPath: "/models/ggml-tiny.en.bin",
                    isMultilingual: false,
                    transcript: transcript,
                    modelsDirectory: modelsDirectory
                ),
                "under four words the heuristic's verdict is not evidence: \(transcript)"
            )
        }
    }

    /// The same reading one word longer **is** a refusal: at four words the
    /// heuristic agrees with the truth 92.9% of the time and stops being a coin
    /// flip, so the gate decides on it — and the floor is exactly where the
    /// captain's own Polish dictation sits (`Cześć, jak się masz?`, four words,
    /// refused as it always was).
    func testAFourWordTranscriptThatReadsAsPolishIsRefused() throws {
        XCTAssertEqual(SpeechModelLanguageGate.languageConflictMinimumWords, 4)

        let fourWordEnglish = "nowadays Miami brownie and"
        XCTAssertEqual(LanguageDetector.detect(fourWordEnglish).languageCode, "pl")
        XCTAssertEqual(SpeechModelLanguageGate.contentWords(of: fourWordEnglish).count, 4)

        let conflict = try XCTUnwrap(
            SpeechModelLanguageGate.conflict(
                modelPath: "/models/ggml-tiny.en.bin",
                isMultilingual: false,
                transcript: fourWordEnglish,
                modelsDirectory: modelsDirectory
            ),
            "four words is where the heuristic's verdict becomes evidence"
        )
        XCTAssertEqual(conflict.detectedLanguageCode, "pl")
        XCTAssertEqual(conflict.detectedLanguageName, "Polish")
    }

    /// And from there it behaves as it always did: the transcript that is
    /// exactly at the floor is refused, and so is the longer one — both the
    /// Polish of his own dictation.
    func testTranscriptsFromTheFloorUpBehaveAsBefore() throws {
        for transcript in [
            "Cześć, jak się masz?",                                     // 4 words, at the floor
            "Cześć, jak się masz? Chciałbym wysłać raport do klienta.", // 11 words
        ] {
            XCTAssertGreaterThanOrEqual(
                SpeechModelLanguageGate.contentWords(of: transcript).count,
                SpeechModelLanguageGate.languageConflictMinimumWords,
                transcript
            )
            XCTAssertNotNil(
                SpeechModelLanguageGate.conflict(
                    modelPath: "/models/ggml-tiny.en.bin",
                    isMultilingual: false,
                    transcript: transcript,
                    modelsDirectory: modelsDirectory
                ),
                transcript
            )
        }
    }

    /// A multilingual model hears every language, so nothing is refused —
    /// including when the loaded context and the file name disagree, where the
    /// context is the one that counts.
    func testAMultilingualModelIsNeverRefused() throws {
        XCTAssertNil(SpeechModelLanguageGate.conflict(
            modelPath: "/models/ggml-large-v3-turbo.bin",
            isMultilingual: true,
            transcript: "Cześć, jak się masz?",
            modelsDirectory: modelsDirectory
        ))
        XCTAssertNil(SpeechModelLanguageGate.conflict(
            modelPath: "/models/ggml-tiny.en.bin",
            isMultilingual: true,
            transcript: "Cześć, jak się masz?",
            modelsDirectory: modelsDirectory
        ))
    }

    /// Before a model is loaded there is no context to ask, so the file name is
    /// the only signal — and it is enough for the captain's own file.
    func testTheFileNameAloneRefusesAnEnglishOnlyModel() throws {
        for name in ["ggml-tiny.en.bin", "ggml-base.en.bin", "ggml-small.en-q5_1.bin"] {
            XCTAssertNotNil(
                SpeechModelLanguageGate.conflict(
                    modelPath: "/models/\(name)",
                    isMultilingual: nil,
                    transcript: "Cześć, jak się masz?",
                    modelsDirectory: modelsDirectory
                ),
                name
            )
        }
    }

    /// Nothing selected is not this guard's business: there is no model to blame
    /// and nothing to refuse — a multilingual model with the same transcript is
    /// fine.
    func testNoModelIsNotRefused() throws {
        XCTAssertNil(SpeechModelLanguageGate.conflict(
            modelPath: nil,
            isMultilingual: nil,
            transcript: "Cześć, jak się masz?",
            modelsDirectory: modelsDirectory
        ))
    }

    /// A model that hears Polish does not need this guard, and a model whose
    /// name is not the English-only family is never blamed.
    func testOnlyEnglishOnlyModelsAreBlamed() throws {
        for name in ["ggml-large-v3-turbo.bin", "ggml-medium.bin", "ggml-ivrit-large-v3-turbo.bin"] {
            XCTAssertNil(SpeechModelLanguageGate.conflict(
                modelPath: "/models/\(name)",
                isMultilingual: nil,
                transcript: "Cześć, jak się masz?",
                modelsDirectory: modelsDirectory
            ), name)
        }
    }

    /// The offered fix is a real multilingual model: the recommended one when it
    /// is installed, and never the English-only model or the VAD weights.
    func testTheOfferedFixIsAUsableMultilingualModel() throws {
        XCTAssertEqual(
            SpeechModelLanguageGate.installedMultilingualModel(in: modelsDirectory)?.lastPathComponent,
            "ggml-large-v3-turbo.bin"
        )

        let bare = temporaryDirectory.appendingPathComponent("bare")
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        for name in ["ggml-tiny.en.bin", "ggml-silero-v5.1.2.bin"] {
            try Data([0]).write(to: bare.appendingPathComponent(name))
        }
        XCTAssertNil(
            SpeechModelLanguageGate.installedMultilingualModel(in: bare),
            "Neither an English-only model nor the VAD weights can fix this"
        )
    }

    // MARK: - The refusal

    private func englishOnlyService(text: String, language: String?) -> TranscriptionService {
        TranscriptionService(
            selection: TranscriptionService.EngineSelection(
                engine: "whisper",
                modelPath: "/models/ggml-tiny.en.bin",
                modelVersion: ""
            ),
            engineLoader: { _ in StubLanguageWhisperEngine(text: text, language: language) }
        )
    }

    private func transcribe(
        _ service: TranscriptionService,
        settings: Settings = Settings()
    ) async throws -> TranscriptionService.TranscriptionOutput {
        try await service.transcribeAudio(
            url: URL(fileURLWithPath: "/unused-dictation.wav"),
            settings: settings,
            operationID: UUID(),
            pcmSamples: nil
        )
    }

    /// `Settings()` reads the user's `noSpeechThreshold` from the preference
    /// domain, which other tests write to; the no-speech rule is a comparison
    /// against that number, so the tests that exercise it state it.
    private func settings(noSpeechThreshold: Double = 0.6) -> Settings {
        var settings = Settings()
        settings.noSpeechThreshold = noSpeechThreshold
        return settings
    }

    /// The captain's case, refused by the service rather than kept: the model
    /// wrote English over Polish speech, so no transcript is published and
    /// nothing is pasted.
    func testEnglishOnlyModelWritingOverPolishIsRefusedInsteadOfKept() async throws {
        // What `ggml-tiny.en.bin` produced from Polish speech: whispered English
        // ("There are some people..."), and — the case the guard can see — the
        // Polish words it wrote instead of hearing.
        let service = englishOnlyService(text: "Cześć, jak się masz? Proszę wysłać raport.", language: nil)

        do {
            let output = try await transcribe(service)
            XCTFail("an English-only model over Polish speech must not publish a transcript; got \(output.text)")
        } catch let error as TranscriptionError {
            guard case .speechLanguageConflict(let conflict) = error else {
                return XCTFail("expected speechLanguageConflict, got \(error)")
            }
            XCTAssertEqual(conflict.modelName, "ggml-tiny.en.bin")
            XCTAssertEqual(conflict.detectedLanguageCode, "pl")
        }

        XCTAssertFalse(service.isTranscribing, "a refused dictation must not look like one in progress")
        XCTAssertEqual(service.transcribedText, "", "nothing was published")
    }

    /// The same model and engine over English speech: dictation works, so the
    /// guard refuses the impossible pair and not the model.
    func testEnglishOnlyModelStillTranscribesEnglish() async throws {
        let service = englishOnlyService(text: "Please send the report.", language: nil)

        let output = try await transcribe(service)

        XCTAssertEqual(output.text, "Please send the report.")
        XCTAssertNil(output.language, "an English-only model measures nothing")
    }

    /// A multilingual model on disk — the remedy the alert offers — produces a
    /// Polish transcript that is kept, because it could really have heard it.
    func testAMultilingualModelKeepsThePolishTranscript() async throws {
        let service = TranscriptionService(
            selection: TranscriptionService.EngineSelection(
                engine: "whisper",
                modelPath: "/models/ggml-large-v3-turbo.bin",
                modelVersion: ""
            ),
            engineLoader: { _ in StubLanguageWhisperEngine(text: "Cześć, jak się masz?", language: "pl") }
        )

        let output = try await transcribe(service)

        XCTAssertEqual(output.text, "Cześć, jak się masz?")
        XCTAssertEqual(output.language, "pl")
    }

    // MARK: - Which model the dictation runs on

    /// With a multilingual model on the machine, dictation does not run on the
    /// English-only one. A `.en` model measures no language at all, so Polish
    /// speech comes back as fluent English nobody spoke, and no gate reading
    /// the transcript can see it: the text is English.
    func testAnInstalledMultilingualModelIsPreferredOverAnEnglishOnlyOne() throws {
        let actual = SpeechModelLanguageGate.preferredDictationModelPath(
            over: modelsDirectory.appendingPathComponent("ggml-tiny.en.bin").path,
            modelsDirectory: modelsDirectory
        )
        // Compare resolved paths: the temporary directory is reached through /var,
        // which is a symlink to /private/var, so the raw strings differ while the
        // file is the same one. What the gate returns is what it found, and finding
        // the multilingual model is the behaviour under test.
        let resolvedActual = actual.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        let expected = URL(fileURLWithPath: modelsDirectory.appendingPathComponent("ggml-large-v3-turbo.bin").path)
            .resolvingSymlinksInPath().path
        if resolvedActual != expected {
            let listing = (try? FileManager.default.contentsOfDirectory(atPath: modelsDirectory.path).sorted().joined(separator: ",")) ?? "unreadable"
            XCTFail("GATE ACTUAL=[\(resolvedActual ?? "nil")] EXPECTED=[\(expected)] DIR=[\(listing)]")
        }
    }

    /// With nothing but English-only models installed, the resolved model runs
    /// as it always did — the preference cannot invent a model that is not
    /// there, and the conflict gate still refuses the transcript and names the
    /// fix.
    func testNothingMultilingualLeavesTheResolvedModelAlone() throws {
        let bare = temporaryDirectory.appendingPathComponent("bare")
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        let englishOnly = bare.appendingPathComponent("ggml-tiny.en.bin")
        try Data([0]).write(to: englishOnly)

        XCTAssertEqual(
            SpeechModelLanguageGate.preferredDictationModelPath(over: englishOnly.path, modelsDirectory: bare),
            englishOnly.path
        )
        XCTAssertNil(SpeechModelLanguageGate.preferredDictationModelPath(over: nil, modelsDirectory: bare))
    }

    /// A model that can already hear every language is never swapped: this is a
    /// preference about a model that cannot hear, not a rewrite of the choice.
    func testAMultilingualSelectionIsLeftAsItIs() throws {
        let selected = modelsDirectory.appendingPathComponent("ggml-medium.bin")
        try Data([0]).write(to: selected)

        XCTAssertEqual(
            SpeechModelLanguageGate.preferredDictationModelPath(
                over: selected.path,
                modelsDirectory: modelsDirectory
            ),
            selected.path
        )
    }

    // MARK: - No speech in the recording

    /// Only evidence refuses: the VAD's verdict, or a measured no-speech
    /// probability at or above the user's own threshold. No measurement is not
    /// evidence, which is what keeps every engine that does not measure working
    /// exactly as before.
    func testOnlyMeasuredNoSpeechRefuses() throws {
        XCTAssertNil(
            SpeechModelLanguageGate.noSpeechConflict(presence: nil, noSpeechThreshold: 0.6),
            "nothing measured is not evidence"
        )
        XCTAssertNil(
            SpeechModelLanguageGate.noSpeechConflict(
                presence: .measured(meanNoSpeechProbability: 0.59),
                noSpeechThreshold: 0.6
            ),
            "under the threshold is speech"
        )
        XCTAssertNotNil(
            SpeechModelLanguageGate.noSpeechConflict(
                presence: .measured(meanNoSpeechProbability: 0.6),
                noSpeechThreshold: 0.6
            ),
            "at the threshold is over the line, the same line whisper is given"
        )
        XCTAssertNotNil(
            SpeechModelLanguageGate.noSpeechConflict(presence: .noSpeechSegment, noSpeechThreshold: 0.6),
            "the VAD finding no speech segment is evidence on its own"
        )
    }

    /// The refusal says what to act on — there was no speech — and names the
    /// model that wrote over it, rather than reading like a language error.
    func testTheNoSpeechMessageNamesTheModelAndTheSilence() throws {
        let refusal = try XCTUnwrap(
            SpeechModelLanguageGate.noSpeechConflict(
                presence: .measured(meanNoSpeechProbability: 0.9),
                noSpeechThreshold: 0.6,
                modelPath: "/models/ggml-tiny.en.bin"
            )
        )

        XCTAssertEqual(refusal.title, "No speech was detected")
        XCTAssertTrue(refusal.message.contains("No speech was detected"), refusal.message)
        XCTAssertTrue(refusal.message.contains("ggml-tiny.en.bin"), refusal.message)
        XCTAssertTrue(refusal.message.contains("no-speech probability 0.90"), refusal.message)
        XCTAssertFalse(refusal.message.contains("understands English only"), refusal.message)
    }

    /// A multilingual model does not save an invention over silence: the text
    /// is refused before anything is published, and the measurement travels
    /// with it.
    func testAMeasuredNonSpeechTranscriptIsRefusedInsteadOfKept() async throws {
        let service = TranscriptionService(
            selection: TranscriptionService.EngineSelection(
                engine: "whisper",
                modelPath: "/models/ggml-large-v3-turbo.bin",
                modelVersion: ""
            ),
            engineLoader: { _ in
                StubLanguageWhisperEngine(
                    text: "Thank you for watching!",
                    language: "en",
                    multilingual: true,
                    speechPresence: .measured(meanNoSpeechProbability: 0.92)
                )
            }
        )

        do {
            let output = try await transcribe(service, settings: settings())
            XCTFail("a transcript whose segments are not speech must not publish; got \(output.text)")
        } catch let error as TranscriptionError {
            guard case .noSpeechDetected(let refusal) = error else {
                return XCTFail("expected noSpeechDetected, got \(error)")
            }
            XCTAssertEqual(refusal.presence, .measured(meanNoSpeechProbability: 0.92))
            XCTAssertEqual(refusal.modelName, "ggml-large-v3-turbo.bin")
        }

        XCTAssertFalse(service.isTranscribing, "a refused dictation must not look like one in progress")
        XCTAssertEqual(service.transcribedText, "", "nothing was published")
    }

    /// The VAD's verdict travels the same path: a recording with no speech
    /// segment is refused rather than published as the empty transcript the
    /// engine returns, and the threshold does not enter into it.
    func testARecordingWithNoSpeechSegmentIsRefused() async throws {
        let service = TranscriptionService(
            selection: TranscriptionService.EngineSelection(
                engine: "whisper",
                modelPath: "/models/ggml-large-v3-turbo.bin",
                modelVersion: ""
            ),
            engineLoader: { _ in
                StubLanguageWhisperEngine(
                    text: "",
                    language: nil,
                    multilingual: true,
                    speechPresence: .noSpeechSegment
                )
            }
        )

        do {
            _ = try await transcribe(service, settings: settings())
            XCTFail("a recording with no speech segment must not publish")
        } catch let error as TranscriptionError {
            guard case .noSpeechDetected(let refusal) = error else {
                return XCTFail("expected noSpeechDetected, got \(error)")
            }
            XCTAssertEqual(refusal.presence, .noSpeechSegment)
        }
    }

    /// Speech that was really there goes on through the language gate as it did
    /// before, measurement and all.
    func testMeasuredSpeechIsStillPublished() async throws {
        let service = TranscriptionService(
            selection: TranscriptionService.EngineSelection(
                engine: "whisper",
                modelPath: "/models/ggml-large-v3-turbo.bin",
                modelVersion: ""
            ),
            engineLoader: { _ in
                StubLanguageWhisperEngine(
                    text: "Cześć, jak się masz?",
                    language: "pl",
                    multilingual: true,
                    speechPresence: .measured(meanNoSpeechProbability: 0.02)
                )
            }
        )

        let output = try await transcribe(service, settings: settings())

        XCTAssertEqual(output.text, "Cześć, jak się masz?")
        XCTAssertEqual(output.language, "pl")
        XCTAssertEqual(output.speechPresence, .measured(meanNoSpeechProbability: 0.02))
    }
}
