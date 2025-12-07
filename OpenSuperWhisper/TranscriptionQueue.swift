import Foundation
import AVFoundation

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
    private var abortFlag: UnsafeMutablePointer<Bool>?
    
    private init() {
        self.transcriptionService = TranscriptionService.shared
        self.recordingStore = RecordingStore.shared
    }
    
    deinit {
        abortFlag?.deallocate()
    }
    
    func cancelRecording(_ recordingId: UUID) {
        cancelledRecordingIds.insert(recordingId)
        
        if currentRecordingId == recordingId {
            abortFlag?.pointee = true
            currentTranscriptionTask?.cancel()
        }
    }
    
    private func resetAbortFlag() {
        if abortFlag != nil {
            abortFlag?.deallocate()
        }
        abortFlag = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
        abortFlag?.initialize(to: false)
    }
    
    private func isRecordingCancelled(_ recordingId: UUID) -> Bool {
        return cancelledRecordingIds.contains(recordingId)
    }
    
    private func clearCancellation(_ recordingId: UUID) {
        cancelledRecordingIds.remove(recordingId)
    }
    
    func startProcessingQueue() {
        guard !isProcessing else { return }
        
        processingTask = Task {
            await cleanupMissingFiles()
            await processQueue()
        }
    }
    
    private func cleanupMissingFiles() async {
        let pendingRecordings = recordingStore.getPendingRecordings()
        
        for recording in pendingRecordings {
            guard let sourceURLString = recording.sourceFileURL,
                  !sourceURLString.isEmpty else {
                recordingStore.deleteRecording(recording)
                continue
            }
            
            let sourceURL = URL(fileURLWithPath: sourceURLString)
            if !FileManager.default.fileExists(atPath: sourceURL.path) {
                recordingStore.deleteRecording(recording)
            }
        }
    }
    
    func addFileToQueue(url: URL) async {
        do {
            let asset = AVAsset(url: url)
            let duration = try await asset.load(.duration)
            let durationInSeconds = CMTimeGetSeconds(duration)
            
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
    
    private func processQueue() async {
        isProcessing = true
        
        while true {
            let pendingRecordings = recordingStore.getPendingRecordings()
            
            guard let recording = pendingRecordings.first else {
                break
            }
            
            currentRecordingId = recording.id
            await processRecording(recording)
            currentRecordingId = nil
        }
        
        isProcessing = false
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
        
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            await recordingStore.updateRecordingProgressOnlySync(
                recording.id,
                transcription: "Source file not found",
                progress: 0.0,
                status: .failed
            )
            return
        }
        
        await recordingStore.updateRecordingProgressOnlySync(
            recording.id,
            transcription: "",
            progress: 0.0,
            status: .converting
        )
        
        currentTranscriptionTask = Task {
            do {
                if isRecordingCancelled(recording.id) {
                    return
                }
                
                let samples = try await transcriptionService.convertAudioToPCM(fileURL: sourceURL) { [weak self] progress in
                    Task { @MainActor in
                        guard let self = self, !self.isRecordingCancelled(recording.id) else { return }
                        self.recordingStore.updateRecordingProgressOnly(
                            recording.id,
                            transcription: "",
                            progress: progress * 0.1,
                            status: .converting
                        )
                    }
                }
                
                if isRecordingCancelled(recording.id) || Task.isCancelled {
                    return
                }
                
                guard let samples = samples else {
                    throw TranscriptionError.audioConversionFailed
                }
                
                await recordingStore.updateRecordingProgressOnlySync(
                    recording.id,
                    transcription: "Starting transcription...",
                    progress: 0.1,
                    status: .transcribing
                )
                
                if isRecordingCancelled(recording.id) || Task.isCancelled {
                    return
                }
                
                let text = try await transcribeWithProgress(
                    samples: samples,
                    recordingId: recording.id,
                    sourceURL: sourceURL
                )
                
                if isRecordingCancelled(recording.id) || Task.isCancelled {
                    return
                }
                
                let finalURL = recording.url
                try? FileManager.default.createDirectory(
                    at: Recording.recordingsDirectory,
                    withIntermediateDirectories: true
                )
                
                if FileManager.default.fileExists(atPath: finalURL.path) {
                    try? FileManager.default.removeItem(at: finalURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: finalURL)
                
                await recordingStore.updateRecordingProgressOnlySync(
                    recording.id,
                    transcription: text,
                    progress: 1.0,
                    status: .completed
                )
                
            } catch {
                if !isRecordingCancelled(recording.id) && !Task.isCancelled {
                    await recordingStore.updateRecordingProgressOnlySync(
                        recording.id,
                        transcription: "Failed to transcribe: \(error.localizedDescription)",
                        progress: 0.0,
                        status: .failed
                    )
                }
            }
        }
        
        await currentTranscriptionTask?.value
        currentTranscriptionTask = nil
        clearCancellation(recording.id)
    }
    
    private func transcribeWithProgress(samples: [Float], recordingId: UUID, sourceURL: URL) async throws -> String {
        let asset = AVAsset(url: sourceURL)
        let duration = try await asset.load(.duration)
        let totalDuration = Float(CMTimeGetSeconds(duration))
        
        resetAbortFlag()
        let abortFlagForTask = abortFlag
        
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached(priority: .userInitiated) { [self] in
                guard let context = await self.transcriptionService.createContext() else {
                    continuation.resume(throwing: TranscriptionError.contextInitializationFailed)
                    return
                }
                
                let nThreads = 4
                
                guard context.pcmToMel(samples: samples, nSamples: samples.count, nThreads: nThreads) else {
                    continuation.resume(throwing: TranscriptionError.processingFailed)
                    return
                }
                
                guard context.encode(offset: 0, nThreads: nThreads) else {
                    continuation.resume(throwing: TranscriptionError.processingFailed)
                    return
                }
                
                var params = WhisperFullParams()
                let settings = Settings()
                
                params.strategy = settings.useBeamSearch ? .beamSearch : .greedy
                params.nThreads = Int32(nThreads)
                params.noTimestamps = !settings.showTimestamps
                params.suppressBlank = settings.suppressBlankAudio
                params.translate = settings.translateToEnglish
                params.language = settings.selectedLanguage != "auto" ? settings.selectedLanguage : nil
                params.detectLanguage = false
                params.temperature = Float(settings.temperature)
                params.noSpeechThold = Float(settings.noSpeechThreshold)
                params.initialPrompt = settings.initialPrompt.isEmpty ? nil : settings.initialPrompt
                
                if settings.useBeamSearch {
                    params.beamSearchBeamSize = Int32(settings.beamSize)
                }
                
                params.printRealtime = false
                params.print_realtime = false
                
                let abortCallback: @convention(c) (UnsafeMutableRawPointer?) -> Bool = { userData in
                    guard let userData = userData else { return false }
                    let flag = userData.assumingMemoryBound(to: Bool.self)
                    return flag.pointee
                }
                params.abortCallback = abortCallback
                if let abortFlag = abortFlagForTask {
                    params.abortCallbackUserData = UnsafeMutableRawPointer(abortFlag)
                }
                
                let segmentCallback: @convention(c) (OpaquePointer?, OpaquePointer?, Int32, UnsafeMutableRawPointer?) -> Void = { ctx, state, n_new, user_data in
                    guard let ctx = ctx,
                          let userData = user_data else { return }
                    
                    let info = userData.assumingMemoryBound(to: SegmentCallbackInfo.self).pointee
                    
                    let nSegments = Int(whisper_full_n_segments(ctx))
                    let startIdx = max(0, nSegments - Int(n_new))
                    
                    var newText = ""
                    var latestTimestamp: Float = 0
                    
                    for i in startIdx..<nSegments {
                        guard let cString = whisper_full_get_segment_text(ctx, Int32(i)) else { continue }
                        let segmentText = String(cString: cString)
                        newText += segmentText + " "
                        
                        let t1 = Float(whisper_full_get_segment_t1(ctx, Int32(i))) / 100.0
                        latestTimestamp = max(latestTimestamp, t1)
                    }
                    
                    let cleanedText = newText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !cleanedText.isEmpty {
                        let recordingId = info.recordingId
                        let totalDuration = info.totalDuration
                        let progress = totalDuration > 0 ? min(latestTimestamp / totalDuration, 1.0) : 0.0
                        let normalizedProgress = 0.1 + (progress * 0.9)
                        
                        Task { @MainActor in
                            let store = RecordingStore.shared
                            if let current = store.recordings.first(where: { $0.id == recordingId }) {
                                let updatedText = current.transcription == "Starting transcription..." ? cleanedText : current.transcription + " " + cleanedText
                                store.updateRecordingProgressOnly(
                                    recordingId,
                                    transcription: updatedText,
                                    progress: normalizedProgress,
                                    status: .transcribing
                                )
                            }
                        }
                    }
                }
                
                let callbackInfo = UnsafeMutablePointer<SegmentCallbackInfo>.allocate(capacity: 1)
                callbackInfo.initialize(to: SegmentCallbackInfo(recordingId: recordingId, totalDuration: totalDuration))
                defer { callbackInfo.deallocate() }
                
                params.newSegmentCallback = segmentCallback
                params.newSegmentCallbackUserData = UnsafeMutableRawPointer(callbackInfo)
                
                var cParams = params.toC()
                
                guard context.full(samples: samples, params: &cParams) else {
                    continuation.resume(throwing: TranscriptionError.processingFailed)
                    return
                }
                
                var text = ""
                let nSegments = context.fullNSegments
                
                for i in 0..<nSegments {
                    guard let segmentText = context.fullGetSegmentText(iSegment: i) else { continue }
                    
                    if settings.showTimestamps {
                        let t0 = context.fullGetSegmentT0(iSegment: i)
                        let t1 = context.fullGetSegmentT1(iSegment: i)
                        text += String(format: "[%.1f->%.1f] ", Float(t0) / 100.0, Float(t1) / 100.0)
                    }
                    text += segmentText + "\n"
                }
                
                let cleanedText = text
                    .replacingOccurrences(of: "[MUSIC]", with: "")
                    .replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                
                let finalText = cleanedText.isEmpty ? "No speech detected in the audio" : cleanedText
                
                continuation.resume(returning: finalText)
            }
        }
    }
}

struct SegmentCallbackInfo {
    let recordingId: UUID
    let totalDuration: Float
}
