import Foundation
import AVFoundation
import Combine

@MainActor
class TranscriptionQueue: ObservableObject {
    static let shared = TranscriptionQueue()

    @Published private(set) var isProcessing = false
    @Published private(set) var currentRecordingId: UUID?

    private let transcriptionService: TranscriptionService
    private let recordingStore: RecordingStore
    private var processingTask: Task<Void, Never>?
    private var currentTranscriptionTask: Task<Void, Never>?
    private var cancelledRecordingIds: Set<UUID> = []
    private var progressCancellable: AnyCancellable?

    private init() {
        self.transcriptionService = TranscriptionService.shared
        self.recordingStore = RecordingStore.shared
        setupProgressObserver()
    }
    
    private func setupProgressObserver() {
        progressCancellable = transcriptionService.$progress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newProgress in
                guard let self = self,
                      let recordingId = self.currentRecordingId,
                      newProgress > 0,
                      newProgress < 1.0 else { return }
                
                Task {
                    await self.recordingStore.updateRecordingStatusOnly(
                        recordingId,
                        progress: newProgress,
                        status: .transcribing
                    )
                }
            }
    }

    func cancelRecording(_ recordingId: UUID) {
        cancelledRecordingIds.insert(recordingId)

        if currentRecordingId == recordingId {
            transcriptionService.cancelTranscription()
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
            let durationInSeconds = await (try? Task.detached(priority: .userInitiated) {
                let asset = AVAsset(url: url)
                let duration = try await asset.load(.duration)
                return CMTimeGetSeconds(duration)
            }.value) ?? 0.0

            let timestamp = Date()
            let fileName = "\(Int(timestamp.timeIntervalSince1970)).wav"
            let id = UUID()

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

    private func processQueue() async {
        while let recording = recordingStore.getNextPendingRecording() {
            currentRecordingId = recording.id
            await processRecording(recording)
            currentRecordingId = nil
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

        currentTranscriptionTask = Task {
            do {
                if isRecordingCancelled(recording.id) {
                    return
                }

                if isRecordingCancelled(recording.id) || Task.isCancelled {
                    return
                }

                let settings = Settings()
                let text = try await transcriptionService.transcribeAudio(url: sourceURL, settings: settings)

                if isRecordingCancelled(recording.id) || Task.isCancelled {
                    return
                }

                let finalURL = recording.url
                try await Task.detached(priority: .userInitiated) {
                    try? FileManager.default.createDirectory(
                        at: Recording.recordingsDirectory,
                        withIntermediateDirectories: true
                    )

                    if sourceURL.path != finalURL.path {
                        if FileManager.default.fileExists(atPath: finalURL.path) {
                            try? FileManager.default.removeItem(at: finalURL)
                        }
                        try FileManager.default.copyItem(at: sourceURL, to: finalURL)
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
