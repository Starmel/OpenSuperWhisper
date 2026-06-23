#if arch(arm64)
import AVFoundation
import Foundation

/// Local Moonshine engine (English) via sherpa-onnx. Low-latency model built for live / short-form
/// speech — fast and fully on-device. English-only by design.
final class MoonshineEngine: TranscriptionEngine {
    var engineName: String { "Moonshine" }

    private var recognizer: SherpaOnnxOfflineRecognizer?
    private var isCancelled = false

    var isModelLoaded: Bool { recognizer != nil }

    func initialize() async throws {
        let mgr = MoonshineModelManager.shared
        guard mgr.isDownloaded else { throw TranscriptionError.contextInitializationFailed }

        // Moonshine v2 — a fused encoder + merged decoder (no separate preprocessor/cached pair).
        let moonshine = sherpaOnnxOfflineMoonshineModelConfig(
            encoder: mgr.encoderPath.path,
            mergedDecoder: mgr.mergedDecoderPath.path
        )
        let modelConfig = sherpaOnnxOfflineModelConfig(
            tokens: mgr.tokensPath.path,
            numThreads: 2,
            provider: "cpu",
            debug: 0,
            moonshine: moonshine
        )
        let featConfig = sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80)
        var config = sherpaOnnxOfflineRecognizerConfig(featConfig: featConfig, modelConfig: modelConfig)
        recognizer = SherpaOnnxOfflineRecognizer(config: &config)
    }

    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        guard let recognizer else { throw TranscriptionError.contextInitializationFailed }
        isCancelled = false

        let samples = try Self.read16kMonoFloat(url: url)
        guard !isCancelled else { throw CancellationError() }

        // Decode is synchronous + CPU-bound; this runs off the main thread (queue Task).
        let result = recognizer.decode(samples: samples, sampleRate: 16000)
        guard !isCancelled else { throw CancellationError() }

        var text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if settings.shouldApplyCustomDictionary {
            text = CustomDictionary.apply(text, entries: settings.customDictionaryEntries)
        }
        return text.isEmpty ? TranscriptionResult.noSpeech : text
    }

    func cancelTranscription() { isCancelled = true }

    func getSupportedLanguages() -> [String] { [MoonshineModelManager.shared.language] }

    /// Reads any audio file and returns 16 kHz mono float32 samples (the model's required input).
    private static func read16kMonoFloat(url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let srcFormat = file.processingFormat
        guard let dstFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                            channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            throw TranscriptionError.audioConversionFailed
        }
        converter.sampleRateConverterQuality = AVAudioQuality.medium.rawValue

        guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat,
                                               frameCapacity: AVAudioFrameCount(file.length)) else {
            throw TranscriptionError.audioConversionFailed
        }
        try file.read(into: srcBuffer)

        let ratio = 16000.0 / srcFormat.sampleRate
        let dstCapacity = AVAudioFrameCount(Double(srcBuffer.frameLength) * ratio) + 4096
        guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: dstCapacity) else {
            throw TranscriptionError.audioConversionFailed
        }

        var fed = false
        var convError: NSError?
        converter.convert(to: dstBuffer, error: &convError) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return srcBuffer
        }
        if let convError { throw convError }

        guard let channel = dstBuffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channel[0], count: Int(dstBuffer.frameLength)))
    }
}
#endif
