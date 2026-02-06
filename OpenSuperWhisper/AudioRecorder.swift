import AVFoundation
import Foundation
import SwiftUI
import AppKit
import CoreAudio

class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var isPlaying = false
    @Published var currentlyPlayingURL: URL?
    @Published var canRecord = false
    
    private var captureSession: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var audioFile: AVAudioFile?
    private var audioConverter: AVAudioConverter?
    private let captureQueue = DispatchQueue(label: "com.opensuperwhisper.audiocapture")
    
    // Auto-detect which input channel has the microphone signal
    private var activeInputChannel: Int = 0
    private var channelDetected: Bool = false
    
    private var audioPlayer: AVAudioPlayer?
    private var notificationSound: NSSound?
    private let temporaryDirectory: URL
    private var currentRecordingURL: URL?
    private var notificationObserver: Any?
    private var microphoneChangeObserver: Any?

    // MARK: - Singleton Instance

    static let shared = AudioRecorder()
    
    override private init() {
        let tempDir = FileManager.default.temporaryDirectory
        temporaryDirectory = tempDir.appendingPathComponent("temp_recordings")
        
        super.init()
        createTemporaryDirectoryIfNeeded()
        setup()
    }
    
    deinit {
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = microphoneChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    private func setup() {
        updateCanRecordStatus()
        
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasConnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateCanRecordStatus()
        }
        
        NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateCanRecordStatus()
        }
        
        microphoneChangeObserver = NotificationCenter.default.addObserver(
            forName: .microphoneDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updateCanRecordStatus()
        }
    }
    
    private func updateCanRecordStatus() {
        canRecord = MicrophoneService.shared.getActiveMicrophone() != nil
    }
    
    private func createTemporaryDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        } catch {
            print("Failed to create temporary recordings directory: \(error)")
        }
    }
    
    private func playNotificationSound() {
        // Try to play using NSSound first
        guard let soundURL = Bundle.main.url(forResource: "notification", withExtension: "mp3") else {
            print("Failed to find notification sound file")
            // Fall back to system sound if notification.mp3 is not found
            NSSound.beep()
            return
        }
        
        if let sound = NSSound(contentsOf: soundURL, byReference: false) {
            // Set maximum volume to ensure it's audible
            sound.volume = 0.3
            sound.play()
            notificationSound = sound
        } else {
            print("Failed to create NSSound from URL, falling back to system beep")
            // Fall back to system beep if NSSound creation fails
            NSSound.beep()
        }
    }
    
    func startRecording() {
        guard canRecord else {
            print("Cannot start recording - no audio input available")
            return
        }
        
        if isRecording {
            print("stop recording while recording")
            _ = stopRecording()
        }
        
        if AppPreferences.shared.playSoundOnRecordStart {
            playNotificationSound()
        }
        
        let timestamp = Int(Date().timeIntervalSince1970)
        let filename = "\(timestamp).wav"
        let fileURL = temporaryDirectory.appendingPathComponent(filename)
        currentRecordingURL = fileURL
        
        print("start record file to \(fileURL)")
        
        let activeMic = MicrophoneService.shared.getActiveMicrophone()
        startRecordingWithCaptureSession(fileURL: fileURL, device: activeMic)
    }
    
    private func startRecordingWithCaptureSession(fileURL: URL, device: MicrophoneService.AudioDevice?) {
        // Reset channel detection for each new recording
        activeInputChannel = 0
        channelDetected = false
        
        // Get the AVCaptureDevice for the selected microphone
        let captureDevice: AVCaptureDevice?
        if let device = device {
            captureDevice = AVCaptureDevice(uniqueID: device.id)
        } else {
            captureDevice = AVCaptureDevice.default(for: .audio)
        }
        
        guard let captureDevice = captureDevice else {
            print("Failed to get capture device")
            currentRecordingURL = nil
            return
        }
        
        // Create the capture session
        let session = AVCaptureSession()
        
        do {
            let input = try AVCaptureDeviceInput(device: captureDevice)
            if session.canAddInput(input) {
                session.addInput(input)
            } else {
                print("Cannot add input to capture session")
                currentRecordingURL = nil
                return
            }
        } catch {
            print("Failed to create capture device input: \(error)")
            currentRecordingURL = nil
            return
        }
        
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: captureQueue)
        
        if session.canAddOutput(output) {
            session.addOutput(output)
        } else {
            print("Cannot add output to capture session")
            currentRecordingURL = nil
            return
        }
        
        // Target format: 16kHz, mono, 16-bit integer PCM (what Whisper expects)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        
        do {
            let file = try AVAudioFile(forWriting: fileURL, settings: outputSettings)
            self.audioFile = file
        } catch {
            print("Failed to create audio file: \(error)")
            currentRecordingURL = nil
            return
        }
        
        self.captureSession = session
        self.audioOutput = output
        
        session.startRunning()
        isRecording = true
        
        print("Recording started successfully with AVCaptureSession")
    }
    
    private func stopCaptureSession() {
        captureSession?.stopRunning()
        captureSession = nil
        audioOutput = nil
        audioFile = nil
        audioConverter = nil
    }
    
    func stopRecording() -> URL? {
        stopCaptureSession()
        isRecording = false
        
        if let url = currentRecordingURL,
           let duration = try? AVAudioPlayer(contentsOf: url).duration,
           duration < 1.0
        {
            try? FileManager.default.removeItem(at: url)
            currentRecordingURL = nil
            return nil
        }
        
        let url = currentRecordingURL
        currentRecordingURL = nil
        return url
    }
    
    func cancelRecording() {
        stopCaptureSession()
        isRecording = false
        
        if let url = currentRecordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        currentRecordingURL = nil
    }
    
    func moveTemporaryRecording(from tempURL: URL, to finalURL: URL) throws {

        let directory = finalURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        if FileManager.default.fileExists(atPath: finalURL.path) {
            try FileManager.default.removeItem(at: finalURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: finalURL)
    }
    
    func playRecording(url: URL) {
        // Stop current playback if any
        stopPlaying()
        
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.delegate = self
            audioPlayer?.play()
            isPlaying = true
            currentlyPlayingURL = url
        } catch {
            print("Failed to play recording: \(error), url: \(url)")
            isPlaying = false
            currentlyPlayingURL = nil
        }
    }
    
    func stopPlaying() {
        audioPlayer?.stop()
        audioPlayer = nil
        isPlaying = false
        currentlyPlayingURL = nil
    }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

extension AudioRecorder: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let file = self.audioFile else { return }
        
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return }
        
        let sampleRate = asbd.pointee.mSampleRate
        let channelCount = Int(asbd.pointee.mChannelsPerFrame)
        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        let isFloat = asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isInterleaved = asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        let bitsPerChannel = asbd.pointee.mBitsPerChannel
        let bytesPerFrame = Int(asbd.pointee.mBytesPerFrame)
        
        // Use AudioBufferList to properly access all channels (CMBlockBufferGetDataPointer
        // does not reliably return all channels for non-interleaved multi-channel audio)
        var ablSize: Int = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &ablSize,
            bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        
        let ablRaw = UnsafeMutableRawPointer.allocate(byteCount: ablSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { ablRaw.deallocate() }
        let ablPtr = ablRaw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var retainedBlockBuffer: CMBlockBuffer?
        let ablStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil,
            bufferListOut: ablPtr, bufferListSize: ablSize,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &retainedBlockBuffer)
        guard ablStatus == noErr else { return }
        
        let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
        
        // Auto-detect active input channel: scan all channels for the strongest signal.
        // This handles multi-channel audio interfaces (e.g. Focusrite Scarlett) where
        // the microphone may not be on channel 0.
        if !channelDetected && channelCount > 1 {
            if !isInterleaved && abl.count > 1 && isFloat && bitsPerChannel == 32 {
                // Non-interleaved Float32: each abl buffer is one channel
                var bestCh = 0
                var bestAmp: Float = 0
                for ch in 0..<abl.count {
                    guard let chData = abl[ch].mData else { continue }
                    let src = chData.bindMemory(to: Float.self, capacity: frameCount)
                    var maxA: Float = 0
                    for i in 0..<min(frameCount, Int(abl[ch].mDataByteSize) / 4) {
                        maxA = max(maxA, abs(src[i]))
                    }
                    if maxA > bestAmp { bestAmp = maxA; bestCh = ch }
                }
                if bestAmp > 0.001 {
                    activeInputChannel = bestCh
                    channelDetected = true
                }
            } else if isInterleaved && channelCount > 1 {
                // Interleaved: scan each channel within the single buffer
                guard let data = abl[0].mData else { return }
                let bytesPerSample = channelCount > 0 ? bytesPerFrame / channelCount : bytesPerFrame
                var bestCh = 0
                var bestAmp: Float = 0
                
                if isFloat && bytesPerSample == 4 {
                    let src = data.bindMemory(to: Float.self, capacity: frameCount * channelCount)
                    for ch in 0..<channelCount {
                        var maxA: Float = 0
                        for i in 0..<frameCount { maxA = max(maxA, abs(src[i * channelCount + ch])) }
                        if maxA > bestAmp { bestAmp = maxA; bestCh = ch }
                    }
                } else if !isFloat && bytesPerSample == 4 {
                    let src = data.bindMemory(to: Int32.self, capacity: frameCount * channelCount)
                    for ch in 0..<channelCount {
                        var maxA: Float = 0
                        for i in 0..<frameCount {
                            var val = src[i * channelCount + ch]
                            if bitsPerChannel <= 24 { val = (val << 8) >> 8 }
                            maxA = max(maxA, abs(Float(val)))
                        }
                        if maxA > bestAmp { bestAmp = maxA; bestCh = ch }
                    }
                }
                
                if bestAmp > (isFloat ? Float(0.001) : Float(100)) {
                    activeInputChannel = bestCh
                    channelDetected = true
                }
            }
        }
        
        // Output format: 16kHz mono Float32 for resampling
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else { return }
        
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else { return }
        
        let frameCapacity = AVAudioFrameCount(frameCount)
        guard let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frameCapacity) else { return }
        monoBuffer.frameLength = frameCapacity
        guard let dstData = monoBuffer.floatChannelData else { return }
        
        // Extract active channel audio data from AudioBufferList
        let ch = activeInputChannel
        
        if isInterleaved {
            // Interleaved: single buffer with all channels interleaved
            guard abl.count >= 1, let data = abl[0].mData else { return }
            let bytesPerSample = channelCount > 0 ? bytesPerFrame / channelCount : bytesPerFrame
            let chOffset = min(ch, channelCount - 1) // safe channel index
            
            if isFloat && bytesPerSample == 4 {
                let src = data.bindMemory(to: Float.self, capacity: frameCount * channelCount)
                for i in 0..<frameCount {
                    dstData[0][i] = src[i * channelCount + chOffset]
                }
            } else if !isFloat && bytesPerSample == 4 {
                // Int32 or 24-bit-in-32-bit container
                let src = data.bindMemory(to: Int32.self, capacity: frameCount * channelCount)
                if bitsPerChannel <= 24 {
                    for i in 0..<frameCount {
                        var val = src[i * channelCount + chOffset]
                        val = (val << 8) >> 8  // sign-extend from 24 bits
                        dstData[0][i] = Float(val) / Float(0x800000)
                    }
                } else {
                    for i in 0..<frameCount {
                        dstData[0][i] = Float(src[i * channelCount + chOffset]) / Float(Int32.max)
                    }
                }
            } else if !isFloat && bytesPerSample == 3 {
                // True 24-bit packed (3 bytes per sample)
                let src = data.assumingMemoryBound(to: UInt8.self)
                for i in 0..<frameCount {
                    let offset = i * bytesPerFrame + chOffset * bytesPerSample
                    let b0 = Int32(src[offset])
                    let b1 = Int32(src[offset + 1])
                    let b2 = Int32(src[offset + 2])
                    var sample = (b2 << 16) | (b1 << 8) | b0
                    if sample > 0x7FFFFF { sample -= 0x1000000 }
                    dstData[0][i] = Float(sample) / Float(0x800000)
                }
            } else if !isFloat && bytesPerSample == 2 {
                let src = data.bindMemory(to: Int16.self, capacity: frameCount * channelCount)
                for i in 0..<frameCount {
                    dstData[0][i] = Float(src[i * channelCount + chOffset]) / 32768.0
                }
            } else {
                return
            }
        } else {
            // Non-interleaved: each buffer in the AudioBufferList is one channel
            let bufIdx = min(ch, abl.count - 1) // safe buffer index
            guard abl.count >= 1, let data = abl[bufIdx].mData else { return }
            let bufSize = Int(abl[bufIdx].mDataByteSize)
            
            if isFloat && bitsPerChannel == 32 {
                let src = data.bindMemory(to: Float.self, capacity: bufSize / 4)
                let count = min(frameCount, bufSize / 4)
                for i in 0..<count {
                    dstData[0][i] = src[i]
                }
                // Zero-fill remainder if buffer is smaller than frameCount
                for i in count..<frameCount { dstData[0][i] = 0 }
            } else if !isFloat && bitsPerChannel == 32 {
                let src = data.bindMemory(to: Int32.self, capacity: bufSize / 4)
                let count = min(frameCount, bufSize / 4)
                for i in 0..<count {
                    dstData[0][i] = Float(src[i]) / Float(Int32.max)
                }
                for i in count..<frameCount { dstData[0][i] = 0 }
            } else if !isFloat && bitsPerChannel == 16 {
                let src = data.bindMemory(to: Int16.self, capacity: bufSize / 2)
                let count = min(frameCount, bufSize / 2)
                for i in 0..<count {
                    dstData[0][i] = Float(src[i]) / 32768.0
                }
                for i in count..<frameCount { dstData[0][i] = 0 }
            } else if !isFloat && bitsPerChannel == 24 {
                // 24-bit non-interleaved: bytesPerFrame = bytes per single sample
                let bytesPerSample = bytesPerFrame  // for non-interleaved, mBytesPerFrame = per-channel
                if bytesPerSample == 4 {
                    // 24-in-32 container
                    let src = data.bindMemory(to: Int32.self, capacity: bufSize / 4)
                    let count = min(frameCount, bufSize / 4)
                    for i in 0..<count {
                        var val = src[i]
                        val = (val << 8) >> 8
                        dstData[0][i] = Float(val) / Float(0x800000)
                    }
                    for i in count..<frameCount { dstData[0][i] = 0 }
                } else if bytesPerSample == 3 {
                    let src = data.assumingMemoryBound(to: UInt8.self)
                    let count = min(frameCount, bufSize / 3)
                    for i in 0..<count {
                        let offset = i * 3
                        let b0 = Int32(src[offset])
                        let b1 = Int32(src[offset + 1])
                        let b2 = Int32(src[offset + 2])
                        var sample = (b2 << 16) | (b1 << 8) | b0
                        if sample > 0x7FFFFF { sample -= 0x1000000 }
                        dstData[0][i] = Float(sample) / Float(0x800000)
                    }
                    for i in count..<frameCount { dstData[0][i] = 0 }
                } else {
                    return
                }
            } else {
                return
            }
        }
        
        // Resample mono buffer from native rate to 16kHz
        if sampleRate != 16000 {
            if self.audioConverter == nil || self.audioConverter?.inputFormat.sampleRate != sampleRate || self.audioConverter?.inputFormat.channelCount != 1 {
                self.audioConverter = AVAudioConverter(from: monoFormat, to: outputFormat)
            }
            guard let converter = self.audioConverter else { return }
            
            let ratio = 16000.0 / sampleRate
            let outCap = AVAudioFrameCount(Double(monoBuffer.frameLength) * ratio) + 1
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outCap) else { return }
            
            var error: NSError?
            var hasData = true
            converter.convert(to: outBuf, error: &error) { _, outStatus in
                if hasData {
                    hasData = false
                    outStatus.pointee = .haveData
                    return monoBuffer
                } else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
            }
            
            if let error = error { print("Resample error: \(error)"); return }
            
            if outBuf.frameLength > 0 {
                do { try file.write(from: outBuf) } catch { print("Write error: \(error)") }
            }
        } else {
            // Already 16kHz
            if monoBuffer.frameLength > 0 {
                do { try file.write(from: monoBuffer) } catch { print("Write error: \(error)") }
            }
        }
    }
}

extension AudioRecorder: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        currentlyPlayingURL = nil
    }
}
