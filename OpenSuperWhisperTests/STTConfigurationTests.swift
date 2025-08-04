//
//  STTConfigurationTests.swift
//  OpenSuperWhisperTests
//
//  Created by Claude on 03.08.2025.
//

import XCTest
@testable import OpenSuperWhisper

final class STTConfigurationTests: XCTestCase {
    
    override func setUpWithError() throws {
        // Clear any existing API keys
        SecureStorageManager.shared.clearAllAPIKeys()
    }
    
    override func tearDownWithError() throws {
        // Clean up API keys
        SecureStorageManager.shared.clearAllAPIKeys()
    }
    
    // MARK: - WhisperLocalConfiguration Tests
    
    func testWhisperLocalConfigurationDefaults() throws {
        let config = WhisperLocalConfiguration()
        
        XCTAssertTrue(config.isEnabled)
        XCTAssertEqual(config.priority, 1)
        XCTAssertNil(config.modelPath)
        XCTAssertTrue(config.useGPUAcceleration)
        XCTAssertEqual(config.maxThreads, 4)
    }
    
    func testWhisperLocalConfigurationInitialization() throws {
        let modelPath = "/test/path/model.bin"
        let config = WhisperLocalConfiguration(
            modelPath: modelPath,
            useGPUAcceleration: false,
            maxThreads: 8
        )
        
        XCTAssertTrue(config.isEnabled)
        XCTAssertEqual(config.priority, 1)
        XCTAssertEqual(config.modelPath, modelPath)
        XCTAssertFalse(config.useGPUAcceleration)
        XCTAssertEqual(config.maxThreads, 8)
    }
    
    func testWhisperLocalConfigurationSerialization() throws {
        let config = WhisperLocalConfiguration(
            modelPath: "/test/model.bin",
            useGPUAcceleration: false,
            maxThreads: 6
        )
        
        // Encode to JSON
        let encoder = JSONEncoder()
        let data = try encoder.encode(config)
        
        // Decode from JSON
        let decoder = JSONDecoder()
        let decodedConfig = try decoder.decode(WhisperLocalConfiguration.self, from: data)
        
        // Verify all properties are preserved
        XCTAssertEqual(config.isEnabled, decodedConfig.isEnabled)
        XCTAssertEqual(config.priority, decodedConfig.priority)
        XCTAssertEqual(config.modelPath, decodedConfig.modelPath)
        XCTAssertEqual(config.useGPUAcceleration, decodedConfig.useGPUAcceleration)
        XCTAssertEqual(config.maxThreads, decodedConfig.maxThreads)
    }
    
    // MARK: - MistralVoxtralConfiguration Tests
    
    func testMistralVoxtralConfigurationDefaults() throws {
        let config = MistralVoxtralConfiguration()
        
        XCTAssertFalse(config.isEnabled)
        XCTAssertEqual(config.priority, 2)
        XCTAssertEqual(config.endpoint, "https://api.mistral.ai/v1/audio/transcriptions")
        XCTAssertEqual(config.maxRetries, 3)
        XCTAssertEqual(config.timeoutInterval, 60.0)
        XCTAssertEqual(config.model, "voxtral-mini-latest")
        XCTAssertEqual(config.maxFileSizeMB, 25)
        XCTAssertFalse(config.hasValidAPIKey)
        XCTAssertNil(config.apiKey)
    }
    
    func testMistralVoxtralConfigurationInitialization() throws {
        let endpoint = "https://custom.api.endpoint.com/v1/transcriptions"
        let model = "custom-model"
        let config = MistralVoxtralConfiguration(
            endpoint: endpoint,
            model: model,
            maxRetries: 5,
            timeoutInterval: 120.0
        )
        
        XCTAssertFalse(config.isEnabled)
        XCTAssertEqual(config.priority, 2)
        XCTAssertEqual(config.endpoint, endpoint)
        XCTAssertEqual(config.model, model)
        XCTAssertEqual(config.maxRetries, 5)
        XCTAssertEqual(config.timeoutInterval, 120.0)
        XCTAssertEqual(config.maxFileSizeMB, 25)
    }
    
    func testMistralVoxtralConfigurationAPIKeyIntegration() throws {
        var config = MistralVoxtralConfiguration()
        let testKey = "test_api_key_123"
        
        // Initially no API key
        XCTAssertFalse(config.hasValidAPIKey)
        XCTAssertNil(config.apiKey)
        
        // Set API key
        config.apiKey = testKey
        XCTAssertTrue(config.hasValidAPIKey)
        XCTAssertEqual(config.apiKey, testKey)
        
        // Clear API key
        config.apiKey = nil
        XCTAssertFalse(config.hasValidAPIKey)
        XCTAssertNil(config.apiKey)
    }
    
    func testMistralVoxtralConfigurationSerialization() throws {
        let config = MistralVoxtralConfiguration(
            endpoint: "https://test.endpoint.com",
            model: "test-model",
            maxRetries: 2,
            timeoutInterval: 30.0
        )
        
        // Encode to JSON
        let encoder = JSONEncoder()
        let data = try encoder.encode(config)
        
        // Decode from JSON
        let decoder = JSONDecoder()
        let decodedConfig = try decoder.decode(MistralVoxtralConfiguration.self, from: data)
        
        // Verify all properties are preserved (except API key which is not serialized)
        XCTAssertEqual(config.isEnabled, decodedConfig.isEnabled)
        XCTAssertEqual(config.priority, decodedConfig.priority)
        XCTAssertEqual(config.endpoint, decodedConfig.endpoint)
        XCTAssertEqual(config.model, decodedConfig.model)
        XCTAssertEqual(config.maxRetries, decodedConfig.maxRetries)
        XCTAssertEqual(config.timeoutInterval, decodedConfig.timeoutInterval)
        XCTAssertEqual(config.maxFileSizeMB, decodedConfig.maxFileSizeMB)
    }
    
    func testMistralVoxtralConfigurationAPIKeyNotSerialized() throws {
        var config = MistralVoxtralConfiguration()
        config.apiKey = "sensitive_key_should_not_be_serialized"
        
        // Encode to JSON
        let encoder = JSONEncoder()
        let data = try encoder.encode(config)
        let jsonString = String(data: data, encoding: .utf8)!
        
        // API key should not appear in serialized JSON
        XCTAssertFalse(jsonString.contains("sensitive_key_should_not_be_serialized"))
        
        // Decode from JSON
        let decoder = JSONDecoder()
        let decodedConfig = try decoder.decode(MistralVoxtralConfiguration.self, from: data)
        
        // API key should still be accessible through secure storage
        XCTAssertEqual(decodedConfig.apiKey, "sensitive_key_should_not_be_serialized")
    }
    
    // MARK: - TranscriptionSettings Tests
    
    func testTranscriptionSettingsDefaults() throws {
        let settings = TranscriptionSettings()
        
        XCTAssertEqual(settings.selectedLanguage, "auto")
        XCTAssertFalse(settings.showTimestamps)
        XCTAssertFalse(settings.translateToEnglish)
        XCTAssertEqual(settings.initialPrompt, "")
        XCTAssertEqual(settings.primaryProvider, .whisperLocal)
        XCTAssertTrue(settings.enableFallback)
        XCTAssertEqual(settings.fallbackProviders, [.mistralVoxtral])
        XCTAssertEqual(settings.temperature, 0.0)
        XCTAssertEqual(settings.noSpeechThreshold, 0.6)
        XCTAssertFalse(settings.useBeamSearch)
        XCTAssertEqual(settings.beamSize, 5)
        XCTAssertFalse(settings.suppressBlankAudio)
    }
    
    func testTranscriptionSettingsFromAppPreferences() throws {
        let prefs = AppPreferences.shared
        
        // Set up test preferences
        prefs.whisperLanguage = "es"
        prefs.showTimestamps = true
        prefs.translateToEnglish = true
        prefs.initialPrompt = "Test prompt"
        prefs.temperature = 0.5
        prefs.primarySTTProvider = "mistral_voxtral"
        prefs.enableSTTFallback = false
        
        let settings = TranscriptionSettings(fromAppPreferences: prefs)
        
        XCTAssertEqual(settings.selectedLanguage, "es")
        XCTAssertTrue(settings.showTimestamps)
        XCTAssertTrue(settings.translateToEnglish)
        XCTAssertEqual(settings.initialPrompt, "Test prompt")
        XCTAssertEqual(settings.temperature, 0.5)
        XCTAssertEqual(settings.primaryProvider, .mistralVoxtral)
        XCTAssertFalse(settings.enableFallback)
    }
    
    func testTranscriptionSettingsFromLegacySettings() throws {
        let legacySettings = Settings()
        legacySettings.selectedLanguage = "fr"
        legacySettings.showTimestamps = true
        legacySettings.translateToEnglish = false
        legacySettings.initialPrompt = "Legacy prompt"
        legacySettings.temperature = 0.3
        legacySettings.useBeamSearch = true
        legacySettings.beamSize = 10
        
        let transcriptionSettings = TranscriptionSettings(fromLegacySettings: legacySettings)
        
        XCTAssertEqual(transcriptionSettings.selectedLanguage, "fr")
        XCTAssertTrue(transcriptionSettings.showTimestamps)
        XCTAssertFalse(transcriptionSettings.translateToEnglish)
        XCTAssertEqual(transcriptionSettings.initialPrompt, "Legacy prompt")
        XCTAssertEqual(transcriptionSettings.temperature, 0.3)
        XCTAssertTrue(transcriptionSettings.useBeamSearch)
        XCTAssertEqual(transcriptionSettings.beamSize, 10)
    }
    
    // MARK: - AppPreferences Integration Tests
    
    func testAppPreferencesWhisperConfigPersistence() throws {
        let prefs = AppPreferences.shared
        let originalConfig = prefs.whisperLocalConfig
        
        // Create new configuration
        var newConfig = WhisperLocalConfiguration()
        newConfig.modelPath = "/test/new/path.bin"
        newConfig.useGPUAcceleration = false
        newConfig.maxThreads = 8
        
        // Set configuration
        prefs.whisperLocalConfig = newConfig
        
        // Retrieve configuration
        let retrievedConfig = prefs.whisperLocalConfig
        
        XCTAssertEqual(retrievedConfig.modelPath, "/test/new/path.bin")
        XCTAssertFalse(retrievedConfig.useGPUAcceleration)
        XCTAssertEqual(retrievedConfig.maxThreads, 8)
        
        // Restore original
        prefs.whisperLocalConfig = originalConfig
    }
    
    func testAppPreferencesMistralConfigPersistence() throws {
        let prefs = AppPreferences.shared
        let originalConfig = prefs.mistralVoxtralConfig
        
        // Create new configuration
        var newConfig = MistralVoxtralConfiguration()
        newConfig.endpoint = "https://test.custom.endpoint.com"
        newConfig.model = "custom-test-model"
        newConfig.maxRetries = 5
        newConfig.timeoutInterval = 120.0
        
        // Set configuration
        prefs.mistralVoxtralConfig = newConfig
        
        // Retrieve configuration
        let retrievedConfig = prefs.mistralVoxtralConfig
        
        XCTAssertEqual(retrievedConfig.endpoint, "https://test.custom.endpoint.com")
        XCTAssertEqual(retrievedConfig.model, "custom-test-model")
        XCTAssertEqual(retrievedConfig.maxRetries, 5)
        XCTAssertEqual(retrievedConfig.timeoutInterval, 120.0)
        
        // Restore original
        prefs.mistralVoxtralConfig = originalConfig
    }
    
    func testAppPreferencesGetConfiguration() throws {
        let prefs = AppPreferences.shared
        
        // Test getting Whisper configuration
        let whisperConfig = prefs.getConfiguration(for: .whisperLocal)
        XCTAssertTrue(whisperConfig is WhisperLocalConfiguration)
        
        // Test getting Mistral configuration
        let mistralConfig = prefs.getConfiguration(for: .mistralVoxtral)
        XCTAssertTrue(mistralConfig is MistralVoxtralConfiguration)
    }
    
    func testAppPreferencesSetConfiguration() throws {
        let prefs = AppPreferences.shared
        let originalWhisperConfig = prefs.whisperLocalConfig
        let originalMistralConfig = prefs.mistralVoxtralConfig
        
        // Create new configurations
        var newWhisperConfig = WhisperLocalConfiguration()
        newWhisperConfig.modelPath = "/test/set/path.bin"
        
        var newMistralConfig = MistralVoxtralConfiguration()
        newMistralConfig.endpoint = "https://test.set.endpoint.com"
        
        // Set configurations
        prefs.setConfiguration(newWhisperConfig, for: .whisperLocal)
        prefs.setConfiguration(newMistralConfig, for: .mistralVoxtral)
        
        // Verify they were set
        let retrievedWhisperConfig = prefs.whisperLocalConfig
        let retrievedMistralConfig = prefs.mistralVoxtralConfig
        
        XCTAssertEqual(retrievedWhisperConfig.modelPath, "/test/set/path.bin")
        XCTAssertEqual(retrievedMistralConfig.endpoint, "https://test.set.endpoint.com")
        
        // Restore originals
        prefs.whisperLocalConfig = originalWhisperConfig
        prefs.mistralVoxtralConfig = originalMistralConfig
    }
    
    // MARK: - Edge Cases and Error Handling
    
    func testConfigurationWithInvalidJSON() throws {
        let prefs = AppPreferences.shared
        
        // Set invalid JSON directly in UserDefaults
        UserDefaults.standard.set("invalid_json_string", forKey: "whisperLocalConfig")
        
        // Should return default configuration on invalid JSON
        let config = prefs.whisperLocalConfig
        XCTAssertTrue(config.isEnabled)
        XCTAssertEqual(config.priority, 1)
        // Should use selectedModelPath for backward compatibility
        XCTAssertEqual(config.modelPath, prefs.selectedModelPath)
    }
    
    func testConfigurationWithEmptyJSON() throws {
        let prefs = AppPreferences.shared
        
        // Set empty string
        UserDefaults.standard.set("", forKey: "mistralVoxtralConfig")
        
        // Should return default configuration
        let config = prefs.mistralVoxtralConfig
        XCTAssertFalse(config.isEnabled)
        XCTAssertEqual(config.priority, 2)
        XCTAssertEqual(config.endpoint, "https://api.mistral.ai/v1/audio/transcriptions")
    }
    
    func testCurrentTranscriptionSettings() throws {
        let prefs = AppPreferences.shared
        
        // Modify some preferences
        prefs.whisperLanguage = "de"
        prefs.showTimestamps = true
        prefs.primarySTTProvider = "mistral_voxtral"
        
        let settings = prefs.currentTranscriptionSettings
        
        XCTAssertEqual(settings.selectedLanguage, "de")
        XCTAssertTrue(settings.showTimestamps)
        XCTAssertEqual(settings.primaryProvider, .mistralVoxtral)
    }
}