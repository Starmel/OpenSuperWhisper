import XCTest

@testable import OpenSuperWhisper

/// A fresh install, and a model the user downloaded, on the paths that decide
/// whether the app can transcribe at all.
///
/// `fm-20260925-19`: after an uninstall and a reinstall the app came up with
/// nothing to run, and what a user sees then is `ContentView`'s "Model could not
/// be loaded". The app carries a model of its own — `ggml-tiny.en.bin` inside the
/// bundle — and downloads the rest from the catalogue, so this file pins both
/// ends of that: nothing placed by anyone still resolves **and loads**, and a
/// model the user downloaded is still the model in use after a restart.
///
/// Everything runs in a scratch models directory — `WhisperModelManager.modelsDirectory`
/// is the seam — so no test reads or writes the models of the app on this
/// machine, and none depends on any other application's storage.
@MainActor
final class FreshInstallModelTests: XCTestCase {

    private var fixtureDirectory: URL!
    private var savedModelsDirectory: URL!
    private var savedSelection: String?

    override func setUp() {
        super.setUp()
        savedModelsDirectory = WhisperModelManager.modelsDirectory
        savedSelection = AppPreferences.shared.selectedWhisperModelPath

        fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osw-fresh-install-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        WhisperModelManager.modelsDirectory = fixtureDirectory
        AppPreferences.shared.selectedWhisperModelPath = nil
    }

    override func tearDown() {
        WhisperModelManager.modelsDirectory = savedModelsDirectory
        AppPreferences.shared.selectedWhisperModelPath = savedSelection
        try? FileManager.default.removeItem(at: fixtureDirectory)
        super.tearDown()
    }

    // MARK: - Helpers

    /// The model the app carries inside its own bundle — the one the first run
    /// copies into the app's directory. A missing copy is a packaging defect, so
    /// this fails rather than skips.
    private func bundledModel() throws -> URL {
        try XCTUnwrap(
            Bundle.main.url(forResource: "ggml-tiny.en", withExtension: "bin"),
            "the app bundle has to carry ggml-tiny.en.bin (WhisperModelManager.defaultModelName)"
        )
    }

    /// A real, loadable model in the app's own directory, standing in for one the
    /// user downloaded, under a name of its own so it can never be confused with
    /// the bundled copy. (The bytes are the bundled model's; which weights they
    /// are is not what this test is about — the selection surviving a launch is.)
    ///
    /// Copied, not hard-linked: the scratch directory is `TMPDIR` and the built
    /// bundle can be on another volume, where a link fails with EXDEV.
    private func modelAsIfDownloaded() throws -> URL {
        let destination = fixtureDirectory.appendingPathComponent("ggml-base.en.bin")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: try bundledModel(), to: destination)
        return destination
    }

    /// Loads what `path` names exactly as the production loader does, and says
    /// whether the model came up.
    ///
    /// This is the assertion behind "Model could not be loaded":
    /// `WhisperEngine.initialize()` loads the model and the VAD, and a failure
    /// there is what `TranscriptionService.finishEngineLoad` puts into
    /// `loadingError`, which `ContentView` shows as that alert.
    @discardableResult
    private func modelLoads(at path: String) async throws -> Bool {
        let engine = WhisperEngine(modelPath: path)
        defer { engine.unload() }
        try await engine.initialize()
        return engine.isModelLoaded
    }

    // MARK: - A fresh install

    /// Nothing placed by anyone, nothing downloaded: the app still resolves a
    /// model, points itself at it, and the production load path comes up.
    func testAFreshInstallResolvesAModelAndLoadsIt() async throws {
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixtureDirectory.path), [],
                       "precondition: a fresh install, nothing of the user's own")

        // What the app does on launch (`OpenSuperWhisperApp.init`).
        WhisperModelManager.shared.ensureDefaultModelPresent()

        let selected = try XCTUnwrap(AppPreferences.shared.selectedWhisperModelPath,
                                     "a fresh install has to be pointed at the model the app carries")
        XCTAssertEqual(URL(fileURLWithPath: selected).lastPathComponent, WhisperModelManager.defaultModelName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: selected),
                      "the model the app selects has to be a file it can load")

        // What the transcription path asks for, and what the engine is handed.
        let resolved = try XCTUnwrap(TranscriptionService.resolvedWhisperModelPath())
        XCTAssertEqual(resolved, selected)
        XCTAssertEqual(TranscriptionService.EngineSelection.current.modelPath, selected)

        // The production load path end to end: the service loads the engine from
        // its own resolution, and reports no failure.
        let service = TranscriptionService(selection: .current)
        try await service.waitUntilReady()
        XCTAssertNil(service.loadingError, "a fresh install must never report 'Model could not be loaded'")
        await service.shutdown()

        let loaded = try await modelLoads(at: resolved)
        XCTAssertTrue(loaded, "and the model itself comes up")
    }

    /// The same resolution with no preference at all — the state the process is
    /// in before the launch hook runs — still hands the engine the bundled model,
    /// from the bundle itself when the copy into the app's directory has not
    /// happened yet.
    func testTheBundledModelIsResolvableWithoutAnyPreference() throws {
        XCTAssertNil(AppPreferences.shared.selectedWhisperModelPath, "precondition: nothing is selected")

        let resolved = try XCTUnwrap(TranscriptionService.resolvedWhisperModelPath())
        // The scratch directory is empty, so the copy cannot be there: this is
        // the bundle's own file, which the engine can load directly.
        XCTAssertEqual(try XCTUnwrap(resolved), try bundledModel().path)
        XCTAssertEqual(TranscriptionService.EngineSelection.current.modelPath, resolved)

        // Resolution is a read: it does not write a preference behind the
        // launch hook's back.
        XCTAssertNil(AppPreferences.shared.selectedWhisperModelPath)
    }

    // MARK: - A model the user downloaded

    /// It is the model in use, it stays that way across a restart, and nothing
    /// at launch moves the user off it.
    func testADownloadedModelStaysSelectedAcrossARestartAndStillLoads() async throws {
        let downloaded = try modelAsIfDownloaded()
        AppPreferences.shared.selectedWhisperModelPath = downloaded.path
        let noticeBefore = WhisperModelManager.shared.lastNotice

        // Two launches' worth of the startup hook.
        WhisperModelManager.shared.ensureDefaultModelPresent()
        WhisperModelManager.shared.ensureDefaultModelPresent()

        XCTAssertEqual(AppPreferences.shared.selectedWhisperModelPath, downloaded.path,
                       "the app must not move a user off the model they chose")
        XCTAssertEqual(WhisperModelManager.shared.lastNotice, noticeBefore,
                       "a working selection is nothing to announce")
        XCTAssertEqual(TranscriptionService.resolvedWhisperModelPath(), downloaded.path)
        let stillLoads = try await modelLoads(at: downloaded.path)
        XCTAssertTrue(stillLoads, "the model has to stay loadable across restarts")
    }

    /// A selection whose file is gone is reported and replaced by the bundled
    /// model — and the app keeps transcribing on the same launch.
    func testAMissingSelectionFallsBackToTheBundledModelAndKeepsWorking() async throws {
        WhisperModelManager.shared.ensureDefaultModelPresent()
        let bundled = try XCTUnwrap(AppPreferences.shared.selectedWhisperModelPath)
        let gone = fixtureDirectory.appendingPathComponent("was-here-yesterday.bin")
        AppPreferences.shared.selectedWhisperModelPath = gone.path

        WhisperModelManager.shared.ensureDefaultModelPresent()

        XCTAssertEqual(WhisperModelManager.shared.lastNotice,
                       .selectionWasMissing(was: "was-here-yesterday.bin",
                                            now: WhisperModelManager.defaultModelName),
                       "the Model tab has to say the model changed under the user")
        XCTAssertEqual(AppPreferences.shared.selectedWhisperModelPath, bundled)
        XCTAssertEqual(TranscriptionService.resolvedWhisperModelPath(), bundled)
        let fallbackLoads = try await modelLoads(at: bundled)
        XCTAssertTrue(fallbackLoads, "the fallback has to leave the app able to transcribe")
    }

    // MARK: - What a fresh install can and cannot hear

    /// On a fresh install the model the app carries is `ggml-tiny.en.bin`, which
    /// is English-only. A Polish dictation through it measures nothing, and the
    /// app already refuses to keep such a transcript and names the fix: a
    /// multilingual model to download. A fresh install must not look as if it
    /// could hear Polish.
    func testAFreshInstallRefusesPolishThroughTheBundledEnglishOnlyModel() throws {
        WhisperModelManager.shared.ensureDefaultModelPresent()
        let selected = try XCTUnwrap(AppPreferences.shared.selectedWhisperModelPath)
        XCTAssertTrue(
            SpeechModelLanguageGate.isEnglishOnlyFileName(URL(fileURLWithPath: selected).lastPathComponent),
            "the model a fresh install runs on is the English-only one: \(selected)"
        )

        let conflict = try XCTUnwrap(
            SpeechModelLanguageGate.conflict(
                modelPath: selected,
                isMultilingual: nil,
                transcript: "Cześć, jak się masz?",
                modelsDirectory: fixtureDirectory
            ),
            "a Polish dictation through the bundled model has to be refused"
        )

        XCTAssertNil(conflict.remedyModelName, "nothing multilingual is installed yet")
        XCTAssertTrue(
            conflict.message.contains("Download a multilingual model in Settings"),
            "the refusal has to name the fix: \(conflict.message)"
        )
        XCTAssertTrue(conflict.message.contains("Dictation is blocked until this is fixed."))
    }
}
