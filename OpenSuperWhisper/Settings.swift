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
        .frame(width: 500, height: 400)
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
            }
        }
        .onAppear {
            previousModelURL = viewModel.selectedModelURL
        }
    }
    
    private var modelSettings: some View {
        Form {
            Section(header: Text("Whisper Model").bold()) {
                Picker("Model", selection: $viewModel.selectedModelURL) {
                    ForEach(viewModel.availableModels, id: \.self) { url in
                        Text(url.lastPathComponent)
                            .tag(url as URL?)
                    }
                }
                .pickerStyle(.menu)
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Models Directory:")
                            .font(.caption)
                        Button(action: {
                            NSWorkspace.shared.open(WhisperModelManager.shared.modelsDirectory)
                        }) {
                            Image(systemName: "folder")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("Open models directory")
                    }
                    Text(WhisperModelManager.shared.modelsDirectory.path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }
    
    private var transcriptionSettings: some View {
        Form {
            Section(header: Text("Language Settings").bold()) {
                Picker("Language", selection: $viewModel.selectedLanguage) {
                    ForEach(LanguageUtil.availableLanguages, id: \.self) { code in
                        Text(LanguageUtil.languageNames[code] ?? code)
                            .tag(code)
                    }
                }
                .pickerStyle(.menu)
                
                Toggle("Translate to English", isOn: $viewModel.translateToEnglish)
            }
            
            Section(header: Text("Output Options").bold()) {
                Toggle("Show Timestamps", isOn: $viewModel.showTimestamps)
                Toggle("Suppress Blank Audio", isOn: $viewModel.suppressBlankAudio)
            }
            
            Section(header: Text("Initial Prompt").bold()) {
                TextEditor(text: $viewModel.initialPrompt)
                    .frame(height: 60)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                    )
                Text("Optional text to guide the model's transcription")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    private var advancedSettings: some View {
        Form {
            Section(header: Text("Decoding Strategy").bold()) {
                Toggle("Use Beam Search", isOn: $viewModel.useBeamSearch)
                    .help("Beam search can provide better results but is slower")
                    .padding(.horizontal, 16)
                
                if viewModel.useBeamSearch {
                    HStack {
                        Text("Beam Size:")
                            .padding(.leading, 16)
                        Stepper("\(viewModel.beamSize)", value: $viewModel.beamSize, in: 1...10)
                            .help("Number of beams to use in beam search")
                            .padding(.trailing, 16)
                    }
                }
            }
            
            Section(header: Text("Model Parameters").bold()) {
                VStack(alignment: .leading) {
                    Text("Temperature: \(String(format: "%.2f", viewModel.temperature))")
                        .padding(.horizontal, 16)
                    Slider(value: $viewModel.temperature, in: 0.0...1.0, step: 0.1)
                        .help("Higher values make the output more random")
                        .padding(.horizontal, 16)
                }
                
                VStack(alignment: .leading) {
                    Text("No Speech Threshold: \(String(format: "%.2f", viewModel.noSpeechThreshold))")
                        .padding(.horizontal, 16)
                    Slider(value: $viewModel.noSpeechThreshold, in: 0.0...1.0, step: 0.1)
                        .help("Threshold for detecting speech vs. silence")
                        .padding(.horizontal, 16)
                }
            }
            
            Section(header: Text("Debug Options").bold()) {
                Toggle("Debug Mode", isOn: $viewModel.debugMode)
                    .help("Enable additional logging and debugging information")
                    .padding(.horizontal, 16)
            }
        }
    }
    
    private var shortcutSettings: some View {
        Form {
            Section(header: Text("Recording Shortcut").bold()) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        KeyboardShortcuts.Recorder("Toggle record:", name: .toggleRecord)
                    }
                    
                    if isRecordingNewShortcut {
                        Text("Press your new shortcut combination...")
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 16)
                    }
                }
            }
            
            Section(header: Text("Instructions").bold()) {
                Text("• Press any key combination to set as the recording shortcut")
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                Text("• The shortcut will work even when the app is in the background")
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                Text("• Recommended to use Command (⌘) or Option (⌥) key combinations")
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
            }
        }
    }
}
