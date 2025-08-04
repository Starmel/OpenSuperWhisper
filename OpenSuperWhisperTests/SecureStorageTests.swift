//
//  SecureStorageTests.swift
//  OpenSuperWhisperTests
//
//  Created by Claude on 03.08.2025.
//

import XCTest
import Security
@testable import OpenSuperWhisper

final class SecureStorageTests: XCTestCase {
    
    private let testService = "com.opensuperwhisper.apikeys.test"
    private let testKey = "test_api_key"
    private let testValue = "test_secret_key_123"
    
    override func setUpWithError() throws {
        // Clean up any existing test data
        clearTestKeychain()
    }
    
    override func tearDownWithError() throws {
        // Clean up test data
        clearTestKeychain()
    }
    
    // MARK: - SecureStorage Property Wrapper Tests
    
    func testSecureStorageSetAndGet() throws {
        @SecureStorage(testKey) var testAPIKey: String?
        
        // Initially should be nil
        XCTAssertNil(testAPIKey)
        
        // Set a value
        testAPIKey = testValue
        
        // Should retrieve the same value
        XCTAssertEqual(testAPIKey, testValue)
    }
    
    func testSecureStorageOverwrite() throws {
        @SecureStorage(testKey) var testAPIKey: String?
        
        // Set initial value
        testAPIKey = testValue
        XCTAssertEqual(testAPIKey, testValue)
        
        // Overwrite with new value
        let newValue = "new_secret_key_456"
        testAPIKey = newValue
        XCTAssertEqual(testAPIKey, newValue)
    }
    
    func testSecureStorageClear() throws {
        @SecureStorage(testKey) var testAPIKey: String?
        
        // Set a value
        testAPIKey = testValue
        XCTAssertEqual(testAPIKey, testValue)
        
        // Clear the value
        testAPIKey = nil
        XCTAssertNil(testAPIKey)
    }
    
    func testSecureStorageEmptyString() throws {
        @SecureStorage(testKey) var testAPIKey: String?
        
        // Set empty string should clear the value
        testAPIKey = ""
        XCTAssertNil(testAPIKey)
        
        // Set whitespace string should clear the value  
        testAPIKey = "   "
        XCTAssertNil(testAPIKey)
    }
    
    func testSecureStorageHasValue() throws {
        @SecureStorage(testKey) var testAPIKey: String?
        
        // Initially should not have value
        XCTAssertFalse(testAPIKey.hasValue)
        
        // Set a value
        testAPIKey = testValue
        XCTAssertTrue(testAPIKey.hasValue)
        
        // Clear the value
        testAPIKey = nil
        XCTAssertFalse(testAPIKey.hasValue)
    }
    
    func testSecureStoragePersistence() throws {
        // Create first instance and set value
        do {
            @SecureStorage(testKey) var testAPIKey1: String?
            testAPIKey1 = testValue
        }
        
        // Create second instance and verify value persists
        do {
            @SecureStorage(testKey) var testAPIKey2: String?
            XCTAssertEqual(testAPIKey2, testValue)
        }
    }
    
    // MARK: - SecureStorageManager Tests
    
    func testSecureStorageManagerMistralProvider() throws {
        let manager = SecureStorageManager.shared
        
        // Initially should not have valid API key
        XCTAssertFalse(manager.hasValidAPIKey(for: .mistralVoxtral))
        XCTAssertNil(manager.getAPIKey(for: .mistralVoxtral))
        
        // Set API key
        manager.setAPIKey(testValue, for: .mistralVoxtral)
        
        // Should now have valid API key
        XCTAssertTrue(manager.hasValidAPIKey(for: .mistralVoxtral))
        XCTAssertEqual(manager.getAPIKey(for: .mistralVoxtral), testValue)
        
        // Clear API key
        manager.setAPIKey(nil, for: .mistralVoxtral)
        XCTAssertFalse(manager.hasValidAPIKey(for: .mistralVoxtral))
        XCTAssertNil(manager.getAPIKey(for: .mistralVoxtral))
    }
    
    func testSecureStorageManagerWhisperProvider() throws {
        let manager = SecureStorageManager.shared
        
        // Whisper local should always return true for hasValidAPIKey
        XCTAssertTrue(manager.hasValidAPIKey(for: .whisperLocal))
        
        // Should return nil for API key (local provider doesn't need one)
        XCTAssertNil(manager.getAPIKey(for: .whisperLocal))
        
        // Setting API key should be ignored
        manager.setAPIKey(testValue, for: .whisperLocal)
        XCTAssertNil(manager.getAPIKey(for: .whisperLocal))
    }
    
    func testSecureStorageManagerEmptyKey() throws {
        let manager = SecureStorageManager.shared
        
        // Set empty string should be treated as no key
        manager.setAPIKey("", for: .mistralVoxtral)
        XCTAssertFalse(manager.hasValidAPIKey(for: .mistralVoxtral))
        
        // Set whitespace string should be treated as no key
        manager.setAPIKey("   ", for: .mistralVoxtral)
        XCTAssertFalse(manager.hasValidAPIKey(for: .mistralVoxtral))
    }
    
    func testSecureStorageManagerClearAllAPIKeys() throws {
        let manager = SecureStorageManager.shared
        
        // Set API keys for providers that support them
        manager.setAPIKey(testValue, for: .mistralVoxtral)
        XCTAssertTrue(manager.hasValidAPIKey(for: .mistralVoxtral))
        
        // Clear all API keys
        manager.clearAllAPIKeys()
        
        // Should all be cleared
        XCTAssertFalse(manager.hasValidAPIKey(for: .mistralVoxtral))
    }
    
    // MARK: - Configuration Integration Tests
    
    func testMistralConfigurationAPIKeyIntegration() throws {
        var config = MistralVoxtralConfiguration()
        
        // Initially should not have valid API key
        XCTAssertFalse(config.hasValidAPIKey)
        XCTAssertNil(config.apiKey)
        
        // Set API key through configuration
        config.apiKey = testValue
        
        // Should now have valid API key
        XCTAssertTrue(config.hasValidAPIKey)
        XCTAssertEqual(config.apiKey, testValue)
        
        // Verify it was stored securely
        let manager = SecureStorageManager.shared
        XCTAssertEqual(manager.getAPIKey(for: .mistralVoxtral), testValue)
        
        // Clear through configuration
        config.apiKey = nil
        XCTAssertFalse(config.hasValidAPIKey)
        XCTAssertNil(config.apiKey)
    }
    
    // MARK: - Security Tests
    
    func testKeychainSecurity() throws {
        @SecureStorage("security_test_key") var secureKey: String?
        
        // Set a sensitive value
        let sensitiveData = "super_secret_api_key_with_special_chars!@#$%"
        secureKey = sensitiveData
        
        // Verify it can be retrieved correctly
        XCTAssertEqual(secureKey, sensitiveData)
        
        // Verify it's actually stored in keychain (not in UserDefaults)
        XCTAssertNil(UserDefaults.standard.string(forKey: "security_test_key"))
        
        // Clear it
        secureKey = nil
        XCTAssertNil(secureKey)
    }
    
    func testKeychainMultipleKeys() throws {
        @SecureStorage("key1") var key1: String?
        @SecureStorage("key2") var key2: String?
        
        // Set different values
        key1 = "value1"
        key2 = "value2"
        
        // Verify they don't interfere with each other
        XCTAssertEqual(key1, "value1")
        XCTAssertEqual(key2, "value2")
        
        // Clear one, other should remain
        key1 = nil
        XCTAssertNil(key1)
        XCTAssertEqual(key2, "value2")
    }
    
    // MARK: - Error Handling Tests
    
    func testKeychainErrorHandling() throws {
        // This test is more about ensuring no crashes occur during keychain operations
        @SecureStorage("error_test_key") var testKey: String?
        
        // These operations should not throw or crash
        XCTAssertNoThrow(testKey = "test")
        XCTAssertNoThrow(_ = testKey)
        XCTAssertNoThrow(testKey = nil)
        XCTAssertNoThrow(_ = testKey.hasValue)
    }
    
    // MARK: - Helper Methods
    
    private func clearTestKeychain() {
        // Clear any test keys from keychain
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: testService
        ]
        SecItemDelete(query as CFDictionary)
        
        // Also clear the main service keys used by the app
        SecureStorageManager.shared.clearAllAPIKeys()
    }
}