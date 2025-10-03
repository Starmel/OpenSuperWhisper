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
    @Published var openAIAPIKey: String = ""
    @Published var apiKeyStatusMessage: String?
    @Published var apiKeyStatusIsError: Bool = false
    @Published var transcriptionBackend: TranscriptionBackend {
        didSet {
            AppPreferences.shared.transcriptionBackend = transcriptionBackend
        }
    }
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
    
    @Published var useAsianAutocorrect: Bool {
        didSet {
            AppPreferences.shared.useAsianAutocorrect = useAsianAutocorrect
        }
    }
    
    private let apiKeyStore = OpenAIAPIKeyStore.shared

    init() {
        let prefs = AppPreferences.shared
        self.transcriptionBackend = prefs.transcriptionBackend
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
        self.useAsianAutocorrect = prefs.useAsianAutocorrect
        self.openAIAPIKey = (try? apiKeyStore.loadKey()) ?? ""
        
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

    func persistOpenAIAPIKey() {
        let trimmed = openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.isEmpty {
                try apiKeyStore.deleteKey()
                openAIAPIKey = ""
                apiKeyStatusMessage = "Removed saved API key."
                apiKeyStatusIsError = false
            } else {
                try apiKeyStore.saveKey(trimmed)
                if trimmed != openAIAPIKey {
                    openAIAPIKey = trimmed
                }
                apiKeyStatusMessage = "API key saved securely."
                apiKeyStatusIsError = false
            }
        } catch {
            apiKeyStatusMessage = "Could not update API key (\(error.localizedDescription))."
            apiKeyStatusIsError = true
        }
    }

    func reloadOpenAIAPIKeyFromStore() {
        do {
            openAIAPIKey = try apiKeyStore.loadKey() ?? ""
        } catch {
            apiKeyStatusMessage = "Could not read API key (\(error.localizedDescription))."
            apiKeyStatusIsError = true
        }
    }

    func clearAPIKeyStatus() {
        apiKeyStatusMessage = nil
        apiKeyStatusIsError = false
    }
}

struct Settings {
    var selectedLanguage: String
    var translateToEnglish: Bool
    var suppressBlankAudio: Bool
    var transcriptionBackend: TranscriptionBackend
    var showTimestamps: Bool
    var temperature: Double
    var noSpeechThreshold: Double
    var initialPrompt: String
    var useBeamSearch: Bool
    var beamSize: Int
    var useAsianAutocorrect: Bool
    
    init() {
        let prefs = AppPreferences.shared
        self.selectedLanguage = prefs.whisperLanguage
        self.translateToEnglish = prefs.translateToEnglish
        self.suppressBlankAudio = prefs.suppressBlankAudio
        self.transcriptionBackend = prefs.transcriptionBackend
        self.showTimestamps = prefs.showTimestamps
        self.temperature = prefs.temperature
        self.noSpeechThreshold = prefs.noSpeechThreshold
        self.initialPrompt = prefs.initialPrompt
        self.useBeamSearch = prefs.useBeamSearch
        self.beamSize = prefs.beamSize
        self.useAsianAutocorrect = prefs.useAsianAutocorrect
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
            // Model Settings
            modelSettings
                .tabItem {
                    Label("Model", systemImage: "cpu")
                }
                .tag(1)
            
            // Transcription Settings
            transcriptionSettings
                .tabItem {
                    Label("Transcription", systemImage: "text.bubble")
                }
                .tag(2)
            
            // Advanced Settings
            advancedSettings
                .tabItem {
                    Label("Advanced", systemImage: "gear")
                }
                .tag(3)
            }
        .padding()
        .frame(width: 550)
        .background(Color(.windowBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("Done") {
                    if viewModel.transcriptionBackend == .local,
                       let selectedModel = viewModel.selectedModelURL,
                       selectedModel != previousModelURL {
                        TranscriptionService.shared.reloadModel(with: selectedModel.path)
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
        .onChange(of: viewModel.transcriptionBackend) { backend in
            if backend == .openAI {
                viewModel.reloadOpenAIAPIKeyFromStore()
            } else {
                viewModel.clearAPIKeyStatus()
            }
        }
    }
    
    private var modelSettings: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Transcription Backend")
                        .font(.headline)
                        .foregroundColor(.primary)

                    Picker("Backend", selection: $viewModel.transcriptionBackend) {
                        ForEach(TranscriptionBackend.allCases) { backend in
                            Text(backend.displayName).tag(backend)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(viewModel.transcriptionBackend.helpText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding()
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
            }
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
            .disabled(viewModel.transcriptionBackend == .openAI)

            if viewModel.transcriptionBackend == .openAI {
                Section {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("OpenAI API Key")
                            .font(.headline)
                            .foregroundColor(.primary)

                        SecureField("sk-...", text: $viewModel.openAIAPIKey)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: viewModel.openAIAPIKey) { _ in
                                viewModel.clearAPIKeyStatus()
                            }

                        if viewModel.openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Label("Add an API key before using the OpenAI backend.", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }

                        HStack(spacing: 12) {
                            Button("Save Key") {
                                viewModel.persistOpenAIAPIKey()
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Clear") {
                                viewModel.openAIAPIKey = ""
                                viewModel.persistOpenAIAPIKey()
                            }
                            .buttonStyle(.bordered)
                        }

                        if let message = viewModel.apiKeyStatusMessage {
                            Text(message)
                                .font(.caption)
                                .foregroundColor(viewModel.apiKeyStatusIsError ? .red : .secondary)
                        }

                        Text("Your key is stored securely in the macOS Keychain and never leaves this Mac except when contacting OpenAI.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Link("Manage OpenAI API keys", destination: URL(string: "https://platform.openai.com/account/api-keys")!)
                            .font(.caption)
                    }
                    .padding()
                    .background(Color(.controlBackgroundColor).opacity(0.3))
                    .cornerRadius(12)
                }
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
                        
                        if ["zh", "ja", "ko"].contains(viewModel.selectedLanguage) {
                            Toggle(isOn: $viewModel.useAsianAutocorrect) {
                                Text("Use Asian Autocorrect")
                                    .font(.subheadline)
                            }
                            .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                            .padding(.top, 4)
                        }
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
}
