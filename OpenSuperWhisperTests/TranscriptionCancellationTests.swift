import Foundation
import GRDB
import XCTest
@testable import OpenSuperWhisper

private final class ControlledTranscriptionEngine: TranscriptionEngine {
    var isModelLoaded: Bool { true }
    var engineName: String { "Controlled test engine" }

    private let lock = NSLock()
    private var continuations: [String: CheckedContinuation<String, Error>] = [:]
    private var nextStartHandler: (() -> Void)?
    private var startCountStorage = 0
    private var cancelCountStorage = 0
    private var activeCallCount = 0
    private var maxConcurrentCallCountStorage = 0

    var startCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return startCountStorage
    }

    var cancelCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancelCountStorage
    }

    var maxConcurrentCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return maxConcurrentCallCountStorage
    }

    func initialize() async throws {}

    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<String, Error>) in
            lock.lock()
            continuations[url.path] = continuation
            startCountStorage += 1
            activeCallCount += 1
            maxConcurrentCallCountStorage = max(
                maxConcurrentCallCountStorage,
                activeCallCount
            )
            let startHandler = nextStartHandler
            nextStartHandler = nil
            lock.unlock()

            startHandler?()
        }
    }

    func cancelTranscription() {
        lock.lock()
        cancelCountStorage += 1
        lock.unlock()
    }

    func getSupportedLanguages() -> [String] {
        ["en", "ru"]
    }

    func notifyOnNextStart(_ handler: @escaping () -> Void) {
        lock.lock()
        nextStartHandler = handler
        lock.unlock()
    }

    @discardableResult
    func complete(
        url: URL,
        with result: Result<String, Error>
    ) -> Bool {
        lock.lock()
        guard let continuation = continuations.removeValue(forKey: url.path) else {
            lock.unlock()
            return false
        }
        activeCallCount -= 1
        lock.unlock()

        continuation.resume(with: result)
        return true
    }
}

@MainActor
final class TranscriptionCancellationTests: XCTestCase {
    private let audioURL = URL(fileURLWithPath: "/tmp/osw-cancellation-test.wav")

    func testEscDuringDecodingCancelsEngineAndRejectsLateResult() async throws {
        let engine = ControlledTranscriptionEngine()
        let service = TranscriptionService(engine: engine)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("osw-escape-cancel-\(UUID().uuidString).wav")
        try Data(repeating: 0, count: 64).write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let viewModel = IndicatorViewModel(
            transcriptionService: service,
            stopRecording: { RecordedAudio(url: tempURL, samples: []) },
            cancelAudioRecording: {}
        )
        viewModel.state = .recording

        let started = expectation(description: "native decode started")
        engine.notifyOnNextStart { started.fulfill() }

        viewModel.startDecoding()

        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(viewModel.state == .decoding)
        viewModel.cancelRecording()

        XCTAssertEqual(engine.cancelCount, 1)
        XCTAssertTrue(
            service.isTranscribing,
            "The service must stay busy until the native decoder actually exits"
        )

        XCTAssertTrue(
            engine.complete(url: tempURL, with: .success("late result"))
        )

        for _ in 0..<100 {
            if !service.isTranscribing { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        XCTAssertFalse(service.isTranscribing)
        XCTAssertTrue(service.transcribedText.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempURL.path))
        viewModel.cleanup()
    }

    func testShortcutEscapeReachesDecodingWithoutActiveRecordingReference() async throws {
        let engine = ControlledTranscriptionEngine()
        let service = TranscriptionService(engine: engine)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let vm = IndicatorViewModel(transcriptionService: service,
                                    stopRecording: { RecordedAudio(url: url, samples: []) },
                                    cancelAudioRecording: {})
        vm.state = .recording
        let manager = IndicatorWindowManager.shared
        let original = manager.viewModel
        manager.viewModel = vm
        defer { manager.viewModel = original; vm.cleanup() }
        let started = expectation(description: "started")
        engine.notifyOnNextStart { started.fulfill() }
        vm.startDecoding()
        await fulfillment(of: [started], timeout: 2)
        ShortcutManager(registerShortcuts: false).handleEscape()
        XCTAssertEqual(engine.cancelCount, 1)
        XCTAssertTrue(engine.complete(url: url, with: .success("must not publish")))
        for _ in 0..<100 where service.isTranscribing {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(service.transcribedText.isEmpty)
    }

    func testCancellingQueueWaiterDoesNotCancelDictation() async throws {
        let engine = ControlledTranscriptionEngine()
        let service = TranscriptionService(engine: engine)
        let store = try RecordingStore(databaseQueue: DatabaseQueue())
        let queue = TranscriptionQueue(transcriptionService: service, recordingStore: store)
        let started = expectation(description: "dictation started")
        engine.notifyOnNextStart { started.fulfill() }
        let dictation = Task { try await service.transcribeAudio(url: audioURL, settings: Settings()) }
        await fulfillment(of: [started], timeout: 2)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([1]).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let id = UUID()
        let recording = Recording(id: id, timestamp: Date(), fileName: Recording.fileName(for: id),
                                  transcription: "", duration: 1, status: .pending, progress: 0,
                                  sourceFileURL: source.path)
        try await store.addRecordingSync(recording)
        queue.startProcessingQueue()
        for _ in 0..<100 where queue.currentRecordingId != id {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(queue.currentRecordingId, id)
        queue.cancelRecording(id)
        try await store.deleteRecordingSync(recording)
        XCTAssertEqual(engine.cancelCount, 0)
        XCTAssertTrue(engine.complete(url: audioURL, with: .success("dictation survives")))
        let result = try await dictation.value
        XCTAssertEqual(result, "dictation survives")
        for _ in 0..<100 where queue.isProcessing {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(queue.isProcessing)
        XCTAssertEqual(engine.startCount, 1)
    }

    func testDecodingErrorPreservesFailedRecording() async throws {
        let engine = ControlledTranscriptionEngine()
        let service = TranscriptionService(engine: engine)
        let store = try RecordingStore(databaseQueue: DatabaseQueue())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data([1, 2]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url); AppErrorCenter.shared.issue = nil }
        let vm = IndicatorViewModel(transcriptionService: service, recordingStore: store,
                                    stopRecording: { RecordedAudio(url: url, samples: []) }, cancelAudioRecording: {})
        vm.state = .recording
        let started = expectation(description: "decode started")
        engine.notifyOnNextStart { started.fulfill() }
        vm.startDecoding()
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(engine.complete(url: url, with: .failure(TranscriptionError.processingFailed)))
        var rows: [Recording] = []
        for _ in 0..<100 {
            rows = try await store.fetchRecordings(limit: 10, offset: 0)
            if !rows.isEmpty { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let row = try XCTUnwrap(rows.first)
        defer { try? FileManager.default.removeItem(at: row.url); vm.cleanup() }
        XCTAssertEqual(row.status, .failed)
        XCTAssertEqual(try Data(contentsOf: row.url), Data([1, 2]))
        XCTAssertTrue(service.transcribedText.isEmpty)
    }

    func testScopedCancellationDoesNotCancelDifferentOperation() async throws {
        let engine = ControlledTranscriptionEngine()
        let service = TranscriptionService(engine: engine)
        let operationID = UUID()
        let started = expectation(description: "decode started")
        engine.notifyOnNextStart { started.fulfill() }

        let transcription = Task {
            try await service.transcribeAudio(
                url: audioURL,
                settings: Settings(),
                operationID: operationID
            )
        }

        await fulfillment(of: [started], timeout: 2)
        service.cancelTranscription(operationID: UUID())

        XCTAssertEqual(engine.cancelCount, 0)
        XCTAssertTrue(
            engine.complete(url: audioURL, with: .success("expected result"))
        )
        let result = try await transcription.value
        XCTAssertEqual(result, "expected result")
    }

    func testCancelledNativeRunBlocksNextDecodeUntilItReturns() async throws {
        let engine = ControlledTranscriptionEngine()
        let service = TranscriptionService(engine: engine)
        let firstID = UUID()
        let firstURL = URL(fileURLWithPath: "/tmp/osw-cancellation-first.wav")
        let secondURL = URL(fileURLWithPath: "/tmp/osw-cancellation-second.wav")
        let firstStarted = expectation(description: "first decode started")
        engine.notifyOnNextStart { firstStarted.fulfill() }

        let first = Task {
            try await service.transcribeAudio(
                url: firstURL,
                settings: Settings(),
                operationID: firstID
            )
        }

        await fulfillment(of: [firstStarted], timeout: 2)
        service.cancelTranscription(operationID: firstID)

        let secondStarted = expectation(description: "second decode started")
        let secondEnteredService = expectation(
            description: "second caller entered service"
        )
        engine.notifyOnNextStart { secondStarted.fulfill() }
        let second = Task {
            secondEnteredService.fulfill()
            return try await service.transcribeAudio(
                url: secondURL,
                settings: Settings(),
                operationID: UUID()
            )
        }

        await fulfillment(of: [secondEnteredService], timeout: 2)
        await Task.yield()
        XCTAssertEqual(
            engine.startCount,
            1,
            "A second native decode must wait while cancellation is in flight"
        )
        XCTAssertTrue(service.isTranscribing)

        XCTAssertTrue(
            engine.complete(
                url: firstURL,
                with: .success("ignored late result")
            )
        )
        do {
            _ = try await first.value
            XCTFail("The first decode must finish as cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }

        await fulfillment(of: [secondStarted], timeout: 2)
        XCTAssertEqual(engine.maxConcurrentCallCount, 1)
        XCTAssertTrue(
            engine.complete(url: secondURL, with: .success("second result"))
        )
        let secondResult = try await second.value
        XCTAssertEqual(secondResult, "second result")
    }

    func testLateViewModelCompletionCannotHideCurrentSession() {
        let service = TranscriptionService(engine: ControlledTranscriptionEngine())
        let oldViewModel = IndicatorViewModel(transcriptionService: service)
        let currentViewModel = IndicatorViewModel(transcriptionService: service)
        let manager = IndicatorWindowManager.shared
        let originalViewModel = manager.viewModel
        defer { manager.viewModel = originalViewModel }

        manager.viewModel = currentViewModel
        let accepted = manager.didFinishDecoding(from: oldViewModel)

        XCTAssertFalse(accepted)
        XCTAssertTrue(manager.viewModel === currentViewModel)
        oldViewModel.cleanup()
        currentViewModel.cleanup()
    }
}
