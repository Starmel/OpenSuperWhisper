import AppKit
import Carbon
import Combine
import Foundation
import KeyboardShortcuts
import SwiftUI

class SettingsViewModel: ObservableObject {
    @Published var selectedModelURL: URL? {
        didSet {
            if let url = selectedModelURL {
                AppPreferences.shared.selectedModelPath = url.path
            }
        }
    }

    @Published var availableModels: [URL] = []
    @Published var selectedLanguage: String {
        didSet {
            AppPreferences.shared.whisperLanguage = selectedLanguage
        }
    }

    @Published var translateToEnglish: Bool {
        didSet {
            AppPreferences.shared.translateToEnglish = translateToEnglish
        }
    }

    @Published var suppressBlankAudio: Bool {
        didSet {
            AppPreferences.shared.suppressBlankAudio = suppressBlankAudio
        }
    }

    @Published var showTimestamps: Bool {
        didSet {
            AppPreferences.shared.showTimestamps = showTimestamps
        }
    }
    
    @Published var temperature: Double {
        didSet {
            AppPreferences.shared.temperature = temperature
        }
    }

    @Published var noSpeechThreshold: Double {
        didSet {
            AppPreferences.shared.noSpeechThreshold = noSpeechThreshold
        }
    }

    @Published var initialPrompt: String {
        didSet {
            AppPreferences.shared.initialPrompt = initialPrompt
        }
    }

    @Published var useBeamSearch: Bool {
        didSet {
            AppPreferences.shared.useBeamSearch = useBeamSearch
        }
    }

    @Published var beamSize: Int {
        didSet {
            AppPreferences.shared.beamSize = beamSize
        }
    }

    @Published var debugMode: Bool {
        didSet {
            AppPreferences.shared.debugMode = debugMode
        }
    }
    
    @Published var playSoundOnRecordStart: Bool {
        didSet {
            AppPreferences.shared.playSoundOnRecordStart = playSoundOnRecordStart
        }
    }
    
    // MARK: - STT Provider Settings
    
    @Published var selectedSTTProvider: STTProviderType {
        didSet {
            AppPreferences.shared.primarySTTProvider = selectedSTTProvider.rawValue
        }
    }
    
    @Published var enableSTTFallback: Bool {
        didSet {
            AppPreferences.shared.enableSTTFallback = enableSTTFallback
        }
    }
    
    @Published var mistralAPIKey: String = "" {
        didSet {
            // Update the secure storage
            var config = AppPreferences.shared.mistralVoxtralConfig
            config.apiKey = mistralAPIKey.isEmpty ? nil : mistralAPIKey
            AppPreferences.shared.mistralVoxtralConfig = config
        }
    }
    
    @Published var mistralModel: String {
        didSet {
            var config = AppPreferences.shared.mistralVoxtralConfig
            config.model = mistralModel
            AppPreferences.shared.mistralVoxtralConfig = config
        }
    }
    
    @Published var apiKeyValidationState: APIKeyValidationState = .unknown
    
    enum APIKeyValidationState: Equatable {
        case unknown
        case validating
        case valid
        case invalid(String)
    }
    
    // MARK: - Text Improvement Settings
    
    @Published var textImprovementEnabled: Bool {
        didSet {
            var config = AppPreferences.shared.textImprovementConfig
            config.isEnabled = textImprovementEnabled
            AppPreferences.shared.textImprovementConfig = config
        }
    }
    
    @Published var textImprovementAPIKey: String = "" {
        didSet {
            var config = AppPreferences.shared.textImprovementConfig
            config.apiKey = textImprovementAPIKey.isEmpty ? nil : textImprovementAPIKey
            AppPreferences.shared.textImprovementConfig = config
        }
    }
    
    @Published var textImprovementModel: String {
        didSet {
            var config = AppPreferences.shared.textImprovementConfig
            config.model = textImprovementModel
            AppPreferences.shared.textImprovementConfig = config
        }
    }
    
    @Published var textImprovementBaseURL: String {
        didSet {
            var config = AppPreferences.shared.textImprovementConfig
            config.baseURL = textImprovementBaseURL
            AppPreferences.shared.textImprovementConfig = config
        }
    }
    
    @Published var textImprovementPrompt: String {
        didSet {
            var config = AppPreferences.shared.textImprovementConfig
            config.customPrompt = textImprovementPrompt
            AppPreferences.shared.textImprovementConfig = config
        }
    }
    
    @Published var useAdvancedTextImprovementSettings: Bool {
        didSet {
            var config = AppPreferences.shared.textImprovementConfig
            config.useAdvancedSettings = useAdvancedTextImprovementSettings
            
            // Set or clear advanced settings based on toggle
            if useAdvancedTextImprovementSettings {
                config.temperature = textImprovementTemperature
                config.maxTokens = textImprovementMaxTokens
            } else {
                config.temperature = nil
                config.maxTokens = nil
            }
            
            AppPreferences.shared.textImprovementConfig = config
        }
    }
    
    @Published var textImprovementTemperature: Double {
        didSet {
            var config = AppPreferences.shared.textImprovementConfig
            config.temperature = config.useAdvancedSettings ? textImprovementTemperature : nil
            AppPreferences.shared.textImprovementConfig = config
        }
    }
    
    @Published var textImprovementMaxTokens: Int {
        didSet {
            var config = AppPreferences.shared.textImprovementConfig
            config.maxTokens = config.useAdvancedSettings ? textImprovementMaxTokens : nil
            AppPreferences.shared.textImprovementConfig = config
        }
    }
    
    @Published var textImprovementValidationState: APIKeyValidationState = .unknown
    
    init() {
        let prefs = AppPreferences.shared
        self.selectedLanguage = prefs.whisperLanguage
        self.translateToEnglish = prefs.translateToEnglish
        self.suppressBlankAudio = prefs.suppressBlankAudio
        self.showTimestamps = prefs.showTimestamps
        self.temperature = prefs.temperature
        self.noSpeechThreshold = prefs.noSpeechThreshold
        self.initialPrompt = prefs.initialPrompt
        self.useBeamSearch = prefs.useBeamSearch
        self.beamSize = prefs.beamSize
        self.debugMode = prefs.debugMode
        self.playSoundOnRecordStart = prefs.playSoundOnRecordStart
        
        // Initialize STT provider settings
        self.selectedSTTProvider = STTProviderType(rawValue: prefs.primarySTTProvider) ?? .whisperLocal
        self.enableSTTFallback = prefs.enableSTTFallback
        
        let mistralConfig = prefs.mistralVoxtralConfig
        self.mistralAPIKey = mistralConfig.apiKey ?? ""
        self.mistralModel = mistralConfig.model
        
        // Initialize text improvement settings
        let textImprovementConfig = prefs.textImprovementConfig
        self.textImprovementEnabled = textImprovementConfig.isEnabled
        self.textImprovementAPIKey = textImprovementConfig.apiKey ?? ""
        self.textImprovementModel = textImprovementConfig.model
        self.textImprovementBaseURL = textImprovementConfig.baseURL
        self.textImprovementPrompt = textImprovementConfig.customPrompt
        self.useAdvancedTextImprovementSettings = textImprovementConfig.useAdvancedSettings
        self.textImprovementTemperature = textImprovementConfig.temperature ?? 0.3
        self.textImprovementMaxTokens = textImprovementConfig.maxTokens ?? 1000
        
        if let savedPath = prefs.selectedModelPath {
            self.selectedModelURL = URL(fileURLWithPath: savedPath)
        }
        loadAvailableModels()
    }
    
    func loadAvailableModels() {
        availableModels = WhisperModelManager.shared.getAvailableModels()
        if selectedModelURL == nil {
            selectedModelURL = availableModels.first
        }
    }
    
    // MARK: - STT Provider Methods
    
    func validateMistralAPIKey() {
        guard !mistralAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            apiKeyValidationState = .invalid("API key cannot be empty")
            return
        }
        
        apiKeyValidationState = .validating
        
        Task {
            do {
                let provider = try await STTProviderFactory.shared.getProvider(for: .mistralVoxtral)
                let result = try await provider.validateConfiguration()
                
                await MainActor.run {
                    if result.isValid {
                        self.apiKeyValidationState = .valid
                    } else {
                        let errorMessage = result.errors.first?.localizedDescription ?? "Unknown validation error"
                        self.apiKeyValidationState = .invalid(errorMessage)
                    }
                }
            } catch {
                await MainActor.run {
                    self.apiKeyValidationState = .invalid(error.localizedDescription)
                }
            }
        }
    }
    
    func validateTextImprovementAPIKey() {
        guard !textImprovementAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            textImprovementValidationState = .invalid("API key cannot be empty")
            return
        }
        
        textImprovementValidationState = .validating
        
        Task {
            let isValid = await TextImprovementService.shared.validateAPIKey()
            
            await MainActor.run {
                if isValid {
                    self.textImprovementValidationState = .valid
                } else {
                    self.textImprovementValidationState = .invalid("Invalid API key or service unavailable")
                }
            }
        }
    }
    
    var availableSTTProviders: [STTProviderType] {
        return STTProviderType.allCases
    }
    
    var availableMistralModels: [String] {
        return ["voxtral-mini-latest"]
    }
    
}

struct Settings {
    var selectedLanguage: String
    var translateToEnglish: Bool
    var suppressBlankAudio: Bool
    var showTimestamps: Bool
    var temperature: Double
    var noSpeechThreshold: Double
    var initialPrompt: String
    var useBeamSearch: Bool
    var beamSize: Int
    
    init() {
        let prefs = AppPreferences.shared
        self.selectedLanguage = prefs.whisperLanguage
        self.translateToEnglish = prefs.translateToEnglish
        self.suppressBlankAudio = prefs.suppressBlankAudio
        self.showTimestamps = prefs.showTimestamps
        self.temperature = prefs.temperature
        self.noSpeechThreshold = prefs.noSpeechThreshold
        self.initialPrompt = prefs.initialPrompt
        self.useBeamSearch = prefs.useBeamSearch
        self.beamSize = prefs.beamSize
    }
}

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    
    var body: some View {
        ModernSettingsView(viewModel: viewModel)
    }
}