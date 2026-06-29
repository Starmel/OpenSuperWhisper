import AppKit
import Carbon
import Combine
import Foundation
import KeyboardShortcuts
import SwiftUI
import FluidAudio

class SettingsViewModel: ObservableObject {
    @Published var selectedEngine: String {
        didSet {
            AppPreferences.shared.selectedEngine = selectedEngine
            if selectedEngine == "whisper" {
                loadAvailableModels()
            } else {
                initializeFluidAudioModels()
            }
            clampLanguageToSupported()
            Task { @MainActor in
                TranscriptionService.shared.reloadEngine()
            }
        }
    }
    
    @Published var fluidAudioModelVersion: String {
        didSet {
            AppPreferences.shared.fluidAudioModelVersion = fluidAudioModelVersion
            // Clicking a Parakeet model activates the Parakeet engine (browse ≠ select).
            if selectedEngine != "fluidaudio" {
                selectedEngine = "fluidaudio"
            } else {
                clampLanguageToSupported()
                Task { @MainActor in
                    TranscriptionService.shared.reloadEngine()
                }
            }
            initializeFluidAudioModels()
        }
    }
    
    @Published var selectedModelURL: URL? {
        didSet {
            if let url = selectedModelURL {
                AppPreferences.shared.selectedWhisperModelPath = url.path
            }
        }
    }

    /// User-initiated model selection. Persists the model and, when the model declares a
    /// preferred language (e.g. the ivrit.ai Hebrew model), switches to it. Use this for
    /// explicit user actions only — not from init/restore — so we never override the language
    /// on a routine reload.
    func selectModel(_ url: URL) {
        selectedModelURL = url
        // Clicking a Whisper model is what activates the Whisper engine (browse ≠ select).
        if selectedEngine != "whisper" { selectedEngine = "whisper" }
        if let lang = SettingsDownloadableModels.preferredLanguage(forFilename: url.lastPathComponent),
           selectedLanguage != lang {
            selectedLanguage = lang
        }
    }

    @Published var availableModels: [URL] = []
    
    @Published var downloadableModels: [SettingsDownloadableModel] = []
    @Published var downloadableFluidAudioModels: [SettingsFluidAudioModel] = []
    @Published var isDownloading: Bool = false
    @Published var downloadProgress: Double = 0.0
    @Published var downloadingModelName: String?
    private var downloadTask: Task<Void, Error>?
    
    @Published var selectedLanguage: String {
        didSet {
            AppPreferences.shared.whisperLanguage = selectedLanguage
            NotificationCenter.default.post(name: .appPreferencesLanguageChanged, object: nil)
        }
    }

    @Published var translateToEnglish: Bool {
        didSet {
            AppPreferences.shared.translateToEnglish = translateToEnglish
        }
    }

    /// Whether the selected engine + model can translate to English (#124). When false the
    /// "Translate to English" toggle is disabled — Parakeet/SenseVoice (and Groq's turbo model)
    /// ignore the flag, so showing an active toggle is misleading.
    var canTranslate: Bool {
        EngineCapabilities.supportsTranslation(engine: selectedEngine, groqModel: AppPreferences.shared.groqModel)
    }

    /// Languages the selected engine+model can transcribe — filters the language picker (#155).
    var supportedLanguages: [String] {
        EngineCapabilities.supportedLanguages(engine: selectedEngine, fluidAudioModelVersion: fluidAudioModelVersion)
    }

    /// Reset the language to a supported one when the current engine/model can't transcribe the
    /// previously selected one (e.g. switching to a model without that language) (#155). Prefers
    /// Auto-detect, then English, then whatever the model lists first — so the picker is never blank.
    func clampLanguageToSupported() {
        let supported = supportedLanguages
        guard !supported.contains(selectedLanguage) else { return }
        selectedLanguage = supported.first(where: { $0 == "auto" })
            ?? supported.first(where: { $0 == "en" })
            ?? supported.first ?? "auto"
    }

    @Published var suppressBlankAudio: Bool {
        didSet {
            AppPreferences.shared.suppressBlankAudio = suppressBlankAudio
        }
    }

    @Published var showTimestamps: Bool {
        didSet {
            AppPreferences.shared.showTimestamps = showTimestamps
        }
    }
    
    @Published var temperature: Double {
        didSet {
            AppPreferences.shared.temperature = temperature
        }
    }

    @Published var noSpeechThreshold: Double {
        didSet {
            AppPreferences.shared.noSpeechThreshold = noSpeechThreshold
        }
    }

    @Published var initialPrompt: String {
        didSet {
            AppPreferences.shared.initialPrompt = initialPrompt
        }
    }

    @Published var customDictionaryEnabled: Bool {
        didSet {
            AppPreferences.shared.customDictionaryEnabled = customDictionaryEnabled
        }
    }

    @Published var customDictionaryEntries: [CustomDictionaryEntry] {
        didSet {
            AppPreferences.shared.customDictionaryEntries = customDictionaryEntries
        }
    }

    @Published var useBeamSearch: Bool {
        didSet {
            AppPreferences.shared.useBeamSearch = useBeamSearch
        }
    }

    @Published var beamSize: Int {
        didSet {
            AppPreferences.shared.beamSize = beamSize
        }
    }

    @Published var debugMode: Bool {
        didSet {
            AppPreferences.shared.debugMode = debugMode
        }
    }
    
    @Published var playSoundOnRecordStart: Bool {
        didSet {
            AppPreferences.shared.playSoundOnRecordStart = playSoundOnRecordStart
        }
    }

    @Published var startHidden: Bool {
        didSet {
            AppPreferences.shared.startHidden = startHidden
        }
    }

    @Published var indicatorPosition: String {
        didSet {
            AppPreferences.shared.indicatorPosition = indicatorPosition
        }
    }

    @Published var liveTranscriptionEnabled: Bool {
        didSet {
            AppPreferences.shared.liveTranscriptionEnabled = liveTranscriptionEnabled
        }
    }

    @Published var useAsianAutocorrect: Bool {
        didSet {
            AppPreferences.shared.useAsianAutocorrect = useAsianAutocorrect
        }
    }
    
    @Published var modifierOnlyHotkey: ModifierKey {
        didSet {
            AppPreferences.shared.modifierOnlyHotkey = modifierOnlyHotkey.rawValue
            NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
        }
    }
    
    @Published var holdToRecord: Bool {
        didSet {
            AppPreferences.shared.holdToRecord = holdToRecord
        }
    }


    @Published var addSpaceAfterSentence: Bool {
        didSet {
            AppPreferences.shared.addSpaceAfterSentence = addSpaceAfterSentence
        }
    }

    @Published var aiPostProcessingEnabled: Bool {
        didSet {
            AppPreferences.shared.aiPostProcessingEnabled = aiPostProcessingEnabled
            // Surface connectivity right away when the user turns it on, so they aren't left
            // wondering why their cleanup silently does nothing when Ollama isn't running.
            if aiPostProcessingEnabled { testOllamaConnection() }
        }
    }

    @Published var aiOllamaEndpoint: String {
        didSet {
            AppPreferences.shared.aiOllamaEndpoint = aiOllamaEndpoint
        }
    }

    @Published var aiOllamaModel: String {
        didSet {
            AppPreferences.shared.aiOllamaModel = aiOllamaModel
        }
    }

    @Published var aiPostProcessingPrompt: String {
        didSet {
            AppPreferences.shared.aiPostProcessingPrompt = aiPostProcessingPrompt
        }
    }

    /// Live result of the last Ollama connectivity probe, shown next to the AI-cleanup fields.
    @Published var ollamaStatus: OllamaStatus = .unknown

    func testOllamaConnection() {
        ollamaStatus = .checking
        let endpoint = aiOllamaEndpoint
        let model = aiOllamaModel
        Task { @MainActor in
            self.ollamaStatus = await LLMPostProcessor.checkConnection(endpoint: endpoint, model: model)
        }
    }

    @Published var removeFillerWords: Bool {
        didSet {
            AppPreferences.shared.removeFillerWords = removeFillerWords
        }
    }

    @Published var fillerWordsPattern: String {
        didSet {
            AppPreferences.shared.fillerWordsPattern = fillerWordsPattern
        }
    }

    @Published var postRecordHookEnabled: Bool {
        didSet {
            AppPreferences.shared.postRecordHookEnabled = postRecordHookEnabled
        }
    }

    @Published var postRecordHookCommand: String {
        didSet {
            AppPreferences.shared.postRecordHookCommand = postRecordHookCommand
        }
    }

    @Published var autoCopyToClipboard: Bool {
        didSet {
            AppPreferences.shared.autoCopyToClipboard = autoCopyToClipboard
        }
    }

    @Published var autoPasteTranscription: Bool {
        didSet {
            AppPreferences.shared.autoPasteTranscription = autoPasteTranscription
        }
    }

    @Published var pasteInsteadOfTyping: Bool {
        didSet {
            AppPreferences.shared.pasteInsteadOfTyping = pasteInsteadOfTyping
        }
    }

    @Published var notifyWhenNoPasteTarget: Bool {
        didSet {
            AppPreferences.shared.notifyWhenNoPasteTarget = notifyWhenNoPasteTarget
        }
    }

    @Published var submitOnVoiceCommand: Bool {
        didSet {
            AppPreferences.shared.submitOnVoiceCommand = submitOnVoiceCommand
        }
    }

    @Published var pauseMediaOnRecord: Bool {
        didSet {
            AppPreferences.shared.pauseMediaOnRecord = pauseMediaOnRecord
        }
    }

    @Published var reduceVolumeOnRecord: Bool {
        didSet {
            AppPreferences.shared.reduceVolumeOnRecord = reduceVolumeOnRecord
        }
    }

    @Published var reduceVolumeLevel: Double {
        didSet {
            AppPreferences.shared.reduceVolumeLevel = reduceVolumeLevel
        }
    }

    // MARK: - Retention / storage policy

    @Published var retentionMaxCountEnabled: Bool {
        didSet {
            AppPreferences.shared.retentionMaxCountEnabled = retentionMaxCountEnabled
            enforceRetention()
        }
    }

    @Published var retentionMaxCount: Int {
        didSet {
            // Clamp the published property itself (not only the stored value) so the UI and
            // the persisted/enforced value can never diverge. The re-assignment re-enters
            // didSet once with an already-clamped value, which then falls through.
            let clamped = max(1, retentionMaxCount)
            if clamped != retentionMaxCount {
                retentionMaxCount = clamped
                return
            }
            AppPreferences.shared.retentionMaxCount = clamped
            enforceRetention()
        }
    }

    @Published var retentionMaxAgeEnabled: Bool {
        didSet {
            AppPreferences.shared.retentionMaxAgeEnabled = retentionMaxAgeEnabled
            enforceRetention()
        }
    }

    @Published var retentionMaxAgeValue: Int {
        didSet {
            // Clamp the published property itself (see retentionMaxCount) so the UI and the
            // persisted/enforced value can never diverge.
            let clamped = max(1, retentionMaxAgeValue)
            if clamped != retentionMaxAgeValue {
                retentionMaxAgeValue = clamped
                return
            }
            AppPreferences.shared.retentionMaxAgeValue = clamped
            enforceRetention()
        }
    }

    @Published var retentionMaxAgeUnit: RetentionUnit {
        didSet {
            AppPreferences.shared.retentionMaxAgeUnit = retentionMaxAgeUnit.rawValue
            enforceRetention()
        }
    }

    private var retentionEnforceTimer: Timer?

    /// Applies the retention policy after a short debounce so the user sees the effect of
    /// toggling a switch or changing a limit, without the data-loss footgun of enforcing on
    /// every keystroke: the count/age TextFields use `format: .number`, whose binding commits
    /// (and fires didSet) on each parsed value, so typing "500" passes through 5 and 50.
    /// Enforcing immediately would permanently delete recordings at those intermediate values.
    /// Debouncing coalesces a burst of edits into a single enforcement at the final value.
    private func enforceRetention() {
        retentionEnforceTimer?.invalidate()
        retentionEnforceTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { _ in
            Task { @MainActor in
                await RecordingStore.shared.enforceRetentionPolicy()
            }
        }
    }

    @Published var saveTranscriptionHistory: Bool {
        didSet {
            AppPreferences.shared.saveTranscriptionHistory = saveTranscriptionHistory
        }
    }

    init() {
        let prefs = AppPreferences.shared
        self.selectedEngine = prefs.selectedEngine
        self.fluidAudioModelVersion = prefs.fluidAudioModelVersion
        self.selectedLanguage = prefs.whisperLanguage
        self.translateToEnglish = prefs.translateToEnglish
        self.suppressBlankAudio = prefs.suppressBlankAudio
        self.showTimestamps = prefs.showTimestamps
        self.temperature = prefs.temperature
        self.noSpeechThreshold = prefs.noSpeechThreshold
        self.initialPrompt = prefs.initialPrompt
        self.customDictionaryEnabled = prefs.customDictionaryEnabled
        self.customDictionaryEntries = prefs.customDictionaryEntries
        self.useBeamSearch = prefs.useBeamSearch
        self.beamSize = prefs.beamSize
        self.debugMode = prefs.debugMode
        self.playSoundOnRecordStart = prefs.playSoundOnRecordStart
        self.startHidden = prefs.startHidden
        self.indicatorPosition = prefs.indicatorPosition
        self.liveTranscriptionEnabled = prefs.liveTranscriptionEnabled
        self.useAsianAutocorrect = prefs.useAsianAutocorrect
        self.modifierOnlyHotkey = ModifierKey(rawValue: prefs.modifierOnlyHotkey) ?? .none
        self.holdToRecord = prefs.holdToRecord
        self.addSpaceAfterSentence = prefs.addSpaceAfterSentence
        self.aiPostProcessingEnabled = prefs.aiPostProcessingEnabled
        self.aiOllamaEndpoint = prefs.aiOllamaEndpoint
        self.aiOllamaModel = prefs.aiOllamaModel
        self.aiPostProcessingPrompt = prefs.aiPostProcessingPrompt
        self.removeFillerWords = prefs.removeFillerWords
        self.fillerWordsPattern = prefs.fillerWordsPattern
        self.postRecordHookEnabled = prefs.postRecordHookEnabled
        self.postRecordHookCommand = prefs.postRecordHookCommand
        self.autoCopyToClipboard = prefs.autoCopyToClipboard
        self.autoPasteTranscription = prefs.autoPasteTranscription
        self.pasteInsteadOfTyping = prefs.pasteInsteadOfTyping
        self.notifyWhenNoPasteTarget = prefs.notifyWhenNoPasteTarget
        self.submitOnVoiceCommand = prefs.submitOnVoiceCommand
        self.pauseMediaOnRecord = prefs.pauseMediaOnRecord
        self.reduceVolumeOnRecord = prefs.reduceVolumeOnRecord
        self.reduceVolumeLevel = prefs.reduceVolumeLevel
        self.retentionMaxCountEnabled = prefs.retentionMaxCountEnabled
        self.retentionMaxCount = prefs.retentionMaxCount
        self.retentionMaxAgeEnabled = prefs.retentionMaxAgeEnabled
        self.retentionMaxAgeValue = prefs.retentionMaxAgeValue
        self.retentionMaxAgeUnit = RetentionUnit(rawValue: prefs.retentionMaxAgeUnit) ?? .days
        self.saveTranscriptionHistory = prefs.saveTranscriptionHistory

        if let savedPath = prefs.selectedWhisperModelPath ?? prefs.selectedModelPath {
            self.selectedModelURL = URL(fileURLWithPath: savedPath)
        }
        loadAvailableModels()
        initializeDownloadableModels()
        initializeFluidAudioModels()
    }
    
    func initializeFluidAudioModels() {
        downloadableFluidAudioModels = SettingsFluidAudioModels.availableModels.map { model in
            var updatedModel = model
            updatedModel.isDownloaded = isFluidAudioModelDownloaded(version: model.version)
            return updatedModel
        }
    }
    
    func isFluidAudioModelDownloaded(version: String) -> Bool {
        let asrVersion: AsrModelVersion = version == "v2" ? .v2 : .v3
        
        // Используем правильный путь к кэшу согласно документации:
        // ~/Library/Application Support/FluidAudio/Models/<version-folder>/
        let cacheDirectory = AsrModels.defaultCacheDirectory(for: asrVersion)
        
        // Проверяем наличие всех необходимых файлов модели
        return AsrModels.modelsExist(at: cacheDirectory, version: asrVersion)
    }
    
    func initializeDownloadableModels() {
        let modelManager = WhisperModelManager.shared
        downloadableModels = SettingsDownloadableModels.availableModels.map { model in
            var updatedModel = model
            let filename = model.filename
            updatedModel.isDownloaded = modelManager.isModelDownloaded(name: filename)
            return updatedModel
        }
    }
    
    func loadAvailableModels() {
        availableModels = WhisperModelManager.shared.getAvailableModels()
        if selectedModelURL == nil {
            selectedModelURL = availableModels.first
        }
        initializeDownloadableModels()
    }
    
    @MainActor
    func downloadModel(_ model: SettingsDownloadableModel) async throws {
        guard !isDownloading else { return }
        
        isDownloading = true
        downloadingModelName = model.name
        downloadProgress = 0.0
        
        downloadTask = Task {
            do {
                let filename = model.filename
                
                try await WhisperModelManager.shared.downloadModel(url: model.url, name: filename) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self = self, !Task.isCancelled else { return }
                        guard let task = self.downloadTask, !task.isCancelled else { return }
                        
                        self.downloadProgress = progress
                        if let index = self.downloadableModels.firstIndex(where: { $0.name == model.name }) {
                            self.downloadableModels[index].downloadProgress = progress
                            if progress >= 1.0 {
                                self.downloadableModels[index].isDownloaded = true
                            }
                        }
                    }
                }
                
                guard !Task.isCancelled else {
                    await MainActor.run {
                        self.isDownloading = false
                        self.downloadingModelName = nil
                        self.downloadProgress = 0.0
                        if let index = self.downloadableModels.firstIndex(where: { $0.name == model.name }) {
                            self.downloadableModels[index].downloadProgress = 0.0
                        }
                    }
                    return
                }
                
                await MainActor.run {
                    if let index = downloadableModels.firstIndex(where: { $0.name == model.name }) {
                        downloadableModels[index].isDownloaded = true
                        downloadableModels[index].downloadProgress = 0.0
                    }
                    loadAvailableModels()
                    let modelPath = WhisperModelManager.shared.modelsDirectory.appendingPathComponent(filename).path
                    selectModel(URL(fileURLWithPath: modelPath))
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 0.0
                    
                    Task { @MainActor in
                        TranscriptionService.shared.reloadModel(with: modelPath)
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 0.0
                    if let index = downloadableModels.firstIndex(where: { $0.name == model.name }) {
                        downloadableModels[index].downloadProgress = 0.0
                    }
                }
            } catch {
                await MainActor.run {
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 0.0
                    if let index = downloadableModels.firstIndex(where: { $0.name == model.name }) {
                        downloadableModels[index].downloadProgress = 0.0
                    }
                }
                throw error
            }
        }
        
        try await downloadTask?.value
    }
    
    func cancelDownload() {
        downloadTask?.cancel()
        if let modelName = downloadingModelName {
            if selectedEngine == "whisper", let model = downloadableModels.first(where: { $0.name == modelName }) {
                let filename = model.filename
                WhisperModelManager.shared.cancelDownload(name: filename)
            }
            // Reset progress for the downloading model
            if let index = downloadableModels.firstIndex(where: { $0.name == modelName }) {
                downloadableModels[index].downloadProgress = 0.0
            }
            if let index = downloadableFluidAudioModels.firstIndex(where: { $0.name == modelName }) {
                downloadableFluidAudioModels[index].downloadProgress = 0.0
            }
        }
        isDownloading = false
        downloadingModelName = nil
        downloadProgress = 0.0
    }
    
    @MainActor
    func downloadFluidAudioModel(_ model: SettingsFluidAudioModel) async throws {
        guard !isDownloading else { return }
        
        isDownloading = true
        downloadingModelName = model.name
        downloadProgress = 0.0
        
        if let index = downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
            downloadableFluidAudioModels[index].downloadProgress = 0.0
        }
        
        var wasCancelled = false
        
        downloadTask = Task {
            do {
                let version: AsrModelVersion = model.version == "v2" ? .v2 : .v3
                
                guard !Task.isCancelled else {
                    await MainActor.run {
                        self.isDownloading = false
                        self.downloadingModelName = nil
                        self.downloadProgress = 0.0
                        if let index = self.downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                            self.downloadableFluidAudioModels[index].downloadProgress = 0.0
                        }
                    }
                    throw CancellationError()
                }
                
                let models = try await AsrModels.downloadAndLoad(version: version)
                
                guard !Task.isCancelled else {
                    await MainActor.run {
                        self.isDownloading = false
                        self.downloadingModelName = nil
                        self.downloadProgress = 0.0
                        if let index = self.downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                            self.downloadableFluidAudioModels[index].downloadProgress = 0.0
                        }
                    }
                    throw CancellationError()
                }
                
                let manager = AsrManager(config: .default)
                try await manager.initialize(models: models)
                
                await MainActor.run {
                    if let index = downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                        downloadableFluidAudioModels[index].isDownloaded = true
                        downloadableFluidAudioModels[index].downloadProgress = 1.0
                    }
                    fluidAudioModelVersion = model.version
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 1.0
                    
                    Task { @MainActor in
                        TranscriptionService.shared.reloadEngine()
                    }
                }
            } catch is CancellationError {
                wasCancelled = true
                await MainActor.run {
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 0.0
                    if let index = downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                        downloadableFluidAudioModels[index].downloadProgress = 0.0
                    }
                }
                // Don't re-throw CancellationError - it's a manual cancellation
            } catch {
                // Check if we were cancelled before the error occurred
                if Task.isCancelled {
                    wasCancelled = true
                    await MainActor.run {
                        isDownloading = false
                        downloadingModelName = nil
                        downloadProgress = 0.0
                        if let index = downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                            downloadableFluidAudioModels[index].downloadProgress = 0.0
                        }
                    }
                } else {
                    await MainActor.run {
                        isDownloading = false
                        downloadingModelName = nil
                        downloadProgress = 0.0
                        if let index = downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                            downloadableFluidAudioModels[index].downloadProgress = 0.0
                        }
                    }
                    throw error
                }
            }
        }
        
        // Handle cancellation gracefully - don't throw if cancelled
        do {
            try await downloadTask?.value
        } catch is CancellationError {
            // Already handled in catch block above, just consume the error
            wasCancelled = true
        } catch {
            // If we were cancelled, don't throw
            if !wasCancelled {
                throw error
            }
        }
    }
    
    @MainActor
    func downloadFluidAudioModel() async throws {
        let versionString = AppPreferences.shared.fluidAudioModelVersion
        if let model = downloadableFluidAudioModels.first(where: { $0.version == versionString }) {
            try await downloadFluidAudioModel(model)
        }
    }
}

struct SettingsDownloadableModel: Identifiable {
    let id = UUID()
    let name: String
    var isDownloaded: Bool
    let url: URL
    let size: Int
    let description: String
    var downloadProgress: Double = 0.0
    /// On-disk filename. Defaults to the URL's basename, but some sources (e.g. the ivrit.ai
    /// model served as a generic `ggml-model.bin`) need an explicit, distinct name.
    let filename: String
    /// Language to switch to when this model is selected (e.g. "he" for the Hebrew model).
    let preferredLanguage: String?

    var sizeString: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(size) * 1000000)
    }

    init(name: String, isDownloaded: Bool, url: URL, size: Int, description: String,
         filename: String? = nil, preferredLanguage: String? = nil) {
        self.name = name
        self.isDownloaded = isDownloaded
        self.url = url
        self.size = size
        self.description = description
        self.filename = filename ?? url.lastPathComponent
        self.preferredLanguage = preferredLanguage
    }
}

struct SettingsDownloadableModels {
    static let availableModels = [
        SettingsDownloadableModel(
            name: "Turbo V3 large",
            isDownloaded: false,
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin?download=true")!,
            size: 1624,
            description: "High accuracy, best quality"
        ),
        SettingsDownloadableModel(
            name: "Turbo V3 medium",
            isDownloaded: false,
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q8_0.bin?download=true")!,
            size: 874,
            description: "Balanced speed and accuracy"
        ),
        SettingsDownloadableModel(
            name: "Turbo V3 small",
            isDownloaded: false,
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin?download=true")!,
            size: 574,
            description: "Fastest processing"
        ),
        SettingsDownloadableModel(
            name: "Hebrew — ivrit.ai Turbo v3",
            isDownloaded: false,
            url: URL(string: "https://huggingface.co/ivrit-ai/whisper-large-v3-turbo-ggml/resolve/main/ggml-model.bin?download=true")!,
            size: 1624,
            description: "Hebrew-optimized model by ivrit.ai. Selecting it sets the language to Hebrew.",
            filename: "ggml-ivrit-large-v3-turbo.bin",
            preferredLanguage: "he"
        )
    ]

    static func preferredLanguage(forFilename filename: String) -> String? {
        availableModels.first { $0.filename == filename }?.preferredLanguage
    }
}

struct Settings {
    static let asianLanguages: Set<String> = ["zh", "ja", "ko"]
    
    var selectedLanguage: String
    var translateToEnglish: Bool
    var suppressBlankAudio: Bool
    var showTimestamps: Bool
    var temperature: Double
    var noSpeechThreshold: Double
    var initialPrompt: String
    var useBeamSearch: Bool
    var beamSize: Int
    var useAsianAutocorrect: Bool
    var customDictionaryEnabled: Bool
    var customDictionaryEntries: [CustomDictionaryEntry]

    var isAsianLanguage: Bool {
        Settings.asianLanguages.contains(selectedLanguage)
    }

    var shouldApplyAsianAutocorrect: Bool {
        isAsianLanguage && useAsianAutocorrect
    }

    var shouldApplyCustomDictionary: Bool {
        customDictionaryEnabled && !customDictionaryEntries.isEmpty
    }

    init() {
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
        self.customDictionaryEnabled = prefs.customDictionaryEnabled
        self.customDictionaryEntries = prefs.customDictionaryEntries
    }
}

/// A small "ⓘ" button that reveals a longer explanation in a popover, so setting rows can
/// show a short caption by default and keep the full details one click away.
struct InfoButton: View {
    let text: LocalizedStringKey
    @State private var isShown = false

    var body: some View {
        Button {
            isShown.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .help("More info")
        .popover(isPresented: $isShown, arrowEdge: .bottom) {
            Text(text)
                .font(.callout)
                .multilineTextAlignment(.leading)
                .frame(width: 300, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding()
        }
    }
}

/// A standard setting row: title (+ optional ⓘ with full details), a short caption, and a
/// trailing control (e.g. a Toggle).
struct SettingRow<Trailing: View>: View {
    let title: LocalizedStringKey
    let caption: LocalizedStringKey
    var info: LocalizedStringKey? = nil
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(title).font(.subheadline)
                    if let info { InfoButton(text: info) }
                }
                Text(caption)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer()
            trailing()
        }
    }
}

/// The settings tabs, shown as a vertical sidebar in the dedicated settings window.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, model, transcription, history, advanced, updates, feedback
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "General"
        case .model: return "Engine & Model"
        case .transcription: return "Transcription"
        case .history: return "History"
        case .advanced: return "Advanced"
        case .updates: return "Updates"
        case .feedback: return "Feedback"
        }
    }
    var icon: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .model: return "cpu"
        case .transcription: return "text.bubble"
        case .history: return "clock.arrow.circlepath"
        case .advanced: return "gearshape"
        case .updates: return "sparkles"
        case .feedback: return "heart.text.square"
        }
    }
}

struct SettingsView: View {
    struct HookVariable { let name: String; let description: String }
    static let postRecordHookVariables = [
        HookVariable(name: "$OSW_TEXT", description: "the transcription"),
        HookVariable(name: "$OSW_AUDIO_PATH", description: "wav file path (when history is on)"),
        HookVariable(name: "$OSW_TIMESTAMP", description: "ISO 8601 date"),
        HookVariable(name: "$OSW_DURATION", description: "length in seconds"),
    ]

    @StateObject private var viewModel = SettingsViewModel()
    @ObservedObject private var launchAtLogin = LaunchAtLoginManager.shared
    @Environment(\.dismiss) var dismiss
    @State private var isRecordingNewShortcut = false
    @State private var selectedTab: SettingsTab = .general
    /// The engine whose models are currently being *browsed* (navigation only — the active engine
    /// in `viewModel.selectedEngine` changes only when the user clicks a model).
    @State private var browseEngine: String = AppPreferences.shared.selectedEngine
    @State private var previousModelURL: URL?
    @State private var appLanguage = LanguageManager.selected
    @State private var langNeedsRelaunch = false
    @State private var cancelKey = "esc"

    /// Curated cancel-recording keys (the recorder can't capture Esc / single special keys).
    struct CancelKeyChoice: Identifiable {
        let id: String
        let label: String
        let shortcut: KeyboardShortcuts.Shortcut
    }
    static let cancelKeyChoices: [CancelKeyChoice] = [
        .init(id: "esc", label: "Esc", shortcut: .init(.escape)),
        .init(id: "cmd-esc", label: "⌘ Esc", shortcut: .init(.escape, modifiers: .command)),
        .init(id: "opt-esc", label: "⌥ Esc", shortcut: .init(.escape, modifiers: .option)),
        .init(id: "ctrl-esc", label: "⌃ Esc", shortcut: .init(.escape, modifiers: .control)),
        .init(id: "cmd-period", label: "⌘ .", shortcut: .init(.period, modifiers: .command)),
    ]
    static func currentCancelKeyID() -> String {
        let current = KeyboardShortcuts.getShortcut(for: .escape)
        return cancelKeyChoices.first { $0.shortcut == current }?.id ?? "esc"
    }

    /// One-line description of the selected engine, to help users choose.
    /// Engine → display name for the "active engine" indicator.
    private func engineDisplayName(_ engine: String) -> String {
        switch engine {
        case "fluidaudio": return "Parakeet"
        case "whisper": return "Whisper"
        case "sensevoice": return "SenseVoice"
        case "groq": return "Groq"
        default: return engine
        }
    }

    /// Short engine name (no model/language suffix) for compact controls.
    private func engineShortName(_ engine: String) -> String {
        switch engine {
        case "fluidaudio": return "Parakeet"
        case "whisper": return "Whisper"
        case "sensevoice": return "SenseVoice"
        case "groq": return "Groq"
        default: return engine
        }
    }

    private func engineBlurb(for engine: String) -> LocalizedStringKey {
        switch engine {
        case "whisper":
            return "Most accurate, ~99 languages, and can translate to English. Runs fully on-device."
        case "sensevoice":
            return "Fast — Chinese, Cantonese, English, Japanese, Korean. Runs fully on-device."
        case "groq":
            return "Cloud — extremely fast whisper-large-v3. ⚠️ Audio is sent to Groq's servers (NOT on-device). Needs a free API key."
        default:
            return "Fast, multilingual (25 languages), with a live preview as you speak. Runs fully on-device."
        }
    }

    /// Content for the currently-selected sidebar tab.
    @ViewBuilder private var detailContent: some View {
        switch selectedTab {
        case .general:       shortcutSettings
        case .model:         modelSettings
        case .transcription: transcriptionSettings
        case .history:       storageSettings
        case .advanced:      advancedSettings
        case .updates:       UpdatesView()
        case .feedback:      feedbackSettings
        }
    }

    /// "Feedback" tab — recruit beta testers and route every kind of report (#beta).
    private var feedbackSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Help us improve")
                        .font(.title2).bold()
                    Text("OpenSuperWhisper gets better with your feedback. Hit a bug, or have an idea? Tell us — every report helps make it more stable.")
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                feedbackLink(
                    title: "Report a bug",
                    subtitle: "On GitHub — steps to reproduce, your macOS version & engine, logs if you have them",
                    icon: "ladybug",
                    url: "https://github.com/my-monkeys/OpenSuperWhisper/issues/new")
                feedbackLink(
                    title: "Send feedback or an idea",
                    subtitle: "A quick form on opensuperwhisper.com — no account needed",
                    icon: "bubble.left.and.bubble.right",
                    url: "https://opensuperwhisper.com/#feedback")
                feedbackLink(
                    title: "Try a beta build",
                    subtitle: "Early features before they ship, on GitHub Releases",
                    icon: "testtube.2",
                    url: "https://github.com/my-monkeys/OpenSuperWhisper/releases")

                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func feedbackLink(title: String, subtitle: String, icon: String, url: String) -> some View {
        Button {
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(.accentColor)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption).foregroundColor(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.controlBackgroundColor))
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }

    /// One row in the left sidebar (drawer).
    private func sidebarRow(_ tab: SettingsTab) -> some View {
        Button {
            selectedTab = tab
        } label: {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 20, alignment: .center)
                Text(tab.title)
                    .font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .foregroundStyle(selectedTab == tab ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(selectedTab == tab ? Color.accentColor : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        HStack(spacing: 0) {
            // Vertical sidebar (drawer) listing the tabs — a plain stack so it
            // can never collapse the way a NavigationSplitView sidebar does.
            VStack(alignment: .leading, spacing: 3) {
                ForEach(SettingsTab.allCases) { tab in
                    sidebarRow(tab)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(width: 212)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(.regularMaterial)

            Divider()

            VStack(spacing: 0) {
                detailContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                Divider()

                // Footer lives inside the detail column so it never runs under the sidebar.
                HStack {
                    Link(destination: URL(string: "https://github.com/my-monkeys/OpenSuperWhisper")!) {
                        HStack(spacing: 4) {
                            Image(systemName: "star")
                                .font(.system(size: 10))
                            Text("GitHub")
                                .font(.system(size: 11))
                        }
                        .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    Button("Done") {
                        if viewModel.selectedEngine == "whisper" {
                            if viewModel.selectedModelURL != previousModelURL, let modelPath = viewModel.selectedModelURL?.path {
                                TranscriptionService.shared.reloadModel(with: modelPath)
                            }
                        }
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
                .padding()
                .background(Color(.windowBackgroundColor))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.windowBackgroundColor))
        }
        .frame(minWidth: 720, idealWidth: 780, minHeight: 540, idealHeight: 600)
        .onAppear {
            previousModelURL = viewModel.selectedModelURL
            launchAtLogin.refresh()
            if viewModel.selectedEngine == "fluidaudio" {
                viewModel.initializeFluidAudioModels()
            }
        }
        .onChange(of: viewModel.selectedEngine) { _, newEngine in
            if newEngine == "fluidaudio" {
                viewModel.initializeFluidAudioModels()
            }
        }
        .onChange(of: viewModel.fluidAudioModelVersion) { _, _ in
            Task { @MainActor in
                TranscriptionService.shared.reloadEngine()
            }
        }
        .onChange(of: viewModel.selectedModelURL) { _, newURL in
            if viewModel.selectedEngine == "whisper", let modelPath = newURL?.path {
                Task { @MainActor in
                    TranscriptionService.shared.reloadModel(with: modelPath)
                }
            }
        }
    }
    
    private var modelSettings: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Speech Recognition Engine")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    // Active engine + model — right under the title, always visible while browsing.
                    Label("Active: \(engineDisplayName(viewModel.selectedEngine))",
                          systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.green)

                    // Centered Parakeet / Whisper / Autre. "Autre" reveals an engine dropdown below.
                    HStack {
                        Spacer()
                        Picker("", selection: Binding(
                            get: { ["fluidaudio", "whisper"].contains(browseEngine) ? browseEngine : "other" },
                            set: { newValue in
                                if newValue == "other" {
                                    if !["sensevoice", "groq"].contains(browseEngine) {
#if arch(arm64)
                                        browseEngine = "sensevoice"
#else
                                        browseEngine = "groq"
#endif
                                    }
                                } else {
                                    browseEngine = newValue
                                }
                            }
                        )) {
                            Text("Parakeet").tag("fluidaudio")
                            Text("Whisper").tag("whisper")
                            Text("Autre").tag("other")
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                        Spacer()
                    }
                    .padding(.top, 4)

                    if !["fluidaudio", "whisper"].contains(browseEngine) {
                        HStack {
                            Text("Engine:").foregroundColor(.secondary)
                            Picker("", selection: $browseEngine) {
#if arch(arm64)
                                Text("SenseVoice").tag("sensevoice")
#endif
                                Text("Groq").tag("groq")
                            }
                            .pickerStyle(.menu)
                            .fixedSize()
                            Spacer()
                        }
                        .padding(.top, 4)
                    }


                    Text(engineBlurb(for: browseEngine))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 8)

#if arch(arm64)
                    if browseEngine == "sensevoice" {
                        SenseVoiceModelSection(viewModel: viewModel)
                    }
#endif
                    if browseEngine == "groq" {
                        GroqSettingsSection(viewModel: viewModel)
                    }

                    if browseEngine == "whisper" {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Whisper Model")
                                .font(.headline)
                                .foregroundColor(.primary)
                            
                            ScrollView {
                                VStack(spacing: 12) {
                                    ForEach($viewModel.downloadableModels) { $model in
                                        ModelDownloadItemView(model: $model, viewModel: viewModel)
                                    }
                                }
                            }
                            .frame(maxHeight: 200)
                            
                            if viewModel.isDownloading {
                                VStack(spacing: 8) {
                                    HStack {
                                        if viewModel.downloadProgress > 0 {
                                            ProgressView(value: viewModel.downloadProgress)
                                                .progressViewStyle(LinearProgressViewStyle())
                                        } else {
                                            ProgressView()
                                                .progressViewStyle(CircularProgressViewStyle())
                                        }
                                        
                                        Spacer()
                                        
                                        Button("Cancel") {
                                            viewModel.cancelDownload()
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                    
                                    if let downloadingName = viewModel.downloadingModelName {
                                        Text("Downloading: \(downloadingName)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.top, 8)
                            }
                            
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Models Directory:")
                                        .font(.subheadline)
                                    Button(action: {
                                        NSWorkspace.shared.open(WhisperModelManager.shared.modelsDirectory)
                                    }) {
                                        Label("Open Folder", systemImage: "folder")
                                            .font(.subheadline)
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Open models directory")
                                }
                                Text(WhisperModelManager.shared.modelsDirectory.path)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .textSelection(.enabled)
                                    .padding(8)
                                    .background(Color(.textBackgroundColor).opacity(0.5))
                                    .cornerRadius(6)
                            }
                            .padding(.top, 8)
                        }
                    } else if browseEngine == "fluidaudio" {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Parakeet Model")
                                .font(.headline)
                                .foregroundColor(.primary)
                            
                            ScrollView {
                                VStack(spacing: 12) {
                                    ForEach($viewModel.downloadableFluidAudioModels) { $model in
                                        FluidAudioModelDownloadItemView(model: $model, viewModel: viewModel)
                                    }
                                }
                            }
                            .frame(maxHeight: 200)
                            
                            if viewModel.isDownloading {
                                VStack(spacing: 8) {
                                    HStack {
                                        if viewModel.downloadProgress > 0 {
                                            ProgressView(value: viewModel.downloadProgress)
                                                .progressViewStyle(LinearProgressViewStyle())
                                        } else {
                                            ProgressView()
                                                .progressViewStyle(CircularProgressViewStyle())
                                        }
                                        
                                        Spacer()
                                        
                                        Button("Cancel") {
                                            viewModel.cancelDownload()
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                    
                                    if let downloadingName = viewModel.downloadingModelName {
                                        Text("Downloading: \(downloadingName)")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .padding(.top, 8)
                            }
                            
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Models Directory:")
                                        .font(.subheadline)
                                    Button(action: {
                                        let cacheDir = AsrModels.defaultCacheDirectory(for: .v3)
                                        let parentDir = cacheDir.deletingLastPathComponent()
                                        NSWorkspace.shared.open(parentDir)
                                    }) {
                                        Label("Open Folder", systemImage: "folder")
                                            .font(.subheadline)
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Open models directory")
                                }
                                Text(AsrModels.defaultCacheDirectory(for: .v3).deletingLastPathComponent().path)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .textSelection(.enabled)
                                    .padding(8)
                                    .background(Color(.textBackgroundColor).opacity(0.5))
                                    .cornerRadius(6)
                            }
                            .padding(.top, 8)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
            }
        }
        .padding()
    }
    
    private var transcriptionSettings: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Language Settings
                VStack(alignment: .leading, spacing: 16) {
                    Text("Language Settings")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Transcription Language")
                            .font(.subheadline)
                        
                        Picker("Language", selection: $viewModel.selectedLanguage) {
                            ForEach(viewModel.supportedLanguages, id: \.self) { code in
                                Text(LanguageUtil.languageNames[code] ?? code)
                                    .tag(code)
                            }
                        }
                        // Recreate the picker when the engine's language set changes, so its
                        // selection never gets stuck blank on a value that left the list; and
                        // clamp the stored language to a supported one when this view appears.
                        .id(viewModel.supportedLanguages)
                        .onAppear { viewModel.clampLanguageToSupported() }
                        .pickerStyle(.menu)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(.controlBackgroundColor))
                        .cornerRadius(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("Translate to English")
                                    .font(.subheadline)
                                    .foregroundColor(viewModel.canTranslate ? .primary : .secondary)
                                Spacer()
                                Toggle("", isOn: $viewModel.translateToEnglish)
                                    .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                    .labelsHidden()
                                    .disabled(!viewModel.canTranslate)
                            }
                            if !viewModel.canTranslate {
                                Text("Only Whisper and Groq (large-v3) translate; the current engine ignores this.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.top, 4)
                        
                        if Settings.asianLanguages.contains(viewModel.selectedLanguage) {
                            HStack {
                                Text("Use Asian Autocorrect")
                                    .font(.subheadline)
                                Spacer()
                                Toggle("", isOn: $viewModel.useAsianAutocorrect)
                                    .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                    .labelsHidden()
                            }
                            .padding(.top, 4)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                
                // Output Options
                VStack(alignment: .leading, spacing: 16) {
                    Text("Output Options")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Show Timestamps")
                                .font(.subheadline)
                            Spacer()
                            Toggle("", isOn: $viewModel.showTimestamps)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                        }
                        
                        HStack {
                            Text("Suppress Blank Audio")
                                .font(.subheadline)
                            Spacer()
                            Toggle("", isOn: $viewModel.suppressBlankAudio)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                        }
                        
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Add Space After Sentence")
                                    .font(.subheadline)
                                Text("Appends a space when transcription ends with punctuation")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $viewModel.addSpaceAfterSentence)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)

                // Filler Words
                VStack(alignment: .leading, spacing: 16) {
                    Text("Filler Words")
                        .font(.headline)
                        .foregroundColor(.primary)

                    SettingRow(
                        title: "Remove filler words",
                        caption: "Strip um, uh, er… from transcriptions before inserting.",
                        info: "Removes matches of the regex below (case-insensitive) from the transcription, then tidies the spacing. Off by default; the inserted text is otherwise unchanged."
                    ) {
                        Toggle("", isOn: $viewModel.removeFillerWords)
                            .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                            .labelsHidden()
                    }

                    if viewModel.removeFillerWords {
                        TextEditor(text: $viewModel.fillerWordsPattern)
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 56)
                            .padding(6)
                            .background(Color(.textBackgroundColor))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                            )
                        Text("Case-insensitive regex of filler words to remove.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)

                // AI Cleanup
                VStack(alignment: .leading, spacing: 16) {
                    Text("AI Cleanup")
                        .font(.headline)
                        .foregroundColor(.primary)

                    SettingRow(
                        title: "Clean up with a local LLM (Ollama)",
                        caption: "Fix punctuation & obvious errors via a local model after transcribing.",
                        info: "Sends the transcription to your local Ollama server and inserts the cleaned-up result. Requires Ollama running with the model below pulled (e.g. `ollama pull llama3.2`). Adds a little latency. If Ollama isn't reachable, the raw transcription is used unchanged — nothing is lost. Everything stays on your machine."
                    ) {
                        Toggle("", isOn: $viewModel.aiPostProcessingEnabled)
                            .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                            .labelsHidden()
                    }

                    if viewModel.aiPostProcessingEnabled {
                        HStack {
                            Text("Model")
                                .font(.subheadline)
                            Spacer()
                            TextField("llama3.2", text: $viewModel.aiOllamaModel)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 180)
                        }
                        HStack {
                            Text("Ollama endpoint")
                                .font(.subheadline)
                            Spacer()
                            TextField("http://localhost:11434", text: $viewModel.aiOllamaEndpoint)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 220)
                            Button {
                                viewModel.testOllamaConnection()
                            } label: {
                                Image(systemName: "bolt.horizontal.circle")
                            }
                            .buttonStyle(.plain)
                            .help("Test the connection to Ollama")
                        }

                        HStack(spacing: 8) {
                            Button("Test connection") { viewModel.testOllamaConnection() }
                                .controlSize(.small)

                            switch viewModel.ollamaStatus {
                            case .unknown:
                                EmptyView()
                            case .checking:
                                ProgressView().controlSize(.small)
                                Text("Checking…").font(.caption).foregroundColor(.secondary)
                            case .ok:
                                Label("Connected — model ready", systemImage: "checkmark.circle.fill")
                                    .font(.caption).foregroundColor(.green)
                            case .modelMissing(let model):
                                Label("Reachable, but “\(model)” isn't pulled — run: ollama pull \(model)",
                                      systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption).foregroundColor(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            case .unreachable:
                                Label("Can't reach Ollama — is it running? (ollama serve)",
                                      systemImage: "xmark.circle.fill")
                                    .font(.caption).foregroundColor(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Instruction")
                                .font(.subheadline)
                            TextEditor(text: $viewModel.aiPostProcessingPrompt)
                                .font(.system(.caption, design: .monospaced))
                                .frame(height: 80)
                                .padding(6)
                                .background(Color(.textBackgroundColor))
                                .cornerRadius(8)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                                )
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)

                // Clipboard & Paste
                VStack(alignment: .leading, spacing: 16) {
                    Text("Clipboard & Paste")
                        .font(.headline)
                        .foregroundColor(.primary)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Copy to Clipboard")
                                    .font(.subheadline)
                                Text("Also place the transcription on the clipboard")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $viewModel.autoCopyToClipboard)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                        }

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Auto-paste Transcription")
                                    .font(.subheadline)
                                Text("Type the transcription into the focused app")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $viewModel.autoPasteTranscription)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                        }

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Paste instead of typing")
                                    .font(.subheadline)
                                Text("Insert via ⌘V — works in apps that ignore synthetic typing (Messages, Electron…); uses the clipboard")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $viewModel.pasteInsteadOfTyping)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                        }

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Notify When No Paste Target")
                                    .font(.subheadline)
                                Text("Show a “copied — press ⌘V” notice if no editable field is focused")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $viewModel.notifyWhenNoPasteTarget)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                        }

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Submit on “press enter”")
                                    .font(.subheadline)
                                Text("Saying “press enter” at the end removes it from the text and presses Return — submitting in Claude Code, Slack, etc.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $viewModel.submitOnVoiceCommand)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)

                // Initial Prompt
                VStack(alignment: .leading, spacing: 16) {
                    Text("Initial Prompt")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        TextEditor(text: $viewModel.initialPrompt)
                            .frame(height: 60)
                            .padding(6)
                            .background(Color(.textBackgroundColor))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                            )
                        
                        Text("Optional text to guide the model's transcription")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)

                // Custom Dictionary
                customDictionarySection
            }
            .padding()
        }
    }
    
    private var customDictionarySection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Custom Dictionary")
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
                Toggle("", isOn: $viewModel.customDictionaryEnabled)
                    .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                    .labelsHidden()
            }

            Text("Replace recognized words with a preferred spelling. Matching is case-insensitive and limited to whole words. With Whisper, the replacements are also used to bias recognition.")
                .font(.caption)
                .foregroundColor(.secondary)

            if viewModel.customDictionaryEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Heard")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Replace with")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        // Spacer matching the delete button width.
                        Color.clear.frame(width: 24, height: 1)
                    }

                    if viewModel.customDictionaryEntries.isEmpty {
                        Text("No words yet. Add one below.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.vertical, 4)
                    }

                    ForEach($viewModel.customDictionaryEntries) { $entry in
                        HStack(spacing: 8) {
                            TextField("Heard word", text: $entry.original, prompt: Text("git hub"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: .infinity)
                            TextField("Preferred spelling", text: $entry.replacement, prompt: Text("GitHub"))
                                .labelsHidden()
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: .infinity)
                            Button(action: {
                                viewModel.customDictionaryEntries.removeAll { $0.id == entry.id }
                            }) {
                                Image(systemName: "trash")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Remove this entry")
                            .frame(width: 24)
                        }
                    }

                    Button(action: {
                        viewModel.customDictionaryEntries.append(CustomDictionaryEntry())
                    }) {
                        Label("Add Word", systemImage: "plus.circle")
                            .font(.subheadline)
                    }
                    .buttonStyle(.borderless)
                    .padding(.top, 4)
                }
                .padding(.top, 4)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor).opacity(0.3))
        .cornerRadius(12)
    }

    private var storageSettings: some View {
        Form {
            VStack(spacing: 20) {
                // Maximum number of recordings
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Limit Number of Recordings")
                                .font(.headline)
                                .foregroundColor(.primary)
                            Text("Keep only the most recent recordings & transcriptions")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $viewModel.retentionMaxCountEnabled)
                            .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                            .labelsHidden()
                    }

                    if viewModel.retentionMaxCountEnabled {
                        HStack {
                            Text("Keep at most")
                                .font(.subheadline)
                            Spacer()
                            TextField("", value: $viewModel.retentionMaxCount, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 80)
                            Stepper("", value: $viewModel.retentionMaxCount, in: 1...100000)
                                .labelsHidden()
                            Text("recordings")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)

                // Maximum age
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Delete Old Recordings")
                                .font(.headline)
                                .foregroundColor(.primary)
                            Text("Automatically remove recordings older than the chosen age")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $viewModel.retentionMaxAgeEnabled)
                            .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                            .labelsHidden()
                    }

                    if viewModel.retentionMaxAgeEnabled {
                        HStack {
                            Text("Delete after")
                                .font(.subheadline)
                            Spacer()
                            TextField("", value: $viewModel.retentionMaxAgeValue, format: .number)
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .frame(width: 70)
                            Stepper("", value: $viewModel.retentionMaxAgeValue, in: 1...100000)
                                .labelsHidden()
                            Picker("", selection: $viewModel.retentionMaxAgeUnit) {
                                ForEach(RetentionUnit.allCases) { unit in
                                    Text(unit.displayName).tag(unit)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 110)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)

                Text("Both limits can be active at the same time. Cleanup runs automatically when you change these settings and after each new transcription, and the age limit is also re-checked periodically in the background. Recordings that are still being processed are never deleted.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Privacy
                VStack(alignment: .leading, spacing: 16) {
                    Text("Privacy")
                        .font(.headline)
                        .foregroundColor(.primary)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Save Transcription History")
                                .font(.subheadline)
                            Spacer()
                            Toggle("", isOn: $viewModel.saveTranscriptionHistory)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                        }

                        Text("When disabled, audio recordings and transcriptions are not saved to disk. Only the current transcription is kept in memory for pasting.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)

                // Transcriptions Directory
                VStack(alignment: .leading, spacing: 16) {
                    Text("Transcriptions Directory")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Directory:")
                                .font(.subheadline)
                            Spacer()
                            Button(action: {
                                NSWorkspace.shared.open(Recording.recordingsDirectory)
                            }) {
                                Label("Open Folder", systemImage: "folder")
                                    .font(.subheadline)
                            }
                            .buttonStyle(.borderless)
                            .help("Open transcriptions directory")
                        }
                        
                        Text(Recording.recordingsDirectory.path)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.textBackgroundColor).opacity(0.5))
                            .cornerRadius(6)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)

            }
            .padding()
        }
    }

    private var advancedSettings: some View {
        Form {
            VStack(spacing: 20) {
                // Decoding Strategy
                VStack(alignment: .leading, spacing: 16) {
                    Text("Decoding Strategy")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Use Beam Search")
                                .font(.subheadline)
                            Spacer()
                            Toggle("", isOn: $viewModel.useBeamSearch)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                                .help("Beam search can provide better results but is slower")
                        }
                        
                        if viewModel.useBeamSearch {
                            HStack {
                                Text("Beam Size:")
                                    .font(.subheadline)
                                Spacer()
                                Stepper("\(viewModel.beamSize)", value: $viewModel.beamSize, in: 1...10)
                                    .help("Number of beams to use in beam search")
                                    .frame(width: 120)
                            }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                
                // Model Parameters
                VStack(alignment: .leading, spacing: 16) {
                    Text("Model Parameters")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 14) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Temperature:")
                                    .font(.subheadline)
                                Spacer()
                                Text(String(format: "%.2f", viewModel.temperature))
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            
                            Slider(value: $viewModel.temperature, in: 0.0...1.0, step: 0.1)
                                .help("Higher values make the output more random")
                        }
                        
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("No Speech Threshold:")
                                    .font(.subheadline)
                                Spacer()
                                Text(String(format: "%.2f", viewModel.noSpeechThreshold))
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            
                            Slider(value: $viewModel.noSpeechThreshold, in: 0.0...1.0, step: 0.1)
                                .help("Threshold for detecting speech vs. silence")
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)

                // Post-Record Hook
                VStack(alignment: .leading, spacing: 16) {
                    Text("Post-Record Hook")
                        .font(.headline)
                        .foregroundColor(.primary)

                    SettingRow(
                        title: "Run a command after each transcription",
                        caption: "Launch your own script when a transcription completes.",
                        info: "Runs via /bin/sh -c after each successful transcription, in the background. Your command receives the data as environment variables — OSW_TEXT, OSW_AUDIO_PATH (when history is on), OSW_TIMESTAMP, OSW_DURATION — and a JSON object on stdin with the same fields. Example: echo \"$OSW_TEXT\" >> ~/dictations.txt"
                    ) {
                        Toggle("", isOn: $viewModel.postRecordHookEnabled)
                            .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                            .labelsHidden()
                    }

                    if viewModel.postRecordHookEnabled {
                        TextEditor(text: $viewModel.postRecordHookCommand)
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 56)
                            .padding(6)
                            .background(Color(.textBackgroundColor))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                            )

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Available in your command (also piped as JSON on stdin):")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            ForEach(Self.postRecordHookVariables, id: \.name) { variable in
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(variable.name)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.primary)
                                    Text("— \(variable.description)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)

                // Debug Options
                VStack(alignment: .leading, spacing: 16) {
                    Text("Debug Options")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    HStack {
                        Text("Debug Mode")
                            .font(.subheadline)
                        Spacer()
                        Toggle("", isOn: $viewModel.debugMode)
                            .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                            .labelsHidden()
                            .help("Enable additional logging and debugging information")
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
            }
            .padding()
        }
    }
    
    private var useModifierKey: Bool {
        viewModel.modifierOnlyHotkey != .none
    }
    
    private var shortcutSettings: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Recording Trigger
                VStack(alignment: .leading, spacing: 16) {
                    Text("Recording Trigger")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 16) {
                        Picker("", selection: Binding(
                            get: { useModifierKey },
                            set: { newValue in
                                if !newValue {
                                    viewModel.modifierOnlyHotkey = .none
                                } else if viewModel.modifierOnlyHotkey == .none {
                                    viewModel.modifierOnlyHotkey = .leftCommand
                                }
                            }
                        )) {
                            Text("Key Combination").tag(false)
                            Text("Single Modifier Key").tag(true)
                        }
                        .pickerStyle(.segmented)
                        
                        if useModifierKey {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Modifier Key")
                                        .font(.subheadline)
                                    Spacer()
                                    Picker("", selection: $viewModel.modifierOnlyHotkey) {
                                        ForEach(ModifierKey.allCases.filter { $0 != .none }) { key in
                                            Text(key.displayName).tag(key)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .frame(width: 200)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color(.textBackgroundColor).opacity(0.5))
                                .cornerRadius(8)
                                
                                Text("One-tap to toggle recording")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                Text("⚠️ This mode requires Input Monitoring permission. macOS requires this to detect single modifier key presses globally. Only modifier key events (⌘, ⌥, ⇧, ⌃, Fn) are monitored — no regular keystrokes are captured.")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 4)

                                Button("Open Input Monitoring Settings…") {
                                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                                .font(.caption)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Shortcut")
                                        .font(.subheadline)
                                    Spacer()
                                    KeyboardShortcuts.Recorder("", name: .toggleRecord)
                                        .frame(width: 150)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color(.textBackgroundColor).opacity(0.5))
                                .cornerRadius(8)
                                
                                if isRecordingNewShortcut {
                                    Text("Press your new shortcut combination...")
                                        .foregroundColor(.secondary)
                                        .font(.subheadline)
                                }
                            }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
                
                // Recording Behavior
                VStack(alignment: .leading, spacing: 16) {
                    Text("Recording Behavior")
                        .font(.headline)
                        .foregroundColor(.primary)

                    VStack(alignment: .leading, spacing: 12) {
                        SettingRow(
                            title: "Indicator position",
                            caption: "Where the recording indicator appears.",
                            info: "Near cursor (default) shows it just above your text caret. Top, Center or Bottom pin it to the middle of the screen instead."
                        ) {
                            HStack(spacing: 8) {
                                Picker("", selection: $viewModel.indicatorPosition) {
                                    Text("Near cursor").tag("cursor")
                                    Text("Notch").tag("notch")
                                    Text("Top").tag("top")
                                    Text("Center").tag("center")
                                    Text("Bottom").tag("bottom")
                                }
                                .labelsHidden()
                                .frame(width: 140)
                                Button("Preview") {
                                    IndicatorWindowManager.shared.preview()
                                }
                                .controlSize(.small)
                                .help("Briefly show the indicator at this position")
                            }
                        }

                        SettingRow(
                            title: "Cancel Shortcut",
                            caption: "Press while recording to discard it.",
                            info: "Press this key during recording to cancel and discard it without transcribing. Esc is the default; the ⌘/⌥/⌃ combos are there in case Esc conflicts with something else."
                        ) {
                            Picker("", selection: $cancelKey) {
                                ForEach(SettingsView.cancelKeyChoices) { choice in
                                    Text(choice.label).tag(choice.id)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 140)
                            .onChange(of: cancelKey) { _, id in
                                if let choice = SettingsView.cancelKeyChoices.first(where: { $0.id == id }) {
                                    KeyboardShortcuts.setShortcut(choice.shortcut, for: .escape)
                                }
                            }
                            .onAppear { cancelKey = SettingsView.currentCancelKeyID() }
                        }

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Hold to Record")
                                    .font(.subheadline)
                                Text("Hold the shortcut to record, release to stop")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $viewModel.holdToRecord)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                        }
                        
                        HStack {
                            Text("Play sound when recording starts")
                                .font(.subheadline)
                            Spacer()
                            Toggle("", isOn: $viewModel.playSoundOnRecordStart)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                                .help("Play a notification sound when recording begins")
                        }

                        SettingRow(
                            title: "Live transcription",
                            caption: "Preview your speech in the indicator as you talk (Parakeet only).",
                            info: "The text appears after a short delay and is a rough live preview — it may differ from the final result. The text that actually gets inserted always comes from the full, accurate transcription, not from this preview."
                        ) {
                            Toggle("", isOn: $viewModel.liveTranscriptionEnabled)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                                .disabled(viewModel.selectedEngine != "fluidaudio")
                                .help("Show the transcription live while recording (Parakeet only)")
                        }
                        .opacity(viewModel.selectedEngine == "fluidaudio" ? 1 : 0.5)

                        SettingRow(
                            title: "Pause media during recording",
                            caption: "Pause other apps' playback while recording, then resume.",
                            info: "macOS doesn't let the app detect what was playing, so if media was already paused it may start playing when you stop — if that bothers you, use the volume option below instead."
                        ) {
                            Toggle("", isOn: $viewModel.pauseMediaOnRecord)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                                .help("Automatically pause media playback when recording starts")
                        }

                        SettingRow(
                            title: "Lower system volume while recording",
                            caption: "Temporarily reduce the output volume, then restore it."
                        ) {
                            Toggle("", isOn: $viewModel.reduceVolumeOnRecord)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                                .help("Lower the system output volume while recording, then restore it")
                        }

                        if viewModel.reduceVolumeOnRecord {
                            HStack {
                                Text("Volume while recording")
                                    .font(.subheadline)
                                Spacer()
                                Slider(value: $viewModel.reduceVolumeLevel, in: 0...0.5)
                                    .frame(width: 160)
                                Text("\(Int((viewModel.reduceVolumeLevel * 100).rounded()))%")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .frame(width: 44, alignment: .trailing)
                            }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)

                // Startup
                VStack(alignment: .leading, spacing: 16) {
                    Text("Startup")
                        .font(.headline)
                        .foregroundColor(.primary)

                    SettingRow(
                        title: "Launch at Login",
                        caption: "Start OpenSuperWhisper automatically when you log in."
                    ) {
                        Toggle("", isOn: Binding(
                            get: { launchAtLogin.isEnabled },
                            set: { launchAtLogin.setEnabled($0) }
                        ))
                        .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                        .labelsHidden()
                    }

                    SettingRow(
                        title: "Start in the Menu Bar",
                        caption: "Launch without the main window — open it from the menu bar icon.",
                        info: "Launches straight into the menu bar with no window shown. Open the window anytime from the menu bar icon. Takes effect on next launch."
                    ) {
                        Toggle("", isOn: $viewModel.startHidden)
                            .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                            .labelsHidden()
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)

                // Interface Language
                VStack(alignment: .leading, spacing: 16) {
                    Text("Language")
                        .font(.headline)
                        .foregroundColor(.primary)

                    SettingRow(
                        title: "App Language",
                        caption: "Language of the app interface. Relaunch to apply.",
                        info: "Overrides your Mac's language for OpenSuperWhisper only. \"System\" follows your Mac's language. This is separate from the transcription language."
                    ) {
                        Picker("", selection: $appLanguage) {
                            Text("System").tag("system")
                            Text("English").tag("en")
                            Text("Français").tag("fr")
                            Text("Deutsch").tag("de")
                            Text("Español").tag("es")
                            Text("Italiano").tag("it")
                            Text("Português (BR)").tag("pt-BR")
                            Text("Tiếng Việt").tag("vi")
                        }
                        .pickerStyle(.menu)
                        .frame(width: 150)
                        .labelsHidden()
                        .onChange(of: appLanguage) { _, newValue in
                            LanguageManager.selected = newValue
                            langNeedsRelaunch = true
                        }
                    }

                    if langNeedsRelaunch {
                        HStack {
                            Text("Relaunch to apply the new language.")
                                .font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Button("Relaunch Now") { LanguageManager.relaunch() }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)
            }
            .padding()
        }
    }
}

struct SettingsFluidAudioModel: Identifiable {
    let id = UUID()
    let name: String
    let version: String
    var isDownloaded: Bool
    let description: String
    var size: Int = 0   // approximate download size, MB
    var downloadProgress: Double = 0.0

    var sizeString: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(size) * 1_000_000)
    }
}

struct SettingsFluidAudioModels {
    static let availableModels = [
        SettingsFluidAudioModel(
            name: "Parakeet v3",
            version: "v3",
            isDownloaded: false,
            description: "Multilingual, 25 languages",
            size: 461
        ),
        SettingsFluidAudioModel(
            name: "Parakeet v2",
            version: "v2",
            isDownloaded: false,
            description: "English-only, higher recall",
            size: 460
        )
    ]
}

enum OnboardingModelType {
    case whisper(url: URL, size: Int)
    case parakeet(version: String)
}

struct OnboardingUnifiedModel: Identifiable {
    let id = UUID()
    let name: String
    var isDownloaded: Bool
    let description: String
    let type: OnboardingModelType
    var downloadProgress: Double = 0.0
}

struct OnboardingUnifiedModels {
    static let availableModels = [
        OnboardingUnifiedModel(
            name: "Whisper V3 Large",
            isDownloaded: false,
            description: "High accuracy, best quality",
            type: .whisper(
                url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin?download=true")!,
                size: 1624
            )
        ),
        OnboardingUnifiedModel(
            name: "Parakeet v3",
            isDownloaded: false,
            description: "Fastest processing and accurate",
            type: .parakeet(version: "v3")
        ),
        OnboardingUnifiedModel(
            name: "Parakeet v2",
            isDownloaded: false,
            description: "Fastest processing and English-only, higher recall",
            type: .parakeet(version: "v2")
        ),
        OnboardingUnifiedModel(
            name: "Whisper Medium",
            isDownloaded: false,
            description: "Balanced speed and accuracy",
            type: .whisper(
                url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q8_0.bin?download=true")!,
                size: 874
            )
        ),
        OnboardingUnifiedModel(
            name: "Whisper Small",
            isDownloaded: false,
            description: "Very fast processing",
            type: .whisper(
                url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin?download=true")!,
                size: 574
            )
        )
    ]
}

struct FluidAudioModelDownloadItemView: View {
    @Binding var model: SettingsFluidAudioModel
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showError = false
    @State private var errorMessage = ""
    
    var isSelected: Bool {
        viewModel.fluidAudioModelVersion == model.version
    }

    /// The model actually used for transcription: selected *and* its engine is active.
    /// Only the active model shows the solid green check (resolves the two-checkmarks
    /// ambiguity of #139).
    var isActive: Bool {
        isSelected && viewModel.selectedEngine == "fluidaudio"
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(model.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    
                    if model.isDownloaded {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundColor(.blue)
                            .imageScale(.small)
                    }
                }
                
                HStack(spacing: 6) {
                    Text(model.description)
                    Text("·")
                    Text(model.sizeString)
                }
                .font(.caption)
                .foregroundColor(.secondary)

                if viewModel.isDownloading && viewModel.downloadingModelName == model.name {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .scaleEffect(0.7)
                        .padding(.top, 4)
                } else if model.downloadProgress > 0 && model.downloadProgress < 1 {
                    ProgressView(value: model.downloadProgress)
                        .progressViewStyle(LinearProgressViewStyle())
                        .frame(height: 6)
                        .padding(.top, 4)
                }
            }
            
            Spacer()
            
            if viewModel.isDownloading && viewModel.downloadingModelName == model.name {
                Button("Cancel") {
                    viewModel.cancelDownload()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if model.isDownloaded {
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .imageScale(.large)
                } else if isSelected {
                    // Chosen for this engine, but the engine isn't the active one.
                    Image(systemName: "checkmark.circle")
                        .foregroundColor(.secondary)
                        .imageScale(.large)
                } else {
                    Button(action: {
                        viewModel.fluidAudioModelVersion = model.version
                    }) {
                        Text("Select")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            } else {
                Button(action: {
                    Task {
                        do {
                            try await viewModel.downloadFluidAudioModel(model)
                        } catch is CancellationError {
                            // Don't show error for manual cancellation
                        } catch {
                            errorMessage = error.localizedDescription
                            showError = true
                        }
                    }
                }) {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.isDownloading)
            }
        }
        .padding(12)
        .background(isSelected ? Color(.controlBackgroundColor).opacity(0.7) : Color(.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture {
            // Activate on tap whenever this isn't already the *active* model — even if it's the
            // selected version but Parakeet isn't the active engine (browse ≠ select).
            if model.isDownloaded && !isActive {
                viewModel.fluidAudioModelVersion = model.version
            }
        }
        .alert("Download Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }
}

struct ModelDownloadItemView: View {
    @Binding var model: SettingsDownloadableModel
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showError = false
    @State private var errorMessage = ""
    
    var isSelected: Bool {
        if let selectedURL = viewModel.selectedModelURL {
            let filename = model.filename
            return selectedURL.lastPathComponent == filename
        }
        return false
    }

    /// The model actually used for transcription: selected *and* Whisper is the
    /// active engine. Only the active model shows the solid green check (#139).
    var isActive: Bool {
        isSelected && viewModel.selectedEngine == "whisper"
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(model.name)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    if model.isDownloaded {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundColor(.blue)
                            .imageScale(.small)
                    }
                }

                HStack(spacing: 6) {
                    Text(model.description)
                    Text("·")
                    Text(model.sizeString)
                }
                .font(.caption)
                .foregroundColor(.secondary)

                if model.downloadProgress > 0 && model.downloadProgress < 1 {
                    ProgressView(value: model.downloadProgress)
                        .progressViewStyle(LinearProgressViewStyle())
                        .frame(height: 6)
                        .padding(.top, 4)
                }
            }

            Spacer()

            if viewModel.isDownloading && viewModel.downloadingModelName == model.name {
                Button("Cancel") {
                    viewModel.cancelDownload()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if model.isDownloaded {
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .imageScale(.large)
                } else if isSelected {
                    // Chosen for Whisper, but Whisper isn't the active engine.
                    Image(systemName: "checkmark.circle")
                        .foregroundColor(.secondary)
                        .imageScale(.large)
                } else {
                    Button(action: {
                        let modelPath = WhisperModelManager.shared.modelsDirectory.appendingPathComponent(model.filename).path
                        viewModel.selectModel(URL(fileURLWithPath: modelPath))
                    }) {
                        Text("Select")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            } else {
                Button(action: {
                    Task {
                        do {
                            try await viewModel.downloadModel(model)
                        } catch is CancellationError {
                            // Don't show error for manual cancellation
                        } catch {
                            errorMessage = error.localizedDescription
                            showError = true
                        }
                    }
                }) {
                    Label("Download", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.isDownloading)
            }
        }
        .padding(12)
        .background(isSelected ? Color(.controlBackgroundColor).opacity(0.7) : Color(.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture {
            // Activate on tap whenever this isn't the active model (works even if it's the selected
            // file but Whisper isn't the active engine).
            if model.isDownloaded && !isActive {
                let modelPath = WhisperModelManager.shared.modelsDirectory.appendingPathComponent(model.filename).path
                viewModel.selectModel(URL(fileURLWithPath: modelPath))
            }
        }
        .alert("Download Error", isPresented: $showError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage)
        }
    }
}

