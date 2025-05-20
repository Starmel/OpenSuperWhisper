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
    
    private var context: MyWhisperContext?
    private var totalDuration: Float = 0.0 // Used for file transcription progress
    private var transcriptionTask: Task<String, Error>? = nil // For file transcription
    private var isCancelled = false // For file transcription cancellation
    private var abortFlag: UnsafeMutablePointer<Bool>? = nil // For file transcription abort
    
    // MARK: - Live Transcription State
    @Published private(set) var isLiveTranscribing: Bool = false
    private var liveAudioBuffer: [Float] = []
    private var liveTranscriptionProcessingTask: Task<Void, Error>?
    private var liveAbortFlag: UnsafeMutablePointer<Bool>?
    private var liveSettings: Settings?
    
    private let LIVE_AUDIO_SAMPLE_RATE: Double = 16000.0
    private let LIVE_AUDIO_BUFFER_TARGET_DURATION_SECONDS: Double = 5.0 // Process every 5 seconds of audio
    private var LIVE_AUDIO_BUFFER_TARGET_SAMPLES: Int { Int(LIVE_AUDIO_SAMPLE_RATE * LIVE_AUDIO_BUFFER_TARGET_DURATION_SECONDS) }
    // Serial queue for live audio buffer access and processing task management
    private let liveTranscriptionQueue = DispatchQueue(label: "com.opensuperwhisper.liveTranscriptionQueue", qos: .userInitiated)

    init() {
        loadModel()
    }
    
    // For file-based transcription
    func cancelTranscription() {
        Task { @MainActor in // Ensure UI related properties are updated on main thread
            isCancelled = true
            
            if let abortFlag = abortFlag {
                abortFlag.pointee = true
            }
            
            transcriptionTask?.cancel()
            transcriptionTask = nil
            
            isTranscribing = false // This is for file-based isTranscribing
            currentSegment = ""
            progress = 0.0
            isCancelled = false
        }
    }
    
    deinit {
        abortFlag?.deallocate()
        liveAbortFlag?.deallocate()
    }
    
    private func loadModel() {
        print("Loading model")
        if let modelPath = AppPreferences.shared.selectedModelPath {
            isLoading = true
            
            // Capture the weak self reference before the task
            weak var weakSelf = self
            
            Task.detached(priority: .userInitiated) {
                let params = WhisperContextParams()
                let newContext = MyWhisperContext.initFromFile(path: modelPath, params: params)
                
                await MainActor.run {
                    // Use the weak self reference inside MainActor.run
                    guard let self = weakSelf else { return }
                    self.context = newContext
                    self.isLoading = false
                    print("Model loaded")
                }
            }
        }
    }
    
    func reloadModel(with path: String) {
        print("Reloading model")
        isLoading = true
        
        // Capture the weak self reference before the task
        weak var weakSelf = self
        
        Task.detached(priority: .userInitiated) {
            let params = WhisperContextParams()
            let newContext = MyWhisperContext.initFromFile(path: path, params: params)
            
            await MainActor.run {
                // Use the weak self reference inside MainActor.run
                guard let self = weakSelf else { return }
                self.context = newContext
                self.isLoading = false
                print("Model reloaded")
            }
        }
    }
    
    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        await MainActor.run {
            self.progress = 0.0
            self.isTranscribing = true
            self.transcribedText = ""
            self.currentSegment = ""
            self.isCancelled = false
            
            // Initialize a new abort flag and set it to false
            if self.abortFlag != nil {
                self.abortFlag?.deallocate()
            }
            self.abortFlag = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
            self.abortFlag?.initialize(to: false)
        }
        
        defer {
            Task { @MainActor in
                self.isTranscribing = false
                self.currentSegment = ""
                if !self.isCancelled {
                    self.progress = 1.0
                }
                self.transcriptionTask = nil
            }
        }
        
        let asset = AVAsset(url: url)
        let duration = try await asset.load(.duration)
        let durationInSeconds = Float(CMTimeGetSeconds(duration))
        
        await MainActor.run {
            self.totalDuration = durationInSeconds
        }
        
        // Get the context and abort flag before detaching to a background task
        let contextForTask = context
        let abortFlagForTask = abortFlag
        
        // Create and store the task
        let task = Task.detached(priority: .userInitiated) { [self] in
            // Check for cancellation
            try Task.checkCancellation()
            
            guard let context = contextForTask else {
                throw TranscriptionError.contextInitializationFailed
            }
            
            guard let samples = try await self.convertAudioToPCM(fileURL: url) else {
                throw TranscriptionError.audioConversionFailed
            }
            
            // Check for cancellation
            try Task.checkCancellation()
            
            let nThreads = 4
            
            guard context.pcmToMel(samples: samples, nSamples: samples.count, nThreads: nThreads) else {
                throw TranscriptionError.processingFailed
            }
            
            // Check for cancellation
            try Task.checkCancellation()
            
            guard context.encode(offset: 0, nThreads: nThreads) else {
                throw TranscriptionError.processingFailed
            }
            
            // Check for cancellation
            try Task.checkCancellation()
            
            var params = WhisperFullParams()
            
            params.strategy = settings.useBeamSearch ? .beamSearch : .greedy
            params.nThreads = Int32(nThreads)
            params.noTimestamps = !settings.showTimestamps
            params.suppressBlank = settings.suppressBlankAudio
            params.translate = settings.translateToEnglish
            params.language = settings.selectedLanguage != "auto" ? settings.selectedLanguage : nil
            params.detectLanguage = settings.selectedLanguage == "auto"
            
            params.temperature = Float(settings.temperature)
            params.noSpeechThold = Float(settings.noSpeechThreshold)
            params.initialPrompt = settings.initialPrompt.isEmpty ? nil : settings.initialPrompt
            
            // Set up the abort callback
            typealias GGMLAbortCallback = @convention(c) (UnsafeMutableRawPointer?) -> Bool
            
            let abortCallback: GGMLAbortCallback = { userData in
                guard let userData = userData else { return false }
                let flag = userData.assumingMemoryBound(to: Bool.self)
                return flag.pointee
            }
            
            if settings.useBeamSearch {
                params.beamSearchBeamSize = Int32(settings.beamSize)
            }
            
            params.printRealtime = true
            params.print_realtime = true
            
            // Set up the segment callback
            let segmentCallback: @convention(c) (OpaquePointer?, OpaquePointer?, Int32, UnsafeMutableRawPointer?) -> Void = { ctx, state, n_new, user_data in
                guard let ctx = ctx,
                      let userData = user_data,
                      let service = Unmanaged<TranscriptionService>.fromOpaque(userData).takeUnretainedValue() as TranscriptionService?
                else { return }
                
                // Process the segment in a non-isolated context
                let segmentInfo = service.processNewSegment(context: ctx, state: state, nNew: Int(n_new))
                
                // Update UI on the main thread
                Task { @MainActor in
                    // Check if cancelled
                    if service.isCancelled { return }
                    
                    if !segmentInfo.text.isEmpty {
                        service.currentSegment = segmentInfo.text
                        // The main transcribedText will be assembled at the end or if live insertion is off.
                        // If live insertion is on, we avoid duplicating text here for the main log,
                        // but individual segments are still inserted.
                        if !AppPreferences.shared.liveTextInsertion {
                             service.transcribedText += segmentInfo.text + "\n"
                        }

                        // Live text insertion
                        if AppPreferences.shared.liveTextInsertion {
                            ClipboardUtil.insertTextUsingPasteboard(segmentInfo.text)
                        }
                    }
                    
                    if service.totalDuration > 0 && segmentInfo.timestamp > 0 {
                        let newProgress = min(segmentInfo.timestamp / service.totalDuration, 1.0)
                        service.progress = newProgress
                    }
                }
            }
            
            // Set the callbacks in the params
            params.newSegmentCallback = segmentCallback
            params.newSegmentCallbackUserData = Unmanaged.passUnretained(self).toOpaque()
            
            // Convert to C params and set the abort callback
            var cParams = params.toC()
            cParams.abort_callback = abortCallback
            
            // Set the abort flag user data
            if let abortFlag = abortFlagForTask {
                cParams.abort_callback_user_data = UnsafeMutableRawPointer(abortFlag)
            }
            
            // Check for cancellation
            try Task.checkCancellation()
            
            guard context.full(samples: samples, params: &cParams) else {
                throw TranscriptionError.processingFailed
            }
            
            // Check for cancellation
            try Task.checkCancellation()
            
            // If live text insertion was enabled, transcribedText was populated segment by segment for the UI log,
            // but we still want the full, clean transcript at the end.
            // If live text insertion was OFF, transcribedText has been accumulating.
            // The final text construction from segments is crucial for accuracy and completeness.
            var finalTextAccumulator = ""
            let nSegments = context.fullNSegments
            
            for i in 0..<nSegments {
                // Check for cancellation periodically
                if i % 5 == 0 {
                    try Task.checkCancellation()
                }
                
                guard let segmentText = context.fullGetSegmentText(iSegment: i) else { continue }
                
                var segmentLine = ""
                if settings.showTimestamps {
                    let t0 = context.fullGetSegmentT0(iSegment: i)
                    let t1 = context.fullGetSegmentT1(iSegment: i)
                    segmentLine += String(format: "[%.1f->%.1f] ", Float(t0) / 100.0, Float(t1) / 100.0)
                }
                segmentLine += segmentText
                finalTextAccumulator += segmentLine + "\n"
            }
            
            let cleanedFinalText = finalTextAccumulator
                .replacingOccurrences(of: "[MUSIC]", with: "")
                .replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            
            let resultText = cleanedFinalText.isEmpty ? "No speech detected in the audio" : cleanedFinalText
            
            await MainActor.run {
                if !self.isCancelled {
                    // Update the main transcribedText with the fully processed text
                    self.transcribedText = resultText
                    self.progress = 1.0
                }
            }
            
            return resultText
        }
        
        // Store the task
        await MainActor.run {
            self.transcriptionTask = task
        }
        
        do {
            return try await task.value
        } catch is CancellationError {
            // Handle cancellation
            await MainActor.run {
                self.isCancelled = true
                // Make sure the abort flag is set to true
                self.abortFlag?.pointee = true
            }
            throw TranscriptionError.processingFailed
        }
    }
    
    // MARK: - Live Transcription Methods
    
    func startLiveTranscription(settings: Settings) {
        Task { @MainActor in
            print("Starting live transcription...")
            self.isLiveTranscribing = true
            self.liveSettings = settings
            self.transcribedText = "" // Reset text for the new live session
            self.currentSegment = ""
            self.progress = 0.0 // Progress might be managed differently for live
            
            // Initialize liveAbortFlag
            if self.liveAbortFlag != nil {
                self.liveAbortFlag?.deallocate()
            }
            self.liveAbortFlag = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
            self.liveAbortFlag?.initialize(to: false)
        }
        
        liveTranscriptionQueue.async { [weak self] in
            self?.liveAudioBuffer.removeAll(keepingCapacity: true)
            print("Live audio buffer cleared.")
        }
        
        // Ensure context is loaded (should be by init)
        if context == nil {
            print("Error: Whisper context not loaded for live transcription.")
            Task { @MainActor in self.isLiveTranscribing = false }
            // Consider re-calling loadModel or signaling an error
        }
    }
    
    func processAudioChunk(_ pcmSamples: [Float]) {
        liveTranscriptionQueue.async { [weak self] in
            guard let self = self, self.isLiveTranscribing, self.context != nil else { return }
            
            self.liveAudioBuffer.append(contentsOf: pcmSamples)
            // print("Live buffer size: \(self.liveAudioBuffer.count) samples")

            // Check if buffer is full enough AND no other processing task is running
            guard self.liveAudioBuffer.count >= self.LIVE_AUDIO_BUFFER_TARGET_SAMPLES,
                  self.liveTranscriptionProcessingTask == nil else {
                return
            }
            
            let samplesToProcess = self.liveAudioBuffer
            self.liveAudioBuffer.removeAll(keepingCapacity: true) // Clear buffer for next accumulation
            
            print("Processing chunk of \(samplesToProcess.count) samples.")

            self.liveTranscriptionProcessingTask = Task.detached(priority: .userInitiated) { [weak self] in
                guard let self = self, // Strong self for task duration
                      let context = self.context, // Ensure context is still valid
                      let currentSettings = self.liveSettings, // Ensure settings are available
                      self.isLiveTranscribing // Ensure still in live mode
                else {
                    print("Live transcription processing task cancelled or self/context/settings nil before start.")
                    self?.liveTranscriptionProcessingTask = nil // Clear task holder
                    return
                }
                
                defer {
                    // Ensure task holder is cleared on the queue once processing is done or fails
                    self.liveTranscriptionQueue.async {
                        self?.liveTranscriptionProcessingTask = nil
                    }
                }

                var params = WhisperFullParams()
                params.strategy = currentSettings.useBeamSearch ? .beamSearch : .greedy
                params.nThreads = Int32(4) // Example, make configurable if needed
                params.noTimestamps = !currentSettings.showTimestamps // ShowTimestamps from settings
                params.suppressBlank = currentSettings.suppressBlankAudio
                params.translate = currentSettings.translateToEnglish
                params.language = currentSettings.selectedLanguage != "auto" ? currentSettings.selectedLanguage : nil
                params.detectLanguage = currentSettings.selectedLanguage == "auto"
                params.temperature = Float(currentSettings.temperature)
                params.noSpeechThold = Float(currentSettings.noSpeechThreshold)
                params.initialPrompt = currentSettings.initialPrompt.isEmpty ? nil : currentSettings.initialPrompt
                if currentSettings.useBeamSearch {
                    params.beamSearchBeamSize = Int32(currentSettings.beamSize)
                }
                params.printRealtime = true // Already true, but for clarity
                
                // Setup callbacks
                params.newSegmentCallback = { ctx, state, n_new, user_data in
                    guard let userData = user_data else { return }
                    let service = Unmanaged<TranscriptionService>.fromOpaque(userData).takeUnretainedValue()
                    let segmentInfo = service.processNewSegment(context: ctx!, state: state, nNew: Int(n_new))
                    
                    Task { @MainActor in
                        if service.isCancelled || !service.isLiveTranscribing { return } // Check both cancellation flags
                        
                        if !segmentInfo.text.isEmpty {
                            service.currentSegment = segmentInfo.text
                            if !AppPreferences.shared.liveTextInsertion {
                                service.transcribedText += segmentInfo.text + "\n"
                            }
                            if AppPreferences.shared.liveTextInsertion {
                                ClipboardUtil.insertTextUsingPasteboard(segmentInfo.text)
                            }
                        }
                        // Progress for live transcription might be different, e.g., based on time or segments processed
                        // For now, keep the existing progress logic which might not be ideal for live.
                         if service.totalDuration > 0 && segmentInfo.timestamp > 0 { // totalDuration is 0 for live
                             let newProgress = min(segmentInfo.timestamp / service.totalDuration, 1.0)
                             service.progress = newProgress
                         }
                    }
                }
                params.newSegmentCallbackUserData = Unmanaged.passUnretained(self).toOpaque()
                
                var cParams = params.toC()
                cParams.abort_callback = { userData in
                    guard let userData = userData else { return false }
                    let flag = userData.assumingMemoryBound(to: Bool.self)
                    return flag.pointee
                }
                if let liveAbortFlag = self.liveAbortFlag {
                    cParams.abort_callback_user_data = UnsafeMutableRawPointer(liveAbortFlag)
                } else {
                     print("Warning: liveAbortFlag is nil during C param setup.")
                }

                print("Starting context.full for live chunk of \(samplesToProcess.count) samples.")
                if !context.full(samples: samplesToProcess, params: &cParams) {
                    print("Failed to process live audio chunk.")
                    // Error handling: Maybe set an error state or log more details
                } else {
                    print("Live audio chunk processed successfully.")
                }
            }
        }
    }

    func stopLiveTranscription() {
        Task { @MainActor in
            print("Stopping live transcription...")
            if !self.isLiveTranscribing { return } // Already stopped or never started
            self.isLiveTranscribing = false
        }

        liveTranscriptionQueue.async { [weak self] in
            guard let self = self else { return }

            if let liveAbortFlag = self.liveAbortFlag {
                liveAbortFlag.pointee = true
                print("Live abort flag set to true.")
            }
            
            self.liveTranscriptionProcessingTask?.cancel() // Cancel the Swift Task
            // self.liveTranscriptionProcessingTask = nil // Task will clear itself from queue

            // Process any remaining audio if substantial enough and no task is running
            // For simplicity, we'll just log and clear for now.
            // A more robust solution might queue one last processing task.
            if !self.liveAudioBuffer.isEmpty {
                print("Clearing \(self.liveAudioBuffer.count) remaining samples from live buffer.")
                self.liveAudioBuffer.removeAll(keepingCapacity: true)
            }
            
            // Deallocate liveAbortFlag after ensuring any task using it has finished or been cancelled
            // This needs careful handling; defer deallocation if task might still access it.
            // For now, deallocate here. If crashes occur, move deallocation to after task completion.
            self.liveAbortFlag?.deallocate()
            self.liveAbortFlag = nil
            
            self.liveSettings = nil
            print("Live transcription stopped and resources cleaned up on queue.")
        }
    }

    // MARK: - Common and File-based Methods
    
    // This method is nonisolated and used by both file and live transcription.
    // It should remain nonisolated.
    nonisolated func processNewSegment(context: OpaquePointer, state: OpaquePointer?, nNew: Int) -> (text: String, timestamp: Float) {
        let nSegments = Int(whisper_full_n_segments(context))
        // For live transcription, nNew might represent segments from the current chunk.
        // The logic here correctly extracts text for these new segments.
        let startIdx = max(0, nSegments - nNew) 
        
        var newText = ""
        var latestTimestamp: Float = 0 // Timestamp relative to the current chunk
        
        for i in startIdx..<nSegments {
            guard let cString = whisper_full_get_segment_text(context, Int32(i)) else { continue }
            let segmentText = String(cString: cString)
            newText += segmentText // Append segment text, add space later if needed or rely on UI
            
            // Timestamps from whisper_full_get_segment_tX are relative to the start of the audio fed to whisper_full.
            // For chunked processing, these are timestamps within the chunk.
            let t1 = Float(whisper_full_get_segment_t1(context, Int32(i))) / 100.0 
            latestTimestamp = max(latestTimestamp, t1)
        }
        
        // For live streaming, we might want to trim less aggressively or handle spaces carefully.
        // For now, keep existing trimming.
        let cleanedText = newText.trimmingCharacters(in: .whitespacesAndNewlines) 
        return (cleanedText, latestTimestamp)
    }
    
    // This method is nonisolated.
    nonisolated func createContext() -> MyWhisperContext? {
        guard let modelPath = AppPreferences.shared.selectedModelPath else {
            print("Error: Model path not found for context creation.")
            return nil
        }
        
        let params = WhisperContextParams()
        return MyWhisperContext.initFromFile(path: modelPath, params: params)
    }
    
    nonisolated func convertAudioToPCM(fileURL: URL) async throws -> [Float]? {
        return try await Task.detached(priority: .userInitiated) {
            let audioFile = try AVAudioFile(forReading: fileURL)
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                       sampleRate: 16000,
                                       channels: 1,
                                       interleaved: false)!
            
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let converter = AVAudioConverter(from: audioFile.processingFormat, to: format)!
            
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: audioFile.processingFormat)
            
            let lengthInFrames = UInt32(audioFile.length)
            let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                          frameCapacity: AVAudioFrameCount(lengthInFrames))
            
            guard let buffer = buffer else { return nil }
            
            var error: NSError?
            let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                do {
                    let tempBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat,
                                                      frameCapacity: AVAudioFrameCount(inNumPackets))
                    guard let tempBuffer = tempBuffer else {
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    try audioFile.read(into: tempBuffer)
                    outStatus.pointee = .haveData
                    return tempBuffer
                } catch {
                    outStatus.pointee = .endOfStream
                    return nil
                }
            }
            
            converter.convert(to: buffer,
                              error: &error,
                              withInputFrom: inputBlock)
            
            if let error = error {
                print("Conversion error: \(error)")
                return nil
            }
            
            guard let channelData = buffer.floatChannelData else { return nil }
            return Array(UnsafeBufferPointer(start: channelData[0],
                                             count: Int(buffer.frameLength)))
        }.value
    }
}

enum TranscriptionError: Error {
    case contextInitializationFailed
    case audioConversionFailed
    case processingFailed
}
