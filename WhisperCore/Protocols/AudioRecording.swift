import Foundation
import Combine

/// Platform-agnostic protocol for audio recording.
/// macOS: Implemented by AudioRecorder (AppKit/CoreAudio)
/// iOS: Implemented by iOSAudioRecorder (AVAudioSession) in future cycle
public protocol AudioRecording: ObservableObject {
    var isRecording: Bool { get }
    var isConnecting: Bool { get }
    var canRecord: Bool { get }
    var currentTime: TimeInterval { get }

    func startRecording()
    func stopRecording() -> URL?
    func cancelRecording()
}
