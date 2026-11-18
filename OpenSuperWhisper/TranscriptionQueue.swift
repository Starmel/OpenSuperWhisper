import Foundation
import Combine

@MainActor
class TranscriptionQueue: ObservableObject {
    static let shared = TranscriptionQueue()

    @Published private(set) var isProcessing = false
    @Published private(set) var currentRecordingId: UUID?

    private let transcriptionService: TranscriptionService
    private let recordingStore: RecordingStore
    private var processingTask: Task<Void, Never>?
    private var currentOperationID: UUID?
    private var currentTranscriptionTask: Task<Void, Error>?
    private var cancelledRecordingIds: Set<UUID> = []
    private var progressCancellable: AnyCancellable?

    init(transcriptionService: TranscriptionService = .shared, recordingStore: RecordingStore = .shared) {
        self.transcriptionService = transcriptionService
        self.recordingStore = recordingStore
        setupProgressObserver()
    }
    
    private func setupProgressObserver() {
        progressCancellable = transcriptionService.$progress
            .sink { [weak self] newProgress in
                guard let self = self,
                      let recordingId = self.currentRecordingId,
                      let operationID = self.currentOperationID,
                      self.transcriptionService.activeOperationID == operationID,
                      newProgress > 0,
                      newProgress < 1.0 else { return }
                
                self.recordingStore.updateRecordingProgressTransient(
                    recordingId,
                    progress: newProgress,
                    status: .transcribing
                )
            }
    }

    func cancelRecording(_ recordingId: UUID) {
        cancelledRecordingIds.insert(recordingId)

        if currentRecordingId == recordingId, let operationID = currentOperationID {
            transcriptionService.cancelTranscription(operationID: operationID)
            currentTranscriptionTask?.cancel()
        }
    }

    func cancelRecordingAndWait(_ id: UUID) async {
        cancelRecording(id)
        if currentRecordingId == id { _ = await currentTranscriptionTask?.result }
    }

    func stopProcessingQueue() async {
        processingTask?.cancel()
        if let id = currentRecordingId { cancelRecording(id) }
        await processingTask?.value
    }

    private func isRecordingCancelled(_ recordingId: UUID) -> Bool {
        return cancelledRecordingIds.contains(recordingId)
    }

    private func clearCancellation(_ recordingId: UUID) {
        cancelledRecordingIds.remove(recordingId)
    }

    func startProcessingQueue() {
        guard !isProcessing else { return }

        isProcessing = true

        processingTask = Task {
            do {
                try await cleanupMissingFiles()
                try await processQueue()
            } catch is CancellationError {
            } catch {
                AppErrorCenter.shared.report("Transcription queue stopped", error: error)
            }
            isProcessing = false
            processingTask = nil
        }
    }

    private func cleanupMissingFiles() async throws {
        let pendingRecordings = try recordingStore.getPendingRecordings()

        let recordingsToDelete = await Task.detached(priority: .utility) {
            var toDelete: [Recording] = []
            for recording in pendingRecordings {
                guard let sourceURLString = recording.sourceFileURL,
                      !sourceURLString.isEmpty else {
                    toDelete.append(recording)
                    continue
                }

                let sourceURL = URL(fileURLWithPath: sourceURLString)
                if !FileManager.default.fileExists(atPath: sourceURL.path) {
                    toDelete.append(recording)
                }
            }
            return toDelete
        }.value
        
        for recording in recordingsToDelete {
            try await recordingStore.deleteRecordingSync(recording, cancelTranscription: false)
        }
    }

    func addFileToQueue(url: URL) async {
        do {
            let durationInSeconds = await AudioUtil.audioDuration(url: url)

            let timestamp = Date()
            let id = UUID()
            let fileName = Recording.fileName(for: id)

            let recording = Recording(
                id: id,
                timestamp: timestamp,
                fileName: fileName,
                transcription: "",
                duration: durationInSeconds,
                status: .pending,
                progress: 0.0,
                sourceFileURL: url.path
            )

            try await recordingStore.addRecordingSync(recording)

            startProcessingQueue()
        } catch {
            AppErrorCenter.shared.report("File could not be queued", error: error)
        }
    }

    func requeueRecording(_ recording: Recording) async {
        do { try await requeue(recording) }
        catch { AppErrorCenter.shared.report("Recording could not be queued", error: error) }
    }

    private func requeue(_ recording: Recording) async throws {
        let sourceURL: URL? = await Task.detached(priority: .userInitiated) {
            if let existingSource = recording.sourceFileURL,
               !existingSource.isEmpty,
               FileManager.default.fileExists(atPath: existingSource) {
                return URL(fileURLWithPath: existingSource)
            } else if FileManager.default.fileExists(atPath: recording.url.path) {
                return recording.url
            }
            return nil
        }.value
        
        guard let sourceURL = sourceURL else {
            try await recordingStore.updateRecordingProgressOnlySync(
                recording.id,
                transcription: "Cannot regenerate: audio file not found",
                progress: 0.0,
                status: .failed
            )
            return
        }

        try await recordingStore.updateRecordingStatusOnly(
            recording.id,
            progress: 0.0,
            status: .pending,
            isRegeneration: true
        )

        try await recordingStore.updateSourceFileURL(recording.id, sourceURL: sourceURL.path)

        startProcessingQueue()
    }

    nonisolated static func shouldDiscardEmptyDictation(text: String, sourceURL: URL) -> Bool {
        text.isEmpty && isOurOwnRecording(sourceURL)
    }

    /// Whether the source is a recording of ours — the recorder's own temp
    /// directory — rather than a file the user queued from disk, which is
    /// theirs and is never moved, copied or deleted by a refusal.
    nonisolated static func isOurOwnRecording(_ sourceURL: URL) -> Bool {
        sourceURL.path.hasPrefix(AudioRecorder.temporaryRecordingsDirectory.path)
    }

    /// Whether the source *is* the audio the row keeps — a regeneration reads the
    /// recording's own file — rather than a copy of it.
    ///
    /// Such a file is never deleted by any path here: removing it would remove
    /// the recording its own row stands for. That is also why this case does not
    /// go through `DictationFailurePolicy.settle`, whose discard would delete it.
    nonisolated static func isTheRecordingsOwnAudio(_ sourceURL: URL, of recording: Recording) -> Bool {
        sourceURL.standardizedFileURL == recording.url.standardizedFileURL
    }

    private func processQueue() async throws {
        while let recording = try recordingStore.getNextPendingRecording() {
            try Task.checkCancellation()
            currentRecordingId = recording.id
            currentOperationID = UUID()
            defer { currentRecordingId = nil; currentOperationID = nil }
            try await processRecording(recording)
        }
    }

    private func processRecording(_ recording: Recording) async throws {
        if isRecordingCancelled(recording.id) {
            clearCancellation(recording.id)
            return
        }

        guard let sourceURLString = recording.sourceFileURL,
              !sourceURLString.isEmpty else {
            try await recordingStore.updateRecordingProgressOnlySync(
                recording.id,
                transcription: "Source file not found",
                progress: 0.0,
                status: .failed
            )
            return
        }

        let sourceURL = URL(fileURLWithPath: sourceURLString)

        let sourceExists = await Task.detached(priority: .userInitiated) {
            FileManager.default.fileExists(atPath: sourceURL.path)
        }.value
        
        guard sourceExists else {
            try await recordingStore.updateRecordingProgressOnlySync(
                recording.id,
                transcription: "Source file not found",
                progress: 0.0,
                status: .failed
            )
            return
        }

        let isRegeneration = !recording.transcription.isEmpty && 
            recording.transcription != "In queue..." && 
            recording.transcription != "Starting transcription..."

        if isRegeneration {
            try await recordingStore.updateRecordingStatusOnly(
                recording.id,
                progress: 0.0,
                status: .converting
            )
        } else {
            try await recordingStore.updateRecordingProgressOnlySync(
                recording.id,
                transcription: "",
                progress: 0.0,
                status: .converting
            )
        }

        guard let operationID = currentOperationID else { return }
        currentTranscriptionTask = Task {
            do {
                if isRecordingCancelled(recording.id) {
                    return
                }

                if isRecordingCancelled(recording.id) || Task.isCancelled {
                    return
                }

                let settings = Settings()
                // An outcome with no text — an engine that returned nothing, or a
                // refusal that is silence rather than a failure — is invisible
                // wherever the user looks: no alert, no history row, no copy
                // left behind, nothing inserted.
                var silentRefusal: Error?
                var text = ""
                do {
                    text = try await transcriptionService.transcribeAudio(
                        url: sourceURL,
                        settings: settings,
                        operationID: operationID
                    ).text
                } catch {
                    // Everything that is not silence keeps today's failed row.
                    guard DictationFailurePolicy.outcome(for: error) != .report else { throw error }
                    silentRefusal = error
                }

                if isRecordingCancelled(recording.id) || Task.isCancelled {
                    return
                }

                if text.isEmpty {
                    // An outcome with no text leaves nothing new behind: no
                    // alert, no copy, nothing inserted. What happens to the audio
                    // depends on whose it is.
                    if Self.shouldDiscardEmptyDictation(text: text, sourceURL: sourceURL) {
                        // Our own temp recording. The shared decision settles it:
                        // deleted for silence, kept — moved into the recordings
                        // directory with a row that records it — for a refusal
                        // over audio that was really recorded. Either way the
                        // pending row goes with it.
                        if let silentRefusal {
                            let outcome = DictationFailurePolicy.outcome(for: silentRefusal)
                            await DictationFailurePolicy.settle(
                                RecordedAudio(url: sourceURL, samples: []),
                                error: silentRefusal,
                                store: recordingStore
                            )
                            switch outcome {
                            case .discard:
                                print("Dictation refused for no speech; the temp audio was discarded")
                            case .keepAudio, .keepAudioAndExplain:
                                print("Dictation yielded no transcript; the recording was kept")
                            case .report:
                                // Unreachable: a failure that is not silence was
                                // rethrown above.
                                break
                            }
                        } else {
                            await Task.detached(priority: .utility) {
                                try? FileManager.default.removeItem(at: sourceURL)
                            }.value
                        }
                        try await recordingStore.deleteRecordingSync(recording, cancelTranscription: false)
                        return
                    }
                    // Anything else belongs to the user: a file he queued, or the
                    // recording's own audio that a regeneration reads. Neither is
                    // copied, moved or deleted, and — because he asked for this
                    // recording — the row stays and says so, named by the file it
                    // stands for (`sourceFileURL`, which History shows), with no
                    // transcript of its own: silence would leave him unable to
                    // tell whether it worked.
                    try await recordingStore.updateRecordingProgressOnlySync(
                        recording.id,
                        transcription: "",
                        progress: 0.0,
                        status: .failed,
                        isRegeneration: false
                    )
                    if Self.isTheRecordingsOwnAudio(sourceURL, of: recording) {
                        print("Regenerated recording yielded no transcript; the recording and its audio were left as they are: \(sourceURL.path)")
                    } else {
                        print("Queued file produced no transcript; it was left exactly where it is: \(sourceURL.path)")
                    }
                    return
                }

                let finalURL = recording.url
                try await Task.detached(priority: .userInitiated) {
                    try? FileManager.default.createDirectory(
                        at: Recording.recordingsDirectory,
                        withIntermediateDirectories: true
                    )

                    if sourceURL.path != finalURL.path {
                        // Our own temp recordings are moved (no disk duplication);
                        // user-provided files must stay in place, so they are copied.
                        if sourceURL.path.hasPrefix(AudioRecorder.temporaryRecordingsDirectory.path) {
                            try FileManager.default.moveItem(at: sourceURL, to: finalURL)
                        } else {
                            try FileManager.default.copyItem(at: sourceURL, to: finalURL)
                        }
                    }
                }.value

                try await recordingStore.updateRecordingProgressOnlySync(
                    recording.id,
                    transcription: text,
                    progress: 1.0,
                    status: .completed,
                    isRegeneration: false
                )

            } catch {
                if !isRecordingCancelled(recording.id) && !Task.isCancelled {
                    // The transcript column means "what the user dictated", so a
                    // failure's own description never goes in it: the row stores
                    // nothing and the reason goes to the log and the row's failed
                    // status, exactly as a failed dictation does.
                    print("Transcription failed: \(error.localizedDescription)")
                    if Self.isOurOwnRecording(sourceURL) {
                        // Our own temp recording is moved where a row's audio
                        // lives before the row says it failed, so the failed row
                        // never points at a file the temp cleanup will take.
                        let destination = recording.url
                        do {
                            try FileManager.default.createDirectory(
                                at: Recording.recordingsDirectory,
                                withIntermediateDirectories: true
                            )
                            try FileManager.default.moveItem(at: sourceURL, to: destination)
                            try await recordingStore.updateSourceFileURL(
                                recording.id,
                                sourceURL: destination.path
                            )
                        } catch {
                            // The row is not written without its audio: the
                            // recording is still here, and the user is told.
                            AppErrorCenter.shared.report(
                                "The recording could not be saved",
                                message: "The failed dictation is still here: \(sourceURL.path)\n\(error.localizedDescription)"
                            )
                            return
                        }
                    }
                    try await recordingStore.updateRecordingProgressOnlySync(
                        recording.id,
                        transcription: "",
                        progress: 0.0,
                        status: .failed,
                        isRegeneration: false
                    )
                }
            }
        }

        defer { currentTranscriptionTask = nil; clearCancellation(recording.id) }
        try await currentTranscriptionTask?.value
    }

}
