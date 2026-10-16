import Foundation
import AVFoundation

/// The third speech engine: Qwen3-ASR 1.7B, run in-process by the vendored
/// llama.cpp through its multimodal library.
///
/// It is a different animal from the other two. whisper.cpp takes a model file
/// and self-tests it; Parakeet downloads what it needs by itself; Qwen3-ASR
/// needs **two** GGUF files the app owns and verifies (the text model and its
/// audio projector), and with either missing it cannot transcribe at all — so
/// this engine fails with the file to download instead of transcribing with
/// somebody else's weights.
final class Qwen3ASREngine: TranscriptionEngine {
    /// The value `AppPreferences.selectedEngine` holds for this engine.
    static let engineID = "qwen3asr"

    var engineName: String { "Qwen3-ASR" }

    var onProgressUpdate: ((Float) -> Void)?

    private let modelManager: Qwen3ASRModelManager
    private let threadCount: Int
    private var engine: Qwen3ASRNative?

    /// Read from the decode thread and written from the cancellation path, so it
    /// is a lock rather than a bare `Bool`.
    private final class CancellationFlag {
        private let lock = NSLock()
        private var flag = false

        var isSet: Bool {
            get {
                lock.lock()
                defer { lock.unlock() }
                return flag
            }
            set {
                lock.lock()
                flag = newValue
                lock.unlock()
            }
        }
    }

    private let isCancelled = CancellationFlag()

    var isModelLoaded: Bool { engine?.isLoaded == true }

    /// `threadCount` is the work that does not run on the GPU; the default is
    /// one thread per performance core, which is what llama.cpp's own CLI picks.
    init(modelManager: Qwen3ASRModelManager = .shared,
         threadCount: Int = ProcessInfo.processInfo.activeProcessorCount) {
        self.modelManager = modelManager
        self.threadCount = max(1, threadCount)
    }

    /// Loads both GGUF files, fetching whatever is missing first.
    ///
    /// The download is the app's own path (`Qwen3ASRModelManager`: URLSession
    /// progress, atomic install, pinned digest checked before the file becomes
    /// the engine's) — the same shape as the Parakeet engine's
    /// `AsrModels.downloadAndLoad` on first use. Selecting the engine is
    /// therefore enough to dictate with it: the Model tab lists the two files so
    /// they can be seen and removed, but a first run does not have to find a
    /// button before it can transcribe.
    ///
    /// A download that fails — no network, a digest that does not match, no disk
    /// — throws with what failed, and the engine does not fall back to another
    /// one's weights.
    func initialize() async throws {
        try await installWeightsIfNeeded()

        let paths = try modelManager.requireInstalledPaths()
        engine = try Qwen3ASRNative(textModelPath: paths.model,
                                    projectorPath: paths.projector,
                                    threadCount: threadCount)
    }

    private func installWeightsIfNeeded() async throws {
        let missing = modelManager.missingFiles
        guard !missing.isEmpty else { return }
        try DiskSpaceUtil.ensureEnoughFreeSpaceForModelDownload()

        for (index, file) in missing.enumerated() {
            try Task.checkCancellation()
            // Reported as the load's own progress: whoever installed an
            // `onProgressUpdate` sees the first file fill half the range and the
            // second the rest. Nothing is watching on a cold start — the app
            // shows the engine loading, like it does for Parakeet's download.
            let base = Float(index) / Float(missing.count)
            let span = 1.0 / Float(missing.count)
            try await withTaskCancellationHandler {
                try await modelManager.download(file) { [weak self] progress in
                    self?.onProgressUpdate?(base + Float(progress) * span)
                }
            } onCancel: {
                modelManager.cancelDownload(fileID: file.id)
            }
        }
        onProgressUpdate?(1.0)
    }

    /// Frees the weights: a 2.5 GB model that nothing is transcribing with
    /// should not stay resident.
    func unload() {
        engine?.unload()
        engine = nil
    }

    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        guard let engine else {
            throw TranscriptionError.contextInitializationFailed
        }

        isCancelled.isSet = false
        onProgressUpdate?(0.02)

        // The samples are the same 16 kHz mono float PCM whisper decodes, so the
        // app has one loader for both engines. It only decodes a file — the
        // throwaway whisper engine behind it holds no model.
        let samples = try await WhisperEngine().convertAudioToPCM(
            fileURL: url,
            cancellationCheck: { self.isCancelled.isSet }
        )
        guard !isCancelled.isSet else { throw CancellationError() }
        guard let samples, !samples.isEmpty else {
            throw TranscriptionError.audioConversionFailed
        }

        onProgressUpdate?(0.35)

        // Off the main actor: the decode is seconds of Metal work.
        let transcript: String
        do {
            transcript = try await Task.detached(priority: .userInitiated) {
                try engine.transcribe(samples: samples)
            }.value
        } catch {
            // A decode stopped by `cancelTranscription()` fails with the
            // bridge's own message; the app's cancellation is the same event
            // spelled the way `TranscriptionService` expects it.
            if isCancelled.isSet { throw CancellationError() }
            throw error
        }

        guard !isCancelled.isSet else { throw CancellationError() }
        onProgressUpdate?(0.95)

        var processedText = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        // Qwen3-ASR answers in the language it heard, and the engine reports no
        // language of its own here, so the transcript itself is the signal: the
        // CJK autocorrect applies when the text is written in one of the scripts
        // it exists for — exactly like the Parakeet path.
        if settings.shouldApplyAsianAutocorrect(detectedLanguage: nil, text: processedText),
           !processedText.isEmpty {
            processedText = AutocorrectWrapper.format(processedText)
        }

        onProgressUpdate?(1.0)

        return processedText
    }

    func cancelTranscription() {
        isCancelled.isSet = true
        engine?.cancel()
    }

    /// The model detects the language of each utterance itself and cannot be
    /// told one from the app's settings, so "auto" is the only entry.
    func getSupportedLanguages() -> [String] { ["auto"] }
}
