import Foundation

@propertyWrapper
struct UserDefault<T> {
    let key: String
    let defaultValue: T
    
    var wrappedValue: T {
        get { AppPreferences.defaults.object(forKey: key) as? T ?? defaultValue }
        set { AppPreferences.defaults.set(newValue, forKey: key) }
    }
}

@propertyWrapper
struct OptionalUserDefault<T> {
    let key: String
    
    var wrappedValue: T? {
        get { AppPreferences.defaults.object(forKey: key) as? T }
        set { AppPreferences.defaults.set(newValue, forKey: key) }
    }
}

final class AppPreferences {
    static let shared = AppPreferences()

    /// Where every preference is read from and written to.
    ///
    /// In production this is `UserDefaults.standard` — the app's own domain,
    /// exactly as before. A test process gets a scratch suite of its own
    /// instead, because the standard domain is shared with everything else on
    /// this machine that runs the same bundle id: Xcode runs test classes in
    /// several processes at once, every crew worktree builds
    /// `ru.starmel.OpenSuperWhisper.dev`, and the app the developer is using
    /// holds the same preferences. With one domain between them, a suite's
    /// `toneEnabled` is another suite's state — and a test's tidy-up writes
    /// into the preferences of a running app.
    ///
    /// Two properties make the scratch suite safe to share between the tests of
    /// one process: the name carries the pid, so two processes can never meet,
    /// and the suite is emptied first, so a reused pid cannot inherit values
    /// from an earlier run.
    ///
    /// The seam covers `AppPreferences` values and nothing else. Two writers
    /// still reach the standard domain under test, neither an `AppPreferences`
    /// value nor routable through here: the `KeyboardShortcuts` library reads
    /// and writes its own `KeyboardShortcuts_*` keys through
    /// `UserDefaults.standard` whatever this says, and AppKit autosaves
    /// `NSWindow Frame …` for any window a process shows, tests included. The
    /// primary checkout keeps the shipped bundle id (see `Scripts/dev-run.sh`),
    /// so under test those keys are the developer's own; `ShortcutRecorderTests`
    /// plants and restores the one shortcut key it drives, and the second
    /// writer has no guard at all.
    static let defaults: UserDefaults = makeDefaults()

    private static func makeDefaults() -> UserDefaults {
        guard OpenSuperWhisperApp.isRunningTests else { return .standard }

        let name = "OpenSuperWhisperTests.\(ProcessInfo.processInfo.processIdentifier)"
        guard let scratch = UserDefaults(suiteName: name) else { return .standard }
        scratch.removePersistentDomain(forName: name)
        return scratch
    }

    /// Shape version of the stored preferences. Bump this whenever a stored
    /// value has to be reinterpreted; `migrateOldPreferences()` then runs the
    /// matching migration once per install.
    static let prefsSchemaVersion = 1
    static let prefsSchemaVersionKey = "prefsSchemaVersion"

    private init() {
        migrateOldPreferences()
    }

    /// One-time migrations for installs that already carry preferences.
    ///
    /// Every step converges an existing install onto the current model of the
    /// world and is safe to run again (a fresh install has nothing stored, so
    /// nothing happens at all). Installing a new version over an old one must
    /// leave the user with working dictation, not with a pointer to a file the
    /// app no longer owns.
    private func migrateOldPreferences() {
        let defaults = Self.defaults

        if let oldPath = defaults.string(forKey: "selectedModelPath"),
           defaults.string(forKey: "selectedWhisperModelPath") == nil {
            defaults.set(oldPath, forKey: "selectedWhisperModelPath")
        }

        guard defaults.integer(forKey: Self.prefsSchemaVersionKey) < Self.prefsSchemaVersion else { return }

        // 1. Whisper model paths are app-owned storage or nothing. A path that
        //    points into a git checkout (or anywhere else outside the app's own
        //    folder) is adopted by copying the file in; a path whose file is
        //    gone is dropped, and the app falls back to the model it ships.
        let modelsDirectory = WhisperModelManager.modelsDirectory
        for key in ["selectedWhisperModelPath", "selectedModelPath"] {
            guard let stored = defaults.string(forKey: key) else { continue }
            if let migrated = Self.adoptedModelPath(stored: stored, modelsDirectory: modelsDirectory) {
                defaults.set(migrated, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        // 2. `transformModel` (the id an external endpoint used to be told) is
        //    no longer read by anything, so nothing migrates it: the stale id
        //    stays in the domain exactly as the other removed translation keys
        //    do, and no code path looks at it.
        defaults.set(Self.prefsSchemaVersion, forKey: Self.prefsSchemaVersionKey)
    }

    /// The app-owned path for a stored model path, or `nil` when there is
    /// nothing usable to point at.
    ///
    /// A path already inside `modelsDirectory` is kept as is. One outside it is
    /// copied in — once — and the copy is returned. A path whose file does not
    /// exist yields `nil` so the caller drops it.
    static func adoptedModelPath(
        stored: String,
        modelsDirectory: URL,
        fileManager: FileManager = .default
    ) -> String? {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let storedURL = URL(fileURLWithPath: trimmed).standardizedFileURL
        let directoryPath = modelsDirectory.standardizedFileURL.path
        if storedURL.path == directoryPath || storedURL.path.hasPrefix(directoryPath + "/") {
            return trimmed
        }

        guard fileManager.fileExists(atPath: storedURL.path) else { return nil }

        let destination = modelsDirectory.appendingPathComponent(storedURL.lastPathComponent)
        if !fileManager.fileExists(atPath: destination.path) {
            do {
                try fileManager.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
                try fileManager.copyItem(at: storedURL, to: destination)
                print("[AppPreferences] adopted \(storedURL.path) into app storage")
            } catch {
                print("[AppPreferences] could not adopt \(storedURL.path): \(error)")
                return nil
            }
        }
        return destination.path
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

    // Transcription settings
    @UserDefault(key: "suppressBlankAudio", defaultValue: true)
    var suppressBlankAudio: Bool
    
    @UserDefault(key: "showTimestamps", defaultValue: false)
    var showTimestamps: Bool

    /// "VAD" — whether the silero speech-only pre-filter runs before the decoder.
    ///
    /// **Off by default**, on measurement, and measured on the captain's own
    /// recordings rather than on synthetic audio: with the filter on, one 8.69 s
    /// dictation kept 0.86 s of speech and came out "See you later." where the
    /// same audio with the filter off reads "All right, I gotta go home. See you
    /// later and keep up."; across the four worst rows the filter off recovered
    /// 35 words with 0 still missing, against 0 recovered and 35 still missing
    /// with it on. A threshold of 0.15 recovered 29 of those 35, min-silence,
    /// min-speech, speech-pad and beam size changed almost nothing, and the
    /// filter on a fully silent recording returns no transcript at all. So the
    /// control is off/on and the VAD's own parameters are not exposed
    /// (`WhisperEngine.vadParams`). Jev 1.13.0 ruling: toggle_only 0.96
    /// (conf 0.93), settings toggle 0.76 (conf 0.67).
    ///
    /// This recovery is an audio-level result measured outside the test suite;
    /// CI cannot re-verify it, and the suite asserts only that the setting
    /// reaches the decoder's parameters.
    @UserDefault(key: "useVAD", defaultValue: false)
    var useVAD: Bool

    /// "Long Pauses End the Sentence" — the switch that keeps a pause instead of
    /// dissolving it.
    ///
    /// The name says what the behaviour is, not what the captain first asked
    /// for: the nonsense came from *dissolving* the pause into a 0.1 s breath,
    /// so "ignore pauses" would name the defect. On, a pause of at least
    /// `PauseBoundaryPolicy.restored.sentenceThreshold` between two speech
    /// segments is kept as real silence (up to `maxPause`) and closes the
    /// sentence in the assembled text when the decoder did not close it.
    ///
    /// **On by default, and the English audio pays a measured two-word change for
    /// it.** The switch fixes the Polish the complaint is about (`pl-1` gains its
    /// sentence boundary and its verb; `pl-2` reads "Open Super Whisper" and
    /// "Dodałem" where the switch off garbles both). With the decoder prompt this
    /// app used to send — none — it did worse than that: the English control
    /// invented a fragment ("based, no,") at every silence cap tried. The prompt
    /// now sent for the language spoken removes that invention, and what is left
    /// is the switch's own audio half: it is present in the arm that sends no
    /// prompt at all and is identical across prompts, so **no prompt removes it**.
    /// The captain was shown that with the numbers and accepted it on
    /// **2026-09-25** — option (a), "pause fix everywhere, English takes a 2-word
    /// change", `fleet/data/fm-20260925-14` — and the shipped configuration is
    /// asserted against exactly that delta in `WhisperPauseBoundaryPairingTests`,
    /// so widening it fails the suite instead of landing quietly. It is measured
    /// on three recordings by one speaker, so it is a property of that pause and
    /// not a claim about English in general.
    ///
    /// With no prompt of your own the decoder prompt is chosen by the language of
    /// the dictation, and that costs one extra detect-only language pass over the
    /// audio before each dictation — measured +1.34 s against a 3.5 s decode,
    /// ≈ 38 % — paid only while this switch is on and no prompt is set; and on
    /// pause-heavy English speech the switch changes two words against the switch
    /// off ("Basically now it creates a sentences" where the switch off says
    /// "Basically how it creates a sentence"), a change the captain accepted on
    /// 2026-09-25 with the measurement in front of him, because no prompt removes
    /// it and the Polish fix rides on the same silence.
    ///
    /// Off remains byte-for-byte the behaviour every earlier build had, and
    /// flipping it back is this one line. The tables are in
    /// `WhisperPauseBoundaryPairingTests` and `fleet/data/fm-20260925-14/report.md`.
    @UserDefault(key: "longPausesEndSentences", defaultValue: true)
    var longPausesEndSentences: Bool
    
    @UserDefault(key: "temperature", defaultValue: 0.0)
    var temperature: Double
    
    @UserDefault(key: "noSpeechThreshold", defaultValue: 0.6)
    var noSpeechThreshold: Double
    
    /// The decoder context the user has set, or the empty string for none.
    ///
    /// Empty does **not** mean the decoder receives no prompt: when the switch
    /// above is on, an install that has never set one sends the default its
    /// language has (`WhisperEngine.decoderPrompt` — one measured entry for
    /// Polish, one for English, nothing for a language nobody measured). A value
    /// the user sets always wins over it, in any language, and this app never
    /// writes one for them.
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
    
    @UserDefault(key: "modifierOnlyHotkey", defaultValue: "none")
    var modifierOnlyHotkey: String
    
    /// Last non-none modifier key, used to restore the user's choice
    /// when switching back to Single Modifier Key mode.
    @UserDefault(key: "lastModifierOnlyHotkey", defaultValue: "leftCommand")
    var lastModifierOnlyHotkey: String
    
    @UserDefault(key: "mouseButtonHotkey", defaultValue: "none")
    var mouseButtonHotkey: String


    @UserDefault(key: "holdToRecord", defaultValue: true)
    var holdToRecord: Bool
    
    @UserDefault(key: "addSpaceAfterSentence", defaultValue: true)
    var addSpaceAfterSentence: Bool

    // Clipboard settings
    @UserDefault(key: "autoCopyToClipboard", defaultValue: false)
    var autoCopyToClipboard: Bool

    @UserDefault(key: "autoPasteTranscription", defaultValue: true)
    var autoPasteTranscription: Bool

    /// How a dictation is delivered to the focused application.
    ///
    /// Stored as its raw value because `UserDefault` reads the domain back
    /// untyped; `automatic` is the default, and an unreadable value falls back
    /// to it rather than to an arbitrary mechanism. See `TextDelivery` for what
    /// automatic means and why there are two mechanisms at all.
    @UserDefault(key: "deliveryPreference", defaultValue: DeliveryPreference.automatic.rawValue)
    var deliveryPreferenceRaw: String

    var deliveryPreference: DeliveryPreference {
        get { DeliveryPreference(rawValue: deliveryPreferenceRaw) ?? .automatic }
        set { deliveryPreferenceRaw = newValue.rawValue }
    }

    /// Whether a *vendor-prefix* match is enough to send a delivery through the
    /// clipboard.
    ///
    /// Defaults to `false`, because that half of the target rule is a judgement
    /// and an independent reading put it at 0.36: the exact bundle identifiers
    /// measured on this machine are what pastes on their own, and a bare family
    /// match only does so when the user says it should. See `TextDelivery`.
    @UserDefault(key: "pasteIntoRecognisedVendors", defaultValue: false)
    var pasteIntoRecognisedVendors: Bool

    /// Whether the user has already been told that a dictation went through the
    /// clipboard. The notice is shown once: after that the Settings control and
    /// the delivery record carry it. See `IndicatorViewModel.insertText`.
    @UserDefault(key: "clipboardDeliveryExplained", defaultValue: false)
    var clipboardDeliveryExplained: Bool

    // Tone and clean-up settings
    //
    // The translation feature is gone, and so are the preferences that
    // configured it: `translateEnabled`, `transformTargetLanguage`,
    // `transformEndpoint`, `transformModel`, `transformTimeout`,
    // `transformUseExternalEndpoint` and `whisperLanguage` are no longer read
    // or written anywhere. A domain that still holds them — the captain's own
    // does — simply carries values nothing looks at, which is the honest
    // handling: no migration, because there is nothing to migrate to, and
    // nothing that could resurrect a removed control.

    /// Gates every piece of tone text sent to the model. Defaults to `false`
    /// on purpose: a `true` default would start rewriting the dictation of
    /// installs that never enabled anything. There is deliberately no migration
    /// for it — existing installs stay bit-identical until the switch is
    /// flipped.
    ///
    /// The tone is a same-language rewrite: it changes the register of the
    /// transcript, never its language.
    @UserDefault(key: "toneEnabled", defaultValue: false)
    var toneEnabled: Bool

    @UserDefault(key: "transformToneMode", defaultValue: ToneMode.neutral.rawValue)
    private var transformToneModeRaw: String

    var transformToneMode: ToneMode {
        get { ToneMode(rawValue: transformToneModeRaw) ?? .neutral }
        set { transformToneModeRaw = newValue.rawValue }
    }

    /// The clean-up pass: the deterministic scrub of filler, stutters and
    /// repeated words, plus the grammar repair folded into the transform call.
    ///
    /// On by default because the deterministic half costs nothing, works
    /// without any model, and only ever removes an artifact — it can never
    /// invent a word. The grammar half rides on a transform call the user has
    /// already enabled, so it adds no call of its own.
    @UserDefault(key: "cleanUpDictation", defaultValue: true)
    var cleanUpEnabled: Bool

    /// Names, jargon and domain terms the user actually says, fed into the
    /// transform prompt so they come back spelled the way the user writes them.
    /// Empty by default and inert while empty: the composed prompt then contains
    /// no reference block at all.
    @UserDefault(key: "transformReference", defaultValue: "")
    var transformReference: String

    @UserDefault(key: "escCancelWithoutConfirmation", defaultValue: false)
    var escCancelWithoutConfirmation: Bool

    @UserDefault(key: "startHiddenInMenuBar", defaultValue: false)
    var startHiddenInMenuBar: Bool

    @UserDefault(key: "autoDeleteRecordingsEnabled", defaultValue: false)
    var autoDeleteRecordingsEnabled: Bool

    @UserDefault(key: "autoDeleteRecordingsAfterDays", defaultValue: 30)
    var autoDeleteRecordingsAfterDays: Int
}
