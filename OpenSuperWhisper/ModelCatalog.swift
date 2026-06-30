import FluidAudio
import Foundation

/// One selectable dictation model across all engines. Used by the menu-bar model
/// picker and the per-app context rules.
struct DictationModelOption: Codable, Equatable, Hashable {
    /// "whisper" | "fluidaudio" | "sensevoice" | "remote" — matches AppPreferences.selectedEngine.
    let engine: String
    /// whisper: model file path; fluidaudio: version ("v2"/"v3"); sensevoice: "default";
    /// remote: model id.
    let identifier: String
    let displayName: String
}

/// Single source of truth for which models are actually usable right now
/// (downloaded locally, or advertised by the configured remote server) and for
/// applying a selection. The menu and the context rules read from here so they
/// always agree.
enum ModelCatalog {
    /// Downloaded whisper.cpp model files.
    static func whisperModels() -> [DictationModelOption] {
        WhisperModelManager.shared.getAvailableModels().map { url in
            DictationModelOption(
                engine: "whisper",
                identifier: url.path,
                displayName: url.deletingPathExtension().lastPathComponent
            )
        }
    }

    /// Downloaded Parakeet (FluidAudio) model versions only — hide ones that
    /// aren't on disk, since the menu must never trigger a download.
    static func parakeetModels() -> [DictationModelOption] {
        SettingsFluidAudioModels.availableModels.compactMap { model in
            let version: AsrModelVersion = model.version == "v2" ? .v2 : .v3
            let cache = AsrModels.defaultCacheDirectory(for: version)
            guard AsrModels.modelsExist(at: cache, version: version) else { return nil }
            return DictationModelOption(
                engine: "fluidaudio",
                identifier: model.version,
                displayName: model.name
            )
        }
    }

    /// SenseVoice — a single (int8) model, arm64-only and only when downloaded.
    static func senseVoiceModels() -> [DictationModelOption] {
#if arch(arm64)
        guard SenseVoiceModelManager.shared.isDownloaded else { return [] }
        return [DictationModelOption(engine: "sensevoice", identifier: "default", displayName: "SenseVoice")]
#else
        return []
#endif
    }

    /// Models advertised by the remote server's /v1/models, cached by the
    /// settings panel when it last fetched. The currently-selected model is
    /// always included even if the cache is empty/stale, so the active choice is
    /// never missing from the list.
    static func remoteModels() -> [DictationModelOption] {
        var ids = AppPreferences.shared.cachedRemoteModels
        let current = AppPreferences.shared.remoteServerModel
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty, !ids.contains(current) {
            ids.insert(current, at: 0)
        }
        return ids.map {
            DictationModelOption(engine: "remote", identifier: $0, displayName: $0)
        }
    }

    /// Every usable model across engines. Used to decide whether switching is
    /// even meaningful (one model → nothing to choose).
    static func allAvailable() -> [DictationModelOption] {
        whisperModels() + parakeetModels() + senseVoiceModels() + remoteModels()
    }

    /// The model currently in effect (active engine + its selected model).
    static func activeOption() -> DictationModelOption? {
        let prefs = AppPreferences.shared
        switch prefs.selectedEngine {
        case "whisper":
            guard let path = prefs.selectedWhisperModelPath else { return nil }
            return DictationModelOption(
                engine: "whisper",
                identifier: path,
                displayName: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            )
        case "fluidaudio":
            return DictationModelOption(
                engine: "fluidaudio",
                identifier: prefs.fluidAudioModelVersion,
                displayName: prefs.fluidAudioModelVersion
            )
        case "sensevoice":
            return DictationModelOption(engine: "sensevoice", identifier: "default", displayName: "SenseVoice")
        case "remote":
            let id = prefs.remoteServerModel.trimmingCharacters(in: .whitespacesAndNewlines)
            return id.isEmpty
                ? nil
                : DictationModelOption(engine: "remote", identifier: id, displayName: id)
        default:
            return nil
        }
    }

    /// Switch the active engine + model, then invalidate the engine so the next
    /// recording re-initializes with the new choice. Mirrors the Settings UI.
    static func activate(_ option: DictationModelOption) {
        let prefs = AppPreferences.shared
        prefs.selectedEngine = option.engine
        switch option.engine {
        case "whisper":
            prefs.selectedWhisperModelPath = option.identifier
        case "fluidaudio":
            prefs.fluidAudioModelVersion = option.identifier
        case "remote":
            prefs.remoteServerModel = option.identifier
        case "sensevoice":
            break  // single model, nothing else to set
        default:
            break
        }
        // reloadEngine() is @MainActor-isolated on TranscriptionService.
        Task { @MainActor in
            TranscriptionService.shared.reloadEngine()
        }
    }
}
