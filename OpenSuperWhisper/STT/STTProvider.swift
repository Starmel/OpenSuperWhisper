import Foundation

// MARK: - Core STT Provider Protocol

/// Core protocol that all STT providers must implement
protocol STTProvider: Actor {
    var id: STTProviderType { get }
    var displayName: String { get }
    var isConfigured: Bool { get }
    var supportedLanguages: [String] { get }
    var configuration: STTProviderConfiguration { get set }
    
    /// Core transcription method
    func transcribe(audioURL: URL, settings: TranscriptionSettings) async throws -> String
    
    /// Progress tracking for providers that support it
    func transcribe(
        audioURL: URL, 
        settings: TranscriptionSettings,
        progressCallback: @escaping (TranscriptionProgress) -> Void
    ) async throws -> String
    
    /// Configuration validation
    func validateConfiguration() async throws -> ValidationResult
    
    /// Provider-specific capabilities
    func supportedFeatures() -> Set<STTFeature>
}

// MARK: - Enums and Types
// Note: STTProviderType is defined in STTTypes.swift to avoid circular imports

enum STTFeature: String, CaseIterable {
    case realTimeProgress = "real_time_progress"
    case timestampSupport = "timestamp_support"
    case languageDetection = "language_detection"
    case translation = "translation"
    case customPrompts = "custom_prompts"
    case beamSearch = "beam_search"
    case speakerDiarization = "speaker_diarization"
    case noiseReduction = "noise_reduction"
}

enum TranscriptionError: LocalizedError {
    case providerNotConfigured(STTProviderType)
    case networkError(Error)
    case audioProcessingError(Error)
    case apiKeyInvalid
    case quotaExceeded
    case unsupportedLanguage(String)
    case fileTooBig(maxSize: Int)
    case providerUnavailable(STTProviderType)
    
    var errorDescription: String? {
        switch self {
        case .providerNotConfigured(let type):
            return "Provider \(type.displayName) is not properly configured"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .apiKeyInvalid:
            return "Invalid API key"
        case .quotaExceeded:
            return "API quota exceeded"
        case .unsupportedLanguage(let lang):
            return "Language '\(lang)' is not supported by this provider"
        case .fileTooBig(let maxSize):
            return "Audio file exceeds maximum size of \(maxSize) bytes"
        case .providerUnavailable(let type):
            return "Provider \(type.displayName) is currently unavailable"
        case .audioProcessingError(let error):
            return "Audio processing error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Progress Tracking

struct TranscriptionProgress {
    let percentage: Float
    let currentSegment: String
    let timestamp: Float
    let estimatedTimeRemaining: TimeInterval?
}

// MARK: - Validation

struct ValidationResult {
    let isValid: Bool
    let errors: [ValidationError]
    let warnings: [ValidationWarning]
}

enum ValidationError: LocalizedError {
    case missingApiKey
    case invalidApiKey
    case networkUnreachable
    case modelNotFound(path: String)
    case insufficientDiskSpace
    case unsupportedAudioFormat
    
    var errorDescription: String? {
        switch self {
        case .missingApiKey: return "API key is required"
        case .invalidApiKey: return "API key is invalid"
        case .networkUnreachable: return "Network is unreachable"
        case .modelNotFound(let path): return "Model not found at path: \(path)"
        case .insufficientDiskSpace: return "Insufficient disk space"
        case .unsupportedAudioFormat: return "Audio format not supported"
        }
    }
}

enum ValidationWarning {
    case highLatencyExpected
    case quotaNearLimit(remaining: Int)
    case modelOutdated
    case networkSlowConnection
    
    var description: String {
        switch self {
        case .highLatencyExpected: return "High latency expected with current settings"
        case .quotaNearLimit(let remaining): return "API quota near limit (\(remaining) requests remaining)"
        case .modelOutdated: return "Model version is outdated"
        case .networkSlowConnection: return "Network connection is slow"
        }
    }
}

// MARK: - Configuration Protocol
// Note: STTProviderConfiguration is defined in STTTypes.swift to avoid circular imports