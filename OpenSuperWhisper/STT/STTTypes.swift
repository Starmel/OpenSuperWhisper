import Foundation

// MARK: - Forward Type Declarations for AppPreferences

/// Forward declaration for STTProviderType to avoid circular imports
public enum STTProviderType: String, CaseIterable, Identifiable {
    case whisperLocal = "whisper_local"
    case mistralVoxtral = "mistral_voxtral"
    case groq = "groq"
    
    public var id: String { rawValue }
    
    public var displayName: String {
        switch self {
        case .whisperLocal: return "Whisper (Local)"
        case .mistralVoxtral: return "Mistral Voxtral"
        case .groq: return "Groq Whisper"
        }
    }
    
    public var requiresInternetConnection: Bool {
        switch self {
        case .whisperLocal: return false
        case .mistralVoxtral: return true
        case .groq: return true
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

/// Configuration for Groq cloud provider
public struct GroqConfiguration: STTProviderConfiguration {
    public var isEnabled: Bool = false
    public var priority: Int = 3
    public var endpoint: String = "https://api.groq.com/openai/v1/audio/transcriptions"
    public var maxRetries: Int = 3
    public var timeoutInterval: TimeInterval = 60.0
    public var model: String = "whisper-large-v3-turbo" // Default to faster, cheaper model  
    public var maxFileSizeMB: Int = 25 // Free tier: 25MB, Dev tier: 100MB
    
    // Model Options:
    // - whisper-large-v3-turbo: $0.04/hour, 12% WER, 216x real-time speed, transcription only
    // - whisper-large-v3: $0.111/hour, 10.3% WER, 189x real-time speed, transcription + translation
    public static let availableModels = [
        "whisper-large-v3-turbo", // Faster, cheaper, transcription only
        "whisper-large-v3"        // More accurate, supports translation  
    ]
    
    // API key is stored securely via SecureStorage
    public var apiKey: String? {
        get {
            return SecureStorageManager.shared.getAPIKey(for: .groq)
        }
        set {
            SecureStorageManager.shared.setAPIKey(newValue, for: .groq)
        }
    }
    
    public var hasValidAPIKey: Bool {
        return SecureStorageManager.shared.hasValidAPIKey(for: .groq)
    }
    
    public init() {}
    
    public init(endpoint: String = "https://api.groq.com/openai/v1/audio/transcriptions",
         model: String = "whisper-large-v3-turbo",
         maxRetries: Int = 3,
         timeoutInterval: TimeInterval = 60.0,
         maxFileSizeMB: Int = 25) {
        self.endpoint = endpoint
        self.model = model
        self.maxRetries = maxRetries
        self.timeoutInterval = timeoutInterval
        self.maxFileSizeMB = maxFileSizeMB
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