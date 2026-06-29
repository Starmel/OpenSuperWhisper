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
    
    func initialize() async throws {
        let versionString = AppPreferences.shared.fluidAudioModelVersion
        let version: AsrModelVersion = versionString == "v2" ? .v2 : .v3
        
        let models = try await AsrModels.downloadAndLoad(version: version)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)

        asrManager = manager
        asrModels = models
    }
    
    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
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

        // Two file paths:
        //  • No custom dictionary  → the offline AsrManager (full accuracy, the default).
        //  • Custom dictionary set  → a sliding-window pass with vocabulary boosting, the only
        //    place FluidAudio 0.15.4 exposes decoder boosting. We feed the WAV through it
        //    rather than the mic (see `transcribeFileWithBoosting`).
        let boostTerms = activeBoostTerms()
        let rawText: String
        if boostTerms.isEmpty {
            // A fresh TDT decoder state per file keeps transcriptions independent.
            var decoderState = TdtDecoderState.make(decoderLayers: await asrManager.decoderLayerCount)
            rawText = try await asrManager.transcribe(url, decoderState: &decoderState).text
        } else {
            rawText = try await transcribeFileWithBoosting(url: url, boostTerms: boostTerms)
        }

        guard !isCancelled else {
            throw CancellationError()
        }

        // Finalize
        onProgressUpdate?(0.95)

        var processedText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if settings.shouldApplyAsianAutocorrect && !processedText.isEmpty {
            processedText = AutocorrectWrapper.format(processedText)
        }

        if settings.shouldApplyCustomDictionary {
            processedText = CustomDictionary.apply(processedText, entries: settings.customDictionaryEntries)
        }

        onProgressUpdate?(1.0)
        
        return processedText.isEmpty ? TranscriptionResult.noSpeech : processedText
    }
    
    func cancelTranscription() {
        isCancelled = true
        progressTask?.cancel()
        progressTask = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
    }
    
    func getSupportedLanguages() -> [String] {
        EngineCapabilities.supportedLanguages(
            engine: "fluidaudio", fluidAudioModelVersion: AppPreferences.shared.fluidAudioModelVersion)
    }

    /// The custom-dictionary terms to bias recognition toward, or `[]` when the dictionary
    /// is disabled/empty. Single source shared with Whisper's prompt boost and the live
    /// streaming preview (`CustomDictionary.boostTerms`).
    private func activeBoostTerms() -> [String] {
        let prefs = AppPreferences.shared
        guard prefs.customDictionaryEnabled else { return [] }
        return CustomDictionary.boostTerms(entries: prefs.customDictionaryEntries)
    }

    /// Transcribes a whole file through a `SlidingWindowAsrManager` configured with vocabulary
    /// boosting — the only API surface in FluidAudio 0.15.4 that biases the Parakeet decoder
    /// toward custom terms. The 11+2+2 `.default` window matches the offline chunking, so output
    /// quality tracks the offline path; boosting only nudges misrecognized terms.
    ///
    /// The audio comes entirely from `streamAudio(_:)` (the WAV read into one buffer, then sliced),
    /// never a microphone — `startStreaming(source:)` only records the source as metadata and opens
    /// no input device. `finish()` returns the merged transcript.
    private func transcribeFileWithBoosting(url: URL, boostTerms: [String]) async throws -> String {
        let versionString = AppPreferences.shared.fluidAudioModelVersion
        let version: AsrModelVersion = versionString == "v2" ? .v2 : .v3
        let models = try await AsrModels.downloadAndLoad(version: version)

        let manager = SlidingWindowAsrManager(config: .default)
        try await configureVocabulary(on: manager, boostTerms: boostTerms)
        try await manager.loadModels(models)
        try await manager.startStreaming(source: .system)

        let audioFile = try AVAudioFile(forReading: url)
        let format = audioFile.processingFormat
        let frameCount = AVAudioFrameCount(audioFile.length)
        guard frameCount > 0,
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else {
            await manager.cancel()
            return ""
        }
        try audioFile.read(into: buffer)

        // Feed in window-sized chunks (the manager re-buffers internally for its sliding window).
        let samplesPerChunk = Int(SlidingWindowAsrConfig.default.chunkSeconds * format.sampleRate)
        var position = 0
        let totalFrames = Int(buffer.frameLength)
        while position < totalFrames {
            if isCancelled {
                await manager.cancel()
                throw CancellationError()
            }
            let chunkSize = min(samplesPerChunk, totalFrames - position)
            guard let chunk = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunkSize))
            else { break }
            for channel in 0..<Int(format.channelCount) {
                if let src = buffer.floatChannelData?[channel], let dst = chunk.floatChannelData?[channel] {
                    for i in 0..<chunkSize { dst[i] = src[position + i] }
                }
            }
            chunk.frameLength = AVAudioFrameCount(chunkSize)
            await manager.streamAudio(chunk)
            position += chunkSize
            await Task.yield()
        }

        return try await manager.finish()
    }

    /// Configures vocabulary boosting on a `SlidingWindowAsrManager` from the dictionary terms,
    /// using the same temp-file + CTC-token approach the engine has always used. Throws on failure
    /// so the caller surfaces it rather than silently transcribing without the requested boost.
    private func configureVocabulary(on manager: SlidingWindowAsrManager, boostTerms: [String]) async throws {
        let terms = boostTerms.filter { !$0.isEmpty }
        guard !terms.isEmpty else { return }

        let vocabularyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenSuperWhisper-ParakeetVocabulary-\(UUID().uuidString)")
            .appendingPathExtension("txt")
        try terms.joined(separator: "\n").write(to: vocabularyURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: vocabularyURL) }

        let vocabulary = try await CustomVocabularyContext.loadWithCtcTokens(from: vocabularyURL.path)
        guard !vocabulary.vocab.terms.isEmpty else { return }

        try await manager.configureVocabularyBoosting(
            vocabulary: vocabulary.vocab,
            ctcModels: vocabulary.models
        )
    }
}

