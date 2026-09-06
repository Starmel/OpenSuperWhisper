import XCTest
import GRDB
@testable import OpenSuperWhisper

@MainActor
private final class SuspendedRecordingStore: RecordingStore {
    var entered: XCTestExpectation?
    var resume: CheckedContinuation<Void, Never>?
    var saving: Recording?
    var reject = false
    override func addRecordingSync(_ recording: Recording) async throws {
        saving = recording
        await withCheckedContinuation { continuation in
            resume = continuation
            entered?.fulfill()
        }
        if reject { throw TranscriptionError.processingFailed }
        try await Task { try await self.commitRow(recording) }.value
    }
    private func commitRow(_ recording: Recording) async throws {
        try await super.addRecordingSync(recording)
    }
}

@MainActor
private final class PasteTrackingIndicator: IndicatorViewModel {
    var inserted: [String] = []
    override func insertText(_ text: String) { inserted.append(text) }
}

@MainActor
final class DictationSaveCancellationTests: XCTestCase {
    func testCancellationDuringSaveRemovesAudioAndRejectsPaste() async throws {
        for reject in [false, true] {
            let store = try SuspendedRecordingStore(databaseQueue: DatabaseQueue())
            store.reject = reject
            store.entered = expectation(description: "saving")
            let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            try Data([1]).write(to: source)
            defer { try? FileManager.default.removeItem(at: source) }
            let service = TranscriptionService(engine: NamedTestEngine("recognized"))
            let vm = PasteTrackingIndicator(transcriptionService: service, recordingStore: store,
                stopRecording: { RecordedAudio(url: source, samples: []) }, cancelAudioRecording: {})
            vm.state = .recording
            vm.startDecoding()
            await fulfillment(of: [try XCTUnwrap(store.entered)], timeout: 2)
            let row = try XCTUnwrap(store.saving)
            defer { try? FileManager.default.removeItem(at: row.url); vm.cleanup() }
            vm.cancelRecording()
            store.resume?.resume()
            for _ in 0..<100 where FileManager.default.fileExists(atPath: row.url.path) {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: row.url.path))
            let rows = try await store.fetchRecordings(limit: 10, offset: 0)
            XCTAssertTrue(rows.isEmpty)
            XCTAssertTrue(vm.inserted.isEmpty)
        }
    }
}
