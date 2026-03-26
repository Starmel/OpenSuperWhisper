import AVFoundation
import Foundation

@MainActor
public class TranscriptionService: ObservableObject {
    public static let shared = TranscriptionService()

    @Published public private(set) var isTranscribing = false
    @Published public private(set) var transcribedText = ""
    @Published public private(set) var currentSegment = ""
    @Published public private(set) var isLoading = false
    @Published public private(set) var progress: Float = 0.0
    @Published public private(set) var isConverting = false
    @Published public private(set) var conversionProgress: Float = 0.0

    /// Platform provides a text post-processor (e.g., autocorrect on macOS)
    public var textPostProcessor: TextPostProcessor = NoOpTextPostProcessor()

    /// Platform provides an alternative engine factory (e.g., FluidAudioEngine on macOS).
    /// Returns nil if the platform engine is unavailable.
    public var alternateEngineFactory: (() async -> TranscriptionEngine?)?

    private var currentEngine: TranscriptionEngine?
    private var totalDuration: Float = 0.0
    private var transcriptionTask: Task<String, Error>? = nil
    private var isCancelled = false

    public init() {
        loadEngine()
    }

    public func cancelTranscription() {
        isCancelled = true
        currentEngine?.cancelTranscription()
        transcriptionTask?.cancel()
        transcriptionTask = nil

        isTranscribing = false
        currentSegment = ""
        progress = 0.0
        isCancelled = false
    }

    private func loadEngine() {
        let selectedEngine = AppPreferences.shared.selectedEngine
        print("Loading engine: \(selectedEngine)")

        isLoading = true

        Task.detached(priority: .userInitiated) {
            let engine: TranscriptionEngine?
            let postProcessor = await self.textPostProcessor

            if selectedEngine == "fluidaudio", let factory = await self.alternateEngineFactory {
                engine = await factory()
            } else {
                engine = await WhisperEngine(textPostProcessor: postProcessor)
            }

            do {
                try await engine?.initialize()

                await MainActor.run {
                    self.currentEngine = engine
                    self.isLoading = false
                    print("Engine loaded: \(selectedEngine)")
                }
            } catch {
                await MainActor.run {
                    self.isLoading = false
                    print("Failed to load engine: \(error)")
                }
            }
        }
    }

    public func reloadEngine() {
        loadEngine()
    }

    public func reloadModel(with path: String) {
        if AppPreferences.shared.selectedEngine == "whisper" {
            AppPreferences.shared.selectedWhisperModelPath = path
            reloadEngine()
        }
    }

    public func transcribeAudio(url: URL, settings: TranscriptionSettings) async throws -> String {
        await MainActor.run {
            self.progress = 0.0
            self.conversionProgress = 0.0
            self.isConverting = true
            self.isTranscribing = true
            self.transcribedText = ""
            self.currentSegment = ""
            self.isCancelled = false
        }

        defer {
            Task { @MainActor in
                self.isTranscribing = false
                self.isConverting = false
                self.currentSegment = ""
                if !self.isCancelled {
                    self.progress = 1.0
                }
                self.transcriptionTask = nil
            }
        }

        let durationInSeconds: Float = await (try? Task.detached(priority: .userInitiated) {
            let asset = AVAsset(url: url)
            let duration = try await asset.load(.duration)
            return Float(CMTimeGetSeconds(duration))
        }.value) ?? 0.0

        await MainActor.run {
            self.totalDuration = durationInSeconds
        }

        guard let engine = currentEngine else {
            throw TranscriptionError.contextInitializationFailed
        }

        // Setup progress callback for engines
        if let whisperEngine = engine as? WhisperEngine {
            whisperEngine.onProgressUpdate = { [weak self] newProgress in
                Task { @MainActor in
                    guard let self = self, !self.isCancelled else { return }
                    self.progress = newProgress
                }
            }
        }

        let task = Task.detached(priority: .userInitiated) { [weak self] in
            try Task.checkCancellation()

            let cancelled = await MainActor.run {
                guard let self = self else { return true }
                return self.isCancelled
            }

            guard !cancelled else {
                throw CancellationError()
            }

            let result = try await engine.transcribeAudio(url: url, settings: settings)

            try Task.checkCancellation()

            let finalCancelled = await MainActor.run {
                guard let self = self else { return true }
                return self.isCancelled
            }

            await MainActor.run {
                guard let self = self, !self.isCancelled else { return }
                self.transcribedText = result
                self.progress = 1.0
            }

            guard !finalCancelled else {
                throw CancellationError()
            }

            return result
        }

        await MainActor.run {
            self.transcriptionTask = task
        }

        do {
            return try await task.value
        } catch is CancellationError {
            await MainActor.run {
                self.isCancelled = true
            }
            throw TranscriptionError.processingFailed
        }
    }
}

public enum TranscriptionError: Error {
    case contextInitializationFailed
    case audioConversionFailed
    case processingFailed
}
