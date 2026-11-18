import Foundation
import AVFoundation

protocol TranscriptionEngine: AnyObject {
    var isModelLoaded: Bool { get }
    var engineName: String { get }

    func initialize() async throws
    func transcribeAudio(url: URL, settings: Settings) async throws -> String
    func cancelTranscription()
    func getSupportedLanguages() -> [String]
    /// Frees native weights held by the engine, so a shut-down app does not keep
    /// gigabytes resident on the way out. Engines that do not hold any (the
    /// Parakeet engine loads through FluidAudio's own manager) do nothing.
    ///
    /// A requirement, not an extension-only method: callers hold engines as this
    /// protocol, and a method that exists only in the extension is dispatched
    /// statically to the empty default — which is how `shutdown()` used to keep
    /// a loaded whisper model alive.
    func unload()
}

extension TranscriptionEngine {
    func unload() {}
}

