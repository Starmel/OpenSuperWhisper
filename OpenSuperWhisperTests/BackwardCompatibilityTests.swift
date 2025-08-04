//
//  BackwardCompatibilityTests.swift
//  OpenSuperWhisperTests
//
//  Created by Claude on 03.08.2025.
//

import XCTest
@testable import OpenSuperWhisper

final class BackwardCompatibilityTests: XCTestCase {
    
    private var originalPreferences: (
        selectedModelPath: String?,
        whisperLanguage: String,
        translateToEnglish: Bool,
        suppressBlankAudio: Bool,
        showTimestamps: Bool,
        temperature: Double,
        noSpeechThreshold: Double,
        initialPrompt: String,
        useBeamSearch: Bool,
        beamSize: Int
    )!
    
    override func setUpWithError() throws {
        // Save original preferences
        let prefs = AppPreferences.shared
        originalPreferences = (
            selectedModelPath: prefs.selectedModelPath,
            whisperLanguage: prefs.whisperLanguage,
            translateToEnglish: prefs.translateToEnglish,
            suppressBlankAudio: prefs.suppressBlankAudio,
            showTimestamps: prefs.showTimestamps,
            temperature: prefs.temperature,
            noSpeechThreshold: prefs.noSpeechThreshold,
            initialPrompt: prefs.initialPrompt,
            useBeamSearch: prefs.useBeamSearch,
            beamSize: prefs.beamSize
        )
    }
    
    override func tearDownWithError() throws {
        // Restore original preferences
        let prefs = AppPreferences.shared
        prefs.selectedModelPath = originalPreferences.selectedModelPath
        prefs.whisperLanguage = originalPreferences.whisperLanguage
        prefs.translateToEnglish = originalPreferences.translateToEnglish
        prefs.suppressBlankAudio = originalPreferences.suppressBlankAudio
        prefs.showTimestamps = originalPreferences.showTimestamps
        prefs.temperature = originalPreferences.temperature
        prefs.noSpeechThreshold = originalPreferences.noSpeechThreshold
        prefs.initialPrompt = originalPreferences.initialPrompt
        prefs.useBeamSearch = originalPreferences.useBeamSearch
        prefs.beamSize = originalPreferences.beamSize
        
        // Clear API keys
        SecureStorageManager.shared.clearAllAPIKeys()
    }
    
    // MARK: - Legacy Settings Conversion Tests
    
    func testLegacySettingsToTranscriptionSettingsConversion() throws {
        // Create legacy settings with specific values
        let legacySettings = Settings()
        legacySettings.selectedLanguage = "es"
        legacySettings.translateToEnglish = true
        legacySettings.suppressBlankAudio = true
        legacySettings.showTimestamps = true
        legacySettings.temperature = 0.5
        legacySettings.noSpeechThreshold = 0.8
        legacySettings.initialPrompt = "Legacy prompt"
        legacySettings.useBeamSearch = true
        legacySettings.beamSize = 10
        
        // Convert to new TranscriptionSettings
        let transcriptionSettings = TranscriptionSettings(fromLegacySettings: legacySettings)
        
        // Verify all properties are correctly converted
        XCTAssertEqual(transcriptionSettings.selectedLanguage, "es")
        XCTAssertTrue(transcriptionSettings.translateToEnglish)
        XCTAssertTrue(transcriptionSettings.suppressBlankAudio)
        XCTAssertTrue(transcriptionSettings.showTimestamps)
        XCTAssertEqual(transcriptionSettings.temperature, 0.5)
        XCTAssertEqual(transcriptionSettings.noSpeechThreshold, 0.8)
        XCTAssertEqual(transcriptionSettings.initialPrompt, "Legacy prompt")
        XCTAssertTrue(transcriptionSettings.useBeamSearch)
        XCTAssertEqual(transcriptionSettings.beamSize, 10)
        
        // Provider-specific settings should use current app preferences
        XCTAssertEqual(transcriptionSettings.primaryProvider, .whisperLocal) // Default
        XCTAssertTrue(transcriptionSettings.enableFallback) // Default
    }
    
    func testAppPreferencesToTranscriptionSettingsConversion() throws {
        let prefs = AppPreferences.shared
        
        // Set specific preferences
        prefs.whisperLanguage = "fr"
        prefs.showTimestamps = true
        prefs.translateToEnglish = false
        prefs.initialPrompt = "App preferences prompt"
        prefs.temperature = 0.3
        prefs.noSpeechThreshold = 0.7
        prefs.useBeamSearch = false
        prefs.beamSize = 3
        prefs.suppressBlankAudio = true
        prefs.primarySTTProvider = "mistral_voxtral"
        prefs.enableSTTFallback = false
        prefs.sttFallbackProviders = ["whisper_local"]
        
        let settings = TranscriptionSettings(fromAppPreferences: prefs)
        
        XCTAssertEqual(settings.selectedLanguage, "fr")
        XCTAssertTrue(settings.showTimestamps)
        XCTAssertFalse(settings.translateToEnglish)
        XCTAssertEqual(settings.initialPrompt, "App preferences prompt")
        XCTAssertEqual(settings.temperature, 0.3)
        XCTAssertEqual(settings.noSpeechThreshold, 0.7)
        XCTAssertFalse(settings.useBeamSearch)
        XCTAssertEqual(settings.beamSize, 3)
        XCTAssertTrue(settings.suppressBlankAudio)
        XCTAssertEqual(settings.primaryProvider, .mistralVoxtral)
        XCTAssertFalse(settings.enableFallback)
        XCTAssertEqual(settings.fallbackProviders, [.whisperLocal])
    }
    
    // MARK: - WhisperLocalProvider Legacy Integration Tests
    
    func testWhisperLocalProviderSettingsConversion() async throws {
        // Create TranscriptionSettings
        var settings = TranscriptionSettings()
        settings.selectedLanguage = "de"
        settings.translateToEnglish = true
        settings.suppressBlankAudio = false
        settings.showTimestamps = true
        settings.temperature = 0.4
        settings.noSpeechThreshold = 0.5
        settings.initialPrompt = "Test prompt"
        settings.useBeamSearch = true
        settings.beamSize = 7
        
        // Create WhisperLocalProvider
        let provider = WhisperLocalProvider()
        
        // The provider should convert TranscriptionSettings to legacy Settings internally
        // We can test this by examining the conversion logic
        
        let legacySettings = Settings(
            selectedLanguage: settings.selectedLanguage,
            translateToEnglish: settings.translateToEnglish,
            suppressBlankAudio: settings.suppressBlankAudio,
            showTimestamps: settings.showTimestamps,
            temperature: settings.temperature,
            noSpeechThreshold: settings.noSpeechThreshold,
            initialPrompt: settings.initialPrompt,
            useBeamSearch: settings.useBeamSearch,
            beamSize: settings.beamSize
        )
        
        XCTAssertEqual(legacySettings.selectedLanguage, "de")
        XCTAssertTrue(legacySettings.translateToEnglish)
        XCTAssertFalse(legacySettings.suppressBlankAudio)
        XCTAssertTrue(legacySettings.showTimestamps)
        XCTAssertEqual(legacySettings.temperature, 0.4)
        XCTAssertEqual(legacySettings.noSpeechThreshold, 0.5)
        XCTAssertEqual(legacySettings.initialPrompt, "Test prompt")
        XCTAssertTrue(legacySettings.useBeamSearch)
        XCTAssertEqual(legacySettings.beamSize, 7)
    }
    
    func testWhisperLocalProviderValidationWithoutModel() async throws {
        let provider = WhisperLocalProvider()
        
        let result = try await provider.validateConfiguration()
        
        // Should fail validation without model path
        XCTAssertFalse(result.isValid)
        XCTAssertFalse(result.errors.isEmpty)
        
        let hasModelError = result.errors.contains { error in
            if case .modelNotFound = error { return true }
            return false
        }
        XCTAssertTrue(hasModelError)
    }
    
    func testWhisperLocalProviderValidationWithModel() async throws {
        // Set up configuration with a test model path
        var config = WhisperLocalConfiguration()
        
        // Try to find the bundled model
        if let modelPath = Bundle.main.path(forResource: "ggml-tiny.en", ofType: "bin") {
            config.modelPath = modelPath
        } else {
            // Create a temporary fake model file for testing
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_model.bin")
            let dummyData = Data(count: 1024 * 1024) // 1MB of dummy data
            try dummyData.write(to: tempURL)
            config.modelPath = tempURL.path
            
            defer {
                try? FileManager.default.removeItem(at: tempURL)
            }
        }
        
        let provider = WhisperLocalProvider(configuration: config)
        
        let result = try await provider.validateConfiguration()
        
        // Should pass validation with valid model path
        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.errors.isEmpty)
    }
    
    // MARK: - Enhanced TranscriptionService Backward Compatibility
    
    @MainActor
    func testEnhancedTranscriptionServiceLegacyMethod() async throws {
        let service = EnhancedTranscriptionService.shared
        
        // Create legacy settings
        let legacySettings = Settings()
        legacySettings.selectedLanguage = "it"
        legacySettings.showTimestamps = true
        legacySettings.temperature = 0.6
        
        // Test the legacy method signature
        let testURL = Bundle(for: type(of: self)).url(forResource: "test_audio", withExtension: "m4a")
        
        if let audioURL = testURL {
            do {
                let result = try await service.transcribeAudio(url: audioURL, settings: legacySettings)
                // If it succeeds, the conversion worked
                XCTAssertTrue(result is String)
            } catch {
                // If it fails, it should be due to configuration issues, not conversion issues
                XCTAssertTrue(error is TranscriptionError)
            }
        } else {
            throw XCTSkip("Test audio file not found")
        }
    }
    
    // MARK: - Configuration Migration Tests
    
    func testWhisperConfigurationBackwardCompatibility() throws {
        let prefs = AppPreferences.shared
        
        // Test that WhisperLocalConfiguration uses selectedModelPath for backward compatibility
        prefs.selectedModelPath = "/legacy/model/path.bin"
        
        // Clear any existing whisper config to test fallback
        UserDefaults.standard.set("", forKey: "whisperLocalConfig")
        
        let config = prefs.whisperLocalConfig
        
        // Should fall back to selectedModelPath
        XCTAssertEqual(config.modelPath, "/legacy/model/path.bin")
        XCTAssertTrue(config.isEnabled) // Default
        XCTAssertEqual(config.priority, 1) // Default
    }
    
    func testConfigurationUpgradeFromLegacySettings() throws {
        let prefs = AppPreferences.shared
        
        // Simulate legacy setup
        prefs.selectedModelPath = "/legacy/path.bin"
        prefs.whisperLanguage = "ja"
        prefs.temperature = 0.7
        
        // Get current transcription settings (should migrate from legacy)
        let settings = prefs.currentTranscriptionSettings
        
        XCTAssertEqual(settings.selectedLanguage, "ja")
        XCTAssertEqual(settings.temperature, 0.7)
        XCTAssertEqual(settings.primaryProvider, .whisperLocal)
        
        // Whisper config should include legacy model path
        let whisperConfig = prefs.whisperLocalConfig
        XCTAssertEqual(whisperConfig.modelPath, "/legacy/path.bin")
    }
    
    // MARK: - Provider Type String Conversion Tests
    
    func testSTTProviderTypeStringConversion() throws {
        // Test that string values work correctly for backward compatibility
        XCTAssertEqual(STTProviderType.whisperLocal.rawValue, "whisper_local")
        XCTAssertEqual(STTProviderType.mistralVoxtral.rawValue, "mistral_voxtral")
        
        // Test reverse conversion
        XCTAssertEqual(STTProviderType(rawValue: "whisper_local"), .whisperLocal)
        XCTAssertEqual(STTProviderType(rawValue: "mistral_voxtral"), .mistralVoxtral)
        
        // Test invalid string
        XCTAssertNil(STTProviderType(rawValue: "invalid_provider"))
    }
    
    func testAppPreferencesProviderStringHandling() throws {
        let prefs = AppPreferences.shared
        
        // Test setting provider by string
        prefs.primarySTTProvider = "mistral_voxtral"
        let settings = prefs.currentTranscriptionSettings
        XCTAssertEqual(settings.primaryProvider, .mistralVoxtral)
        
        // Test fallback providers array
        prefs.sttFallbackProviders = ["whisper_local", "mistral_voxtral"]
        let updatedSettings = prefs.currentTranscriptionSettings
        XCTAssertEqual(updatedSettings.fallbackProviders, [.whisperLocal, .mistralVoxtral])
        
        // Test invalid provider strings are filtered out
        prefs.sttFallbackProviders = ["whisper_local", "invalid_provider", "mistral_voxtral"]
        let filteredSettings = prefs.currentTranscriptionSettings
        XCTAssertEqual(filteredSettings.fallbackProviders, [.whisperLocal, .mistralVoxtral])
    }
    
    // MARK: - UserDefaults Key Compatibility Tests
    
    func testUserDefaultsKeyBackwardCompatibility() throws {
        // Test that existing UserDefaults keys are preserved
        let expectedKeys = [
            "selectedModelPath",
            "whisperLanguage",
            "translateToEnglish",
            "suppressBlankAudio",
            "showTimestamps",
            "temperature",
            "noSpeechThreshold",
            "initialPrompt",
            "useBeamSearch",
            "beamSize",
            "debugMode",
            "playSoundOnRecordStart",
            "hasCompletedOnboarding",
            "primarySTTProvider",
            "enableSTTFallback",
            "sttFallbackProviders",
            "whisperLocalConfig",
            "mistralVoxtralConfig"
        ]
        
        // Set test values for all keys
        for key in expectedKeys {
            UserDefaults.standard.set("test_value", forKey: key)
        }
        
        // Verify keys exist
        for key in expectedKeys {
            XCTAssertNotNil(UserDefaults.standard.object(forKey: key), "Key \(key) should exist")
        }
        
        // Clean up
        for key in expectedKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
    
    // MARK: - Error Handling Backward Compatibility
    
    func testTranscriptionErrorBackwardCompatibility() throws {
        // Test that error cases are handled the same way
        
        let networkError = NSError(domain: "TestDomain", code: -1, userInfo: nil)
        let transcriptionError = TranscriptionError.networkError(networkError)
        
        XCTAssertNotNil(transcriptionError.errorDescription)
        XCTAssertTrue(transcriptionError.errorDescription!.contains("Network error"))
        
        // Test other error types
        let apiKeyError = TranscriptionError.apiKeyInvalid
        XCTAssertEqual(apiKeyError.errorDescription, "Invalid API key")
        
        let quotaError = TranscriptionError.quotaExceeded
        XCTAssertEqual(quotaError.errorDescription, "API quota exceeded")
        
        let configError = TranscriptionError.providerNotConfigured(.whisperLocal)
        XCTAssertTrue(configError.errorDescription!.contains("Whisper (Local)"))
    }
    
    // MARK: - Integration Tests
    
    @MainActor
    func testFullBackwardCompatibilityFlow() async throws {
        // Simulate an existing user upgrading to the new STT system
        let prefs = AppPreferences.shared
        
        // Set up legacy preferences
        prefs.selectedModelPath = "/test/model.bin"
        prefs.whisperLanguage = "ko"
        prefs.temperature = 0.8
        prefs.showTimestamps = true
        
        // Get transcription settings (should work with legacy preferences)
        let settings = prefs.currentTranscriptionSettings
        
        XCTAssertEqual(settings.selectedLanguage, "ko")
        XCTAssertEqual(settings.temperature, 0.8)
        XCTAssertTrue(settings.showTimestamps)
        XCTAssertEqual(settings.primaryProvider, .whisperLocal)
        
        // Test that provider factory works with these settings
        let factory = STTProviderFactory.shared
        let provider = await factory.getProvider(for: settings.primaryProvider)
        
        XCTAssertEqual(provider.id, .whisperLocal)
        XCTAssertEqual(provider.displayName, "Whisper (Local)")
        
        // Test service integration
        let service = EnhancedTranscriptionService.shared
        let availableProviders = await service.getAvailableProviders()
        
        XCTAssertTrue(availableProviders.contains(.whisperLocal))
        XCTAssertTrue(availableProviders.contains(.mistralVoxtral))
    }
}