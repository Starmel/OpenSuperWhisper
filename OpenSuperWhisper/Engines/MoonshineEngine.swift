import Foundation
import AVFoundation
import CoreAudioTypes
import MoonshineVoice

class MoonshineEngine: TranscriptionEngine {
    var engineName: String { "Moonshine" }
    
    private var transcriber: Transcriber?
    private let stateLock = NSLock()
    private var _isCancelled = false
    
    var onProgressUpdate: ((Float) -> Void)?
    
    var isModelLoaded: Bool {
        transcriber != nil
    }
    
    private var isCancelled: Bool {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _isCancelled
        }
        set {
            stateLock.lock()
            defer { stateLock.unlock() }
            _isCancelled = newValue
        }
    }
    
    func initialize() async throws {
        guard let modelPath = AppPreferences.shared.selectedMoonshineModelPath else {
            throw TranscriptionError.contextInitializationFailed
        }
        
        let archRaw = UInt32(AppPreferences.shared.moonshineModelArch)
        let arch = ModelArch(rawValue: archRaw) ?? .base
        
        transcriber = try Transcriber(modelPath: modelPath, modelArch: arch)
        
        guard transcriber != nil else {
            throw TranscriptionError.contextInitializationFailed
        }
    }
    
    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        guard let transcriber = transcriber else {
            throw TranscriptionError.contextInitializationFailed
        }
        
        isCancelled = false
        
        onProgressUpdate?(0.05)
        
        guard let samples = try await convertAudioToPCM(fileURL: url) else {
            throw TranscriptionError.audioConversionFailed
        }
        
        onProgressUpdate?(0.10)
        
        try Task.checkCancellation()
        guard !isCancelled else { throw CancellationError() }
        
        onProgressUpdate?(0.30)
        
        let transcript = try transcriber.transcribeWithoutStreaming(
            audioData: samples,
            sampleRate: 16000,
            flags: 0
        )
        
        try Task.checkCancellation()
        guard !isCancelled else { throw CancellationError() }
        
        onProgressUpdate?(0.90)
        
        let text = transcript.lines
            .map { $0.text }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        var processedText = text
        if settings.shouldApplyAsianAutocorrect && !text.isEmpty {
            processedText = AutocorrectWrapper.format(text)
        }
        
        onProgressUpdate?(1.0)
        
        return processedText.isEmpty ? "No speech detected in the audio" : processedText
    }
    
    func cancelTranscription() {
        isCancelled = true
    }
    
    func getSupportedLanguages() -> [String] {
        return ["en", "ar", "es", "ja", "ko", "vi", "uk", "zh"]
    }
    
    // MARK: - Audio Conversion (same approach as WhisperEngine)
    
    nonisolated func convertAudioToPCM(fileURL: URL) async throws -> [Float]? {
        return try await Task.detached(priority: .userInitiated) {
            let audioFile = try AVAudioFile(forReading: fileURL)
            let sourceFormat = audioFile.processingFormat
            let totalFrames = audioFile.length
            
            guard let targetFormat = self.makeTargetFormat(channelCount: sourceFormat.channelCount) else {
                return nil
            }
            
            let sourceRate = sourceFormat.sampleRate
            let targetRate = targetFormat.sampleRate
            let ratio = targetRate / sourceRate
            
            guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
                return nil
            }
            converter.sampleRateConverterQuality = AVAudioQuality.medium.rawValue
            
            let outputFrameCount = AVAudioFrameCount(Double(totalFrames) * ratio) + 1024
            let inputChunkSize: AVAudioFrameCount = 1048576
            
            guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: inputChunkSize) else {
                return nil
            }
            
            var result = [Float]()
            result.reserveCapacity(Int(outputFrameCount))
            
            let outputChunkSize = AVAudioFrameCount(Double(inputChunkSize) * ratio) + 256
            guard let chunkOutputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputChunkSize) else {
                return nil
            }
            
            while audioFile.framePosition < totalFrames {
                inputBuffer.frameLength = 0
                try audioFile.read(into: inputBuffer, frameCount: inputChunkSize)
                
                if inputBuffer.frameLength == 0 { break }
                
                var inputConsumed = false
                var error: NSError?
                
                let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
                    if inputConsumed {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    inputConsumed = true
                    outStatus.pointee = .haveData
                    return inputBuffer
                }
                
                chunkOutputBuffer.frameLength = 0
                converter.convert(to: chunkOutputBuffer, error: &error, withInputFrom: inputBlock)
                
                if let error = error {
                    print("Conversion error: \(error)")
                    break
                }
                
                self.appendMixedSamples(from: chunkOutputBuffer, to: &result)
            }
            
            return result.isEmpty ? nil : result
        }.value
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
        
        let normalization = 1.0 / Float(channelCount)
        output.reserveCapacity(output.count + frameCount)
        
        for frame in 0..<frameCount {
            var mixed: Float = 0
            for channel in 0..<channelCount {
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
