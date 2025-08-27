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
    private var audioEngine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var notificationSound: NSSound?
    private let temporaryDirectory: URL
    private var currentRecordingURL: URL?
    private var notificationObserver: Any?

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
            // return
        }
        
        if AppPreferences.shared.playSoundOnRecordStart {
            playNotificationSound()
        }
        
        let timestamp = Int(Date().timeIntervalSince1970)
        let filename = "\(timestamp).wav"
        let fileURL = temporaryDirectory.appendingPathComponent(filename)
        currentRecordingURL = fileURL
        
        print("start record file to \(fileURL)")
        
        // Try using AVAudioEngine for non-interrupting recording
        if let engine = setupAudioEngine(outputURL: fileURL) {
            audioEngine = engine
            do {
                try engine.start()
                isRecording = true
                print("Started recording with AVAudioEngine (non-interrupting)")
            } catch {
                print("Failed to start audio engine: \(error)")
                // Fall back to standard AVAudioRecorder
                fallbackToAVAudioRecorder(fileURL: fileURL)
            }
        } else {
            // Fall back to standard AVAudioRecorder
            fallbackToAVAudioRecorder(fileURL: fileURL)
        }
    }
    
    private func setupAudioEngine(outputURL: URL) -> AVAudioEngine? {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        
        // Create the desired output format (16kHz, mono, 16-bit PCM)
        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                       sampleRate: 16000,
                                       channels: 1,
                                       interleaved: false)
        
        guard let format = outputFormat else {
            print("Failed to create output format")
            return nil
        }
        
        do {
            // Create audio file for writing
            audioFile = try AVAudioFile(forWriting: outputURL,
                                      settings: format.settings,
                                      commonFormat: format.commonFormat,
                                      interleaved: format.isInterleaved)
            
            // Install a tap on the input node to capture audio without interrupting playback
            // Use the input node's format for the tap, then convert if needed
            let inputFormat = inputNode.outputFormat(forBus: 0)
            
            inputNode.installTap(onBus: 0,
                               bufferSize: 1024,
                               format: inputFormat) { [weak self] buffer, _ in
                // Convert buffer to output format if needed
                if inputFormat != format {
                    // Create converter
                    guard let converter = AVAudioConverter(from: inputFormat, to: format) else {
                        return
                    }
                    
                    let convertedBuffer = AVAudioPCMBuffer(pcmFormat: format,
                                                         frameCapacity: buffer.frameCapacity)
                    
                    guard let outputBuffer = convertedBuffer else { return }
                    
                    do {
                        try converter.convert(to: outputBuffer, from: buffer)
                        try self?.audioFile?.write(from: outputBuffer)
                    } catch {
                        print("Conversion/write error: \(error)")
                    }
                } else {
                    // Direct write if formats match
                    do {
                        try self?.audioFile?.write(from: buffer)
                    } catch {
                        print("Write error: \(error)")
                    }
                }
            }
            
            return engine
        } catch {
            print("Failed to setup audio engine: \(error)")
            return nil
        }
    }
    
    private func fallbackToAVAudioRecorder(fileURL: URL) {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false
        ]
        
        do {
            audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.record()
            isRecording = true
            print("Started recording with AVAudioRecorder (may interrupt audio)")
        } catch {
            print("Failed to start recording: \(error)")
            currentRecordingURL = nil
        }
    }
    
    func stopRecording() -> URL? {
        // Stop audio engine if it's being used
        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            audioEngine = nil
            audioFile = nil
        }
        
        // Stop audio recorder if it's being used
        audioRecorder?.stop()
        isRecording = false
        
        // Check if recording duration is less than 1 second
        if let url = currentRecordingURL,
           let duration = try? AVAudioPlayer(contentsOf: url).duration,
           duration < 1.0
        {
            // Remove recordings shorter than 1 second
            try? FileManager.default.removeItem(at: url)
            currentRecordingURL = nil
            return nil
        }
        
        let url = currentRecordingURL
        currentRecordingURL = nil
        return url
    }
    
    func cancelRecording() {
        audioRecorder?.stop()
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
