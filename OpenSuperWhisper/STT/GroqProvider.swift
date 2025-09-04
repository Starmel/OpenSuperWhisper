import Foundation
import AVFoundation

// MARK: - Groq STT Provider

/// Groq cloud-based STT provider implementation using Whisper models
/// 
/// Key Features:
/// - Fastest speech-to-text available (189-216x real-time speed)
/// - Automatic audio preprocessing (downsampled to 16kHz mono)
/// - Word and segment-level timestamps
/// - Minimum billing: 10 seconds (shorter audio still billed for 10s)
/// - File size limits: 25MB (free tier), 100MB (dev tier)
actor GroqProvider: STTProvider {
    
    // MARK: - STTProvider Protocol Conformance
    
    let id: STTProviderType = .groq
    let displayName: String = "Groq Whisper"
    
    var configuration: STTProviderConfiguration {
        get { _configuration }
        set { 
            if let groqConfig = newValue as? GroqConfiguration {
                _configuration = groqConfig
            }
        }
    }
    
    var isConfigured: Bool {
        return _configuration.hasValidAPIKey && _configuration.isEnabled
    }
    
    var supportedLanguages: [String] {
        // Groq uses Whisper models which support multiple languages
        return [
            "auto", "en", "es", "fr", "de", "it", "pt", "ru", "ja", "ko", "zh", 
            "ar", "hi", "tr", "pl", "nl", "sv", "da", "no", "fi", "cs", "sk",
            "hu", "ro", "bg", "hr", "sl", "et", "lv", "lt", "mt", "ga", "cy"
        ]
    }
    
    // MARK: - Private Properties
    
    private var _configuration: GroqConfiguration
    private let session: URLSession
    private let maxFileSizeBytes: Int
    
    // MARK: - Initialization
    
    init(configuration: GroqConfiguration = GroqConfiguration()) {
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
            throw TranscriptionError.providerNotConfigured(.groq)
        }
        
        // Check file size
        try await validateAudioFile(url: audioURL)
        
        // Report initial progress
        progressCallback(TranscriptionProgress(
            percentage: 0.0,
            currentSegment: "Preparing audio for Groq API...",
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
        if !isValidGroqAPIKeyFormat(apiKey) {
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
        var features: Set<STTFeature> = [
            .timestampSupport,
            .languageDetection,
            .customPrompts
            // Note: Real-time progress is limited for cloud providers
            // Groq supports both segment and word-level timestamps
        ]
        
        // Only whisper-large-v3 supports translation, turbo model does NOT
        if _configuration.model == "whisper-large-v3" {
            features.insert(.translation)
        }
        
        return features
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
                NSError(domain: "GroqProvider", code: -1, userInfo: [
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
                    currentSegment: "Uploading audio to Groq (attempt \(attempt))...",
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
            NSError(domain: "GroqProvider", code: -1, userInfo: [
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
            currentSegment: "Sending request to Groq API...",
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
                NSError(domain: "GroqProvider", code: -1, userInfo: [
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
                NSError(domain: "GroqProvider", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Invalid endpoint URL"
                ])
            )
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        
        // Create multipart form data
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        let httpBody = try await createMultipartFormData(
            audioURL: audioURL,
            settings: settings,
            boundary: boundary
        )
        
        request.httpBody = httpBody
        
        // Log request details (only in debug builds)
        #if DEBUG
        print("🚀 DEBUG: Groq Request URL: \(request.url?.absoluteString ?? "nil")")
        print("🚀 DEBUG: Request method: \(request.httpMethod ?? "nil")")
        print("🚀 DEBUG: Request headers:")
        if let headers = request.allHTTPHeaderFields {
            for (key, value) in headers {
                if key.lowercased() == "authorization" {
                    print("🚀 DEBUG:   \(key): Bearer \(String(apiKey.prefix(8)))...")
                } else {
                    print("🚀 DEBUG:   \(key): \(value)")
                }
            }
        }
        print("🚀 DEBUG: Request body size: \(httpBody.count) bytes")
        #endif
        
        return request
    }
    
    private func createMultipartFormData(
        audioURL: URL,
        settings: TranscriptionSettings,
        boundary: String
    ) async throws -> Data {
        
        var formData = Data()
        let lineBreak = "\r\n"
        
        #if DEBUG
        print("🚀 DEBUG: Creating multipart form data for Groq:")
        print("🚀 DEBUG: Endpoint: \(_configuration.endpoint)")
        print("🚀 DEBUG: Model: \(_configuration.model)")
        print("🚀 DEBUG: Language: \(settings.selectedLanguage)")
        print("🚀 DEBUG: Show timestamps: \(settings.showTimestamps)")
        print("🚀 DEBUG: Initial prompt: \(settings.initialPrompt)")
        #endif
        
        // Add model parameter (required)
        formData.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
        formData.append("Content-Disposition: form-data; name=\"model\"\(lineBreak)\(lineBreak)".data(using: .utf8)!)
        formData.append("\(_configuration.model)\(lineBreak)".data(using: .utf8)!)
        
        // Add language parameter if specified and not auto
        if settings.selectedLanguage != "auto" && supportedLanguages.contains(settings.selectedLanguage) {
            formData.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
            formData.append("Content-Disposition: form-data; name=\"language\"\(lineBreak)\(lineBreak)".data(using: .utf8)!)
            formData.append("\(settings.selectedLanguage)\(lineBreak)".data(using: .utf8)!)
        }
        
        // Add prompt if provided (max 224 tokens for Groq)
        if !settings.initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            formData.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
            formData.append("Content-Disposition: form-data; name=\"prompt\"\(lineBreak)\(lineBreak)".data(using: .utf8)!)
            formData.append("\(settings.initialPrompt)\(lineBreak)".data(using: .utf8)!)
        }
        
        // Add response format for timestamps
        if settings.showTimestamps {
            formData.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
            formData.append("Content-Disposition: form-data; name=\"response_format\"\(lineBreak)\(lineBreak)".data(using: .utf8)!)
            formData.append("verbose_json\(lineBreak)".data(using: .utf8)!)
            
            // Add timestamp granularities - Groq supports both segment and word level
            // Adding segment granularity for full metadata
            formData.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
            formData.append("Content-Disposition: form-data; name=\"timestamp_granularities[]\"\(lineBreak)\(lineBreak)".data(using: .utf8)!)
            formData.append("segment\(lineBreak)".data(using: .utf8)!)
            
            // Adding word granularity for precise timing
            formData.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
            formData.append("Content-Disposition: form-data; name=\"timestamp_granularities[]\"\(lineBreak)\(lineBreak)".data(using: .utf8)!)
            formData.append("word\(lineBreak)".data(using: .utf8)!)
        } else {
            formData.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
            formData.append("Content-Disposition: form-data; name=\"response_format\"\(lineBreak)\(lineBreak)".data(using: .utf8)!)
            formData.append("json\(lineBreak)".data(using: .utf8)!)
        }
        
        // Add temperature parameter
        if settings.temperature > 0 {
            formData.append("--\(boundary)\(lineBreak)".data(using: .utf8)!)
            formData.append("Content-Disposition: form-data; name=\"temperature\"\(lineBreak)\(lineBreak)".data(using: .utf8)!)
            formData.append("\(settings.temperature)\(lineBreak)".data(using: .utf8)!)
        }
        
        // Add audio file (validate size first to prevent memory issues)
        let fileSize = try audioURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        if fileSize > maxFileSizeBytes {
            throw TranscriptionError.fileTooBig(maxSize: maxFileSizeBytes)
        }
        
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
                    NSError(domain: "GroqProvider", code: response.statusCode, userInfo: [
                        NSLocalizedDescriptionKey: message
                    ])
                )
            }
            throw TranscriptionError.audioProcessingError(
                NSError(domain: "GroqProvider", code: response.statusCode, userInfo: [
                    NSLocalizedDescriptionKey: "Unprocessable entity"
                ])
            )
            
        case 429:
            throw TranscriptionError.quotaExceeded
            
        case 500...599:
            throw TranscriptionError.providerUnavailable(.groq)
            
        default:
            let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw TranscriptionError.networkError(
                NSError(domain: "GroqProvider", code: response.statusCode, userInfo: [
                    NSLocalizedDescriptionKey: "HTTP \(response.statusCode): \(errorMessage)"
                ])
            )
        }
    }
    
    private func parseTranscriptionResponse(_ data: Data) throws -> String {
        guard let responseDict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscriptionError.audioProcessingError(
                NSError(domain: "GroqProvider", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Invalid JSON response"
                ])
            )
        }
        
        guard let text = responseDict["text"] as? String else {
            throw TranscriptionError.audioProcessingError(
                NSError(domain: "GroqProvider", code: -1, userInfo: [
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
                NSError(domain: "GroqProvider", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Invalid configuration"
                ])
            )
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
                NSError(domain: "GroqProvider", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Network request timeout"
                ])
            )
        } catch {
            throw TranscriptionError.networkError(error)
        }
    }
    
    private func isValidGroqAPIKeyFormat(_ apiKey: String) -> Bool {
        // Enhanced validation for Groq API key format
        // Groq API keys follow pattern: gsk_[alphanumeric string of ~50+ chars]
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard trimmedKey.hasPrefix("gsk_") else { return false }
        
        // Check length (Groq keys are typically 50+ characters)
        guard trimmedKey.count >= 50 else { return false }
        
        // Verify only valid characters after prefix
        let keyBody = String(trimmedKey.dropFirst(4)) // Remove "gsk_" prefix
        let validCharacterSet = CharacterSet.alphanumerics
        return keyBody.rangeOfCharacter(from: validCharacterSet.inverted) == nil
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
        case "webm":
            return "audio/webm"
        case "mp4":
            return "audio/mp4"
        default:
            return "audio/wav" // Default fallback
        }
    }
}

// MARK: - Response Models

private struct GroqTranscriptionResponse: Codable {
    let text: String
    let task: String?
    let language: String?
    let duration: Double?
    let segments: [GroqSegment]?
}

private struct GroqSegment: Codable {
    let id: Int
    let seek: Double
    let start: Double
    let end: Double
    let text: String
    let tokens: [Int]
    let temperature: Double?
    let avgLogprob: Double?
    let compressionRatio: Double?
    let noSpeechProb: Double?
    
    private enum CodingKeys: String, CodingKey {
        case id, seek, start, end, text, tokens, temperature
        case avgLogprob = "avg_logprob"
        case compressionRatio = "compression_ratio"
        case noSpeechProb = "no_speech_prob"
    }
}