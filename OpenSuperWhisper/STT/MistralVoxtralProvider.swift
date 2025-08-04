import Foundation
import AVFoundation

// MARK: - Mistral Voxtral STT Provider

/// Mistral Voxtral cloud-based STT provider implementation
actor MistralVoxtralProvider: STTProvider {
    
    // MARK: - STTProvider Protocol Conformance
    
    let id: STTProviderType = .mistralVoxtral
    let displayName: String = "Mistral Voxtral"
    
    var configuration: STTProviderConfiguration {
        get { _configuration }
        set { 
            if let mistralConfig = newValue as? MistralVoxtralConfiguration {
                _configuration = mistralConfig
            }
        }
    }
    
    var isConfigured: Bool {
        return _configuration.hasValidAPIKey && _configuration.isEnabled
    }
    
    var supportedLanguages: [String] {
        // Mistral Voxtral supports multiple languages
        return [
            "auto", "en", "es", "fr", "de", "it", "pt", "ru", "ja", "ko", "zh", 
            "ar", "hi", "tr", "pl", "nl", "sv", "da", "no", "fi", "cs", "sk",
            "hu", "ro", "bg", "hr", "sl", "et", "lv", "lt", "mt", "ga", "cy"
        ]
    }
    
    // MARK: - Private Properties
    
    private var _configuration: MistralVoxtralConfiguration
    private let session: URLSession
    private let maxFileSizeBytes: Int
    
    // MARK: - Initialization
    
    init(configuration: MistralVoxtralConfiguration = MistralVoxtralConfiguration()) {
        self._configuration = configuration
        self.maxFileSizeBytes = configuration.maxFileSizeMB * 1024 * 1024 // Convert MB to bytes
        
        // Configure URLSession with appropriate timeout and retry settings
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = configuration.timeoutInterval
        sessionConfig.timeoutIntervalForResource = configuration.timeoutInterval * 2
        sessionConfig.requestCachePolicy = .reloadIgnoringLocalCacheData
        
        self.session = URLSession(configuration: sessionConfig)
    }
    
    // MARK: - Core Transcription Methods
    
    func transcribe(audioURL: URL, settings: TranscriptionSettings) async throws -> String {
        return try await transcribe(audioURL: audioURL, settings: settings) { _ in }
    }
    
    func transcribe(
        audioURL: URL,
        settings: TranscriptionSettings,
        progressCallback: @escaping (TranscriptionProgress) -> Void
    ) async throws -> String {
        
        // Validate configuration 
        let validationResult = try await validateConfiguration()
        guard validationResult.isValid else {
            throw TranscriptionError.providerNotConfigured(.mistralVoxtral)
        }
        
        // Check file size
        try await validateAudioFile(url: audioURL)
        
        // Report initial progress
        progressCallback(TranscriptionProgress(
            percentage: 0.0,
            currentSegment: "Preparing audio for upload...",
            timestamp: 0.0,
            estimatedTimeRemaining: nil
        ))
        
        // Perform transcription with retry logic
        do {
            let result = try await performTranscriptionWithRetry(
                audioURL: audioURL,
                settings: settings,
                progressCallback: progressCallback
            )
            return result
        } catch {
            throw error
        }
    }
    
    // MARK: - Configuration Validation
    
    func validateConfiguration() async throws -> ValidationResult {
        var errors: [ValidationError] = []
        var warnings: [ValidationWarning] = []
        
        // Check API key
        guard let apiKey = _configuration.apiKey, !apiKey.isEmpty else {
            errors.append(.missingApiKey)
            return ValidationResult(isValid: false, errors: errors, warnings: warnings)
        }
        
        // Validate API key format (basic validation)
        if !isValidMistralAPIKeyFormat(apiKey) {
            errors.append(.invalidApiKey)
            return ValidationResult(isValid: false, errors: errors, warnings: warnings)
        }
        
        // Test network connectivity and API key validity
        do {
            try await testAPIConnectivity()
        } catch {
            if let transcriptionError = error as? TranscriptionError {
                switch transcriptionError {
                case .apiKeyInvalid:
                    errors.append(.invalidApiKey)
                case .networkError:
                    errors.append(.networkUnreachable)
                default:
                    warnings.append(.networkSlowConnection)
                }
            } else {
                errors.append(.networkUnreachable)
            }
        }
        
        // Check for potential high latency
        if _configuration.timeoutInterval > 30 {
            warnings.append(.highLatencyExpected)
        }
        
        let result = ValidationResult(
            isValid: errors.isEmpty,
            errors: errors,
            warnings: warnings
        )
        
        return result
    }
    
    // MARK: - Supported Features
    
    func supportedFeatures() -> Set<STTFeature> {
        return [
            .timestampSupport,
            .languageDetection
            // Note: Real-time progress is limited for cloud providers
            // Other features like translation may be added in future Mistral updates
        ]
    }
    
    // MARK: - Private Implementation
    
    private func validateAudioFile(url: URL) async throws {
        let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        
        if fileSize > maxFileSizeBytes {
            throw TranscriptionError.fileTooBig(maxSize: maxFileSizeBytes)
        }
        
        // Validate audio format
        let asset = AVAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        
        guard !tracks.isEmpty else {
            throw TranscriptionError.audioProcessingError(
                NSError(domain: "MistralVoxtralProvider", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "No audio tracks found in file"
                ])
            )
        }
    }
    
    private func performTranscriptionWithRetry(
        audioURL: URL,
        settings: TranscriptionSettings,
        progressCallback: @escaping (TranscriptionProgress) -> Void
    ) async throws -> String {
        
        var lastError: Error?
        
        for attempt in 1..._configuration.maxRetries {
            do {
                progressCallback(TranscriptionProgress(
                    percentage: 0.1,
                    currentSegment: "Uploading audio (attempt \(attempt))...",
                    timestamp: 0.0,
                    estimatedTimeRemaining: nil
                ))
                
                return try await performTranscription(
                    audioURL: audioURL,
                    settings: settings,
                    progressCallback: progressCallback
                )
                
            } catch {
                lastError = error
                
                // Don't retry on certain errors
                if case TranscriptionError.apiKeyInvalid = error {
                    throw error
                }
                if case TranscriptionError.fileTooBig = error {
                    throw error
                }
                if case TranscriptionError.unsupportedLanguage = error {
                    throw error
                }
                
                // Wait before retry (exponential backoff)
                if attempt < _configuration.maxRetries {
                    let backoffTime = min(pow(2.0, Double(attempt)), 10.0)
                    try await Task.sleep(nanoseconds: UInt64(backoffTime * 1_000_000_000))
                }
            }
        }
        
        throw lastError ?? TranscriptionError.networkError(
            NSError(domain: "MistralVoxtralProvider", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Maximum retry attempts exceeded"
            ])
        )
    }
    
    private func performTranscription(
        audioURL: URL,
        settings: TranscriptionSettings,
        progressCallback: @escaping (TranscriptionProgress) -> Void
    ) async throws -> String {
        
        guard let apiKey = _configuration.apiKey else {
            throw TranscriptionError.apiKeyInvalid
        }
        
        // Create multipart form request
        let request = try await createTranscriptionRequest(
            audioURL: audioURL,
            settings: settings,
            apiKey: apiKey
        )
        
        progressCallback(TranscriptionProgress(
            percentage: 0.3,
            currentSegment: "Sending request to Mistral API...",
            timestamp: 0.0,
            estimatedTimeRemaining: nil
        ))
        
        // Perform the request
        let (data, response) = try await session.data(for: request)
        
        progressCallback(TranscriptionProgress(
            percentage: 0.8,
            currentSegment: "Processing response...",
            timestamp: 0.0,
            estimatedTimeRemaining: nil
        ))
        
        // Handle response
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.networkError(
                NSError(domain: "MistralVoxtralProvider", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Invalid response type"
                ])
            )
        }
        
        try handleHTTPResponse(httpResponse, data: data)
        
        // Parse transcription result
        let transcriptionResult = try parseTranscriptionResponse(data)
        
        progressCallback(TranscriptionProgress(
            percentage: 1.0,
            currentSegment: "Transcription completed",
            timestamp: 0.0,
            estimatedTimeRemaining: nil
        ))
        
        return transcriptionResult
    }
    
    private func createTranscriptionRequest(
        audioURL: URL,
        settings: TranscriptionSettings,
        apiKey: String
    ) async throws -> URLRequest {
        
        guard let url = URL(string: _configuration.endpoint) else {
            throw TranscriptionError.networkError(
                NSError(domain: "MistralVoxtralProvider", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Invalid endpoint URL"
                ])
            )
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        
        // Create multipart form data
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        let httpBody = try await createMultipartFormData(
            audioURL: audioURL,
            settings: settings,
            boundary: boundary
        )
        
        request.httpBody = httpBody
        
        // Log request details
        print("🔧 DEBUG: Request URL: \(request.url?.absoluteString ?? "nil")")
        print("🔧 DEBUG: Request method: \(request.httpMethod ?? "nil")")
        print("🔧 DEBUG: Request headers:")
        if let headers = request.allHTTPHeaderFields {
            for (key, value) in headers {
                if key.lowercased() == "x-api-key" {
                    print("🔧 DEBUG:   \(key): \(String(value.prefix(8)))...")
                } else {
                    print("🔧 DEBUG:   \(key): \(value)")
                }
            }
        }
        print("🔧 DEBUG: Request body size: \(httpBody.count) bytes")
        
        return request
    }
    
    private func createMultipartFormData(
        audioURL: URL,
        settings: TranscriptionSettings,
        boundary: String
    ) async throws -> Data {
        
        var formData = Data()
        let lineBreak = "\r\n"
        
        print("🔧 DEBUG: Creating multipart form data:")
        print("🔧 DEBUG: Endpoint: \(_configuration.endpoint)")
        print("🔧 DEBUG: Model: \(_configuration.model)")
        print("🔧 DEBUG: Language: \(settings.selectedLanguage)")
        print("🔧 DEBUG: Show timestamps: \(settings.showTimestamps)")
        
        // Add model parameter
        formData.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
        formData.append("Content-Disposition: form-data; name=\"model\"\(lineBreak)\(lineBreak)".data(using: .utf8)!)
        formData.append("\(_configuration.model)\(lineBreak)".data(using: .utf8)!)
        
        // Add language parameter if specified and not auto
        if settings.selectedLanguage != "auto" && supportedLanguages.contains(settings.selectedLanguage) {
            formData.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
            formData.append("Content-Disposition: form-data; name=\"language\"\(lineBreak)\(lineBreak)".data(using: .utf8)!)
            formData.append("\(settings.selectedLanguage)\(lineBreak)".data(using: .utf8)!)
        }
        
        // Add timestamp granularities if timestamps are requested
        if settings.showTimestamps {
            formData.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
            formData.append("Content-Disposition: form-data; name=\"timestamp_granularities[]\"\(lineBreak)\(lineBreak)".data(using: .utf8)!)
            formData.append("segment\(lineBreak)".data(using: .utf8)!)
        }
        
        // Add audio file
        let audioData = try Data(contentsOf: audioURL)
        let filename = audioURL.lastPathComponent
        let mimeType = getMimeType(for: audioURL)
        
        formData.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
        formData.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\(lineBreak)".data(using: .utf8)!)
        formData.append("Content-Type: \(mimeType)\(lineBreak)\(lineBreak)".data(using: .utf8)!)
        formData.append(audioData)
        formData.append("\(lineBreak)".data(using: .utf8)!)
        
        // End boundary
        formData.append("--\(boundary)--\(lineBreak)".data(using: .utf8)!)
        
        // Log the complete multipart structure (without binary audio data)
        if let formString = String(data: formData, encoding: .utf8) {
            let audioDataPattern = #"Content-Type: audio/.*?\r\n\r\n[\s\S]*?(\r\n--)"#
            let logString = formString.replacingOccurrences(
                of: audioDataPattern,
                with: "Content-Type: audio/wav\r\n\r\n[BINARY AUDIO DATA - \(try! Data(contentsOf: audioURL).count) bytes]\r\n--",
                options: .regularExpression
            )
            print("🔧 DEBUG: Complete multipart form data:")
            print(logString)
        }
        
        return formData
    }
    
    private func handleHTTPResponse(_ response: HTTPURLResponse, data: Data) throws {
        switch response.statusCode {
        case 200...299:
            return // Success
            
        case 401:
            throw TranscriptionError.apiKeyInvalid
            
        case 402:
            throw TranscriptionError.quotaExceeded
            
        case 413:
            throw TranscriptionError.fileTooBig(maxSize: maxFileSizeBytes)
            
        case 422:
            // Parse error response for more details
            if let errorResponse = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = errorResponse["error"] as? [String: Any],
               let message = error["message"] as? String {
                if message.lowercased().contains("language") {
                    throw TranscriptionError.unsupportedLanguage("Specified language not supported")
                }
                throw TranscriptionError.audioProcessingError(
                    NSError(domain: "MistralVoxtralProvider", code: response.statusCode, userInfo: [
                        NSLocalizedDescriptionKey: message
                    ])
                )
            }
            throw TranscriptionError.audioProcessingError(
                NSError(domain: "MistralVoxtralProvider", code: response.statusCode, userInfo: [
                    NSLocalizedDescriptionKey: "Unprocessable entity"
                ])
            )
            
        case 429:
            throw TranscriptionError.quotaExceeded
            
        case 500...599:
            throw TranscriptionError.providerUnavailable(.mistralVoxtral)
            
        default:
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw TranscriptionError.networkError(
                NSError(domain: "MistralVoxtralProvider", code: response.statusCode, userInfo: [
                    NSLocalizedDescriptionKey: "HTTP \(response.statusCode): \(errorMessage)"
                ])
            )
        }
    }
    
    private func parseTranscriptionResponse(_ data: Data) throws -> String {
        guard let responseDict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscriptionError.audioProcessingError(
                NSError(domain: "MistralVoxtralProvider", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Invalid JSON response"
                ])
            )
        }
        
        guard let text = responseDict["text"] as? String else {
            throw TranscriptionError.audioProcessingError(
                NSError(domain: "MistralVoxtralProvider", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Missing text field in response"
                ])
            )
        }
        
        // Handle empty or whitespace-only results
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedText.isEmpty ? "No speech detected in the audio" : trimmedText
    }
    
    private func testAPIConnectivity() async throws {
        // Create a minimal test request to validate API key and connectivity
        guard let apiKey = _configuration.apiKey,
              let url = URL(string: _configuration.endpoint) else {
            throw TranscriptionError.networkError(
                NSError(domain: "MistralVoxtralProvider", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Invalid configuration"
                ])
            )
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("multipart/form-data; boundary=test", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10.0 // Short timeout for connectivity test
        
        // Send minimal invalid request to test auth (expect 400/422, not 401)
        let testBody = "--test\r\n--test--\r\n".data(using: .utf8)!
        request.httpBody = testBody
        
        do {
            let (_, response) = try await session.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                switch httpResponse.statusCode {
                case 401:
                    throw TranscriptionError.apiKeyInvalid
                case 400, 422:
                    return // API key is valid, request format is invalid (expected)
                case 200...299:
                    return // Unexpected success
                default:
                    return // Other errors are likely not auth-related
                }
            }
        } catch is CancellationError {
            throw TranscriptionError.networkError(
                NSError(domain: "MistralVoxtralProvider", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Network request timeout"
                ])
            )
        } catch {
            throw TranscriptionError.networkError(error)
        }
    }
    
    private func isValidMistralAPIKeyFormat(_ apiKey: String) -> Bool {
        // Basic validation for Mistral API key format
        // Mistral API keys typically start with a prefix and have a specific length
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedKey.isEmpty && trimmedKey.count > 10
    }
    
    private func getMimeType(for url: URL) -> String {
        let pathExtension = url.pathExtension.lowercased()
        switch pathExtension {
        case "wav":
            return "audio/wav"
        case "mp3":
            return "audio/mpeg"
        case "m4a":
            return "audio/mp4"
        case "aac":
            return "audio/aac"
        case "flac":
            return "audio/flac"
        case "ogg":
            return "audio/ogg"
        default:
            return "audio/wav" // Default fallback
        }
    }
}

// MARK: - Response Models

private struct MistralTranscriptionResponse: Codable {
    let text: String
    let segments: [MistralSegment]?
}

private struct MistralSegment: Codable {
    let id: Int
    let seek: Double
    let start: Double
    let end: Double
    let text: String
    let tokens: [Int]
    let temperature: Double
    let avgLogprob: Double
    let compressionRatio: Double
    let noSpeechProb: Double
    
    private enum CodingKeys: String, CodingKey {
        case id, seek, start, end, text, tokens, temperature
        case avgLogprob = "avg_logprob"
        case compressionRatio = "compression_ratio"
        case noSpeechProb = "no_speech_prob"
    }
}
