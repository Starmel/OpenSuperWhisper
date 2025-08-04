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
    @Environment(\.dismiss) var dismiss
    @State private var isRecordingNewShortcut = false
    @State private var selectedTab = 0
    @State private var previousModelURL: URL?
    
    var body: some View {
        TabView(selection: $selectedTab) {

             // Shortcut Settings
            shortcutSettings
                .tabItem {
                    Label("Shortcuts", systemImage: "command")
                }
                .tag(0)
            // STT Provider Settings
            sttProviderSettings
                .tabItem {
                    Label("Provider", systemImage: "cloud")
                }
                .tag(1)
            
            // Model Settings
            modelSettings
                .tabItem {
                    Label("Model", systemImage: "cpu")
                }
                .tag(2)
            
            // Transcription Settings
            transcriptionSettings
                .tabItem {
                    Label("Transcription", systemImage: "text.bubble")
                }
                .tag(3)
            
            // Text Improvement Settings
            textImprovementSettings
                .tabItem {
                    Label("Text Enhancement", systemImage: "text.magnifyingglass")
                }
                .tag(4)
            
            // Advanced Settings
            advancedSettings
                .tabItem {
                    Label("Advanced", systemImage: "gear")
                }
                .tag(5)
            }
        .padding()
        .frame(width: 550)
        .background(Color(.windowBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("Done") {
                    if viewModel.selectedModelURL != previousModelURL {
                        // Reload model if changed
                        if let modelPath = viewModel.selectedModelURL?.path {
                            TranscriptionService.shared.reloadModel(with: modelPath)
                        }
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
        }
        .onAppear {
            previousModelURL = viewModel.selectedModelURL
        }
    }
    
    private var modelSettings: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Whisper Model")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Picker("Model", selection: $viewModel.selectedModelURL) {
                        ForEach(viewModel.availableModels, id: \.self) { url in
                            Text(url.lastPathComponent)
                                .tag(url as URL?)
                        }
                    }
                    .pickerStyle(.menu)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.controlBackgroundColor))
                    .cornerRadius(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Models Directory:")
                                .font(.subheadline)
                            Spacer()
                            Button(action: {
                                NSWorkspace.shared.open(WhisperModelManager.shared.modelsDirectory)
                            }) {
                                Label("Open Folder", systemImage: "folder")
                                    .font(.subheadline)
                            }
                            .buttonStyle(.borderless)
                            .help("Open models directory")
                        }
                        Text(WhisperModelManager.shared.modelsDirectory.path)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                            .padding(8)
                            .background(Color(.textBackgroundColor).opacity(0.5))
                            .cornerRadius(6)
                    }
                    .padding(.top, 8)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("To display other models in the list, you need to download a ggml bin file and place it in the models folder. Then restart the application.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        
                        Link("Download models here", destination: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/tree/main")!)
                        .font(.caption)
                    }
                    .padding(.top, 8)
                }
                .padding()
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
    }
    
    private var transcriptionSettings: some View {
        Form {
            VStack(spacing: 20) {
                // Language Settings
                VStack(alignment: .leading, spacing: 16) {
                    Text("Language Settings")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Transcription Language")
                            .font(.subheadline)
                        
                        Picker("Language", selection: $viewModel.selectedLanguage) {
                            ForEach(LanguageUtil.availableLanguages, id: \.self) { code in
                                Text(LanguageUtil.languageNames[code] ?? code)
                                    .tag(code)
                            }
                        }
                        .pickerStyle(.menu)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(.controlBackgroundColor))
                        .cornerRadius(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        
                        Toggle(isOn: $viewModel.translateToEnglish) {
                            Text("Translate to English")
                                .font(.subheadline)
                        }
                        .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                        .padding(.top, 4)
                    }
                }
                .padding()
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                
                // Output Options
                VStack(alignment: .leading, spacing: 16) {
                    Text("Output Options")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(isOn: $viewModel.showTimestamps) {
                            Text("Show Timestamps")
                                .font(.subheadline)
                        }
                        .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                        
                        Toggle(isOn: $viewModel.suppressBlankAudio) {
                            Text("Suppress Blank Audio")
                                .font(.subheadline)
                        }
                        .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                    }
                }
                .padding()
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                
                // Initial Prompt
                VStack(alignment: .leading, spacing: 16) {
                    Text("Initial Prompt")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        TextEditor(text: $viewModel.initialPrompt)
                            .frame(height: 60)
                            .padding(6)
                            .background(Color(.textBackgroundColor))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                            )
                        
                        Text("Optional text to guide the model's transcription")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                
                // Transcriptions Directory
                VStack(alignment: .leading, spacing: 16) {
                    Text("Transcriptions Directory")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Directory:")
                                .font(.subheadline)
                            Spacer()
                            Button(action: {
                                NSWorkspace.shared.open(Recording.recordingsDirectory)
                            }) {
                                Label("Open Folder", systemImage: "folder")
                                    .font(.subheadline)
                            }
                            .buttonStyle(.borderless)
                            .help("Open transcriptions directory")
                        }
                        
                        Text(Recording.recordingsDirectory.path)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                            .padding(8)
                            .background(Color(.textBackgroundColor).opacity(0.5))
                            .cornerRadius(6)
                    }
                }
                .padding()
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
    }
    
    private var advancedSettings: some View {
        Form {
            VStack(spacing: 20) {
                // Decoding Strategy
                VStack(alignment: .leading, spacing: 16) {
                    Text("Decoding Strategy")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(isOn: $viewModel.useBeamSearch) {
                            Text("Use Beam Search")
                                .font(.subheadline)
                        }
                        .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                        .help("Beam search can provide better results but is slower")
                        
                        if viewModel.useBeamSearch {
                            HStack {
                                Text("Beam Size:")
                                    .font(.subheadline)
                                Spacer()
                                Stepper("\(viewModel.beamSize)", value: $viewModel.beamSize, in: 1...10)
                                    .help("Number of beams to use in beam search")
                                    .frame(width: 120)
                            }
                            .padding(.leading, 24)
                        }
                    }
                }
                .padding()
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                
                // Model Parameters
                VStack(alignment: .leading, spacing: 16) {
                    Text("Model Parameters")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Temperature:")
                                    .font(.subheadline)
                                Spacer()
                                Text(String(format: "%.2f", viewModel.temperature))
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            
                            Slider(value: $viewModel.temperature, in: 0.0...1.0, step: 0.1)
                                .help("Higher values make the output more random")
                        }
                        
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("No Speech Threshold:")
                                    .font(.subheadline)
                                Spacer()
                                Text(String(format: "%.2f", viewModel.noSpeechThreshold))
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            
                            Slider(value: $viewModel.noSpeechThreshold, in: 0.0...1.0, step: 0.1)
                                .help("Threshold for detecting speech vs. silence")
                        }
                    }
                }
                .padding()
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                
                // Debug Options
                VStack(alignment: .leading, spacing: 16) {
                    Text("Debug Options")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Toggle(isOn: $viewModel.debugMode) {
                        Text("Debug Mode")
                            .font(.subheadline)
                    }
                    .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                    .help("Enable additional logging and debugging information")
                }
                .padding()
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
    }
    
    private var shortcutSettings: some View {
        Form {
            VStack(spacing: 20) {
                // Recording Shortcut
                VStack(alignment: .leading, spacing: 16) {
                    Text("Recording Shortcut")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Toggle record:")
                                .font(.subheadline)
                            Spacer()
                            KeyboardShortcuts.Recorder("", name: .toggleRecord)
                                .frame(width: 120)
                        }
                        
                        if isRecordingNewShortcut {
                            Text("Press your new shortcut combination...")
                                .foregroundColor(.secondary)
                                .font(.subheadline)
                                .padding(.vertical, 4)
                        }
                        
                        Toggle(isOn: $viewModel.playSoundOnRecordStart) {
                            Text("Play sound when recording starts")
                                .font(.subheadline)
                        }
                        .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                        .help("Play a notification sound when recording begins")
                        .padding(.top, 4)
                    }
                }
                .padding()
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                
                // Instructions
                VStack(alignment: .leading, spacing: 16) {
                    Text("Instructions")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "1.circle.fill")
                                .foregroundColor(.accentColor)
                            Text("Press any key combination to set as the recording shortcut")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "2.circle.fill")
                                .foregroundColor(.accentColor)
                            Text("The shortcut will work even when the app is in the background")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "3.circle.fill")
                                .foregroundColor(.accentColor)
                            Text("Recommended to use Command (⌘) or Option (⌥) key combinations")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding()
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
    }
    
    private var sttProviderSettings: some View {
        Form {
            VStack(spacing: 20) {
                // Provider Selection
                VStack(alignment: .leading, spacing: 16) {
                    Text("Speech-to-Text Provider")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Primary Provider")
                            .font(.subheadline)
                        
                        Picker("Provider", selection: $viewModel.selectedSTTProvider) {
                            ForEach(viewModel.availableSTTProviders, id: \.self) { provider in
                                HStack {
                                    Text(provider.displayName)
                                    if provider.requiresInternetConnection {
                                        Image(systemName: "cloud")
                                            .foregroundColor(.secondary)
                                            .font(.caption)
                                    }
                                }
                                .tag(provider)
                            }
                        }
                        .pickerStyle(.menu)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(.controlBackgroundColor))
                        .cornerRadius(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        
                        Toggle(isOn: $viewModel.enableSTTFallback) {
                            Text("Enable Fallback to Local Provider")
                                .font(.subheadline)
                        }
                        .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                        .help("Automatically fallback to local Whisper if cloud provider fails")
                        .padding(.top, 4)
                    }
                }
                .padding()
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                
                // Mistral Configuration
                if viewModel.selectedSTTProvider == .mistralVoxtral || viewModel.enableSTTFallback {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text("Mistral Voxtral Configuration")
                                .font(.headline)
                                .foregroundColor(.primary)
                            
                            Spacer()
                            
                            // Keychain status indicator
                            keychainStatusIndicator
                        }
                        
                        VStack(alignment: .leading, spacing: 12) {
                            // API Key
                            VStack(alignment: .leading, spacing: 6) {
                                Text("API Key")
                                    .font(.subheadline)
                                
                                HStack {
                                    SecureField("Enter your Mistral API key", text: $viewModel.mistralAPIKey)
                                        .textFieldStyle(.roundedBorder)
                                        .onSubmit {
                                            if !viewModel.mistralAPIKey.isEmpty {
                                                viewModel.validateMistralAPIKey()
                                            }
                                        }
                                    
                                    Button(action: {
                                        viewModel.validateMistralAPIKey()
                                    }) {
                                        switch viewModel.apiKeyValidationState {
                                        case .unknown:
                                            Image(systemName: "checkmark.circle")
                                                .foregroundColor(.gray)
                                        case .validating:
                                            ProgressView()
                                                .scaleEffect(0.8)
                                        case .valid:
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.green)
                                        case .invalid:
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundColor(.red)
                                        }
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(viewModel.mistralAPIKey.isEmpty || viewModel.apiKeyValidationState == .validating)
                                    .help("Validate API Key")
                                }
                                
                                if case .invalid(let error) = viewModel.apiKeyValidationState {
                                    Text(error)
                                        .font(.caption)
                                        .foregroundColor(.red)
                                }
                                
                                Text("Get your API key from platform.mistral.ai")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            // Model Selection
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Model")
                                    .font(.subheadline)
                                
                                Picker("Model", selection: $viewModel.mistralModel) {
                                    ForEach(viewModel.availableMistralModels, id: \.self) { model in
                                        Text(model).tag(model)
                                    }
                                }
                                .pickerStyle(.menu)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color(.controlBackgroundColor))
                                .cornerRadius(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                
                                Text("voxtral-mini-2507 is recommended for most use cases")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding()
                    .background(Color(.controlBackgroundColor).opacity(0.3))
                    .cornerRadius(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                
                // Provider Information
                VStack(alignment: .leading, spacing: 16) {
                    Text("Provider Information")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        if viewModel.selectedSTTProvider == .whisperLocal {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "cpu")
                                    .foregroundColor(.blue)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Local Processing")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Text("Uses your computer's resources. Works offline. All data stays on your device.")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        } else {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "cloud")
                                    .foregroundColor(.blue)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Cloud Processing")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Text("Faster processing with latest models. Requires internet connection. Audio sent to Mistral servers.")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        
                        let keychainState = KeychainPermissionManager.shared.checkKeychainAccess()
                        
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: keychainState.isAccessible ? "shield" : "exclamationmark.shield")
                                .foregroundColor(keychainState.isAccessible ? .green : .orange)
                            VStack(alignment: .leading, spacing: 4) {
                                if keychainState.isAccessible {
                                    Text("API keys are stored securely in macOS Keychain")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                } else {
                                    Text("Keychain access is limited. API keys may not be stored securely.")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                    Text("You can re-enable keychain access in System Preferences > Security & Privacy > Privacy > Keychain")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding()
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
    }
    
    private var keychainStatusIndicator: some View {
        let keychainState = KeychainPermissionManager.shared.checkKeychainAccess()
        
        return HStack(spacing: 4) {
            switch keychainState {
            case .available:
                Image(systemName: "checkmark.shield.fill")
                    .foregroundColor(.green)
                    .help("Keychain access available - API keys will be stored securely")
            case .denied, .restricted, .unavailable:
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundColor(.orange)
                    .help("Keychain access limited - API keys may not persist between sessions")
            case .unknown:
                Image(systemName: "questionmark.circle")
                    .foregroundColor(.gray)
                    .help("Keychain access status unknown")
            }
            
            if keychainState != .available {
                Text("Limited")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
    }
    
    private var textImprovementSettings: some View {
        Form {
            VStack(spacing: 20) {
                // Enable/Disable Text Improvement
                VStack(alignment: .leading, spacing: 16) {
                    Text("Text Enhancement")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle(isOn: $viewModel.textImprovementEnabled) {
                            Text("Enable Text Enhancement")
                                .font(.subheadline)
                        }
                        .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                        .help("Improve transcribed text for clarity and coherence using AI")
                        
                        if viewModel.textImprovementEnabled {
                            Text("Transcribed text will be improved for clarity and coherence while preserving the original meaning.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.leading, 24)
                        }
                    }
                }
                .padding()
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                
                // API Configuration
                if viewModel.textImprovementEnabled {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("OpenRouter Configuration")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        VStack(alignment: .leading, spacing: 12) {
                            // API Key
                            VStack(alignment: .leading, spacing: 6) {
                                Text("API Key")
                                    .font(.subheadline)
                                
                                HStack {
                                    SecureField("Enter your OpenRouter API key", text: $viewModel.textImprovementAPIKey)
                                        .textFieldStyle(.roundedBorder)
                                        .onSubmit {
                                            if !viewModel.textImprovementAPIKey.isEmpty {
                                                viewModel.validateTextImprovementAPIKey()
                                            }
                                        }
                                    
                                    Button(action: {
                                        viewModel.validateTextImprovementAPIKey()
                                    }) {
                                        switch viewModel.textImprovementValidationState {
                                        case .unknown:
                                            Image(systemName: "checkmark.circle")
                                                .foregroundColor(.gray)
                                        case .validating:
                                            ProgressView()
                                                .scaleEffect(0.8)
                                        case .valid:
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundColor(.green)
                                        case .invalid:
                                            Image(systemName: "xmark.circle.fill")
                                                .foregroundColor(.red)
                                        }
                                    }
                                    .buttonStyle(.borderless)
                                    .disabled(viewModel.textImprovementAPIKey.isEmpty || viewModel.textImprovementValidationState == .validating)
                                    .help("Validate API Key")
                                }
                                
                                if case .invalid(let error) = viewModel.textImprovementValidationState {
                                    Text(error)
                                        .font(.caption)
                                        .foregroundColor(.red)
                                }
                                
                                Text("Get your API key from openrouter.ai")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            // Base URL
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Base URL")
                                    .font(.subheadline)
                                
                                TextField("API Base URL", text: $viewModel.textImprovementBaseURL)
                                    .textFieldStyle(.roundedBorder)
                                    .help("OpenRouter API endpoint URL")
                                
                                Text("Default: https://openrouter.ai/api/v1/chat/completions")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            // Model Selection
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Model")
                                    .font(.subheadline)
                                
                                TextField("Enter model name", text: $viewModel.textImprovementModel)
                                    .textFieldStyle(.roundedBorder)
                                    .help("Enter model name in provider/model-name format")
                                
                                Text("Use provider/model-name format (e.g., openai/gpt-4o-mini, anthropic/claude-3-haiku)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .padding()
                    .background(Color(.controlBackgroundColor).opacity(0.3))
                    .cornerRadius(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    // Prompt Configuration
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Improvement Settings")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        VStack(alignment: .leading, spacing: 12) {
                            // Custom Prompt
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Custom Prompt")
                                    .font(.subheadline)
                                
                                TextEditor(text: $viewModel.textImprovementPrompt)
                                    .frame(height: 80)
                                    .padding(6)
                                    .background(Color(.textBackgroundColor))
                                    .cornerRadius(8)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                                    )
                                
                                Text("Instructions for the AI on how to improve the text")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            // Advanced Settings Toggle
                            Toggle(isOn: $viewModel.useAdvancedTextImprovementSettings) {
                                Text("Advanced Settings")
                                    .font(.subheadline)
                            }
                            .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                            .help("Enable advanced parameters like temperature and token limits")
                            
                            if viewModel.useAdvancedTextImprovementSettings {
                                VStack(alignment: .leading, spacing: 12) {
                                    // Temperature
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text("Temperature:")
                                                .font(.subheadline)
                                            Spacer()
                                            Text(String(format: "%.1f", viewModel.textImprovementTemperature))
                                                .font(.subheadline)
                                                .foregroundColor(.secondary)
                                        }
                                        
                                        Slider(value: $viewModel.textImprovementTemperature, in: 0.0...1.0, step: 0.1)
                                            .help("Controls creativity: lower values are more conservative")
                                        
                                        Text("Leave at default (0.3) unless you need specific behavior. Higher values = more creative, lower = more conservative.")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    // Max Tokens
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text("Max Tokens:")
                                                .font(.subheadline)
                                            Spacer()
                                            Text("\(viewModel.textImprovementMaxTokens)")
                                                .font(.subheadline)
                                                .foregroundColor(.secondary)
                                        }
                                        
                                        Slider(value: .init(
                                            get: { Double(viewModel.textImprovementMaxTokens) },
                                            set: { viewModel.textImprovementMaxTokens = Int($0) }
                                        ), in: 100...4000, step: 100)
                                        .help("Maximum tokens for the improved text response")
                                        
                                        Text("Limits response length. Most providers will choose appropriate limits automatically.")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.leading, 24)
                            }
                        }
                    }
                    .padding()
                    .background(Color(.controlBackgroundColor).opacity(0.3))
                    .cornerRadius(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    
                    // Information
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Information")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "cloud")
                                    .foregroundColor(.blue)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Cloud Processing")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Text("Text is sent to OpenRouter for improvement. Requires internet connection and API credits.")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "textformat")
                                    .foregroundColor(.green)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Meaning Preservation")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Text("AI improves clarity and coherence while preserving the original meaning of your speech.")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "shield")
                                    .foregroundColor(.orange)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("API Key Security")
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                    Text("API keys are stored securely in macOS Keychain and transmitted over HTTPS.")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .padding()
                    .background(Color(.controlBackgroundColor).opacity(0.3))
                    .cornerRadius(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
    }
}
