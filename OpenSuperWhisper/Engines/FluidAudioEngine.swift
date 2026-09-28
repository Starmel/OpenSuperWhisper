import Foundation
import AVFoundation
import FluidAudio

class FluidAudioEngine: TranscriptionEngine {
    var engineName: String { "FluidAudio" }
    
    private var asrManager: AsrManager?
    private var asrModels: AsrModels?
    private var isCancelled = false
    private var transcriptionTask: Task<String, Error>?
    private var progressTask: Task<Void, Never>?
    
    var onProgressUpdate: ((Float) -> Void)?
    
    var isModelLoaded: Bool {
        asrManager != nil
    }
    
    private let versionString: String

    init(modelVersion: String? = nil) {
        versionString = modelVersion ?? AppPreferences.shared.fluidAudioModelVersion
    }

    func initialize() async throws {
        let version: AsrModelVersion = versionString == "v2" ? .v2 : .v3
        
        let models = try await AsrModels.downloadAndLoad(version: version)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        
        asrManager = manager
        asrModels = models
    }
    
    private enum AudioInput {
        case file(URL)
        case pcm([Float])
    }

    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        try await transcribe(input: .file(url), settings: settings)
    }

    /// Transcribes 16 kHz mono samples already mixed by the recorder.
    /// Reading the multi-channel WAV instead lets FluidAudio downmix it with
    /// AVAudioConverter, which yields silence when speech is only on one of
    /// several unlabeled channels (e.g. interfaces exposing loopback inputs).
    func transcribeSamples(_ samples: [Float], settings: Settings) async throws -> String {
        try await transcribe(input: .pcm(samples), settings: settings)
    }

    private func transcribe(input: AudioInput, settings: Settings) async throws -> String {
        guard let asrManager = asrManager else {
            throw TranscriptionError.contextInitializationFailed
        }
        
        isCancelled = false
        
        // Notify start
        onProgressUpdate?(0.02)
        
        guard !isCancelled else {
            throw CancellationError()
        }
        
        // Start progress monitoring task using FluidAudio's transcriptionProgressStream
        let onProgress = onProgressUpdate
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            guard let self = self else { return }
            
            do {
                // Get the real progress stream from FluidAudio
                let progressStream = await asrManager.transcriptionProgressStream
                
                for try await progress in progressStream {
                    guard !Task.isCancelled, !self.isCancelled else { break }
                    
                    // FluidAudio reports 0.0-1.0, we map to 0.05-0.95
                    let scaledProgress = 0.05 + Float(progress) * 0.90
                    
                    await MainActor.run {
                        onProgress?(scaledProgress)
                    }
                }
            } catch {
                // Stream finished or error
            }
        }
        
        defer {
            progressTask?.cancel()
            progressTask = nil
        }
        
        // Perform actual transcription - FluidAudio will emit progress automatically
        // FluidAudio 0.15.x requires an explicit decoder state per transcription.
        var decoderState = try TdtDecoderState(decoderLayers: await asrManager.decoderLayerCount)
        let result: ASRResult
        switch input {
        case .file(let url):
            result = try await asrManager.transcribe(url, decoderState: &decoderState)
        case .pcm(let samples):
            result = try await asrManager.transcribe(samples, decoderState: &decoderState)
        }
        
        guard !isCancelled else {
            throw CancellationError()
        }
        
        // Finalize
        onProgressUpdate?(0.95)
        
        var processedText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if settings.shouldApplyAsianAutocorrect && !processedText.isEmpty {
            processedText = AutocorrectWrapper.format(processedText)
        }
        
        onProgressUpdate?(1.0)
        
        return processedText
    }
    
    func cancelTranscription() {
        isCancelled = true
        progressTask?.cancel()
        progressTask = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
    }
    
    func getSupportedLanguages() -> [String] {
        LanguageUtil.supportedLanguages(
            engine: "fluidaudio",
            fluidAudioModelVersion: AppPreferences.shared.fluidAudioModelVersion
        )
    }
}

