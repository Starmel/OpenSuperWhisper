import AVFoundation
import Foundation

class AudioRecorder: NSObject, ObservableObject {
    @Published var isRecording = false
    @Published var recordings: [URL] = []
    
    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    private let recordingsDirectory: URL
    private var currentRecordingURL: URL? // To store the current recording's URL

    // MARK: - Singleton Instance

    static let shared = AudioRecorder() // The shared instance
    
    override private init() { // Private initializer to prevent external instantiation
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDirectory = applicationSupport.appendingPathComponent(Bundle.main.bundleIdentifier!)
        recordingsDirectory = appDirectory.appendingPathComponent("recordings")
        
        super.init()
        
        createRecordingsDirectoryIfNeeded()
        loadRecordings()
    }
    
    private func createRecordingsDirectoryIfNeeded() {
        do {
            try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
        } catch {
            print("Failed to create recordings directory: \(error)")
        }
    }
    
    private func loadRecordings() {
        do {
            recordings = try FileManager.default.contentsOfDirectory(at: recordingsDirectory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "wav" }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
        } catch {
            print("Failed to load recordings: \(error)")
        }
    }
    
    func startRecording() {
        if isRecording {
            stopRecording()
            print("Wtf return")
            return
        }
        
        let timestamp = Int(Date().timeIntervalSince1970)
        let filename = "\(timestamp).wav"
        let fileURL = recordingsDirectory.appendingPathComponent(filename)
        currentRecordingURL = fileURL // Save the URL of the current recording
        
        print("start record file to \(fileURL)")
        
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
        } catch {
            print("Failed to start recording: \(error)")
            currentRecordingURL = nil // Reset the URL if recording fails
        }
    }
    
    func stopRecording() -> URL? { // Changed to return URL?
        audioRecorder?.stop()
        isRecording = false
        loadRecordings()
        let url = currentRecordingURL
        currentRecordingURL = nil // Reset the URL
        return url // Return the URL of the stopped recording
    }
    
    func playRecording(url: URL) {
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.play()
        } catch {
            print("Failed to play recording: \(error)")
        }
    }
    
    func deleteRecording(url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
            loadRecordings()
        } catch {
            print("Failed to delete recording: \(error)")
        }
    }
}

extension AudioRecorder: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if flag {
            loadRecordings()
        }
    }
}
