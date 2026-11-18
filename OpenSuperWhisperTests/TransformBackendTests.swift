import XCTest
@testable import OpenSuperWhisper

/// What the transform does with the model's answer, and which model each job and
/// language runs on. The built-in runtime is driven through an injected local
/// transform, so no test here loads real weights.
final class TransformBackendTests: XCTestCase {

    private final class LocalRecorder {
        var systemPrompts: [String] = []
        var userTexts: [String] = []
        /// The model each call was routed to, so a test can assert which one a
        /// job and language resolved to — by name, without loading any weights.
        var models: [TransformModel] = []
        var result: Result<String, Error> = .success("Please send the report.")
        var calls: Int { systemPrompts.count }
    }

    private func service(
        local: LocalRecorder,
        settings: GateSettings = GateSettings(tone: true, cleanUp: false, toneMode: .neutral),
        model: @escaping (TransformPolicy) -> TransformModel = { _ in TransformModelStandIn.instruct }
    ) -> TransformService {
        TransformService(
            localTransform: { systemPrompt, userText, chosen in
                local.systemPrompts.append(systemPrompt)
                local.userTexts.append(userText)
                local.models.append(chosen)
                return try local.result.get()
            },
            modelForPolicy: model,
            gateSettings: { settings }
        )
    }

    // MARK: - The in-process runtime is the only backend

    /// There is no second backend and no endpoint: every transform runs on the
    /// weights the app owns, in this process.
    func testEveryTransformRunsInProcess() async {
        let local = LocalRecorder()
        let subject = service(local: local)

        let result = await subject.transformIfEnabled("Please send the report.", sourceLanguage: "en")

        XCTAssertEqual(result, "Please send the report.")
        // A tone turn is framed and delimited — the transcript is handed over
        // inside the delimiters, not as a bare request the model could obey.
        // That framing is the invariant here; the sentences themselves are
        // `TransformServiceTests`' business, not a copy pinned twice.
        let userTurn = local.userTexts.first ?? ""
        XCTAssertEqual(local.calls, 1)
        XCTAssertNotEqual(userTurn, "Please send the report.", "the transcript is not sent as it was dictated")
        XCTAssertTrue(userTurn.contains("<<<TRANSCRIPT\nPlease send the report.\nTRANSCRIPT>>>"), userTurn)
    }

    // MARK: - Response handling

    func testFailure_returnsTheRawTranscript() async {
        let local = LocalRecorder()
        local.result = .failure(TransformModelError.notInstalled("Test Model"))
        let subject = service(local: local)

        let result = await subject.transformIfEnabled("Please send the report.", sourceLanguage: "en")

        XCTAssertEqual(result, "Please send the report.",
                       "a missing or broken model must still paste what was said")
    }

    func testCancellation_returnsTheRawTranscript() async {
        let local = LocalRecorder()
        local.result = .failure(CancellationError())
        let subject = service(local: local)

        let result = await subject.transformIfEnabled("Please send the report.", sourceLanguage: "en")

        XCTAssertEqual(result, "Please send the report.")
    }

    func testReasoningTracesAreStripped() async {
        let local = LocalRecorder()
        local.result = .success("<think>let me think</think>Please send it.")
        let subject = service(local: local)

        let result = await subject.transformIfEnabled("Please send the report.", sourceLanguage: "en")

        XCTAssertEqual(result, "Please send it.")
    }

    func testAnEmptyAnswerIsRejected() async {
        let local = LocalRecorder()
        local.result = .success("<think>nothing useful</think>")
        let subject = service(local: local)

        let result = await subject.transformIfEnabled("Please send the report.", sourceLanguage: "en")

        XCTAssertEqual(result, "Please send the report.")
    }

    /// Both switches off is the default install: no model is resolved at all, so
    /// no weights can be loaded by a dictation that asked for nothing.
    func testBothSwitchesOff_resolveNoModelAndMakeNoCall() async {
        for language in ["pl", "en"] {
            let local = LocalRecorder()
            let subject = service(
                local: local,
                settings: GateSettings(tone: false, cleanUp: false, toneMode: .neutral),
                model: { _ in
                    XCTFail("no model may be resolved when nothing is switched on")
                    return TransformModelStandIn.instruct
                }
            )

            let text = language == "pl" ? "Cześć, jak się masz?" : "Please send the report."
            let result = await subject.transformIfEnabled(text, sourceLanguage: language)

            XCTAssertEqual(result, text)
            XCTAssertTrue(local.models.isEmpty, "\(language): no model call")
        }
    }

    // MARK: - Which model a job runs on

    /// The routing is by job first and language second, because the two backends
    /// are not interchangeable: a tone (Polish or English alike) and the e-mail
    /// mode take the instruction model, English clean-up alone takes the
    /// normalizer, and a Polish clean-up policy is never handed out by the gate
    /// at all — the deterministic scrub is what Polish clean-up is. What is on
    /// disk does not change the answer; a missing file is what the runtime
    /// refuses on, with the file to download.
    func testEachJobResolvesToItsBackend() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osw-preference-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = TransformModelManager(
            directory: directory,
            catalogue: TransformModelManager.availableModels
        )

        // English clean-up alone: the normalizer, built for exactly that job and a
        // tenth of the instruction model's memory.
        XCTAssertEqual(manager.model(for: .cleanUp(language: .english)).id,
                       TransformModelManager.normalizerModelID)

        // Every tone, in either language, and the e-mail mode: the instruction
        // model. Polish tone is the reason it exists.
        let tonePolicies: [TransformPolicy] = [
            .tone(language: .english, tone: .formal),
            .tone(language: .polish, tone: .formal),
            .cleanUpWithTone(language: .english, tone: .neutral),
            .cleanUpWithTone(language: .polish, tone: .casual),
            .email(language: .english, tone: .formal),
            .email(language: .polish, tone: .neutral),
        ]
        for policy in tonePolicies {
            XCTAssertEqual(manager.model(for: policy).id, TransformModelManager.toneModelID, "\(policy)")
        }

        // A Polish clean-up policy never exists — `TransformPolicy.resolve`
        // refuses it — but `model(for:)` covers the whole enum, and it answers
        // with the instruction model rather than the English-only normalizer.
        XCTAssertEqual(manager.model(for: .cleanUp(language: .polish)).id,
                       TransformModelManager.toneModelID)

        // The record-start warm-up resolves through the same function, so it
        // warms the backend the switches imply: a tone-enabled install the
        // instruction model, clean-up alone the normalizer.
        XCTAssertEqual(
            manager.model(for: TransformRuntime.warmUpPolicy(toneEnabled: true, toneMode: .neutral)).id,
            TransformModelManager.toneModelID,
            "a tone-enabled install warms the tone model"
        )
        XCTAssertEqual(
            manager.model(for: TransformRuntime.warmUpPolicy(toneEnabled: false, toneMode: .neutral)).id,
            TransformModelManager.normalizerModelID,
            "clean-up alone in English warms the normalizer"
        )

        TestFixtures.report("[transform] routing: English clean-up → "
                    + "\(TransformModelManager.normalizerModelID); every tone and the e-mail mode → "
                    + "\(TransformModelManager.toneModelID), installed or not")
    }

    /// Polish no longer reaches no backend: a Polish **tone** resolves to the
    /// instruction model — that is the point of the two-model catalogue. Polish
    /// clean-up alone still resolves nothing, because it is the deterministic
    /// scrub and there is no model call to make.
    func testPolishToneResolvesAndPolishCleanUpAloneDoesNot() throws {
        XCTAssertEqual(
            TransformPolicy.resolve(tone: true, cleanUp: false, language: "pl", toneMode: .formal),
            .tone(language: .polish, tone: .formal),
            "Polish tone now resolves: the instruction model reads Polish"
        )
        XCTAssertEqual(
            TransformPolicy.resolve(tone: true, cleanUp: true, language: "pl", toneMode: .casual),
            .cleanUpWithTone(language: .polish, tone: .casual)
        )
        XCTAssertNil(
            TransformPolicy.resolve(tone: false, cleanUp: true, language: "pl", toneMode: .formal),
            "Polish clean-up alone is the deterministic scrub, so it never resolves a policy"
        )
        TestFixtures.report("[transform] Polish tone resolves to the instruction model; the catalogue is "
                    + "\(TransformModelManager.availableModels.map(\.id).joined(separator: ", "))")
    }

    /// The service hands the **policy's** model to the runtime, so the route is
    /// what the transform actually runs on. The policy carries the job and the
    /// language, and those carry the model.
    func testTheResolvedModelIsTheOneTheRuntimeIsHanded() async {
        let normalizer = TransformModelManager.shared.normalizerModel
        let tone = TransformModelManager.shared.toneModel
        let resolver: (TransformPolicy) -> TransformModel = { TransformModelManager.shared.model(for: $0) }

        // Tone, English: the instruction model.
        let englishTone = LocalRecorder()
        let englishToneService = service(
            local: englishTone,
            settings: GateSettings(tone: true, cleanUp: false, toneMode: .neutral),
            model: resolver
        )
        _ = await englishToneService.transformIfEnabled("Please send the report.", sourceLanguage: "en")
        XCTAssertEqual(englishTone.models.map(\.id), [tone.id])

        // Clean-up alone, English: the normalizer.
        let englishCleanUp = LocalRecorder()
        let englishCleanUpService = service(
            local: englishCleanUp,
            settings: GateSettings(tone: false, cleanUp: true, toneMode: .neutral),
            model: resolver
        )
        _ = await englishCleanUpService.transformIfEnabled("Please send the report.", sourceLanguage: "en")
        XCTAssertEqual(englishCleanUp.models.map(\.id), [normalizer.id])

        // Polish tone: still the instruction model — the point of the change.
        let polishTone = LocalRecorder()
        let polishToneService = service(
            local: polishTone,
            settings: GateSettings(tone: true, cleanUp: false, toneMode: .formal),
            model: resolver
        )
        _ = await polishToneService.transformIfEnabled("Cześć, jak się masz?", sourceLanguage: "pl")
        XCTAssertEqual(polishTone.models.map(\.id), [tone.id],
                       "Polish tone runs on the instruction model")

        // Polish clean-up alone resolves no model, so the runtime is handed
        // nothing at all.
        let polishCleanUp = LocalRecorder()
        let polishCleanUpService = service(
            local: polishCleanUp,
            settings: GateSettings(tone: false, cleanUp: true, toneMode: .neutral),
            model: resolver
        )
        _ = await polishCleanUpService.transformIfEnabled("Cześć, jak się masz?", sourceLanguage: "pl")
        XCTAssertTrue(polishCleanUp.models.isEmpty,
                      "Polish clean-up alone is the scrub, not a model call")
    }
}
