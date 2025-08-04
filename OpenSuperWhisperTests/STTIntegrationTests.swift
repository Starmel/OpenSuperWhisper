import XCTest
@testable import OpenSuperWhisper

final class STTIntegrationTests: XCTestCase {
    
    func testSecureStorageBasicOperations() throws {
        // Test basic secure storage operations
        let testKey = "test_api_key_\(UUID().uuidString)"
        let testValue = "test_value_123"
        
        // Test storage
        SecureStorageManager.shared.setAPIKey(testValue, for: .mistralVoxtral)
        
        // Test retrieval
        let retrievedValue = SecureStorageManager.shared.getAPIKey(for: .mistralVoxtral)
        XCTAssertNotNil(retrievedValue, "Should retrieve stored API key")
        
        // Test validation
        let hasKey = SecureStorageManager.shared.hasValidAPIKey(for: .mistralVoxtral)
        XCTAssertTrue(hasKey, "Should report having valid API key")
        
        // Clean up
        SecureStorageManager.shared.setAPIKey(nil, for: .mistralVoxtral)
        
        let clearedKey = SecureStorageManager.shared.getAPIKey(for: .mistralVoxtral)
        XCTAssertNil(clearedKey, "Should clear API key")
    }
    
    func testSTTProviderTypes() throws {
        // Test provider type properties
        XCTAssertEqual(STTProviderType.whisperLocal.displayName, "Whisper (Local)")
        XCTAssertEqual(STTProviderType.mistralVoxtral.displayName, "Mistral Voxtral")
        
        XCTAssertFalse(STTProviderType.whisperLocal.requiresInternetConnection)
        XCTAssertTrue(STTProviderType.mistralVoxtral.requiresInternetConnection)
        
        // Test all cases
        let allCases = STTProviderType.allCases
        XCTAssertEqual(allCases.count, 2, "Should have exactly 2 provider types")
        XCTAssertTrue(allCases.contains(.whisperLocal))
        XCTAssertTrue(allCases.contains(.mistralVoxtral))
    }
    
    func testConfigurationSerialization() throws {
        // Test Whisper configuration
        let whisperConfig = WhisperLocalConfiguration(
            modelPath: "/test/path",
            useGPUAcceleration: true,
            maxThreads: 8
        )
        
        let whisperData = try JSONEncoder().encode(whisperConfig)
        let decodedWhisperConfig = try JSONDecoder().decode(WhisperLocalConfiguration.self, from: whisperData)
        
        XCTAssertEqual(whisperConfig.modelPath, decodedWhisperConfig.modelPath)
        XCTAssertEqual(whisperConfig.useGPUAcceleration, decodedWhisperConfig.useGPUAcceleration)
        XCTAssertEqual(whisperConfig.maxThreads, decodedWhisperConfig.maxThreads)
        
        // Test Mistral configuration
        let mistralConfig = MistralVoxtralConfiguration(
            endpoint: "https://test.api.mistral.ai/v1/audio/transcriptions",
            model: "voxtral-test",
            maxRetries: 5,
            timeoutInterval: 120.0
        )
        
        let mistralData = try JSONEncoder().encode(mistralConfig)
        let decodedMistralConfig = try JSONDecoder().decode(MistralVoxtralConfiguration.self, from: mistralData)
        
        XCTAssertEqual(mistralConfig.endpoint, decodedMistralConfig.endpoint)
        XCTAssertEqual(mistralConfig.model, decodedMistralConfig.model)
        XCTAssertEqual(mistralConfig.maxRetries, decodedMistralConfig.maxRetries)
        XCTAssertEqual(mistralConfig.timeoutInterval, decodedMistralConfig.timeoutInterval)
    }
    
    func testTranscriptionSettingsBackwardCompatibility() throws {
        // Create settings from preferences (backward compatibility)
        let prefs = AppPreferences.shared
        let settings = TranscriptionSettings(fromAppPreferences: prefs)
        
        // Verify settings are properly initialized
        XCTAssertNotNil(settings.selectedLanguage)
        XCTAssertEqual(settings.primaryProvider.rawValue, prefs.primarySTTProvider)
        XCTAssertEqual(settings.enableFallback, prefs.enableSTTFallback)
        
        // Test current settings property
        let currentSettings = prefs.currentTranscriptionSettings
        XCTAssertNotNil(currentSettings)
        XCTAssertEqual(currentSettings.selectedLanguage, prefs.whisperLanguage)
    }
    
    func testProviderFactory() async throws {
        // Test provider factory basic functionality
        let factory = STTProviderFactory.shared
        
        // Test getting providers (should not throw)
        let whisperProvider = await factory.getProvider(for: .whisperLocal)
        XCTAssertEqual(whisperProvider.id, .whisperLocal)
        XCTAssertEqual(whisperProvider.displayName, "Whisper (Local)")
        
        let mistralProvider = await factory.getProvider(for: .mistralVoxtral)
        XCTAssertEqual(mistralProvider.id, .mistralVoxtral)
        XCTAssertEqual(mistralProvider.displayName, "Mistral Voxtral")
        
        // Test provider caching (should return same instance)
        let whisperProvider2 = await factory.getProvider(for: .whisperLocal)
        XCTAssertTrue(whisperProvider === whisperProvider2, "Should return cached provider instance")
    }
    
    func testErrorHandling() throws {
        // Test error descriptions
        let errors: [TranscriptionError] = [
            .providerNotConfigured(.mistralVoxtral),
            .apiKeyInvalid,
            .quotaExceeded,
            .unsupportedLanguage("xyz"),
            .fileTooBig(maxSize: 1024),
            .providerUnavailable(.whisperLocal)
        ]
        
        for error in errors {
            XCTAssertNotNil(error.localizedDescription)
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        
        // Test validation errors
        let validationErrors: [ValidationError] = [
            .missingApiKey,
            .invalidApiKey,
            .networkUnreachable,
            .modelNotFound(path: "/test"),
            .insufficientDiskSpace,
            .unsupportedAudioFormat
        ]
        
        for error in validationErrors {
            XCTAssertNotNil(error.localizedDescription)
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }
    
    func testMistralConfigurationValidation() throws {
        // Test valid configuration
        var config = MistralVoxtralConfiguration()
        config.apiKey = "test-key-123"
        XCTAssertTrue(config.hasValidAPIKey)
        
        // Test invalid configuration
        config.apiKey = nil
        XCTAssertFalse(config.hasValidAPIKey)
        
        config.apiKey = ""
        XCTAssertFalse(config.hasValidAPIKey)
    }
    
    func testEnhancedTranscriptionServiceInitialization() throws {
        // Test service initialization
        let service = EnhancedTranscriptionService.shared
        XCTAssertFalse(service.isTranscribing)
        XCTAssertTrue(service.transcribedText.isEmpty)
        XCTAssertTrue(service.currentSegment.isEmpty)
        XCTAssertFalse(service.isLoading)
        XCTAssertEqual(service.progress, 0.0)
        XCTAssertNil(service.currentProvider)
        XCTAssertNil(service.lastError)
    }
    
    func testSettingsViewModelValidation() {
        // Test settings view model
        let viewModel = SettingsViewModel()
        
        // Test initial state
        XCTAssertEqual(viewModel.apiKeyValidationState, .unknown)
        XCTAssertFalse(viewModel.availableSTTProviders.isEmpty)
        XCTAssertFalse(viewModel.availableMistralModels.isEmpty)
        
        // Test available providers
        XCTAssertTrue(viewModel.availableSTTProviders.contains(.whisperLocal))
        XCTAssertTrue(viewModel.availableSTTProviders.contains(.mistralVoxtral))
        
        // Test available models
        XCTAssertTrue(viewModel.availableMistralModels.contains("voxtral-mini-latest"))
    }
}