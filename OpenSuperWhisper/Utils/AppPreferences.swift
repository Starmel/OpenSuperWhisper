import Foundation
import KeyboardShortcuts

@propertyWrapper
struct UserDefault<T> {
    let key: String
    let defaultValue: T
    
    var wrappedValue: T {
        get { UserDefaults.standard.object(forKey: key) as? T ?? defaultValue }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

@propertyWrapper
struct OptionalUserDefault<T> {
    let key: String
    
    var wrappedValue: T? {
        get { UserDefaults.standard.object(forKey: key) as? T }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

final class AppPreferences {
    static let shared = AppPreferences()
    private init() {
        migrateOldPreferences()
    }
    
    private func migrateOldPreferences() {
        if let oldPath = UserDefaults.standard.string(forKey: "selectedModelPath"),
           UserDefaults.standard.string(forKey: "selectedWhisperModelPath") == nil {
            UserDefaults.standard.set(oldPath, forKey: "selectedWhisperModelPath")
        }

        // Migrate single-modifier hotkey -> singleKeyTriggers list, exactly once.
        // Always write the new key (even when empty) so migration never re-runs and
        // can't re-seed from the legacy value after the user clears their list.
        if UserDefaults.standard.data(forKey: Self.singleKeyTriggersKey) == nil {
            let migrated = Self.migratedSingleKeyTriggers(
                legacyModifierOnly: UserDefaults.standard.string(forKey: "modifierOnlyHotkey"),
                existingData: nil
            )
            singleKeyTriggers = migrated
            UserDefaults.standard.removeObject(forKey: "modifierOnlyHotkey")
            if !migrated.isEmpty {
                KeyboardShortcuts.setShortcut(nil, for: .toggleRecord)
            }
        }
    }

    // Recording trigger: list of bare single keys handled by the event-tap monitor.
    private static let singleKeyTriggersKey = "singleKeyTriggers"

    var singleKeyTriggers: [TriggerKey] {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.singleKeyTriggersKey),
                  let decoded = try? JSONDecoder().decode([TriggerKey].self, from: data)
            else { return [] }
            return decoded
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            UserDefaults.standard.set(data, forKey: Self.singleKeyTriggersKey)
        }
    }

    /// Pure migration logic (unit-tested). `existingData` is the current
    /// `singleKeyTriggers` JSON, if any; when present it always wins.
    static func migratedSingleKeyTriggers(legacyModifierOnly: String?, existingData: Data?) -> [TriggerKey] {
        if let existingData,
           let decoded = try? JSONDecoder().decode([TriggerKey].self, from: existingData) {
            return decoded
        }
        guard let legacy = legacyModifierOnly,
              let modifier = ModifierKey(rawValue: legacy),
              modifier != .none
        else { return [] }
        return [TriggerKey(modifierKey: modifier)]
    }
    
    // Engine settings
    @UserDefault(key: "selectedEngine", defaultValue: "whisper")
    var selectedEngine: String
    
    // Model settings
    var selectedModelPath: String? {
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
    var selectedWhisperModelPath: String?
    
    @UserDefault(key: "fluidAudioModelVersion", defaultValue: "v3")
    var fluidAudioModelVersion: String
    
    @UserDefault(key: "whisperLanguage", defaultValue: "en")
    var whisperLanguage: String
    
    // Transcription settings
    @UserDefault(key: "translateToEnglish", defaultValue: false)
    var translateToEnglish: Bool
    
    @UserDefault(key: "suppressBlankAudio", defaultValue: true)
    var suppressBlankAudio: Bool
    
    @UserDefault(key: "showTimestamps", defaultValue: false)
    var showTimestamps: Bool
    
    @UserDefault(key: "temperature", defaultValue: 0.0)
    var temperature: Double
    
    @UserDefault(key: "noSpeechThreshold", defaultValue: 0.6)
    var noSpeechThreshold: Double
    
    @UserDefault(key: "initialPrompt", defaultValue: "")
    var initialPrompt: String
    
    @UserDefault(key: "useBeamSearch", defaultValue: false)
    var useBeamSearch: Bool
    
    @UserDefault(key: "beamSize", defaultValue: 5)
    var beamSize: Int
    
    @UserDefault(key: "debugMode", defaultValue: false)
    var debugMode: Bool
    
    @UserDefault(key: "playSoundOnRecordStart", defaultValue: false)
    var playSoundOnRecordStart: Bool
    
    @UserDefault(key: "hasCompletedOnboarding", defaultValue: false)
    var hasCompletedOnboarding: Bool
    
    @UserDefault(key: "useAsianAutocorrect", defaultValue: true)
    var useAsianAutocorrect: Bool
    
    @OptionalUserDefault(key: "selectedMicrophoneData")
    var selectedMicrophoneData: Data?
    
    @UserDefault(key: "holdToRecord", defaultValue: true)
    var holdToRecord: Bool
    
    @UserDefault(key: "addSpaceAfterSentence", defaultValue: true)
    var addSpaceAfterSentence: Bool

    // Clipboard settings
    @UserDefault(key: "autoCopyToClipboard", defaultValue: true)
    var autoCopyToClipboard: Bool

    @UserDefault(key: "autoPasteTranscription", defaultValue: true)
    var autoPasteTranscription: Bool
}
