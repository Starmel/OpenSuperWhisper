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
    
    /// The English-only-model conflict for one transcript, or `nil` when there
    /// is nothing to refuse.
    ///
    /// Only whisper can be wrong this way — the model's own context is asked
    /// (`whisper_is_multilingual() == 0`), and the file name stands in for a
    /// model that is not loaded. The evidence is the transcript itself: the
    /// manual language picker is gone, and an English-only model measures
    /// nothing, so what the text looks like is all there is.
    @MainActor
    private func speechLanguageConflict(
        engine: TranscriptionEngine,
        transcript: String,
        modelPath: String?
    ) -> SpeechLanguageConflict? {
        guard let whisper = engine as? WhisperEngine else { return nil }
        return SpeechModelLanguageGate.conflict(
            modelPath: modelPath,
            isMultilingual: whisper.isModelMultilingual,
            transcript: transcript
        )
    }

    /// The model file the transcription path is running, for the refusals that
    /// name it.
    ///
    /// The engine's own selection is the model that produced the transcript, so
    /// it wins; before one has been applied — a service built around an engine,
    /// as the tests build one — the preferences are the only answer there is.
    /// Read once, as an operation starts (`transcribeAudio`), and carried into
    /// that operation's refusals: the selection can change while a decode is in
    /// flight, and the refusal must blame the model the text came from.
    private var selectedSpeechModelPath: String? {
        engineSelection?.modelPath
            ?? AppPreferences.shared.selectedWhisperModelPath
            ?? AppPreferences.shared.selectedModelPath
    }

    /// The no-speech refusal for one transcript, or `nil` when the audio held
    /// speech — or when nothing measured it.
    private func noSpeechRefusal(
        presence: SpeechPresence?,
        threshold: Double,
        modelPath: String?
    ) -> SpeechPresenceConflict? {
        SpeechModelLanguageGate.noSpeechConflict(
            presence: presence,
            noSpeechThreshold: threshold,
            modelPath: modelPath
        )
    }

    /// The comparative refusal for one transcript, or `nil` when the second
    /// reading of the same audio contains it — and when there is no second
    /// reading at all, which refuses nothing.
    ///
    /// The reading is the engine's: the same audio, the same model, decoded once
    /// more with the decoder prompt decision flipped (`WhisperEngine`). What
    /// this decides, and the two readings it was measured against, are in
    /// `SpeechModelLanguageGate.corroborationConflict`.
    private func corroborationConflict(
        secondReading: String?,
        transcript: String,
        modelPath: String?
    ) -> SpeechCorroborationConflict? {
        SpeechModelLanguageGate.corroborationConflict(
            transcript: transcript,
            secondReading: secondReading,
            modelPath: modelPath
        )
    }

    /// The result of one transcription: the text, plus the language the engine
    /// measured. The language decides whether the transform gate tones or
    /// cleans up the transcript or pastes it as-is, and which model does the
    /// work, so it travels with the text instead of living in ambient state
    /// that concurrent operations could overwrite. What the engine measured
    /// about speech in the audio travels the same way: it is the second thing a
    /// transcript can be refused for, and the one the text cannot show.
    struct TranscriptionOutput {
        let text: String
        /// Engine-reported language, or `nil` when the engine has no signal
        /// (Parakeet/FluidAudio, or a whisper model that is not multilingual).
        let language: String?
        /// Whether the audio this text came from held speech, as the engine
        /// measured it. `nil` when the engine measures nothing — which refuses
        /// nothing.
        var speechPresence: SpeechPresence? = nil
        /// The same audio read a second time by the same engine, or `nil` when
        /// there is no second reading. The third thing a transcript can be
        /// refused for, and the only one that is a comparison — see
        /// `SpeechCorroborationConflict`.
        var secondReading: String? = nil
    }

    private final class TranscriptionTaskBox {
        let id: UUID
        let engine: TranscriptionEngine
        let task: Task<TranscriptionOutput, Error>

        init(id: UUID, engine: TranscriptionEngine, task: Task<TranscriptionOutput, Error>) {
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
    private var shutdownEngines: [TranscriptionEngine] = []
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
            activeTask?.engine.unload()
            preparation?.engine.unload()
            engine?.unload()
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
                        modelPath: modelPath(forEngine: prefs.selectedEngine),
                        modelVersion: prefs.fluidAudioModelVersion)
        }

        /// The weights the selected engine will load, as the service's own idea
        /// of "the same selection".
        ///
        /// It is what makes a download or a removal visible to `loadEngine`: the
        /// Qwen3-ASR engine's two files are not a preference, so their presence
        /// is what stands in for one — nil while either half is missing, which
        /// reloads the engine with the weights that are now there, and empties
        /// the selection when they are deleted, so a loaded model cannot keep
        /// transcribing after its files are gone.
        private static func modelPath(forEngine engine: String) -> String? {
            if engine == Qwen3ASREngine.engineID {
                return Qwen3ASRModelManager.shared.installedPaths?.model
            }
            return resolvedWhisperModelPath()
        }
    }

    /// The speech model the app will load.
    ///
    /// The user's selection wins while its file is there. With nothing usable
    /// selected — a fresh install, a preference that was dropped, a file that
    /// went missing — the app falls back to the model inside its own bundle,
    /// which it copied into its own directory on first run. Those are the only
    /// two places: everything else is a download from the catalogue, and a
    /// download the user has not made is not a model.
    ///
    /// `nil` only when the bundle does not carry its model either, which is a
    /// broken build rather than a state a user can reach. This is what keeps a
    /// fresh install from failing every dictation with
    /// `contextInitializationFailed` and reporting "Model could not be loaded".
    ///
    /// Nothing is repaired here: `WhisperModelManager.ensureDefaultModelPresent()`
    /// does that at launch and reports it in the Model tab. This answers only
    /// what is usable now, so the engine-load path never writes a preference —
    /// and it is `nonisolated` for that reason, because answering it reads two
    /// files and no state of this service (`EngineSelection.current` is the
    /// nonisolated static that asks it).
    nonisolated static func resolvedWhisperModelPath() -> String? {
        let prefs = AppPreferences.shared
        let resolved: String?
        if let stored = prefs.selectedWhisperModelPath ?? prefs.selectedModelPath,
           !stored.isEmpty,
           FileManager.default.fileExists(atPath: stored) {
            resolved = stored
        } else {
            resolved = WhisperModelManager.bundledModelPath
        }
        // An English-only model cannot detect language, so asked to transcribe
        // Polish it answers with fluent English that was never spoken — and a
        // gate that reads the transcript cannot tell that English is an
        // invention. With a multilingual model already on this machine, the
        // dictation runs on that one instead; with only English-only models it
        // is the resolved model that runs, and the conflict gate still refuses
        // the transcript and offers the remedy.
        return SpeechModelLanguageGate.preferredDictationModelPath(over: resolved)
    }

    @Published private(set) var loadingError: String?
    /// The same failure as an `Error`, so a dictation can report the engine's
    /// own reason rather than the generic "the model could not be loaded".
    private var loadingFailure: Error?
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
        let engine = self.engine(for: selection)
        try await engine.initialize()
        return engine
    }

    /// The engine a selection names, before it is initialized.
    ///
    /// Split out from the load so the mapping from the preference value to an
    /// engine can be read — and tested — without loading gigabytes of weights.
    /// An unknown engine value runs whisper, which is the preference's own
    /// default; a Qwen3-ASR selection whose two files are missing fails in
    /// `initialize()` with the download to make, and never lands here on
    /// whisper's model.
    static func engine(for selection: EngineSelection) -> TranscriptionEngine {
        switch selection.engine {
        case "fluidaudio":
            return FluidAudioEngine(modelVersion: selection.modelVersion)
        case Qwen3ASREngine.engineID:
            // The weights are this engine's own two files, and it resolves them
            // from the model manager: an engine preference carries no path for
            // them, and a missing download is a load failure — never a silent
            // switch to the whisper model below.
            return Qwen3ASREngine()
        default:
            return WhisperEngine(modelPath: selection.modelPath)
        }
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
        engineSelection = selection
        let id = UUID()
        engineLoadID = id
        currentEngine = nil
        recordingPreparation = nil
        loadingError = nil
        loadingFailure = nil
        isLoading = true
        let loader = engineLoader
        let task = Task.detached(priority: .userInitiated) {
            let engine = try await loader(selection)
            try Task.checkCancellation()
            return engine
        }
        engineLoadTask = task
        backgroundOperations[id] = Task { [weak self] in
            let result = await task.result
            self?.finishEngineLoad(id: id, result: result)
            self?.backgroundOperations[id] = nil
        }
    }

    private func finishEngineLoad(id: UUID, result: Result<TranscriptionEngine, Error>) {
        guard !isShuttingDown else {
            if case .success(let engine) = result {
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
            loadingFailure = nil
        case .failure(let error):
            loadingError = error.localizedDescription
            // Kept as the error itself, not only as the localized sentence the
            // alert shows: a dictation that arrives before the engine loads must
            // fail with the engine's own reason (a Qwen3-ASR download that is
            // missing names the file to fetch) instead of a generic refusal.
            loadingFailure = error
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
        guard currentEngine != nil else {
            throw loadingFailure ?? TranscriptionError.contextInitializationFailed
        }
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
    
    /// Convenience overload for callers that only need the text; the language is
    /// still computed and simply dropped here.
    func transcribeAudio(url: URL, settings: Settings, pcmSamples: [Float]? = nil) async throws -> String {
        try await transcribeAudio(
            url: url,
            settings: settings,
            operationID: UUID(),
            pcmSamples: pcmSamples
        ).text
    }

    func transcribeAudio(
        url: URL,
        settings: Settings,
        operationID: UUID,
        pcmSamples: [Float]? = nil
    ) async throws -> TranscriptionOutput {
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

        // The model this operation runs, read once as the operation starts: a
        // remedy that switches models while the decode is in flight must not
        // rename the model a refusal blames. The transcript came from this one.
        let modelPath = selectedSpeechModelPath

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
        } else if let qwenEngine = engine as? Qwen3ASREngine {
            qwenEngine.onProgressUpdate = { [weak self] newProgress in
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
            
            let output: TranscriptionOutput
            do {
                if let whisper = engine as? WhisperEngine {
                    // Whisper reports the language of the utterance it just
                    // decoded; the other engines cannot, so they fall back to the
                    // transcript text at the gate.
                    let detailed: WhisperEngine.DetailedTranscription
                    if let pcmSamples {
                        detailed = try await whisper.transcribeSamplesDetailed(pcmSamples, settings: settings)
                    } else {
                        detailed = try await whisper.transcribeAudioDetailed(url: url, settings: settings)
                    }
                    output = TranscriptionOutput(
                        text: detailed.text,
                        language: detailed.language,
                        speechPresence: detailed.speechPresence,
                        secondReading: detailed.secondReading
                    )
                } else {
                    output = TranscriptionOutput(
                        text: try await engine.transcribeAudio(url: url, settings: settings),
                        language: nil
                    )
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

            // Nothing can be transcribed from audio that held no speech, and
            // whisper will write a fluent phrase over silence anyway — a model
            // that hears every language invents just as readily as an
            // English-only one, and no language gate can see it, because the
            // text is fluent. The measurement travels with the text (see
            // `SpeechPresence`); the refusal is non-destructive exactly like the
            // language conflict below — nothing is published, nothing is pasted,
            // and the audio is kept.
            if let refusal = await MainActor.run(body: {
                self?.noSpeechRefusal(
                    presence: output.speechPresence,
                    threshold: settings.noSpeechThreshold,
                    modelPath: modelPath
                )
            }) {
                throw TranscriptionError.noSpeechDetected(refusal)
            }

            // The one combination that cannot work is refused before anything is
            // published: an English-only model writing English over speech it
            // never understood must not reach the paste path, and must not be
            // saved as the record of what the user said. The transcript is the
            // evidence — see `SpeechModelLanguageGate`.
            if let conflict = await MainActor.run(body: {
                self?.speechLanguageConflict(engine: engine, transcript: output.text, modelPath: modelPath)
            }) {
                throw TranscriptionError.speechLanguageConflict(conflict)
            }

            // And the one a comparison can see that neither of the two above
            // can: text the same audio, read a second time, does not contain.
            // The reading travels with the text the same way the measurement
            // does (see `SpeechCorroborationConflict`); the refusal is
            // non-destructive exactly like the other two — nothing is published,
            // nothing is pasted, and the audio is kept. With no second reading
            // there is nothing to refuse on, and the dictation goes on as it did
            // before this layer existed.
            if let conflict = await MainActor.run(body: {
                self?.corroborationConflict(
                    secondReading: output.secondReading,
                    transcript: output.text,
                    modelPath: modelPath
                )
            }) {
                throw TranscriptionError.uncorroboratedTranscript(conflict)
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
                self.transcribedText = output.text
                self.progress = 1.0
                return true
            }

            guard didPublish else { throw CancellationError() }
            try Task.checkCancellation()
            
            return output
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
    /// A speech model that cannot hear the selected language, carrying the whole
    /// story so every surface — the indicator, the queue, the history row —
    /// tells the same one.
    case speechLanguageConflict(SpeechLanguageConflict)
    /// A transcript produced from audio that held no speech. The same
    /// non-destructive refusal as the conflict above, and a different thing for
    /// the user to act on: the recording, not the model — see
    /// `SpeechPresenceConflict` for why the text cannot tell them this.
    case noSpeechDetected(SpeechPresenceConflict)
    /// A transcript the same audio, read a second time, does not contain. The
    /// same non-destructive refusal again, and the third thing for the user to
    /// act on: the recording was read twice and the readings disagree — see
    /// `SpeechCorroborationConflict`.
    case uncorroboratedTranscript(SpeechCorroborationConflict)
}

extension TranscriptionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .speechLanguageConflict(let conflict): return conflict.message
        case .noSpeechDetected(let refusal): return refusal.message
        case .uncorroboratedTranscript(let conflict): return conflict.message
        default: return nil
        }
    }
}
