import Foundation
import GRDB
import XCTest
@testable import OpenSuperWhisper

/// An engine that fails the way a real one does when its decode goes wrong: no
/// text, just the error.
private final class FailingTranscriptionEngine: TranscriptionEngine {
    var isModelLoaded: Bool { true }
    var engineName: String { "Failing test engine" }

    private let failure: Error

    init(failure: Error) {
        self.failure = failure
    }

    func initialize() async throws {}

    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        throw failure
    }

    func cancelTranscription() {}

    func getSupportedLanguages() -> [String] { ["en"] }
}

/// Records what reached the keyboard, so "a kept recording is a record, not a
/// delivery" can be checked.
@MainActor
private final class PasteTrackingIndicator: IndicatorViewModel {
    var inserted: [String] = []
    override func insertText(_ text: String) { inserted.append(text) }
}

/// The user-visible boundary of a dictation that yields no transcript, pinned on
/// the one decision `DictationFailurePolicy` takes for every surface — the
/// indicator, the main window's record button, the queue, and the recorder.
///
/// A refusal leaves nothing new behind when the audio held nothing: no alert,
/// no row, nothing pasted. It keeps the audio — with a row that records it, so
/// it is visible in History and ages with everything else — when the audio is
/// real and only the model or the threshold could not hear it: the VAD's verdict
/// and an empty capture take nothing with them, a measured refusal and a
/// language conflict keep the recording. Nothing is ever pasted for any of them,
/// and a genuine failure over recorded audio is still reported and still keeps
/// its audio.
@MainActor
final class SilentEmptyDictationTests: XCTestCase {

    /// What whisper hears when it is handed something it cannot place.
    private static let polishDictation = "Cześć, jak się masz?"
    private static let englishOnlyModelPath = "/models/ggml-tiny.en.bin"

    override func setUp() {
        // The dictation pipeline reads one shared recording session, so a
        // session left behind by another test would redirect `startDecoding()`
        // into someone else's stop closure.
        RecordingSessionController.shared.finish(RecordingSessionController.shared.currentID)
        AppErrorCenter.shared.issue = nil
        super.setUp()
    }

    override func tearDown() {
        AppErrorCenter.shared.issue = nil
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeStore() throws -> RecordingStore {
        try RecordingStore(databaseQueue: DatabaseQueue())
    }

    private func makeTempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("osw-silent-\(UUID().uuidString).wav")
    }

    /// The refusal the service throws for a measurement, built through the gate
    /// that produces it so the payload is the real one.
    private func noSpeechRefusal(presence: SpeechPresence) throws -> Error {
        let conflict = try XCTUnwrap(
            SpeechModelLanguageGate.noSpeechConflict(presence: presence, noSpeechThreshold: 0.6)
        )
        return TranscriptionError.noSpeechDetected(conflict)
    }

    /// An English-only model hearing Polish: the language conflict, with the
    /// model the service reports named by its selection. The engine is a stub,
    /// and the selection is loaded before the dictation starts so the view model
    /// does not see a busy service.
    private func englishOnlyService() async throws -> TranscriptionService {
        let service = TranscriptionService(
            selection: TranscriptionService.EngineSelection(
                engine: "whisper",
                modelPath: Self.englishOnlyModelPath,
                modelVersion: ""
            ),
            engineLoader: { _ in
                StubLanguageWhisperEngine(
                    text: Self.polishDictation,
                    language: "pl",
                    multilingual: false
                )
            }
        )
        try await service.waitUntilReady()
        return service
    }

    private func makeViewModel(
        service: TranscriptionService,
        store: RecordingStore,
        audio: @escaping () -> RecordedAudio?
    ) -> IndicatorViewModel {
        // These tests are about what leaves the pipeline, not about the tone
        // switch: an identity transform keeps them off the user's preferences
        // and off whether any transform weights are installed.
        let viewModel = IndicatorViewModel(
            transcriptionService: service,
            recordingStore: store,
            stopRecording: audio,
            cancelAudioRecording: {},
            transformText: { text, _, _ in
                TransformService.TransformOutcome(text: text, policy: nil, didRunModel: false)
            }
        )
        viewModel.state = .recording
        return viewModel
    }

    /// A dictation is done once its temp audio is gone — deleted, or moved where
    /// kept audio goes. The settle lets a run that is *not* done reach its own
    /// end before the outcome is read.
    private func waitForTempAudioToGo(_ url: URL) async throws {
        for _ in 0..<200 {
            if !FileManager.default.fileExists(atPath: url.path) { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    /// The preservation of a genuine failure ends with its report, so that is
    /// the signal that the pipeline is done with the dictation.
    private func waitForReport() async throws {
        for _ in 0..<200 {
            if AppErrorCenter.shared.issue != nil { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// A pending row for a dictation of ours, as the recorder and the indicator
    /// leave it.
    private func pendingRecording(sourceURL: URL) -> Recording {
        let id = UUID()
        return Recording(
            id: id,
            timestamp: Date(),
            fileName: Recording.fileName(for: id),
            transcription: "",
            duration: 1,
            status: .pending,
            progress: 0,
            sourceFileURL: sourceURL.path
        )
    }

    /// Runs one queued recording through the queue to completion.
    private func runQueue(
        _ recording: Recording,
        store: RecordingStore,
        speechPresence: SpeechPresence?,
        text: String = "",
        failure: Error? = nil
    ) async throws {
        let engine: TranscriptionEngine = failure.map(FailingTranscriptionEngine.init(failure:))
            ?? StubLanguageWhisperEngine(
                text: text,
                language: "en",
                multilingual: true,
                speechPresence: speechPresence
            )
        let queue = TranscriptionQueue(
            transcriptionService: TranscriptionService(engine: engine),
            recordingStore: store
        )
        try await store.addRecordingSync(recording)
        queue.startProcessingQueue()
        for _ in 0..<200 where queue.isProcessing {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(queue.isProcessing, "the queue must finish the recording")
    }

    // MARK: - The one decision

    /// The whole table, without side effects: what decides is the evidence about
    /// the audio, not which class of failure reached the policy.
    func testOnlyAudioHoldingNothingIsSilent() throws {
        let dummy = URL(fileURLWithPath: "/tmp/osw-silent-decision.wav")
        let empty = RecordedAudio(url: dummy, samples: [])
        let recorded = RecordedAudio(url: dummy, samples: [Float](repeating: 0.05, count: 16000))

        XCTAssertEqual(
            DictationFailurePolicy.outcome(for: RecordingCaptureError(audio: empty, underlying: TranscriptionError.audioConversionFailed)),
            .discard,
            "a capture that never wrote a frame carries nothing to keep and nothing to report"
        )
        XCTAssertEqual(
            DictationFailurePolicy.outcome(for: RecordingCaptureError(audio: recorded, underlying: TranscriptionError.audioConversionFailed)),
            .report,
            "the same capture failure over recorded audio is a genuine failure"
        )
        XCTAssertEqual(
            DictationFailurePolicy.outcome(for: try noSpeechRefusal(presence: .noSpeechSegment)),
            .discard,
            "the VAD's verdict is evidence about the recording itself"
        )
        XCTAssertEqual(
            DictationFailurePolicy.outcome(for: try noSpeechRefusal(presence: .measured(meanNoSpeechProbability: 0.95))),
            .keepAudio,
            "a measured refusal is a guess about real speech, so its audio is kept"
        )
        XCTAssertEqual(
            DictationFailurePolicy.outcome(for: try languageConflict()),
            .keepAudioAndExplain,
            "a model that cannot hear the language refused real speech, which is kept and explained"
        )
        XCTAssertEqual(
            DictationFailurePolicy.outcome(for: TranscriptionError.processingFailed),
            .report,
            "an engine that failed is reported, never silenced"
        )
        XCTAssertEqual(
            DictationFailurePolicy.outcome(for: TranscriptionError.audioConversionFailed),
            .report,
            "a converter that failed is reported, never silenced"
        )
    }

    private func languageConflict() throws -> Error {
        let conflict = try XCTUnwrap(
            SpeechModelLanguageGate.conflict(
                modelPath: Self.englishOnlyModelPath,
                isMultilingual: false,
                transcript: Self.polishDictation
            )
        )
        return TranscriptionError.speechLanguageConflict(conflict)
    }

    // MARK: - The refusals that keep nothing

    /// The engine heard the recording and the VAD found no speech segment in it:
    /// nothing is kept, nothing is written, nothing is reported.
    func testADictationWithoutSpeechIsDiscardedWithoutARowOrAnAlert() async throws {
        let store = try makeStore()
        let tempURL = makeTempURL()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let audio = try TestFixtures.recordedAudio(at: tempURL)

        let service = TranscriptionService(
            engine: StubLanguageWhisperEngine(
                text: "",
                language: nil,
                multilingual: true,
                speechPresence: .noSpeechSegment
            )
        )
        let viewModel = makeViewModel(service: service, store: store, audio: { audio })
        defer { viewModel.cleanup() }

        viewModel.startDecoding()
        try await waitForTempAudioToGo(tempURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path),
                       "a silent dictation must not leave temp audio behind")
        XCTAssertNil(AppErrorCenter.shared.issue,
                     "a recording whose audio held no speech must not raise an alert")
        let rows = try await store.fetchRecordings(limit: 10, offset: 0)
        XCTAssertTrue(rows.isEmpty,
                      "a recording whose audio held no speech writes no history row, got: \(rows.map(\.id))")
    }

    /// The reachable empty-capture path: the recorder's writer fails before its
    /// first frame and `AudioRecorder.preserveCaptureFailure` hands the failure
    /// to the same decision. Nothing was recorded, so nothing is kept, reported
    /// or written.
    func testACaptureThatCarriedNoAudioIsDiscardedWithoutARowOrAnAlert() async throws {
        let store = try makeStore()
        let tempURL = makeTempURL()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        // The header stub a dead capture leaves on disk, with no samples.
        try Data([1, 2, 3, 4]).write(to: tempURL)
        let audio = RecordedAudio(url: tempURL, samples: [])
        let failure = RecordingCaptureError(audio: audio, underlying: TranscriptionError.audioConversionFailed)

        let kept = await DictationFailurePolicy.settle(audio, error: failure, store: store)
        let rows = try await store.fetchRecordings(limit: 10, offset: 0)

        XCTAssertNil(kept, "a capture that carried no audio keeps nothing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path),
                       "a capture that carried no audio leaves no temp audio behind")
        XCTAssertTrue(rows.isEmpty,
                      "a capture that carried no audio writes no history row")
        XCTAssertNil(AppErrorCenter.shared.issue,
                     "a capture that carried no audio raises no alert")
    }

    // MARK: - The refusals that keep the recording

    /// A measurement above the user's own threshold, over audio that really was
    /// recorded: nothing is alerted, and the recording is kept — moved into the
    /// recordings directory byte for byte, with a row that records it so it is
    /// visible in History and ages with everything else.
    func testAMeasuredNoSpeechRefusalKeepsTheRecordingWithARow() async throws {
        let store = try makeStore()
        let tempURL = makeTempURL()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let audio = try TestFixtures.recordedAudio(at: tempURL)
        let recordedBytes = try Data(contentsOf: tempURL)

        let settled = await DictationFailurePolicy.settle(
            audio,
            error: try noSpeechRefusal(presence: .measured(meanNoSpeechProbability: 0.95)),
            store: store
        )
        let keptURL = try XCTUnwrap(settled, "a refusal measured over real audio must keep that audio")

        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path),
                       "the audio is moved out of the temp directory, which is cleaned up")
        XCTAssertEqual(try Data(contentsOf: keptURL), recordedBytes,
                       "the audio kept is the recording, byte for byte")
        let rows = try await store.fetchRecordings(limit: 10, offset: 0)
        let row = try XCTUnwrap(rows.first, "a kept recording is recorded so it can be found")
        defer { try? FileManager.default.removeItem(at: row.url) }
        XCTAssertEqual(row.status, .failed,
                       "a kept recording is marked as not transcribed")
        XCTAssertTrue(row.transcription.isEmpty,
                      "a kept recording carries no transcript, got: \(row.transcription)")
        XCTAssertEqual(row.sourceFileURL, row.url.path)
        XCTAssertNil(AppErrorCenter.shared.issue,
                     "a silent refusal raises no alert")
    }

    /// The language conflict end to end: the model cannot hear the dictation's
    /// language, so nothing is alerted, nothing is pasted, the recording is kept
    /// with a row that carries no transcript, and the panel says what happened,
    /// what to do, and where the recording is.
    func testALanguageConflictKeepsTheRecordingAndNamesItInThePanel() async throws {
        let store = try makeStore()
        let tempURL = makeTempURL()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let audio = try TestFixtures.recordedAudio(at: tempURL)
        let recordedBytes = try Data(contentsOf: tempURL)

        let service = try await englishOnlyService()
        let viewModel = PasteTrackingIndicator(
            transcriptionService: service,
            recordingStore: store,
            stopRecording: { audio },
            cancelAudioRecording: {},
            transformText: { text, _, _ in
                TransformService.TransformOutcome(text: text, policy: nil, didRunModel: false)
            }
        )
        viewModel.state = .recording
        defer { viewModel.cleanup() }

        viewModel.startDecoding()
        try await waitForTempAudioToGo(tempURL)

        XCTAssertNil(AppErrorCenter.shared.issue,
                     "a language conflict raises no alert")
        XCTAssertTrue(viewModel.inserted.isEmpty,
                      "a kept recording is a record, not a delivery")
        let rows = try await store.fetchRecordings(limit: 10, offset: 0)
        let row = try XCTUnwrap(rows.first, "the kept recording must be recorded")
        defer { try? FileManager.default.removeItem(at: row.url) }
        XCTAssertEqual(row.status, .failed)
        XCTAssertTrue(row.transcription.isEmpty,
                      "a kept recording carries no transcript, got: \(row.transcription)")
        XCTAssertEqual(try Data(contentsOf: row.url), recordedBytes,
                       "the recording is kept byte for byte")

        guard case .incompatibleModel(let notice) = viewModel.state else {
            return XCTFail("the panel must say what happened, got: \(viewModel.state)")
        }
        XCTAssertTrue(notice.problem.contains("Polish"),
                      "the panel must name the problem, got: \(notice.problem)")
        XCTAssertTrue(notice.action.contains("multilingual model"),
                      "the panel must name the one action, got: \(notice.action)")
        XCTAssertTrue(notice.location.contains("Transcriptions Directory"),
                      "the panel must say where the recording is, got: \(notice.location)")
    }

    // MARK: - The queue leaves nothing either

    /// A dictation of ours that is refused for no speech after being routed to
    /// the queue (a busy engine) is discarded exactly like the indicator's
    /// silent paths: no row, no copy in the recordings directory, and the temp
    /// audio goes.
    func testAQueuedDictationRefusedForNoSpeechIsDiscarded() async throws {
        let store = try makeStore()
        // The recorder's own temp directory: what makes the queue treat this as
        // a recording of ours rather than a file the user queued.
        try FileManager.default.createDirectory(
            at: AudioRecorder.temporaryRecordingsDirectory,
            withIntermediateDirectories: true
        )
        let sourceURL = AudioRecorder.temporaryRecordingsDirectory
            .appendingPathComponent("osw-queued-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        _ = try TestFixtures.recordedAudio(at: sourceURL)

        let recording = pendingRecording(sourceURL: sourceURL)
        defer { try? FileManager.default.removeItem(at: recording.url) }
        try await runQueue(recording, store: store, speechPresence: .noSpeechSegment)

        let rows = try await store.fetchRecordings(limit: 10, offset: 0)
        XCTAssertTrue(rows.isEmpty,
                      "a dictation refused for no speech is discarded, not stored, got: \(rows.map(\.transcription))")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path),
                       "our own temp recording goes with the row")
        XCTAssertFalse(FileManager.default.fileExists(atPath: recording.url.path),
                       "nothing may be copied into the recordings directory")
        XCTAssertNil(AppErrorCenter.shared.issue,
                     "a dictation refused for no speech must not raise an alert")
    }

    /// A file the user queued is theirs. Refused for no speech it is left
    /// exactly where it is — no copy in the recordings directory, no row, no
    /// alert, and the file's own bytes untouched.
    func testAQueuedImportedFileRefusedForNoSpeechIsLeftWhereItIs() async throws {
        try await assertImportedFileIsLeftWhereItIs(speechPresence: .noSpeechSegment)
    }

    /// The same rule for an engine that returned no text at all: an outcome with
    /// no text is invisible wherever the user looks, and a file he queued is
    /// never copied, moved or deleted for it.
    func testAQueuedImportedFileWithNoTranscriptIsLeftWhereItIs() async throws {
        try await assertImportedFileIsLeftWhereItIs(speechPresence: nil)
    }

    private func assertImportedFileIsLeftWhereItIs(speechPresence: SpeechPresence?) async throws {
        let store = try makeStore()
        // Somewhere the user keeps files: not the recorder's temp directory, so
        // the queue must treat it as an import.
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("osw-imported-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        _ = try TestFixtures.recordedAudio(at: sourceURL)
        let sourceBytes = try Data(contentsOf: sourceURL)

        let recording = pendingRecording(sourceURL: sourceURL)
        defer { try? FileManager.default.removeItem(at: recording.url) }
        try await runQueue(recording, store: store, speechPresence: speechPresence)

        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path),
                      "the user's file must stay where it is")
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBytes,
                       "the user's file must be untouched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: recording.url.path),
                       "no copy may land in the recordings directory")
        // He asked for this file to be transcribed, so the row stays and names
        // it — silence would leave him unable to tell whether it worked.
        let rows = try await store.fetchRecordings(limit: 10, offset: 0)
        let row = try XCTUnwrap(rows.first, "a file the user queued keeps its row")
        XCTAssertEqual(row.status, .failed)
        XCTAssertTrue(row.transcription.isEmpty,
                      "the row carries no transcript of its own, got: \(row.transcription)")
        XCTAssertEqual(row.sourceFileURL, sourceURL.path)
        XCTAssertEqual(row.sourceFileName, sourceURL.lastPathComponent,
                       "the row names the file he chose")
        XCTAssertNil(AppErrorCenter.shared.issue,
                     "a silent refusal must not raise an alert")
    }

    /// A file the user queued that transcribes: the row gets the text, and his
    /// file is copied into the recordings directory but never modified, moved or
    /// deleted — he keeps what he imported and History keeps a playable copy.
    func testAQueuedImportedFileTranscribedKeepsTheTextAndItsSource() async throws {
        let store = try makeStore()
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("osw-imported-success-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        _ = try TestFixtures.recordedAudio(at: sourceURL)
        let sourceBytes = try Data(contentsOf: sourceURL)

        let recording = pendingRecording(sourceURL: sourceURL)
        defer { try? FileManager.default.removeItem(at: recording.url) }
        try await runQueue(
            recording,
            store: store,
            speechPresence: nil,
            text: "hello there"
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path),
                      "the user's file must stay where it is")
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceBytes,
                       "the user's file must not be modified")
        let rows = try await store.fetchRecordings(limit: 10, offset: 0)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.status, .completed)
        XCTAssertEqual(row.transcription, "hello there",
                       "the transcript the engine produced is stored")
        XCTAssertEqual(row.sourceFileURL, sourceURL.path)
        XCTAssertEqual(try Data(contentsOf: row.url), sourceBytes,
                       "the recordings-directory copy is the file he imported")
        XCTAssertNil(AppErrorCenter.shared.issue)
    }

    /// A regeneration reads the recording's own file, so the row and its audio
    /// are the same thing. A refusal there must leave both exactly as they are:
    /// deleting the row would take the recording with it, and nothing may claim
    /// the file moved when it never did.
    func testARegeneratedRecordingRefusedForNoSpeechKeepsItsRowAndItsAudio() async throws {
        let store = try makeStore()
        let id = UUID()
        try FileManager.default.createDirectory(
            at: Recording.recordingsDirectory,
            withIntermediateDirectories: true
        )
        let storedURL = Recording.recordingsDirectory.appendingPathComponent(Recording.fileName(for: id))
        defer { try? FileManager.default.removeItem(at: storedURL) }
        let audio = try TestFixtures.recordedAudio(at: storedURL)
        let storedBytes = try Data(contentsOf: storedURL)

        let recording = Recording(
            id: id,
            timestamp: Date(),
            fileName: storedURL.lastPathComponent,
            transcription: "what was said before",
            duration: audio.duration,
            // The queue only picks up pending/converting/transcribing rows
            // (`getNextPendingRecording`), and a real regeneration is put in
            // that state by `TranscriptionQueue.requeue(_:)` before processing
            // starts. A completed row is never picked up, so the fixture must
            // use the state the path actually processes.
            status: .pending,
            progress: 1.0,
            sourceFileURL: storedURL.path
        )
        try await runQueue(
            recording,
            store: store,
            speechPresence: .measured(meanNoSpeechProbability: 0.95)
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: storedURL.path),
                      "the recording's own audio must never be deleted")
        XCTAssertEqual(try Data(contentsOf: storedURL), storedBytes,
                       "the recording's own audio must be untouched")
        let rows = try await store.fetchRecordings(limit: 10, offset: 0)
        let row = try XCTUnwrap(rows.first, "the row must survive with its audio")
        XCTAssertEqual(row.id, id)
        XCTAssertTrue(row.transcription.isEmpty,
                      "a kept recording carries no transcript, got: \(row.transcription)")
        XCTAssertNotEqual(row.status, .completed,
                          "a recording that produced no transcript is not marked transcribed")
        XCTAssertNil(AppErrorCenter.shared.issue,
                     "a silent refusal raises no alert")
    }

    /// A failed transcription stores no transcript — the reason belongs to the
    /// log and the row's failed status, not to the column that means "what the
    /// user dictated" — and our own temp recording is moved where the row keeps
    /// its audio before the row is written, so the failed row never points at a
    /// file the temp cleanup will take.
    func testAQueuedFailureStoresNoTranscriptAndKeepsItsAudio() async throws {
        let store = try makeStore()
        try FileManager.default.createDirectory(
            at: AudioRecorder.temporaryRecordingsDirectory,
            withIntermediateDirectories: true
        )
        let sourceURL = AudioRecorder.temporaryRecordingsDirectory
            .appendingPathComponent("osw-queued-failure-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        _ = try TestFixtures.recordedAudio(at: sourceURL)
        let sourceBytes = try Data(contentsOf: sourceURL)

        let recording = pendingRecording(sourceURL: sourceURL)
        defer { try? FileManager.default.removeItem(at: recording.url) }
        try await runQueue(
            recording,
            store: store,
            speechPresence: nil,
            failure: TranscriptionError.processingFailed
        )

        let rows = try await store.fetchRecordings(limit: 10, offset: 0)
        let row = try XCTUnwrap(rows.first, "a failed transcription is recorded")
        XCTAssertEqual(row.status, .failed)
        XCTAssertTrue(row.transcription.isEmpty,
                      "the failure's own text was stored as the transcript, got: \(row.transcription)")
        XCTAssertEqual(try Data(contentsOf: row.url), sourceBytes,
                       "the failed row's audio is the recording, kept where the row says")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path),
                       "the temp audio was moved, not left for the cleanup")
        XCTAssertEqual(row.sourceFileURL, row.url.path)
    }

    // MARK: - The failure that stays visible

    /// Real audio, an engine that failed unexpectedly: a defect the user has to
    /// know about, and the audio is theirs, so the alert and the failed row both
    /// stay — with no transcript, as every failed dictation.
    func testAGenuineDecodeFailureStillReportsAndStillKeepsItsAudio() async throws {
        let store = try makeStore()
        let tempURL = makeTempURL()
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let audio = try TestFixtures.recordedAudio(at: tempURL)
        let recordedBytes = try Data(contentsOf: tempURL)

        let service = TranscriptionService(
            engine: FailingTranscriptionEngine(failure: TranscriptionError.processingFailed)
        )
        let viewModel = makeViewModel(service: service, store: store, audio: { audio })
        defer { viewModel.cleanup() }

        viewModel.startDecoding()
        try await waitForReport()
        let rows = try await store.fetchRecordings(limit: 10, offset: 0)
        let row = try XCTUnwrap(rows.first, "a genuine decode failure is still recorded")
        // The store keeps failed audio in the app's own directory, so remove
        // exactly the file this call created — its returned URL, nothing broader.
        defer { try? FileManager.default.removeItem(at: row.url) }

        XCTAssertEqual(row.status, .failed)
        XCTAssertTrue(row.transcription.isEmpty,
                      "a failed dictation must carry no transcript, got: \(row.transcription)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: row.url.path),
                      "a genuine decode failure must keep its audio")
        XCTAssertEqual(try Data(contentsOf: row.url), recordedBytes,
                       "the recorded audio is what was kept")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path),
                       "the audio was moved into the recordings directory")
        XCTAssertNotNil(AppErrorCenter.shared.issue,
                        "a genuine decode failure must still be reported to the user")
    }
}
