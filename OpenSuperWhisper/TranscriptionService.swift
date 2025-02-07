import AVFoundation
import Foundation

class TranscriptionService: ObservableObject {
    static let shared = TranscriptionService()
    
    @Published private(set) var isTranscribing = false
    @Published private(set) var transcribedText = ""
    @Published private(set) var currentSegment = ""
    @Published private(set) var isLoading = false
    
    private var context: MyWhisperContext?
    private var realTimeTranscriptionTask: Task<Void, Never>?
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private let sampleRate: Double = 16000
    private var audioBuffer: [Float] = []
    private let bufferSize = 4096
    private var audioBufferLock = NSLock()
    private var isProcessing = false
    private var settings: Settings?
    
    init() {
        loadModel()
        setupAudioEngine()
    }
    
    private func loadModel() {
        if let modelPath = UserDefaults.standard.string(forKey: "selectedModelPath") {
            isLoading = true
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let params = WhisperContextParams()
                self?.context = MyWhisperContext.initFromFile(path: modelPath, params: params)
                DispatchQueue.main.async {
                    self?.isLoading = false
                }
            }
        }
    }
    
    func reloadModel(with path: String) {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let params = WhisperContextParams()
            self?.context = MyWhisperContext.initFromFile(path: path, params: params)
            DispatchQueue.main.async {
                self?.isLoading = false
            }
        }
    }
    
    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        inputNode = audioEngine?.inputNode
        
        guard let inputNode = inputNode else { return }
        
        // Get the native format of the input node
        let inputFormat = inputNode.inputFormat(forBus: 0)
        
        // Create an audio converter format for our desired output
        let converterFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                            sampleRate: sampleRate,
                                            channels: 1,
                                            interleaved: false)!
        
        // Install tap on the input node with its native format
        inputNode.installTap(onBus: 0, bufferSize: UInt32(bufferSize), format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            
            // Convert the buffer to the desired format
            let frameCount = AVAudioFrameCount(buffer.frameLength)
            guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: converterFormat,
                                                         frameCapacity: frameCount) else { return }
            
            let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            
            var error: NSError?
            guard let converter = AVAudioConverter(from: inputFormat, to: converterFormat) else { return }
            
            converter.convert(to: convertedBuffer,
                              error: &error,
                              withInputFrom: inputBlock)
            
            if let error = error {
                print("Conversion error: \(error)")
                return
            }
            
            // Get the channel data as float array
            guard let channelData = convertedBuffer.floatChannelData?[0] else { return }
            let frames = Array(UnsafeBufferPointer(start: channelData,
                                                   count: Int(convertedBuffer.frameLength)))
            
            self.audioBuffer.append(contentsOf: frames)
            
            // Process buffer when it reaches a certain size
            if self.audioBuffer.count >= Int(self.sampleRate * 3) { // Process every 3 seconds
                self.processAudioBuffer()
            }
        }
    }
    
    private func processAudioBuffer() {
        guard let context = context,
              let settings = settings,
              !isProcessing else { return }
        
        audioBufferLock.lock()
        defer { audioBufferLock.unlock() }
        
        // Check if we have enough samples
        guard audioBuffer.count >= Int(sampleRate * 3) else { return }
        
        isProcessing = true
        
        // Create a local copy of the samples we want to process
        let samples = Array(audioBuffer.prefix(Int(sampleRate * 3)))
        audioBuffer.removeFirst(min(samples.count, audioBuffer.count))
        
        Task {
            defer { isProcessing = false }
            
            // Process the audio with Whisper
            let nThreads = 4
            
            // Create a contiguous array of samples
            let sampleCount = samples.count
            let samplePtr = UnsafeMutablePointer<Float>.allocate(capacity: sampleCount)
            defer { samplePtr.deallocate() }
            
            // Copy samples to the contiguous memory
            samples.withUnsafeBufferPointer { buffer in
                samplePtr.initialize(from: buffer.baseAddress!, count: sampleCount)
            }
            
            // Process with error handling
            guard context.pcmToMel(samples: Array(UnsafeBufferPointer(start: samplePtr, count: sampleCount)),
                                   nSamples: sampleCount,
                                   nThreads: nThreads)
            else {
                print("Failed to convert PCM to MEL")
                return
            }
            
            guard context.encode(offset: 0, nThreads: nThreads) else {
                print("Failed to encode audio")
                return
            }
            
            var params = WhisperFullParams()
            // Use the same parameters as in file transcription
            params.strategy = settings.viewModel.useBeamSearch ? .beamSearch : .greedy
            params.nThreads = Int32(nThreads)
            params.noTimestamps = !settings.viewModel.showTimestamps
            params.suppressBlank = settings.viewModel.suppressBlankAudio
            params.translate = settings.viewModel.translateToEnglish
            params.language = settings.viewModel.selectedLanguage != "auto" ? settings.viewModel.selectedLanguage : nil
            params.detectLanguage = settings.viewModel.selectedLanguage == "auto"
            params.temperature = Float(settings.viewModel.temperature)
            params.noSpeechThold = Float(settings.viewModel.noSpeechThreshold)
            params.initialPrompt = settings.viewModel.initialPrompt.isEmpty ? nil : settings.viewModel.initialPrompt
            
            if settings.viewModel.useBeamSearch {
                params.beamSearchBeamSize = Int32(settings.viewModel.beamSize)
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
            
            if !context.full(samples: Array(UnsafeBufferPointer(start: samplePtr, count: sampleCount)),
                             params: &params)
            {
                print("Failed to process audio segment")
            }
        }
    }
    
    func startRealTimeTranscription(settings: Settings) {
        self.settings = settings
        guard let audioEngine = audioEngine else { return }
        
        do {
            try audioEngine.start()
            isTranscribing = true
            currentSegment = ""
            transcribedText = ""
        } catch {
            print("Failed to start audio engine: \(error)")
        }
    }
    
    func stopTranscribing() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        setupAudioEngine()
        isTranscribing = false
        currentSegment = ""
        audioBuffer.removeAll()
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
        params.strategy = settings.viewModel.useBeamSearch ? .beamSearch : .greedy
        params.nThreads = Int32(nThreads)
        params.noTimestamps = !settings.viewModel.showTimestamps
        params.suppressBlank = settings.viewModel.suppressBlankAudio
        params.translate = settings.viewModel.translateToEnglish
        params.language = settings.viewModel.selectedLanguage != "auto" ? settings.viewModel.selectedLanguage : nil
        params.detectLanguage = settings.viewModel.selectedLanguage == "auto"
        
        // Set advanced parameters from settings
        params.temperature = Float(settings.viewModel.temperature)
        params.noSpeechThold = Float(settings.viewModel.noSpeechThreshold)
        params.initialPrompt = settings.viewModel.initialPrompt.isEmpty ? nil : settings.viewModel.initialPrompt
        
        print("params \(params)")
        
        if settings.viewModel.useBeamSearch {
            params.beamSearchBeamSize = Int32(settings.viewModel.beamSize)
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
            
            if settings.viewModel.showTimestamps {
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
        guard let modelPath = UserDefaults.standard.string(forKey: "selectedModelPath") else {
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
}
