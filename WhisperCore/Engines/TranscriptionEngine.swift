import Foundation
import AVFoundation

public protocol TranscriptionEngine: AnyObject {
    var isModelLoaded: Bool { get }
    var engineName: String { get }

    func initialize() async throws
    func transcribeAudio(url: URL, settings: TranscriptionSettings) async throws -> String
    func cancelTranscription()
    func getSupportedLanguages() -> [String]
}
