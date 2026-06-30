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

/// Static engine capabilities keyed by the stored engine id (`AppPreferences.selectedEngine`),
/// so the UI can gate features without instantiating an engine.
enum EngineCapabilities {
    /// Translation to English works on Whisper (any model) and on the remote engine, which
    /// forwards translation to the server's OpenAI-standard `/audio/translations` endpoint (the
    /// server decides whether its model supports it). Parakeet/SenseVoice silently ignore the
    /// `translateToEnglish` flag, so the toggle is disabled for them (#124).
    static func supportsTranslation(engine: String) -> Bool {
        switch engine {
        case "whisper": return true
        case "remote": return true
        default: return false
        }
    }

    /// The language codes an engine+model can transcribe, in display order. The single source of
    /// truth for both the engines' `getSupportedLanguages()` and the language picker, so the UI can
    /// filter without instantiating an engine and the two can't drift (#155). Whisper uses the full
    /// Whisper set; "auto" (where present) means let the model detect the language.
    static func supportedLanguages(engine: String, fluidAudioModelVersion: String) -> [String] {
        switch engine {
        case "remote":
            // The remote server decides language support; advertise the full Whisper set
            // (incl. "auto") so the user's choice is forwarded verbatim.
            return LanguageUtil.availableLanguages
        case "sensevoice":
            return ["auto", "zh", "en", "ja", "ko", "yue"]
        case "fluidaudio":
            return fluidAudioModelVersion == "v2"
                ? ["en"]
                : ["en", "de", "es", "fr", "it", "pt", "ru", "pl", "nl", "tr", "cs", "ar", "zh", "ja",
                   "hu", "fi", "hr", "sk", "sr", "sl", "uk", "ca", "da", "el", "bg"]
        default: // whisper — the full Whisper language set
            return LanguageUtil.availableLanguages
        }
    }
}

