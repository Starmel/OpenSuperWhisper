import Foundation

/// Settings for a transcription operation.
/// Populated from AppPreferences at transcription time.
public struct TranscriptionSettings {
    public static let asianLanguages: Set<String> = ["zh", "ja", "ko"]

    public var selectedLanguage: String
    public var translateToEnglish: Bool
    public var suppressBlankAudio: Bool
    public var showTimestamps: Bool
    public var temperature: Double
    public var noSpeechThreshold: Double
    public var initialPrompt: String
    public var useBeamSearch: Bool
    public var beamSize: Int
    public var useAsianAutocorrect: Bool

    public var isAsianLanguage: Bool {
        Self.asianLanguages.contains(selectedLanguage)
    }

    public var shouldApplyAsianAutocorrect: Bool {
        isAsianLanguage && useAsianAutocorrect
    }

    public init() {
        let prefs = AppPreferences.shared
        self.selectedLanguage = prefs.whisperLanguage
        self.translateToEnglish = prefs.translateToEnglish
        self.suppressBlankAudio = prefs.suppressBlankAudio
        self.showTimestamps = prefs.showTimestamps
        self.temperature = prefs.temperature
        self.noSpeechThreshold = prefs.noSpeechThreshold
        self.initialPrompt = prefs.initialPrompt
        self.useBeamSearch = prefs.useBeamSearch
        self.beamSize = prefs.beamSize
        self.useAsianAutocorrect = prefs.useAsianAutocorrect
    }
}
