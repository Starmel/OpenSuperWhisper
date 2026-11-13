import AppKit
import Carbon
import Combine
import Foundation
import KeyboardShortcuts
import SwiftUI
import FluidAudio

@MainActor
class SettingsViewModel: ObservableObject {
    @Published var selectedEngine: String {
        didSet {
            AppPreferences.shared.selectedEngine = selectedEngine
            if selectedEngine == "whisper" {
                loadAvailableModels()
            } else if selectedEngine == Qwen3ASREngine.engineID {
                initializeQwen3ASRModels()
            } else {
                initializeFluidAudioModels()
            }
            Task { @MainActor in
                TranscriptionService.shared.reloadEngine()
            }
        }
    }
    
    @Published var fluidAudioModelVersion: String {
        didSet {
            AppPreferences.shared.fluidAudioModelVersion = fluidAudioModelVersion
            if selectedEngine == "fluidaudio" {
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

    /// User-initiated model selection. Persists the model; the transcription
    /// language is not a setting any more, so there is nothing else to switch.
    func selectModel(_ url: URL) {
        selectedModelURL = url
    }

    @Published var availableModels: [URL] = []
    
    @Published var downloadableModels: [SettingsDownloadableModel] = []
    @Published var downloadableFluidAudioModels: [SettingsFluidAudioModel] = []
    @Published var isDownloading: Bool = false
    @Published var downloadProgress: Double = 0.0
    @Published var downloadingModelName: String?
    private var downloadTask: Task<Void, Error>?
    private var downloadID: UUID?
    
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
    
    /// "Speech-Only Filter (VAD)". Off by default; the measurement behind that
    /// is in `AppPreferences.useVAD`.
    @Published var useVAD: Bool {
        didSet {
            AppPreferences.shared.useVAD = useVAD
        }
    }
    
    @Published var longPausesEndSentences: Bool {
        didSet {
            AppPreferences.shared.longPausesEndSentences = longPausesEndSentences
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
    
    @Published var useAsianAutocorrect: Bool {
        didSet {
            AppPreferences.shared.useAsianAutocorrect = useAsianAutocorrect
        }
    }
    
    @Published var modifierOnlyHotkey: ModifierKey {
        didSet {
            AppPreferences.shared.modifierOnlyHotkey = modifierOnlyHotkey.rawValue
            if modifierOnlyHotkey != .none {
                AppPreferences.shared.lastModifierOnlyHotkey = modifierOnlyHotkey.rawValue
            }
            NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
        }
    }

    @Published var mouseButtonHotkey: MouseButton {
        didSet {
            AppPreferences.shared.mouseButtonHotkey = mouseButtonHotkey.rawValue
            NotificationCenter.default.post(name: .hotkeySettingsChanged, object: nil)
        }
    }
    
    @Published var holdToRecord: Bool {
        didSet {
            AppPreferences.shared.holdToRecord = holdToRecord
        }
    }
    
    @Published var escCancelWithoutConfirmation: Bool {
        didSet {
            AppPreferences.shared.escCancelWithoutConfirmation = escCancelWithoutConfirmation
        }
    }

    @Published var startHiddenInMenuBar: Bool {
        didSet {
            AppPreferences.shared.startHiddenInMenuBar = startHiddenInMenuBar
        }
    }
    
    @Published var addSpaceAfterSentence: Bool {
        didSet {
            AppPreferences.shared.addSpaceAfterSentence = addSpaceAfterSentence
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

    /// Which mechanism delivers a dictation. Read per dictation, so changing it
    /// takes effect on the next one.
    @Published var deliveryPreference: DeliveryPreference {
        didSet {
            AppPreferences.shared.deliveryPreference = deliveryPreference
        }
    }

    /// Whether a vendor-prefix match alone is enough to paste. Off by default:
    /// that half of the target rule is a judgement, so it is the user's to make.
    @Published var pasteIntoRecognisedVendors: Bool {
        didSet {
            AppPreferences.shared.pasteIntoRecognisedVendors = pasteIntoRecognisedVendors
        }
    }

    @Published var toneEnabled: Bool {
        didSet {
            AppPreferences.shared.toneEnabled = toneEnabled
        }
    }

    @Published var transformToneMode: ToneMode {
        didSet {
            AppPreferences.shared.transformToneMode = transformToneMode
        }
    }

    /// The clean-up pass: the filler/stutter scrub plus the grammar repair folded
    /// into the transform call. Read per dictation, so flipping it takes effect
    /// on the next one.
    @Published var cleanUpEnabled: Bool {
        didSet {
            AppPreferences.shared.cleanUpEnabled = cleanUpEnabled
        }
    }

    /// Names, jargon and domain terms fed into the transform prompt. Empty means
    /// no reference block at all.
    @Published var transformReference: String {
        didSet {
            AppPreferences.shared.transformReference = transformReference
        }
    }

    // MARK: - Built-in transform models

    /// The catalogue ids whose weights verify on disk. Both are checked, because
    /// either can be the one a dictation runs on.
    @Published var installedTransformModelIDs: Set<String> = []
    @Published var transformModelDownloadProgress: Double = 0
    @Published var transformModelError: String?
    /// The model whose download is in flight, so only its row shows the
    /// progress and the Cancel button.
    @Published var downloadingTransformModelID: String?

    private var transformDownloadTask: Task<Void, Never>?

    /// The manager the card reads installed state from and downloads through.
    /// Injecting it is how a test proves the card's words against a real
    /// directory layout — the app's own, or one a test stages — instead of
    /// against the user's Application Support.
    let transformModelManager: TransformModelManager

    /// The catalogue. Two rows, two jobs: S1-mini for English clean-up, the
    /// instruction model for tone and the e-mail mode in both languages.
    var transformModels: [TransformModel] { TransformModelManager.availableModels }

    /// The English clean-up backend — S1-mini, the smaller of the two. The only
    /// model a clean-up-alone dictation in English runs on, and the only one
    /// that cannot be instructed.
    var transformModel: TransformModel {
        transformModelManager.normalizerModel
    }

    /// The tone and e-mail backend — the instruction model, the larger of the
    /// two. Every tone rewrite, and the spoken e-mail trigger, runs on it, in
    /// Polish and English alike; it never does an English clean-up by itself.
    var toneTransformModel: TransformModel {
        transformModelManager.toneModel
    }

    func isTransformModelInstalled(_ model: TransformModel) -> Bool {
        installedTransformModelIDs.contains(model.id)
    }

    func isDownloading(_ model: TransformModel) -> Bool {
        downloadingTransformModelID == model.id
    }

    /// What the row's model is and what it does for the app, in the app's own
    /// routing words.
    ///
    /// The row's title is the model's own name, so this says what that name is
    /// for — and what the model *is*, which is the difference the two rows turn
    /// on: one normalizer that cannot be instructed and reads English only, and
    /// one instruction follower that reads both languages. What each row leaves
    /// to the other is stated rather than implied, because a missing file now
    /// costs one job, not the whole transform.
    func transformModelRoleDescription(_ model: TransformModel) -> String {
        switch model.style {
        case .normalizer:
            return "The English clean-up backend. English clean-up alone runs on it, and nothing else "
                + "does: a 0.6B normalizer trained on exactly this job — raw transcript in, clean "
                + "written text out — and not an instruction follower, so it cannot be told what to do. "
                + "It takes one fixed prompt and a control line, which is why the reference list above "
                + "does not reach it, and it reads English only. Its clean-up line repairs punctuation, "
                + "casing, articles and word order. Without this file English clean-up alone falls back "
                + "to the deterministic scrub — fillers gone, grammar untouched — and the dictation says "
                + "so; tone and e-mail run on the other model and keep working."
        case .instruction:
            return "The tone and e-mail backend. Every tone rewrite — Polish and English alike — and the "
                + "spoken e-mail mode run on it; English clean-up alone does not. It is an instruction "
                + "follower, so it takes the app's own prompt, which is where the reference list above "
                + "rides. It is roughly ten times the normalizer's size because it has to read both "
                + "languages and follow a register: tone was English-only until it existed. Without this "
                + "file a tone or e-mail rewrite is delivered as transcribed and the app says so; "
                + "English clean-up alone runs on the other model and keeps working."
        }
    }

    /// The card's opening paragraph: what the weights are, where they live, and
    /// what the two rows mean together.
    ///
    /// Two models, two jobs, so the question the rows cannot answer — what
    /// happens when one of them is absent? — is answered here, before them: each
    /// job needs its own file, and without it that job is delivered as
    /// transcribed (or, for clean-up, as the deterministic scrub) and says so.
    /// The costs are stated because they are the reason there are two rows
    /// rather than one.
    var transformModelsHeaderDescription: String {
        return "The app runs these itself, from its own folder, so uninstalling takes them with it. Two "
            + "models, two jobs. S1-mini by Superwhisper (462 MB, about 1 GB of memory) is the normalizer "
            + "English clean-up alone runs on — it cannot be instructed and reads English only. Qwen2.5 7B "
            + "Instruct (4.68 GB on disk, about 5.3 GB of memory while a rewrite runs — the engine's "
            + "accounting, not a wired measurement) is the instruction follower that rewrites tone and "
            + "e-mail in Polish and English. A weight file is a download, not a requirement: without the "
            + "missing file its job is delivered as transcribed and the app says so, and the other job "
            + "keeps working. No weight file ships inside the app. Each model is resident only while it is "
            + "being used — released after ten minutes without a transform — so only the model the last "
            + "rewrite needed costs memory."
    }

    /// What a row says about its model: download state, disk and RAM.
    func transformModelStateDescription(_ model: TransformModel) -> String {
        let cost = "\(model.sizeDescription) on disk, about \(model.memoryDescription) of RAM while loaded"
        if isDownloading(model) {
            return "Downloading \(model.sizeDescription)…"
        }
        return isTransformModelInstalled(model) ? "Installed — \(cost)" : "Not downloaded — \(cost)"
    }

    /// What is missing while `model` is absent, or `nil` when it is installed.
    ///
    /// Each model is a requirement for its own jobs and not for the other's: a
    /// missing normalizer costs English clean-up alone (the deterministic scrub
    /// still runs), a missing instruction model costs tone and e-mail. Saying
    /// which job stops is the point — a row that warned about "the transform"
    /// would over-report the loss.
    func transformMissingNotice(for model: TransformModel) -> String? {
        guard !isTransformModelInstalled(model) else { return nil }
        switch model.style {
        case .normalizer:
            return "Without it English clean-up alone cannot run: the grammar repair of a clean-up "
                + "dictation is this model's, so until it is downloaded that job is delivered as the "
                + "deterministic scrub's output — fillers gone, grammar untouched — and the dictation says "
                + "so. Tone and the e-mail mode run on the instruction model and do not need this file. "
                + "Download it here."
        case .instruction:
            return "Without it neither a tone rewrite nor the e-mail mode can run, in Polish or English: "
                + "both jobs run on this instruction model. Until it is downloaded a dictation with the "
                + "tone switch on is delivered as transcribed — the deterministic scrub still applies when "
                + "clean-up is on — and the app says so. Download it here."
        }
    }

    /// Which model each job will run on, and whether it is present.
    ///
    /// The job decides the model, so this names both: tone and e-mail in either
    /// language run on the instruction model, English clean-up alone runs on the
    /// normalizer, and each absence is reported against the job it costs rather
    /// than against a single "transform".
    var transformLanguageModelDescription: String {
        let cleanUpPresence = transformModelManager.isNormalizerInstalled
            ? "S1-mini is installed."
            : "S1-mini is not installed — download it below; until then English clean-up alone falls back "
                + "to the deterministic scrub, and the dictation says so."
        let tonePresence = isTransformModelInstalled(toneTransformModel)
            ? "\(toneTransformModel.displayName) is installed."
            : "\(toneTransformModel.displayName) is not installed — download it below; until then a tone "
                + "or e-mail rewrite is delivered as transcribed, and the app says so."
        return "Tone and the e-mail mode run on \(toneTransformModel.displayName), in Polish and English "
            + "alike; English clean-up alone runs on \(transformModel.displayName), the normalizer. "
            + cleanUpPresence + " " + tonePresence
    }

    /// Recomputes the installed state of every backend off the main thread: the
    /// first check of a hand-placed file hashes it, which is a 462 MB or a
    /// 4.68 GB read. The cached stamp means only that first check pays it.
    func refreshTransformModelState() {
        let catalogue = TransformModelManager.availableModels
        let manager = transformModelManager
        Task.detached(priority: .utility) { [weak self] in
            var installed: Set<String> = []
            for model in catalogue where manager.verifiedPath(for: model) != nil {
                installed.insert(model.id)
            }
            let verified = installed
            await MainActor.run { [weak self] in
                self?.installedTransformModelIDs = verified
            }
        }
    }

    /// Fetches one backend's weights, with the pinned digest the manager
    /// verifies before the file is installed.
    @MainActor
    func downloadTransformModel(_ model: TransformModel) async {
        guard downloadingTransformModelID == nil else { return }
        transformModelError = nil

        do {
            try DiskSpaceUtil.ensureEnoughFreeSpaceForModelDownload()
        } catch {
            transformModelError = error.localizedDescription
            return
        }

        downloadingTransformModelID = model.id
        transformModelDownloadProgress = 0
        defer {
            downloadingTransformModelID = nil
            transformModelDownloadProgress = 0
        }

        do {
            try await transformModelManager.download(model: model) { progress in
                Task { @MainActor [weak self] in
                    guard let self, self.downloadingTransformModelID == model.id else { return }
                    self.transformModelDownloadProgress = progress
                }
            }
            await MainActor.run { self.refreshTransformModelState() }
        } catch {
            transformModelError = error.localizedDescription
        }
    }

    @MainActor
    func cancelTransformModelDownload(_ model: TransformModel) {
        transformModelManager.cancelDownload(modelID: model.id)
    }

    /// Removes one backend's weights. The runtime lets go of that model first,
    /// so the memory is back before the file is.
    @MainActor
    func removeTransformModel(_ model: TransformModel) {
        transformModelError = nil
        do {
            TransformRuntime.shared.unloadIfResident(modelID: model.id)
            try transformModelManager.remove(model)
            refreshTransformModelState()
        } catch {
            transformModelError = error.localizedDescription
        }
    }

    private let downloadWhisper: (URL, String, @escaping (Double) -> Void) async throws -> Void

    private let downloadFluid: (AsrModelVersion, ProgressHandler?) async throws -> AsrModels

    init(downloadWhisper: @escaping (URL, String, @escaping (Double) -> Void) async throws -> Void = {
        try await WhisperModelManager.shared.downloadModel(url: $0, name: $1, progressCallback: $2)
    }, downloadFluid: @escaping (AsrModelVersion, ProgressHandler?) async throws -> AsrModels = {
        try await AsrModels.downloadAndLoad(version: $0, progressHandler: $1)
    }, transformModelManager: TransformModelManager = .shared,
       qwen3ASRModelManager: Qwen3ASRModelManager = .shared) {
        self.transformModelManager = transformModelManager
        self.qwen3ASRModelManager = qwen3ASRModelManager
        self.downloadFluid = downloadFluid
        self.downloadWhisper = downloadWhisper
        let prefs = AppPreferences.shared
        self.selectedEngine = prefs.selectedEngine
        self.fluidAudioModelVersion = prefs.fluidAudioModelVersion
        self.suppressBlankAudio = prefs.suppressBlankAudio
        self.showTimestamps = prefs.showTimestamps
        self.useVAD = prefs.useVAD
        self.longPausesEndSentences = prefs.longPausesEndSentences
        self.temperature = prefs.temperature
        self.noSpeechThreshold = prefs.noSpeechThreshold
        self.initialPrompt = prefs.initialPrompt
        self.useBeamSearch = prefs.useBeamSearch
        self.beamSize = prefs.beamSize
        self.debugMode = prefs.debugMode
        self.playSoundOnRecordStart = prefs.playSoundOnRecordStart
        self.useAsianAutocorrect = prefs.useAsianAutocorrect
        self.modifierOnlyHotkey = ModifierKey(rawValue: prefs.modifierOnlyHotkey) ?? .none
        self.mouseButtonHotkey = MouseButton(rawValue: prefs.mouseButtonHotkey) ?? .none
        self.holdToRecord = prefs.holdToRecord
        self.escCancelWithoutConfirmation = prefs.escCancelWithoutConfirmation
        self.startHiddenInMenuBar = prefs.startHiddenInMenuBar
        self.addSpaceAfterSentence = prefs.addSpaceAfterSentence
        self.autoCopyToClipboard = prefs.autoCopyToClipboard
        self.autoPasteTranscription = prefs.autoPasteTranscription
        self.deliveryPreference = prefs.deliveryPreference
        self.pasteIntoRecognisedVendors = prefs.pasteIntoRecognisedVendors
        self.toneEnabled = prefs.toneEnabled
        self.transformToneMode = prefs.transformToneMode
        self.cleanUpEnabled = prefs.cleanUpEnabled
        self.transformReference = prefs.transformReference

        if let savedPath = prefs.selectedWhisperModelPath ?? prefs.selectedModelPath {
            self.selectedModelURL = URL(fileURLWithPath: savedPath)
        }
        loadAvailableModels()
        initializeDownloadableModels()
        initializeFluidAudioModels()
        initializeQwen3ASRModels()
        refreshTransformModelState()
    }
    
    func initializeFluidAudioModels() {
        downloadableFluidAudioModels = SettingsFluidAudioModels.availableModels.map { model in
            var updatedModel = model
            updatedModel.isDownloaded = isFluidAudioModelDownloaded(version: model.version)
            return updatedModel
        }
    }
    
    func isFluidAudioModelDownloaded(version: String) -> Bool {
        let asrVersion = AsrModelVersion(storedParakeetVersion: version)
        
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
        refreshInstalledModels()
    }

    // MARK: - What is on disk (G-04, G-05, G-06, G-07)

    /// One model file in the models directory, catalogue entry or not.
    struct InstalledWhisperModel: Identifiable, Equatable {
        let url: URL
        let name: String
        let sizeBytes: Int64
        let isSelected: Bool
        /// Set when the catalogue knows this file: it is then also the digest the
        /// publisher reports, which is what `Verify` compares against.
        let pinnedSHA256: String?

        var id: String { url.path }
        var sizeDescription: String {
            ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        }
        var catalogueName: String? {
            SettingsDownloadableModels.availableModels.first { $0.filename == name }?.name
        }
    }

    @Published var installedWhisperModels: [InstalledWhisperModel] = []
    /// The last thing that happened to the models on disk, as the Model tab says it.
    @Published var modelStorageNotice: ModelStorageNotice?
    /// What the last check said, per checked path, in the words the row shows.
    @Published var checkSummaries: [String: String] = [:]
    /// Paths whose check found something wrong, so the row can say so loudly.
    @Published var checkProblems: Set<String> = []
    /// The path currently being checked, if any.
    @Published var checkingPath: String?
    /// The typed result of the last whisper-file check, for callers that want
    /// more than the sentence (the digest, and whether it matched).
    @Published var verificationResults: [String: ModelVerification] = [:]
    @Published var verificationError: String?

    /// Every model file on disk, selected one marked, catalogue digests attached.
    func refreshInstalledModels() {
        let manager = WhisperModelManager.shared
        let selectedPath = selectedModelURL?.path
        installedWhisperModels = manager.getAvailableModels().map { url in
            InstalledWhisperModel(url: url,
                                  name: url.lastPathComponent,
                                  sizeBytes: manager.fileSize(at: url),
                                  isSelected: selectedPath.map { WhisperModelManager.isSameFile(url.path, $0) } ?? false,
                                  pinnedSHA256: SettingsDownloadableModels.pinnedSHA256(forFilename: url.lastPathComponent))
        }
        modelStorageNotice = manager.lastNotice
    }

    /// How the Model tab names the model in use.
    var selectedModelDescription: String {
        guard let selectedModelURL else {
            return installedWhisperModels.isEmpty ? "none — no model file is on disk" : "none"
        }
        return selectedModelURL.lastPathComponent
    }

    /// Deletes a model file and updates everything that described it.
    func removeInstalledModel(_ model: InstalledWhisperModel) {
        do {
            modelStorageNotice = try WhisperModelManager.shared.removeModel(at: model.url)
        } catch {
            verificationError = error.localizedDescription
            return
        }
        verificationResults[model.url.path] = nil
        checkSummaries[model.url.path] = nil
        checkProblems.remove(model.url.path)
        loadAvailableModels()
        if selectedModelURL?.path != model.url.path,
           let reloadPath = selectedModelURL?.path {
            Task { @MainActor in
                TranscriptionService.shared.reloadModel(with: reloadPath)
            }
        }
    }

    /// Removes a catalogue row's downloaded file by name.
    func removeDownloadedModel(named filename: String) {
        let url = WhisperModelManager.shared.modelsDirectory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            modelStorageNotice = try WhisperModelManager.shared.removeModel(at: url)
        } catch {
            verificationError = error.localizedDescription
            return
        }
        verificationResults[url.path] = nil
        checkSummaries[url.path] = nil
        checkProblems.remove(url.path)
        loadAvailableModels()
    }

    /// Checks a model file against the digest the catalogue pins for it. The
    /// digest of a 1.6 GB file takes seconds, so it runs off the main thread.
    func verifyModel(at url: URL, pinnedSHA256: String?) {
        guard checkingPath == nil else { return }
        checkingPath = url.path
        verificationError = nil
        Task.detached(priority: .userInitiated) { [pinnedSHA256] in
            let outcome = Result { try WhisperModelManager.shared.verifyModel(at: url, pinnedSHA256: pinnedSHA256) }
            await MainActor.run {
                self.checkingPath = nil
                switch outcome {
                case .success(let verification):
                    self.verificationResults[url.path] = verification
                    self.checkSummaries[url.path] = verification.summary
                    if verification.matchesPinnedDigest == false { self.checkProblems.insert(url.path) }
                    else { self.checkProblems.remove(url.path) }
                case .failure(let error):
                    self.verificationError = "\(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }
    }

    func verification(for url: URL) -> ModelVerification? {
        verificationResults[url.path]
    }

    /// Checks a Parakeet model's files: FluidAudio publishes no digest for them,
    /// so what is checked is that every file the engine needs is on disk and
    /// none of them is empty, and the row says exactly that.
    func verifyFluidAudioModel(version: String) {
        let asrVersion = AsrModelVersion(storedParakeetVersion: version)
        let directory = AsrModels.defaultCacheDirectory(for: asrVersion)
        guard checkingPath == nil else { return }
        checkingPath = directory.path
        verificationError = nil

        Task.detached(priority: .userInitiated) { [directory, asrVersion] in
            let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                      includingPropertiesForKeys: [.fileSizeKey]))
                ?? []
            let totalBytes = files.reduce(Int64(0)) { sum, url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return sum + Int64(size)
            }
            let empty = files.filter { ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) == 0 }
            let complete = AsrModels.modelsExist(at: directory, version: asrVersion)
            await MainActor.run {
                self.checkingPath = nil
                let sizeText = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
                if complete && empty.isEmpty {
                    self.checkSummaries[directory.path] =
                        "Verified ✓ — \(countLabel(files.count, singular: "file", plural: "files")), \(sizeText) on disk"
                    self.checkProblems.remove(directory.path)
                } else {
                    self.checkSummaries[directory.path] =
                        "Incomplete — \(countLabel(files.count, singular: "file", plural: "files")), \(sizeText) on disk"
                        + (empty.isEmpty ? "" : ", \(empty.count) of them empty")
                    self.checkProblems.insert(directory.path)
                }
            }
        }
    }

    /// Size on disk of a Parakeet model, for the "Installed" line.
    func fluidAudioModelSizeDescription(version: String) -> String {
        let asrVersion = AsrModelVersion(storedParakeetVersion: version)
        let directory = AsrModels.defaultCacheDirectory(for: asrVersion)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let totalBytes = files.reduce(Int64(0)) { sum, url in
            sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
    }

    /// Deletes a Parakeet model's files. The engine downloads them again on
    /// demand, and the row stops claiming to be installed.
    func removeFluidAudioModel(version: String) {
        let asrVersion = AsrModelVersion(storedParakeetVersion: version)
        let directory = AsrModels.defaultCacheDirectory(for: asrVersion)
        let freed = (try? FileManager.default.contentsOfDirectory(at: directory,
                                                                  includingPropertiesForKeys: [.fileSizeKey]))?
            .reduce(Int64(0)) { sum, url in
                sum + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            } ?? 0
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            verificationError = error.localizedDescription
            return
        }
        checkSummaries[directory.path] = nil
        checkProblems.remove(directory.path)
        modelStorageNotice = .removed(
            name: ParakeetModelVersion(stored: version)?.displayName ?? "Parakeet \(version)",
            bytesFreed: freed
        )
        initializeFluidAudioModels()
    }
    
    @MainActor
    func downloadModel(_ model: SettingsDownloadableModel) async throws {
        guard !isDownloading else { return }
        try DiskSpaceUtil.ensureEnoughFreeSpaceForModelDownload()
        
        isDownloading = true
        downloadingModelName = model.name
        downloadProgress = 0.0
        
        let id = UUID()
        downloadID = id
        downloadTask = Task {
            defer {
                if downloadID == id { downloadTask = nil; downloadID = nil }
            }
            do {
                let filename = model.filename
                
                try await downloadWhisper(model.url, filename) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self = self, self.downloadID == id, !Task.isCancelled else { return }
                        guard let task = self.downloadTask, !task.isCancelled else { return }
                        
                        self.downloadProgress = progress
                        if let index = self.downloadableModels.firstIndex(where: { $0.name == model.name }) {
                            self.downloadableModels[index].downloadProgress = progress
                        }
                    }
                }
                
                guard !Task.isCancelled else {
                    await MainActor.run {
                        guard self.downloadID == id else { return }
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
                    guard self.downloadID == id else { return }
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
                    guard self.downloadID == id else { return }
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 0.0
                    if let index = downloadableModels.firstIndex(where: { $0.name == model.name }) {
                        downloadableModels[index].downloadProgress = 0.0
                    }
                }
            } catch {
                guard self.downloadID == id, !Task.isCancelled else { return }
                await MainActor.run {
                    guard self.downloadID == id else { return }
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
        downloadID = nil
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
            if let index = downloadableQwen3ASRModels.firstIndex(where: { $0.name == modelName }) {
                downloadableQwen3ASRModels[index].downloadProgress = 0.0
                qwen3ASRModelManager.cancelDownload(fileID: downloadableQwen3ASRModels[index].id)
            }
        }
        isDownloading = false
        downloadingModelName = nil
        downloadProgress = 0.0
    }
    
    @MainActor
    func downloadFluidAudioModel(_ model: SettingsFluidAudioModel) async throws {
        guard !isDownloading else { return }

        // The row hides this, but the call also arrives from the "download the
        // selected model" entry point: refuse Redux on a system whose Core ML
        // cannot load it before 219 MB start moving over the network.
        if let requested = ParakeetModelVersion(stored: model.version), !requested.isSupportedOnThisMac {
            throw ParakeetModelError.requiresMacOS15(requested.displayName)
        }
        try DiskSpaceUtil.ensureEnoughFreeSpaceForModelDownload()
        
        isDownloading = true
        downloadingModelName = model.name
        downloadProgress = 0.0
        
        if let index = downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
            downloadableFluidAudioModels[index].downloadProgress = 0.0
        }
        
        var wasCancelled = false
        
        let id = UUID()
        downloadID = id
        downloadTask = Task {
            defer {
                if downloadID == id { downloadTask = nil; downloadID = nil }
            }
            do {
                let version = AsrModelVersion(storedParakeetVersion: model.version)
                
                guard !Task.isCancelled else {
                    await MainActor.run {
                        guard self.downloadID == id else { return }
                        self.isDownloading = false
                        self.downloadingModelName = nil
                        self.downloadProgress = 0.0
                        if let index = self.downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                            self.downloadableFluidAudioModels[index].downloadProgress = 0.0
                        }
                    }
                    throw CancellationError()
                }
                
                let modelId = model.id
                let models = try await downloadFluid(version) { [weak self] progress in
                    print("[ParakeetProgress] fraction=\(progress.fractionCompleted) phase=\(progress.phase)")
                    Task { @MainActor [weak self] in
                        guard let self = self, self.downloadID == id, !Task.isCancelled else { return }
                        guard let task = self.downloadTask, !task.isCancelled else { return }
                        self.downloadProgress = progress.fractionCompleted
                        if let index = self.downloadableFluidAudioModels.firstIndex(where: { $0.id == modelId }) {
                            self.downloadableFluidAudioModels[index].downloadProgress = progress.fractionCompleted
                        }
                    }
                }
                
                guard !Task.isCancelled else {
                    await MainActor.run {
                        guard self.downloadID == id else { return }
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
                try await manager.loadModels(models)
                
                await MainActor.run {
                    guard self.downloadID == id else { return }
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
                    guard self.downloadID == id else { return }
                    isDownloading = false
                    downloadingModelName = nil
                    downloadProgress = 0.0
                    if let index = downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                        downloadableFluidAudioModels[index].downloadProgress = 0.0
                    }
                }
                // Don't re-throw CancellationError - it's a manual cancellation
            } catch {
                guard self.downloadID == id, !Task.isCancelled else { return }
                // Check if we were cancelled before the error occurred
                if Task.isCancelled {
                    wasCancelled = true
                    await MainActor.run {
                        guard self.downloadID == id else { return }
                        isDownloading = false
                        downloadingModelName = nil
                        downloadProgress = 0.0
                        if let index = downloadableFluidAudioModels.firstIndex(where: { $0.id == model.id }) {
                            downloadableFluidAudioModels[index].downloadProgress = 0.0
                        }
                    }
                } else {
                    await MainActor.run {
                        guard self.downloadID == id else { return }
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

    // MARK: - Qwen3-ASR models

    /// The manager the Qwen3-ASR card downloads through and reads installed state
    /// from. Injecting it is how a test proves the card's words against a real
    /// directory layout — the app's own, or one a test stages — instead of the
    /// user's Application Support.
    let qwen3ASRModelManager: Qwen3ASRModelManager

    /// The two GGUF files as rows. Both are needed for the engine to start, so
    /// each row is a file to fetch rather than a model to choose.
    @Published var downloadableQwen3ASRModels: [SettingsQwen3ASRModel] = []

    func initializeQwen3ASRModels() {
        downloadableQwen3ASRModels = SettingsQwen3ASRModels.rows(for: qwen3ASRModelManager)
    }

    /// Whether both halves of the engine are on disk at their published size.
    var isQwen3ASRDownloaded: Bool {
        qwen3ASRModelManager.installedPaths != nil
    }

    /// Fetches one of the two files. The engine is reloaded when the last one
    /// lands, because until then it has nothing to load — and the selection is
    /// the weights themselves, so that reload is not a no-op.
    @MainActor
    func downloadQwen3ASRModel(_ model: SettingsQwen3ASRModel) async throws {
        guard !isDownloading else { return }
        guard let file = qwen3ASRModelManager.file(forID: model.id) else { return }
        try DiskSpaceUtil.ensureEnoughFreeSpaceForModelDownload()

        isDownloading = true
        downloadingModelName = model.name
        downloadProgress = 0.0

        let id = UUID()
        downloadID = id
        downloadTask = Task {
            defer {
                if downloadID == id { downloadTask = nil; downloadID = nil }
            }
            do {
                try await qwen3ASRModelManager.download(file) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self = self, self.downloadID == id, !Task.isCancelled else { return }
                        guard let task = self.downloadTask, !task.isCancelled else { return }

                        self.downloadProgress = progress
                        if let index = self.downloadableQwen3ASRModels.firstIndex(where: { $0.id == file.id }) {
                            self.downloadableQwen3ASRModels[index].downloadProgress = progress
                        }
                    }
                }

                await MainActor.run {
                    guard self.downloadID == id else { return }
                    self.resetQwen3ASRDownloadState(of: file.id)
                    self.initializeQwen3ASRModels()
                    if self.selectedEngine == Qwen3ASREngine.engineID {
                        TranscriptionService.shared.reloadEngine()
                    }
                }
            } catch is CancellationError {
                await MainActor.run {
                    guard self.downloadID == id else { return }
                    self.resetQwen3ASRDownloadState(of: file.id)
                }
            } catch {
                await MainActor.run {
                    guard self.downloadID == id else { return }
                    self.resetQwen3ASRDownloadState(of: file.id)
                }
                throw error
            }
        }

        try await downloadTask?.value
    }

    /// Removes one of the two files. The engine is reloaded either way: with a
    /// half removed it must stop transcribing rather than run on weights the
    /// Model tab says are gone, and the selection is the pair, so a loaded engine
    /// is unloaded and the load fails with the file to download.
    @MainActor
    func removeQwen3ASRModel(_ model: SettingsQwen3ASRModel) {
        guard let file = qwen3ASRModelManager.file(forID: model.id) else { return }
        let url = qwen3ASRModelManager.fileURL(for: file)
        do {
            try qwen3ASRModelManager.remove(file)
        } catch {
            verificationError = error.localizedDescription
            return
        }
        verificationResults[url.path] = nil
        checkSummaries[url.path] = nil
        checkProblems.remove(url.path)
        modelStorageNotice = .removed(name: model.name, bytesFreed: model.sizeBytes)
        initializeQwen3ASRModels()
        if selectedEngine == Qwen3ASREngine.engineID {
            TranscriptionService.shared.reloadEngine()
        }
        refreshInstalledModels()
    }

    /// Checks one of the two files against the digest the catalogue pins, through
    /// the same check the whisper rows use.
    func verifyQwen3ASRModel(_ model: SettingsQwen3ASRModel) {
        guard let file = qwen3ASRModelManager.file(forID: model.id) else { return }
        verifyModel(at: qwen3ASRModelManager.fileURL(for: file), pinnedSHA256: file.sha256)
    }

    private func resetQwen3ASRDownloadState(of fileID: String) {
        isDownloading = false
        downloadingModelName = nil
        downloadProgress = 0.0
        if let index = downloadableQwen3ASRModels.firstIndex(where: { $0.id == fileID }) {
            downloadableQwen3ASRModels[index].downloadProgress = 0.0
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
    let filename: String
    let preferredLanguage: String?
    /// The digest the model's publisher reports for this file. `Verify` in the
    /// Model tab compares the file on disk against it, so "it downloaded" is not
    /// the only thing the user has to go on.
    let sha256: String?

    var sizeString: String {
        formatModelSize(megabytes: size)
    }

    var huggingFacePageURL: URL? {
        makeHuggingFacePageURL(fromDownloadURL: url)
    }

    init(name: String, isDownloaded: Bool, url: URL, size: Int, description: String,
         filename: String? = nil, preferredLanguage: String? = nil, sha256: String? = nil) {
        self.name = name
        self.isDownloaded = isDownloaded
        self.url = url
        self.size = size
        self.description = description
        self.filename = filename ?? url.lastPathComponent
        self.preferredLanguage = preferredLanguage
        self.sha256 = sha256
    }
}

struct SettingsDownloadableModels {
    static let availableModels = [
        SettingsDownloadableModel(
            name: "Turbo V3 large",
            isDownloaded: false,
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin?download=true")!,
            size: 1624,
            description: "High accuracy, best quality",
            sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"
        ),
        SettingsDownloadableModel(
            name: "Turbo V3 medium",
            isDownloaded: false,
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q8_0.bin?download=true")!,
            size: 874,
            description: "Balanced speed and accuracy",
            sha256: "317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1"
        ),
        SettingsDownloadableModel(
            name: "Turbo V3 small",
            isDownloaded: false,
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin?download=true")!,
            size: 574,
            description: "Fastest processing",
            sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
        ),
        SettingsDownloadableModel(
            name: "Turbo V3 Hebrew",
            isDownloaded: false,
            url: URL(string: "https://huggingface.co/ivrit-ai/whisper-large-v3-turbo-ggml/resolve/main/ggml-model.bin?download=true")!,
            size: 1624,
            description: "Hebrew fine-tune of Turbo V3 by ivrit.ai.",
            filename: "ggml-ivrit-large-v3-turbo.bin",
            preferredLanguage: "he",
            sha256: "c8090411113357097bfafc2b8e228ec1639fa7f5fe4ecb5d054ac0ccef8641b1"
        )
    ]

    /// The digest published for a file, or `nil` for one nobody publishes a
    /// checksum for (a hand-placed model, say).
    ///
    /// The model the app ships with is not a catalogue entry — it comes from the
    /// bundle, not a download — but its publisher does publish a digest for it,
    /// so `Verify` can still compare it instead of shrugging.
    static func pinnedSHA256(forFilename filename: String) -> String? {
        if filename == WhisperModelManager.defaultModelName {
            return bundledModelSHA256
        }
        return availableModels.first { $0.filename == filename }?.sha256
    }

    /// sha256 of `ggml-tiny.en.bin`, as published by the whisper.cpp repository
    /// it is released from.
    static let bundledModelSHA256 = "921e4cf8686fdd993dcd081a5da5b6c365bfde1162e72b08d75ac75289920b1f"

    /// A model tuned for one language is only offered where it can be useful:
    /// on a machine whose own language it serves. The transcription language is
    /// always auto-detected now, so there is no setting to consult here — and an
    /// already-downloaded model is always listed.
    static func isVisible(_ model: SettingsDownloadableModel,
                          systemLanguage: String) -> Bool {
        guard let lang = model.preferredLanguage else { return true }
        if model.isDownloaded { return true }
        return systemLanguage == lang
    }
}

func countLabel(_ count: Int, singular: String, plural: String) -> String {
    count == 1 ? "\(count) \(singular)" : "\(count) \(plural)"
}

func formatModelSize(megabytes: Int) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useMB, .useGB]
    formatter.countStyle = .file
    formatter.includesUnit = true
    formatter.isAdaptive = true
    return formatter.string(fromByteCount: Int64(megabytes) * 1000000)
}

func makeHuggingFacePageURL(fromDownloadURL url: URL) -> URL? {
    let absoluteString = url.absoluteString
    guard let range = absoluteString.range(of: "/resolve/") else { return nil }
    return URL(string: String(absoluteString[..<range.lowerBound]))
}

/// The Hugging Face owner (user / organization) from a model page URL,
/// e.g. https://huggingface.co/ivrit-ai/whisper-... -> "ivrit-ai".
func huggingFaceOwner(fromPageURL url: URL) -> String? {
    url.pathComponents.first { $0 != "/" }
}

struct Settings {
    static let asianLanguages: Set<String> = ["zh", "ja", "ko"]

    /// Advanced → Debug Options. Whisper prints its verbose decode trace when
    /// this is on; read here so the toggle takes effect on the next dictation.
    var debugMode: Bool
    var suppressBlankAudio: Bool
    var showTimestamps: Bool
    /// Whether the silero speech-only pre-filter runs before the decoder. See
    /// `AppPreferences.useVAD`: off by default, on measurement.
    var useVAD: Bool
    /// See `PauseBoundaryPolicy`: on, a long pause is kept as a real pause and
    /// closes the sentence; off, upstream's 0.1 s of zeros everywhere.
    var longPausesEndSentences: Bool
    var temperature: Double
    var noSpeechThreshold: Double
    var initialPrompt: String
    var useBeamSearch: Bool
    var beamSize: Int
    var useAsianAutocorrect: Bool

    /// Whether the CJK autocorrect runs on this utterance.
    ///
    /// There is no language setting any more: the language is whatever the
    /// engine heard for this very utterance. A multilingual whisper model
    /// measures it, and Chinese, Japanese and Korean are the three the
    /// autocorrect's rule set covers. An engine that measures nothing at all
    /// (Parakeet/FluidAudio) leaves only the transcript itself, and there the
    /// scripts the autocorrect exists for — Han, Hiragana, Katakana, Hangul —
    /// are the signal.
    func shouldApplyAsianAutocorrect(detectedLanguage: String?, text: String) -> Bool {
        guard useAsianAutocorrect else { return false }
        if let detectedLanguage { return Settings.asianLanguages.contains(detectedLanguage) }
        return Settings.containsAsianScript(text)
    }

    /// Whether `text` is written in one of the scripts the autocorrect covers.
    static func containsAsianScript(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x1100...0x11FF,   // Hangul Jamo
                 0x3040...0x30FF,   // Hiragana and Katakana
                 0x3130...0x318F,   // Hangul Compatibility Jamo
                 0x3400...0x4DBF,   // CJK Extension A
                 0x4E00...0x9FFF,   // CJK Unified Ideographs
                 0xAC00...0xD7AF,   // Hangul Syllables
                 0xF900...0xFAFF:   // CJK Compatibility Ideographs
                return true
            default:
                return false
            }
        }
    }

    init() {
        let prefs = AppPreferences.shared
        self.suppressBlankAudio = prefs.suppressBlankAudio
        self.showTimestamps = prefs.showTimestamps
        self.useVAD = prefs.useVAD
        self.longPausesEndSentences = prefs.longPausesEndSentences
        self.temperature = prefs.temperature
        self.noSpeechThreshold = prefs.noSpeechThreshold
        self.initialPrompt = prefs.initialPrompt
        self.useBeamSearch = prefs.useBeamSearch
        self.beamSize = prefs.beamSize
        self.useAsianAutocorrect = prefs.useAsianAutocorrect
        self.debugMode = prefs.debugMode
    }
}

/// Hosts the library's shortcut recorder so that clicking it starts recording.
///
/// `KeyboardShortcuts.RecorderCocoa` reaches the keyboard through a local event
/// monitor it installs in `becomeFirstResponder()` and nowhere else, and a click
/// on an `NSSearchField` never gets it there: `AppKit` puts the field editor in
/// as the window's first responder and never asks the field itself, so the
/// recorder was watching nothing while the combination the user pressed was
/// inserted into the field as ordinary text. Measured in this process, in the
/// real Settings sheet: the field's placeholder never became “Press Shortcut”,
/// the field's value went to `K` as ⌥⇧K was typed into it, and nothing was
/// stored — while the very same keystroke was captured and stored the moment the
/// field *was* made the first responder.
///
/// This host takes the click and hands the recorder the first responder, which
/// is the whole fix. Everything else stays the library's: the displayed
/// shortcut, the conflict and “taken by the system” checks, the storage, and the
/// monitoring itself.
private final class ShortcutRecorderHost: NSView {
    let recorder = KeyboardShortcuts.RecorderCocoa(for: .toggleRecord)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(recorder)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize { recorder.intrinsicContentSize }

    override func layout() {
        super.layout()
        recorder.frame = bounds
    }

    /// The mouse events belong to this view rather than to the field: giving
    /// them to the field is exactly what makes the field editor the responder
    /// and keeps the recorder from ever starting.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, alphaValue > 0, let superview else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    /// A bare `NSView` refuses the mouse-down that would activate an inactive
    /// window, which is the one thing a text field does not do — and this host
    /// stands in for one. Without it the click is dropped on every window that is
    /// not already key and recording never starts.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(recorder)
    }
}

private struct ShortcutRecorderField: NSViewRepresentable {
    func makeNSView(context: Context) -> ShortcutRecorderHost {
        ShortcutRecorderHost(frame: NSRect(x: 0, y: 0, width: 150, height: 24))
    }

    func updateNSView(_ nsView: ShortcutRecorderHost, context: Context) {}
}

struct SettingsView: View {
    @StateObject private var viewModel = SettingsViewModel()
    @StateObject private var permissionsManager = PermissionsManager()
    /// G-12: the Advanced tab resets the welcome flow through the same state the
    /// app's root reads.
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) var dismiss
    @State private var selectedTab = 0
    @State private var previousModelURL: URL?
    @State private var showingUninstallSheet = false
    @State private var resetPermissionsOnUninstall = false
    @State private var uninstallError: String?

    /// Lets the offscreen snapshot harness (SettingsLayoutSnapshotTests) open a
    /// tab other than the first; the app keeps using `SettingsView()`.
    init(selectedTab: Int = 0) {
        _selectedTab = State(initialValue: selectedTab)
    }

    // The four tab bodies below are internal rather than private so the offscreen
    // layout snapshot harness (SettingsLayoutSnapshotTests) can render one tab at
    // a time; nothing outside this file uses them.

    /// The sheet's natural size. The width fits the 450 pt main window that
    /// presents the sheet: at 550 pt the sheet was wider than its own window.
    private var sheetSize: CGSize {
        let visibleFrame = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
        let width = min(450, visibleFrame.width - 40)
        let height = min(500, visibleFrame.height - 60)
        return CGSize(width: width, height: height)
    }

    var body: some View {
        VStack(spacing: 0) {
            settingsTabStrip
            settingsTabContent
        }
        .padding()
        // Flexible on purpose: whatever room the sheet window ends up with — a
        // 400 pt tall window on a small screen, a taller one on a big screen —
        // the cards lay out in it and the tab scrolls instead of hanging off the
        // panel edge.
        .frame(minWidth: 380, idealWidth: sheetSize.width, maxWidth: .infinity,
               minHeight: 300, idealHeight: sheetSize.height, maxHeight: .infinity)
        .background(Color(.windowBackgroundColor))
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Done") {
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                
                Spacer()
                
                Link(destination: URL(string: "https://github.com/Starmel/OpenSuperWhisper")!) {
                    HStack(spacing: 4) {
                        Image(systemName: "star")
                            .font(.system(size: 10))
                        Text("GitHub")
                            .font(.system(size: 11))
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color(.windowBackgroundColor))
        }
        .onAppear {
            previousModelURL = viewModel.selectedModelURL
            if viewModel.selectedEngine == "fluidaudio" {
                viewModel.initializeFluidAudioModels()
            } else if viewModel.selectedEngine == Qwen3ASREngine.engineID {
                viewModel.initializeQwen3ASRModels()
            }
        }
        .onChange(of: viewModel.selectedEngine) { _, newEngine in
            if newEngine == "fluidaudio" {
                viewModel.initializeFluidAudioModels()
            } else if newEngine == Qwen3ASREngine.engineID {
                viewModel.initializeQwen3ASRModels()
            }
        }
        .onChange(of: viewModel.selectedModelURL) { _, newURL in
            if viewModel.selectedEngine == "whisper", let modelPath = newURL?.path {
                Task { @MainActor in
                    TranscriptionService.shared.reloadModel(with: modelPath)
                }
            }
        }
        .sheet(isPresented: $showingUninstallSheet) {
            UninstallConfirmationSheet(
                resetPermissions: $resetPermissionsOnUninstall,
                onCancel: { showingUninstallSheet = false },
                onConfirm: {
                    showingUninstallSheet = false
                    performUninstall()
                }
            )
        }
    }

    /// The tab strip.
    ///
    /// This is a plain segmented control rather than the `TabView` strip it
    /// replaced, because inside a sheet a `TabView`'s strip never gets a size on
    /// this macOS: `NSTabViewSegmentedControl` stays 0x0, so the four labels are
    /// drawn on top of each other and there is nothing to click — which is how
    /// the Transcription tab, and with it the tone controls, became unreachable.
    /// The same four tabs, the same `selectedTab`, nothing else moved.
    private var settingsTabStrip: some View {
        Picker("", selection: $selectedTab) {
            Text("Shortcuts").tag(0)
            Text("Model").tag(1)
            Text("Transcription").tag(2)
            Text("Advanced").tag(3)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var settingsTabContent: some View {
        switch selectedTab {
        case 1:
            modelSettings
        case 2:
            transcriptionSettings
        case 3:
            advancedSettings
        default:
            shortcutSettings
        }
    }

    /// Starts the uninstaller and quits. The script waits for this process to
    /// exit before it removes anything, which is the only way an app can delete
    /// the bundle it is running from.
    private func performUninstall() {
        do {
            try UninstallService.startUninstall(resetPermissions: resetPermissionsOnUninstall)
        } catch {
            uninstallError = error.localizedDescription
            return
        }
        NSApplication.shared.terminate(nil)
    }
    
    var modelSettings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Speech Recognition Engine")
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Picker("Engine", selection: $viewModel.selectedEngine) {
                    Text("Parakeet").tag("fluidaudio")
                    Text("Whisper").tag("whisper")
                    Text("Qwen3-ASR").tag(Qwen3ASREngine.engineID)
                }
                .pickerStyle(.segmented)
                .padding(.bottom, 8)
                
                if viewModel.selectedEngine == "whisper" {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Whisper Model")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        Text("Download Models")
                            .font(.headline)
                            .foregroundColor(.primary)
                            .padding(.top, 8)
                        
                        VStack(spacing: 12) {
                            ForEach($viewModel.downloadableModels) { $model in
                                if SettingsDownloadableModels.isVisible(model,
                                        systemLanguage: LanguageUtil.getSystemLanguage()) {
                                    ModelDownloadItemView(model: $model, viewModel: viewModel)
                                }
                            }
                        }
                        
                        // G-05: everything on disk, catalogue row or not, with
                        // the file in use marked. G-07: what the app did about
                        // the models last, including a fallback nobody asked for.
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Installed models (\(viewModel.installedWhisperModels.count))")
                                    .font(.headline)
                                Spacer()
                                Button("Refresh") {
                                    viewModel.loadAvailableModels()
                                }
                                .buttonStyle(.borderless)
                                .font(.caption)
                                .help("Re-read the models directory")
                            }

                            Text("Selected model: \(viewModel.selectedModelDescription)")
                                .font(.caption)
                                .foregroundColor(.secondary)

                            if let notice = viewModel.modelStorageNotice {
                                Text(notice.message)
                                    .font(.caption)
                                    .foregroundColor(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            if let error = viewModel.verificationError {
                                Text(error)
                                    .font(.caption)
                                    .foregroundColor(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            ForEach(viewModel.installedWhisperModels) { model in
                                InstalledWhisperModelView(model: model, viewModel: viewModel)
                            }

                            if viewModel.installedWhisperModels.isEmpty {
                                Text("No model files on disk.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.top, 8)

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
                } else if viewModel.selectedEngine == Qwen3ASREngine.engineID {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Qwen3-ASR Model")
                            .font(.headline)
                            .foregroundColor(.primary)

                        Text("Download Models")
                            .font(.headline)
                            .foregroundColor(.primary)
                            .padding(.top, 8)

                        Text("Both files are needed: the speech model and the audio encoder it is prompted with. The engine fetches them the first time it runs — they are listed here so the download can be seen, verified and the files removed.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        VStack(spacing: 12) {
                            ForEach($viewModel.downloadableQwen3ASRModels) { $model in
                                Qwen3ASRModelDownloadItemView(model: $model, viewModel: viewModel)
                            }
                        }

                        if !viewModel.isQwen3ASRDownloaded {
                            Text("Neither file is on disk yet. The engine downloads both the first time it runs, and dictation with it works once they are verified — the app never switches to another engine on its own.")
                                .font(.caption)
                                .foregroundColor(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if let notice = viewModel.modelStorageNotice {
                            Text(notice.message)
                                .font(.caption)
                                .foregroundColor(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if let error = viewModel.verificationError {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Models Directory:")
                                    .font(.subheadline)
                                Button(action: {
                                    NSWorkspace.shared.open(viewModel.qwen3ASRModelManager.directory)
                                }) {
                                    Label("Open Folder", systemImage: "folder")
                                        .font(.subheadline)
                                }
                                .buttonStyle(.borderless)
                                .help("Open models directory")
                            }
                            Text(viewModel.qwen3ASRModelManager.directory.path)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                                .padding(8)
                                .background(Color(.textBackgroundColor).opacity(0.5))
                                .cornerRadius(6)
                        }
                        .padding(.top, 8)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Parakeet Model")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        Text("Download Models")
                            .font(.headline)
                            .foregroundColor(.primary)
                            .padding(.top, 8)
                        
                        VStack(spacing: 12) {
                            ForEach($viewModel.downloadableFluidAudioModels) { $model in
                                FluidAudioModelDownloadItemView(model: $model, viewModel: viewModel)
                            }
                        }
                        
                        if let notice = viewModel.modelStorageNotice {
                            Text(notice.message)
                                .font(.caption)
                                .foregroundColor(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if let error = viewModel.verificationError {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                                .fixedSize(horizontal: false, vertical: true)
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
        .padding()
    }
    
    var transcriptionSettings: some View {
        ScrollView {
            VStack(spacing: 20) {
                // Language Settings
                VStack(alignment: .leading, spacing: 16) {
                    Text("Language Settings")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Recognition Language")
                            .font(.subheadline)

                        // No picker: the engine always detects the language of
                        // the utterance, and the app never changes it.
                        Text("Automatic — the model detects the language of each dictation")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Use Asian Autocorrect")
                                    .font(.subheadline)
                                Text("Chinese, Japanese and Korean dictation, as detected above")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $viewModel.useAsianAutocorrect)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                        }
                        .padding(.top, 4)

                        // The captain asked for pauses to be "ignored"; the
                        // pause was never the problem — replacing it with a 0.1
                        // second breath is what made a sentence out of nothing,
                        // and the label says what the switch does instead.
                        //
                        // The second paragraph is the cost of the decision, in
                        // the same words as `AppPreferences.longPausesEndSentences`
                        // and Readme §8: the switch ships on, and the captain
                        // accepted this much English change on 2026-09-25 rather
                        // than a switch that does nothing on English.
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Long Pauses End the Sentence")
                                    .font(.subheadline)
                                Text(
                                    "Whisper: a pause of "
                                        + "\(WhisperEngine.PauseBoundaryPolicy.restored.sentenceThreshold) s or longer "
                                        + "keeps its silence and closes the sentence, instead of dissolving "
                                        + "into a breath that lets two thoughts merge. "
                                        + "With no prompt of your own the decoder prompt is chosen by the "
                                        + "language of the dictation, and that costs one extra detect-only "
                                        + "language pass over the audio before each dictation — measured "
                                        + "+1.34 s against a 3.5 s decode, \u{2248} 38 % — paid only while this "
                                        + "switch is on and no prompt is set; and on pause-heavy English "
                                        + "speech the switch changes two words against the switch off "
                                        + "(\u{201C}Basically now it creates a sentences\u{201D} where the switch "
                                        + "off says \u{201C}Basically how it creates a sentence\u{201D}), a "
                                        + "change the captain accepted on 2026-09-25 with the measurement "
                                        + "in front of him, because no prompt removes it and the Polish "
                                        + "fix rides on the same silence."
                                )
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Toggle("", isOn: $viewModel.longPausesEndSentences)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                        }
                        .padding(.top, 4)
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
                        
                        // Off by default, and the numbers are why. The filter is
                        // the reason quiet dictations came back missing words:
                        // it keeps only the speech silero finds, and on a quiet
                        // recording that is sometimes a fraction of what was
                        // said. See `AppPreferences.useVAD` for the full
                        // measurement and `WhisperEngine.vadParams` for why the
                        // threshold is not a second control.
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Speech-Only Filter (VAD)")
                                    .font(.subheadline)
                                Text(
                                    "Whisper: the silero voice-activity filter finds the speech and "
                                        + "hands the decoder nothing else. Measured on his own "
                                        + "recordings it drops speech too — one 8.69 s dictation kept "
                                        + "0.86 s of it and came out \u{201C}See you later.\u{201D} where "
                                        + "the same audio without the filter reads \u{201C}All right, I "
                                        + "gotta go home. See you later and keep up.\u{201D} Across the "
                                        + "four worst dictations, off recovered 35 words with 0 still "
                                        + "missing, against 0 recovered and 35 still missing with it "
                                        + "on; a lower detection threshold (0.15) recovered 29 of the "
                                        + "35, so the filter's own settings stay internal and this "
                                        + "switch is off/on only."
                                )
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Toggle("", isOn: $viewModel.useVAD)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                        }
                        .padding(.top, 4)
                        
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
                                Text("Keep transcription in clipboard after recording")
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
                                Text("Delivers the text into the focused app as it is transcribed — "
                                     + "Accessibility is required for that to land. Keystrokes by default, "
                                     + "and the clipboard paste for a virtual machine or remote desktop; "
                                     + "see below")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Toggle("", isOn: $viewModel.autoPasteTranscription)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                        }

                        if viewModel.autoPasteTranscription {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Delivery")
                                    .font(.subheadline)
                                Picker("Delivery", selection: $viewModel.deliveryPreference) {
                                    ForEach(DeliveryPreference.allCases, id: \.self) { preference in
                                        Text(preference.displayName).tag(preference)
                                    }
                                }
                                .pickerStyle(.menu)
                                .labelsHidden()
                                Text(viewModel.deliveryPreference.explanation
                                     + ". Text is typed as synthetic keystrokes, which no keyboard layout "
                                     + "changes and which leaves the clipboard alone. A Citrix session, a "
                                     + "virtual machine or a remote desktop may never read that text — "
                                     + "measured on the Citrix client, its viewer links no Unicode-payload "
                                     + "reader at all — so those get the transcript through the clipboard "
                                     + "instead, and what was in the clipboard is written to disk (readable "
                                     + "by you alone) and put back 1.5 s later, or on the next launch if "
                                     + "the app does not survive that long. Keystrokes only turns the "
                                     + "clipboard path off.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)

                                if viewModel.deliveryPreference == .automatic {
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text("Paste into other apps from these vendors")
                                                .font(.subheadline)
                                            Text("The exact Citrix, Parallels and Screen Sharing bundles are "
                                                 + "recognised from measurements on this Mac. Any other bundle "
                                                 + "from those vendors is a guess, so it is typed into unless "
                                                 + "you ask for the clipboard here.")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                        Spacer()
                                        Toggle("", isOn: $viewModel.pasteIntoRecognisedVendors)
                                            .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                            .labelsHidden()
                                    }
                                }
                            }
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)

                // Tone, clean-up and the spoken e-mail trigger.
                VStack(alignment: .leading, spacing: 16) {
                    Text("Tone, Clean-up & E-mail")
                        .font(.headline)
                        .foregroundColor(.primary)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Apply tone")
                                    .font(.subheadline)
                                Text("Rewrite the dictation in the selected tone, in the language you spoke — the language is never changed, and nothing else is rewritten")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $viewModel.toneEnabled)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Tone")
                                .font(.subheadline)
                            Picker("Tone", selection: $viewModel.transformToneMode) {
                                ForEach(ToneMode.allCases) { tone in
                                    Text(tone.displayName).tag(tone)
                                }
                            }
                            .pickerStyle(.menu)
                            .labelsHidden()
                            .disabled(!viewModel.toneEnabled)
                        }

                        Divider()

                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Clean up dictation")
                                    .font(.subheadline)
                                Text("Remove filler words, stutters and repeats in any language — that scrub is a function and needs no model. The grammar repair (punctuation, articles, word order) needs a model: on its own it is English-only, on S1-mini; with a tone on it rides the tone call, in Polish or English.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $viewModel.cleanUpEnabled)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Reference")
                                .font(.subheadline)
                            TextEditor(text: $viewModel.transformReference)
                                .frame(height: 50)
                                .padding(6)
                                .background(Color(.textBackgroundColor))
                                .cornerRadius(8)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                                )
                            Text("Names, jargon and domain terms you say, one per line — the transform is told to keep these spellings. Optional, and inert while empty. It rides the instruction model's prompt (tone and e-mail); S1-mini's input format is fixed and has no slot for a list, so English clean-up alone does not get it.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        // E-mail mode is selected by what the dictation opens
                        // with, not by a control: the trigger phrase is spoken,
                        // so the card spells it out and says there is no switch.
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("E-mail mode (spoken)")
                                    .font(.subheadline)
                                Text("Say the trigger at the start of a dictation — “dyktuję maila” (also “dyktuję mejla”, “napisz maila”, “dyktuję email”, accepted inside the first four words). The phrase is taken off the front and the rest is shaped into a greeting, body paragraphs, a polite closing and a sign-off — no subject line, no placeholders — in Polish or English. There is no switch and no second hotkey; a trigger with nothing after it is discarded as an empty dictation.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }

                        // Built-in runtime: the weights the app downloads and
                        // runs itself. There is no backend outside it.
                        Divider()

                        VStack(alignment: .leading, spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Transform models")
                                    .font(.subheadline)
                                // The paragraph is a view-model property so the
                                // routing it states is asserted by the suite
                                // rather than living only in the view body.
                                Text(viewModel.transformModelsHeaderDescription)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            // Which model each job runs on right now, and whether
                            // each one is present — stated, never warned about:
                            // the weights are downloads, not requirements.
                            Text(viewModel.transformLanguageModelDescription)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)

                            ForEach(viewModel.transformModels) { model in
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack(alignment: .top) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            // The model's own name first: three
                                            // rows whose titles were their roles
                                            // left "which one is S1-mini?" to be
                                            // inferred from the prose below.
                                            Text(model.displayName)
                                                .font(.subheadline.weight(.semibold))
                                            Text(viewModel.transformModelRoleDescription(model))
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                            Text(viewModel.transformModelStateDescription(model))
                                                .font(.caption)
                                                .foregroundColor(
                                                    viewModel.isTransformModelInstalled(model) ? .secondary : .orange
                                                )
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                        Spacer()
                                        if viewModel.isDownloading(model) {
                                            Button("Cancel") {
                                                viewModel.cancelTransformModelDownload(model)
                                            }
                                            .font(.subheadline)
                                        } else if viewModel.isTransformModelInstalled(model) {
                                            Button("Remove") {
                                                viewModel.removeTransformModel(model)
                                            }
                                            .font(.subheadline)
                                        } else {
                                            Button("Download model") {
                                                Task { await viewModel.downloadTransformModel(model) }
                                            }
                                            .font(.subheadline)
                                            .buttonStyle(.borderedProminent)
                                            .disabled(viewModel.downloadingTransformModelID != nil)
                                        }
                                    }

                                    if viewModel.isDownloading(model) {
                                        ProgressView(value: viewModel.transformModelDownloadProgress)
                                        Text(String(
                                            format: "%.0f%% of %@",
                                            viewModel.transformModelDownloadProgress * 100,
                                            model.sizeDescription
                                        ))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    }

                                    if let notice = viewModel.transformMissingNotice(for: model) {
                                        Text(notice)
                                            .font(.caption)
                                            .foregroundColor(.orange)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }

                                    // The name is the row's title now, so this
                                    // line carries only what the title does not:
                                    // the licence and where the weights come from.
                                    Text("Runs inside the app. \(model.licence). From \(model.source).")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }

                            if let error = viewModel.transformModelError {
                                Text(error)
                                    .font(.caption)
                                    .foregroundColor(.red)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        Text("Nothing here changes the language of what you dictated: Polish comes back Polish and English comes back English, and neither switch is a translation. Tone and the e-mail mode run on the instruction model, in Polish and English alike — Polish tone is new; the deterministic scrub is still what Polish clean-up is — while English clean-up alone runs on S1-mini. With both switches off and no e-mail trigger, nothing is sent to a model at all. Before any model runs, a deterministic function replaces profanity and crude slang with neutral wording that carries the same meaning, so that part is a guarantee rather than the model's judgement; if the model then refuses the job or invents a bracketed placeholder, the answer is thrown away and the dictation is delivered with the profanity already neutralised, with a notice that the rewrite did not happen. Every dictation reports the detected language and shows the raw transcript beside the cleaned and rewritten text; history always keeps the raw transcript, and recordings transcribed from the list are never rewritten. The language of each utterance is detected automatically, which needs a multilingual whisper model.")
                            .font(.caption)
                            .foregroundColor(.secondary)
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
                        
                        Text("Optional text to guide the model's transcription. Leave it empty and the app "
                            + "sends a short default written for the language it hears (Polish or English — "
                            + "nothing for any other language), whenever Long Pauses End the Sentence is on.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
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
                
                RecordingStorageSettingsView()
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.controlBackgroundColor).opacity(0.3))
                    .cornerRadius(12)
            }
            .padding()
        }
    }
    
    var advancedSettings: some View {
        ScrollView {
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
                
                // G-12: the welcome flow could only be re-shown by editing a
                // DEBUG config file; this is the same reset, from the UI.
                welcomeScreenSettings

                // Uninstall
                VStack(alignment: .leading, spacing: 16) {
                    Text("Uninstall")
                        .font(.headline)
                        .foregroundColor(.primary)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Removes the app, your dictation history, the downloaded models and the installer receipt in one operation.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Button("Uninstall OpenSuperWhisper…") {
                            uninstallError = nil
                            showingUninstallSheet = true
                        }
                        .foregroundColor(.red)

                        if let uninstallError {
                            Text(uninstallError)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
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
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Debug Mode")
                                .font(.subheadline)
                            Text("Prints whisper.cpp's verbose decode trace while transcribing "
                                 + "(temperatures, fallbacks, timings) — for bug reports")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer()
                        Toggle("", isOn: $viewModel.debugMode)
                            .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                            .labelsHidden()
                            .help("Print the decoder's verbose trace to the app's output")
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
    
    private enum TriggerMode: Hashable {
        case keyCombo
        case modifier
        case mouse
    }

    @ViewBuilder
    private func permissionWarning(message: String, isGranted: Bool, grantAction: @escaping () -> Void) -> some View {
        if permissionsManager.hasCompletedInitialCheck && !isGranted {
            VStack(alignment: .leading, spacing: 8) {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.orange)
                
                Button("Grant Permission") {
                    grantAction()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.top, 4)
        }
    }

    private var triggerMode: TriggerMode {
        if viewModel.mouseButtonHotkey != .none { return .mouse }
        if viewModel.modifierOnlyHotkey != .none { return .modifier }
        return .keyCombo
    }
    
    /// G-12: show the welcome flow again.
    ///
    /// It sets the shortcut and the speech model, and it was reachable
    /// only once — resetting `hasCompletedOnboarding` needed a DEBUG
    /// `dev_config.json`. This is the same reset, and it changes nothing until
    /// something is picked in the flow.
    private var welcomeScreenSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Welcome Screen")
                .font(.headline)
                .foregroundColor(.primary)

            Text("The welcome screen sets your dictation shortcut and speech model. "
                 + "Showing it again changes none of them until you choose something there. "
                 + "The main window shows it as soon as this sheet closes.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("Show the welcome screen again") {
                appState.hasCompletedOnboarding = false
                dismiss()
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor).opacity(0.3))
        .cornerRadius(12)
    }

    /// G-02/G-03: the two grants this app needs, in Settings, where everything
    /// else about its state lives.
    ///
    /// Both were invisible here before: the Accessibility warning existed only
    /// inside two of the three trigger modes (never for the default key
    /// combination), and the microphone was not mentioned in the sheet at all —
    /// the only place it appeared was the main window, and only while something
    /// was missing.
    private var permissionsSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Permissions")
                .font(.headline)
                .foregroundColor(.primary)

            permissionSettingsRow(
                title: "Keystrokes into other apps",
                detail: "Accessibility. Needed to type a transcription into the app you are dictating into.",
                granted: permissionsManager.isAccessibilityPermissionGranted,
                action: { permissionsManager.requestAccessibilityPermissionOrOpenSystemPreferences() })

            permissionSettingsRow(
                title: "Microphone",
                detail: "Needed to record your dictation.",
                granted: permissionsManager.isMicrophonePermissionGranted,
                action: { permissionsManager.requestMicrophonePermissionOrOpenSystemPreferences() })
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor).opacity(0.3))
        .cornerRadius(12)
        // The manager reads both grants when it is created and again on every
        // activation, but opening this tab reads nothing: re-read them here
        // rather than showing whatever was true when the sheet was built.
        .onAppear {
            permissionsManager.checkAccessibilityPermission()
            permissionsManager.checkMicrophonePermission()
        }
    }

    @ViewBuilder
    private func permissionSettingsRow(title: String, detail: String, granted: Bool,
                                       action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(granted ? .green : .orange)
                .imageScale(.medium)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)

                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if permissionsManager.hasCompletedInitialCheck {
                    Text(granted ? "Granted" : "Not granted")
                        .font(.caption)
                        .foregroundColor(granted ? .green : .orange)
                } else {
                    Text("Checking…")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            if !granted {
                Button("Open System Settings", action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    var shortcutSettings: some View {
        ScrollView {
            VStack(spacing: 20) {
                permissionsSettings

                // Recording Trigger
                VStack(alignment: .leading, spacing: 16) {
                    Text("Recording Trigger")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    VStack(alignment: .leading, spacing: 16) {
                        Picker("", selection: Binding(
                            get: { triggerMode },
                            set: { newMode in
                                switch newMode {
                                case .keyCombo:
                                    viewModel.mouseButtonHotkey = .none
                                    viewModel.modifierOnlyHotkey = .none
                                case .modifier:
                                    viewModel.mouseButtonHotkey = .none
                                    if viewModel.modifierOnlyHotkey == .none {
                                        viewModel.modifierOnlyHotkey =
                                            ModifierKey(rawValue: AppPreferences.shared.lastModifierOnlyHotkey) ?? .leftCommand
                                    }
                                case .mouse:
                                    viewModel.modifierOnlyHotkey = .none
                                    if viewModel.mouseButtonHotkey == .none {
                                        viewModel.mouseButtonHotkey = .middle
                                    }
                                }
                            }
                        )) {
                            Text("Key Combination").tag(TriggerMode.keyCombo)
                            Text("Single Modifier Key").tag(TriggerMode.modifier)
                            Text("Mouse Button").tag(TriggerMode.mouse)
                        }
                        .pickerStyle(.segmented)

                        switch triggerMode {
                        case .modifier:
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

                                permissionWarning(
                                    message: "This mode requires Accessibility permission so single modifier key presses can be detected globally. Only modifier key events (⌘, ⌥, ⇧, ⌃, Fn) are monitored — no regular keystrokes are captured.",
                                    isGranted: permissionsManager.isAccessibilityPermissionGranted
                                ) {
                                    permissionsManager.requestAccessibilityPermissionOrOpenSystemPreferences()
                                }
                            }
                        case .mouse:
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Mouse Button")
                                        .font(.subheadline)
                                    Spacer()
                                    Picker("", selection: $viewModel.mouseButtonHotkey) {
                                        ForEach(MouseButton.allCases.filter { $0 != .none }) { button in
                                            Text(button.displayName).tag(button)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .frame(width: 200)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color(.textBackgroundColor).opacity(0.5))
                                .cornerRadius(8)

                                Text("Click to toggle recording, or hold when Hold to Record is on. The left and right buttons are reserved — pick the middle or an extra (thumb) button.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                permissionWarning(
                                    message: "⚠️ This mode requires Accessibility permission so the button can be detected globally and used only as a recording trigger. Only the selected mouse button is intercepted — no other clicks or keystrokes are captured.",
                                    isGranted: permissionsManager.isAccessibilityPermissionGranted
                                ) {
                                    permissionsManager.requestAccessibilityPermissionOrOpenSystemPreferences()
                                }
                            }
                        case .keyCombo:
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text("Shortcut")
                                        .font(.subheadline)
                                    Spacer()
                                    ShortcutRecorderField()
                                        .frame(width: 150)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color(.textBackgroundColor).opacity(0.5))
                                .cornerRadius(8)

                                Text("Click the field and press the combination you want. Hold it to record, or press it once to start and once to stop.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
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
                        
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Cancel without confirmation")
                                    .font(.subheadline)
                                Text("Skip the double-Esc confirmation for recordings longer than 10 seconds")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: $viewModel.escCancelWithoutConfirmation)
                                .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                                .labelsHidden()
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.controlBackgroundColor).opacity(0.3))
                .cornerRadius(12)

                // Application
                VStack(alignment: .leading, spacing: 16) {
                    Text("Application")
                        .font(.headline)
                        .foregroundColor(.primary)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Start hidden in menu bar")
                                .font(.subheadline)
                            Text("Launch without opening the main window; use the menu bar icon to open it")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $viewModel.startHiddenInMenuBar)
                            .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                            .labelsHidden()
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
    let size: Int
    var downloadProgress: Double = 0.0

    var sizeString: String {
        formatModelSize(megabytes: size)
    }

    /// Whether this Mac can load the model at all. Redux's encoder is built from
    /// macOS 15 Core ML operations, so on an older system the row offers neither
    /// its download nor its selection: the engine would refuse the load after
    /// the whole file had crossed the network.
    var isSupportedOnThisMac: Bool {
        ParakeetModelVersion(stored: version)?.isSupportedOnThisMac ?? true
    }
}

struct SettingsFluidAudioModels {
    static let availableModels = [
        SettingsFluidAudioModel(
            name: "Parakeet v3",
            version: "v3",
            isDownloaded: false,
            description: "Multilingual, 25 languages",
            size: 483
        ),
        SettingsFluidAudioModel(
            name: "Parakeet Redux",
            version: "redux",
            isDownloaded: false,
            description: "Multilingual, 25 languages — 2-bit ternary encoder, needs macOS 15",
            size: 219
        ),
        SettingsFluidAudioModel(
            name: "Parakeet v2",
            version: "v2",
            isDownloaded: false,
            description: "English-only, higher recall",
            size: 464
        )
    ]
}

/// One Qwen3-ASR GGUF file as the Model tab shows it.
///
/// The two files are one download from the user's point of view but two rows on
/// disk: each has its own URL, digest and size, and the engine starts only when
/// both are there.
struct SettingsQwen3ASRModel: Identifiable {
    let id: String
    let name: String
    let fileName: String
    let url: URL
    let sizeBytes: Int64
    let description: String
    let sha256: String
    var isDownloaded: Bool
    var downloadProgress: Double = 0.0

    var sizeString: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    var huggingFacePageURL: URL? {
        makeHuggingFacePageURL(fromDownloadURL: url)
    }
}

struct SettingsQwen3ASRModels {
    /// The rows, with what is on disk read from the manager that owns it.
    static func rows(for manager: Qwen3ASRModelManager) -> [SettingsQwen3ASRModel] {
        manager.files.map { file in
            SettingsQwen3ASRModel(
                id: file.id,
                name: file.displayName,
                fileName: file.fileName,
                url: file.downloadURL,
                sizeBytes: file.sizeBytes,
                description: file.id == Qwen3ASRModelManager.projectorFileID
                    ? "The audio encoder — the text model cannot hear without it"
                    : "The speech model — the transcript comes from here",
                sha256: file.sha256,
                isDownloaded: manager.hasInstalledFile(file)
            )
        }
    }
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

    var huggingFacePageURL: URL? {
        switch type {
        case .whisper(let url, _):
            return makeHuggingFacePageURL(fromDownloadURL: url)
        case .parakeet(let version):
            let repo = (ParakeetModelVersion(stored: version) ?? .v3).huggingFaceRepo
            return URL(string: "https://huggingface.co/FluidInference/\(repo)")
        }
    }
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
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text(model.description)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if !model.isSupportedOnThisMac {
                    Text("Not available on this Mac — needs macOS 15 or newer")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }

                if model.isDownloaded {
                    Text("Downloaded — \(viewModel.fluidAudioModelSizeDescription(version: model.version)) on disk")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                if viewModel.isDownloading && viewModel.downloadingModelName == model.name {
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
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 6) {
                        if isSelected {
                            Label("In use", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundColor(.green)
                        } else {
                            Button(action: {
                                viewModel.fluidAudioModelVersion = model.version
                            }) {
                                Text("Select")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(!model.isSupportedOnThisMac)
                        }

                        Button("Remove") {
                            viewModel.removeFluidAudioModel(version: model.version)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Delete this model's files and free the space they take")

                        Button("Verify") {
                            viewModel.verifyFluidAudioModel(version: model.version)
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }

                    if viewModel.checkingPath == AsrModels.defaultCacheDirectory(for: AsrModelVersion(storedParakeetVersion: model.version)).path {
                        ProgressView().controlSize(.small).scaleEffect(0.7)
                    }
                    if let summary = viewModel.checkSummaries[
                        AsrModels.defaultCacheDirectory(for: AsrModelVersion(storedParakeetVersion: model.version)).path] {
                        Text(summary)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Text(model.sizeString)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
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
                    .disabled(viewModel.isDownloading || !model.isSupportedOnThisMac)
                }
            }
        }
        .padding(12)
        .background(isSelected ? Color(.controlBackgroundColor).opacity(0.7) : Color(.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture {
            if model.isDownloaded && !isSelected {
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

struct RecordingStorageSettingsView: View {
    @State private var autoDeleteEnabled = AppPreferences.shared.autoDeleteRecordingsEnabled
    @State private var retentionDays = AppPreferences.shared.autoDeleteRecordingsAfterDays
    @State private var diskUsage: Int64 = 0
    @State private var showConfirmation = false
    @State private var pendingDays = 0
    @State private var pendingCount = 0
    @State private var pendingOldestDate: Date?

    private let dayOptions = [1, 7, 14, 30, 90]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("History Storage")
                .font(.headline)
                .foregroundColor(.primary)

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Recordings on disk:")
                        .font(.subheadline)
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: diskUsage, countStyle: .file))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Delete recordings older than")
                        .font(.subheadline)
                    Spacer()
                    Picker("", selection: Binding(
                        get: { retentionDays },
                        set: { newValue in
                            if autoDeleteEnabled {
                                requestAutoDelete(days: newValue)
                            } else {
                                retentionDays = newValue
                                AppPreferences.shared.autoDeleteRecordingsAfterDays = newValue
                            }
                        }
                    )) {
                        ForEach(dayOptions, id: \.self) { days in
                            Text(countLabel(days, singular: "day", plural: "days")).tag(days)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 120)
                }

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Auto-delete old recordings")
                            .font(.subheadline)
                        Text("Removes both audio files and their transcriptions from history")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { autoDeleteEnabled },
                        set: { newValue in
                            if newValue {
                                requestAutoDelete(days: retentionDays)
                            } else {
                                autoDeleteEnabled = false
                                AppPreferences.shared.autoDeleteRecordingsEnabled = false
                            }
                        }
                    ))
                    .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
                    .labelsHidden()
                    .help("Automatically delete recordings and their transcriptions older than the selected number of days")
                }
            }
        }
        .onAppear {
            refreshDiskUsage()
        }
        .alert("Delete Old Recordings?", isPresented: $showConfirmation) {
            Button("Delete", role: .destructive) {
                confirmAutoDelete()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(countLabel(pendingCount, singular: "recording", plural: "recordings")) with \(pendingCount == 1 ? "its transcription" : "their transcriptions") starting from \(formattedDate(pendingOldestDate)) will be deleted.")
        }
    }

    private func requestAutoDelete(days: Int) {
        Task { @MainActor in
            let result: (count: Int, oldestDate: Date?) = (try? await RecordingStore.shared.recordingsOlderThan(days: days)) ?? (count: 0, oldestDate: nil)
            if result.count > 0 {
                pendingDays = days
                pendingCount = result.count
                pendingOldestDate = result.oldestDate
                showConfirmation = true
            } else {
                applyAutoDelete(days: days)
            }
        }
    }

    private func confirmAutoDelete() {
        applyAutoDelete(days: pendingDays)
    }

    private func applyAutoDelete(days: Int) {
        retentionDays = days
        autoDeleteEnabled = true
        AppPreferences.shared.autoDeleteRecordingsAfterDays = days
        AppPreferences.shared.autoDeleteRecordingsEnabled = true
        Task { @MainActor in
            try? await RecordingStore.shared.deleteRecordings(olderThanDays: days)
            refreshDiskUsage()
        }
    }

    private func refreshDiskUsage() {
        Task.detached {
            let usage = RecordingStore.recordingsDiskUsage()
            await MainActor.run {
                diskUsage = usage
            }
        }
    }

    private func formattedDate(_ date: Date?) -> String {
        guard let date else { return "-" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

/// The verify control every model row shares: the button, a spinner while the
/// file is hashed, and the sentence the check produced.
struct ModelVerificationView: View {
    let path: String
    let pinnedSHA256: String?
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if viewModel.checkingPath == path {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.7)
                    Text("Checking…")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } else {
                Button("Verify") {
                    viewModel.verifyModel(at: URL(fileURLWithPath: path), pinnedSHA256: pinnedSHA256)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .help(pinnedSHA256 == nil
                      ? "Read this file's sha256 — its publisher reports no checksum, so nothing is compared"
                      : "Compare this file against the sha256 its publisher reports")
            }

            if let summary = viewModel.checkSummaries[path] {
                Text(summary)
                    .font(.caption2)
                    .foregroundColor(viewModel.checkProblems.contains(path) ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One speech model file that is on disk right now: a catalogue row or a file
/// someone put there by hand, with the model in use marked.
struct InstalledWhisperModelView: View {
    let model: SettingsViewModel.InstalledWhisperModel
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.name)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    if model.isSelected {
                        Label("In use", systemImage: "checkmark.circle.fill")
                            .font(.caption2)
                            .foregroundColor(.green)
                    }

                    if model.name == WhisperModelManager.defaultModelName {
                        Text("shipped with the app")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .help("This is the model inside the app bundle, copied into the models directory on first run")
                    } else if model.catalogueName == nil {
                        Text("not in the catalogue")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .help("This file was not downloaded from the list above, so no publisher checksum is known for it")
                    }
                }

                Text("\(model.sizeDescription) on disk")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ModelVerificationView(path: model.url.path,
                                      pinnedSHA256: model.pinnedSHA256,
                                      viewModel: viewModel)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                if !model.isSelected {
                    Button("Use") {
                        viewModel.selectModel(model.url)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                Button("Remove") {
                    viewModel.removeInstalledModel(model)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Delete this file and free \(model.sizeDescription)")
            }
        }
        .padding(12)
        .background(model.isSelected ? Color(.controlBackgroundColor).opacity(0.7)
                                     : Color(.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }
}

/// One Qwen3-ASR file: the same shape as the whisper download row, without the
/// selection — the engine runs on the pair, so neither file is chosen by itself.
struct Qwen3ASRModelDownloadItemView: View {
    @Binding var model: SettingsQwen3ASRModel
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showError = false
    @State private var errorMessage = ""

    private var filePath: String {
        viewModel.qwen3ASRModelManager.directory.appendingPathComponent(model.fileName).path
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.name)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    if let pageURL = model.huggingFacePageURL,
                       let owner = huggingFaceOwner(fromPageURL: pageURL) {
                        Link(owner, destination: pageURL)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("View on Hugging Face")
                    }
                }

                Text(model.description)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(model.fileName)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)

                if model.isDownloaded {
                    Text("Downloaded — \(model.sizeString) on disk")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                if viewModel.isDownloading && viewModel.downloadingModelName == model.name {
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
                VStack(alignment: .trailing, spacing: 6) {
                    Button("Remove") {
                        viewModel.removeQwen3ASRModel(model)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Delete this file and free \(model.sizeString)")

                    ModelVerificationView(path: filePath,
                                          pinnedSHA256: model.sha256,
                                          viewModel: viewModel)
                }
            } else {
                HStack(spacing: 8) {
                    Text(model.sizeString)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button(action: {
                        Task {
                            do {
                                try await viewModel.downloadQwen3ASRModel(model)
                            } catch is CancellationError {
                                // A cancelled download is not an error to report.
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
        }
        .padding(12)
        .background(Color(.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
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
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(model.name)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    if let pageURL = model.huggingFacePageURL,
                       let owner = huggingFaceOwner(fromPageURL: pageURL) {
                        Link(owner, destination: pageURL)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("View on Hugging Face")
                    }
                }
                
                Text(model.description)
                    .font(.caption)
                    .foregroundColor(.secondary)

                if model.isDownloaded {
                    Text("Downloaded — \(model.sizeString) on disk")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                if viewModel.isDownloading && viewModel.downloadingModelName == model.name {
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
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 6) {
                        if isSelected {
                            Label("In use", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundColor(.green)
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

                        Button("Remove") {
                            viewModel.removeDownloadedModel(named: model.filename)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Delete this model and free \(model.sizeString)")
                    }

                    // G-06: the file is on disk — this says whether it is the
                    // file the publisher signed.
                    ModelVerificationView(
                        path: WhisperModelManager.shared.modelsDirectory.appendingPathComponent(model.filename).path,
                        pinnedSHA256: model.sha256,
                        viewModel: viewModel)
                }
            } else {
                HStack(spacing: 8) {
                    Text(model.sizeString)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
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
        }
        .padding(12)
        .background(isSelected ? Color(.controlBackgroundColor).opacity(0.7) : Color(.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture {
            if model.isDownloaded && !isSelected {
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

