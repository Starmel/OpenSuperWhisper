import Foundation

// MARK: - STT Provider Factory

/// Factory for creating and managing STT provider instances
actor STTProviderFactory {
    static let shared = STTProviderFactory()
    
    private var providerInstances: [STTProviderType: any STTProvider] = [:]
    
    private init() {}
    
    /// Get or create a provider instance for the specified type
    func getProvider(for type: STTProviderType) async -> any STTProvider {
        if let existingProvider = providerInstances[type] {
            return existingProvider
        }
        
        let provider = await createProvider(for: type)
        providerInstances[type] = provider
        return provider
    }
    
    /// Create a new provider instance for the specified type
    private func createProvider(for type: STTProviderType) async -> any STTProvider {
        switch type {
        case .whisperLocal:
            let config = AppPreferences.shared.whisperLocalConfig
            return await WhisperLocalProvider(configuration: config)
            
        case .mistralVoxtral:
            let config = AppPreferences.shared.mistralVoxtralConfig
            return await MistralVoxtralProvider(configuration: config)
            
        case .groq:
            let config = AppPreferences.shared.groqConfig
            return await GroqProvider(configuration: config)
        }
    }
    
    /// Refresh provider configuration (useful when settings change)
    func refreshProvider(for type: STTProviderType) async {
        providerInstances.removeValue(forKey: type)
    }
    
    /// Refresh all providers
    func refreshAllProviders() async {
        providerInstances.removeAll()
    }
    
    /// Get all available provider types
    func getAvailableProviders() -> [STTProviderType] {
        return STTProviderType.allCases
    }
    
    /// Get configured providers only
    func getConfiguredProviders() async -> [STTProviderType] {
        var configuredProviders: [STTProviderType] = []
        
        for providerType in STTProviderType.allCases {
            let provider = await getProvider(for: providerType)
            if await provider.isConfigured {
                configuredProviders.append(providerType)
            }
        }
        
        return configuredProviders
    }
}

// MARK: - WhisperLocal Provider Placeholder

/// Placeholder for the local Whisper provider that bridges to the existing TranscriptionService
actor WhisperLocalProvider: STTProvider {
    let id: STTProviderType = .whisperLocal
    let displayName: String = "Whisper (Local)"
    
    var configuration: STTProviderConfiguration {
        get { _configuration }
        set {
            if let whisperConfig = newValue as? WhisperLocalConfiguration {
                _configuration = whisperConfig
            }
        }
    }
    
    var isConfigured: Bool {
        return _configuration.isEnabled && _configuration.modelPath != nil
    }
    
    var supportedLanguages: [String] {
        return [
            "auto", "en", "es", "fr", "de", "it", "pt", "ru", "ja", "ko", "zh",
            "ar", "hi", "tr", "pl", "nl", "sv", "da", "no", "fi", "cs", "sk",
            "hu", "ro", "bg", "hr", "sl", "et", "lv", "lt", "mt", "ga", "cy"
        ]
    }
    
    private var _configuration: WhisperLocalConfiguration
    
    init(configuration: WhisperLocalConfiguration = WhisperLocalConfiguration()) {
        self._configuration = configuration
    }
    
    func transcribe(audioURL: URL, settings: TranscriptionSettings) async throws -> String {
        return try await transcribe(audioURL: audioURL, settings: settings) { _ in }
    }
    
    func transcribe(
        audioURL: URL,
        settings: TranscriptionSettings,
        progressCallback: @escaping (TranscriptionProgress) -> Void
    ) async throws -> String {
        
        // Convert TranscriptionSettings to legacy Settings for compatibility
        let legacySettings = Settings(
            selectedLanguage: settings.selectedLanguage,
            translateToEnglish: settings.translateToEnglish,
            suppressBlankAudio: settings.suppressBlankAudio,
            showTimestamps: settings.showTimestamps,
            temperature: settings.temperature,
            noSpeechThreshold: settings.noSpeechThreshold,
            initialPrompt: settings.initialPrompt,
            useBeamSearch: settings.useBeamSearch,
            beamSize: settings.beamSize
        )
        
        // Use the direct transcription method to avoid circular dependency
        // Note: TranscriptionService is @MainActor isolated
        return try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                do {
                    let result = try await TranscriptionService.shared.transcribeAudioDirectly(
                        url: audioURL,
                        settings: legacySettings
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    func validateConfiguration() async throws -> ValidationResult {
        var errors: [ValidationError] = []
        var warnings: [ValidationWarning] = []
        
        // Check if model path exists
        guard let modelPath = _configuration.modelPath else {
            errors.append(.modelNotFound(path: "No model path specified"))
            return ValidationResult(isValid: false, errors: errors, warnings: warnings)
        }
        
        let modelURL = URL(fileURLWithPath: modelPath)
        guard FileManager.default.fileExists(atPath: modelPath) else {
            errors.append(.modelNotFound(path: modelPath))
            return ValidationResult(isValid: false, errors: errors, warnings: warnings)
        }
        
        // Check file size (models should be reasonably sized)
        do {
            let fileSize = try modelURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            if fileSize < 1024 * 1024 { // Less than 1MB is suspicious
                warnings.append(.modelOutdated)
            }
        } catch {
            warnings.append(.modelOutdated)
        }
        
        return ValidationResult(isValid: errors.isEmpty, errors: errors, warnings: warnings)
    }
    
    func supportedFeatures() -> Set<STTFeature> {
        return [
            .realTimeProgress,
            .timestampSupport,
            .languageDetection,
            .translation,
            .customPrompts,
            .beamSearch,
            .noiseReduction
        ]
    }
}

// MARK: - Legacy Settings Bridge

extension Settings {
    init(
        selectedLanguage: String,
        translateToEnglish: Bool,
        suppressBlankAudio: Bool,
        showTimestamps: Bool,
        temperature: Double,
        noSpeechThreshold: Double,
        initialPrompt: String,
        useBeamSearch: Bool,
        beamSize: Int
    ) {
        self.selectedLanguage = selectedLanguage
        self.translateToEnglish = translateToEnglish
        self.suppressBlankAudio = suppressBlankAudio
        self.showTimestamps = showTimestamps
        self.temperature = temperature
        self.noSpeechThreshold = noSpeechThreshold
        self.initialPrompt = initialPrompt
        self.useBeamSearch = useBeamSearch
        self.beamSize = beamSize
    }
}