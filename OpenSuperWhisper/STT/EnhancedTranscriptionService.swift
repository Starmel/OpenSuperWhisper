import Foundation
import AVFoundation

// MARK: - Enhanced Transcription Service

/// Enhanced transcription service that supports multiple STT providers with fallback
@MainActor
class EnhancedTranscriptionService: ObservableObject {
    static let shared = EnhancedTranscriptionService()
    
    // MARK: - Published Properties
    
    @Published private(set) var isTranscribing = false
    @Published private(set) var transcribedText = ""
    @Published private(set) var currentSegment = ""
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Float = 0.0
    @Published private(set) var currentProvider: STTProviderType?
    @Published private(set) var lastError: Error?
    
    // MARK: - Private Properties
    
    private var transcriptionTask: Task<String, Error>?
    private var isCancelled = false
    
    private init() {}
    
    // MARK: - Public Methods
    
    /// Transcribe audio using the configured providers with fallback support
    func transcribeAudio(url: URL, settings: TranscriptionSettings? = nil) async throws -> String {
        let transcriptionSettings = settings ?? AppPreferences.shared.currentTranscriptionSettings
        
        // Update UI state
        self.isTranscribing = true
        self.transcribedText = ""
        self.currentSegment = ""
        self.progress = 0.0
        self.isCancelled = false
        self.lastError = nil
        
        defer {
            self.isTranscribing = false
            self.currentSegment = ""
            if !self.isCancelled {
                self.progress = 1.0
            }
            self.currentProvider = nil
            self.transcriptionTask = nil
        }
        
        // Create and store the transcription task
        let task = Task {
            return try await performTranscriptionWithFallback(
                audioURL: url,
                settings: transcriptionSettings
            )
        }
        
        self.transcriptionTask = task
        
        do {
            return try await task.value
        } catch is CancellationError {
            self.isCancelled = true
            throw TranscriptionError.audioProcessingError(
                NSError(domain: "EnhancedTranscriptionService", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Transcription was cancelled"
                ])
            )
        }
    }
    
    /// Cancel the current transcription
    func cancelTranscription() {
        isCancelled = true
        transcriptionTask?.cancel()
        transcriptionTask = nil
        
        // Reset state
        isTranscribing = false
        currentSegment = ""
        progress = 0.0
        currentProvider = nil
        isCancelled = false
    }
    
    /// Get available providers
    func getAvailableProviders() async -> [STTProviderType] {
        return await STTProviderFactory.shared.getAvailableProviders()
    }
    
    /// Get configured providers
    func getConfiguredProviders() async -> [STTProviderType] {
        return await STTProviderFactory.shared.getConfiguredProviders()
    }
    
    /// Validate a specific provider
    func validateProvider(_ providerType: STTProviderType) async -> ValidationResult {
        let provider = await STTProviderFactory.shared.getProvider(for: providerType)
        do {
            return try await provider.validateConfiguration()
        } catch {
            return ValidationResult(
                isValid: false,
                errors: [.networkUnreachable],
                warnings: []
            )
        }
    }
    
    /// Test a provider with a sample audio file
    func testProvider(_ providerType: STTProviderType, with audioURL: URL) async throws -> String {
        let provider = await STTProviderFactory.shared.getProvider(for: providerType)
        let settings = AppPreferences.shared.currentTranscriptionSettings
        
        return try await provider.transcribe(audioURL: audioURL, settings: settings)
    }
    
    // MARK: - Private Implementation
    
    private func performTranscriptionWithFallback(
        audioURL: URL,
        settings: TranscriptionSettings
    ) async throws -> String {
        
        let providers = getProvidersInPriorityOrder(settings: settings)
        
        guard !providers.isEmpty else {
            throw TranscriptionError.providerNotConfigured(settings.primaryProvider)
        }
        
        var lastError: Error?
        
        for providerType in providers {
            // Check if cancelled
            try Task.checkCancellation()
            
            do {
                await MainActor.run {
                    self.currentProvider = providerType
                    self.currentSegment = "Trying \(providerType.displayName)..."
                }
                
                print("🔧 DEBUG: Attempting transcription with \(providerType.displayName)")
                let result = try await transcribeWithProvider(
                    providerType: providerType,
                    audioURL: audioURL,
                    settings: settings
                )
                
                print("🔧 DEBUG: Successfully transcribed with \(providerType.displayName)")
                return result
                
            } catch {
                lastError = error
                print("🔧 DEBUG: Failed with \(providerType.displayName): \(error)")
                
                // Log the error for debugging
                await MainActor.run {
                    self.lastError = error
                }
                
                // Don't try fallback for certain errors
                if case TranscriptionError.apiKeyInvalid = error {
                    continue // Try next provider
                }
                if case TranscriptionError.fileTooBig = error {
                    continue // Try next provider (different providers have different limits)
                }
                if !settings.enableFallback {
                    throw error // No fallback allowed
                }
                
                // Continue to next provider
                continue
            }
        }
        
        // All providers failed
        throw lastError ?? TranscriptionError.providerUnavailable(settings.primaryProvider)
    }
    
    private func transcribeWithProvider(
        providerType: STTProviderType,
        audioURL: URL,
        settings: TranscriptionSettings
    ) async throws -> String {
        
        let provider = await STTProviderFactory.shared.getProvider(for: providerType)
        
        // Validate provider configuration
        let validation = try await provider.validateConfiguration()
        guard validation.isValid else {
            throw TranscriptionError.providerNotConfigured(providerType)
        }
        
        // Set up progress callback
        let progressCallback: (TranscriptionProgress) -> Void = { [weak self] progressInfo in
            Task { @MainActor in
                guard let self = self else { return }
                self.progress = progressInfo.percentage
                self.currentSegment = progressInfo.currentSegment
            }
        }
        
        // Perform transcription
        return try await provider.transcribe(
            audioURL: audioURL,
            settings: settings,
            progressCallback: progressCallback
        )
    }
    
    private func getProvidersInPriorityOrder(settings: TranscriptionSettings) -> [STTProviderType] {
        var providers: [STTProviderType] = []
        
        // Add primary provider first
        providers.append(settings.primaryProvider)
        print("🔧 DEBUG: Primary provider: \(settings.primaryProvider)")
        
        // Add fallback providers if enabled
        if settings.enableFallback {
            print("🔧 DEBUG: Fallback enabled, fallback providers: \(settings.fallbackProviders)")
            for fallbackProvider in settings.fallbackProviders {
                if !providers.contains(fallbackProvider) {
                    providers.append(fallbackProvider)
                }
            }
        }
        
        print("🔧 DEBUG: Final provider order: \(providers)")
        return providers
    }
}

// MARK: - Backward Compatibility

extension EnhancedTranscriptionService {
    /// Legacy method for backward compatibility with existing code
    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        // Convert legacy Settings to TranscriptionSettings
        let transcriptionSettings = TranscriptionSettings(fromLegacySettings: settings)
        return try await transcribeAudio(url: url, settings: transcriptionSettings)
    }
}

// MARK: - Legacy Settings Conversion

extension TranscriptionSettings {
    init(fromLegacySettings legacySettings: Settings) {
        self.selectedLanguage = legacySettings.selectedLanguage
        self.showTimestamps = legacySettings.showTimestamps
        self.translateToEnglish = legacySettings.translateToEnglish
        self.initialPrompt = legacySettings.initialPrompt
        self.temperature = legacySettings.temperature
        self.noSpeechThreshold = legacySettings.noSpeechThreshold
        self.useBeamSearch = legacySettings.useBeamSearch
        self.beamSize = legacySettings.beamSize
        self.suppressBlankAudio = legacySettings.suppressBlankAudio
        
        // Use current provider settings
        self.primaryProvider = AppPreferences.shared.primarySTTProvider.isEmpty ? 
            .whisperLocal : 
            STTProviderType(rawValue: AppPreferences.shared.primarySTTProvider) ?? .whisperLocal
        self.enableFallback = AppPreferences.shared.enableSTTFallback
        self.fallbackProviders = AppPreferences.shared.sttFallbackProviders.compactMap { 
            STTProviderType(rawValue: $0) 
        }
    }
}