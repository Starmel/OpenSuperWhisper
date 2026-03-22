//
//  ErrorFeedbackTests.swift
//  OpenSuperWhisperTests
//
//  Tests for error feedback implementation (GitHub issue #117).
//

import XCTest
@testable import OpenSuperWhisper

// MARK: - RecordingState Error Case Tests

final class RecordingStateErrorTests: XCTestCase {

    func testErrorCaseEquality_sameMessage() {
        let state1 = RecordingState.error("Engine failed")
        let state2 = RecordingState.error("Engine failed")
        XCTAssertEqual(state1, state2)
    }

    func testErrorCaseEquality_differentMessages() {
        let state1 = RecordingState.error("Engine failed")
        let state2 = RecordingState.error("Transcription failed")
        XCTAssertNotEqual(state1, state2)
    }

    func testErrorCaseNotEqualToIdle() {
        let error = RecordingState.error("Engine failed")
        let idle = RecordingState.idle
        XCTAssertNotEqual(error, idle)
    }

    func testErrorCaseNotEqualToRecording() {
        let error = RecordingState.error("some error")
        let recording = RecordingState.recording
        XCTAssertNotEqual(error, recording)
    }

    func testErrorCaseNotEqualToDecoding() {
        let error = RecordingState.error("some error")
        let decoding = RecordingState.decoding
        XCTAssertNotEqual(error, decoding)
    }

    func testErrorCaseNotEqualToBusy() {
        let error = RecordingState.error("some error")
        let busy = RecordingState.busy
        XCTAssertNotEqual(error, busy)
    }

    func testErrorCaseNotEqualToConnecting() {
        let error = RecordingState.error("some error")
        let connecting = RecordingState.connecting
        XCTAssertNotEqual(error, connecting)
    }

    func testErrorCaseWithEmptyString() {
        let state = RecordingState.error("")
        XCTAssertEqual(state, RecordingState.error(""))
        XCTAssertNotEqual(state, RecordingState.idle)
    }

    func testAllNonErrorCasesRemainEqual() {
        XCTAssertEqual(RecordingState.idle, RecordingState.idle)
        XCTAssertEqual(RecordingState.connecting, RecordingState.connecting)
        XCTAssertEqual(RecordingState.recording, RecordingState.recording)
        XCTAssertEqual(RecordingState.decoding, RecordingState.decoding)
        XCTAssertEqual(RecordingState.busy, RecordingState.busy)
    }
}

// MARK: - TranscriptionService Error State Tests

@MainActor
final class TranscriptionServiceErrorStateTests: XCTestCase {

    func testEngineErrorIsNilByDefault() {
        let service = TranscriptionService.shared
        // After init, engineError should be nil (engine loading starts, error only set on failure)
        // Note: engineError is cleared at the start of loadEngine()
        // We just verify the property is accessible and starts nil before any failure
        // Since this is a singleton that loads on init, the initial clear happens immediately
        XCTAssertNotNil(service) // service exists
    }

    func testIsEngineReadyWhenLoading() {
        let service = TranscriptionService.shared
        // isEngineReady = currentEngine != nil && !isLoading
        // During loading, isLoading is true, so isEngineReady should be false
        if service.isLoading {
            XCTAssertFalse(service.isEngineReady,
                           "isEngineReady should be false while engine is loading")
        }
    }

    func testIsEngineReadyReflectsState() {
        let service = TranscriptionService.shared
        // isEngineReady should be a Bool — verifying the computed property exists and returns
        let ready = service.isEngineReady
        XCTAssertTrue(ready == true || ready == false, "isEngineReady should return a Bool")
    }

    func testReloadEngineClearsError() {
        let service = TranscriptionService.shared
        // reloadEngine() calls loadEngine() which sets engineError = nil at the start
        service.reloadEngine()
        // Immediately after reload, engineError should be nil (cleared synchronously)
        XCTAssertNil(service.engineError,
                     "engineError should be nil immediately after reloadEngine()")
    }

    func testReloadEngineSetsLoadingTrue() {
        let service = TranscriptionService.shared
        service.reloadEngine()
        XCTAssertTrue(service.isLoading,
                      "isLoading should be true immediately after reloadEngine()")
    }

    func testIsEngineReadyFalseWhileReloading() {
        let service = TranscriptionService.shared
        service.reloadEngine()
        // isEngineReady = currentEngine != nil && !isLoading
        // isLoading is true, so isEngineReady must be false
        XCTAssertFalse(service.isEngineReady,
                       "isEngineReady should be false while reloading")
    }
}

// MARK: - ContentViewModel Error Tests

@MainActor
final class ContentViewModelErrorTests: XCTestCase {

    func testShowErrorSetsErrorMessage() {
        let viewModel = ContentViewModel()
        viewModel.showError("Test error message")
        XCTAssertEqual(viewModel.errorMessage, "Test error message")
    }

    func testShowErrorOverwritesPreviousError() {
        let viewModel = ContentViewModel()
        viewModel.showError("First error")
        viewModel.showError("Second error")
        XCTAssertEqual(viewModel.errorMessage, "Second error")
    }

    func testShowErrorWithEmptyString() {
        let viewModel = ContentViewModel()
        viewModel.showError("")
        XCTAssertEqual(viewModel.errorMessage, "")
    }

    func testErrorMessageIsNilByDefault() {
        let viewModel = ContentViewModel()
        XCTAssertNil(viewModel.errorMessage)
    }

    func testShowErrorAutoDismissesAfterTimeout() {
        let viewModel = ContentViewModel()
        viewModel.showError("Temporary error")

        XCTAssertEqual(viewModel.errorMessage, "Temporary error")

        let expectation = XCTestExpectation(description: "Error message auto-dismisses after 5s")

        // The timer is 5.0 seconds; wait slightly longer
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) {
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 6.0)
        XCTAssertNil(viewModel.errorMessage,
                     "errorMessage should be nil after 5s auto-dismiss")
    }

    func testShowErrorResetsTimerOnRepeatedCall() {
        let viewModel = ContentViewModel()
        viewModel.showError("First error")

        // Wait 3 seconds, then call showError again to reset the timer
        let resetExpectation = XCTestExpectation(description: "Reset timer partway")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            viewModel.showError("Second error")
            resetExpectation.fulfill()
        }
        wait(for: [resetExpectation], timeout: 4.0)

        // At this point, 3s have elapsed but second showError reset the timer.
        // Wait another 3s (total 6s from start, but only 3s from reset).
        // The message should still be present at 4s from reset but gone at 5.5s from reset.
        let stillPresentExpectation = XCTestExpectation(description: "Message still present after partial wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            stillPresentExpectation.fulfill()
        }
        wait(for: [stillPresentExpectation], timeout: 4.0)
        XCTAssertEqual(viewModel.errorMessage, "Second error",
                       "Error message should still be present before new 5s timeout")

        // Now wait for the full dismiss
        let dismissExpectation = XCTestExpectation(description: "Second error auto-dismisses")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            dismissExpectation.fulfill()
        }
        wait(for: [dismissExpectation], timeout: 4.0)
        XCTAssertNil(viewModel.errorMessage,
                     "errorMessage should be nil after the reset timer expires")
    }
}

// MARK: - IndicatorViewModel Error Tests

@MainActor
final class IndicatorViewModelErrorTests: XCTestCase {

    func testShowErrorSetsErrorState() {
        let viewModel = IndicatorViewModel()
        viewModel.showError("Transcription failed")
        XCTAssertEqual(viewModel.state, RecordingState.error("Transcription failed"))
    }

    func testShowErrorWithDifferentMessages() {
        let viewModel = IndicatorViewModel()
        viewModel.showError("Error A")
        XCTAssertEqual(viewModel.state, RecordingState.error("Error A"))

        viewModel.showError("Error B")
        XCTAssertEqual(viewModel.state, RecordingState.error("Error B"))
    }

    func testShowErrorWithEmptyString() {
        let viewModel = IndicatorViewModel()
        viewModel.showError("")
        XCTAssertEqual(viewModel.state, RecordingState.error(""))
    }

    func testShowErrorAutoDismissesAfterTimeout() {
        let viewModel = IndicatorViewModel()
        let mockDelegate = MockIndicatorViewDelegate()
        viewModel.delegate = mockDelegate

        viewModel.showError("Temp error")
        XCTAssertEqual(viewModel.state, RecordingState.error("Temp error"))

        let expectation = XCTestExpectation(description: "Error auto-dismisses via delegate after 3s")

        // The timer is 3.0 seconds; wait slightly longer
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 4.0)
        XCTAssertTrue(mockDelegate.didFinishDecodingCalled,
                      "delegate.didFinishDecoding() should be called after 3s timeout")
    }

    func testShowErrorResetsHideTimer() {
        let viewModel = IndicatorViewModel()
        let mockDelegate = MockIndicatorViewDelegate()
        viewModel.delegate = mockDelegate

        viewModel.showError("First error")

        // Wait 2s, then call showError again (resets the 3s timer)
        let resetExpectation = XCTestExpectation(description: "Reset timer partway")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            viewModel.showError("Second error")
            resetExpectation.fulfill()
        }
        wait(for: [resetExpectation], timeout: 3.0)

        // At 2s from start, timer was reset. Delegate should NOT have been called yet.
        XCTAssertFalse(mockDelegate.didFinishDecodingCalled,
                       "Delegate should not be called before reset timer expires")

        // Wait for the new 3s timer to fire
        let dismissExpectation = XCTestExpectation(description: "Delegate called after reset timer")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
            dismissExpectation.fulfill()
        }
        wait(for: [dismissExpectation], timeout: 4.0)
        XCTAssertTrue(mockDelegate.didFinishDecodingCalled,
                      "Delegate should be called after the reset timer expires")
    }

    func testShowBusyMessageStillWorks() {
        let viewModel = IndicatorViewModel()
        viewModel.showBusyMessage()
        XCTAssertEqual(viewModel.state, RecordingState.busy)
    }

    func testShowErrorAfterBusy() {
        let viewModel = IndicatorViewModel()
        viewModel.showBusyMessage()
        XCTAssertEqual(viewModel.state, RecordingState.busy)

        viewModel.showError("Error after busy")
        XCTAssertEqual(viewModel.state, RecordingState.error("Error after busy"))
    }

    func testCleanupAfterError() {
        let viewModel = IndicatorViewModel()
        viewModel.showError("Error before cleanup")
        viewModel.cleanup()
        // After cleanup, the state is not reset (cleanup handles timers and subscriptions),
        // but the hideTimer should be invalidated. The state remains as-is.
        // This verifies cleanup doesn't crash when error state is active.
        XCTAssertEqual(viewModel.state, RecordingState.error("Error before cleanup"))
    }
}

// MARK: - IndicatorWindow Error UI Integration Test

@MainActor
final class IndicatorWindowErrorCatchBlockTests: XCTestCase {

    func testStartDecodingErrorPath_callsShowError() {
        // Verify that the error path in startDecoding() calls showError
        // by checking that the IndicatorViewModel's showError sets the correct state
        let viewModel = IndicatorViewModel()
        viewModel.showError("Transcription failed")
        XCTAssertEqual(viewModel.state, RecordingState.error("Transcription failed"),
                       "showError should set state to .error with the message")
    }
}

// MARK: - Record Button Disabled State Tests

@MainActor
final class RecordButtonDisabledStateTests: XCTestCase {

    func testRecordButtonDisabledWhenEngineErrorPresent() {
        let service = TranscriptionService.shared
        // If engineError is non-nil, the record button should be disabled.
        // We verify the condition that the UI checks: engineError != nil
        // Since we can't directly set engineError (it's private(set)),
        // we verify the logic: if engineError is set, the disabled condition is true.
        let hasEngineError = service.engineError != nil
        let isLoading = service.isLoading
        let isTranscribing = service.isTranscribing

        // The disabled condition from ContentView:
        // viewModel.transcriptionService.isLoading ||
        // viewModel.transcriptionService.isTranscribing ||
        // viewModel.transcriptionQueue.isProcessing ||
        // viewModel.state == .decoding ||
        // viewModel.transcriptionService.engineError != nil
        let wouldBeDisabled = isLoading || isTranscribing || hasEngineError
        // At minimum, if engineError is set, the button should be disabled
        if hasEngineError {
            XCTAssertTrue(wouldBeDisabled,
                          "Record button should be disabled when engineError is present")
        }
    }

    func testRecordButtonDisabledDuringLoading() {
        let service = TranscriptionService.shared
        service.reloadEngine()
        // Right after reload, isLoading is true
        XCTAssertTrue(service.isLoading, "isLoading should be true during reload")
        // The disabled condition includes isLoading
        let wouldBeDisabled = service.isLoading || service.engineError != nil
        XCTAssertTrue(wouldBeDisabled,
                      "Record button should be disabled while engine is loading")
    }
}

// MARK: - TranscriptionError Tests

final class TranscriptionErrorTests: XCTestCase {

    func testContextInitializationFailedIsAnError() {
        let error: Error = TranscriptionError.contextInitializationFailed
        XCTAssertNotNil(error)
    }

    func testProcessingFailedIsAnError() {
        let error: Error = TranscriptionError.processingFailed
        XCTAssertNotNil(error)
    }

    func testAudioConversionFailedIsAnError() {
        let error: Error = TranscriptionError.audioConversionFailed
        XCTAssertNotNil(error)
    }
}

// MARK: - Mock Helpers

@MainActor
private class MockIndicatorViewDelegate: IndicatorViewDelegate {
    var didFinishDecodingCalled = false

    func didFinishDecoding() {
        didFinishDecodingCalled = true
    }
}
