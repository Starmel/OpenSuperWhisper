import Foundation
import AVFoundation
import CoreAudioTypes

private class ProgressContext {
    var onProgress: ((Float) -> Void)?
    private var _lastReportedProgress: Float = 0.0
    private let lock = NSLock()
    
    var lastReportedProgress: Float {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _lastReportedProgress
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _lastReportedProgress = newValue
        }
    }
}

/// Thread-safe cancellation flag. Owned by the engine for its whole lifetime,
/// so the pointer passed into whisper's C callback can never dangle.
private final class AbortFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _isSet = false
    
    var isSet: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _isSet
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _isSet = newValue
        }
    }
}

class WhisperEngine: TranscriptionEngine {
    private enum AudioInput {
        case file(URL)
        case pcm([Float])
    }
    struct DecodedSegment: Equatable {
        let text: String
        let endTimeCentiseconds: Int64
    }

    struct DetailedTranscription {
        let text: String
        let segments: [DecodedSegment]
    }

    var engineName: String { "Whisper" }
    
    /// Silero VAD model shipped in the app bundle; always used to drop
    /// non-speech audio before the encoder (faster, no hallucinations on silence).
    static let vadModelPath = Bundle(for: WhisperEngine.self)
        .path(forResource: "ggml-silero-v5.1.2", ofType: "bin")
    
    private var context: MyWhisperContext?
    private var vadContext: MyWhisperVadContext?
    private let abortFlag = AbortFlag()
    private var progressContext: ProgressContext?
    
    var onProgressUpdate: ((Float) -> Void)?
    
    var isModelLoaded: Bool {
        context != nil
    }

    var hasPreparedState: Bool { context?.hasState == true }

    func prepareForRecording() throws {
        guard let context else {
            throw TranscriptionError.contextInitializationFailed
        }
        if !context.hasState && !context.initState() {
            throw TranscriptionError.contextInitializationFailed
        }
    }
    
    private let modelPath: String?

    init(modelPath: String? = nil) {
        self.modelPath = modelPath ?? AppPreferences.shared.selectedWhisperModelPath ?? AppPreferences.shared.selectedModelPath
    }

    func initialize() async throws {
        guard let modelPath = modelPath else {
            throw TranscriptionError.contextInitializationFailed
        }
        
        let params = WhisperContextParams()
        // Load the model without a decoding state: a fresh whisper_state is
        // created per transcription, so recordings can share the model weights
        // while keeping their decoding context (prompt_past) fully isolated.
        context = MyWhisperContext.initFromFileNoState(path: modelPath, params: params)
        
        guard context != nil else {
            throw TranscriptionError.contextInitializationFailed
        }

        guard let path = Self.vadModelPath,
              let vad = MyWhisperVadContext(modelPath: path) else {
            throw TranscriptionError.contextInitializationFailed
        }
        vadContext = vad
    }
    
    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        try await transcribeAudioDetailed(url: url, settings: settings).text
    }

    /// Internal detailed result used by long-form regression tests. Production
    /// callers keep receiving only the final text through TranscriptionEngine.
    func transcribeAudioDetailed(
        url: URL,
        settings: Settings
    ) async throws -> DetailedTranscription {
        try await transcribe(input: .file(url), settings: settings)
    }

    func transcribeSamples(_ samples: [Float], settings: Settings) async throws -> String {
        try await transcribe(input: .pcm(samples), settings: settings).text
    }

    private func transcribe(input: AudioInput, settings: Settings) async throws -> DetailedTranscription {
        try await withTaskCancellationHandler {
            try await performTranscription(input: input, settings: settings)
        } onCancel: { [abortFlag] in
            abortFlag.isSet = true
        }
    }

    private func performTranscription(
        input: AudioInput,
        settings: Settings
    ) async throws -> DetailedTranscription {
        try Task.checkCancellation()

        guard let context = context else {
            throw TranscriptionError.contextInitializationFailed
        }
        defer { context.freeState() }
        
        abortFlag.isSet = false
        try Task.checkCancellation()
        
        // Setup progress context for callback
        progressContext = ProgressContext()
        progressContext?.onProgress = onProgressUpdate
        
        defer {
            progressContext = nil
        }
        
        // Notify conversion start (0-10% is conversion phase)
        onProgressUpdate?(0.05)
        
        let converted: [Float]
        switch input {
        case .pcm(let samples):
            guard !samples.isEmpty else { throw TranscriptionError.audioConversionFailed }
            converted = samples
        case .file(let url):
            guard let samples = try await convertAudioToPCM(
                fileURL: url,
                cancellationCheck: { [abortFlag] in abortFlag.isSet }
            ) else {
                if abortFlag.isSet || Task.isCancelled { throw CancellationError() }
                throw TranscriptionError.audioConversionFailed
            }
            converted = samples
        }
        
        // Conversion done, now processing
        onProgressUpdate?(0.10)
        
        try Task.checkCancellation()
        
        // VAD gate: whisper never sees non-speech audio, so silence cannot
        // produce hallucinated text and long pauses are not decoded at all.
        // (whisper_full_with_state has no built-in VAD path — params.vad works
        // only through whisper_full, which would share decoding state.)
        let speechSegments = try detectSpeech(in: converted)
        try Task.checkCancellation()
        if abortFlag.isSet { throw CancellationError() }
        if speechSegments.isEmpty {
            return DetailedTranscription(text: "", segments: [])
        }
        // Timestamps of the trimmed audio would not match the original file,
        // so trimming is applied only when timestamps are not requested.
        let samples = settings.showTimestamps
            ? converted
            : Self.speechOnlySamples(from: converted, segments: speechSegments)
        
        let nThreads = max(2, min(ProcessInfo.processInfo.activeProcessorCount, 8))
        
        let initialPromptTokenCount = settings.initialPrompt.isEmpty
            ? 0
            : context.tokenCount(text: settings.initialPrompt)
        var params = Self.makeFullParams(
            settings: settings,
            nThreads: nThreads,
            modelTextContext: context.nTextCtx,
            initialPromptTokenCount: initialPromptTokenCount
        )
        
        typealias GGMLAbortCallback = @convention(c) (UnsafeMutableRawPointer?) -> Bool
        let abortCallback: GGMLAbortCallback = { userData in
            guard let userData = userData else { return false }
            return Unmanaged<AbortFlag>.fromOpaque(userData).takeUnretainedValue().isSet
        }
        
        // Progress callback: whisper reports 0-100%, we map to 10-95%
        // Note: callback is called from C code, we need to bridge to Swift safely
        typealias WhisperProgressCallback = @convention(c) (OpaquePointer?, OpaquePointer?, Int32, UnsafeMutableRawPointer?) -> Void
        let progressCallback: WhisperProgressCallback = { _, _, progressPercent, userData in
            guard let userData = userData else { return }
            let ctx = Unmanaged<ProgressContext>.fromOpaque(userData).takeUnretainedValue()
            // Map whisper progress (0-100) to our range (10-95%)
            let normalizedProgress = 0.10 + (Float(progressPercent) / 100.0) * 0.85
            // Report every progress update for smooth animation
            if normalizedProgress > ctx.lastReportedProgress {
                ctx.lastReportedProgress = normalizedProgress
                DispatchQueue.main.async {
                    ctx.onProgress?(normalizedProgress)
                }
            }
        }
        
        let progressContextPtr = Unmanaged.passUnretained(progressContext!).toOpaque()
        params.progressCallback = progressCallback
        params.progressCallbackUserData = progressContextPtr
        
        if settings.useBeamSearch {
            params.beamSearchBeamSize = Int32(settings.beamSize)
        }
        
        var cParams = params.toC()
        cParams.abort_callback = abortCallback
        cParams.abort_callback_user_data = Unmanaged.passUnretained(abortFlag).toOpaque()
        
        try Task.checkCancellation()
        
        // Fresh decoding state per recording: isolates prompt_past between
        // recordings (a hallucination on silence cannot poison the next one).
        try prepareForRecording()
        
        guard context.full(samples: samples, params: &cParams) else {
            if abortFlag.isSet || Task.isCancelled {
                throw CancellationError()
            }
            throw TranscriptionError.processingFailed
        }
        
        try Task.checkCancellation()
        
        var segmentTexts: [String] = []
        var decodedSegments: [DecodedSegment] = []
        let nSegments = context.fullNSegments
        segmentTexts.reserveCapacity(nSegments)
        decodedSegments.reserveCapacity(nSegments)
        
        for i in 0..<nSegments {
            if i % 5 == 0 {
                try Task.checkCancellation()
            }
            
            guard let segmentText = context.fullGetSegmentText(iSegment: i) else { continue }
            let segmentEnd = context.fullGetSegmentT1(iSegment: i)
            decodedSegments.append(
                DecodedSegment(
                    text: segmentText,
                    endTimeCentiseconds: segmentEnd
                )
            )
            
            if settings.showTimestamps {
                let t0 = context.fullGetSegmentT0(iSegment: i)
                segmentTexts.append(
                    String(format: "[%.1f->%.1f] ", Float(t0) / 100.0, Float(segmentEnd) / 100.0)
                        + segmentText
                )
            } else {
                segmentTexts.append(segmentText)
            }
        }
        
        let cleanedText = Self.assembleSegmentTexts(
            segmentTexts,
            showTimestamps: settings.showTimestamps
        )
            .replacingOccurrences(of: "[MUSIC]", with: "")
            .replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        var processedText = cleanedText
        if settings.shouldApplyAsianAutocorrect && !cleanedText.isEmpty {
            processedText = AutocorrectWrapper.format(cleanedText)
        }
        
        return DetailedTranscription(
            text: processedText,
            segments: decodedSegments
        )
    }

    /// Whisper segments are decoder boundaries, not paragraph boundaries.
    /// Their text already contains the token-level whitespace needed between
    /// adjacent segments, so adding a newline (or an inferred space) changes
    /// the dictated text. Timestamp mode remains line-oriented for readability.
    static func assembleSegmentTexts(_ segments: [String], showTimestamps: Bool) -> String {
        segments.joined(separator: showTimestamps ? "\n" : "")
    }

    static func makeFullParams(
        settings: Settings,
        nThreads: Int,
        modelTextContext: Int,
        initialPromptTokenCount: Int
    ) -> WhisperFullParams {
        var params = WhisperFullParams()
        params.strategy = settings.useBeamSearch ? .beamSearch : .greedy
        params.nThreads = Int32(nThreads)
        // Match whisper.cpp defaults: on temperature fallback the decoder samples
        // best_of candidates and keeps the most probable one; with 1 the fallback
        // degenerates to a single random sample on hard audio.
        params.greedyBestOf = 5

        // A fresh state isolates recordings, while prompt_past must remain enabled
        // between the decoder's 30-second windows inside this recording.
        params.noContext = false
        let rollingContextCapacity = max(1, modelTextContext / 2)
        params.nMaxTextCtx = Int32(clamping: rollingContextCapacity)
        params.noTimestamps = !settings.showTimestamps
        params.suppressBlank = settings.suppressBlankAudio
        let isAutoDetect = settings.selectedLanguage == "auto"
        params.language = isAutoDetect ? nil : settings.selectedLanguage
        params.detectLanguage = false
        params.temperature = Float(settings.temperature)
        params.noSpeechThold = Float(settings.noSpeechThreshold)
        params.initialPrompt = settings.initialPrompt.isEmpty
            ? nil
            : settings.initialPrompt

        // A very long static prompt can otherwise consume the entire prompt
        // budget on every window and evict prompt_past. Carry it only while at
        // least half of the rolling budget remains available for prior speech.
        let maxCarriedPromptTokens = max(1, (rollingContextCapacity - 1) / 2)
        params.carryInitialPrompt = params.initialPrompt != nil
            && initialPromptTokenCount <= maxCarriedPromptTokens
        return params
    }
    
    func cancelTranscription() {
        abortFlag.isSet = true
    }
    
    // MARK: - VAD
    
    private func detectSpeech(in samples: [Float]) throws -> [WhisperVadSegment] {
        guard let vadContext else {
            throw TranscriptionError.contextInitializationFailed
        }
        guard let segments = vadContext.speechSegments(in: samples) else {
            throw TranscriptionError.processingFailed
        }
        return segments
    }
    
    /// Keeps only speech, mirroring upstream whisper_full VAD stitching:
    /// each segment (already padded by the VAD) gets 0.1s of the following
    /// audio as overlap and segments are separated by 0.1s of silence, so the
    /// decoder still sees natural pauses between phrases.
    static func speechOnlySamples(from samples: [Float], segments: [WhisperVadSegment]) -> [Float] {
        let samplesPerCs = 160 // 16 kHz / 100
        let overlapSamples = 1600 // 0.1 s
        let gapSamples = 1600 // 0.1 s
        
        var result = [Float]()
        for (index, segment) in segments.enumerated() {
            let start = min(max(0, Int(segment.startCs) * samplesPerCs), samples.count)
            var end = min(Int(segment.endCs) * samplesPerCs, samples.count)
            if index < segments.count - 1 {
                end = min(end + overlapSamples, samples.count)
            }
            guard end > start else { continue }
            
            result.append(contentsOf: samples[start..<end])
            if index < segments.count - 1 {
                result.append(contentsOf: repeatElement(0, count: gapSamples))
            }
        }
        return result
    }
    
    func getSupportedLanguages() -> [String] {
        return LanguageUtil.availableLanguages
    }
    
    private nonisolated func resolveFileURL(_ fileURL: URL) throws -> (URL, Bool) {
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        guard data.count >= 12 else { return (fileURL, false) }

        let ext = fileURL.pathExtension.lowercased()

        let isMP4Header = data[4...7].elementsEqual([0x66, 0x74, 0x79, 0x70]) // "ftyp"
        if isMP4Header && ext != "m4a" && ext != "mp4" && ext != "m4b" && ext != "aac" {
            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("m4a")
            try FileManager.default.copyItem(at: fileURL, to: tmpURL)
            return (tmpURL, true)
        }

        return (fileURL, false)
    }

    nonisolated func convertAudioToPCM(
        fileURL: URL,
        cancellationCheck: @escaping () -> Bool = { false }
    ) async throws -> [Float]? {
        return try await Task.detached(priority: .userInitiated) {
            if cancellationCheck() { throw CancellationError() }
            let (resolvedURL, isTempFile) = try self.resolveFileURL(fileURL)
            defer {
                if isTempFile { try? FileManager.default.removeItem(at: resolvedURL) }
            }
            let audioFile = try AVAudioFile(forReading: resolvedURL)
            let sourceFormat = audioFile.processingFormat
            let totalFrames = audioFile.length
            if cancellationCheck() { throw CancellationError() }
            
            guard let targetFormat = self.makeTargetFormat(channelCount: sourceFormat.channelCount) else {
                return nil
            }
            
            let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
            
            // Use parallel processing for large files (> 10 seconds of audio)
            // Benchmarked: 4 cores = +339%, 8 cores = +609% improvement
            let minFramesForParallel = AVAudioFramePosition(sourceFormat.sampleRate * 10)
            let workerCount = totalFrames > minFramesForParallel ? ProcessInfo.processInfo.activeProcessorCount : 1
            
            if workerCount == 1 {
                let result = try self.convertSegment(
                    fileURL: resolvedURL,
                    sourceFormat: sourceFormat,
                    targetFormat: targetFormat,
                    ratio: ratio,
                    startFrame: 0,
                    frameCount: totalFrames,
                    inputChunkSize: 1_048_576,
                    cancellationCheck: cancellationCheck
                )
                return result.isEmpty ? nil : result
            }
            
            // Parallel processing: each worker converts its own frame range with an
            // independent converter (flushed at the end), results are concatenated in
            // worker order so no samples are lost or overwritten at boundaries.
            let framesPerWorker = totalFrames / AVAudioFramePosition(workerCount)
            var segmentResults = [[Float]?](repeating: nil, count: workerCount)
            let resultLock = NSLock()
            
            let group = DispatchGroup()
            let queue = DispatchQueue(label: "audio.conversion.parallel", attributes: .concurrent)
            
            for workerIndex in 0..<workerCount {
                group.enter()
                queue.async {
                    defer { group.leave() }
                    
                    let startFrame = AVAudioFramePosition(workerIndex) * framesPerWorker
                    let endFrame = workerIndex == workerCount - 1 ? totalFrames : startFrame + framesPerWorker
                    
                    let segment = try? self.convertSegment(
                        fileURL: resolvedURL,
                        sourceFormat: sourceFormat,
                        targetFormat: targetFormat,
                        ratio: ratio,
                        startFrame: startFrame,
                        frameCount: endFrame - startFrame,
                        inputChunkSize: 262_144,
                        cancellationCheck: cancellationCheck
                    )
                    
                    resultLock.lock()
                    segmentResults[workerIndex] = segment
                    resultLock.unlock()
                }
            }
            
            group.wait()

            if cancellationCheck() { throw CancellationError() }
            
            guard !segmentResults.contains(where: { $0 == nil }) else { return nil }
            
            // Release each segment right after it is appended, so the peak stays
            // near 1x of the total instead of holding both copies until the end.
            var result = [Float]()
            result.reserveCapacity(segmentResults.reduce(0) { $0 + ($1?.count ?? 0) })
            for index in segmentResults.indices {
                if cancellationCheck() { throw CancellationError() }
                result.append(contentsOf: segmentResults[index]!)
                segmentResults[index] = nil
            }
            
            return result.isEmpty ? nil : result
        }.value
    }
    
    nonisolated func convertSegment(
        fileURL: URL,
        sourceFormat: AVAudioFormat,
        targetFormat: AVAudioFormat,
        ratio: Double,
        startFrame: AVAudioFramePosition,
        frameCount: AVAudioFramePosition,
        inputChunkSize: AVAudioFrameCount,
        cancellationCheck: @escaping () -> Bool
    ) throws -> [Float] {
        if cancellationCheck() { throw CancellationError() }
        let audioFile = try AVAudioFile(forReading: fileURL)
        audioFile.framePosition = startFrame
        
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw TranscriptionError.audioConversionFailed
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        
        // Buffers hold Float32 per channel, so cap the chunk by bytes: a chunk sized
        // in frames alone balloons for multi-channel sources (8ch = 32 MB per buffer).
        let maxChunkBytes = 8 * 1024 * 1024
        let bytesPerFrame = Int(sourceFormat.channelCount) * MemoryLayout<Float>.size
        let chunkFrames = min(inputChunkSize, AVAudioFrameCount(max(maxChunkBytes / bytesPerFrame, 65536)))
        
        let outputChunkSize = AVAudioFrameCount(Double(chunkFrames) * ratio) + 256
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: chunkFrames),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputChunkSize) else {
            throw TranscriptionError.audioConversionFailed
        }
        
        var result = [Float]()
        result.reserveCapacity(Int(Double(frameCount) * ratio) + 256)
        
        var framesRead: AVAudioFramePosition = 0
        
        while framesRead < frameCount {
            if cancellationCheck() { throw CancellationError() }
            let framesToRead = min(AVAudioFrameCount(frameCount - framesRead), chunkFrames)
            inputBuffer.frameLength = 0
            try audioFile.read(into: inputBuffer, frameCount: framesToRead)
            
            if inputBuffer.frameLength == 0 { break }
            framesRead += AVAudioFramePosition(inputBuffer.frameLength)
            
            var inputConsumed = false
            var convError: NSError?
            
            outputBuffer.frameLength = 0
            converter.convert(to: outputBuffer, error: &convError) { _, outStatus in
                if inputConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                inputConsumed = true
                outStatus.pointee = .haveData
                return inputBuffer
            }
            
            if let convError = convError {
                throw convError
            }
            
            appendMixedSamples(from: outputBuffer, to: &result)
        }
        
        // Flush the resampler: without an .endOfStream pass its internal latency
        // (the last few milliseconds of audio) is silently dropped.
        var status = AVAudioConverterOutputStatus.haveData
        while status == .haveData {
            if cancellationCheck() { throw CancellationError() }
            var convError: NSError?
            outputBuffer.frameLength = 0
            status = converter.convert(to: outputBuffer, error: &convError) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            if convError != nil { break }
            appendMixedSamples(from: outputBuffer, to: &result)
        }
        
        return result
    }
    
    private nonisolated func appendMixedSamples(from buffer: AVAudioPCMBuffer, to output: inout [Float]) {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, let channelData = buffer.floatChannelData else { return }
        
        let channelCount = Int(buffer.format.channelCount)
        if channelCount == 1 {
            let mono = UnsafeBufferPointer(start: channelData[0], count: frameCount)
            output.append(contentsOf: mono)
            return
        }
        
        let activityThreshold: Float = 0.0001
        var activeChannels: [Int] = []
        activeChannels.reserveCapacity(channelCount)
        
        for channel in 0..<channelCount {
            let channelSamples = UnsafeBufferPointer(start: channelData[channel], count: frameCount)
            var energy: Float = 0
            for sample in channelSamples {
                energy += sample * sample
            }
            let rms = sqrtf(energy / Float(frameCount))
            if rms > activityThreshold {
                activeChannels.append(channel)
            }
        }
        
        if activeChannels.isEmpty {
            activeChannels = Array(0..<channelCount)
        }
        
        let normalization = 1.0 / Float(activeChannels.count)
        output.reserveCapacity(output.count + frameCount)
        
        for frame in 0..<frameCount {
            var mixed: Float = 0
            for channel in activeChannels {
                mixed += channelData[channel][frame]
            }
            output.append(mixed * normalization)
        }
    }
    
    nonisolated func makeTargetFormat(channelCount: AVAudioChannelCount) -> AVAudioFormat? {
        guard channelCount > 0 else { return nil }
        
        let layoutTag = AudioChannelLayoutTag(kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channelCount))
        guard let channelLayout = AVAudioChannelLayout(layoutTag: layoutTag) else { return nil }
        
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            interleaved: false,
            channelLayout: channelLayout
        )
    }
}
