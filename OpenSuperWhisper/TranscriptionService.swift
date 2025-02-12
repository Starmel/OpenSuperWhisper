import AVFoundation
import Foundation

@MainActor
class TranscriptionService: ObservableObject {
    static let shared = TranscriptionService()
    
    @Published private(set) var isTranscribing = false
    @Published private(set) var transcribedText = ""
    @Published private(set) var currentSegment = ""
    @Published private(set) var isLoading = false
    
    private var context: MyWhisperContext?
    
    init() {
        loadModel()
    }
    
    private func loadModel() {
        print("Loading model")
        if let modelPath = AppPreferences.shared.selectedModelPath {
            isLoading = true
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let params = WhisperContextParams()
                self?.context = MyWhisperContext.initFromFile(path: modelPath, params: params)
                DispatchQueue.main.async {
                    self?.isLoading = false
                    print("Model loaded")
                }
            }
        }
    }
    
    func reloadModel(with path: String) {
        print("Reloading model")
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let params = WhisperContextParams()
            self?.context = MyWhisperContext.initFromFile(path: path, params: params)
            DispatchQueue.main.async {
                self?.isLoading = false
                print("Model reloaded")
            }
        }
    }
    
    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        guard let context = context ?? createContext() else {
            throw TranscriptionError.contextInitializationFailed
        }
        
        DispatchQueue.main.async {
            self.isTranscribing = true
            self.transcribedText = ""
            self.currentSegment = ""
        }
        
        defer {
            DispatchQueue.main.async {
                self.isTranscribing = false
                self.currentSegment = ""
            }
        }
        
        // Convert audio file to PCM samples
        guard let samples = try convertAudioToPCM(fileURL: url) else {
            throw TranscriptionError.audioConversionFailed
        }
        
        // Process the audio with Whisper
        let nThreads = 4 // Use 4 threads for processing
        
        // Convert samples to mel spectrogram
        guard context.pcmToMel(samples: samples, nSamples: samples.count, nThreads: nThreads) else {
            throw TranscriptionError.processingFailed
        }
        
        // Encode the audio
        guard context.encode(offset: 0, nThreads: nThreads) else {
            throw TranscriptionError.processingFailed
        }
        
        // Set up decoding parameters
        var params = WhisperFullParams()

        print("settings.translateToEnglish \(settings.translateToEnglish)")

        params.strategy = settings.useBeamSearch ? .beamSearch : .greedy
        params.nThreads = Int32(nThreads)
        params.noTimestamps = !settings.showTimestamps
        params.suppressBlank = settings.suppressBlankAudio
        params.translate = settings.translateToEnglish
        params.language = settings.selectedLanguage != "auto" ? settings.selectedLanguage : nil
        params.detectLanguage = settings.selectedLanguage == "auto"
        
        // Set advanced parameters from settings
        params.temperature = Float(settings.temperature)
        params.noSpeechThold = Float(settings.noSpeechThreshold)
        params.initialPrompt = settings.initialPrompt.isEmpty ? nil : settings.initialPrompt
        
        print("params \(params)")
        
        if settings.useBeamSearch {
            params.beamSearchBeamSize = Int32(settings.beamSize)
        }
        
        // Enable real-time output
        params.printRealtime = true
        params.print_realtime = true
        let callback: @convention(c) (OpaquePointer?, OpaquePointer?, Int32, UnsafeMutableRawPointer?) -> Void = { ctx, state, n_new, user_data in
            guard let ctx = ctx,
                  let userData = user_data,
                  let service = Unmanaged<TranscriptionService>.fromOpaque(userData).takeUnretainedValue() as TranscriptionService?
            else { return }
            service.handleNewSegment(context: ctx, state: state, nNew: Int(n_new))
        }
        params.newSegmentCallback = callback
        params.newSegmentCallbackUserData = Unmanaged.passUnretained(self).toOpaque()
        
        // Process the audio
        guard context.full(samples: samples, params: &params) else {
            throw TranscriptionError.processingFailed
        }
        
        // Get the transcribed text
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
        
        DispatchQueue.main.async {
            self.transcribedText = finalText
        }
        
        return finalText
    }
    
    private func handleNewSegment(context: OpaquePointer, state: OpaquePointer?, nNew: Int) {
        let nSegments = Int(whisper_full_n_segments(context))
        let startIdx = max(0, nSegments - nNew)
        
        var newText = ""
        for i in startIdx..<nSegments {
            guard let cString = whisper_full_get_segment_text(context, Int32(i)) else { continue }
            let segmentText = String(cString: cString)
            newText += segmentText + " "
        }
        
        let cleanedText = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        DispatchQueue.main.async { [weak self] in
            if !cleanedText.isEmpty {
                self?.currentSegment = cleanedText
                self?.transcribedText += cleanedText + "\n"
            }
        }
    }
    
    private func createContext() -> MyWhisperContext? {
        guard let modelPath = AppPreferences.shared.selectedModelPath else {
            return nil
        }
        
        let params = WhisperContextParams()
        context = MyWhisperContext.initFromFile(path: modelPath, params: params)
        return context
    }
    
    private func convertAudioToPCM(fileURL: URL) throws -> [Float]? {
        let audioFile = try AVAudioFile(forReading: fileURL)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 16000,
                                   channels: 1,
                                   interleaved: false)!
        
        // Create audio engine and nodes
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let converter = AVAudioConverter(from: audioFile.processingFormat, to: format)!
        
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: audioFile.processingFormat)
        
        // Calculate buffer size and prepare buffers
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
        
        // Convert to array of floats
        guard let channelData = buffer.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: channelData[0],
                                         count: Int(buffer.frameLength)))
    }
}

enum TranscriptionError: Error {
    case contextInitializationFailed
    case audioConversionFailed
    case processingFailed
    case languageAllocationFailed
    case modelNotFound
}
