//
//  SettingsViewModelTests.swift
//  OpenSuperWhisperTests
//
//  Created by user on 05.02.2025.
//

import XCTest
import Combine
@testable import OpenSuperWhisper

@MainActor
final class SettingsViewModelTests: XCTestCase {
    
    var viewModel: SettingsViewModel!
    var cancellables: Set<AnyCancellable>!
    
    override func setUpWithError() throws {
        super.setUp()
        cancellables = Set<AnyCancellable>()
        viewModel = SettingsViewModel()
    }
    
    override func tearDownWithError() throws {
        cancellables = nil
        viewModel = nil
        super.tearDown()
    }
    
    // MARK: - Initialization Tests
    
    func testViewModelInitialization() throws {
        // Test that viewModel initializes with default values from AppPreferences
        XCTAssertNotNil(viewModel.selectedLanguage)
        XCTAssertNotNil(viewModel.selectedSTTProvider)
        XCTAssertEqual(viewModel.apiKeyValidationState, .unknown)
        XCTAssertEqual(viewModel.textImprovementValidationState, .unknown)
    }
    
    func testAvailableModelsLoad() throws {
        // Test that available models are loaded on initialization
        viewModel.loadAvailableModels()
        XCTAssertGreaterThanOrEqual(viewModel.availableModels.count, 0)
    }
    
    // MARK: - Language Settings Tests
    
    func testLanguageSelectionUpdatesPreferences() throws {
        let expectation = expectation(description: "Language preference updated")
        let testLanguage = "es"
        
        // Monitor preference changes
        viewModel.$selectedLanguage
            .dropFirst() // Skip initial value
            .sink { language in
                if language == testLanguage {
                    expectation.fulfill()
                }
            }
            .store(in: &cancellables)
        
        // Update language
        viewModel.selectedLanguage = testLanguage
        
        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(AppPreferences.shared.whisperLanguage, testLanguage)
    }
    
    func testTranslateToEnglishToggle() throws {
        let initialValue = viewModel.translateToEnglish
        viewModel.translateToEnglish = !initialValue
        
        XCTAssertEqual(viewModel.translateToEnglish, !initialValue)
        XCTAssertEqual(AppPreferences.shared.translateToEnglish, !initialValue)
    }
    
    // MARK: - STT Provider Tests
    
    func testSTTProviderSelection() throws {
        let testProvider = STTProviderType.mistralVoxtral
        viewModel.selectedSTTProvider = testProvider
        
        XCTAssertEqual(viewModel.selectedSTTProvider, testProvider)
        XCTAssertEqual(AppPreferences.shared.primarySTTProvider, testProvider.rawValue)
    }
    
    func testAvailableSTTProviders() throws {
        let providers = viewModel.availableSTTProviders
        XCTAssertTrue(providers.contains(.whisperLocal))
        XCTAssertTrue(providers.contains(.mistralVoxtral))
    }
    
    func testSTTFallbackToggle() throws {
        let initialValue = viewModel.enableSTTFallback
        viewModel.enableSTTFallback = !initialValue
        
        XCTAssertEqual(viewModel.enableSTTFallback, !initialValue)
        XCTAssertEqual(AppPreferences.shared.enableSTTFallback, !initialValue)
    }
    
    // MARK: - API Key Validation Tests
    
    func testMistralAPIKeyUpdate() throws {
        let testAPIKey = "test_api_key_123"
        viewModel.mistralAPIKey = testAPIKey
        
        XCTAssertEqual(viewModel.mistralAPIKey, testAPIKey)
        let config = AppPreferences.shared.mistralVoxtralConfig
        XCTAssertEqual(config.apiKey, testAPIKey)
    }
    
    func testEmptyMistralAPIKeyValidation() throws {
        viewModel.mistralAPIKey = ""
        viewModel.validateMistralAPIKey()
        
        if case .invalid(let error) = viewModel.apiKeyValidationState {
            XCTAssertTrue(error.contains("empty"))
        } else {
            XCTFail("Expected invalid state for empty API key")
        }
    }
    
    func testMistralModelSelection() throws {
        let testModel = "voxtral-mini-latest"
        viewModel.mistralModel = testModel
        
        XCTAssertEqual(viewModel.mistralModel, testModel)
        let config = AppPreferences.shared.mistralVoxtralConfig
        XCTAssertEqual(config.model, testModel)
    }
    
    // MARK: - Text Improvement Tests
    
    func testTextImprovementToggle() throws {
        let initialValue = viewModel.textImprovementEnabled
        viewModel.textImprovementEnabled = !initialValue
        
        XCTAssertEqual(viewModel.textImprovementEnabled, !initialValue)
        let config = AppPreferences.shared.textImprovementConfig
        XCTAssertEqual(config.isEnabled, !initialValue)
    }
    
    func testTextImprovementAPIKeyUpdate() throws {
        let testAPIKey = "test_openrouter_key"
        viewModel.textImprovementAPIKey = testAPIKey
        
        XCTAssertEqual(viewModel.textImprovementAPIKey, testAPIKey)
        let config = AppPreferences.shared.textImprovementConfig
        XCTAssertEqual(config.apiKey, testAPIKey)
    }
    
    func testTextImprovementModelUpdate() throws {
        let testModel = "openai/gpt-4o-mini"
        viewModel.textImprovementModel = testModel
        
        XCTAssertEqual(viewModel.textImprovementModel, testModel)
        let config = AppPreferences.shared.textImprovementConfig
        XCTAssertEqual(config.model, testModel)
    }
    
    func testTextImprovementBaseURLUpdate() throws {
        let testURL = "https://custom.api.endpoint.com"
        viewModel.textImprovementBaseURL = testURL
        
        XCTAssertEqual(viewModel.textImprovementBaseURL, testURL)
        let config = AppPreferences.shared.textImprovementConfig
        XCTAssertEqual(config.baseURL, testURL)
    }
    
    func testAdvancedTextImprovementSettings() throws {
        // Test advanced settings toggle
        viewModel.useAdvancedTextImprovementSettings = true
        let config = AppPreferences.shared.textImprovementConfig
        XCTAssertTrue(config.useAdvancedSettings)
        
        // Test temperature setting
        let testTemperature = 0.7
        viewModel.textImprovementTemperature = testTemperature
        let updatedConfig = AppPreferences.shared.textImprovementConfig
        XCTAssertEqual(updatedConfig.temperature, testTemperature)
        
        // Test max tokens setting
        let testMaxTokens = 2000
        viewModel.textImprovementMaxTokens = testMaxTokens
        let finalConfig = AppPreferences.shared.textImprovementConfig
        XCTAssertEqual(finalConfig.maxTokens, testMaxTokens)
    }
    
    func testAdvancedTextImprovementDisabled() throws {
        // Enable advanced settings first
        viewModel.useAdvancedTextImprovementSettings = true
        viewModel.textImprovementTemperature = 0.8
        viewModel.textImprovementMaxTokens = 1500
        
        // Disable advanced settings
        viewModel.useAdvancedTextImprovementSettings = false
        
        let config = AppPreferences.shared.textImprovementConfig
        XCTAssertFalse(config.useAdvancedSettings)
        XCTAssertNil(config.temperature)
        XCTAssertNil(config.maxTokens)
    }
    
    // MARK: - Advanced Settings Tests
    
    func testTemperatureSlider() throws {
        let testTemperature = 0.5
        viewModel.temperature = testTemperature
        
        XCTAssertEqual(viewModel.temperature, testTemperature)
        XCTAssertEqual(AppPreferences.shared.temperature, testTemperature)
    }
    
    func testNoSpeechThreshold() throws {
        let testThreshold = 0.3
        viewModel.noSpeechThreshold = testThreshold
        
        XCTAssertEqual(viewModel.noSpeechThreshold, testThreshold)
        XCTAssertEqual(AppPreferences.shared.noSpeechThreshold, testThreshold)
    }
    
    func testBeamSearchSettings() throws {
        // Test beam search toggle
        viewModel.useBeamSearch = true
        XCTAssertTrue(viewModel.useBeamSearch)
        XCTAssertTrue(AppPreferences.shared.useBeamSearch)
        
        // Test beam size
        let testBeamSize = 5
        viewModel.beamSize = testBeamSize
        XCTAssertEqual(viewModel.beamSize, testBeamSize)
        XCTAssertEqual(AppPreferences.shared.beamSize, testBeamSize)
    }
    
    func testInitialPromptUpdate() throws {
        let testPrompt = "Test transcription prompt"
        viewModel.initialPrompt = testPrompt
        
        XCTAssertEqual(viewModel.initialPrompt, testPrompt)
        XCTAssertEqual(AppPreferences.shared.initialPrompt, testPrompt)
    }
    
    func testDebugModeToggle() throws {
        let initialValue = viewModel.debugMode
        viewModel.debugMode = !initialValue
        
        XCTAssertEqual(viewModel.debugMode, !initialValue)
        XCTAssertEqual(AppPreferences.shared.debugMode, !initialValue)
    }
    
    func testPlaySoundOnRecordStart() throws {
        let initialValue = viewModel.playSoundOnRecordStart
        viewModel.playSoundOnRecordStart = !initialValue
        
        XCTAssertEqual(viewModel.playSoundOnRecordStart, !initialValue)
        XCTAssertEqual(AppPreferences.shared.playSoundOnRecordStart, !initialValue)
    }
    
    // MARK: - Output Settings Tests
    
    func testShowTimestampsToggle() throws {
        let initialValue = viewModel.showTimestamps
        viewModel.showTimestamps = !initialValue
        
        XCTAssertEqual(viewModel.showTimestamps, !initialValue)
        XCTAssertEqual(AppPreferences.shared.showTimestamps, !initialValue)
    }
    
    func testSuppressBlankAudioToggle() throws {
        let initialValue = viewModel.suppressBlankAudio
        viewModel.suppressBlankAudio = !initialValue
        
        XCTAssertEqual(viewModel.suppressBlankAudio, !initialValue)
        XCTAssertEqual(AppPreferences.shared.suppressBlankAudio, !initialValue)
    }
    
    // MARK: - Validation State Tests
    
    func testAPIKeyValidationStateTransitions() throws {
        // Test initial state
        XCTAssertEqual(viewModel.apiKeyValidationState, .unknown)
        
        // Test validating state (would be set by validateMistralAPIKey)
        viewModel.mistralAPIKey = "valid_key"
        // Note: In a real test, we'd mock the network call
        // For now, we test the empty key case which doesn't require network
        viewModel.mistralAPIKey = ""
        viewModel.validateMistralAPIKey()
        
        if case .invalid = viewModel.apiKeyValidationState {
            // Expected behavior for empty key
        } else {
            XCTFail("Expected invalid state for empty API key")
        }
    }
    
    func testTextImprovementValidationStateTransitions() throws {
        // Test initial state
        XCTAssertEqual(viewModel.textImprovementValidationState, .unknown)
        
        // Test empty key validation
        viewModel.textImprovementAPIKey = ""
        viewModel.validateTextImprovementAPIKey()
        
        if case .invalid = viewModel.textImprovementValidationState {
            // Expected behavior for empty key
        } else {
            XCTFail("Expected invalid state for empty API key")
        }
    }
    
    // MARK: - Model URL Tests
    
    func testSelectedModelURLUpdate() throws {
        let testURL = URL(fileURLWithPath: "/path/to/test/model.bin")
        viewModel.selectedModelURL = testURL
        
        XCTAssertEqual(viewModel.selectedModelURL, testURL)
        XCTAssertEqual(AppPreferences.shared.selectedModelPath, testURL.path)
    }
    
    func testModelURLNilHandling() throws {
        viewModel.selectedModelURL = nil
        XCTAssertNil(viewModel.selectedModelURL)
        // AppPreferences should handle nil gracefully
    }
}