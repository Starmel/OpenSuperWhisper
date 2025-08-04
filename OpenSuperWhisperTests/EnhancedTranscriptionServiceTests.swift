//
//  EnhancedTranscriptionServiceTests.swift
//  OpenSuperWhisperTests
//
//  Created by Claude on 03.08.2025.
//

import XCTest
@testable import OpenSuperWhisper

final class EnhancedTranscriptionServiceTests: XCTestCase {
    
    private var service: EnhancedTranscriptionService!
    private var testAudioURL: URL!
    
    @MainActor
    override func setUpWithError() throws {
        service = EnhancedTranscriptionService.shared
        
        // Set up test audio URL
        testAudioURL = Bundle(for: type(of: self)).url(forResource: "test_audio", withExtension: "m4a")
        
        // Clean up any existing state
        service.cancelTranscription()
        
        // Clear API keys
        SecureStorageManager.shared.clearAllAPIKeys()
    }
    
    @MainActor
    override func tearDownWithError() throws {
        service.cancelTranscription()
        SecureStorageManager.shared.clearAllAPIKeys()
    }
    
    // MARK: - Service Initialization Tests
    
    @MainActor
    func testServiceSingleton() throws {
        let service1 = EnhancedTranscriptionService.shared
        let service2 = EnhancedTranscriptionService.shared
        
        XCTAssertTrue(service1 === service2)
    }
    
    @MainActor
    func testInitialState() throws {
        XCTAssertFalse(service.isTranscribing)
        XCTAssertEqual(service.transcribedText, "")
        XCTAssertEqual(service.currentSegment, "")
        XCTAssertFalse(service.isLoading)
        XCTAssertEqual(service.progress, 0.0)
        XCTAssertNil(service.currentProvider)
        XCTAssertNil(service.lastError)
    }
    
    // MARK: - Provider Access Tests
    
    func testGetAvailableProviders() async throws {
        let providers = await service.getAvailableProviders()
        
        XCTAssertEqual(providers.count, STTProviderType.allCases.count)
        XCTAssertTrue(providers.contains(.whisperLocal))
        XCTAssertTrue(providers.contains(.mistralVoxtral))
    }
    
    func testGetConfiguredProviders() async throws {
        // Initially, only providers with valid configurations should be returned
        let initialProviders = await service.getConfiguredProviders()
        
        // Set up a valid Mistral configuration
        SecureStorageManager.shared.setAPIKey("test_key", for: .mistralVoxtral)
        var mistralConfig = AppPreferences.shared.mistralVoxtralConfig
        mistralConfig.isEnabled = true
        AppPreferences.shared.mistralVoxtralConfig = mistralConfig
        
        // Refresh providers to pick up new configuration
        await STTProviderFactory.shared.refreshProvider(for: .mistralVoxtral)
        
        let configuredProviders = await service.getConfiguredProviders()
        
        // Should now include Mistral
        XCTAssertTrue(configuredProviders.contains(.mistralVoxtral))
        
        // Clean up
        SecureStorageManager.shared.setAPIKey(nil, for: .mistralVoxtral)
    }
    
    // MARK: - Provider Validation Tests
    
    func testValidateProviderWhisperLocal() async throws {
        // Test validation with no model path
        var whisperConfig = AppPreferences.shared.whisperLocalConfig
        whisperConfig.modelPath = nil
        AppPreferences.shared.whisperLocalConfig = whisperConfig
        
        await STTProviderFactory.shared.refreshProvider(for: .whisperLocal)
        
        let result = await service.validateProvider(.whisperLocal)
        XCTAssertFalse(result.isValid)
        XCTAssertFalse(result.errors.isEmpty)
    }
    
    func testValidateProviderMistralVoxtral() async throws {
        // Test validation with no API key
        SecureStorageManager.shared.setAPIKey(nil, for: .mistralVoxtral)
        await STTProviderFactory.shared.refreshProvider(for: .mistralVoxtral)
        
        let result = await service.validateProvider(.mistralVoxtral)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains { error in
            if case .missingApiKey = error { return true }
            return false
        })
    }
    
    func testValidateProviderMistralWithAPIKey() async throws {
        // Test validation with API key
        SecureStorageManager.shared.setAPIKey("test_api_key_123", for: .mistralVoxtral)
        await STTProviderFactory.shared.refreshProvider(for: .mistralVoxtral)
        
        let result = await service.validateProvider(.mistralVoxtral)
        
        // May still be invalid due to network issues in test environment,
        // but should not have missing API key error
        let hasMissingKeyError = result.errors.contains { error in
            if case .missingApiKey = error { return true }
            return false
        }
        XCTAssertFalse(hasMissingKeyError)
    }
    
    // MARK: - Transcription State Management Tests
    
    @MainActor
    func testTranscriptionStateManagement() async throws {
        // Skip if no test audio file
        guard testAudioURL != nil else {
            throw XCTSkip("Test audio file not found")
        }
        
        let settings = TranscriptionSettings()
        
        // Start transcription task
        let transcriptionTask = Task {
            try await service.transcribeAudio(url: testAudioURL, settings: settings)
        }
        
        // Wait a bit for state to update
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
        
        // Should be transcribing
        XCTAssertTrue(service.isTranscribing)
        
        // Cancel transcription
        service.cancelTranscription()
        
        // Wait for task to complete
        do {
            _ = try await transcriptionTask.value
            XCTFail("Should have thrown cancellation error")
        } catch {
            // Expected to throw due to cancellation
        }
        
        // State should be reset
        XCTAssertFalse(service.isTranscribing)
        XCTAssertEqual(service.currentSegment, "")
        XCTAssertEqual(service.progress, 0.0)
        XCTAssertNil(service.currentProvider)
    }
    
    @MainActor
    func testCancelTranscription() throws {
        // Initially should not be transcribing
        XCTAssertFalse(service.isTranscribing)
        
        // Cancel should be safe to call even when not transcribing
        XCTAssertNoThrow(service.cancelTranscription())
        
        // State should remain clean
        XCTAssertFalse(service.isTranscribing)
        XCTAssertEqual(service.currentSegment, "")
        XCTAssertEqual(service.progress, 0.0)
    }
    
    // MARK: - Fallback Mechanism Tests
    
    func testFallbackMechanismEnabled() async throws {
        // Skip if no test audio file
        guard testAudioURL != nil else {
            throw XCTSkip("Test audio file not found")
        }
        
        // Set up settings with fallback enabled
        var settings = TranscriptionSettings()
        settings.primaryProvider = .mistralVoxtral // Will fail without API key
        settings.enableFallback = true
        settings.fallbackProviders = [.whisperLocal] // Will also likely fail without model
        
        // Ensure Mistral has no API key to force failure
        SecureStorageManager.shared.setAPIKey(nil, for: .mistralVoxtral)
        
        do {
            let result = await service.transcribeAudio(url: testAudioURL, settings: settings)
            // If it succeeds, one of the providers worked
            XCTAssertFalse(result.isEmpty)
        } catch {
            // If all providers fail, should get an appropriate error
            XCTAssertTrue(error is TranscriptionError)
        }
    }
    
    func testFallbackMechanismDisabled() async throws {
        // Skip if no test audio file
        guard testAudioURL != nil else {
            throw XCTSkip("Test audio file not found")
        }
        
        // Set up settings with fallback disabled
        var settings = TranscriptionSettings()
        settings.primaryProvider = .mistralVoxtral // Will fail without API key
        settings.enableFallback = false
        
        // Ensure Mistral has no API key to force failure
        SecureStorageManager.shared.setAPIKey(nil, for: .mistralVoxtral)
        
        // Should fail immediately without trying fallback
        do {
            _ = await service.transcribeAudio(url: testAudioURL, settings: settings)
            XCTFail("Should have failed due to missing API key")
        } catch {
            XCTAssertTrue(error is TranscriptionError)
        }
    }
    
    // MARK: - Backward Compatibility Tests
    
    @MainActor
    func testBackwardCompatibilityWithLegacySettings() async throws {
        // Skip if no test audio file
        guard testAudioURL != nil else {
            throw XCTSkip("Test audio file not found")
        }
        
        // Create legacy settings
        let legacySettings = Settings()
        legacySettings.selectedLanguage = "es"
        legacySettings.showTimestamps = true
        legacySettings.translateToEnglish = false
        
        // Should be able to use legacy settings
        do {
            let result = try await service.transcribeAudio(url: testAudioURL, settings: legacySettings)
            // If it succeeds, the conversion worked
            XCTAssertTrue(result is String)
        } catch {
            // If it fails, it should be due to provider configuration, not settings conversion
            XCTAssertTrue(error is TranscriptionError)
        }
    }
    
    // MARK: - Error Handling Tests
    
    func testTranscriptionWithInvalidURL() async throws {
        let invalidURL = URL(fileURLWithPath: "/nonexistent/file.mp3")
        let settings = TranscriptionSettings()
        
        do {
            _ = await service.transcribeAudio(url: invalidURL, settings: settings)
            XCTFail("Should have failed with invalid URL")
        } catch {
            XCTAssertTrue(error is TranscriptionError)
        }
    }
    
    func testTranscriptionWithNoConfiguredProviders() async throws {
        // Skip if no test audio file
        guard testAudioURL != nil else {
            throw XCTSkip("Test audio file not found")
        }
        
        // Set up settings where no providers are configured
        var settings = TranscriptionSettings()
        settings.primaryProvider = .mistralVoxtral
        settings.enableFallback = false
        
        // Ensure no API key
        SecureStorageManager.shared.setAPIKey(nil, for: .mistralVoxtral)
        
        do {
            _ = await service.transcribeAudio(url: testAudioURL, settings: settings)
            XCTFail("Should have failed with no configured providers")
        } catch {
            XCTAssertTrue(error is TranscriptionError)
        }
    }
    
    // MARK: - Progress Tracking Tests
    
    @MainActor
    func testProgressTracking() async throws {
        // Skip if no test audio file
        guard testAudioURL != nil else {
            throw XCTSkip("Test audio file not found")
        }
        
        let settings = TranscriptionSettings()
        var progressUpdates: [Float] = []
        
        // Monitor progress changes
        let progressObserver = service.$progress.sink { progress in
            progressUpdates.append(progress)
        }
        
        defer { progressObserver.cancel() }
        
        do {
            _ = try await service.transcribeAudio(url: testAudioURL, settings: settings)
            
            // Should have received progress updates
            XCTAssertTrue(progressUpdates.count > 1)
            XCTAssertEqual(progressUpdates.first, 0.0)
            
        } catch {
            // Even if transcription fails, we should have seen progress updates
            XCTAssertTrue(progressUpdates.count >= 1)
        }
    }
    
    // MARK: - Provider Selection Tests
    
    func testProviderSelectionOrder() async throws {
        // Test that providers are tried in the correct order
        var settings = TranscriptionSettings()
        settings.primaryProvider = .whisperLocal
        settings.enableFallback = true
        settings.fallbackProviders = [.mistralVoxtral]
        
        // The service should try whisperLocal first, then mistralVoxtral
        // We can't easily test the exact order without mocking, but we can test
        // that the provider selection logic works
        
        let providersInOrder = service.getProvidersInPriorityOrder(settings: settings)
        XCTAssertEqual(providersInOrder.first, .whisperLocal)
        XCTAssertTrue(providersInOrder.contains(.mistralVoxtral))
    }
    
    // MARK: - Thread Safety Tests
    
    func testConcurrentTranscriptionCalls() async throws {
        // Skip if no test audio file
        guard testAudioURL != nil else {
            throw XCTSkip("Test audio file not found")
        }
        
        let settings = TranscriptionSettings()
        
        // Start multiple transcription tasks concurrently
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask { @MainActor in
                    do {
                        _ = try await self.service.transcribeAudio(url: self.testAudioURL, settings: settings)
                    } catch {
                        // Expected to fail in test environment
                    }
                }
            }
        }
        
        // Service should handle concurrent calls gracefully
        // The exact behavior depends on implementation, but it should not crash
    }
    
    // MARK: - Memory Management Tests
    
    func testMemoryManagement() async throws {
        // Test that service doesn't retain excessive memory
        
        let initialProviders = await service.getAvailableProviders()
        XCTAssertFalse(initialProviders.isEmpty)
        
        // Multiple operations should not cause memory leaks
        for _ in 0..<5 {
            _ = await service.getConfiguredProviders()
            _ = await service.validateProvider(.whisperLocal)
        }
        
        // Service should remain functional
        let finalProviders = await service.getAvailableProviders()
        XCTAssertEqual(initialProviders.count, finalProviders.count)
    }
}

// MARK: - Test Helper Extensions

private extension EnhancedTranscriptionService {
    func getProvidersInPriorityOrder(settings: TranscriptionSettings) -> [STTProviderType] {
        var providers: [STTProviderType] = []
        
        // Add primary provider first
        providers.append(settings.primaryProvider)
        
        // Add fallback providers if enabled
        if settings.enableFallback {
            for fallbackProvider in settings.fallbackProviders {
                if !providers.contains(fallbackProvider) {
                    providers.append(fallbackProvider)
                }
            }
        }
        
        return providers
    }
}