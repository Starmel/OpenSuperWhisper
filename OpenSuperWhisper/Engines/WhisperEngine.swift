import Foundation
import AVFoundation

class WhisperEngine: TranscriptionEngine {
    var engineName: String { "Whisper" }
    
    private var context: MyWhisperContext?
    private var isCancelled = false
    private var abortFlag: UnsafeMutablePointer<Bool>?
    
    var isModelLoaded: Bool {
        context != nil
    }
    
    func initialize() async throws {
        let modelPath = AppPreferences.shared.selectedWhisperModelPath ?? AppPreferences.shared.selectedModelPath
        guard let modelPath = modelPath else {
            throw TranscriptionError.contextInitializationFailed
        }
        
        let params = WhisperContextParams()
        context = MyWhisperContext.initFromFile(path: modelPath, params: params)
        
        guard context != nil else {
            throw TranscriptionError.contextInitializationFailed
        }
    }
    
    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        guard let context = context else {
            throw TranscriptionError.contextInitializationFailed
        }
        
        isCancelled = false
        
        if abortFlag != nil {
            abortFlag?.deallocate()
        }
        abortFlag = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
        abortFlag?.initialize(to: false)
        
        defer {
            abortFlag?.deallocate()
            abortFlag = nil
        }
        
        guard let samples = try await convertAudioToPCM(fileURL: url) else {
            throw TranscriptionError.audioConversionFailed
        }
        
        try Task.checkCancellation()
        
        let nThreads = 4
        
        guard context.pcmToMel(samples: samples, nSamples: samples.count, nThreads: nThreads) else {
            throw TranscriptionError.processingFailed
        }
        
        try Task.checkCancellation()
        
        guard context.encode(offset: 0, nThreads: nThreads) else {
            throw TranscriptionError.processingFailed
        }
        
        try Task.checkCancellation()
        
        var params = WhisperFullParams()
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
        
        var cParams = params.toC()
        cParams.abort_callback = abortCallback
        
        if let abortFlag = abortFlag {
            cParams.abort_callback_user_data = UnsafeMutableRawPointer(abortFlag)
        }
        
        try Task.checkCancellation()
        
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
        if ["zh", "ja", "ko"].contains(settings.selectedLanguage) && settings.useAsianAutocorrect && !cleanedText.isEmpty {
            processedText = AutocorrectWrapper.format(cleanedText)
        }
        
        return processedText.isEmpty ? "No speech detected in the audio" : processedText
    }
    
    func cancelTranscription() {
        isCancelled = true
        if let abortFlag = abortFlag {
            abortFlag.pointee = true
        }
    }
    
    func getSupportedLanguages() -> [String] {
        return LanguageUtil.availableLanguages
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

