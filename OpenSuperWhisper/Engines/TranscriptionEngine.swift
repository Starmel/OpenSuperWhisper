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
    /// Translation to English only works on Whisper (any model) and on Groq with the
    /// `whisper-large-v3` model. Parakeet/SenseVoice — and Groq's turbo model — silently ignore
    /// the `translateToEnglish` flag, so the toggle is disabled for them (#124).
    static func supportsTranslation(engine: String, groqModel: String) -> Bool {
        switch engine {
        case "whisper": return true
        case "groq": return groqModel == GroqEngine.translatingModel
        default: return false
        }
    }

    /// The language codes an engine+model can transcribe, in display order. The single source of
    /// truth for both the engines' `getSupportedLanguages()` and the language picker, so the UI can
    /// filter without instantiating an engine and the two can't drift (#155). Whisper uses the full
    /// Whisper set; "auto" (where present) means let the model detect the language.
    static func supportedLanguages(engine: String, fluidAudioModelVersion: String) -> [String] {
        switch engine {
        case "groq":
            return ["auto", "en", "fr", "es", "de", "it", "pt", "nl", "ru", "zh", "ja", "ko", "ar", "hi", "tr", "pl", "uk"]
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

