//
//  OnboardingView.swift
//  OpenSuperWhisper
//
//  Created by user on 08.02.2025.
//

import Foundation
import SwiftUI

class OnboardingViewModel: ObservableObject {
    @Published var selectedLanguage: String {
        didSet {
            AppPreferences.shared.whisperLanguage = selectedLanguage
        }
    }

    @Published var selectedModel: DownloadableModel?
    @Published var models: [DownloadableModel]
    @Published var isDownloadingAny: Bool = false

    private let modelManager = WhisperModelManager.shared

    init() {
        let systemLanguage = LanguageUtil.getSystemLanguage()
        AppPreferences.shared.whisperLanguage = systemLanguage
        self.selectedLanguage = systemLanguage
        self.models = []
        initializeModels()

        if let defaultModel = models.first(where: { $0.name == "Turbo V3 large" }) {
            self.selectedModel = defaultModel
        }
    }

    private func initializeModels() {
        // Initialize models with their actual download status
        models = availableModels.map { model in
            var updatedModel = model
            updatedModel.isDownloaded = modelManager.isModelDownloaded(name: model.name)
            return updatedModel
        }
    }

    @MainActor
    func downloadSelectedModel() async throws {
        guard let model = selectedModel, !model.isDownloaded else { return }

        guard !isDownloadingAny else { return }
        isDownloadingAny = true

        do {
            // Find the index of the model we're downloading
            guard let modelIndex = models.firstIndex(where: { $0.name == model.name }) else {
                isDownloadingAny = false
                return
            }

            // Start the download with progress updates

            let filename = model.url.lastPathComponent

            try await modelManager.downloadModel(url: model.url, name: filename) { [weak self] progress in

                DispatchQueue.main.async {
                    self?.models[modelIndex].downloadProgress = progress
                    if progress >= 1.0 {
                        self?.models[modelIndex].isDownloaded = true
                        self?.isDownloadingAny = false
                        // Update the model path after successful download
                        if let modelPath = self?.modelManager.modelsDirectory.appendingPathComponent(filename).path {
                            AppPreferences.shared.selectedModelPath = modelPath
                            print("Model path after download: \(modelPath)")
                        }
                    }
                }
            }
        } catch {
            print("Failed to download model: \(error)")
            if let modelIndex = models.firstIndex(where: { $0.name == model.name }) {
                models[modelIndex].downloadProgress = 0
            }
            isDownloadingAny = false
            throw error
        }
    }
}

struct OnboardingView: View {
    @StateObject private var viewModel = OnboardingViewModel()
    @EnvironmentObject private var appState: AppState
    @State private var isDownloading = false
    @State private var showError = false
    @State private var errorMessage = ""

    var body: some View {
        ZStack {
            VStack(alignment: .leading) {
                Text("Welcome to OpenSuperWhisper!")
                    .font(.title)
                    .padding()

                // Language selection
                VStack(alignment: .leading) {
                    Text("Choose speech language")
                        .font(.headline)
                    Picker("", selection: $viewModel.selectedLanguage) {
                        ForEach(LanguageUtil.availableLanguages, id: \.self) { code in
                            Text(LanguageUtil.languageNames[code] ?? code)
                                .tag(code)
                        }
                    }
                    .frame(width: 200)
                }
                .padding()

                VStack(alignment: .leading) {
                    Text("Choose Model")
                        .font(.headline)

                    Text("The model is designed to transcribe audio into text. It is a powerful tool that can be used to transcribe audio into text.")
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }
                .padding()

                ModelListView(viewModel: viewModel)

                HStack {
                    Spacer()
                    Button(action: {
                        handleNextButtonTap()
                    }) {
                        Text("Next")
                    }
                    .padding()
                    .disabled(viewModel.selectedModel == nil || viewModel.isDownloadingAny)
                }
            }
            .padding()
            .frame(width: 450, height: 650)
            .alert("Download Error", isPresented: $showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage)
            }
        }
    }

    private func handleNextButtonTap() {
        guard let selectedModel = viewModel.selectedModel else { return }

        if selectedModel.isDownloaded {
            // If model is already downloaded, proceed immediately
            appState.hasCompletedOnboarding = true
        } else {
            // If model needs to be downloaded, start download
            Task {
                do {
                    try await viewModel.downloadSelectedModel()
                    // After successful download, proceed to the main app
                    await MainActor.run {
                        appState.hasCompletedOnboarding = true
                    }
                } catch {
                    await MainActor.run {
                        errorMessage = error.localizedDescription
                        showError = true
                    }
                }
            }
        }
    }
}

struct DownloadableModel: Identifiable {
    let id = UUID() // Add an ID for Identifiable conformance
    let name: String
    var isDownloaded: Bool
    let url: URL
    let size: Int
    var speedRate: Int
    var accuracyRate: Int
    var downloadProgress: Double = 0.0 // 0 to 1
    var isSelected: Bool = false

    var sizeString: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB] // More appropriate units
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true // Let the formatter decide
        return formatter.string(fromByteCount: Int64(size) * 1000000) // Convert to MB as your size is in MB
    }

    init(name: String, isDownloaded: Bool, url: URL, size: Int, speedRate: Int, accuracyRate: Int) {
        self.name = name
        self.isDownloaded = isDownloaded
        self.url = url
        self.size = size
        self.speedRate = speedRate
        self.accuracyRate = accuracyRate
    }

    // Example mutator to simulate download progress (you'd replace this with real logic)
    mutating func updateDownloadProgress(progress: Double) {
        downloadProgress = progress
    }
}

let availableModels = [

    DownloadableModel(
        name: "Turbo V3 large",
        isDownloaded: false,
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin?download=true")!,
        size: 1624,
        speedRate: 60,
        accuracyRate: 100
    ),
    DownloadableModel(
        name: "Turbo V3 medium",
        isDownloaded: false,
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q8_0.bin?download=true")!,
        size: 874,
        speedRate: 70,
        accuracyRate: 70
    ),
    DownloadableModel(
        name: "Turbo V3 small",
        isDownloaded: false,
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin?download=true")!,
        size: 574,
        speedRate: 100,
        accuracyRate: 60
    )
]

// UI for the model
struct DownloadableItemView: View {
    @Binding var model: DownloadableModel
    @EnvironmentObject var viewModel: OnboardingViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 12) {
                        Text(model.name)
                            .font(.headline)

                        Spacer()

                        VStack {
                            Text("Accuracy")
                            ProgressView(value: Double(model.accuracyRate), total: 100)
                                .progressViewStyle(LinearProgressViewStyle())
                                .frame(width: 64, height: 4)
                        }

                        VStack {
                            Text("Speed")
                            ProgressView(value: Double(model.speedRate), total: 100)
                                .progressViewStyle(LinearProgressViewStyle())
                                .frame(width: 64, height: 4)
                        }
                    }

                    Text(model.sizeString)
                        .font(.subheadline)
                        .foregroundColor(.gray)

                    if model.name == "Turbo V3 large" {
                        Text("Recommended!")
                            .font(.caption)
                            .foregroundColor(.green)
                            .padding(.top, 2)
                    }
                }

                Spacer()

                // Download status indicator
                if model.isDownloaded {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else if model.downloadProgress > 0 && model.downloadProgress < 1 {
                    VStack(spacing: 4) {
                        ProgressView(value: model.downloadProgress)
                            .progressViewStyle(CircularProgressViewStyle())
                            .frame(width: 30, height: 30)
                    }
                } else {
                    Image(systemName: "arrow.down.circle")
                        .foregroundColor(.gray)
                        .imageScale(.large)
                }
            }
            .padding(16)
        }
        .frame(width: 400)
        .padding(.vertical, 8)
        .background(model.name == viewModel.selectedModel?.name ? Color.gray.opacity(0.3) : Color.clear)
        .cornerRadius(16)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.selectedModel = model
        }
    }
}

struct ModelListView: View {
    @ObservedObject var viewModel: OnboardingViewModel

    var body: some View {
        VStack {
            ForEach($viewModel.models) { $model in
                DownloadableItemView(model: $model)
                    .environmentObject(viewModel)
            }
        }
        .listStyle(.bordered)
    }
}

#Preview {
    OnboardingView()
}

#Preview {
    ModelListView(viewModel: OnboardingViewModel())
}
