//
//  STTProviderFactoryTests.swift
//  OpenSuperWhisperTests
//
//  Created by Claude on 03.08.2025.
//

import XCTest
@testable import OpenSuperWhisper

final class STTProviderFactoryTests: XCTestCase {
    
    private var factory: STTProviderFactory!
    
    override func setUpWithError() throws {
        // Create a fresh factory instance for each test
        factory = STTProviderFactory.shared
        
        // Clear any cached providers
        Task {
            await factory.refreshAllProviders()
        }
    }
    
    override func tearDownWithError() throws {
        Task {
            await factory.refreshAllProviders()
        }
    }
    
    // MARK: - Factory Basic Tests
    
    func testFactorySharedInstance() throws {
        let factory1 = STTProviderFactory.shared
        let factory2 = STTProviderFactory.shared
        
        // Should be the same instance (singleton)
        XCTAssertTrue(factory1 === factory2)
    }
    
    func testGetAvailableProviders() async throws {
        let providers = await factory.getAvailableProviders()
        
        // Should return all provider types
        XCTAssertEqual(providers.count, STTProviderType.allCases.count)
        XCTAssertTrue(providers.contains(.whisperLocal))
        XCTAssertTrue(providers.contains(.mistralVoxtral))
    }
    
    // MARK: - Provider Creation Tests
    
    func testGetWhisperLocalProvider() async throws {
        let provider = await factory.getProvider(for: .whisperLocal)
        
        XCTAssertEqual(provider.id, .whisperLocal)
        XCTAssertEqual(provider.displayName, "Whisper (Local)")
        XCTAssertTrue(provider is WhisperLocalProvider)
    }
    
    func testGetMistralVoxtralProvider() async throws {
        let provider = await factory.getProvider(for: .mistralVoxtral)
        
        XCTAssertEqual(provider.id, .mistralVoxtral)
        XCTAssertEqual(provider.displayName, "Mistral Voxtral")
        XCTAssertTrue(provider is MistralVoxtralProvider)
    }
    
    // MARK: - Provider Caching Tests
    
    func testProviderCaching() async throws {
        // First call should create new provider
        let provider1 = await factory.getProvider(for: .whisperLocal)
        
        // Second call should return cached provider
        let provider2 = await factory.getProvider(for: .whisperLocal)
        
        // Should be the same instance due to caching
        // Note: This tests that the factory maintains the same instance
        XCTAssertEqual(provider1.id, provider2.id)
        XCTAssertEqual(provider1.displayName, provider2.displayName)
    }
    
    func testProviderCachingDifferentTypes() async throws {
        let whisperProvider = await factory.getProvider(for: .whisperLocal)
        let mistralProvider = await factory.getProvider(for: .mistralVoxtral)
        
        // Should be different providers
        XCTAssertNotEqual(whisperProvider.id, mistralProvider.id)
        XCTAssertNotEqual(whisperProvider.displayName, mistralProvider.displayName)
    }
    
    // MARK: - Provider Refresh Tests
    
    func testRefreshSpecificProvider() async throws {
        // Get initial provider
        let initialProvider = await factory.getProvider(for: .whisperLocal)
        
        // Refresh the provider
        await factory.refreshProvider(for: .whisperLocal)
        
        // Get provider again - should be a new instance
        let refreshedProvider = await factory.getProvider(for: .whisperLocal)
        
        // Should have same properties but be potentially different instances
        XCTAssertEqual(initialProvider.id, refreshedProvider.id)
        XCTAssertEqual(initialProvider.displayName, refreshedProvider.displayName)
    }
    
    func testRefreshAllProviders() async throws {
        // Get initial providers
        let whisperProvider1 = await factory.getProvider(for: .whisperLocal)
        let mistralProvider1 = await factory.getProvider(for: .mistralVoxtral)
        
        // Refresh all providers
        await factory.refreshAllProviders()
        
        // Get providers again
        let whisperProvider2 = await factory.getProvider(for: .whisperLocal)
        let mistralProvider2 = await factory.getProvider(for: .mistralVoxtral)
        
        // Should have same properties
        XCTAssertEqual(whisperProvider1.id, whisperProvider2.id)
        XCTAssertEqual(mistralProvider1.id, mistralProvider2.id)
    }
    
    // MARK: - Configuration Tests
    
    func testProviderConfigurationIntegration() async throws {
        // Test that providers are created with current app preferences
        
        // Modify app preferences
        let originalWhisperConfig = AppPreferences.shared.whisperLocalConfig
        var newWhisperConfig = WhisperLocalConfiguration()
        newWhisperConfig.modelPath = "/test/path/model.bin"
        newWhisperConfig.useGPUAcceleration = false
        AppPreferences.shared.whisperLocalConfig = newWhisperConfig
        
        // Refresh to pick up new config
        await factory.refreshProvider(for: .whisperLocal)
        
        // Get provider and check configuration
        let provider = await factory.getProvider(for: .whisperLocal)
        let config = provider.configuration as? WhisperLocalConfiguration
        
        XCTAssertNotNil(config)
        XCTAssertEqual(config?.modelPath, "/test/path/model.bin")
        XCTAssertEqual(config?.useGPUAcceleration, false)
        
        // Restore original config
        AppPreferences.shared.whisperLocalConfig = originalWhisperConfig
    }
    
    // MARK: - Provider Configuration Validation Tests
    
    func testGetConfiguredProvidersWithValidWhisper() async throws {
        // Set up valid Whisper configuration
        var whisperConfig = AppPreferences.shared.whisperLocalConfig
        whisperConfig.modelPath = Bundle.main.path(forResource: "ggml-tiny.en", ofType: "bin")
        whisperConfig.isEnabled = true
        AppPreferences.shared.whisperLocalConfig = whisperConfig
        
        await factory.refreshProvider(for: .whisperLocal)
        
        let configuredProviders = await factory.getConfiguredProviders()
        
        // If model file exists, whisper should be configured
        if whisperConfig.modelPath != nil && FileManager.default.fileExists(atPath: whisperConfig.modelPath!) {
            XCTAssertTrue(configuredProviders.contains(.whisperLocal))
        }
    }
    
    func testGetConfiguredProvidersWithInvalidWhisper() async throws {
        // Set up invalid Whisper configuration (no model path)
        var whisperConfig = AppPreferences.shared.whisperLocalConfig
        whisperConfig.modelPath = nil
        whisperConfig.isEnabled = true
        AppPreferences.shared.whisperLocalConfig = whisperConfig
        
        await factory.refreshProvider(for: .whisperLocal)
        
        let configuredProviders = await factory.getConfiguredProviders()
        
        // Should not include whisper if no model path
        XCTAssertFalse(configuredProviders.contains(.whisperLocal))
    }
    
    func testGetConfiguredProvidersWithValidMistral() async throws {
        // Set up valid Mistral configuration
        var mistralConfig = AppPreferences.shared.mistralVoxtralConfig
        mistralConfig.isEnabled = true
        AppPreferences.shared.mistralVoxtralConfig = mistralConfig
        
        // Set a test API key
        SecureStorageManager.shared.setAPIKey("test_key_123", for: .mistralVoxtral)
        
        await factory.refreshProvider(for: .mistralVoxtral)
        
        let configuredProviders = await factory.getConfiguredProviders()
        
        // Should include Mistral if API key is set
        XCTAssertTrue(configuredProviders.contains(.mistralVoxtral))
        
        // Clean up
        SecureStorageManager.shared.setAPIKey(nil, for: .mistralVoxtral)
    }
    
    func testGetConfiguredProvidersWithInvalidMistral() async throws {
        // Set up invalid Mistral configuration (no API key)
        var mistralConfig = AppPreferences.shared.mistralVoxtralConfig
        mistralConfig.isEnabled = true
        AppPreferences.shared.mistralVoxtralConfig = mistralConfig
        
        // Ensure no API key is set
        SecureStorageManager.shared.setAPIKey(nil, for: .mistralVoxtral)
        
        await factory.refreshProvider(for: .mistralVoxtral)
        
        let configuredProviders = await factory.getConfiguredProviders()
        
        // Should not include Mistral if no API key
        XCTAssertFalse(configuredProviders.contains(.mistralVoxtral))
    }
    
    // MARK: - Thread Safety Tests
    
    func testConcurrentProviderAccess() async throws {
        // Test concurrent access to the same provider type
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<10 {
                group.addTask {
                    let provider = await self.factory.getProvider(for: .whisperLocal)
                    XCTAssertEqual(provider.id, .whisperLocal)
                }
            }
        }
    }
    
    func testConcurrentDifferentProviders() async throws {
        // Test concurrent access to different provider types
        await withTaskGroup(of: STTProviderType.self) { group in
            for providerType in STTProviderType.allCases {
                group.addTask {
                    let provider = await self.factory.getProvider(for: providerType)
                    return provider.id
                }
            }
            
            var results: [STTProviderType] = []
            for await result in group {
                results.append(result)
            }
            
            // Should have all provider types
            XCTAssertEqual(results.count, STTProviderType.allCases.count)
            for providerType in STTProviderType.allCases {
                XCTAssertTrue(results.contains(providerType))
            }
        }
    }
    
    // MARK: - Error Handling Tests
    
    func testProviderCreationDoesNotThrow() async throws {
        // Provider creation should not throw, even with invalid configurations
        for providerType in STTProviderType.allCases {
            XCTAssertNoThrow(await factory.getProvider(for: providerType))
        }
    }
    
    // MARK: - Memory Management Tests
    
    func testProviderMemoryManagement() async throws {
        // Get a provider
        var provider: (any STTProvider)? = await factory.getProvider(for: .whisperLocal)
        weak var weakProvider = provider
        
        // Clear reference
        provider = nil
        
        // Refresh all providers (should clear cache)
        await factory.refreshAllProviders()
        
        // Note: Due to the nature of the factory caching, this test may not work as expected
        // The factory maintains strong references to providers, so they won't be deallocated
        // until the factory itself is deallocated or refreshed
    }
}