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
    private var currentTranscriptionTask: Task<Void, Never>?
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
            await cleanupMissingFiles()
            await processQueue()
            isProcessing = false
            processingTask = nil
        }
    }

    private func cleanupMissingFiles() async {
        let pendingRecordings = recordingStore.getPendingRecordings()

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
            recordingStore.deleteRecording(recording)
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
            print("Failed to add file to queue: \(error)")
        }
    }

    func requeueRecording(_ recording: Recording) async {
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
            await recordingStore.updateRecordingProgressOnlySync(
                recording.id,
                transcription: "Cannot regenerate: audio file not found",
                progress: 0.0,
                status: .failed
            )
            return
        }

        await recordingStore.updateRecordingStatusOnly(
            recording.id,
            progress: 0.0,
            status: .pending,
            isRegeneration: true
        )

        do {
            try await recordingStore.updateSourceFileURL(recording.id, sourceURL: sourceURL.path)
        } catch {
            print("Failed to update source URL: \(error)")
        }

        startProcessingQueue()
    }

    nonisolated static func shouldDiscardEmptyDictation(text: String, sourceURL: URL) -> Bool {
        text.isEmpty && sourceURL.path.hasPrefix(AudioRecorder.temporaryRecordingsDirectory.path)
    }

    private func processQueue() async {
        while let recording = recordingStore.getNextPendingRecording() {
            currentRecordingId = recording.id
            currentOperationID = UUID()
            await processRecording(recording)
            currentRecordingId = nil
            currentOperationID = nil
        }
    }

    private func processRecording(_ recording: Recording) async {
        if isRecordingCancelled(recording.id) {
            clearCancellation(recording.id)
            return
        }

        guard let sourceURLString = recording.sourceFileURL,
              !sourceURLString.isEmpty else {
            await recordingStore.updateRecordingProgressOnlySync(
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
            await recordingStore.updateRecordingProgressOnlySync(
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
            await recordingStore.updateRecordingStatusOnly(
                recording.id,
                progress: 0.0,
                status: .converting
            )
        } else {
            await recordingStore.updateRecordingProgressOnlySync(
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
                let text = try await transcriptionService.transcribeAudio(url: sourceURL, settings: settings, operationID: operationID)

                if isRecordingCancelled(recording.id) || Task.isCancelled {
                    return
                }

                if Self.shouldDiscardEmptyDictation(text: text, sourceURL: sourceURL) {
                    await Task.detached(priority: .utility) {
                        try? FileManager.default.removeItem(at: sourceURL)
                    }.value
                    await recordingStore.deleteRecordingSync(recording)
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

                await recordingStore.updateRecordingProgressOnlySync(
                    recording.id,
                    transcription: text,
                    progress: 1.0,
                    status: .completed,
                    isRegeneration: false
                )

            } catch {
                if !isRecordingCancelled(recording.id) && !Task.isCancelled {
                    await recordingStore.updateRecordingProgressOnlySync(
                        recording.id,
                        transcription: "Failed to transcribe: \(error.localizedDescription)",
                        progress: 0.0,
                        status: .failed,
                        isRegeneration: false
                    )
                }
            }
        }

        await currentTranscriptionTask?.value
        currentTranscriptionTask = nil
        clearCancellation(recording.id)
    }

}
