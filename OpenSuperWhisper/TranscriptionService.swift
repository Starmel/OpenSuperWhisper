import AVFoundation
import Foundation

@MainActor
class TranscriptionService: ObservableObject {
    static let shared = TranscriptionService()
    
    @Published private(set) var isTranscribing = false
    @Published private(set) var transcribedText = ""
    @Published private(set) var improvedText = ""
    @Published private(set) var currentSegment = ""
    @Published private(set) var isLoading = false
    @Published private(set) var progress: Float = 0.0
    @Published private(set) var isImprovingText = false
    
    private var context: MyWhisperContext?
    private var totalDuration: Float = 0.0
    private var transcriptionTask: Task<String, Error>? = nil
    private var isCancelled = false
    private var abortFlag: UnsafeMutablePointer<Bool>? = nil
    private var modelLoadingTask: Task<Void, Error>? = nil
    
    init() {
        // Model will be loaded lazily when needed for local transcription
    }
    
    func cancelTranscription() {
        isCancelled = true
        
        // Set the abort flag to true to signal the whisper processing to stop
        if let abortFlag = abortFlag {
            abortFlag.pointee = true
        }
        
        transcriptionTask?.cancel()
        transcriptionTask = nil
        
        // Reset state
        isTranscribing = false
        currentSegment = ""
        progress = 0.0
        isCancelled = false
    }
    
    deinit {
        // Free the abort flag if it exists
        abortFlag?.deallocate()
    }
    
    private func loadModel() {
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
                }
            }
        }
    }
    
    /// Ensure model is loaded with proper synchronization to prevent race conditions
    private func ensureModelLoaded() async throws {
        // If model is already loaded, return immediately
        guard context == nil else { return }
        
        // If loading is already in progress, wait for it to complete
        if let existingTask = modelLoadingTask {
            try await existingTask.value
            return
        }
        
        // Start model loading task
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            
            await MainActor.run {
                self.isLoading = true
            }
            
            guard let modelPath = AppPreferences.shared.selectedModelPath else {
                await MainActor.run {
                    self.isLoading = false
                }
                throw LegacyTranscriptionError.contextInitializationFailed
            }
            
            let params = WhisperContextParams()
            let newContext = MyWhisperContext.initFromFile(path: modelPath, params: params)
            
            await MainActor.run {
                self.context = newContext
                self.isLoading = false
            }
        }
        
        modelLoadingTask = task
        
        do {
            try await task.value
            modelLoadingTask = nil
        } catch {
            modelLoadingTask = nil
            throw error
        }
    }
    
    func reloadModel(with path: String) {
        // Cancel any ongoing model loading
        modelLoadingTask?.cancel()
        modelLoadingTask = nil
        
        // Reset context and reload
        context = nil
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
            }
        }
    }
    
    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        // Check if we should use the enhanced service with multiple providers
        let prefs = AppPreferences.shared
        if prefs.primarySTTProvider != "whisper_local" || prefs.enableSTTFallback {
            // Use the enhanced service for cloud providers or fallback
            let enhancedService = EnhancedTranscriptionService.shared
            let transcriptionSettings = TranscriptionSettings(
                whisperLanguage: prefs.whisperLanguage,
                showTimestamps: prefs.showTimestamps,  
                translateToEnglish: prefs.translateToEnglish,
                initialPrompt: prefs.initialPrompt,
                primarySTTProvider: prefs.primarySTTProvider,
                enableSTTFallback: prefs.enableSTTFallback,
                temperature: prefs.temperature,
                noSpeechThreshold: prefs.noSpeechThreshold,
                useBeamSearch: prefs.useBeamSearch,
                beamSize: prefs.beamSize,
                suppressBlankAudio: prefs.suppressBlankAudio
            )
            return try await enhancedService.transcribeAudio(url: url, settings: transcriptionSettings)
        }
        
        // Continue with local Whisper processing
        return try await transcribeAudioDirectly(url: url, settings: settings)
    }
    
    /// Direct local transcription method to avoid circular dependency with WhisperLocalProvider
    func transcribeAudioDirectly(url: URL, settings: Settings) async throws -> String {
        // Ensure model is loaded for local transcription with proper synchronization
        try await ensureModelLoaded()
        
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
                throw LegacyTranscriptionError.contextInitializationFailed
            }
            
            guard let samples = try await self.convertAudioToPCM(fileURL: url) else {
                throw LegacyTranscriptionError.audioConversionFailed
            }
            
            // Check for cancellation
            try Task.checkCancellation()
            
            let nThreads = 4
            
            guard context.pcmToMel(samples: samples, nSamples: samples.count, nThreads: nThreads) else {
                throw LegacyTranscriptionError.processingFailed
            }
            
            // Check for cancellation
            try Task.checkCancellation()
            
            guard context.encode(offset: 0, nThreads: nThreads) else {
                throw LegacyTranscriptionError.processingFailed
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
            params.detectLanguage = false // should be false, whisper handles language detection by language property.
            
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
                        service.transcribedText += segmentInfo.text + "\n"
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
                throw LegacyTranscriptionError.processingFailed
            }
            
            // Check for cancellation
            try Task.checkCancellation()
            
            var text = ""
            let nSegments = context.fullNSegments
            
            for i in 0..<nSegments {
                // Check for cancellation periodically
                if i % 5 == 0 {
                    try Task.checkCancellation()
                }
                
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
            
            await MainActor.run {
                if !self.isCancelled {
                    self.transcribedText = finalText
                    self.progress = 1.0
                }
            }
            
            // Attempt text improvement if enabled
            let improvedFinalText = await self.improveTextIfEnabled(finalText)
            
            return improvedFinalText
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
            throw LegacyTranscriptionError.processingFailed
        }
    }
    
    // Make this method nonisolated to be callable from any context
    nonisolated func processNewSegment(context: OpaquePointer, state: OpaquePointer?, nNew: Int) -> (text: String, timestamp: Float) {
        let nSegments = Int(whisper_full_n_segments(context))
        let startIdx = max(0, nSegments - nNew)
        
        var newText = ""
        var latestTimestamp: Float = 0
        
        for i in startIdx..<nSegments {
            guard let cString = whisper_full_get_segment_text(context, Int32(i)) else { continue }
            let segmentText = String(cString: cString)
            newText += segmentText + " "
            
            let t1 = Float(whisper_full_get_segment_t1(context, Int32(i))) / 100.0
            latestTimestamp = max(latestTimestamp, t1)
        }
        
        let cleanedText = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleanedText, latestTimestamp)
    }
    
    // Make this method nonisolated to be callable from any context
    nonisolated func createContext() -> MyWhisperContext? {
        guard let modelPath = AppPreferences.shared.selectedModelPath else {
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
                return nil
            }
            
            guard let channelData = buffer.floatChannelData else { return nil }
            return Array(UnsafeBufferPointer(start: channelData[0],
                                             count: Int(buffer.frameLength)))
        }.value
    }
    
    // MARK: - Text Improvement Integration
    
    private func improveTextIfEnabled(_ text: String) async -> String {
        // Check if text improvement is enabled
        guard TextImprovementService.shared.isEnabled else {
            return text
        }
        
        // Skip improvement for very short text or "no speech" messages
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty,
              trimmedText != "No speech detected in the audio",
              trimmedText.count > 10 else {
            return text
        }
        
        await MainActor.run {
            self.isImprovingText = true
        }
        
        defer {
            Task { @MainActor in
                self.isImprovingText = false
            }
        }
        
        do {
            let improvedText = try await TextImprovementService.shared.improveText(text)
            
            await MainActor.run {
                self.improvedText = improvedText
            }
            
            // Return improved text if it's not empty, otherwise return original
            return improvedText.isEmpty ? text : improvedText
            
        } catch {
            // If improvement fails, return original text
            print("Text improvement failed: \(error.localizedDescription)")
            return text
        }
    }
}

enum LegacyTranscriptionError: Error {
    case contextInitializationFailed
    case audioConversionFailed
    case processingFailed
}
