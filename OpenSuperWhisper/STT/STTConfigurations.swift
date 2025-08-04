import Foundation

// MARK: - Provider-Specific Configurations and Settings
// Note: Core types moved to STTTypes.swift to avoid circular imports

// MARK: - Enhanced Transcription Settings

extension TranscriptionSettings {
    
    /// Create settings from current app preferences for backward compatibility
    init(fromAppPreferences prefs: AppPreferences) {
        self.selectedLanguage = prefs.whisperLanguage
        self.showTimestamps = prefs.showTimestamps
        self.translateToEnglish = prefs.translateToEnglish
        self.initialPrompt = prefs.initialPrompt
        self.temperature = prefs.temperature
        self.noSpeechThreshold = prefs.noSpeechThreshold
        self.useBeamSearch = prefs.useBeamSearch
        self.beamSize = prefs.beamSize
        self.suppressBlankAudio = prefs.suppressBlankAudio
        
        // Load provider settings
        if let primaryProvider = STTProviderType(rawValue: prefs.primarySTTProvider) {
            self.primaryProvider = primaryProvider
        }
        self.enableFallback = prefs.enableSTTFallback
        self.fallbackProviders = prefs.sttFallbackProviders.compactMap { STTProviderType(rawValue: $0) }
    }
}

