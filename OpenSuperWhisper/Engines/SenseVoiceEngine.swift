import Foundation
import AVFoundation

class SenseVoiceEngine: TranscriptionEngine {
    var engineName: String { "SenseVoice" }

    private static let supportedLanguages = ["auto", "zh", "en", "ja", "ko", "yue"]

    private var recognizer: SherpaOnnxOfflineRecognizer?
    private var isCancelled = false

    var onProgressUpdate: ((Float) -> Void)?

    var isModelLoaded: Bool {
        recognizer != nil
    }

    func initialize() async throws {
        let variant = SenseVoiceVariant(rawValue: AppPreferences.shared.senseVoiceModelVariant) ?? .int8
        let manager = SenseVoiceModelManager.shared

        guard manager.isModelDownloaded(variant: variant) else {
            throw TranscriptionError.contextInitializationFailed
        }

        let modelPath = manager.modelPath(for: variant).path
        let tokensPath = manager.tokensPath(for: variant).path

        let nThreads = max(2, min(ProcessInfo.processInfo.activeProcessorCount, 4))

        let senseVoiceConfig = sherpaOnnxOfflineSenseVoiceModelConfig(
            model: modelPath,
            language: "auto",
            useInverseTextNormalization: true
        )

        let modelConfig = sherpaOnnxOfflineModelConfig(
            tokens: tokensPath,
            numThreads: nThreads,
            provider: "cpu",
            debug: 0,
            senseVoice: senseVoiceConfig
        )

        let featConfig = sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80)

        var recognizerConfig = sherpaOnnxOfflineRecognizerConfig(
            featConfig: featConfig,
            modelConfig: modelConfig,
            decodingMethod: "greedy_search"
        )

        recognizer = SherpaOnnxOfflineRecognizer(config: &recognizerConfig)
    }

    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        guard let recognizer = recognizer else {
            throw TranscriptionError.contextInitializationFailed
        }

        isCancelled = false
        onProgressUpdate?(0.05)

        guard let samples = try await AudioPCMConverter.convertAudioToPCM(fileURL: url) else {
            throw TranscriptionError.audioConversionFailed
        }

        guard !isCancelled else { throw CancellationError() }
        try Task.checkCancellation()

        onProgressUpdate?(0.5)

        let result = recognizer.decode(samples: samples, sampleRate: 16000)

        guard !isCancelled else { throw CancellationError() }

        onProgressUpdate?(0.95)

        var processedText = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

        if settings.shouldApplyAsianAutocorrect && !processedText.isEmpty {
            processedText = AutocorrectWrapper.format(processedText)
        }

        onProgressUpdate?(1.0)

        return processedText.isEmpty ? "No speech detected in the audio" : processedText
    }

    func cancelTranscription() {
        isCancelled = true
    }

    func getSupportedLanguages() -> [String] {
        return Self.supportedLanguages
    }
}
