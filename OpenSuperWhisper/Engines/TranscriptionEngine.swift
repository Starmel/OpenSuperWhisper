import Foundation
import AVFoundation

protocol TranscriptionEngine: AnyObject {
    var isModelLoaded: Bool { get }
    var engineName: String { get }
    
    func initialize() async throws
    func transcribeAudio(url: URL, settings: Settings) async throws -> String
    func cancelTranscription()
    func getSupportedLanguages() -> [String]
}

/// Engines that can consume the recorder's native mono 16 kHz float buffer.
/// Keeping this capability separate prevents live dictation from silently
/// regressing to the temporary-file path when another native engine is added.
protocol PCMTranscriptionEngine: TranscriptionEngine {
    func transcribeSamples(_ samples: [Float], settings: Settings) async throws -> String
}

protocol ProgressReportingTranscriptionEngine: TranscriptionEngine {
    var onProgressUpdate: ((Float) -> Void)? { get set }
}

