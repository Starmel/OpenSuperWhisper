import Foundation

@propertyWrapper
public struct UserDefault<T> {
    let key: String
    let defaultValue: T

    public var wrappedValue: T {
        get { UserDefaults.standard.object(forKey: key) as? T ?? defaultValue }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

@propertyWrapper
public struct OptionalUserDefault<T> {
    let key: String

    public var wrappedValue: T? {
        get { UserDefaults.standard.object(forKey: key) as? T }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

public final class AppPreferences {
    public static let shared = AppPreferences()
    private init() {
        migrateOldPreferences()
    }

    private func migrateOldPreferences() {
        if let oldPath = UserDefaults.standard.string(forKey: "selectedModelPath"),
           UserDefaults.standard.string(forKey: "selectedWhisperModelPath") == nil {
            UserDefaults.standard.set(oldPath, forKey: "selectedWhisperModelPath")
        }
    }

    // Engine settings
    @UserDefault(key: "selectedEngine", defaultValue: "whisper")
    public var selectedEngine: String

    // Model settings
    public var selectedModelPath: String? {
        get {
            if selectedEngine == "whisper" {
                return selectedWhisperModelPath
            }
            return nil
        }
        set {
            if selectedEngine == "whisper" {
                selectedWhisperModelPath = newValue
            }
        }
    }

    @OptionalUserDefault(key: "selectedWhisperModelPath")
    public var selectedWhisperModelPath: String?

    @UserDefault(key: "fluidAudioModelVersion", defaultValue: "v3")
    public var fluidAudioModelVersion: String

    @UserDefault(key: "whisperLanguage", defaultValue: "en")
    public var whisperLanguage: String

    // Transcription settings
    @UserDefault(key: "translateToEnglish", defaultValue: false)
    public var translateToEnglish: Bool

    @UserDefault(key: "suppressBlankAudio", defaultValue: true)
    public var suppressBlankAudio: Bool

    @UserDefault(key: "showTimestamps", defaultValue: false)
    public var showTimestamps: Bool

    @UserDefault(key: "temperature", defaultValue: 0.0)
    public var temperature: Double

    @UserDefault(key: "noSpeechThreshold", defaultValue: 0.6)
    public var noSpeechThreshold: Double

    @UserDefault(key: "initialPrompt", defaultValue: "")
    public var initialPrompt: String

    @UserDefault(key: "useBeamSearch", defaultValue: false)
    public var useBeamSearch: Bool

    @UserDefault(key: "beamSize", defaultValue: 5)
    public var beamSize: Int

    @UserDefault(key: "debugMode", defaultValue: false)
    public var debugMode: Bool

    @UserDefault(key: "playSoundOnRecordStart", defaultValue: false)
    public var playSoundOnRecordStart: Bool

    @UserDefault(key: "hasCompletedOnboarding", defaultValue: false)
    public var hasCompletedOnboarding: Bool

    @UserDefault(key: "useAsianAutocorrect", defaultValue: true)
    public var useAsianAutocorrect: Bool

    @OptionalUserDefault(key: "selectedMicrophoneData")
    public var selectedMicrophoneData: Data?

    @UserDefault(key: "modifierOnlyHotkey", defaultValue: "none")
    public var modifierOnlyHotkey: String

    @UserDefault(key: "holdToRecord", defaultValue: true)
    public var holdToRecord: Bool

    @UserDefault(key: "addSpaceAfterSentence", defaultValue: true)
    public var addSpaceAfterSentence: Bool
}
