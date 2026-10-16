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

extension TranscriptionEngine {
    /// Frees native weights held by the engine, so a shut-down app does not keep
    /// gigabytes resident on the way out. Engines that do not hold any (the
    /// Parakeet engine loads through FluidAudio's own manager) do nothing.
    func unload() {}
}

