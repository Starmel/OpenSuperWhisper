import Foundation

// MARK: - Forward Type Declarations for AppPreferences

/// Forward declaration for STTProviderType to avoid circular imports
public enum STTProviderType: String, CaseIterable, Identifiable {
    case whisperLocal = "whisper_local"
    case mistralVoxtral = "mistral_voxtral"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .whisperLocal: return "Whisper (Local)"
        case .mistralVoxtral: return "Mistral Voxtral"
        }
    }
    
    public var requiresInternetConnection: Bool {
        switch self {
        case .whisperLocal: return false
        case .mistralVoxtral: return true
        }
    }
}

/// Forward declaration for configuration protocol
public protocol STTProviderConfiguration: Codable {
    var isEnabled: Bool { get set }
    var priority: Int { get set }
}

/// Configuration for local Whisper provider
public struct WhisperLocalConfiguration: STTProviderConfiguration {
    public var isEnabled: Bool = true
    public var priority: Int = 1
    public var modelPath: String?
    public var useGPUAcceleration: Bool = true
    public var maxThreads: Int = 4
    
    public init() {}
    
    public init(modelPath: String?, useGPUAcceleration: Bool = true, maxThreads: Int = 4) {
        self.modelPath = modelPath
        self.useGPUAcceleration = useGPUAcceleration
        self.maxThreads = maxThreads
    }
}

/// Configuration for Mistral Voxtral cloud provider
public struct MistralVoxtralConfiguration: STTProviderConfiguration {
    public var isEnabled: Bool = false
    public var priority: Int = 2
    public var endpoint: String = "https://api.mistral.ai/v1/audio/transcriptions"
    public var maxRetries: Int = 3
    public var timeoutInterval: TimeInterval = 60.0
    public var model: String = "voxtral-mini-latest"
    public var maxFileSizeMB: Int = 25 // Mistral's limit is ~15 minutes of audio
    
    // API key is stored securely via SecureStorage
    public var apiKey: String? {
        get {
            return SecureStorageManager.shared.getAPIKey(for: .mistralVoxtral)
        }
        set {
            SecureStorageManager.shared.setAPIKey(newValue, for: .mistralVoxtral)
        }
    }
    
    public var hasValidAPIKey: Bool {
        return SecureStorageManager.shared.hasValidAPIKey(for: .mistralVoxtral)
    }
    
    public init() {}
    
    public init(endpoint: String = "https://api.mistral.ai/v1/audio/transcriptions",
         model: String = "voxtral-mini-latest",
         maxRetries: Int = 3,
         timeoutInterval: TimeInterval = 60.0) {
        self.endpoint = endpoint
        self.model = model
        self.maxRetries = maxRetries
        self.timeoutInterval = timeoutInterval
    }
}

/// Enhanced transcription settings supporting multiple providers
public struct TranscriptionSettings {
    // Universal settings
    public var selectedLanguage: String = "auto"
    public var showTimestamps: Bool = false
    public var translateToEnglish: Bool = false
    public var initialPrompt: String = ""
    
    // Provider selection and fallback
    public var primaryProvider: STTProviderType = .whisperLocal
    public var enableFallback: Bool = true
    public var fallbackProviders: [STTProviderType] = [.mistralVoxtral]
    
    // Whisper-specific settings (for backward compatibility)
    public var temperature: Double = 0.0
    public var noSpeechThreshold: Double = 0.6
    public var useBeamSearch: Bool = false
    public var beamSize: Int = 5
    public var suppressBlankAudio: Bool = false
    
    public init() {}
    
    /// Initialize TranscriptionSettings with individual parameters to avoid circular dependencies
    public init(whisperLanguage: String,
         showTimestamps: Bool,
         translateToEnglish: Bool,
         initialPrompt: String,
         primarySTTProvider: String,
         enableSTTFallback: Bool,
         temperature: Double,
         noSpeechThreshold: Double,
         useBeamSearch: Bool,
         beamSize: Int,
         suppressBlankAudio: Bool) {
        self.selectedLanguage = whisperLanguage
        self.showTimestamps = showTimestamps
        self.translateToEnglish = translateToEnglish
        self.initialPrompt = initialPrompt
        self.primaryProvider = STTProviderType(rawValue: primarySTTProvider) ?? .whisperLocal
        self.enableFallback = enableSTTFallback
        self.temperature = temperature
        self.noSpeechThreshold = noSpeechThreshold
        self.useBeamSearch = useBeamSearch
        self.beamSize = beamSize
        self.suppressBlankAudio = suppressBlankAudio
    }
}