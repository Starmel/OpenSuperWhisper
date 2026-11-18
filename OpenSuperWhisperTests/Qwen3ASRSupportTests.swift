import CryptoKit
import XCTest
@testable import OpenSuperWhisper

/// The Qwen3-ASR engine's non-transcribing surface: the catalogue the Model tab
/// offers, the engine the preference value resolves to, and the errors the
/// bridge and the model manager hand back.
///
/// Nothing here loads the 2.5 GB weights: the interesting failures all happen
/// before a model is read, which is exactly the state a fresh install is in.
final class Qwen3ASRSupportTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osw-qwen3asr-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        try super.tearDownWithError()
    }

    // MARK: - The catalogue

    /// The bytes the app will fetch are the ones the repository pinned: these
    /// digests are the whole contract between the two, so a typo here downloads
    /// a file the install step then refuses.
    func testCataloguePinsThePublishedFiles() {
        let files = Qwen3ASRModelManager.availableFiles
        XCTAssertEqual(files.map(\.fileName).sorted(),
                       ["Qwen3-ASR-1.7B-Q8_0.gguf", "mmproj-Qwen3-ASR-1.7B-Q8_0.gguf"])

        let model = files.first { $0.id == Qwen3ASRModelManager.modelFileID }
        XCTAssertEqual(model?.sha256, "58e22d0532d4eacaf034cfac17a6fed159f37c41390c710186783be439d1fc57")
        XCTAssertEqual(model?.sizeBytes, 2_165_034_944)
        XCTAssertEqual(model?.downloadURL.absoluteString,
                       "https://huggingface.co/ggml-org/Qwen3-ASR-1.7B-GGUF/resolve/main/Qwen3-ASR-1.7B-Q8_0.gguf")

        let projector = files.first { $0.id == Qwen3ASRModelManager.projectorFileID }
        XCTAssertEqual(projector?.sha256, "46c1d533af3f354ceb37ce855dbceff7da7fa7cf1e6a523df3b13440bd164c0d")
        XCTAssertEqual(projector?.sizeBytes, 355_709_344)
        XCTAssertEqual(projector?.downloadURL.absoluteString,
                       "https://huggingface.co/ggml-org/Qwen3-ASR-1.7B-GGUF/resolve/main/mmproj-Qwen3-ASR-1.7B-Q8_0.gguf")

        // Two files, two digests: the projector is not the model under another
        // name, and an install of one must never satisfy the other.
        XCTAssertEqual(Set(files.map(\.sha256)).count, 2)
        XCTAssertEqual(Set(files.map(\.fileName)).count, 2)
    }

    func testModelTabRowsFollowWhatIsOnDisk() throws {
        let manager = Qwen3ASRModelManager(directory: directory)
        XCTAssertEqual(SettingsQwen3ASRModels.rows(for: manager).filter(\.isDownloaded).count, 0)

        let model = manager.modelFile
        try writeEmptyFile(named: model.fileName, size: model.sizeBytes)
        let rows = SettingsQwen3ASRModels.rows(for: manager)
        XCTAssertEqual(rows.first { $0.id == model.id }?.isDownloaded, true)
        XCTAssertEqual(rows.first { $0.id == manager.projectorFile.id }?.isDownloaded, false)
        XCTAssertEqual(rows.first { $0.id == model.id }?.sha256, model.sha256)
    }

    // MARK: - What the manager insists on before the engine starts

    func testMissingWeightsNameBothFilesAndTheRemedy() throws {
        let manager = Qwen3ASRModelManager(directory: directory)
        XCTAssertNil(manager.installedPaths)

        XCTAssertThrowsError(try manager.requireInstalledPaths()) { error in
            guard case Qwen3ASRError.notInstalled(let missing) = error else {
                return XCTFail("expected notInstalled, got \(error)")
            }
            XCTAssertEqual(missing.count, 2)
            let message = try? XCTUnwrap((error as? LocalizedError)?.errorDescription)
            XCTAssertTrue(message?.contains("Settings") == true, "the error must say where to download: \(message ?? "nil")")
            XCTAssertTrue(message?.contains("Qwen3-ASR 1.7B (Q8_0)") == true)
        }
    }

    /// A file that is present but is not the published one (a half download, a
    /// different quantisation, a copy under the right name) is told apart from a
    /// file that is simply not there, and the size is what says so.
    func testWrongSizedFileIsReportedAsNotThePublishedOne() throws {
        let manager = Qwen3ASRModelManager(directory: directory)
        let model = manager.modelFile
        try writeEmptyFile(named: model.fileName, size: model.sizeBytes - 1)
        try writeEmptyFile(named: manager.projectorFile.fileName, size: manager.projectorFile.sizeBytes)

        XCTAssertThrowsError(try manager.requireInstalledPaths()) { error in
            guard case Qwen3ASRError.fileNotVerified(let name, let expected, let actual) = error else {
                return XCTFail("expected fileNotVerified, got \(error)")
            }
            XCTAssertEqual(name, model.fileName)
            XCTAssertEqual(expected, model.sizeBytes)
            XCTAssertEqual(actual, model.sizeBytes - 1)
        }
    }

    /// The digest is checked where it can be checked: at install. A file whose
    /// bytes are not the published ones never becomes the installed file.
    func testInstallRefusesAnUnpinnedFile() throws {
        let manager = Qwen3ASRModelManager(directory: directory)
        let model = manager.modelFile

        let source = directory.appendingPathComponent("download-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0x7f, count: 64).write(to: source)

        XCTAssertThrowsError(try manager.install(fileAt: source, file: model)) { error in
            guard case Qwen3ASRError.checksumMismatch(let expected, let actual) = error else {
                return XCTFail("expected checksumMismatch, got \(error)")
            }
            XCTAssertEqual(expected, model.sha256)
            XCTAssertNotEqual(actual, model.sha256)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: manager.fileURL(for: model).path))
        XCTAssertFalse(manager.hasInstalledFile(model))
    }

    func testInstallAcceptsThePinnedFileAndRemovalTakesItBack() throws {
        let payload = Data((0..<4096).map { UInt8($0 % 251) })
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let file = Qwen3ASRModelFile(
            id: "test-file",
            displayName: "Test File",
            fileName: "test-file.gguf",
            downloadURL: URL(string: "https://example.invalid/test-file.gguf")!,
            sha256: digest,
            sizeBytes: Int64(payload.count)
        )
        let manager = Qwen3ASRModelManager(directory: directory, catalogue: [file])

        let source = directory.appendingPathComponent("source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try payload.write(to: source)

        try manager.install(fileAt: source, file: file)
        XCTAssertTrue(manager.hasInstalledFile(file))
        XCTAssertEqual(try Qwen3ASRModelManager.sha256(ofFileAt: manager.fileURL(for: file)), digest)

        try manager.remove(file)
        XCTAssertFalse(manager.hasInstalledFile(file))
        XCTAssertThrowsError(try manager.requireInstalledPaths())
    }

    /// A partial download from a killed app is not resumable and must not be
    /// mistaken for the installed file.
    func testStalePartialDownloadIsDropped() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let partial = directory.appendingPathComponent("Qwen3-ASR-1.7B-Q8_0.gguf.part")
        try Data(repeating: 1, count: 32).write(to: partial)

        let manager = Qwen3ASRModelManager(directory: directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertFalse(manager.hasInstalledFile(manager.modelFile))
    }

    // MARK: - The preference value

    @MainActor
    func testEngineSelectionMapsEveryPreferenceValue() {
        func engine(_ value: String) -> TranscriptionEngine {
            TranscriptionService.engine(
                for: .init(engine: value, modelPath: "/tmp/unused.bin", modelVersion: "v3")
            )
        }

        XCTAssertTrue(engine("qwen3asr") is Qwen3ASREngine)
        XCTAssertEqual(engine("qwen3asr").engineName, "Qwen3-ASR")
        XCTAssertTrue(engine("fluidaudio") is FluidAudioEngine)
        XCTAssertTrue(engine("whisper") is WhisperEngine)
        // An unknown value runs whisper, which is the preference's own default.
        XCTAssertTrue(engine("") is WhisperEngine)
    }

    /// The Qwen3-ASR selection is the pair of weights on disk, so a download or
    /// a removal changes it — that is what makes `reloadEngine()` act instead of
    /// being a no-op, and what stops a loaded engine from transcribing after its
    /// files were deleted. It is *not* the whisper model: with the two GGUF
    /// files absent — or present — this engine never resolves that path.
    @MainActor
    func testSelectionFollowsTheQwen3WeightsNotTheWhisperModel() {
        let preferences = AppPreferences.shared
        let engine = preferences.selectedEngine
        let whisperPath = preferences.selectedWhisperModelPath
        defer {
            preferences.selectedEngine = engine
            preferences.selectedWhisperModelPath = whisperPath
        }

        preferences.selectedEngine = Qwen3ASREngine.engineID
        preferences.selectedWhisperModelPath = "/tmp/osw-not-the-qwen3-weights.bin"

        let current = TranscriptionService.EngineSelection.current
        XCTAssertEqual(current.engine, Qwen3ASREngine.engineID)
        XCTAssertEqual(current.modelPath, Qwen3ASRModelManager.shared.installedPaths?.model)
        XCTAssertNotEqual(current.modelPath, "/tmp/osw-not-the-qwen3-weights.bin")
    }

    // MARK: - The bridge's own error surface

    /// The bridge refuses a file it cannot read, and says which one — the app
    /// shows this sentence, so it has to name the file rather than report a
    /// faceless load failure.
    func testNativeLoadNamesTheMissingFile() {
        XCTAssertThrowsError(
            try Qwen3ASRNative(textModelPath: "/nonexistent/qwen.gguf",
                               projectorPath: "/nonexistent/mmproj.gguf",
                               threadCount: 2)
        ) { error in
            guard case Qwen3ASRNative.NativeError.load(let message) = error else {
                return XCTFail("expected a load failure, got \(error)")
            }
            XCTAssertTrue(message.contains("/nonexistent/qwen.gguf"), message)
        }

        XCTAssertThrowsError(
            try Qwen3ASRNative(textModelPath: "/etc/hosts",
                               projectorPath: "/nonexistent/mmproj.gguf",
                               threadCount: 2)
        ) { error in
            guard case Qwen3ASRNative.NativeError.load(let message) = error else {
                return XCTFail("expected a load failure, got \(error)")
            }
            XCTAssertTrue(message.contains("/nonexistent/mmproj.gguf"), message)
        }
    }

    /// Loading is the engine's job through the manager, and it fetches what is
    /// missing itself: with the download failing (here a URL that is not there),
    /// the load fails with the download's own reason — and it never falls back
    /// to whisper.
    func testEngineInitializationFailsWhenTheWeightsCannotBeFetched() async throws {
        let catalogue = Qwen3ASRModelManager.availableFiles.map { file in
            Qwen3ASRModelFile(id: file.id,
                              displayName: file.displayName,
                              fileName: file.fileName,
                              downloadURL: directory.appendingPathComponent("absent-\(file.fileName)"),
                              sha256: file.sha256,
                              sizeBytes: file.sizeBytes)
        }
        let manager = Qwen3ASRModelManager(directory: directory, catalogue: catalogue)
        let engine = Qwen3ASREngine(modelManager: manager, threadCount: 2)

        do {
            try await engine.initialize()
            XCTFail("the engine loaded without its weights")
        } catch let error as Qwen3ASRError {
            guard case .downloadFailed = error else {
                return XCTFail("expected downloadFailed, got \(error)")
            }
        }
        XCTAssertFalse(engine.isModelLoaded)
        XCTAssertEqual(manager.missingFiles.count, 2)
    }

    func testEngineReportsTheLanguagesItDetectsForItself() {
        let engine = Qwen3ASREngine(modelManager: Qwen3ASRModelManager(directory: directory), threadCount: 2)
        XCTAssertEqual(engine.getSupportedLanguages(), ["auto"])
        XCTAssertEqual(engine.engineName, "Qwen3-ASR")
    }

    /// Selecting the engine with nothing on disk downloads the weights itself —
    /// through the app's own path, digest-checked before either file becomes the
    /// engine's. The URLs here are `file://` so the test needs no network; what
    /// it proves is the fetch-and-install step, which then fails on the model
    /// itself (these bytes are not a GGUF), not on anything missing.
    func testEngineFetchingMissingWeightsInstallsThemBeforeLoading() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sources = try ["model", "projector"].map { name -> (URL, Data, String) in
            let payload = Data("\(name)-payload".utf8)
            let url = directory.appendingPathComponent("\(name)-source.bin")
            try payload.write(to: url)
            let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
            return (url, payload, digest)
        }
        let catalogue = [
            Qwen3ASRModelFile(id: Qwen3ASRModelManager.modelFileID,
                              displayName: "Model",
                              fileName: "model.gguf",
                              downloadURL: sources[0].0,
                              sha256: sources[0].2,
                              sizeBytes: Int64(sources[0].1.count)),
            Qwen3ASRModelFile(id: Qwen3ASRModelManager.projectorFileID,
                              displayName: "Projector",
                              fileName: "mmproj.gguf",
                              downloadURL: sources[1].0,
                              sha256: sources[1].2,
                              sizeBytes: Int64(sources[1].1.count))
        ]
        let manager = Qwen3ASRModelManager(directory: directory, catalogue: catalogue)
        XCTAssertEqual(manager.missingFiles.count, 2)

        let engine = Qwen3ASREngine(modelManager: manager, threadCount: 2)
        do {
            try await engine.initialize()
            XCTFail("a non-GGUF payload must not load as a model")
        } catch let error as Qwen3ASRNative.NativeError {
            // The bridge refused the bytes, which means both files were on disk
            // by the time it was asked to load them.
            guard case .load = error else {
                return XCTFail("expected a load failure, got \(error)")
            }
        }

        XCTAssertTrue(manager.hasInstalledFile(catalogue[0]))
        XCTAssertTrue(manager.hasInstalledFile(catalogue[1]))
        XCTAssertEqual(try Qwen3ASRModelManager.sha256(ofFileAt: manager.fileURL(for: catalogue[0])),
                       sources[0].2)
        XCTAssertEqual(manager.installedPaths?.model, manager.fileURL(for: catalogue[0]).path)
        XCTAssertFalse(engine.isModelLoaded)
    }

    // MARK: - Helpers

    private func writeEmptyFile(named name: String, size: Int64) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(size))
    }
}
