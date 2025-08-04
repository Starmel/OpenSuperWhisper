//
//  MistralVoxtralProviderTests.swift
//  OpenSuperWhisperTests
//
//  Created by Claude on 03.08.2025.
//

import XCTest
import AVFoundation
@testable import OpenSuperWhisper

final class MistralVoxtralProviderTests: XCTestCase {
    
    private var provider: MistralVoxtralProvider!
    private var testAudioURL: URL!
    
    override func setUpWithError() throws {
        // Create provider with test configuration
        var config = MistralVoxtralConfiguration()
        config.endpoint = "https://api.mistral.ai/v1/audio/transcriptions"
        config.model = "voxtral-mini-latest"
        config.maxRetries = 2
        config.timeoutInterval = 30.0
        
        provider = MistralVoxtralProvider(configuration: config)
        
        // Set up test audio URL
        testAudioURL = Bundle(for: type(of: self)).url(forResource: "test_audio", withExtension: "m4a")
        
        // Clear any existing API keys
        SecureStorageManager.shared.clearAllAPIKeys()
    }
    
    override func tearDownWithError() throws {
        SecureStorageManager.shared.clearAllAPIKeys()
    }
    
    // MARK: - Provider Identity Tests
    
    func testProviderIdentity() async throws {
        XCTAssertEqual(await provider.id, .mistralVoxtral)
        XCTAssertEqual(await provider.displayName, "Mistral Voxtral")
    }
    
    func testProviderSupportedLanguages() async throws {
        let languages = await provider.supportedLanguages
        
        XCTAssertTrue(languages.contains("auto"))
        XCTAssertTrue(languages.contains("en"))
        XCTAssertTrue(languages.contains("es"))
        XCTAssertTrue(languages.contains("fr"))
        XCTAssertTrue(languages.contains("de"))
    }
    
    func testProviderSupportedFeatures() async throws {
        let features = await provider.supportedFeatures()
        
        XCTAssertTrue(features.contains(.timestampSupport))
        XCTAssertTrue(features.contains(.languageDetection))
        XCTAssertFalse(features.contains(.realTimeProgress)) // Not supported by cloud providers
    }
    
    // MARK: - Configuration Management Tests
    
    func testConfigurationManagement() async throws {
        let originalConfig = await provider.configuration as! MistralVoxtralConfiguration
        
        var newConfig = MistralVoxtralConfiguration()
        newConfig.endpoint = "https://custom.endpoint.com"
        newConfig.model = "custom-model"
        newConfig.maxRetries = 5
        
        await provider.setConfiguration(newConfig)
        
        let updatedConfig = await provider.configuration as! MistralVoxtralConfiguration
        XCTAssertEqual(updatedConfig.endpoint, "https://custom.endpoint.com")
        XCTAssertEqual(updatedConfig.model, "custom-model")
        XCTAssertEqual(updatedConfig.maxRetries, 5)
        
        // Restore original
        await provider.setConfiguration(originalConfig)
    }
    
    func testIsConfiguredWithoutAPIKey() async throws {
        // Without API key, should not be configured
        XCTAssertFalse(await provider.isConfigured)
    }
    
    func testIsConfiguredWithAPIKey() async throws {
        SecureStorageManager.shared.setAPIKey("test_api_key", for: .mistralVoxtral)
        
        // Update provider configuration to reflect API key
        var config = MistralVoxtralConfiguration()
        config.isEnabled = true
        await provider.setConfiguration(config)
        
        XCTAssertTrue(await provider.isConfigured)
    }
    
    // MARK: - Validation Tests
    
    func testValidationWithoutAPIKey() async throws {
        let result = try await provider.validateConfiguration()
        
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains { error in
            if case .missingApiKey = error { return true }
            return false
        })
    }
    
    func testValidationWithInvalidAPIKeyFormat() async throws {
        SecureStorageManager.shared.setAPIKey("invalid", for: .mistralVoxtral)
        
        let result = try await provider.validateConfiguration()
        
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.errors.contains { error in
            if case .invalidApiKey = error { return true }
            return false
        })
    }
    
    func testValidationWithValidAPIKeyFormat() async throws {
        SecureStorageManager.shared.setAPIKey("valid_api_key_with_sufficient_length", for: .mistralVoxtral)
        
        let result = try await provider.validateConfiguration()
        
        // Should pass basic validation (though network test may fail in test environment)
        let hasMissingKeyError = result.errors.contains { error in
            if case .missingApiKey = error { return true }
            return false
        }
        let hasInvalidKeyError = result.errors.contains { error in
            if case .invalidApiKey = error { return true }
            return false
        }
        
        XCTAssertFalse(hasMissingKeyError)
        XCTAssertFalse(hasInvalidKeyError)
    }
    
    // MARK: - Audio File Validation Tests
    
    func testAudioFileValidation() async throws {
        // Skip if no test audio file
        guard testAudioURL != nil else {
            throw XCTSkip("Test audio file not found")
        }
        
        // Should not throw for valid audio file
        XCTAssertNoThrow(try await provider.validateAudioFile(url: testAudioURL))
    }
    
    func testAudioFileValidationInvalidURL() async throws {
        let invalidURL = URL(fileURLWithPath: "/nonexistent/file.mp3")
        
        do {
            try await provider.validateAudioFile(url: invalidURL)
            XCTFail("Should have thrown error for invalid URL")
        } catch {
            XCTAssertTrue(error is TranscriptionError)
        }
    }
    
    func testAudioFileValidationNonAudioFile() async throws {
        // Create a temporary non-audio file
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test.txt")
        try "This is not audio".write(to: tempURL, atomically: true, encoding: .utf8)
        
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }
        
        do {
            try await provider.validateAudioFile(url: tempURL)
            XCTFail("Should have thrown error for non-audio file")
        } catch {
            XCTAssertTrue(error is TranscriptionError)
        }
    }
    
    // MARK: - Error Handling Tests
    
    func testTranscriptionWithoutAPIKey() async throws {
        // Skip if no test audio file
        guard testAudioURL != nil else {
            throw XCTSkip("Test audio file not found")
        }
        
        let settings = TranscriptionSettings()
        
        do {
            _ = try await provider.transcribe(audioURL: testAudioURL, settings: settings)
            XCTFail("Should have failed without API key")
        } catch {
            XCTAssertTrue(error is TranscriptionError)
            if let transcriptionError = error as? TranscriptionError {
                switch transcriptionError {
                case .providerNotConfigured:
                    break // Expected
                default:
                    XCTFail("Expected providerNotConfigured error, got \(transcriptionError)")
                }
            }
        }
    }
    
    func testTranscriptionWithInvalidURL() async throws {
        SecureStorageManager.shared.setAPIKey("test_api_key", for: .mistralVoxtral)
        
        let invalidURL = URL(fileURLWithPath: "/nonexistent/file.mp3")
        let settings = TranscriptionSettings()
        
        do {
            _ = try await provider.transcribe(audioURL: invalidURL, settings: settings)
            XCTFail("Should have failed with invalid URL")
        } catch {
            XCTAssertTrue(error is TranscriptionError)
        }
    }
    
    // MARK: - HTTP Response Handling Tests
    
    func testHTTPResponseHandling200() throws {
        let response = HTTPURLResponse(
            url: URL(string: "https://api.mistral.ai")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        
        // Should not throw for 2xx responses
        XCTAssertNoThrow(try provider.handleHTTPResponse(response, data: Data()))
    }
    
    func testHTTPResponseHandling401() throws {
        let response = HTTPURLResponse(
            url: URL(string: "https://api.mistral.ai")!,
            statusCode: 401,
            httpVersion: nil,
            headerFields: nil
        )!
        
        do {
            try provider.handleHTTPResponse(response, data: Data())
            XCTFail("Should have thrown for 401")
        } catch {
            if let transcriptionError = error as? TranscriptionError {
                switch transcriptionError {
                case .apiKeyInvalid:
                    break // Expected
                default:
                    XCTFail("Expected apiKeyInvalid error, got \(transcriptionError)")
                }
            }
        }
    }
    
    func testHTTPResponseHandling402() throws {
        let response = HTTPURLResponse(
            url: URL(string: "https://api.mistral.ai")!,
            statusCode: 402,
            httpVersion: nil,
            headerFields: nil
        )!
        
        do {
            try provider.handleHTTPResponse(response, data: Data())
            XCTFail("Should have thrown for 402")
        } catch {
            if let transcriptionError = error as? TranscriptionError {
                switch transcriptionError {
                case .quotaExceeded:
                    break // Expected
                default:
                    XCTFail("Expected quotaExceeded error, got \(transcriptionError)")
                }
            }
        }
    }
    
    func testHTTPResponseHandling413() throws {
        let response = HTTPURLResponse(
            url: URL(string: "https://api.mistral.ai")!,
            statusCode: 413,
            httpVersion: nil,
            headerFields: nil
        )!
        
        do {
            try provider.handleHTTPResponse(response, data: Data())
            XCTFail("Should have thrown for 413")
        } catch {
            if let transcriptionError = error as? TranscriptionError {
                switch transcriptionError {
                case .fileTooBig:
                    break // Expected
                default:
                    XCTFail("Expected fileTooBig error, got \(transcriptionError)")
                }
            }
        }
    }
    
    func testHTTPResponseHandling429() throws {
        let response = HTTPURLResponse(
            url: URL(string: "https://api.mistral.ai")!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: nil
        )!
        
        do {
            try provider.handleHTTPResponse(response, data: Data())
            XCTFail("Should have thrown for 429")
        } catch {
            if let transcriptionError = error as? TranscriptionError {
                switch transcriptionError {
                case .quotaExceeded:
                    break // Expected
                default:
                    XCTFail("Expected quotaExceeded error, got \(transcriptionError)")
                }
            }
        }
    }
    
    func testHTTPResponseHandling500() throws {
        let response = HTTPURLResponse(
            url: URL(string: "https://api.mistral.ai")!,
            statusCode: 500,
            httpVersion: nil,
            headerFields: nil
        )!
        
        do {
            try provider.handleHTTPResponse(response, data: Data())
            XCTFail("Should have thrown for 500")
        } catch {
            if let transcriptionError = error as? TranscriptionError {
                switch transcriptionError {
                case .providerUnavailable:
                    break // Expected
                default:
                    XCTFail("Expected providerUnavailable error, got \(transcriptionError)")
                }
            }
        }
    }
    
    // MARK: - Response Parsing Tests
    
    func testParseValidTranscriptionResponse() throws {
        let responseDict: [String: Any] = [
            "text": "Hello, this is a test transcription."
        ]
        
        let jsonData = try JSONSerialization.data(withJSONObject: responseDict)
        
        let result = try provider.parseTranscriptionResponse(jsonData)
        XCTAssertEqual(result, "Hello, this is a test transcription.")
    }
    
    func testParseEmptyTranscriptionResponse() throws {
        let responseDict: [String: Any] = [
            "text": ""
        ]
        
        let jsonData = try JSONSerialization.data(withJSONObject: responseDict)
        
        let result = try provider.parseTranscriptionResponse(jsonData)
        XCTAssertEqual(result, "No speech detected in the audio")
    }
    
    func testParseWhitespaceTranscriptionResponse() throws {
        let responseDict: [String: Any] = [
            "text": "   \n\t  "
        ]
        
        let jsonData = try JSONSerialization.data(withJSONObject: responseDict)
        
        let result = try provider.parseTranscriptionResponse(jsonData)
        XCTAssertEqual(result, "No speech detected in the audio")
    }
    
    func testParseInvalidJSONResponse() throws {
        let invalidJSON = "{ invalid json }".data(using: .utf8)!
        
        do {
            _ = try provider.parseTranscriptionResponse(invalidJSON)
            XCTFail("Should have thrown for invalid JSON")
        } catch {
            XCTAssertTrue(error is TranscriptionError)
            if let transcriptionError = error as? TranscriptionError {
                switch transcriptionError {
                case .audioProcessingError:
                    break // Expected
                default:
                    XCTFail("Expected audioProcessingError, got \(transcriptionError)")
                }
            }
        }
    }
    
    func testParseMissingTextFieldResponse() throws {
        let responseDict: [String: Any] = [
            "status": "success"
            // Missing "text" field
        ]
        
        let jsonData = try JSONSerialization.data(withJSONObject: responseDict)
        
        do {
            _ = try provider.parseTranscriptionResponse(jsonData)
            XCTFail("Should have thrown for missing text field")
        } catch {
            XCTAssertTrue(error is TranscriptionError)
            if let transcriptionError = error as? TranscriptionError {
                switch transcriptionError {
                case .audioProcessingError:
                    break // Expected
                default:
                    XCTFail("Expected audioProcessingError, got \(transcriptionError)")
                }
            }
        }
    }
    
    // MARK: - MIME Type Tests
    
    func testGetMimeTypeForCommonFormats() async throws {
        let testCases: [(String, String)] = [
            ("test.wav", "audio/wav"),
            ("test.mp3", "audio/mpeg"),
            ("test.m4a", "audio/mp4"),
            ("test.aac", "audio/aac"),
            ("test.flac", "audio/flac"),
            ("test.ogg", "audio/ogg"),
            ("test.unknown", "audio/wav") // Default fallback
        ]
        
        for (filename, expectedMimeType) in testCases {
            let url = URL(fileURLWithPath: filename)
            let mimeType = await provider.getMimeType(for: url)
            XCTAssertEqual(mimeType, expectedMimeType, "Failed for \(filename)")
        }
    }
    
    // MARK: - API Key Format Validation Tests
    
    func testAPIKeyFormatValidation() async throws {
        // Valid key formats
        XCTAssertTrue(await provider.isValidMistralAPIKeyFormat("valid_api_key_123"))
        XCTAssertTrue(await provider.isValidMistralAPIKeyFormat("abcdefghijklmnop"))
        
        // Invalid key formats
        XCTAssertFalse(await provider.isValidMistralAPIKeyFormat(""))
        XCTAssertFalse(await provider.isValidMistralAPIKeyFormat("   "))
        XCTAssertFalse(await provider.isValidMistralAPIKeyFormat("short"))
        XCTAssertFalse(await provider.isValidMistralAPIKeyFormat("   valid_key   ")) // Should be trimmed and pass
    }
    
    // MARK: - Multipart Form Data Tests
    
    func testCreateMultipartFormData() async throws {
        // Skip if no test audio file
        guard testAudioURL != nil else {
            throw XCTSkip("Test audio file not found")
        }
        
        let settings = TranscriptionSettings()
        settings.selectedLanguage = "en"
        settings.showTimestamps = true
        
        let boundary = "test-boundary"
        
        let formData = try await provider.createMultipartFormData(
            audioURL: testAudioURL,
            settings: settings,
            boundary: boundary
        )
        
        let formDataString = String(data: formData, encoding: .utf8)!
        
        // Check that form data contains expected fields
        XCTAssertTrue(formDataString.contains("--\(boundary)"))
        XCTAssertTrue(formDataString.contains("name=\"model\""))
        XCTAssertTrue(formDataString.contains("name=\"language\""))
        XCTAssertTrue(formDataString.contains("name=\"timestamp_granularities[]\""))
        XCTAssertTrue(formDataString.contains("name=\"file\""))
        XCTAssertTrue(formDataString.contains("voxtral-mini-latest"))
        XCTAssertTrue(formDataString.contains("en"))
        XCTAssertTrue(formDataString.contains("segment"))
    }
    
    // MARK: - Progress Callback Tests
    
    func testProgressCallbackExecution() async throws {
        // Skip if no test audio file
        guard testAudioURL != nil else {
            throw XCTSkip("Test audio file not found")
        }
        
        SecureStorageManager.shared.setAPIKey("test_api_key_for_progress", for: .mistralVoxtral)
        
        let settings = TranscriptionSettings()
        var progressUpdates: [TranscriptionProgress] = []
        
        let progressCallback: (TranscriptionProgress) -> Void = { progress in
            progressUpdates.append(progress)
        }
        
        do {
            _ = try await provider.transcribe(
                audioURL: testAudioURL,
                settings: settings,
                progressCallback: progressCallback
            )
        } catch {
            // Expected to fail in test environment, but we should still have progress updates
        }
        
        // Should have received at least one progress update
        XCTAssertFalse(progressUpdates.isEmpty)
        
        // First update should have 0% progress
        if let firstUpdate = progressUpdates.first {
            XCTAssertEqual(firstUpdate.percentage, 0.0)
        }
    }
}