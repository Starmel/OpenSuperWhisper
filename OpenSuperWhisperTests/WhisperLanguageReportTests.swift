import XCTest
@testable import OpenSuperWhisper

/// The language whisper reports for one utterance — the signal that decides
/// which model rewrites the dictation, and what the English-only-model guard can
/// see.
///
/// There is no language setting any more: the decoder is never conditioned on
/// one, and every case here is the auto-detect path. Needs a real model, and
/// resolves it itself: the bundled English-only `ggml-tiny.en.bin` and the
/// test's own multilingual model (`OSW_TEST_MULTILINGUAL_MODEL`, or a copy
/// cached in the checkout). The machine's own selection is never consulted — see
/// `TestFixtures`.
final class WhisperLanguageReportTests: XCTestCase {

    // MARK: - Helpers

    private func transcribeFixture(model: URL) async throws -> WhisperEngine.DetailedTranscription {
        let engine = WhisperEngine(modelPath: model.path)
        try await engine.initialize()
        defer { engine.unload() }

        // Nothing about the language is set: the engine always measures it.
        var settings = Settings()
        settings.showTimestamps = false
        settings.initialPrompt = ""
        settings.useBeamSearch = false
        settings.temperature = 0
        settings.noSpeechThreshold = 0.6
        settings.suppressBlankAudio = true

        return try await engine.transcribeAudioDetailed(
            url: try TestFixtures.speechSample(),
            settings: settings
        )
    }

    // MARK: - The decoder is never told a language

    /// `params.language` is always `nil` and `params.detectLanguage` stays
    /// `false`: the app has no language setting, and setting `detectLanguage`
    /// would make whisper.cpp return right after detection, without transcribing
    /// anything at all.
    func testTheDecoderIsNeverConditionedOnALanguage() {
        let params = WhisperEngine.makeFullParams(
            settings: Settings(),
            nThreads: 4,
            modelTextContext: 448,
            initialPromptTokenCount: 0
        )

        XCTAssertNil(params.language, "the app never picks the language: the model measures it")
        XCTAssertFalse(params.detectLanguage, "detectLanguage would skip the transcription entirely")
    }

    // MARK: - Auto-detect (the only mode there is)

    /// A multilingual model: the language comes from the same `whisper_full` call
    /// that produced the text (the design study measured `en` at p = 0.9982 on
    /// this fixture), and costs nothing extra on top of the transcription.
    func testMultilingualModelReportsTheSpokenLanguage() async throws {
        let result = try await transcribeFixture(model: try TestFixtures.multilingualModel())

        XCTAssertEqual(result.language, "en")
        XCTAssertFalse(result.text.isEmpty)
    }

    /// A model that cannot detect: whisper.cpp reports a meaningless id for
    /// English-only models (`fa`/`ur` at p = 0.01, measured), so the engine must
    /// refuse it and let the transcript heuristic decide.
    func testEnglishOnlyModelReportsNothing() async throws {
        let result = try await transcribeFixture(model: try TestFixtures.tinyEnglishModel())

        XCTAssertNil(result.language, "A non-multilingual model cannot measure a language")
        XCTAssertFalse(result.text.isEmpty, "…and it still transcribes English")
    }
}
