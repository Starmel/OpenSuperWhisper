//
//  TransformRuntime.swift
//  OpenSuperWhisper
//
//  The in-process transform runtime: one llama.cpp model, loaded on demand,
//  serialized, warmed up ahead of the first dictation and released when idle.
//

import Foundation

/// A one-shot cancellation flag shared between the caller's task and the decode
/// loop running on the runtime's queue.
final class CancellationFlag {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Owns the single in-process llama.cpp model of the app.
///
/// Everything that touches the model runs on one serial queue: a llama context
/// is not thread-safe, and dictation is sequential anyway. The model is released
/// after `idleUnloadInterval` without a request, so the weights it holds are
/// only resident while the feature is actually in use.
///
/// One model at a time, by design: a dictation runs on the model its language
/// resolves to (`TransformModelManager.model(for:)`) — and with the catalogue
/// down to one entry the runtime never has a second one to hold, so the swap in
/// `loadedModel(for:)` is the guard for a catalogue that grows again rather than
/// a step this build can take. Polish reaches no model at all, so the resident
/// backend is always the English one.
final class TransformRuntime {
    static let shared = TransformRuntime()

    /// How long the weights stay resident after the last transform.
    static let idleUnloadInterval: TimeInterval = 10 * 60

    private let queue = DispatchQueue(
        label: "ru.starmel.OpenSuperWhisper.transform",
        qos: .userInitiated
    )
    private let stateLock = NSLock()
    private var model: LlamaModel?
    /// The catalogue id of `model`, so a request for the other direction can
    /// tell whether what is resident is the right backend.
    private var residentModelID: String?
    private var lastUse = Date.distantPast
    private var idleTimer: DispatchSourceTimer?

    /// The catalogue the runtime loads from. Injectable so a test can drive real
    /// weights staged outside the user's Application Support, exactly like
    /// `TransformModelManager(directory:catalogue:)`.
    private let models: TransformModelManager

    /// How long the weights stay resident after the last transform. Defaults to
    /// the shipped window; injectable so a test can watch the timer actually
    /// fire without sitting here for ten minutes.
    private let idleUnloadInterval: TimeInterval

    init(
        models: TransformModelManager = .shared,
        idleUnloadInterval: TimeInterval = TransformRuntime.idleUnloadInterval
    ) {
        self.models = models
        self.idleUnloadInterval = idleUnloadInterval
    }

    /// Whether weights are currently resident. Read by the settings UI.
    var isLoaded: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return model?.isLoaded ?? false
    }

    /// The catalogue id of the resident backend, or `nil` when nothing is
    /// loaded. One backend is resident at a time, so this is also the answer to
    /// "which one is in memory right now".
    var loadedModelID: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let model, model.isLoaded else { return nil }
        return residentModelID
    }

    // MARK: - Public API

    /// Runs one transform in process, on `model`'s weights.
    ///
    /// Throws on every failure (missing model, load failure, decode failure,
    /// cancellation); `TransformService` turns that into the raw transcript.
    /// The model handed in is the one the language's preference resolved to, so
    /// nothing is substituted here: the caller already decided, and a model
    /// missing from disk is a miss to report rather than a reason to use another.
    func transform(systemPrompt: String, userText: String, model: TransformModel) async throws -> String {
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    do {
                        let text = try run(
                            systemPrompt: systemPrompt,
                            userText: userText,
                            model: model,
                            isCancelled: { cancellation.isCancelled }
                        )
                        continuation.resume(returning: text)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    /// Warms up only when the transform could actually run: a switch is on. The
    /// app must never hold a multi-gigabyte model for a feature that is off.
    ///
    /// Which language the next dictation will be in cannot be known before the
    /// speech is in, and the language is what picks the model — so this does not
    /// choose a language. It keeps the backend the last dictation used (the best
    /// predictor there is, and its weights are already paid for), and otherwise
    /// warms the model the current switches imply, resolved through the same
    /// `model(for:)` the dictation path uses. English stands in for the language
    /// the speech has not revealed, which is the backend almost every dictation
    /// uses: S1-mini, the one model there is. A Polish dictation is delivered
    /// raw, so nothing is warmed for it.
    func warmUpIfEnabled() {
        let prefs = AppPreferences.shared
        guard prefs.toneEnabled || prefs.cleanUpEnabled else { return }
        guard !isLoaded else { return }
        warmUp(for: models.model(for: Self.warmUpPolicy(
            toneEnabled: prefs.toneEnabled,
            toneMode: prefs.transformToneMode
        )))
    }

    /// Which job the warm-up prepares for — the switches only, because no
    /// language is known yet.
    ///
    /// The register and the job do not matter: every English policy resolves to
    /// the same model, so `.english` stands in for the language the speech has
    /// not revealed, and the switches only decide whether anything is warmed at
    /// all.
    static func warmUpPolicy(toneEnabled: Bool, toneMode: ToneMode) -> TransformPolicy {
        toneEnabled ? .tone(language: .english, tone: toneMode) : .cleanUp(language: .english)
    }

    /// Loads `model`'s weights and runs one throwaway decode, so the first
    /// dictation does not pay for Metal pipeline creation and the weight
    /// mapping. The llama.cpp counterpart of
    /// `TranscriptionService.prepareForRecording()` — and what hides a model's
    /// ~3.2 s cold load behind the user's own speech.
    ///
    /// A no-op when that model is not installed, and never throws: a failure
    /// here must not disturb dictation.
    func warmUp(for model: TransformModel) {
        queue.async { [self] in
            if let resident = self.model, resident.isLoaded, residentModelID == model.id {
                lastUse = Date()
                return
            }
            do {
                let loaded = try loadedModel(for: model)
                _ = try loaded.complete(
                    systemPrompt: "You are a helpful assistant.",
                    userText: "Hi",
                    assistantPrefix: model.style.assistantPrefix,
                    greedy: model.style.isGreedy
                )
                lastUse = Date()
                scheduleIdleUnload()
                print("[TransformRuntime] warmed up \(model.id)")
            } catch {
                print("[TransformRuntime] warm-up skipped for \(model.id): \(error)")
            }
        }
    }

    /// Releases the weights. Called on idle, when a model is removed, and on
    /// application termination — hence synchronous: the process may be about to
    /// exit and the caller should be able to say the memory really was given
    /// back.
    func unload() {
        queue.sync {
            if releaseResident() {
                print("[TransformRuntime] unloaded")
            }
        }
    }

    /// Releases the weights only when they are the ones `modelID` names, so
    /// removing one backend's file does not evict the other one that is in use.
    func unloadIfResident(modelID: String) {
        queue.sync {
            guard residentModelID == modelID, releaseResident() else { return }
            print("[TransformRuntime] unloaded the removed \(modelID)")
        }
    }

    // MARK: - Queue-confined work

    private func run(
        systemPrompt: String,
        userText: String,
        model: TransformModel,
        isCancelled: () -> Bool
    ) throws -> String {
        let loaded = try loadedModel(for: model)
        let output = try loaded.complete(
            systemPrompt: systemPrompt,
            userText: userText,
            // The model's own input contract, not the app's preference: the
            // normalizer's assistant turn opens with its empty think block and
            // its answers are decoded greedily, and an instruct model takes
            // neither.
            assistantPrefix: model.style.assistantPrefix,
            greedy: model.style.isGreedy,
            isCancelled: isCancelled
        )
        lastUse = Date()
        scheduleIdleUnload()
        return output
    }

    private func loadedModel(for requested: TransformModel) throws -> LlamaModel {
        if let resident = model, resident.isLoaded, residentModelID == requested.id {
            return resident
        }

        // A different model has to be loaded: the other one's weights must go
        // before this one is mapped, or the app would be holding both. A job
        // change swaps the model too, not only a language change.
        if releaseResident() {
            print("[TransformRuntime] unloaded the previous model for a different model")
        }

        guard let path = models.verifiedPath(for: requested) else {
            // `verifiedPath` returns nil for two repairs that look the same and
            // are not: a weight file that is not there is fixed by downloading
            // it, and one that is there but does not verify is fixed by
            // downloading it again. The user's next step differs, so one
            // sentence cannot carry both.
            if FileManager.default.fileExists(atPath: models.fileURL(for: requested).path) {
                throw TransformModelError.notVerified(requested.displayName)
            }
            throw TransformModelError.notInstalled(requested.displayName)
        }
        let created = try LlamaModel(modelPath: path)
        stateLock.lock()
        model = created
        residentModelID = requested.id
        stateLock.unlock()
        print("[TransformRuntime] loaded \(requested.id)")
        return created
    }

    /// Drops the resident weights, whatever they are. Queue-confined. Returns
    /// whether there were any.
    @discardableResult
    private func releaseResident() -> Bool {
        idleTimer?.cancel()
        idleTimer = nil
        stateLock.lock()
        let resident = model
        model = nil
        residentModelID = nil
        stateLock.unlock()
        resident?.unload()
        return resident != nil
    }

    /// One repeating timer per residency window; it only unloads once the model
    /// has been untouched for a whole interval.
    private func scheduleIdleUnload() {
        guard idleTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + idleUnloadInterval, repeating: 60)
        timer.setEventHandler { [self] in
            guard Date().timeIntervalSince(lastUse) >= idleUnloadInterval else { return }
            if releaseResident() {
                print("[TransformRuntime] unloaded after \(Int(idleUnloadInterval))s idle")
            }
        }
        idleTimer = timer
        timer.resume()
    }
}
