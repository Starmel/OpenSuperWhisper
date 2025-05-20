import AVFoundation
import Foundation
import SwiftUI
import AppKit

class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var isPlaying = false
    @Published var currentlyPlayingURL: URL?
    @Published var canRecord = false
    
    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    private var notificationSound: NSSound?
    private let temporaryDirectory: URL
    private var currentRecordingURL: URL?
    private var notificationObserver: Any?

    // For Live Recording
    private let audioEngine = AVAudioEngine()
    private var inputNode: AVAudioInputNode?
    private var audioConverter: AVAudioConverter?
    private let desiredFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private var liveModeActive = false
    private var conversionBuffer: AVAudioPCMBuffer?


    // MARK: - Singleton Instance

    static let shared = AudioRecorder()
    
    override private init() {
        let tempDir = FileManager.default.temporaryDirectory
        temporaryDirectory = tempDir.appendingPathComponent("temp_recordings")
        
        super.init()
        createTemporaryDirectoryIfNeeded()
        setup()
        setupAudioEngine()
    }
    
    private func setupAudioEngine() {
        inputNode = audioEngine.inputNode
        // Prepare the engine. This can throw, but we'll handle errors during start.
        audioEngine.prepare()
    }
    
    deinit {
        if let observer = notificationObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    private func setup() {
        // Check for audio input devices
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        canRecord = !discoverySession.devices.isEmpty
        
        // Add observer for device connection/disconnection
        notificationObserver = NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasConnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let session = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone, .external],
                mediaType: .audio,
                position: .unspecified
            )
            self?.canRecord = !session.devices.isEmpty
        }
        
        NotificationCenter.default.addObserver(
            forName: .AVCaptureDeviceWasDisconnected,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let session = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.microphone, .external],
                mediaType: .audio,
                position: .unspecified
            )
            self?.canRecord = !session.devices.isEmpty
        }
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
        
        print("Found notification sound at: \(soundURL)")
        
        if let sound = NSSound(contentsOf: soundURL, byReference: false) {
            // Set maximum volume to ensure it's audible
            sound.volume = 0.3
            sound.play()
            notificationSound = sound
            print("Notification sound playing with NSSound...")
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
            print("Already recording. Stopping current recording before starting a new one.")
            _ = stopRecording() // Stop previous one, ignore URL
        }

        liveModeActive = AppPreferences.shared.liveTextInsertion

        if AppPreferences.shared.playSoundOnRecordStart {
            playNotificationSound()
        }

        if liveModeActive {
            startLiveRecording()
        } else {
            startFileRecording()
        }
    }

    private func startFileRecording() {
        let timestamp = Int(Date().timeIntervalSince1970)
        let filename = "\(timestamp).wav"
        let fileURL = temporaryDirectory.appendingPathComponent(filename)
        currentRecordingURL = fileURL
        
        print("Starting file recording to \(fileURL)")
        
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0, // Whisper expects 16kHz
            AVNumberOfChannelsKey: 1,    // Mono
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVLinearPCMBitDepthKey: 16,  // 16-bit PCM
            AVLinearPCMIsFloatKey: false // Ensure it's not float if Whisper needs int16
        ]
        
        do {
            audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.record()
            isRecording = true
        } catch {
            print("Failed to start file recording: \(error)")
            currentRecordingURL = nil
            isRecording = false // Ensure this is false on failure
        }
    }

    private func startLiveRecording() {
        guard let inputNode = inputNode else {
            print("Input node not available for live recording.")
            isRecording = false
            return
        }

        let inputFormat = inputNode.outputFormat(forBus: 0)
        print("Input node format: \(inputFormat)")
        print("Desired format: \(desiredFormat)")

        // Only create converter if formats are different
        if inputFormat.sampleRate != desiredFormat.sampleRate || inputFormat.channelCount != desiredFormat.channelCount || inputFormat.commonFormat != desiredFormat.commonFormat {
            audioConverter = AVAudioConverter(from: inputFormat, to: desiredFormat)
            if audioConverter == nil {
                print("Failed to create audio converter. Check formats.")
                isRecording = false
                return
            }
            print("Audio converter created from \(inputFormat) to \(desiredFormat)")
        } else {
            audioConverter = nil // Ensure it's nil if not needed
            print("Input format matches desired format. No conversion needed.")
        }
        
        // Prepare a buffer for conversion output if converter is used
        if audioConverter != nil {
             // Buffer size can be adjusted. 4096 is a common size.
            let frameCapacity = AVAudioFrameCount(desiredFormat.sampleRate * 0.25) // e.g., 250ms of audio
            conversionBuffer = AVAudioPCMBuffer(pcmFormat: desiredFormat, frameCapacity: frameCapacity)
        }


        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] (buffer, time) in
            guard let self = self, self.isRecording else { return } // Ensure still recording

            var floatSamples: [Float]?

            if let converter = self.audioConverter, let conversionBuffer = self.conversionBuffer {
                var error: NSError?
                let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                    outStatus.pointee = .haveData
                    return buffer
                }
                
                conversionBuffer.frameLength = conversionBuffer.frameCapacity // Reset before conversion
                let status = converter.convert(to: conversionBuffer, error: &error, withInputFrom: inputBlock)

                if status == .error {
                    print("Error during audio conversion: \(error?.localizedDescription ?? "Unknown error")")
                    return
                }
                if status == .endOfStream || status == .inputRanDry, conversionBuffer.frameLength == 0 {
                    // No data converted in this pass or end of stream with no new data.
                    return
                }
                
                if let channelData = conversionBuffer.floatChannelData?[0] {
                    floatSamples = Array(UnsafeBufferPointer(start: channelData, count: Int(conversionBuffer.frameLength)))
                }
            } else {
                // No conversion needed, use original buffer directly.
                // Ensure it's in the desired Float32 format.
                // The desiredFormat is Float32, so if inputFormat matched, this buffer should be Float32.
                if let channelData = buffer.floatChannelData?[0] {
                     floatSamples = Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
                } else {
                    print("ERROR: No converter, but buffer is not Float32 or channel data is nil.")
                    return
                }
            }
            
            if let samples = floatSamples, !samples.isEmpty {
                // print("Sending \(samples.count) float samples to TranscriptionService.")
                TranscriptionService.shared.processAudioChunk(samples)
            }
        }
        
        // Start TranscriptionService for live mode
        let currentSettings = Settings() // This will load current preferences
        TranscriptionService.shared.startLiveTranscription(settings: currentSettings)

        do {
            try audioEngine.start()
            isRecording = true
            print("AudioEngine started for live recording.")
        } catch {
            print("Failed to start AVAudioEngine: \(error)")
            inputNode.removeTap(onBus: 0) // Clean up tap if engine fails to start
            isRecording = false
        }
    }

    func stopRecording() -> URL? {
        if liveModeActive {
            stopLiveRecording()
            liveModeActive = false // Reset mode
            return nil // Live recording doesn't produce a single file URL this way
        } else {
            audioRecorder?.stop()
            // isRecording will be set by delegate or immediately
            isRecording = false // Explicitly set for file mode stop
            
            // Check if recording duration is less than 1 second
            if let url = currentRecordingURL,
               let player = try? AVAudioPlayer(contentsOf: url), // AVAudioPlayer is better for duration
               player.duration < 1.0 {
                print("Recording too short, deleting: \(url)")
                try? FileManager.default.removeItem(at: url)
                currentRecordingURL = nil
                return nil
            }
            
            let url = currentRecordingURL
            currentRecordingURL = nil
            return url
        }
    }
    
    private func stopLiveRecording() {
        // Signal TranscriptionService to stop first
        TranscriptionService.shared.stopLiveTranscription()

        if !audioEngine.isRunning {
            print("AudioEngine not running, but ensuring live transcription service is stopped.")
            isRecording = false 
            return
        }
        
        print("Stopping live recording and audio engine.")
        inputNode?.removeTap(onBus: 0)
        audioEngine.stop()
        audioEngine.reset() 
        isRecording = false
    }

    func cancelRecording() {
        if liveModeActive {
            stopLiveRecording() // Same cleanup as stopping for live mode
            liveModeActive = false // Reset mode
        } else {
            audioRecorder?.stop() // Stop recording
            isRecording = false   // Update state
            
            if let url = currentRecordingURL {
                print("Cancelling and deleting file: \(url)")
                try? FileManager.default.removeItem(at: url) // Delete the file
            }
            currentRecordingURL = nil
        }
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

extension AudioRecorder: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag {
            currentRecordingURL = nil
        }
    }
}

extension AudioRecorder: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        currentlyPlayingURL = nil
    }
}
