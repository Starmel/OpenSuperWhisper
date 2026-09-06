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
    
    private final class TranscriptionTaskBox {
        let id: UUID
        let engine: TranscriptionEngine
        let task: Task<String, Error>

        init(id: UUID, engine: TranscriptionEngine, task: Task<String, Error>) {
            self.id = id
            self.engine = engine
            self.task = task
        }
    }
    
    private var currentEngine: TranscriptionEngine?
    private var transcriptionTask: TranscriptionTaskBox? = nil
    var activeOperationID: UUID? { transcriptionTask?.id }
    private var cancellationRequestedFor: UUID?

    private struct RecordingPreparation {
        let engine: WhisperEngine
        let task: Task<Void, Error>
    }

    private var recordingPreparation: RecordingPreparation?

    func prepareForRecording() {
        guard !isLoading, transcriptionTask == nil, recordingPreparation == nil,
              let engine = currentEngine as? WhisperEngine else { return }
        recordingPreparation = RecordingPreparation(
            engine: engine,
            task: Task.detached(priority: .userInitiated) {
                try engine.prepareForRecording()
            }
        )
    }
    
    struct EngineSelection: Equatable {
        let engine: String
        let modelPath: String?
        let modelVersion: String

        static var current: Self {
            let prefs = AppPreferences.shared
            return Self(engine: prefs.selectedEngine,
                        modelPath: prefs.selectedWhisperModelPath ?? prefs.selectedModelPath,
                        modelVersion: prefs.fluidAudioModelVersion)
        }
    }

    @Published private(set) var loadingError: String?
    private let engineLoader: (EngineSelection) async throws -> TranscriptionEngine
    private var engineLoadTask: Task<TranscriptionEngine, Error>?
    private var engineLoadID: UUID?
    private var engineSelection: EngineSelection?

    init(selection: EngineSelection = .current, engineLoader: @escaping (EngineSelection) async throws -> TranscriptionEngine = TranscriptionService.makeEngine) {
        self.engineLoader = engineLoader
        loadEngine(selection: selection)
    }

    init(engine: TranscriptionEngine) {
        engineLoader = Self.makeEngine
        currentEngine = engine
    }

    private static func makeEngine(_ selection: EngineSelection) async throws -> TranscriptionEngine {
        let engine: TranscriptionEngine
        if selection.engine == "fluidaudio" {
            engine = FluidAudioEngine(modelVersion: selection.modelVersion)
        } else {
            guard let path = selection.modelPath else { throw TranscriptionError.contextInitializationFailed }
            engine = WhisperEngine(modelPath: path)
        }
        try await engine.initialize()
        return engine
    }

    func cancelTranscription() {
        guard let activeTask = transcriptionTask else { return }

        cancel(activeTask)
    }

    func cancelTranscription(operationID: UUID) {
        guard let activeTask = transcriptionTask,
              activeTask.id == operationID else { return }

        cancel(activeTask)
    }

    private func cancel(_ activeTask: TranscriptionTaskBox) {

        // Keep the task registered, and keep isTranscribing true, until the
        // engine's native call has actually returned. Clearing either here lets
        // a new recording enter the same engine while whisper.cpp is aborting.
        cancellationRequestedFor = activeTask.id
        activeTask.engine.cancelTranscription()
        activeTask.task.cancel()

        currentSegment = ""
        transcribedText = ""
        progress = 0.0
    }
    
    func loadEngine(selection: EngineSelection) {
        guard selection != engineSelection || (!isLoading && currentEngine == nil) else { return }
        engineLoadTask?.cancel()
        engineSelection = selection
        let id = UUID()
        engineLoadID = id
        currentEngine = nil
        recordingPreparation = nil
        loadingError = nil
        isLoading = true
        let loader = engineLoader
        let task = Task.detached(priority: .userInitiated) {
            let engine = try await loader(selection)
            try Task.checkCancellation()
            return engine
        }
        engineLoadTask = task
        Task { [weak self] in
            let result = await task.result
            self?.finishEngineLoad(id: id, result: result)
        }
    }

    private func finishEngineLoad(id: UUID, result: Result<TranscriptionEngine, Error>) {
        guard engineLoadID == id else { return }
        engineLoadTask = nil
        engineLoadID = nil
        isLoading = false
        switch result {
        case .success(let engine): currentEngine = engine
        case .failure(let error): loadingError = error.localizedDescription
        }
    }

    func waitUntilReady() async throws {
        while let task = engineLoadTask, let id = engineLoadID {
            let result = await task.result
            try Task.checkCancellation()
            finishEngineLoad(id: id, result: result)
        }
        try Task.checkCancellation()
        guard currentEngine != nil else { throw TranscriptionError.contextInitializationFailed }
    }

    func reloadEngine() {
        loadEngine(selection: .current)
    }

    func reloadModel(with path: String) {
        if AppPreferences.shared.selectedEngine == "whisper" {
            AppPreferences.shared.selectedWhisperModelPath = path
            reloadEngine()
        }
    }
    
    func transcribeAudio(url: URL, settings: Settings, pcmSamples: [Float]? = nil) async throws -> String {
        try await transcribeAudio(
            url: url,
            settings: settings,
            operationID: UUID(),
            pcmSamples: pcmSamples
        )
    }

    func transcribeAudio(
        url: URL,
        settings: Settings,
        operationID: UUID,
        pcmSamples: [Float]? = nil
    ) async throws -> String {
        try Task.checkCancellation()

        // Serialize access to the engine: a whisper context must not process
        // two transcriptions concurrently (indicator flow and queue flow can
        // both reach this point due to async busy checks).
        while true {
            try await waitUntilReady()
            guard let existing = transcriptionTask else { break }
            _ = try? await existing.task.value
            try Task.checkCancellation()
            if transcriptionTask === existing {
                transcriptionTask = nil
                if cancellationRequestedFor == existing.id {
                    cancellationRequestedFor = nil
                }
            }
        }
        
        progress = 0.0
        conversionProgress = 0.0
        isConverting = true
        isTranscribing = true
        transcribedText = ""
        currentSegment = ""
        cancellationRequestedFor = nil
        
        guard let engine = currentEngine else {
            isTranscribing = false
            isConverting = false
            throw TranscriptionError.contextInitializationFailed
        }

        let preparation = recordingPreparation
        recordingPreparation = nil

        // Setup progress callback for engines
        if let whisperEngine = engine as? WhisperEngine {
            whisperEngine.onProgressUpdate = { [weak self] newProgress in
                Task { @MainActor in
                    guard let self,
                          self.transcriptionTask?.id == operationID,
                          self.cancellationRequestedFor != operationID else { return }
                    self.progress = newProgress
                }
            }
        } else if let fluidEngine = engine as? FluidAudioEngine {
            fluidEngine.onProgressUpdate = { [weak self] newProgress in
                Task { @MainActor in
                    guard let self,
                          self.transcriptionTask?.id == operationID,
                          self.cancellationRequestedFor != operationID else { return }
                    self.progress = newProgress
                }
            }
        }
        
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            if let preparation, preparation.engine === engine {
                try await preparation.task.value
            }
            try Task.checkCancellation()
            
            let cancelled = await MainActor.run {
                guard let self = self else { return true }
                return self.cancellationRequestedFor == operationID
            }
            
            guard !cancelled else {
                throw CancellationError()
            }
            
            let result: String
            do {
                if let pcmSamples, let whisper = engine as? WhisperEngine {
                    result = try await whisper.transcribeSamples(pcmSamples, settings: settings)
                } else {
                    result = try await engine.transcribeAudio(url: url, settings: settings)
                }
            } catch {
                // Native engines may surface their own generic error after an
                // abort callback. Preserve cancellation as cancellation for the
                // indicator and queue instead of treating it as a failed decode.
                try Task.checkCancellation()
                let cancellationRequested = await MainActor.run {
                    guard let self = self else { return true }
                    return self.cancellationRequestedFor == operationID
                }
                if cancellationRequested {
                    throw CancellationError()
                }
                throw error
            }
            
            try Task.checkCancellation()
            
            let finalCancelled = await MainActor.run {
                guard let self = self else { return true }
                return self.cancellationRequestedFor == operationID
                    || self.transcriptionTask?.id != operationID
            }

            guard !finalCancelled else {
                throw CancellationError()
            }

            let didPublish = await MainActor.run {
                guard let self,
                      self.transcriptionTask?.id == operationID,
                      self.cancellationRequestedFor != operationID else { return false }
                self.transcribedText = result
                self.progress = 1.0
                return true
            }

            guard didPublish else { throw CancellationError() }
            try Task.checkCancellation()
            
            return result
        }
        
        let taskBox = TranscriptionTaskBox(
            id: operationID,
            engine: engine,
            task: task
        )
        transcriptionTask = taskBox

        defer {
            if transcriptionTask === taskBox {
                let wasCancelled = cancellationRequestedFor == taskBox.id
                transcriptionTask = nil
                if wasCancelled {
                    cancellationRequestedFor = nil
                    transcribedText = ""
                }
                isTranscribing = false
                isConverting = false
                currentSegment = ""
                progress = wasCancelled ? 0.0 : 1.0
            }
        }
        
        do {
            return try await task.value
        } catch is CancellationError {
            throw CancellationError()
        }
    }
}

enum TranscriptionError: Error {
    case contextInitializationFailed
    case audioConversionFailed
    case processingFailed
}
