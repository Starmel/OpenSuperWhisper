//
//  ModernSettingsView.swift
//  OpenSuperWhisper
//
//  Created by user on 05.02.2025.
//

import SwiftUI
import KeyboardShortcuts

// MARK: - Settings Categories

enum SettingsCategory: String, CaseIterable, Identifiable {
    case quickSetup = "Quick Setup"
    case recording = "Recording"
    case transcription = "Transcription"
    case providers = "Providers"
    case enhancement = "Enhancement"
    case advanced = "Advanced"
    
    var id: String { rawValue }
    
    var iconName: String {
        switch self {
        case .quickSetup: return "sparkles"
        case .recording: return "mic"
        case .transcription: return "text.bubble"
        case .providers: return "cloud"
        case .enhancement: return "text.magnifyingglass"
        case .advanced: return "gear"
        }
    }
    
    var description: String {
        switch self {
        case .quickSetup: return "Essential settings to get started"
        case .recording: return "Audio recording and shortcuts"
        case .transcription: return "Language and output options"
        case .providers: return "Speech-to-text services"
        case .enhancement: return "AI-powered text improvement"
        case .advanced: return "Advanced model parameters"
        }
    }
}

// MARK: - Navigation Direction

enum NavigationDirection {
    case previous, next
}

// MARK: - Modern Settings View

struct ModernSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @Environment(\.dismiss) var dismiss
    @State private var selectedCategory: SettingsCategory? = .quickSetup
    @State private var previousModelURL: URL?
    @State private var searchText = ""
    
    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
        }
        .navigationTitle("Settings")
        .frame(minWidth: 800, minHeight: 600)
        .toolbar { toolbarContent }
        .onAppear {
            previousModelURL = viewModel.selectedModelURL
        }
    }
    
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button("Done") {
                handleDoneAction()
            }
            .buttonStyle(.borderedProminent)
        }
        
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
                dismiss()
            }
        }
    }
    
    // MARK: - Sidebar
    
    private var sidebar: some View {
        VStack(spacing: 0) {
            // Search Bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                
                TextField("Search settings...", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(.quaternary.opacity(0.5))
            .cornerRadius(8)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            
            // Categories List
            List(selection: $selectedCategory) {
                ForEach(SettingsCategory.allCases, id: \.id) { category in
                    SidebarRow(
                        category: category,
                        isSelected: selectedCategory == category
                    )
                    .tag(category)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            
            Spacer()
            
            // Footer
            VStack(spacing: 8) {
                Divider()
                
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    
                    Text("Version 1.0.0")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .frame(minWidth: 220)
        .background(.ultraThinMaterial)
    }
    
    // MARK: - Detail View
    
    private var detailView: some View {
        ScrollView {
            LazyVStack(spacing: 24) {
                switch selectedCategory ?? .quickSetup {
                case .quickSetup:
                    quickSetupContent
                case .recording:
                    recordingContent
                case .transcription:
                    transcriptionContent
                case .providers:
                    providersContent
                case .enhancement:
                    enhancementContent
                case .advanced:
                    advancedContent
                }
            }
            .padding(24)
        }
        .background(.regularMaterial)
        .navigationTitle((selectedCategory ?? .quickSetup).rawValue)
    }
    
    // MARK: - Content Views
    
    private var quickSetupContent: some View {
        VStack(spacing: 24) {
            SettingsSection(
                title: "Essential Setup",
                description: "Configure the most important settings to get started",
                iconName: "sparkles"
            ) {
                VStack(spacing: 16) {
                    // Model Selection
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Whisper Model")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Picker("Model", selection: $viewModel.selectedModelURL) {
                            ForEach(viewModel.availableModels, id: \.self) { url in
                                Text(url.lastPathComponent)
                                    .tag(url as URL?)
                            }
                        }
                        .modernPickerStyle()
                    }
                    
                    Divider()
                    
                    // Language
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Language")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Picker("Language", selection: $viewModel.selectedLanguage) {
                            ForEach(LanguageUtil.availableLanguages, id: \.self) { code in
                                Text(LanguageUtil.languageNames[code] ?? code)
                                    .tag(code)
                            }
                        }
                        .modernPickerStyle()
                    }
                    
                    Divider()
                    
                    // Quick Toggles
                    SettingsRow(title: "Show Timestamps") {
                        Toggle("", isOn: $viewModel.showTimestamps)
                            .toggleStyle(ModernToggleStyle())
                    }
                    
                    SettingsRow(title: "Play Sound on Recording") {
                        Toggle("", isOn: $viewModel.playSoundOnRecordStart)
                            .toggleStyle(ModernToggleStyle())
                    }
                }
            }
            
            SettingsSection(
                title: "Recording Shortcut",
                description: "Set your global keyboard shortcut",
                iconName: "command"
            ) {
                SettingsRow(
                    title: "Toggle Recording",
                    subtitle: "Press to start/stop recording from anywhere"
                ) {
                    KeyboardShortcuts.Recorder("", name: .toggleRecord)
                        .frame(width: 120)
                }
            }
            
            InfoCard(
                title: "Getting Started",
                message: "These are the essential settings to get OpenSuperWhisper working. You can access more advanced options in the other categories.",
                iconName: "lightbulb",
                color: .blue
            )
        }
    }
    
    private var recordingContent: some View {
        VStack(spacing: 24) {
            SettingsSection(
                title: "Keyboard Shortcuts",
                description: "Configure global shortcuts for recording",
                iconName: "command"
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    SettingsRow(
                        title: "Toggle Recording",
                        subtitle: "Start and stop recording with a global shortcut"
                    ) {
                        KeyboardShortcuts.Recorder("", name: .toggleRecord)
                            .frame(width: 120)
                    }
                    
                    Divider()
                    
                    SettingsRow(
                        title: "Play Sound on Start",
                        subtitle: "Audio feedback when recording begins"
                    ) {
                        Toggle("", isOn: $viewModel.playSoundOnRecordStart)
                            .toggleStyle(ModernToggleStyle())
                    }
                }
            }
            
            SettingsSection(
                title: "Audio Settings",
                description: "Recording quality and processing options",
                iconName: "waveform"
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    SettingsRow(
                        title: "Suppress Blank Audio",
                        subtitle: "Filter out recordings with no speech detected"
                    ) {
                        Toggle("", isOn: $viewModel.suppressBlankAudio)
                            .toggleStyle(ModernToggleStyle())
                    }
                }
            }
            
            SettingsSection(
                title: "File Management",
                description: "Where your recordings are stored",
                iconName: "folder"
            ) {
                DirectoryPathRow(
                    title: "Recordings Directory",
                    path: Recording.recordingsDirectory.path
                ) {
                    NSWorkspace.shared.open(Recording.recordingsDirectory)
                }
            }
            
            InfoCard(
                title: "Pro Tip",
                message: "Use Command+` (backtick) as your recording shortcut for quick access. Choose modifier keys that won't conflict with other apps.",
                iconName: "keyboard",
                color: .green
            )
        }
    }
    
    private var transcriptionContent: some View {
        VStack(spacing: 24) {
            SettingsSection(
                title: "Language Options",
                description: "Configure speech recognition language",
                iconName: "globe"
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Source Language")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Picker("Language", selection: $viewModel.selectedLanguage) {
                            ForEach(LanguageUtil.availableLanguages, id: \.self) { code in
                                Text(LanguageUtil.languageNames[code] ?? code)
                                    .tag(code)
                            }
                        }
                        .modernPickerStyle()
                    }
                    
                    Divider()
                    
                    SettingsRow(
                        title: "Translate to English",
                        subtitle: "Automatically translate non-English speech to English"
                    ) {
                        Toggle("", isOn: $viewModel.translateToEnglish)
                            .toggleStyle(ModernToggleStyle())
                    }
                }
            }
            
            SettingsSection(
                title: "Output Formatting",
                description: "How transcribed text is displayed",
                iconName: "textformat"
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    SettingsRow(
                        title: "Show Timestamps",
                        subtitle: "Include timing information in transcription"
                    ) {
                        Toggle("", isOn: $viewModel.showTimestamps)
                            .toggleStyle(ModernToggleStyle())
                    }
                }
            }
            
            SettingsSection(
                title: "Context & Guidance",
                description: "Help the model understand your content",
                iconName: "doc.text"
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Initial Prompt")
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    TextEditor(text: $viewModel.initialPrompt)
                        .frame(height: 80)
                        .padding(8)
                        .background(.quaternary.opacity(0.5))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(.quaternary, lineWidth: 1)
                        )
                    
                    Text("Provide context or instructions to improve transcription accuracy. For example: 'This is a medical consultation' or 'Technical discussion about software development'.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
    
    private var providersContent: some View {
        VStack(spacing: 24) {
            SettingsSection(
                title: "Primary Provider",
                description: "Choose your speech-to-text service",
                iconName: "cloud"
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Service Provider")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Picker("Provider", selection: $viewModel.selectedSTTProvider) {
                            ForEach(viewModel.availableSTTProviders, id: \.self) { provider in
                                HStack {
                                    Text(provider.displayName)
                                    if provider.requiresInternetConnection {
                                        Image(systemName: "cloud")
                                            .foregroundStyle(.secondary)
                                            .font(.caption)
                                    }
                                }
                                .tag(provider)
                            }
                        }
                        .modernPickerStyle()
                    }
                    
                    Divider()
                    
                    SettingsRow(
                        title: "Enable Fallback",
                        subtitle: "Use local processing if cloud service fails"
                    ) {
                        Toggle("", isOn: $viewModel.enableSTTFallback)
                            .toggleStyle(ModernToggleStyle())
                    }
                }
            }
            
            if viewModel.selectedSTTProvider == .mistralVoxtral || viewModel.enableSTTFallback {
                SettingsSection(
                    title: "Mistral Voxtral Configuration",
                    description: "Cloud-based speech recognition settings",
                    iconName: "key"
                ) {
                    VStack(alignment: .leading, spacing: 16) {
                        APIKeyField(
                            title: "API Key",
                            placeholder: "Enter your Mistral API key",
                            helpText: "Get your API key from platform.mistral.ai",
                            apiKey: $viewModel.mistralAPIKey,
                            validationState: $viewModel.apiKeyValidationState,
                            onValidate: viewModel.validateMistralAPIKey
                        )
                        
                        Divider()
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Model")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            
                            Picker("Model", selection: $viewModel.mistralModel) {
                                ForEach(viewModel.availableMistralModels, id: \.self) { model in
                                    Text(model).tag(model)
                                }
                            }
                            .modernPickerStyle()
                            
                            Text("voxtral-mini-2507 is recommended for most use cases")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            
            SettingsSection(
                title: "Local Processing",
                description: "Whisper model configuration",
                iconName: "cpu"
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Whisper Model")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Picker("Model", selection: $viewModel.selectedModelURL) {
                            ForEach(viewModel.availableModels, id: \.self) { url in
                                Text(url.lastPathComponent)
                                    .tag(url as URL?)
                            }
                        }
                        .modernPickerStyle()
                    }
                    
                    DirectoryPathRow(
                        title: "Models Directory",
                        path: WhisperModelManager.shared.modelsDirectory.path
                    ) {
                        NSWorkspace.shared.open(WhisperModelManager.shared.modelsDirectory)
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("To add more models, download .bin files from the Whisper.cpp repository and place them in the models folder, then restart the app.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        
                        Link("Download Models", destination: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/tree/main")!)
                            .font(.caption)
                    }
                }
            }
            
            // Provider comparison
            VStack(spacing: 12) {
                InfoCard(
                    title: "Local Processing",
                    message: "Uses your computer's resources. Works offline. All data stays on your device. Free but slower.",
                    iconName: "cpu",
                    color: .blue
                )
                
                InfoCard(
                    title: "Cloud Processing",
                    message: "Faster processing with latest models. Requires internet connection. Audio sent to external servers. API costs apply.",
                    iconName: "cloud",
                    color: .orange
                )
            }
        }
    }
    
    private var enhancementContent: some View {
        VStack(spacing: 24) {
            SettingsSection(
                title: "Text Enhancement",
                description: "AI-powered text improvement",
                iconName: "text.magnifyingglass"
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    SettingsRow(
                        title: "Enable Text Enhancement",
                        subtitle: "Improve transcribed text for clarity and coherence"
                    ) {
                        Toggle("", isOn: $viewModel.textImprovementEnabled)
                            .toggleStyle(ModernToggleStyle())
                    }
                    
                    if viewModel.textImprovementEnabled {
                        Text("Transcribed text will be improved for clarity and coherence while preserving the original meaning.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 24)
                    }
                }
            }
            
            if viewModel.textImprovementEnabled {
                SettingsSection(
                    title: "OpenRouter Configuration",
                    description: "Connect to AI services for text improvement",
                    iconName: "key"
                ) {
                    VStack(alignment: .leading, spacing: 16) {
                        APIKeyField(
                            title: "API Key",
                            placeholder: "Enter your OpenRouter API key",
                            helpText: "Get your API key from openrouter.ai",
                            apiKey: $viewModel.textImprovementAPIKey,
                            validationState: $viewModel.textImprovementValidationState,
                            onValidate: viewModel.validateTextImprovementAPIKey
                        )
                        
                        Divider()
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Base URL")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            
                            TextField("API Base URL", text: $viewModel.textImprovementBaseURL)
                                .textFieldStyle(.roundedBorder)
                            
                            Text("Default: https://openrouter.ai/api/v1/chat/completions")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Divider()
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Model")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            
                            TextField("Enter model name", text: $viewModel.textImprovementModel)
                                .textFieldStyle(.roundedBorder)
                            
                            Text("Use provider/model-name format (e.g., openai/gpt-4o-mini, anthropic/claude-3-haiku)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                
                SettingsSection(
                    title: "Improvement Settings",
                    description: "Customize how text is enhanced",
                    iconName: "slider.horizontal.3"
                ) {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Custom Prompt")
                                .font(.subheadline)
                                .fontWeight(.medium)
                            
                            TextEditor(text: $viewModel.textImprovementPrompt)
                                .frame(height: 80)
                                .padding(8)
                                .background(.quaternary.opacity(0.5))
                                .cornerRadius(8)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(.quaternary, lineWidth: 1)
                                )
                            
                            Text("Instructions for the AI on how to improve the text")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Divider()
                        
                        ExpandableSection(
                            title: "Advanced Parameters",
                            subtitle: "Fine-tune enhancement behavior",
                            isAdvanced: true,
                            iconName: "slider.horizontal.3",
                            defaultExpanded: viewModel.useAdvancedTextImprovementSettings
                        ) {
                            VStack(spacing: 16) {
                                SettingsRow(
                                    title: "Use Advanced Settings",
                                    subtitle: "Enable custom temperature and token limits"
                                ) {
                                    Toggle("", isOn: $viewModel.useAdvancedTextImprovementSettings)
                                        .toggleStyle(ModernToggleStyle())
                                }
                                
                                if viewModel.useAdvancedTextImprovementSettings {
                                    VStack(spacing: 16) {
                                        SliderRow(
                                            title: "Temperature",
                                            subtitle: "Controls creativity: lower = conservative, higher = creative",
                                            value: $viewModel.textImprovementTemperature,
                                            range: 0.0...1.0,
                                            step: 0.1
                                        )
                                        
                                        maxTokensSlider
                                    }
                                }
                            }
                        }
                    }
                }
                
                VStack(spacing: 12) {
                    InfoCard(
                        title: "Cloud Processing",
                        message: "Text is sent to OpenRouter for improvement. Requires internet connection and API credits.",
                        iconName: "cloud",
                        color: .blue
                    )
                    
                    InfoCard(
                        title: "Privacy & Security",
                        message: "API keys are stored securely in macOS Keychain and transmitted over HTTPS.",
                        iconName: "shield",
                        color: .green
                    )
                }
            }
        }
    }
    
    private var advancedContent: some View {
        VStack(spacing: 24) {
            SettingsSection(
                title: "Decoding Strategy",
                description: "How the model processes audio",
                iconName: "cpu"
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    SettingsRow(
                        title: "Use Beam Search",
                        subtitle: "Better accuracy but slower processing"
                    ) {
                        Toggle("", isOn: $viewModel.useBeamSearch)
                            .toggleStyle(ModernToggleStyle())
                    }
                    
                    if viewModel.useBeamSearch {
                        beamSizeSlider
                    }
                }
            }
            
            SettingsSection(
                title: "Model Parameters",
                description: "Fine-tune model behavior",
                iconName: "slider.horizontal.3"
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    SliderRow(
                        title: "Temperature",
                        subtitle: "Randomness in output (0.0 = deterministic, 1.0 = creative)",
                        value: $viewModel.temperature,
                        range: 0.0...1.0,
                        step: 0.1
                    )
                    
                    SliderRow(
                        title: "No Speech Threshold",
                        subtitle: "Sensitivity for detecting speech vs. silence",
                        value: $viewModel.noSpeechThreshold,
                        range: 0.0...1.0,
                        step: 0.1
                    )
                }
            }
            
            SettingsSection(
                title: "Development Options",
                description: "Debugging and development features",
                iconName: "hammer"
            ) {
                VStack(alignment: .leading, spacing: 16) {
                    SettingsRow(
                        title: "Debug Mode",
                        subtitle: "Enable additional logging and debugging information"
                    ) {
                        Toggle("", isOn: $viewModel.debugMode)
                            .toggleStyle(ModernToggleStyle())
                    }
                }
            }
            
            InfoCard(
                title: "Advanced Settings",
                message: "These settings are for advanced users. The default values work well for most use cases. Changes may affect transcription quality or performance.",
                iconName: "exclamationmark.triangle",
                color: .orange
            )
        }
    }
    
    // MARK: - Helper Methods
    
    private var maxTokensSlider: some View {
        SliderRow(
            title: "Max Tokens",
            subtitle: "Maximum length of improved text response",
            value: .init(
                get: { Double(viewModel.textImprovementMaxTokens) },
                set: { viewModel.textImprovementMaxTokens = Int($0) }
            ),
            range: 100...4000,
            step: 100,
            formatter: integerFormatter
        )
    }
    
    private var beamSizeSlider: some View {
        SliderRow(
            title: "Beam Size",
            subtitle: "Number of parallel search paths",
            value: .init(
                get: { Double(viewModel.beamSize) },
                set: { viewModel.beamSize = Int($0) }
            ),
            range: 1...10,
            step: 1,
            formatter: integerFormatter
        )
    }
    
    private var integerFormatter: NumberFormatter {
        let f = NumberFormatter()
        f.numberStyle = .none
        return f
    }
    
    private func handleDoneAction() {
        if viewModel.selectedModelURL != previousModelURL {
            // Reload model if changed
            if let modelPath = viewModel.selectedModelURL?.path {
                TranscriptionService.shared.reloadModel(with: modelPath)
            }
        }
        dismiss()
    }
}

// MARK: - Sidebar Row

struct SidebarRow: View {
    let category: SettingsCategory
    let isSelected: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: category.iconName)
                .font(.body)
                .foregroundStyle(.blue)
                .frame(width: 20, height: 20)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(category.rawValue)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                
                Text(category.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        // Accessibility Support
        .accessibilityElement(children: .combine)
        .accessibilityLabel(category.rawValue)
        .accessibilityHint(category.description)
        .focusable()
    }
}

// MARK: - Preview


#Preview {
    ModernSettingsView(viewModel: SettingsViewModel())
}