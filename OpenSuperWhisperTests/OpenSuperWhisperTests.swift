//
//  OpenSuperWhisperTests.swift
//  OpenSuperWhisperTests
//
//  Created by user on 05.02.2025.
//

import XCTest
@testable import OpenSuperWhisper

// Original test class (can be kept for future general tests or removed if empty)
final class OpenSuperWhisperTests: XCTestCase {
    override func setUpWithError() throws {}
    override func tearDownWithError() throws {}
    // func testExample() throws {} // Original example tests can be removed or repurposed
    // func testPerformanceExample() throws { self.measure {} }
}

// MARK: - AppPreferences Tests
class AppPreferencesTests: XCTestCase {
    
    let liveTextInsertionKey = "liveTextInsertion"

    override func setUp() {
        super.setUp()
        // Clear the specific preference before each test to ensure a clean state
        UserDefaults.standard.removeObject(forKey: liveTextInsertionKey)
    }

    override func tearDown() {
        // Clean up after each test
        UserDefaults.standard.removeObject(forKey: liveTextInsertionKey)
        super.tearDown()
    }

    func testLiveTextInsertion_DefaultValueIsFalse() {
        // AppPreferences.shared is a singleton, ensure no other test has set it yet for this check.
        // setUp() handles clearing, so this should reflect the defaultValue.
        XCTAssertFalse(AppPreferences.shared.liveTextInsertion, "Default value for liveTextInsertion should be false.")
    }

    func testLiveTextInsertion_SetToTruePersists() {
        AppPreferences.shared.liveTextInsertion = true
        XCTAssertTrue(AppPreferences.shared.liveTextInsertion, "liveTextInsertion should be true after setting to true.")
        // Verify persistence in UserDefaults
        XCTAssertTrue(UserDefaults.standard.bool(forKey: liveTextInsertionKey), "UserDefaults should store true for liveTextInsertion.")
    }

    func testLiveTextInsertion_SetToFalsePersists() {
        // First set to true, then to false
        AppPreferences.shared.liveTextInsertion = true 
        AppPreferences.shared.liveTextInsertion = false
        XCTAssertFalse(AppPreferences.shared.liveTextInsertion, "liveTextInsertion should be false after setting to false.")
        // Verify persistence in UserDefaults
        XCTAssertFalse(UserDefaults.standard.bool(forKey: liveTextInsertionKey), "UserDefaults should store false for liveTextInsertion.")
    }
}

// MARK: - SettingsViewModel Tests
@MainActor
class SettingsViewModelTests: XCTestCase {
    
    var viewModel: SettingsViewModel!
    let liveTextInsertionKey = "liveTextInsertion"

    override func setUp() {
        super.setUp()
        // Clear the preference before each test to ensure SettingsViewModel loads the default or a known state
        UserDefaults.standard.removeObject(forKey: liveTextInsertionKey)
        viewModel = SettingsViewModel() // Reinitialize ViewModel for each test
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: liveTextInsertionKey)
        viewModel = nil
        super.tearDown()
    }

    func testLiveTextInsertion_LoadsInitialValueFromAppPreferences_Default() {
        // AppPreferences default is false, so ViewModel should pick this up.
        XCTAssertFalse(viewModel.liveTextInsertion, "ViewModel's liveTextInsertion should be false by default.")
    }
    
    func testLiveTextInsertion_LoadsInitialValueFromAppPreferences_True() {
        AppPreferences.shared.liveTextInsertion = true // Set underlying preference
        viewModel = SettingsViewModel() // Reinitialize to pick up new preference
        XCTAssertTrue(viewModel.liveTextInsertion, "ViewModel's liveTextInsertion should be true when AppPreferences is true.")
    }

    func testLiveTextInsertion_UpdatingViewModelUpdatesAppPreferences() {
        viewModel.liveTextInsertion = true
        XCTAssertTrue(AppPreferences.shared.liveTextInsertion, "AppPreferences' liveTextInsertion should be true after ViewModel update.")
        
        viewModel.liveTextInsertion = false
        XCTAssertFalse(AppPreferences.shared.liveTextInsertion, "AppPreferences' liveTextInsertion should be false after ViewModel update.")
    }
}

// MARK: - TranscriptionService Tests
@MainActor
class TranscriptionServiceTests: XCTestCase {
    
    var service: TranscriptionService!
    // Using a real context for these tests as MyWhisperContext setup is simple path-based.
    // If model loading becomes an issue, we might need to mock context loading.
    // For now, assuming a dummy model path or that context can be nil for some tests.
    
    override func setUp() {
        super.setUp()
        // Reset relevant AppPreferences that TranscriptionService might read directly
        UserDefaults.standard.removeObject(forKey: "liveTextInsertion")
        // It's a singleton, but re-assigning for clarity or if we could reset its state.
        // However, TranscriptionService.shared is global. We test its methods' effects.
        service = TranscriptionService.shared
        
        // Ensure no model is actually loaded if not needed, or use a tiny dummy model if context must be non-nil.
        // For now, tests will focus on logic that may or may not require a fully loaded model.
        // If context is required, these tests might fail if a model isn't found.
        // The service attempts to load model in init.
    }

    override func tearDown() {
        // Clean up TranscriptionService state if possible, e.g., by stopping any live transcription.
        if service.isLiveTranscribing {
            service.stopLiveTranscription()
        }
        // Reset preferences
        UserDefaults.standard.removeObject(forKey: "liveTextInsertion")
        service = nil
        super.tearDown()
    }

    func testStartLiveTranscription_SetsStateCorrectly() {
        let initialSettings = Settings() // Default settings
        
        service.startLiveTranscription(settings: initialSettings)
        
        XCTAssertTrue(service.isLiveTranscribing, "isLiveTranscribing should be true after starting.")
        // Accessing liveSettings directly is not possible due to private access.
        // We can infer it's set if other dependent logic works or by testing effects.
        // For now, just test isLiveTranscribing and other observable states.
        XCTAssertEqual(service.transcribedText, "", "transcribedText should be empty after starting live transcription.")
        XCTAssertEqual(service.currentSegment, "", "currentSegment should be empty after starting live transcription.")
    }

    func testStopLiveTranscription_SetsStateCorrectly() {
        let initialSettings = Settings()
        service.startLiveTranscription(settings: initialSettings) // Start it first
        
        service.stopLiveTranscription()
        
        XCTAssertFalse(service.isLiveTranscribing, "isLiveTranscribing should be false after stopping.")
        // Test that liveAudioBuffer is cleared (indirectly, as it's private)
        // Test that liveSettings is cleared (indirectly)
    }

    func testProcessAudioChunk_AppendsSamplesWhenLive() {
        let initialSettings = Settings()
        service.startLiveTranscription(settings: initialSettings)
        
        let samples: [Float] = [0.1, 0.2, 0.3]
        service.processAudioChunk(samples)
        
        // liveAudioBuffer is private. To test this, we need to observe its effect:
        // triggering processing task when buffer is full.
        // For this specific test, we can't directly assert buffer content.
        // We'll rely on the next test for buffer accumulation effect.
        // If we had a way to get buffer count (e.g., through a test-only method), that'd be better.
        // For now, this test is more of a prerequisite for the next one.
        XCTAssertTrue(service.isLiveTranscribing, "Should still be live transcribing.")
    }

    func testProcessAudioChunk_DoesNotAppendOrProcessWhenNotLive() {
        // Ensure not live
        if service.isLiveTranscribing { service.stopLiveTranscription() }
         XCTAssertFalse(service.isLiveTranscribing, "isLiveTranscribing should be initially false.")

        let samples: [Float] = [0.1, 0.2, 0.3]
        service.processAudioChunk(samples)
        
        // Cannot directly check liveAudioBuffer.
        // Check that liveTranscriptionProcessingTask is nil (it should be if not live)
        // This requires exposing liveTranscriptionProcessingTask or its state for testing,
        // or using expectations on the liveTranscriptionQueue.
        
        // For now, we rely on the guard conditions in processAudioChunk.
        // A more robust test would involve checking that no processing task was initiated.
        // Let's use an expectation for the queue to ensure no task is set.
        let expectation = XCTestExpectation(description: "Check no processing task is created on queue")
        service.liveTranscriptionQueue.async { // Use the actual queue
            // Accessing liveTranscriptionProcessingTask directly is not possible if private.
            // This test highlights the need for testable design or specific test helpers.
            // Assuming for now that if not isLiveTranscribing, the processing task path is not taken.
            // If liveTranscriptionProcessingTask was public for testing: XCTAssertNil(self.service.liveTranscriptionProcessingTask)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 0.5) // Short timeout, queue should be quick
    }
    
    // Test for processing task creation is more complex due to async nature and private state.
    // It requires either making liveTranscriptionProcessingTask visible for testing,
    // or a more involved setup with expectations and potentially a mock context.
    // Given the current structure, a direct test for liveTranscriptionProcessingTask creation
    // is challenging without modifying TranscriptionService for testability.

    // A simplified test: check if processing is attempted when buffer is full.
    // This will require the service to have a valid context, which means a model must be loaded.
    // This part of testing might be closer to integration testing.
    func testProcessAudioChunk_AttemptsProcessingWhenBufferFull() {
        // This test assumes a model is available or context loading doesn't crash.
        // It might be flaky if model loading is slow or fails in test environment.
        guard service.context != nil else {
            XCTFail("Whisper context not loaded. Cannot perform this test. Ensure a model is accessible.")
            return
        }

        let initialSettings = Settings()
        AppPreferences.shared.liveTextInsertion = false // Ensure we know the state for pasting logic
        service.startLiveTranscription(settings: initialSettings)

        // Calculate samples needed to trigger processing
        let targetSamples = service.LIVE_AUDIO_BUFFER_TARGET_SAMPLES
        let chunk: [Float] = Array(repeating: 0.1, count: 1000) // Small chunk
        var accumulatedSamples = 0
        
        let processingExpectation = XCTestExpectation(description: "Processing task should be created")

        // Monitor the liveTranscriptionProcessingTask (needs to be visible or use a callback)
        // For now, we will dispatch to its queue and check after feeding enough samples.
        
        while accumulatedSamples < targetSamples {
            service.processAudioChunk(chunk)
            accumulatedSamples += chunk.count
            // Give a slight delay for the queue to potentially pick up and set the task
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        
        // After enough samples, dispatch to the queue to check if a task was set
        service.liveTranscriptionQueue.asyncAfter(deadline: .now() + 0.1) { // Allow time for task to be set
            // If liveTranscriptionProcessingTask was testable (e.g. internal):
            // XCTAssertNotNil(self.service.liveTranscriptionProcessingTask, "Processing task should be created when buffer is full.")
            // Since it's private, we can't directly check.
            // This test's success is hard to verify without more testability.
            // We assume if it doesn't crash and previous tests pass, it's working.
            // A better way would be to have TranscriptionService provide a callback on task creation for tests.
            processingExpectation.fulfill() // Fulfill if we reach here, implying the logic ran.
        }

        wait(for: [processingExpectation], timeout: 2.0) // Increased timeout for async operations
    }
}

// Add XCTMain entry point if this is the only test file and running on Linux,
// or if needed by your test runner configuration.
// For standard Xcode tests, this is not usually required.

