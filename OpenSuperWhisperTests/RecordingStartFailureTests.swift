import XCTest
@testable import OpenSuperWhisper

@MainActor
final class RecordingStartFailureTests: XCTestCase {
    func testLateRecorderEventsCannotReviveFailedIndicator() async throws {
        let vm = IndicatorViewModel(transcriptionService: TranscriptionService(engine: NamedTestEngine("test")))
        let recorder = AudioRecorder.shared
        let previousRecording = recorder.isRecording
        let previousConnecting = recorder.isConnecting
        defer {
            recorder.isRecording = previousRecording
            recorder.isConnecting = previousConnecting
            vm.cleanup()
        }
        vm.state = .connecting
        recorder.isConnecting = true
        recorder.isRecording = true
        vm.resetAfterRecordingFailure()
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(vm.state, .idle)
        XCTAssertFalse(vm.isBlinking)
    }

    func testMainWindowClearsConnectingAndRecordingAfterFailure() {
        let vm = ContentViewModel(fetchPage: { _, _, _ in [] })
        for state in [RecordingState.connecting, .recording] {
            vm.state = state
            vm.isBlinking = true
            vm.recordingDuration = 10
            vm.resetAfterRecordingFailure()
            XCTAssertEqual(vm.state, .idle)
            XCTAssertFalse(vm.isBlinking)
            XCTAssertEqual(vm.recordingDuration, 0)
        }
    }
    func testIndicatorClearsOptimisticCaptureStateAfterFailure() {
        let vm = IndicatorViewModel(transcriptionService: TranscriptionService(engine: NamedTestEngine("test")))
        for state in [RecordingState.connecting, .recording] {
            vm.state = state
            vm.isBlinking = true
            vm.recordingStartedAt = Date()
            vm.resetAfterRecordingFailure()
            XCTAssertEqual(vm.state, .idle)
            XCTAssertFalse(vm.isBlinking)
            XCTAssertNil(vm.recordingStartedAt)
        }
        vm.cleanup()
    }
}
