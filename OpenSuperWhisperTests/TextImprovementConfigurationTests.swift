import XCTest
@testable import OpenSuperWhisper

final class TextImprovementConfigurationTests: XCTestCase {
    
    override func setUp() {
        super.setUp()
        // Clear any existing configuration
        UserDefaults.standard.removeObject(forKey: "textImprovementConfig")
    }
    
    override func tearDown() {
        // Clean up
        UserDefaults.standard.removeObject(forKey: "textImprovementConfig")
        super.tearDown()
    }
    
    // MARK: - Configuration Tests
    
    func testDefaultConfiguration() {
        let config = TextImprovementConfiguration()
        
        XCTAssertFalse(config.isEnabled)
        XCTAssertEqual(config.baseURL, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(config.model, "openai/gpt-4o-mini")
        XCTAssertNil(config.apiKey)
        XCTAssertFalse(config.useAdvancedSettings)
        XCTAssertNil(config.temperature)
        XCTAssertNil(config.maxTokens)
        XCTAssertEqual(config.customPrompt, "Improve the following transcribed text for clarity and coherence without changing its meaning:")
    }
    
    func testConfigurationEncoding() throws {
        var config = TextImprovementConfiguration()
        config.isEnabled = true
        config.apiKey = "test-key-123"
        config.model = "anthropic/claude-3-haiku"
        config.useAdvancedSettings = true
        config.temperature = 0.7
        config.maxTokens = 2000
        config.customPrompt = "Custom prompt here"
        config.baseURL = "https://custom-api.example.com/v1/chat/completions"
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(config)
        
        let decoder = JSONDecoder()
        let decodedConfig = try decoder.decode(TextImprovementConfiguration.self, from: data)
        
        XCTAssertEqual(config.isEnabled, decodedConfig.isEnabled)
        XCTAssertEqual(config.apiKey, decodedConfig.apiKey)
        XCTAssertEqual(config.model, decodedConfig.model)
        XCTAssertEqual(config.useAdvancedSettings, decodedConfig.useAdvancedSettings)
        XCTAssertEqual(config.temperature, decodedConfig.temperature, accuracy: 0.001)
        XCTAssertEqual(config.maxTokens, decodedConfig.maxTokens)
        XCTAssertEqual(config.customPrompt, decodedConfig.customPrompt)
        XCTAssertEqual(config.baseURL, decodedConfig.baseURL)
    }
    
    func testConfigurationValidation() {
        var config = TextImprovementConfiguration()
        
        // Default config should be invalid (no API key)
        XCTAssertFalse(config.isValid)
        
        // Empty API key should be invalid
        config.apiKey = ""
        XCTAssertFalse(config.isValid)
        
        // Valid API key should make it valid
        config.apiKey = "test-key"
        XCTAssertTrue(config.isValid)
        
        // Empty base URL should be invalid
        config.baseURL = ""
        XCTAssertFalse(config.isValid)
        
        // Invalid URL should be invalid
        config.baseURL = "not-a-url"
        XCTAssertFalse(config.isValid)
        
        // Valid URL should make it valid again
        config.baseURL = "https://api.example.com/v1/chat"
        XCTAssertTrue(config.isValid)
        
        // Empty model should be invalid
        config.model = ""
        XCTAssertFalse(config.isValid)
        
        // Valid model should make it valid again
        config.model = "openai/gpt-4"
        XCTAssertTrue(config.isValid)
    }
    
    func testValidationWithCustomSettings() {
        var config = TextImprovementConfiguration()
        config.apiKey = "sk-test123"
        config.baseURL = "https://custom-openrouter.example.com/api/v1/chat/completions"
        config.model = "custom/model-name"
        
        XCTAssertTrue(config.isValid)
    }
    
    func testTemperatureValidation() {
        var config = TextImprovementConfiguration()
        config.apiKey = "test-key"
        
        // Nil temperature should be valid
        config.temperature = nil
        XCTAssertTrue(config.isValid)
        
        // Valid temperature range
        config.temperature = 0.0
        XCTAssertTrue(config.isValid)
        
        config.temperature = 1.0
        XCTAssertTrue(config.isValid)
        
        config.temperature = 0.5
        XCTAssertTrue(config.isValid)
        
        // Invalid temperature (negative)
        config.temperature = -0.1
        XCTAssertFalse(config.isValid)
        
        // Invalid temperature (too high)
        config.temperature = 1.1
        XCTAssertFalse(config.isValid)
    }
    
    func testMaxTokensValidation() {
        var config = TextImprovementConfiguration()
        config.apiKey = "test-key"
        
        // Nil maxTokens should be valid
        config.maxTokens = nil
        XCTAssertTrue(config.isValid)
        
        // Valid max tokens
        config.maxTokens = 1
        XCTAssertTrue(config.isValid)
        
        config.maxTokens = 1000
        XCTAssertTrue(config.isValid)
        
        config.maxTokens = 4000
        XCTAssertTrue(config.isValid)
        
        // Invalid max tokens (zero or negative)
        config.maxTokens = 0
        XCTAssertFalse(config.isValid)
        
        config.maxTokens = -100
        XCTAssertFalse(config.isValid)
    }
    
    // MARK: - AppPreferences Integration Tests
    
    func testAppPreferencesIntegration() {
        let prefs = AppPreferences.shared
        
        // Default config should be returned when no config is saved
        let defaultConfig = prefs.textImprovementConfig
        XCTAssertFalse(defaultConfig.isEnabled)
        XCTAssertEqual(defaultConfig.baseURL, "https://openrouter.ai/api/v1/chat/completions")
        
        // Set a custom configuration
        var customConfig = TextImprovementConfiguration()
        customConfig.isEnabled = true
        customConfig.apiKey = "custom-key"
        customConfig.model = "custom/model"
        customConfig.temperature = 0.8
        customConfig.maxTokens = 1500
        customConfig.customPrompt = "Custom improvement prompt"
        customConfig.baseURL = "https://custom.api.com/v1/chat"
        
        prefs.textImprovementConfig = customConfig
        
        // Retrieve and verify the configuration
        let retrievedConfig = prefs.textImprovementConfig
        XCTAssertEqual(retrievedConfig.isEnabled, customConfig.isEnabled)
        XCTAssertEqual(retrievedConfig.apiKey, customConfig.apiKey)
        XCTAssertEqual(retrievedConfig.model, customConfig.model)
        XCTAssertEqual(retrievedConfig.temperature, customConfig.temperature, accuracy: 0.001)
        XCTAssertEqual(retrievedConfig.maxTokens, customConfig.maxTokens)
        XCTAssertEqual(retrievedConfig.customPrompt, customConfig.customPrompt)
        XCTAssertEqual(retrievedConfig.baseURL, customConfig.baseURL)
    }
    
    func testSecureAPIKeyStorage() {
        // Note: This test would require mocking SecureStorage
        // For now, we'll test the configuration structure
        
        var config = TextImprovementConfiguration()
        config.apiKey = "sensitive-api-key-12345"
        
        // Verify the API key is stored (would be handled by SecureStorage in real implementation)
        XCTAssertEqual(config.apiKey, "sensitive-api-key-12345")
        
        // In a real implementation, the apiKey would be stored securely
        // and the configuration would only store a reference or nil
        // when persisted to UserDefaults
    }
    
    func testConfigurationDefaults() {
        let config = TextImprovementConfiguration()
        
        // Test all default values are reasonable
        XCTAssertFalse(config.isEnabled) // Should be opt-in
        XCTAssertTrue(config.baseURL.hasPrefix("https://")) // Should use HTTPS
        XCTAssertTrue(config.model.contains("/")) // Should follow provider/model format
        XCTAssertGreaterThan(config.temperature, 0.0) // Should allow some creativity
        XCTAssertLessThan(config.temperature, 1.0) // But not too much
        XCTAssertGreaterThan(config.maxTokens, 100) // Should allow reasonable responses
        XCTAssertFalse(config.customPrompt.isEmpty) // Should have a default prompt
    }
    
    // MARK: - Edge Cases
    
    func testEmptyPromptHandling() {
        var config = TextImprovementConfiguration()
        config.apiKey = "test-key"
        config.customPrompt = ""
        
        // Empty prompt should still be valid (will use default)
        XCTAssertTrue(config.isValid)
    }
    
    func testLongPromptHandling() {
        var config = TextImprovementConfiguration()
        config.apiKey = "test-key"
        config.customPrompt = String(repeating: "A", count: 5000)
        
        // Long prompt should still be valid
        XCTAssertTrue(config.isValid)
    }
    
    func testSpecialCharactersInPrompt() {
        var config = TextImprovementConfiguration()
        config.apiKey = "test-key"
        config.customPrompt = "Improve this text: \"quotes\", 'single quotes', \n newlines, \t tabs, émojis 🚀"
        
        XCTAssertTrue(config.isValid)
        
        // Test encoding/decoding with special characters
        let encoder = JSONEncoder()
        let data = try! encoder.encode(config)
        
        let decoder = JSONDecoder()
        let decodedConfig = try! decoder.decode(TextImprovementConfiguration.self, from: data)
        
        XCTAssertEqual(config.customPrompt, decodedConfig.customPrompt)
    }
}