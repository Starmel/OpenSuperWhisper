//
//  OnboardingView.swift
//  OpenSuperWhisper
//
//  Created by user on 08.02.2025.
//

import Foundation
import SwiftUI
import FluidAudio

class OnboardingViewModel: ObservableObject {
    @Published var selectedEngine: String {
        didSet {
            AppPreferences.shared.selectedEngine = selectedEngine
            if selectedEngine == "fluidaudio" {
                selectedWhisperModelURL = nil
                initializeFluidAudioModels()
            } else {
                initializeWhisperModels()
            }
        }
    }
    
    @Published var selectedLanguage: String {
        didSet {
            AppPreferences.shared.whisperLanguage = selectedLanguage
        }
    }
    
    @Published var useAsianAutocorrect: Bool {
        didSet {
            AppPreferences.shared.useAsianAutocorrect = useAsianAutocorrect
        }
    }

    @Published var selectedWhisperModelURL: URL? {
        didSet {
            if let url = selectedWhisperModelURL {
                AppPreferences.shared.selectedWhisperModelPath = url.path
            }
        }
    }
    @Published var downloadableModels: [SettingsDownloadableModel] = []
    @Published var downloadableFluidAudioModels: [SettingsFluidAudioModel] = []
    @Published var isDownloading: Bool = false
    @Published var downloadProgress: Double = 0.0
    @Published var downloadingModelName: String?
    
    @Published var fluidAudioModelVersion: String {
        didSet {
            AppPreferences.shared.fluidAudioModelVersion = fluidAudioModelVersion
        }
    }

    private let modelManager = WhisperModelManager.shared
    private var downloadTask: Task<Void, Error>?

    init() {
        let systemLanguage = LanguageUtil.getSystemLanguage()
        AppPreferences.shared.whisperLanguage = systemLanguage
        self.selectedLanguage = systemLanguage
        self.useAsianAutocorrect = AppPreferences.shared.useAsianAutocorrect
        self.selectedEngine = AppPreferences.shared.selectedEngine
        self.fluidAudioModelVersion = AppPreferences.shared.fluidAudioModelVersion
        initializeWhisperModels()
        initializeFluidAudioModels()
        
        if selectedEngine == "whisper", let defaultPath = AppPreferences.shared.selectedWhisperModelPath {
            self.selectedWhisperModelURL = URL(fileURLWithPath: defaultPath)
        }
    }

    func initializeWhisperModels() {
        guard selectedEngine == "whisper" else { return }
        downloadableModels = SettingsDownloadableModels.availableModels.map { model in
            var updatedModel = model
            let filename = model.url.lastPathComponent
            updatedModel.isDownloaded = modelManager.isModelDownloaded(name: filename)
            return updatedModel
        }
        
        if selectedWhisperModelURL == nil, let firstDownloaded = downloadableModels.first(where: { $0.isDownloaded }) {
            let modelPath = modelManager.modelsDirectory.appendingPathComponent(firstDownloaded.url.lastPathComponent).path
            selectedWhisperModelURL = URL(fileURLWithPath: modelPath)
        }
    }
    
    func initializeFluidAudioModels() {
        downloadableFluidAudioModels = SettingsFluidAudioModels.availableModels.map { model in
            var updatedModel = model
            updatedModel.isDownloaded = isFluidAudioModelDownloaded(version: model.version)
            return updatedModel
        }
    }
    
    func isFluidAudioModelDownloaded(version: String) -> Bool {
        let asrVersion: AsrModelVersion = version == "v2" ? .v2 : .v3
        let cacheDirectory = AsrModels.defaultCacheDirectory(for: asrVersion)
        return AsrModels.modelsExist(at: cacheDirectory, version: asrVersion)
    }
    
    var canContinue: Bool {
        if selectedEngine == "whisper" {
            if let selectedURL = selectedWhisperModelURL {
                let filename = selectedURL.lastPathComponent
                return downloadableModels.contains { $0.url.lastPathComponent == filename && $0.isDownloaded }
            }
            return false
        } else {
            // FluidAudio - проверяем что выбрана загруженная модель
            return downloadableFluidAudioModels.contains { $0.version == fluidAudioModelVersion && $0.isDownloaded }
        }
    }

    @MainActor
    func downloadModel(_ model: SettingsDownloadableModel) async throws {
        guard !isDownloading else { return }
        
        isDownloading = true
        downloadingModelName = model.name
        downloadProgress = 0.0
        
        if let index = downloadableModels.firstIndex(where: { $0.id == model.id }) {
            downloadableModels[index].downloadProgress = 0.0
        }
        
        downloadTask = Task {
            do {
                let filename = model.url.lastPathComponent
                
                try await modelManager.downloadModel(url: model.url, name: filename) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self = self, !Task.isCancelled else { return }
                        guard let task = self.downloadTask, !task.isCancelled else { return }
                        
                        self.downloadProgress = progress
                        if let index = self.downloadableModels.firstIndex(where: { $0.id == model.id }) {
                            self.downloadableModels[index].downloadProgress = progress
                            if progress >= 1.0 {
                                self.downloadableModels[index].isDownloaded = true
                            }
                        }
                    }
                }
                
                guard !Task.isCancelled else {
                    await MainActor.run {
                        self.isDownloading = false
                        self.downloadingModelName = nil
                        self.downloadProgress = 0.0
                        if let index = self.downloadableModels.firstIndex(where: { $0.id == model.id }) {
                            self.downloadableModels[index].downloadProgress = 0.0
                        }
                    }
                    throw CancellationError()
                }
                
                await MainActor.run {
                    if let index = downloadableModels.firstIndex(where: { $0.id == model.id }) {
                        downloadableModels[index].isDownloaded = true
                        downloadableModels[index].downloadProgress = 0.0
                    }
                    initializeWhisperModels()
                    let modelPath = modelManager.modelsDirectory.appendingPathComponent(filename).path
                    selectedWhisperModelURL = URL(fileURLWithPath: modelPath)
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 0.0
                }
            } catch is CancellationError {
                await MainActor.run {
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 0.0
                    if let index = downloadableModels.firstIndex(where: { $0.id == model.id }) {
                        downloadableModels[index].downloadProgress = 0.0
                    }
                }
                // Don't re-throw CancellationError - it's a manual cancellation
            } catch {
                await MainActor.run {
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 0.0
                    if let index = downloadableModels.firstIndex(where: { $0.id == model.id }) {
                        downloadableModels[index].downloadProgress = 0.0
                    }
                }
                throw error
            }
        }
        
        try await downloadTask?.value
    }
    
    @MainActor
    func downloadFluidAudioModel(_ model: SettingsFluidAudioModel) async throws {
        guard !isDownloading else { return }
        
        isDownloading = true
        downloadingModelName = model.name
        downloadProgress = 0.0
        
        if let index = downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
            downloadableFluidAudioModels[index].downloadProgress = 0.0
        }
        
        var wasCancelled = false
        
        downloadTask = Task {
            do {
                let version: AsrModelVersion = model.version == "v2" ? .v2 : .v3
                
                guard !Task.isCancelled else {
                    await MainActor.run {
                        self.isDownloading = false
                        self.downloadingModelName = nil
                        self.downloadProgress = 0.0
                        if let index = self.downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                            self.downloadableFluidAudioModels[index].downloadProgress = 0.0
                        }
                    }
                    throw CancellationError()
                }
                
                let models = try await AsrModels.downloadAndLoad(version: version)
                
                guard !Task.isCancelled else {
                    await MainActor.run {
                        self.isDownloading = false
                        self.downloadingModelName = nil
                        self.downloadProgress = 0.0
                        if let index = self.downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                            self.downloadableFluidAudioModels[index].downloadProgress = 0.0
                        }
                    }
                    throw CancellationError()
                }
                
                let manager = AsrManager(config: .default)
                try await manager.initialize(models: models)
                
                await MainActor.run {
                    if let index = downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                        downloadableFluidAudioModels[index].isDownloaded = true
                        downloadableFluidAudioModels[index].downloadProgress = 1.0
                    }
                    fluidAudioModelVersion = model.version
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 1.0
                }
            } catch is CancellationError {
                wasCancelled = true
                await MainActor.run {
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 0.0
                    if let index = downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                        downloadableFluidAudioModels[index].downloadProgress = 0.0
                    }
                }
                // Don't re-throw CancellationError - it's a manual cancellation
            } catch {
                // Check if we were cancelled before the error occurred
                if Task.isCancelled {
                    wasCancelled = true
                    await MainActor.run {
                        isDownloading = false
                        downloadingModelName = nil
                        downloadProgress = 0.0
                        if let index = downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                            downloadableFluidAudioModels[index].downloadProgress = 0.0
                        }
                    }
                } else {
                    await MainActor.run {
                        isDownloading = false
                        downloadingModelName = nil
                        downloadProgress = 0.0
                        if let index = downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                            downloadableFluidAudioModels[index].downloadProgress = 0.0
                        }
                    }
                    throw error
                }
            }
        }
        
        // Handle cancellation gracefully - don't throw if cancelled
        do {
            try await downloadTask?.value
        } catch is CancellationError {
            // Already handled in catch block above, just consume the error
            wasCancelled = true
        } catch {
            // If we were cancelled, don't throw
            if !wasCancelled {
                throw error
            }
        }
    }
    
    func cancelDownload() {
        downloadTask?.cancel()
        if let modelName = downloadingModelName {
            if selectedEngine == "whisper", let model = downloadableModels.first(where: { $0.name == modelName }) {
                let filename = model.url.lastPathComponent
                modelManager.cancelDownload(name: filename)
            }
            // Reset progress for the downloading model
            if let index = downloadableModels.firstIndex(where: { $0.name == modelName }) {
                downloadableModels[index].downloadProgress = 0.0
            }
            if let index = downloadableFluidAudioModels.firstIndex(where: { $0.name == modelName }) {
                downloadableFluidAudioModels[index].downloadProgress = 0.0
            }
        }
        isDownloading = false
        downloadingModelName = nil
        downloadProgress = 0.0
    }
}

struct OnboardingView: View {
    @StateObject private var viewModel = OnboardingViewModel()
    @EnvironmentObject private var appState: AppState
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header with gradient background
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Welcome to")
                        .font(.title2)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                    
                    Text("OpenSuperWhisper")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(
                            .white
                        )
                }
                .padding(.bottom, 8)
                
                // Language Selection (before engine selection)
                HStack(spacing: 8) {
                    
                    Picker("Language", selection: $viewModel.selectedLanguage) {
                        ForEach(LanguageUtil.availableLanguages, id: \.self) { code in
                            Text(LanguageUtil.languageNames[code] ?? code)
                                .tag(code)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 150)
                }
                
                if ["zh", "ja", "ko"].contains(viewModel.selectedLanguage) {
                    Toggle(isOn: $viewModel.useAsianAutocorrect) {
                        Text("Use Asian Autocorrect")
                            .font(.caption)
                    }
                    .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                }
                
                
                Picker("Engine", selection: $viewModel.selectedEngine) {
                    Text("Parakeet").tag("fluidaudio")
                    Text("Whisper").tag("whisper")
                }
                .pickerStyle(.segmented)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.05),
                        Color.white.opacity(0.03),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            
            Divider()
            
            // Content - Scrollable area
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(viewModel.selectedEngine == "whisper" ? "Whisper Model" : "Parakeet Model")
                        .font(.headline)
                        .fontWeight(.semibold)
                    
                    Text("Download a model to get started")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    
                    if viewModel.selectedEngine == "whisper" {
                        VStack(spacing: 8) {
                            ForEach($viewModel.downloadableModels) { $model in
                                OnboardingWhisperModelItemView(model: $model, viewModel: viewModel)
                            }
                        }
                    } else {
                        VStack(spacing: 8) {
                            ForEach($viewModel.downloadableFluidAudioModels) { $model in
                                OnboardingFluidAudioModelItemView(model: $model, viewModel: viewModel)
                            }
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            Divider()
            
            // Footer with Continue button
            HStack {
                Spacer()
                Button(action: {
                    handleContinueButtonTap()
                }) {
                    HStack(spacing: 6) {
                        Text("Continue")
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .frame(minWidth: 100)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!viewModel.canContinue || viewModel.isDownloading)
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            ZStack {
                Color(.windowBackgroundColor)
                
                // Subtle gradient overlay
                LinearGradient(
                    colors: [
                        Color.blue.opacity(0.02),
                        Color.clear,
                        Color.purple.opacity(0.02)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        )
        .alert("Download Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }

    private func handleContinueButtonTap() {
        appState.hasCompletedOnboarding = true
    }
}

struct OnboardingWhisperModelItemView: View {
    @Binding var model: SettingsDownloadableModel
    @ObservedObject var viewModel: OnboardingViewModel
    @State private var showError = false
    @State private var errorMessage = ""
    
    var isSelected: Bool {
        if let selectedURL = viewModel.selectedWhisperModelURL {
            let filename = model.url.lastPathComponent
            return selectedURL.lastPathComponent == filename
        }
        return false
    }
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(model.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    if model.isDownloaded {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundColor(.blue)
                            .imageScale(.small)
                    }
                }
                
                Text(model.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if model.downloadProgress > 0 && model.downloadProgress < 1 {
                    ProgressView(value: model.downloadProgress)
                        .progressViewStyle(LinearProgressViewStyle())
                        .frame(height: 6)
                        .padding(.top, 4)
                }
            }
            
            Spacer()
            
            if viewModel.isDownloading && viewModel.downloadingModelName == model.name {
                Button("Cancel") {
                    viewModel.cancelDownload()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if model.isDownloaded {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .imageScale(.large)
                } else {
                    Button(action: {
                        let modelPath = WhisperModelManager.shared.modelsDirectory.appendingPathComponent(model.url.lastPathComponent).path
                        viewModel.selectedWhisperModelURL = URL(fileURLWithPath: modelPath)
                    }) {
                        Text("Select")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            } else {
                Button(action: {
                    Task {
                        do {
                            try await viewModel.downloadModel(model)
                        } catch is CancellationError {
                            // Don't show error for manual cancellation
                        } catch {
                            errorMessage = error.localizedDescription
                            showError = true
                        }
                    }
                }) {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.isDownloading)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color(.controlBackgroundColor).opacity(0.8) : Color(.controlBackgroundColor).opacity(0.5))
                .shadow(color: isSelected ? Color.blue.opacity(0.2) : Color.black.opacity(0.05), radius: isSelected ? 8 : 4, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.blue.opacity(0.3) : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if model.isDownloaded && !isSelected {
                let modelPath = WhisperModelManager.shared.modelsDirectory.appendingPathComponent(model.url.lastPathComponent).path
                viewModel.selectedWhisperModelURL = URL(fileURLWithPath: modelPath)
            }
        }
        .alert("Download Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }
}

struct OnboardingFluidAudioModelItemView: View {
    @Binding var model: SettingsFluidAudioModel
    @ObservedObject var viewModel: OnboardingViewModel
    @State private var showError = false
    @State private var errorMessage = ""
    
    var isSelected: Bool {
        viewModel.fluidAudioModelVersion == model.version
    }
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(model.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    if model.isDownloaded {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundColor(.blue)
                            .imageScale(.small)
                    }
                }
                
                Text(model.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if viewModel.isDownloading && viewModel.downloadingModelName == model.name {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .scaleEffect(0.7)
                        .padding(.top, 4)
                } else if model.downloadProgress > 0 && model.downloadProgress < 1 {
                    ProgressView(value: model.downloadProgress)
                        .progressViewStyle(LinearProgressViewStyle())
                        .frame(height: 6)
                        .padding(.top, 4)
                }
            }
            
            Spacer()
            
            if viewModel.isDownloading && viewModel.downloadingModelName == model.name {
                Button("Cancel") {
                    viewModel.cancelDownload()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if model.isDownloaded {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .imageScale(.large)
                } else {
                    Button(action: {
                        viewModel.fluidAudioModelVersion = model.version
                    }) {
                        Text("Select")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            } else {
                Button(action: {
                    Task {
                        do {
                            try await viewModel.downloadFluidAudioModel(model)
                        } catch is CancellationError {
                            // Don't show error for manual cancellation
                        } catch {
                            errorMessage = error.localizedDescription
                            showError = true
                        }
                    }
                }) {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.isDownloading)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color(.controlBackgroundColor).opacity(0.8) : Color(.controlBackgroundColor).opacity(0.5))
                .shadow(color: isSelected ? Color.blue.opacity(0.2) : Color.black.opacity(0.05), radius: isSelected ? 8 : 4, x: 0, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.blue.opacity(0.3) : Color.clear, lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if model.isDownloaded && !isSelected {
                viewModel.fluidAudioModelVersion = model.version
            }
        }
        .alert("Download Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }
}

#Preview {
    OnboardingView()
}

