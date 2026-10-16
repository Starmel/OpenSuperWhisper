import CryptoKit
import XCTest
@testable import OpenSuperWhisper

private final class TestPhononDownloader: PhononDownloading, @unchecked Sendable {
    enum Behavior {
        case data(Data)
        case waitForCancellation
    }

    let behavior: Behavior
    init(_ behavior: Behavior) { self.behavior = behavior }

    func download(
        from source: URL,
        to destination: URL,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        switch behavior {
        case .data(let data):
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination)
            progress(Int64(data.count), Int64(data.count))
        case .waitForCancellation:
            while true {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 5_000_000)
            }
        }
    }
}

private final class TestPhononClient: PhononTranscribing {
    var onPreparationProgress: ((String, Double) -> Void)?
    private(set) var isPrepared = false
    private(set) var prepareCalls = 0
    private(set) var sampleCalls = 0
    private(set) var fileCalls = 0
    private(set) var cancelled = false

    func prepare(modelDirectory: URL) async throws -> PhononPreparationResult {
        prepareCalls += 1
        isPrepared = true
        onPreparationProgress?("loaded enc_5s", 0.25)
        return .init(loadSeconds: 0.25, compileSeconds: 0, loadedFunctions: [15], peakResidentMemoryBytes: 1)
    }

    func transcribe(samples: [Float]) async throws -> PhononTranscriptionResult {
        sampleCalls += 1
        return Self.result("direct pcm")
    }

    func transcribe(fileURL: URL) async throws -> PhononTranscriptionResult {
        fileCalls += 1
        return Self.result("queued url")
    }

    func cancel() {
        cancelled = true
        isPrepared = false
    }

    func simulateInvalidation() {
        isPrepared = false
    }

    private static func result(_ text: String) -> PhononTranscriptionResult {
        .init(
            text: text,
            words: [.init(text: text, start: 0, end: 0.5)],
            audioSeconds: 0.5,
            decodeSeconds: 0.01,
            windows: 1,
            peakResidentMemoryBytes: 1
        )
    }
}

private final class FailingPhononEngine: TranscriptionEngine {
    var isModelLoaded: Bool { false }
    var engineName: String { "broken" }
    func initialize() async throws { throw PhononModelError.missingFile("decoder.bin") }
    func transcribeAudio(url: URL, settings: Settings) async throws -> String { "unexpected" }
    func cancelTranscription() {}
    func getSupportedLanguages() -> [String] { ["en"] }
}

private final class CancelledPhononEngine: TranscriptionEngine {
    var isModelLoaded: Bool { false }
    var engineName: String { "cancelled" }
    func initialize() async throws { throw CancellationError() }
    func transcribeAudio(url: URL, settings: Settings) async throws -> String { "unexpected" }
    func cancelTranscription() {}
    func getSupportedLanguages() -> [String] { ["en"] }
}

private final class FallbackProbeEngine: PCMTranscriptionEngine, ProgressReportingTranscriptionEngine {
    var isModelLoaded = true
    var engineName: String { "fallback probe" }
    var onProgressUpdate: ((Float) -> Void)?
    private(set) var initializeCalls = 0
    func initialize() async throws { initializeCalls += 1 }
    func transcribeAudio(url: URL, settings: Settings) async throws -> String { "url" }
    func transcribeSamples(_ samples: [Float], settings: Settings) async throws -> String { "pcm" }
    func cancelTranscription() {}
    func getSupportedLanguages() -> [String] { ["en"] }
}

@MainActor
final class PhononIntegrationTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories { try? FileManager.default.removeItem(at: directory) }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testPinnedReleaseMetadataAndPlatformGate() {
        let release = PhononModelRelease.pinned
        XCTAssertEqual(release.runtimeVersion, "1.1.2")
        XCTAssertEqual(release.repositoryRevision, "1143812fd4236522232a8c33e3115f0577e3cd7d")
        XCTAssertEqual(release.manifestVersion, "3.0")
        XCTAssertEqual(release.compiledCacheKey, "4b6bfa3a12cc3c4e-0f6c074cb6fd1c3b")
        XCTAssertEqual(release.downloadSize, 345_012_107)
        XCTAssertTrue(PhononPlatform.isSupported)
        XCTAssertEqual(LanguageUtil.supportedLanguages(engine: "phonon", fluidAudioModelVersion: "v3"), ["en"])
    }

    func testInstalledMarkerIsVersionGated() throws {
        let fixture = try makeFixture()
        let wrongRelease = PhononModelRelease(
            runtimeVersion: fixture.release.runtimeVersion,
            repositoryRevision: "different-revision",
            manifestVersion: fixture.release.manifestVersion,
            compiledCacheKey: fixture.release.compiledCacheKey,
            files: fixture.release.files
        )
        try install(release: wrongRelease, into: fixture.manager.modelDirectory, payload: fixture.payload)
        XCTAssertFalse(fixture.manager.isModelInstalled)
    }

    func testChecksumFailureNeverActivatesModel() async throws {
        let good = Data("good".utf8)
        let bad = Data("baad".utf8)
        let fixture = try makeFixture(payload: good, downloader: TestPhononDownloader(.data(bad)))
        do {
            try await fixture.manager.downloadModel { _ in }
            XCTFail("A bad checksum activated the model")
        } catch let error as PhononModelError {
            guard case .checksumMismatch = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertFalse(fixture.manager.isModelInstalled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.manager.modelDirectory.path))
    }

    func testDownloadCancellationCleansStagingAndDoesNotActivate() async throws {
        let fixture = try makeFixture(downloader: TestPhononDownloader(.waitForCancellation))
        let task = Task { try await fixture.manager.downloadModel { _ in } }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do {
            try await task.value
            XCTFail("Cancelled download completed")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as NSError).code == NSURLErrorCancelled)
        }
        let entries = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        XCTAssertFalse(entries.contains { $0.hasSuffix(".download") })
        XCTAssertFalse(fixture.manager.isModelInstalled)
    }

    func testPhononUsesPCMForLiveAndURLForQueuedAudio() async throws {
        let fixture = try makeFixture()
        try install(release: fixture.release, into: fixture.manager.modelDirectory, payload: fixture.payload)
        let client = TestPhononClient()
        let engine = PhononEngine(modelManager: fixture.manager, client: client)
        try await engine.initialize()

        let oldTimestamps = AppPreferences.shared.showTimestamps
        AppPreferences.shared.showTimestamps = false
        defer { AppPreferences.shared.showTimestamps = oldTimestamps }
        let settings = Settings()

        let pcmText = try await engine.transcribeSamples([0.1, -0.1], settings: settings)
        let queuedText = try await engine.transcribeAudio(url: URL(fileURLWithPath: "/durable/queued.wav"), settings: settings)
        XCTAssertEqual(pcmText, "direct pcm")
        XCTAssertEqual(queuedText, "queued url")
        XCTAssertEqual(client.sampleCalls, 1)
        XCTAssertEqual(client.fileCalls, 1)
        XCTAssertEqual(engine.lastResult?.words.first?.end, 0.5)

        client.simulateInvalidation()
        XCTAssertFalse(engine.isModelLoaded)
        let recoveredText = try await engine.transcribeSamples([0.15], settings: settings)
        XCTAssertEqual(recoveredText, "direct pcm")
        XCTAssertEqual(client.prepareCalls, 2)

        engine.cancelTranscription()
        XCTAssertTrue(client.cancelled)

        let retriedText = try await engine.transcribeSamples([0.2], settings: settings)
        XCTAssertEqual(retriedText, "direct pcm")
        XCTAssertEqual(client.prepareCalls, 3)
        XCTAssertEqual(client.sampleCalls, 3)
    }

    func testStorageAccountingAndDeleteIncludeCompiledCache() throws {
        let fixture = try makeFixture()
        try install(release: fixture.release, into: fixture.manager.modelDirectory, payload: fixture.payload)

        let package = fixture.manager.modelDirectory
            .appendingPathComponent("Phonon-2.mlpackage/Data/com.apple.CoreML", isDirectory: true)
        let weights = package.appendingPathComponent("weights", isDirectory: true)
        try FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
        try Data("program".utf8).write(to: package.appendingPathComponent("model.mlmodel"))
        try Data("weights".utf8).write(to: weights.appendingPathComponent("weight.bin"))

        let cache = fixture.manager.compiledCacheDirectoryURL
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cache) }
        try Data(repeating: 7, count: 32).write(to: cache.appendingPathComponent("compiled.bin"))
        try FileManager.default.removeItem(at: fixture.manager.modelDirectory.appendingPathComponent("manifest.json"))

        XCTAssertEqual(fixture.manager.compiledCacheDirectoryURL, cache)
        XCTAssertGreaterThanOrEqual(fixture.manager.storageBytes(), 32)
        try fixture.manager.deleteModel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.manager.modelDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.path))
    }

    func testPersistedPhononSelectionRestoresAfterRelaunch() {
        let defaults = UserDefaults.standard
        let oldEngine = defaults.object(forKey: "selectedEngine")
        defer {
            if let oldEngine { defaults.set(oldEngine, forKey: "selectedEngine") }
            else { defaults.removeObject(forKey: "selectedEngine") }
        }
        AppPreferences.shared.selectedEngine = "phonon"
        XCTAssertEqual(TranscriptionService.EngineSelection.current.engine, "phonon")
    }

    func testAbsentPhononFallsBackToExistingWhisperWithoutChangingSelection() async throws {
        let oldEngine = AppPreferences.shared.selectedEngine
        defer { AppPreferences.shared.selectedEngine = oldEngine }
        AppPreferences.shared.selectedEngine = "phonon"

        let factories = TranscriptionService.EngineFactories(
            makeWhisper: { _ in FallbackProbeEngine() },
            makeFluidAudio: { _ in NamedTestEngine("fluid") },
            makePhonon: { FailingPhononEngine() }
        )
        let selection = TranscriptionService.EngineSelection(engine: "phonon", modelPath: "/fallback.bin", modelVersion: "v3")
        let service = TranscriptionService(selection: selection) {
            try await TranscriptionService.makeEngine($0, factories: factories)
        }
        try await service.waitUntilReady()
        XCTAssertEqual(AppPreferences.shared.selectedEngine, "phonon")
        XCTAssertEqual(service.activeEngineName, "Whisper (Phonon fallback)")
        XCTAssertNotNil(service.loadingWarning)
        let output = try await service.transcribeAudio(
            url: URL(fileURLWithPath: "/unused.wav"),
            settings: Settings(),
            pcmSamples: [0.1]
        )
        XCTAssertEqual(output, "pcm")
    }

    func testCancelledPhononLoadDoesNotInitializeWhisperFallback() async {
        let fallback = FallbackProbeEngine()
        let factories = TranscriptionService.EngineFactories(
            makeWhisper: { _ in fallback },
            makeFluidAudio: { _ in NamedTestEngine("fluid") },
            makePhonon: { CancelledPhononEngine() }
        )

        do {
            _ = try await TranscriptionService.makeEngine(
                .init(engine: "phonon", modelPath: "/fallback.bin", modelVersion: "v3"),
                factories: factories
            )
            XCTFail("Cancelled Phonon load initialized a fallback")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(fallback.initializeCalls, 0)
    }

    func testUnknownEngineDoesNotMasqueradeAsWhisper() async {
        do {
            _ = try await TranscriptionService.makeEngine(
                .init(engine: "typo", modelPath: "/unused", modelVersion: "v3")
            )
            XCTFail("Unknown engine loaded")
        } catch let error as TranscriptionError {
            guard case .unsupportedEngine("typo") = error else { return XCTFail("Unexpected error: \(error)") }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeFixture(
        payload: Data = Data("{\"version\":\"3.0\"}".utf8),
        downloader: PhononDownloading? = nil
    ) throws -> (root: URL, release: PhononModelRelease, manager: PhononModelManager, payload: Data) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("phonon-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryDirectories.append(root)
        let digest = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let release = PhononModelRelease(
            runtimeVersion: "1.1.2",
            repositoryRevision: "test-revision",
            manifestVersion: "3.0",
            compiledCacheKey: "test-cache-key-\(UUID().uuidString)",
            files: [.init(path: "manifest.json", byteCount: Int64(payload.count), sha256: digest)]
        )
        let manager = PhononModelManager(
            release: release,
            modelsDirectory: root,
            downloader: downloader ?? TestPhononDownloader(.data(payload))
        )
        return (root, release, manager, payload)
    }

    private func install(release: PhononModelRelease, into directory: URL, payload: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try payload.write(to: directory.appendingPathComponent("manifest.json"))
        try JSONEncoder().encode(release).write(to: directory.appendingPathComponent("installed.json"))
    }
}
