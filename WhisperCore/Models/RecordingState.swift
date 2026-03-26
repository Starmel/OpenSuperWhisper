import Foundation

/// Represents the current state of the recording/transcription pipeline.
public enum RecordingState: Equatable {
    case idle
    case connecting
    case recording
    case decoding
    case busy
}
