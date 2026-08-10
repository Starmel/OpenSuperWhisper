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
private final class AbortFlag {
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
    
    func initialize() async throws {
        try loadModel()
        unloadModel()
    }
    private func loadModel() throws {
        let modelPath = AppPreferences.shared.selectedWhisperModelPath ?? AppPreferences.shared.selectedModelPath
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
    }
    private func unloadModel(){
        context = nil
    }
    
    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        try loadModel()
        defer { unloadModel() }

        guard let context = context else {
            throw TranscriptionError.contextInitializationFailed
        }
        
        abortFlag.isSet = false
        
        // Setup progress context for callback
        progressContext = ProgressContext()
        progressContext?.onProgress = onProgressUpdate
        
        defer {
            progressContext = nil
        }
        
        // Notify conversion start (0-10% is conversion phase)
        onProgressUpdate?(0.05)
        
        guard let converted = try await convertAudioToPCM(fileURL: url) else {
            throw TranscriptionError.audioConversionFailed
        }
        
        // Conversion done, now processing
        onProgressUpdate?(0.10)
        
        try Task.checkCancellation()
        
        // VAD gate: whisper never sees non-speech audio, so silence cannot
        // produce hallucinated text and long pauses are not decoded at all.
        // (whisper_full_with_state has no built-in VAD path — params.vad works
        // only through whisper_full, which would share decoding state.)
        let speechSegments = try detectSpeech(in: converted)
        if speechSegments.isEmpty {
            return ""
        }
        // Timestamps of the trimmed audio would not match the original file,
        // so trimming is applied only when timestamps are not requested.
        let samples = settings.showTimestamps
            ? converted
            : Self.speechOnlySamples(from: converted, segments: speechSegments)
        
        let nThreads = max(2, min(ProcessInfo.processInfo.activeProcessorCount, 8))
        
        var params = WhisperFullParams()
        params.strategy = settings.useBeamSearch ? .beamSearch : .greedy
        params.nThreads = Int32(nThreads)
        // Match whisper.cpp defaults: on temperature fallback the decoder samples
        // best_of candidates and keeps the most probable one; with 1 the fallback
        // degenerates to a single random sample on hard audio.
        params.greedyBestOf = 5
        // Each transcription runs on a fresh whisper_state (see below), so text
        // context flows between 30s windows within one recording (better
        // coherence, upstream default) but can never leak into the next one.
        params.noContext = false
        params.noTimestamps = !settings.showTimestamps
        params.suppressBlank = settings.suppressBlankAudio
        let isAutoDetect = settings.selectedLanguage == "auto"
        params.language = isAutoDetect ? nil : settings.selectedLanguage
        params.detectLanguage = false // means that it only detects the language and does not process the transcription
        params.temperature = Float(settings.temperature)
        params.noSpeechThold = Float(settings.noSpeechThreshold)
        params.initialPrompt = settings.initialPrompt.isEmpty ? nil : settings.initialPrompt
        // With noContext = false the initial prompt conditions only the first
        // 30s window; carrying it keeps the user's vocabulary effective for the
        // whole recording.
        params.carryInitialPrompt = params.initialPrompt != nil
        
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
        guard context.initState() else {
            throw TranscriptionError.contextInitializationFailed
        }
        defer {
            context.freeState()
        }
        
        guard context.full(samples: samples, params: &cParams) else {
            throw TranscriptionError.processingFailed
        }
        
        try Task.checkCancellation()
        
        var text = ""
        let nSegments = context.fullNSegments
        
        for i in 0..<nSegments {
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
        
        var processedText = cleanedText
        if settings.shouldApplyAsianAutocorrect && !cleanedText.isEmpty {
            processedText = AutocorrectWrapper.format(cleanedText)
        }
        
        return processedText
    }
    
    func cancelTranscription() {
        abortFlag.isSet = true
    }
    
    // MARK: - VAD
    
    private func detectSpeech(in samples: [Float]) throws -> [WhisperVadSegment] {
        if vadContext == nil {
            guard let path = Self.vadModelPath,
                  let vad = MyWhisperVadContext(modelPath: path) else {
                throw TranscriptionError.contextInitializationFailed
            }
            vadContext = vad
        }
        guard let segments = vadContext?.speechSegments(in: samples) else {
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

    nonisolated func convertAudioToPCM(fileURL: URL) async throws -> [Float]? {
        return try await Task.detached(priority: .userInitiated) {
            let (resolvedURL, isTempFile) = try self.resolveFileURL(fileURL)
            defer {
                if isTempFile { try? FileManager.default.removeItem(at: resolvedURL) }
            }
            let audioFile = try AVAudioFile(forReading: resolvedURL)
            let sourceFormat = audioFile.processingFormat
            let totalFrames = audioFile.length
            
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
                    inputChunkSize: 1_048_576
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
                        inputChunkSize: 262_144
                    )
                    
                    resultLock.lock()
                    segmentResults[workerIndex] = segment
                    resultLock.unlock()
                }
            }
            
            group.wait()
            
            guard !segmentResults.contains(where: { $0 == nil }) else { return nil }
            
            // Release each segment right after it is appended, so the peak stays
            // near 1x of the total instead of holding both copies until the end.
            var result = [Float]()
            result.reserveCapacity(segmentResults.reduce(0) { $0 + ($1?.count ?? 0) })
            for index in segmentResults.indices {
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
        inputChunkSize: AVAudioFrameCount
    ) throws -> [Float] {
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

