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
    @Published private(set) var loadingWarning: String?

    var activeEngineName: String? { currentEngine?.engineName }
    var activePhononResult: PhononTranscriptionResult? { (currentEngine as? PhononEngine)?.lastResult }
    var activePhononPreparation: PhononPreparationResult? { (currentEngine as? PhononEngine)?.preparationMetrics }
    
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
    private var backgroundOperations: [UUID: Task<Void, Never>] = [:]
    private var shutdownTask: Task<Void, Never>?
    private var shutdownEngines: [WhisperEngine] = []
    private(set) var isShuttingDown = false

    func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        isShuttingDown = true
        engineLoadTask?.cancel()
        cancelTranscription()
        let engine = currentEngine
        let preparation = recordingPreparation
        let activeTask = transcriptionTask
        let operations = Array(backgroundOperations.values)
        let task = Task {
            _ = await activeTask?.task.result
            _ = await preparation?.task.result
            for operation in operations {
                await operation.value
            }
            for engine in shutdownEngines {
                engine.unload()
            }
            shutdownEngines.removeAll()
            (activeTask?.engine as? WhisperEngine)?.unload()
            preparation?.engine.unload()
            (engine as? WhisperEngine)?.unload()
            currentEngine = nil
            recordingPreparation = nil
            transcriptionTask = nil
            engineLoadTask = nil
            engineLoadID = nil
            isLoading = false
            isTranscribing = false
        }
        shutdownTask = task
        await task.value
    }

    func prepareForRecording() {
        guard !isShuttingDown, !isLoading, transcriptionTask == nil, recordingPreparation == nil,
              let engine = currentEngine as? WhisperEngine else { return }
        let task = Task.detached(priority: .userInitiated) {
            try engine.prepareForRecording()
        }
        recordingPreparation = RecordingPreparation(engine: engine, task: task)
        let id = UUID()
        backgroundOperations[id] = Task { [weak self] in
            _ = await task.result
            self?.backgroundOperations[id] = nil
        }
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

    struct EngineFactories {
        var makeWhisper: (String) -> PCMTranscriptionEngine
        var makeFluidAudio: (String) -> TranscriptionEngine
        var makePhonon: () -> TranscriptionEngine

        static let production = EngineFactories(
            makeWhisper: { WhisperEngine(modelPath: $0) },
            makeFluidAudio: { FluidAudioEngine(modelVersion: $0) },
            makePhonon: { PhononEngine() }
        )
    }

    @Published private(set) var loadingError: String?
    private let engineLoader: (EngineSelection) async throws -> TranscriptionEngine
    private let nativePhononLoader: (EngineSelection) async throws -> TranscriptionEngine
    private let phononFallbackLoader: (EngineSelection, Error) async throws -> TranscriptionEngine
    private var engineLoadTask: Task<TranscriptionEngine, Error>?
    private var engineLoadID: UUID?
    private var engineSelection: EngineSelection?
    private var phononLoadTask: Task<TranscriptionEngine, Error>?
    private var phononLoadID: UUID?

    init(selection: EngineSelection = .current) {
        engineLoader = { try await TranscriptionService.makeEngine($0) }
        nativePhononLoader = {
            try await TranscriptionService.makeNativePhononEngine($0)
        }
        phononFallbackLoader = {
            try await TranscriptionService.makePhononFallbackEngine($0, error: $1)
        }
        loadEngine(selection: selection)
    }

    init(
        selection: EngineSelection,
        engineLoader: @escaping (EngineSelection) async throws -> TranscriptionEngine
    ) {
        self.engineLoader = engineLoader
        nativePhononLoader = engineLoader
        phononFallbackLoader = { _, error in throw error }
        loadEngine(selection: selection)
    }

    init(
        selection: EngineSelection,
        engineLoader: @escaping (EngineSelection) async throws -> TranscriptionEngine,
        nativePhononLoader: @escaping (EngineSelection) async throws -> TranscriptionEngine,
        phononFallbackLoader: @escaping (EngineSelection, Error) async throws -> TranscriptionEngine
    ) {
        self.engineLoader = engineLoader
        self.nativePhononLoader = nativePhononLoader
        self.phononFallbackLoader = phononFallbackLoader
        loadEngine(selection: selection)
    }

    init(engine: TranscriptionEngine) {
        engineLoader = { try await TranscriptionService.makeEngine($0) }
        nativePhononLoader = {
            try await TranscriptionService.makeNativePhononEngine($0)
        }
        phononFallbackLoader = {
            try await TranscriptionService.makePhononFallbackEngine($0, error: $1)
        }
        currentEngine = engine
    }

    static func makeEngine(
        _ selection: EngineSelection,
        factories: EngineFactories = .production
    ) async throws -> TranscriptionEngine {
        switch selection.engine {
        case "fluidaudio":
            let engine = factories.makeFluidAudio(selection.modelVersion)
            try await engine.initialize()
            return engine
        case "whisper":
            guard let path = selection.modelPath else { throw TranscriptionError.contextInitializationFailed }
            let engine = factories.makeWhisper(path)
            try await engine.initialize()
            return engine
        case "phonon":
            do {
                return try await makeNativePhononEngine(selection, factories: factories)
            } catch {
                if error is CancellationError { throw CancellationError() }
                try Task.checkCancellation()
                return try await makePhononFallbackEngine(selection, error: error, factories: factories)
            }
        default:
            throw TranscriptionError.unsupportedEngine(selection.engine)
        }
    }

    private static func makeNativePhononEngine(
        _ selection: EngineSelection,
        factories: EngineFactories = .production
    ) async throws -> TranscriptionEngine {
        let engine = factories.makePhonon()
        try await engine.initialize()
        return engine
    }

    private static func makePhononFallbackEngine(
        _ selection: EngineSelection,
        error: Error,
        factories: EngineFactories = .production
    ) async throws -> TranscriptionEngine {
        guard let path = selection.modelPath else { throw error }
        let whisper = factories.makeWhisper(path)
        try await whisper.initialize()
        return FallbackPCMEngine(
            engine: whisper,
            warning: "Phonon-2 is unavailable (\(error.localizedDescription)). Using the selected Whisper model locally until Phonon-2 is repaired."
        )
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
        guard !isShuttingDown else { return }
        guard selection != engineSelection || (!isLoading && currentEngine == nil) else { return }
        engineLoadTask?.cancel()
        let pendingPhononLoad = phononLoadTask
        engineSelection = selection
        let id = UUID()
        engineLoadID = id
        currentEngine = nil
        recordingPreparation = nil
        loadingError = nil
        loadingWarning = nil
        isLoading = true
        let loader = engineLoader
        let task: Task<TranscriptionEngine, Error>
        if selection.engine == "phonon" {
            let nativeLoader = nativePhononLoader
            let fallbackLoader = phononFallbackLoader
            let nativeTask = Task.detached(priority: .userInitiated) {
                if let pendingPhononLoad {
                    _ = await pendingPhononLoad.result
                    try Task.checkCancellation()
                }
                return try await nativeLoader(selection)
            }
            phononLoadTask = nativeTask
            phononLoadID = id
            task = Task.detached(priority: .userInitiated) { [weak self] in
                let nativeResult = await withTaskCancellationHandler {
                    await nativeTask.result
                } onCancel: {
                    nativeTask.cancel()
                }
                await MainActor.run {
                    self?.finishNativePhononLoad(id: id)
                }
                switch nativeResult {
                case .success(let engine):
                    try Task.checkCancellation()
                    return engine
                case .failure(let error):
                    if error is CancellationError { throw CancellationError() }
                    try Task.checkCancellation()
                    return try await fallbackLoader(selection, error)
                }
            }
        } else {
            task = Task.detached(priority: .userInitiated) {
                if let pendingPhononLoad {
                    _ = await pendingPhononLoad.result
                    try Task.checkCancellation()
                }
                let engine = try await loader(selection)
                try Task.checkCancellation()
                return engine
            }
        }
        engineLoadTask = task
        backgroundOperations[id] = Task { [weak self] in
            let result = await task.result
            self?.finishEngineLoad(id: id, result: result)
            self?.backgroundOperations[id] = nil
        }
    }

    private func finishNativePhononLoad(id: UUID) {
        guard phononLoadID == id else { return }
        phononLoadTask = nil
        phononLoadID = nil
    }

    private func finishEngineLoad(id: UUID, result: Result<TranscriptionEngine, Error>) {
        guard !isShuttingDown else {
            if case .success(let engine as WhisperEngine) = result {
                shutdownEngines.append(engine)
            }
            return
        }
        guard engineLoadID == id else { return }
        engineLoadTask = nil
        engineLoadID = nil
        isLoading = false
        switch result {
        case .success(let engine):
            currentEngine = engine
            loadingWarning = (engine as? EngineLoadWarningProviding)?.loadWarning
        case .failure(let error): loadingError = error.localizedDescription
        }
    }

    func waitUntilReady() async throws {
        guard !isShuttingDown else { throw CancellationError() }
        while let task = engineLoadTask, let id = engineLoadID {
            let result = await task.result
            try Task.checkCancellation()
            guard !isShuttingDown else { throw CancellationError() }
            finishEngineLoad(id: id, result: result)
        }
        try Task.checkCancellation()
        guard !isShuttingDown else { throw CancellationError() }
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

        // Setup progress callback for engines through an explicit capability.
        if let progressEngine = engine as? ProgressReportingTranscriptionEngine {
            progressEngine.onProgressUpdate = { [weak self] newProgress in
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
                if let pcmSamples, let pcmEngine = engine as? PCMTranscriptionEngine {
                    result = try await pcmEngine.transcribeSamples(pcmSamples, settings: settings)
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
    case unsupportedEngine(String)
}

extension TranscriptionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .contextInitializationFailed: return "The transcription engine could not be initialized."
        case .audioConversionFailed: return "The audio could not be converted."
        case .processingFailed: return "The transcription engine could not process the audio."
        case .unsupportedEngine(let engine): return "Unknown transcription engine: \(engine)."
        }
    }
}

private protocol EngineLoadWarningProviding {
    var loadWarning: String { get }
}

private final class FallbackPCMEngine: PCMTranscriptionEngine, ProgressReportingTranscriptionEngine, EngineLoadWarningProviding {
    let engine: PCMTranscriptionEngine
    let loadWarning: String
    var engineName: String { "Whisper (Phonon fallback)" }
    var isModelLoaded: Bool { engine.isModelLoaded }
    var onProgressUpdate: ((Float) -> Void)? {
        get { (engine as? ProgressReportingTranscriptionEngine)?.onProgressUpdate }
        set { (engine as? ProgressReportingTranscriptionEngine)?.onProgressUpdate = newValue }
    }

    init(engine: PCMTranscriptionEngine, warning: String) {
        self.engine = engine
        self.loadWarning = warning
    }

    func initialize() async throws { try await engine.initialize() }
    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        try await engine.transcribeAudio(url: url, settings: settings)
    }
    func transcribeSamples(_ samples: [Float], settings: Settings) async throws -> String {
        try await engine.transcribeSamples(samples, settings: settings)
    }
    func cancelTranscription() { engine.cancelTranscription() }
    func getSupportedLanguages() -> [String] { engine.getSupportedLanguages() }
}
