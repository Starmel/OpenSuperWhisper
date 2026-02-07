//
//  OnboardingView.swift
//  OpenSuperWhisper
//
//  Created by user on 08.02.2025.
//

import Foundation
import SwiftUI
import FluidAudio

enum OnboardingShortcutOption: String, CaseIterable {
    case keyCombination
    case rightOption
}

class OnboardingViewModel: ObservableObject {
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
    
    @Published var selectedShortcut: OnboardingShortcutOption {
        didSet {
            switch selectedShortcut {
            case .keyCombination:
                AppPreferences.shared.modifierOnlyHotkey = ModifierKey.none.rawValue
            case .rightOption:
                AppPreferences.shared.modifierOnlyHotkey = ModifierKey.rightOption.rawValue
            }
            NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
        }
    }

    @Published var unifiedModels: [OnboardingUnifiedModel] = []
    @Published var selectedModelId: UUID?
    @Published var isDownloading: Bool = false
    @Published var downloadProgress: Double = 0.0
    @Published var downloadingModelName: String?

    private let modelManager = WhisperModelManager.shared
    private var downloadTask: Task<Void, Error>?

    init() {
        let systemLanguage = LanguageUtil.getSystemLanguage()
        AppPreferences.shared.whisperLanguage = systemLanguage
        self.selectedLanguage = systemLanguage
        self.useAsianAutocorrect = AppPreferences.shared.useAsianAutocorrect
        
        let currentHotkey = ModifierKey(rawValue: AppPreferences.shared.modifierOnlyHotkey) ?? .none
        if currentHotkey == .none && !AppPreferences.shared.hasCompletedOnboarding {
            self.selectedShortcut = .rightOption
            AppPreferences.shared.modifierOnlyHotkey = ModifierKey.rightOption.rawValue
            NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
        } else {
            self.selectedShortcut = currentHotkey == .rightOption ? .rightOption : .keyCombination
        }
        
        initializeUnifiedModels()
    }

    func initializeUnifiedModels() {
        unifiedModels = OnboardingUnifiedModels.availableModels.map { model in
            var updatedModel = model
            switch model.type {
            case .whisper(let url, _):
                let filename = url.lastPathComponent
                updatedModel.isDownloaded = modelManager.isModelDownloaded(name: filename)
            case .parakeet(let version):
                updatedModel.isDownloaded = isFluidAudioModelDownloaded(version: version)
            }
            return updatedModel
        }
        
        if selectedModelId == nil, let firstDownloaded = unifiedModels.first(where: { $0.isDownloaded }) {
            selectedModelId = firstDownloaded.id
        }
    }
    
    func isFluidAudioModelDownloaded(version: String) -> Bool {
        let asrVersion: AsrModelVersion = version == "v2" ? .v2 : .v3
        let cacheDirectory = AsrModels.defaultCacheDirectory(for: asrVersion)
        return AsrModels.modelsExist(at: cacheDirectory, version: asrVersion)
    }
    
    var canContinue: Bool {
        guard let selectedId = selectedModelId else { return false }
        return unifiedModels.contains { $0.id == selectedId && $0.isDownloaded }
    }
    
    func selectModel(_ model: OnboardingUnifiedModel) {
        selectedModelId = model.id
        
        switch model.type {
        case .whisper(let url, _):
            AppPreferences.shared.selectedEngine = "whisper"
            let modelPath = modelManager.modelsDirectory.appendingPathComponent(url.lastPathComponent).path
            AppPreferences.shared.selectedWhisperModelPath = modelPath
        case .parakeet(let version):
            AppPreferences.shared.selectedEngine = "fluidaudio"
            AppPreferences.shared.fluidAudioModelVersion = version
        }
    }

    @MainActor
    func downloadModel(_ model: OnboardingUnifiedModel) async throws {
        guard !isDownloading else { return }
        
        isDownloading = true
        downloadingModelName = model.name
        downloadProgress = 0.0
        
        if let index = unifiedModels.firstIndex(where: { $0.id == model.id }) {
            unifiedModels[index].downloadProgress = 0.0
        }
        
        switch model.type {
        case .whisper(let url, _):
            try await downloadWhisperModel(model: model, url: url)
        case .parakeet(let version):
            try await downloadParakeetModel(model: model, version: version)
        }
    }
    
    @MainActor
    private func downloadWhisperModel(model: OnboardingUnifiedModel, url: URL) async throws {
        downloadTask = Task {
            do {
                let filename = url.lastPathComponent
                
                try await modelManager.downloadModel(url: url, name: filename) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self = self, !Task.isCancelled else { return }
                        guard let task = self.downloadTask, !task.isCancelled else { return }
                        
                        self.downloadProgress = progress
                        if let index = self.unifiedModels.firstIndex(where: { $0.id == model.id }) {
                            self.unifiedModels[index].downloadProgress = progress
                            if progress >= 1.0 {
                                self.unifiedModels[index].isDownloaded = true
                            }
                        }
                    }
                }
                
                guard !Task.isCancelled else {
                    await MainActor.run {
                        self.isDownloading = false
                        self.downloadingModelName = nil
                        self.downloadProgress = 0.0
                        if let index = self.unifiedModels.firstIndex(where: { $0.id == model.id }) {
                            self.unifiedModels[index].downloadProgress = 0.0
                        }
                    }
                    throw CancellationError()
                }
                
                await MainActor.run {
                    if let index = unifiedModels.firstIndex(where: { $0.id == model.id }) {
                        unifiedModels[index].isDownloaded = true
                        unifiedModels[index].downloadProgress = 0.0
                    }
                    selectModel(model)
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 0.0
                }
            } catch is CancellationError {
                await MainActor.run {
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 0.0
                    if let index = unifiedModels.firstIndex(where: { $0.id == model.id }) {
                        unifiedModels[index].downloadProgress = 0.0
                    }
                }
            } catch {
                await MainActor.run {
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 0.0
                    if let index = unifiedModels.firstIndex(where: { $0.id == model.id }) {
                        unifiedModels[index].downloadProgress = 0.0
                    }
                }
                throw error
            }
        }
        
        try await downloadTask?.value
    }
    
    @MainActor
    private func downloadParakeetModel(model: OnboardingUnifiedModel, version: String) async throws {
        var wasCancelled = false
        
        downloadTask = Task {
            do {
                let asrVersion: AsrModelVersion = version == "v2" ? .v2 : .v3
                
                guard !Task.isCancelled else {
                    await MainActor.run {
                        self.isDownloading = false
                        self.downloadingModelName = nil
                        self.downloadProgress = 0.0
                        if let index = self.unifiedModels.firstIndex(where: { $0.id == model.id }) {
                            self.unifiedModels[index].downloadProgress = 0.0
                        }
                    }
                    throw CancellationError()
                }
                
                let models = try await AsrModels.downloadAndLoad(version: asrVersion)
                
                guard !Task.isCancelled else {
                    await MainActor.run {
                        self.isDownloading = false
                        self.downloadingModelName = nil
                        self.downloadProgress = 0.0
                        if let index = self.unifiedModels.firstIndex(where: { $0.id == model.id }) {
                            self.unifiedModels[index].downloadProgress = 0.0
                        }
                    }
                    throw CancellationError()
                }
                
                let manager = AsrManager(config: .default)
                try await manager.initialize(models: models)
                
                await MainActor.run {
                    if let index = unifiedModels.firstIndex(where: { $0.id == model.id }) {
                        unifiedModels[index].isDownloaded = true
                        unifiedModels[index].downloadProgress = 1.0
                    }
                    selectModel(model)
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
                    if let index = unifiedModels.firstIndex(where: { $0.id == model.id }) {
                        unifiedModels[index].downloadProgress = 0.0
                    }
                }
            } catch {
                if Task.isCancelled {
                    wasCancelled = true
                    await MainActor.run {
                        isDownloading = false
                        downloadingModelName = nil
                        downloadProgress = 0.0
                        if let index = unifiedModels.firstIndex(where: { $0.id == model.id }) {
                            unifiedModels[index].downloadProgress = 0.0
                        }
                    }
                } else {
                    await MainActor.run {
                        isDownloading = false
                        downloadingModelName = nil
                        downloadProgress = 0.0
                        if let index = unifiedModels.firstIndex(where: { $0.id == model.id }) {
                            unifiedModels[index].downloadProgress = 0.0
                        }
                    }
                    throw error
                }
            }
        }
        
        do {
            try await downloadTask?.value
        } catch is CancellationError {
            wasCancelled = true
        } catch {
            if !wasCancelled {
                throw error
            }
        }
    }
    
    func cancelDownload() {
        downloadTask?.cancel()
        if let modelName = downloadingModelName {
            if let model = unifiedModels.first(where: { $0.name == modelName }) {
                if case .whisper(let url, _) = model.type {
                    let filename = url.lastPathComponent
                    modelManager.cancelDownload(name: filename)
                }
            }
            if let index = unifiedModels.firstIndex(where: { $0.name == modelName }) {
                unifiedModels[index].downloadProgress = 0.0
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
    
    private let keyboardLayoutInfo: KeyboardLayoutInfo? = KeyboardLayoutProvider.shared.resolveInfo()

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
                
                // Language Selection
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
                
                if Settings.asianLanguages.contains(viewModel.selectedLanguage) {
                    Toggle(isOn: $viewModel.useAsianAutocorrect) {
                        Text("Use Asian Autocorrect")
                            .font(.caption)
                    }
                    .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                }
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
                VStack(alignment: .leading, spacing: 20) {
                    // Shortcut Selection
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Shortcut")
                            .font(.headline)
                            .fontWeight(.semibold)
                        
                        Text("Choose how to trigger recording")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        if let layoutInfo = keyboardLayoutInfo {
                            OnboardingKeyboardView(selectedShortcut: viewModel.selectedShortcut, layoutInfo: layoutInfo)
                        }
                        
                        HStack(spacing: 8) {
                            OnboardingShortcutCard(
                                title: "⌥ + ~",
                                subtitle: "Key Combination",
                                isSelected: viewModel.selectedShortcut == .keyCombination
                            ) {
                                viewModel.selectedShortcut = .keyCombination
                            }
                            
                            OnboardingShortcutCard(
                                title: "Right ⌥",
                                subtitle: "Single Modifier Key",
                                isSelected: viewModel.selectedShortcut == .rightOption
                            ) {
                                viewModel.selectedShortcut = .rightOption
                            }
                        }
                        
                        Text("You can change this later in Settings")
                            .font(.caption2)
                            .foregroundColor(Color(.tertiaryLabelColor))
                    }
                    
                    // Model Selection
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Model")
                            .font(.headline)
                            .fontWeight(.semibold)
                        
                        Text("Download a model to get started")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        
                        VStack(spacing: 8) {
                            ForEach($viewModel.unifiedModels) { $model in
                                OnboardingUnifiedModelItemView(model: $model, viewModel: viewModel)
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

struct OnboardingUnifiedModelItemView: View {
    @Binding var model: OnboardingUnifiedModel
    @ObservedObject var viewModel: OnboardingViewModel
    @State private var showError = false
    @State private var errorMessage = ""
    
    var isSelected: Bool {
        viewModel.selectedModelId == model.id
    }
    
    var isParakeet: Bool {
        if case .parakeet = model.type { return true }
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
                
                if viewModel.isDownloading && viewModel.downloadingModelName == model.name && isParakeet {
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
                        viewModel.selectModel(model)
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
                viewModel.selectModel(model)
            }
        }
        .alert("Download Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }
}

private struct KeyCap: View {
    let label: String
    let w: CGFloat
    let h: CGFloat
    let highlighted: Bool
    
    var body: some View {
        Text(label)
            .font(.system(size: w > 20 ? 9 : 7, weight: .medium))
            .lineLimit(2)
            .multilineTextAlignment(.center)
            .frame(width: w, height: h)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(highlighted ? Color.accentColor.opacity(0.35) : Color(.controlBackgroundColor).opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(highlighted ? Color.accentColor.opacity(0.7) : Color.white.opacity(0.08), lineWidth: 1)
            )
            .foregroundColor(highlighted ? .white : .secondary)
    }
}

struct OnboardingKeyboardView: View {
    let selectedShortcut: OnboardingShortcutOption
    let layoutInfo: KeyboardLayoutInfo
    
    private let gap: CGFloat = 2
    private let pad: CGFloat = 6
    private let refUnits: CGFloat = 14.5
    private let refGaps: CGFloat = 13
    
    private static let row0Keycodes: [UInt16] = [50, 18, 19, 20, 21, 23, 22, 26, 28, 25, 29, 27, 24]
    private static let row1Keycodes: [UInt16] = [12, 13, 14, 15, 17, 16, 32, 34, 31, 35, 33, 30]
    private static let row2Keycodes: [UInt16] = [0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39]
    private static let row3Keycodes: [UInt16] = [6, 7, 8, 9, 11, 45, 46, 43, 47, 44]
    
    private func isHighlighted(_ id: String) -> Bool {
        switch selectedShortcut {
        case .keyCombination:
            return id == "leftOption" || id == "tilde"
        case .rightOption:
            return id == "rightOption"
        }
    }
    
    private func label(_ keycode: UInt16) -> String {
        layoutInfo.labels[keycode] ?? ""
    }
    
    private func u(for width: CGFloat) -> CGFloat {
        (width - pad * 2 - gap * refGaps) / refUnits
    }
    
    private func wideKey(singleCount: Int, wideCount: Int, u: CGFloat) -> CGFloat {
        let rowWidth = refUnits * u + refGaps * gap
        let singleWidth = CGFloat(singleCount) * u
        let totalGaps = CGFloat(singleCount + wideCount - 1) * gap
        return (rowWidth - singleWidth - totalGaps) / CGFloat(wideCount)
    }
    
    private func spaceWidth(singleCount: Int, cmdWidth: CGFloat, u: CGFloat) -> CGFloat {
        let rowWidth = refUnits * u + refGaps * gap
        let singleWidth = CGFloat(singleCount) * u
        let cmds = cmdWidth * 2
        let totalGaps = CGFloat(singleCount + 3) * gap
        return rowWidth - singleWidth - cmds - totalGaps
    }
    
    var body: some View {
        GeometryReader { geo in
            let u = u(for: geo.size.width)
            let h = u
            
            let backspace = refUnits * u + refGaps * gap - 13 * u - 13 * gap
            let tab = backspace
            let caps = wideKey(singleCount: 11, wideCount: 2, u: u)
            let shift = wideKey(singleCount: 10, wideCount: 2, u: u)
            let cmd = u * 1.25
            let space = spaceWidth(singleCount: 7, cmdWidth: cmd, u: u)
            
            VStack(spacing: gap) {
                HStack(spacing: gap) {
                    KeyCap(label: label(50), w: u, h: h, highlighted: isHighlighted("tilde"))
                    ForEach(Array(Self.row0Keycodes.dropFirst()), id: \.self) { kc in
                        KeyCap(label: label(kc), w: u, h: h, highlighted: false)
                    }
                    KeyCap(label: "⌫", w: backspace, h: h, highlighted: false)
                }
                
                HStack(spacing: gap) {
                    KeyCap(label: "⇥", w: tab, h: h, highlighted: false)
                    ForEach(Self.row1Keycodes, id: \.self) { kc in
                        KeyCap(label: label(kc), w: u, h: h, highlighted: false)
                    }
                    KeyCap(label: label(42), w: u, h: h, highlighted: false)
                }
                
                HStack(spacing: gap) {
                    KeyCap(label: "⇪", w: caps, h: h, highlighted: false)
                    ForEach(Self.row2Keycodes, id: \.self) { kc in
                        KeyCap(label: label(kc), w: u, h: h, highlighted: false)
                    }
                    KeyCap(label: "⏎", w: caps, h: h, highlighted: false)
                }
                
                HStack(spacing: gap) {
                    KeyCap(label: "⇧", w: shift, h: h, highlighted: false)
                    ForEach(Self.row3Keycodes, id: \.self) { kc in
                        KeyCap(label: label(kc), w: u, h: h, highlighted: false)
                    }
                    KeyCap(label: "⇧", w: shift, h: h, highlighted: false)
                }
                
                HStack(spacing: gap) {
                    KeyCap(label: "fn", w: u, h: h, highlighted: false)
                    KeyCap(label: "⌃", w: u, h: h, highlighted: false)
                    KeyCap(label: "⌥", w: u, h: h, highlighted: isHighlighted("leftOption"))
                    KeyCap(label: "⌘", w: cmd, h: h, highlighted: false)
                    KeyCap(label: "", w: space, h: h, highlighted: false)
                    KeyCap(label: "⌘", w: cmd, h: h, highlighted: false)
                    KeyCap(label: "⌥", w: u, h: h, highlighted: isHighlighted("rightOption"))
                    KeyCap(label: "←", w: u, h: h, highlighted: false)
                    VStack(spacing: 1) {
                        KeyCap(label: "↑", w: u, h: h / 2 - 0.5, highlighted: false)
                        KeyCap(label: "↓", w: u, h: h / 2 - 0.5, highlighted: false)
                    }
                    KeyCap(label: "→", w: u, h: h, highlighted: false)
                }
            }
            .padding(pad)
        }
        .frame(height: heightForWidth(450 - 24))
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.controlBackgroundColor).opacity(0.3))
        )
        .animation(.easeInOut(duration: 0.2), value: selectedShortcut)
    }
    
    private func heightForWidth(_ width: CGFloat) -> CGFloat {
        let u = u(for: width)
        return pad * 2 + u * 5 + gap * 4
    }
}

struct OnboardingShortcutCard: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color(.controlBackgroundColor).opacity(0.8) : Color(.controlBackgroundColor).opacity(0.5))
                    .shadow(color: isSelected ? Color.blue.opacity(0.2) : Color.black.opacity(0.05), radius: isSelected ? 8 : 4, x: 0, y: 2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.blue.opacity(0.3) : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    OnboardingView()
}

