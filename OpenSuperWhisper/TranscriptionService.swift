import AVFoundation
import Foundation

@MainActor
class TranscriptionService: ObservableObject {
    static let shared = TranscriptionService()
    
    @Published private(set) var isTranscribing = false
    @Published private(set) var transcribedText = ""
    @Published private(set) var currentSegment = ""
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Float = 0.0
    @Published private(set) var isConverting = false
    @Published private(set) var conversionProgress: Float = 0.0
    @Published private(set) var engineError: String?

    var isEngineReady: Bool {
        currentEngine != nil && !isLoading
    }

    private var currentEngine: TranscriptionEngine?
    private var loadedEngineKind: String?
    private var totalDuration: Float = 0.0
    private var transcriptionTask: Task<String, Error>? = nil
    private var isCancelled = false
    
    init() {
        // Engines load lazily on first transcription (see ensureEngineLoaded), so
        // merely selecting an engine in Settings — or launching the app — never
        // triggers a model download. The download happens only when you actually
        // transcribe with that engine.
    }

    func cancelTranscription() {
        isCancelled = true
        currentEngine?.cancelTranscription()
        transcriptionTask?.cancel()
        transcriptionTask = nil
        
        isTranscribing = false
        currentSegment = ""
        progress = 0.0
        isCancelled = false
    }
    
    /// Initialize the engine matching the current preference if it isn't already
    /// active. Called lazily from transcribeAudio, so selecting an engine in
    /// Settings only records the choice — the model isn't downloaded/loaded until
    /// you actually transcribe with it. Heavy work runs off the main actor.
    private func ensureEngineLoaded() async {
        let selectedEngine = AppPreferences.shared.selectedEngine
        if currentEngine != nil, loadedEngineKind == selectedEngine { return }

        isLoading = true
        engineError = nil
        print("Loading engine: \(selectedEngine)")

        let result = await Task.detached(priority: .userInitiated) { () -> Result<TranscriptionEngine?, Error> in
            let engine: TranscriptionEngine?

            if selectedEngine == "fluidaudio" {
                engine = await FluidAudioEngine()
            } else if selectedEngine == "sensevoice" {
#if arch(arm64)
                engine = SenseVoiceEngine()
#else
                // SenseVoice (sherpa-onnx/onnxruntime) ships arm64-only; fall back on Intel.
                engine = await WhisperEngine()
#endif
            } else if selectedEngine == "remote" {
                engine = RemoteEngine()
            } else {
                engine = await WhisperEngine()
            }

            do {
                try await engine?.initialize()
                return .success(engine)
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success(let engine):
            currentEngine = engine
            loadedEngineKind = (engine != nil) ? selectedEngine : nil
            print("Engine loaded: \(selectedEngine)")
        case .failure(let error):
            currentEngine = nil
            loadedEngineKind = nil
            engineError = "Failed to load engine: \(error.localizedDescription)"
            print("Failed to load engine: \(error)")
        }
        isLoading = false
    }

    /// Invalidate the active engine so the next transcription re-initializes it
    /// (used when the engine selection or model changes). Intentionally does NOT
    /// load or download anything — that's deferred to next use.
    func reloadEngine() {
        currentEngine = nil
        loadedEngineKind = nil
    }
    
    func reloadModel(with path: String) {
        if AppPreferences.shared.selectedEngine == "whisper" {
            AppPreferences.shared.selectedWhisperModelPath = path
            reloadEngine()
        }
    }
    
    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
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

        // Lazily initialize the selected engine on first use (downloads a local
        // model only now, never on mere engine selection in Settings).
        await ensureEngineLoaded()

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
        } else if let fluidEngine = engine as? FluidAudioEngine {
            fluidEngine.onProgressUpdate = { [weak self] newProgress in
                Task { @MainActor in
                    guard let self = self, !self.isCancelled else { return }
                    self.progress = newProgress
                }
            }
        } else if let remoteEngine = engine as? RemoteEngine {
            remoteEngine.onProgressUpdate = { [weak self] newProgress in
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

enum TranscriptionError: Error {
    case contextInitializationFailed
    case audioConversionFailed
    case processingFailed
}
