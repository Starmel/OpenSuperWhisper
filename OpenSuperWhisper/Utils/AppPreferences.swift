import Foundation

// Import STT types
// Note: This file contains only the base types to avoid circular imports

@propertyWrapper
struct UserDefault<T> {
    let key: String
    let defaultValue: T
    
    var wrappedValue: T {
        get { UserDefaults.standard.object(forKey: key) as? T ?? defaultValue }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

@propertyWrapper
struct OptionalUserDefault<T> {
    let key: String
    
    var wrappedValue: T? {
        get { UserDefaults.standard.object(forKey: key) as? T }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

final class AppPreferences {
    static let shared = AppPreferences()
    private init() {}
    
    // Model settings
    @OptionalUserDefault(key: "selectedModelPath")
    var selectedModelPath: String?
    
    @UserDefault(key: "whisperLanguage", defaultValue: "en")
    var whisperLanguage: String
    
    // Transcription settings
    @UserDefault(key: "translateToEnglish", defaultValue: false)
    var translateToEnglish: Bool
    
    @UserDefault(key: "suppressBlankAudio", defaultValue: false)
    var suppressBlankAudio: Bool
    
    @UserDefault(key: "showTimestamps", defaultValue: false)
    var showTimestamps: Bool
    
    @UserDefault(key: "temperature", defaultValue: 0.0)
    var temperature: Double
    
    @UserDefault(key: "noSpeechThreshold", defaultValue: 0.6)
    var noSpeechThreshold: Double
    
    @UserDefault(key: "initialPrompt", defaultValue: "")
    var initialPrompt: String
    
    @UserDefault(key: "useBeamSearch", defaultValue: false)
    var useBeamSearch: Bool
    
    @UserDefault(key: "beamSize", defaultValue: 5)
    var beamSize: Int
    
    @UserDefault(key: "debugMode", defaultValue: false)
    var debugMode: Bool
    
    @UserDefault(key: "playSoundOnRecordStart", defaultValue: false)
    var playSoundOnRecordStart: Bool
    
    @UserDefault(key: "hasCompletedOnboarding", defaultValue: false)
    var hasCompletedOnboarding: Bool
    
    // MARK: STT Provider Selection
    
    @UserDefault(key: "primarySTTProvider", defaultValue: "whisper_local")
    var primarySTTProvider: String
    
    @UserDefault(key: "enableSTTFallback", defaultValue: true)
    var enableSTTFallback: Bool
    
    @UserDefault(key: "sttFallbackProviders", defaultValue: ["mistral_voxtral"])
    var sttFallbackProviders: [String]
    
    // MARK: STT Provider Configurations
    
    @UserDefault(key: "whisperLocalConfig", defaultValue: "")
    private var whisperLocalConfigJSON: String
    
    @UserDefault(key: "mistralVoxtralConfig", defaultValue: "")
    private var mistralVoxtralConfigJSON: String
    
    @UserDefault(key: "textImprovementConfig", defaultValue: "")
    private var textImprovementConfigJSON: String
    
    /// Whisper Local configuration with automatic persistence
    var whisperLocalConfig: WhisperLocalConfiguration {
        get {
            guard !whisperLocalConfigJSON.isEmpty,
                  let data = whisperLocalConfigJSON.data(using: .utf8),
                  let config = try? JSONDecoder().decode(WhisperLocalConfiguration.self, from: data) else {
                // Return default config with current model path for backward compatibility
                var defaultConfig = WhisperLocalConfiguration()
                defaultConfig.modelPath = selectedModelPath
                return defaultConfig
            }
            return config
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let json = String(data: data, encoding: .utf8) {
                whisperLocalConfigJSON = json
            }
        }
    }
    
    /// Mistral Voxtral configuration with automatic persistence
    var mistralVoxtralConfig: MistralVoxtralConfiguration {
        get {
            guard !mistralVoxtralConfigJSON.isEmpty,
                  let data = mistralVoxtralConfigJSON.data(using: .utf8),
                  let config = try? JSONDecoder().decode(MistralVoxtralConfiguration.self, from: data) else {
                return MistralVoxtralConfiguration()
            }
            return config
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let json = String(data: data, encoding: .utf8) {
                mistralVoxtralConfigJSON = json
            }
        }
    }
    
    /// Get configuration for a specific provider
    func getConfiguration(for provider: STTProviderType) -> STTProviderConfiguration {
        switch provider {
        case .whisperLocal:
            return whisperLocalConfig
        case .mistralVoxtral:
            return mistralVoxtralConfig
        }
    }
    
    /// Set configuration for a specific provider
    func setConfiguration(_ config: STTProviderConfiguration, for provider: STTProviderType) {
        switch provider {
        case .whisperLocal:
            if let whisperConfig = config as? WhisperLocalConfiguration {
                whisperLocalConfig = whisperConfig
            }
        case .mistralVoxtral:
            if let mistralConfig = config as? MistralVoxtralConfiguration {
                mistralVoxtralConfig = mistralConfig
            }
        }
    }
    
    /// Text Improvement configuration with automatic persistence
    var textImprovementConfig: TextImprovementConfiguration {
        get {
            guard !textImprovementConfigJSON.isEmpty,
                  let data = textImprovementConfigJSON.data(using: .utf8),
                  let config = try? JSONDecoder().decode(TextImprovementConfiguration.self, from: data) else {
                return TextImprovementConfiguration()
            }
            return config
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let json = String(data: data, encoding: .utf8) {
                textImprovementConfigJSON = json
            }
        }
    }
    
    /// Get current transcription settings
    var currentTranscriptionSettings: TranscriptionSettings {
        return TranscriptionSettings(fromAppPreferences: self)
    }
}
