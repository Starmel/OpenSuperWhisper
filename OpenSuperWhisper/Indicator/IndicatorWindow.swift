import Cocoa
import Combine
import SwiftUI

enum RecordingState: Equatable {
    case idle
    case connecting
    case recording
    case decoding
    case busy
    case noMicrophone
    /// The selected speech model cannot hear the dictation's language — refused
    /// rather than transcribed into invented English, and the recording kept for
    /// the user. The notice is the line the panel shows; no alert accompanies it.
    case incompatibleModel(KeptRecordingNotice)
}

/// The panel's line for a dictation that was refused because the model cannot
/// hear its language, and kept.
///
/// A recording kept without a path the user can find is the same as a lost one,
/// so the line carries all three things that matter: what went wrong, the one
/// action, and where the recording is. The card is 200pt wide, so they are three
/// short lines rather than one sentence.
struct KeptRecordingNotice: Equatable {
    /// What the model could not do, e.g. "Can't hear Polish".
    let problem: String
    /// The one action, e.g. "Install a multilingual model in Settings".
    let action: String
    /// Where the recording is, e.g. "Kept in the Transcriptions Directory" — or
    /// the honest alternative when it could not be kept.
    let location: String
}

@MainActor
protocol IndicatorViewDelegate: AnyObject {
    
    @discardableResult
    func didFinishDecoding(from viewModel: IndicatorViewModel) -> Bool
}

@MainActor
class IndicatorViewModel: ObservableObject {
    static let cancelConfirmationThreshold: TimeInterval = 10.0
    static let cancelConfirmationWindow: TimeInterval = 5.0
    
    @Published var state: RecordingState = .idle
    @Published var isBlinking = false
    @Published var isConfirmingCancel = false
    @Published var recorder: AudioRecorder = .shared
    
    var recordingStartedAt: Date?
    
    var delegate: IndicatorViewDelegate?
    private var blinkTimer: Timer?
    private var hideTimer: Timer?
    private var confirmCancelTimer: Timer?
    private var decodingTask: Task<Void, Never>?
    private var decodingSessionID: UUID?
    private var recordingSessionID: UUID?
    private var cancellables = Set<AnyCancellable>()
    
    private let recordingStore: RecordingStore
    private let transcriptionService: TranscriptionService
    private let transcriptionQueue: TranscriptionQueue
    private let stopRecordingOperation: () async -> RecordedAudio?
    private let cancelAudioRecordingOperation: () -> Void
    private let injectTextOperation: (String) -> KeyboardSimulator.InjectionResult
    private let transformTextOperation: (String, String?, Bool) async -> TransformService.TransformOutcome
    private let cleanUpOperation: (String) -> DictationScrubber.Result
    private let cleanUpEnabledOperation: () -> Bool
    private let reportCenter: DictationReportCenter

    init(
        transcriptionService: TranscriptionService = .shared,
        recordingStore: RecordingStore = .shared,
        stopRecording: @escaping () async -> RecordedAudio? = {
            await AudioRecorder.shared.stopRecording()
        },
        cancelAudioRecording: @escaping () -> Void = {
            AudioRecorder.shared.cancelRecording()
        },
        injectText: @escaping (String) -> KeyboardSimulator.InjectionResult = {
            // The live watch captures the delivery target as the delivery
            // begins and stops it if the target changes or the user types; the
            // ladder picks the mechanism from the application being typed into,
            // and records which one it was — see `TextDelivery`.
            TextDelivery.deliver($0, watch: .live())
        },
        transformText: @escaping (String, String?, Bool) async -> TransformService.TransformOutcome = {
            await TransformService.shared.transformDetailed($0, sourceLanguage: $1, email: $2)
        },
        cleanUp: @escaping (String) -> DictationScrubber.Result = { text in
            // The switch is read per dictation, so flipping it in Settings takes
            // effect on the next one — and the scrub itself is a pure function
            // with no model behind it.
            guard AppPreferences.shared.cleanUpEnabled else {
                return DictationScrubber.Result(
                    text: text,
                    removedFillers: 0,
                    removedRepetitions: 0,
                    removedAnnotations: 0
                )
            }
            return DictationScrubber.scrub(text)
        },
        cleanUpEnabled: @escaping () -> Bool = { AppPreferences.shared.cleanUpEnabled },
        reportCenter: DictationReportCenter = .shared
    ) {
        self.recordingStore = recordingStore
        self.transcriptionService = transcriptionService
        self.transcriptionQueue = TranscriptionQueue.shared
        self.stopRecordingOperation = stopRecording
        self.cancelAudioRecordingOperation = cancelAudioRecording
        self.injectTextOperation = injectText
        self.transformTextOperation = transformText
        self.cleanUpOperation = cleanUp
        self.cleanUpEnabledOperation = cleanUpEnabled
        self.reportCenter = reportCenter
        
        recorder.$startFailure
            .compactMap { $0 }
            .sink { [weak self] failure in
                guard let self, self.recordingSessionID == failure.sessionID else { return }
                self.resetAfterRecordingFailure()
                AppErrorCenter.shared.report("Recording failed", message: failure.message)
            }
            .store(in: &cancellables)

        recorder.$isConnecting
            .receive(on: RunLoop.main)
            .sink { [weak self] isConnecting in
                guard let self, let id = self.recordingSessionID,
                      RecordingSessionController.shared.currentID == id,
                      RecordingSessionController.shared.isCapturing else { return }
                if isConnecting && self.recorder.isConnecting {
                    self.state = .connecting
                    self.stopBlinking()
                }
            }
            .store(in: &cancellables)
        
        recorder.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] isRecording in
                guard let self, let id = self.recordingSessionID,
                      RecordingSessionController.shared.currentID == id,
                      RecordingSessionController.shared.isCapturing else { return }
                if isRecording && self.recorder.isRecording {
                    self.state = .recording
                    self.startBlinking()
                }
            }
            .store(in: &cancellables)
    }
    
    var isTranscriptionBusy: Bool {
        transcriptionService.isLoading || transcriptionService.isTranscribing || transcriptionQueue.isProcessing
    }
    
    func showBusyMessage() {
        showAutoDismissingMessage(.busy)
    }

    private func showAutoDismissingMessage(_ message: RecordingState) {
        state = message

        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                _ = self.delegate?.didFinishDecoding(from: self)
            }
        }
    }

    func resetAfterRecordingFailure() {
        RecordingSessionController.shared.finish(recordingSessionID)
        recordingSessionID = nil
        state = .idle
        stopBlinking()
        recordingStartedAt = nil
        resetCancelConfirmation()
        _ = delegate?.didFinishDecoding(from: self)
    }

    func startRecording() {
        // The microphone is checked before the busy state, not after it. The
        // engine load starts inside TranscriptionService's own initializer, so
        // "busy" is the normal state for the first seconds after launch - and the
        // old order answered "Processing..." to every attempt in that window,
        // never mentioning the input device the user is missing. A missing
        // microphone is a precondition for recording; busy only describes work
        // that is already running.
        //
        // getActiveMicrophone() only reads the cached currentMicrophone, so
        // this guard costs no CoreAudio HAL round-trip on the main thread.
        guard MicrophoneService.shared.getActiveMicrophone() != nil else {
            showAutoDismissingMessage(.noMicrophone)
            return
        }

        if isTranscriptionBusy {
            showBusyMessage()
            return
        }
        
        // Optimistically assume recording: querying the microphone here costs
        // CoreAudio HAL round-trips on the main thread right before the appear
        // animation. The recorder resolves the real state on its own queue and
        // publishes isConnecting/isRecording, which the sinks above translate
        // into .connecting/.recording.
        guard let id = RecordingSessionController.shared.begin(stop: { self.decodeRecording() }) else { return }
        recordingSessionID = id
        state = .recording
        startBlinking()
        recordingStartedAt = Date()
        
        recorder.startRecording(sessionID: id)
    }
    
    func handleCancelRequest() -> Bool {
        guard state == .recording,
              !AppPreferences.shared.escCancelWithoutConfirmation,
              !isConfirmingCancel,
              let startedAt = recordingStartedAt,
              Date().timeIntervalSince(startedAt) >= Self.cancelConfirmationThreshold
        else {
            return true
        }
        
        isConfirmingCancel = true
        confirmCancelTimer?.invalidate()
        confirmCancelTimer = Timer.scheduledTimer(withTimeInterval: Self.cancelConfirmationWindow, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.resetCancelConfirmation()
            }
        }
        return false
    }
    
    private func resetCancelConfirmation() {
        confirmCancelTimer?.invalidate()
        confirmCancelTimer = nil
        isConfirmingCancel = false
    }
    
    func startDecoding() {
        if RecordingSessionController.shared.hasSession {
            RecordingSessionController.shared.requestStop()
        } else {
            decodeRecording()
        }
    }

    private func decodeRecording() {
        // A second stop request (double hotkey press, hold-mode key-up) must not
        // restart decoding or hide the window while transcription is in flight.
        guard state == .recording || state == .connecting else { return }
        
        resetCancelConfirmation()
        stopBlinking()
        
        if isTranscriptionBusy {
            // The engine is busy with another transcription: keep the user's audio
            // and put it into the queue instead of deleting it.
            Task { [weak self] in
                guard let self = self else { return }
                defer {
                    RecordingSessionController.shared.finish(self.recordingSessionID)
                    self.recordingSessionID = nil
                }
                if let audio = await self.stopRecordingOperation() {
                    await self.transcriptionQueue.addFileToQueue(url: audio.url)
                }
            }
            showBusyMessage()
            return
        }
        
        state = .decoding

        let sessionID = UUID()
        decodingSessionID = sessionID
        decodingTask = Task { [weak self] in
            guard let self = self else { return }

            guard let audio = await self.stopRecordingOperation() else {
                print("!!! Not found record url !!!")
                self.finishDecoding(sessionID: sessionID)
                return
            }
            let tempURL = audio.url
            var savedRecording: Recording?

            do {
                try Task.checkCancellation()
                guard self.decodingSessionID == sessionID else {
                    throw CancellationError()
                }

                print("start decoding...")
                let duration = audio.duration
                try Task.checkCancellation()
                guard self.decodingSessionID == sessionID else {
                    throw CancellationError()
                }

                let output = try await transcriptionService.transcribeAudio(
                    url: tempURL,
                    settings: Settings(),
                    operationID: sessionID,
                    pcmSamples: audio.samples
                )
                let rawText = output.text
                try Task.checkCancellation()
                guard self.decodingSessionID == sessionID else {
                    throw CancellationError()
                }

                // The deterministic clean-up runs first and without a model:
                // filler, stutters, repeated words and the recogniser's own
                // annotations are gone before anything is asked of a transform.
                // History keeps the raw transcript either way.
                let scrub = self.cleanUpOperation(rawText)
                // The spoken trigger picks the e-mail mode, and the phrase is
                // taken off the front: what is left is the body the model is
                // asked to shape into an e-mail. A phrase with nothing after it
                // is a dictation with no body, and is discarded like one.
                let spoken = DictationTrigger.email(in: scrub.text)
                let body = spoken?.body ?? scrub.text
                let isEmail = spoken != nil && !body.isEmpty
                let text = body

                if text.isEmpty {
                    try? FileManager.default.removeItem(at: tempURL)
                    print(
                        spoken != nil
                            ? "The e-mail trigger carried no body; dictation discarded"
                            : (rawText.isEmpty
                                ? "No speech detected, dictation discarded"
                                : "Nothing but filler or an annotation; dictation discarded")
                    )
                } else {
                    let timestamp = Date()
                    let recordingId = UUID()
                    let fileName = Recording.fileName(for: recordingId)
                    let newRecording = Recording(
                        id: recordingId,
                        timestamp: timestamp,
                        fileName: fileName,
                        transcription: rawText,
                        duration: duration,
                        status: .completed,
                        progress: 1.0,
                        sourceFileURL: nil
                    )

                    try recorder.moveTemporaryRecording(from: tempURL, to: newRecording.url)
                    savedRecording = newRecording
                    do { try await self.recordingStore.addRecordingSync(newRecording) }
                    catch { throw PreservedAudioError(url: newRecording.url, underlying: error) }

                    try Task.checkCancellation()
                    guard self.decodingSessionID == sessionID else { throw CancellationError() }
                    let outcome = await transformTextOperation(text, output.language, isEmail)
                    try Task.checkCancellation()
                    guard self.decodingSessionID == sessionID else { throw CancellationError() }
                    self.reportCenter.publish(DictationReport(
                        language: output.language,
                        raw: rawText,
                        cleaned: text,
                        final: outcome.text,
                        policy: outcome.policy,
                        didRunModel: outcome.didRunModel,
                        guardRejection: outcome.guardRejection,
                        cleanUpEnabled: cleanUpEnabledOperation(),
                        removedFillers: scrub.removedFillers,
                        removedRepetitions: scrub.removedRepetitions,
                        removedAnnotations: scrub.removedAnnotations,
                        date: timestamp
                    ))
                    insertText(outcome.text)
                    print("Transcription result: \(rawText)")
                }
            } catch is CancellationError {
                if let savedRecording {
                    do { try await Task { try await recordingStore.deleteRecordingSync(savedRecording, cancelTranscription: false) }.value }
                    catch { AppErrorCenter.shared.report("Cancelled recording could not be removed", error: error) }
                } else {
                    try? FileManager.default.removeItem(at: tempURL)
                }
                print("Transcription cancelled")
            } catch {
                if Task.isCancelled || self.decodingSessionID != sessionID {
                    if let savedRecording {
                        do { try await Task { try await recordingStore.deleteRecordingSync(savedRecording, cancelTranscription: false) }.value }
                        catch { AppErrorCenter.shared.report("Cancelled recording could not be removed", error: error) }
                    } else {
                        try? FileManager.default.removeItem(at: tempURL)
                    }
                    print("Transcription cancelled")
                } else {
                    // The one decision every surface shares: a failure that is
                    // silence leaves no alert and no history row, and the audio
                    // goes with it — or is kept, with a row that records it, when
                    // the audio is the user's. A genuine failure keeps today's
                    // report and its audio.
                    let source = (error as? PreservedAudioError)?.url ?? audio.url
                    let outcome = DictationFailurePolicy.outcome(for: error)
                    let keptURL = await DictationFailurePolicy.settle(
                        RecordedAudio(url: source, samples: audio.samples),
                        error: error,
                        store: self.recordingStore
                    )
                    switch outcome {
                    case .discard:
                        print("Dictation discarded: the recording held no speech")
                    case .keepAudio:
                        print("Dictation refused for no speech; the recording was kept")
                    case .keepAudioAndExplain:
                        // Real speech this model cannot hear: the recording was
                        // kept, and the panel says what happened, what to do and
                        // where it is. No alert, nothing pasted, and the kept row
                        // carries no transcript.
                        if case TranscriptionError.speechLanguageConflict(let conflict) = error {
                            self.showAutoDismissingMessage(
                                .incompatibleModel(Self.refusalNotice(conflict, keptAt: keptURL))
                            )
                        }
                    case .report:
                        break
                    }
                }
            }

            self.finishDecoding(sessionID: sessionID)
        }
    }

    /// The panel's line for a language conflict: what the model cannot hear, the
    /// one action, and where the kept recording is.
    ///
    /// The fix lives in Settings, where the model is chosen — the panel only says
    /// so. The location names the Transcriptions Directory, the Settings section
    /// that shows that folder's path and opens it: a recording kept without a
    /// place the user can find is the same as a lost one. When it could not be
    /// kept the line never claims it was, and the failure itself has already been
    /// reported with the recording's path.
    static func refusalNotice(
        _ conflict: SpeechLanguageConflict,
        keptAt: URL?
    ) -> KeptRecordingNotice {
        KeptRecordingNotice(
            problem: "Can't hear \(conflict.detectedLanguageName)",
            action: conflict.remedyModelName.map { "Select a multilingual model (\($0)) in Settings" }
                ?? "Install a multilingual model in Settings",
            location: keptAt == nil
                ? "Could not be moved out of the temporary folder"
                : "Kept in the Transcriptions Directory"
        )
    }

    private func finishDecoding(sessionID: UUID) {
        guard decodingSessionID == sessionID else { return }
        decodingSessionID = nil
        decodingTask = nil
        RecordingSessionController.shared.finish(recordingSessionID)
        recordingSessionID = nil
        _ = delegate?.didFinishDecoding(from: self)
    }
    
    func insertText(_ text: String) {
        guard !text.isEmpty else { return }
        let finalText = Self.applyPostProcessing(text)
        let prefs = AppPreferences.shared

        if prefs.autoPasteTranscription {
            // Deliver the transcription as synthetic keystrokes. When the user
            // also asked to keep it on the clipboard, copy first so the
            // "keep in clipboard" toggle still holds; otherwise leave the
            // clipboard untouched on this path.
            if prefs.autoCopyToClipboard {
                ClipboardUtil.copyToClipboard(finalText)
            }
            let result = injectTextOperation(finalText)
            KeyboardSimulator.logDictation(
                trusted: result.trusted,
                characters: finalText.count,
                injected: result.injected,
                eventsPosted: result.eventsPosted,
                deliveredCharacters: result.deliveredCharacters,
                interruptedBy: result.interruptedBy,
                mechanism: result.mechanism,
                target: result.targetBundleIdentifier,
                match: result.targetMatch
            )
            if !result.trusted {
                reportInjectionWithoutAccessibilityTrust()
            } else if let interruption = result.interruptedBy {
                // The delivery stopped itself to keep the transcript out of the
                // wrong place; say which interference did it and how much got
                // through instead of leaving the short text unexplained.
                reportInterruptedInjection(
                    interruption,
                    delivered: result.deliveredCharacters,
                    total: finalText.count
                )
            } else if !result.injected {
                // Trusted, uninterfered with, and the delivery still handed the
                // system nothing: the events could not be built, so the
                // dictation reached nowhere. That is the one outcome the
                // per-dictation record cannot show the user, so it is said out
                // loud rather than left to look delivered.
                reportInjectionThatPostedNothing(result.mechanism)
            } else if result.mechanism == .clipboardPaste {
                // Last, because it is information and not a failure: a delivery
                // that reached nobody must report that instead, not the notice
                // that would explain a delivery that worked.
                reportClipboardDeliveryOnce()
            }
        } else {
            KeyboardSimulator.logDictation(
                trusted: KeyboardSimulator.isTrustedForInjection,
                characters: finalText.count,
                injected: false,
                eventsPosted: 0
            )
            if prefs.autoCopyToClipboard {
                // Only copy to clipboard, don't paste
                ClipboardUtil.copyToClipboard(finalText)
            }
        }
        // If both are false, do nothing
    }

    /// The delivery stopped itself to keep the transcript out of the wrong
    /// place, so the user gets told what happened to the rest of it rather than
    /// finding a truncated dictation and no reason for it. The whole
    /// transcription is in the History tab either way, which is where the
    /// message points.
    private func reportInterruptedInjection(
        _ interruption: KeyboardSimulator.DeliveryInterruption,
        delivered: Int,
        total: Int
    ) {
        let whatHappened: String
        switch interruption {
        case .focusChanged:
            whatHappened = "Another application came to the front while OpenSuperWhisper was typing, so "
                + "the rest of the transcription would have been typed into that window."
        case .userTyping:
            whatHappened = "You started typing while OpenSuperWhisper was typing, so the rest of the "
                + "transcription would have been mixed into your own keystrokes."
        }
        AppErrorCenter.shared.report(
            "Transcription was not typed in full",
            message: "\(whatHappened)\n\n"
                + "Typing stopped after \(delivered) of the dictation's \(total) characters, and nothing "
                + "else was typed. The whole transcription is in the History tab."
        )
    }

    /// A dictation that went through the clipboard is said out loud, once.
    ///
    /// The paste path is the default for the applications the measurement
    /// recognised, and its failure mode is invisible from here: if the
    /// application's clipboard is not shared with the session, the paste lands
    /// nowhere and this app cannot tell — the user would simply see nothing,
    /// which is worse than seeing something wrong. So the first delivery through
    /// the clipboard says what happened, why, where the switch is, and what to
    /// look at if the text did not appear. Once per install: after that it is in
    /// the Settings copy and in every dictation's record.
    private func reportClipboardDeliveryOnce() {
        guard !AppPreferences.shared.clipboardDeliveryExplained else { return }
        AppPreferences.shared.clipboardDeliveryExplained = true
        AppErrorCenter.shared.report(
            "This dictation went through the clipboard",
            message: "The app in front is one that reads key codes rather than the text "
                + "OpenSuperWhisper types (a Citrix session, a virtual machine or a remote "
                + "desktop), so the transcription was put on the clipboard and pasted with "
                + "⌘V — and what was on the clipboard was written to disk and put back "
                + "afterwards.\n\n"
                + "If the text does not appear there, that application's clipboard is not "
                + "shared with the session, and nothing this app can see says so. "
                + "Settings → Transcription → Delivery switches to Keystrokes only.\n\n"
                + "This notice is shown once."
        )
    }

    /// The delivery was trusted and nothing interfered, and it still handed the
    /// system no event at all: the dictation reached nowhere. Nothing about that
    /// is visible to the user afterwards — the dictation looks delivered — so it
    /// is reported with the same voice as the other two failures, and the
    /// transcript is in the history either way.
    private func reportInjectionThatPostedNothing(_ mechanism: DeliveryMechanism) {
        let how = mechanism == .clipboardPaste
            ? "the ⌘V that pastes the dictation"
            : "the keystrokes that spell it out"
        AppErrorCenter.shared.report(
            "Transcription was not typed",
            message: "OpenSuperWhisper could not build \(how), so the dictation was typed nowhere. "
                + "It is saved in the History tab."
        )
    }

    /// macOS drops every event an untrusted process posts, so a dictation that
    /// reached this point was typed nowhere. Say so through the app's existing
    /// permission surface instead of letting the text look lost — the
    /// transcript stays in the history, and the grant can be restored.
    private func reportInjectionWithoutAccessibilityTrust() {
        // The permission UI reads a value refreshed while a window was key; the
        // indicator is a non-activating panel, so that value can still claim
        // the grant is present while macOS refuses the keystrokes. Ask for a
        // fresh check now rather than trusting the cached one.
        NotificationCenter.default.post(name: .accessibilityPermissionNeededForInjection, object: nil)
        AppErrorCenter.shared.report(
            "Transcription was not typed",
            message: "macOS discarded OpenSuperWhisper's simulated keystrokes because this copy of "
                + "the app is not trusted for Accessibility, so the dictation did not reach the "
                + "focused app. It is saved in the History tab.\n\n"
                + "Open System Settings › Privacy & Security › Accessibility and make sure the "
                + "OpenSuperWhisper entry for this copy is switched on. If it already looks "
                + "enabled, switch it off and on again — several builds of the app share that "
                + "name, and a grant made for a different copy does not apply to the one "
                + "running. Removing the stale row and granting the app again also works."
        )
    }
    
    static func applyPostProcessing(_ text: String) -> String {
        guard AppPreferences.shared.addSpaceAfterSentence,
              let lastChar = text.last,
              lastChar.isPunctuation else {
            return text
        }
        return text + " "
    }
    
    private func startBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            // Update UI on the main thread
            Task { @MainActor in
                guard let self = self else { return }
                self.isBlinking.toggle()
            }
        }
    }
    
    private func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        isBlinking = false
    }

    func cleanup() {
        stopBlinking()
        resetCancelConfirmation()
        recordingStartedAt = nil
        hideTimer?.invalidate()
        hideTimer = nil
        cancellables.removeAll()
    }

    func cancelRecording() {
        hideTimer?.invalidate()
        hideTimer = nil

        if state == .decoding {
            // In decoding the recorder is already stopped. Cancel both the
            // Swift task and the native engine operation, and invalidate the
            // session before either can save or paste a late result.
            let cancelledSessionID = decodingSessionID
            decodingSessionID = nil
            decodingTask?.cancel()
            decodingTask = nil
            if let cancelledSessionID {
                transcriptionService.cancelTranscription(
                    operationID: cancelledSessionID
                )
            }
        }

        if state != .decoding {
            cancelAudioRecordingOperation()
        }
        RecordingSessionController.shared.finish(recordingSessionID)
        recordingSessionID = nil
    }
}

struct RecordingIndicator: View {
    let isBlinking: Bool
    
    var body: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.red.opacity(0.8),
                        Color.red
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 8, height: 8)
            .shadow(color: .red.opacity(0.5), radius: 4)
            .opacity(isBlinking ? 0.3 : 1.0)
            .animation(.easeInOut(duration: 0.4), value: isBlinking)
    }
}

struct CancelConfirmationBar: View {
    @State private var progress: CGFloat = 1
    
    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(Color.orange)
                .frame(width: geo.size.width * progress, height: 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 2)
        .padding(.horizontal, 12)
        .padding(.bottom, 3)
        .onAppear {
            withAnimation(.linear(duration: IndicatorViewModel.cancelConfirmationWindow)) {
                progress = 0
            }
        }
    }
}

struct IndicatorWindow: View {
    /// Geometry shared with IndicatorWindowManager. The panel must be larger
    /// than the card: everything drawn outside the window bounds is cut off,
    /// so the appear offset (moves the card down) and the spring overshoot
    /// need margins, otherwise the card edges are visibly clipped mid-animation.
    static let cardSize = CGSize(width: 200, height: 36)
    static let windowSize = CGSize(width: 256, height: 96)
    static let appearOffset: CGFloat = 20
    static let appearInitialScale: CGFloat = 0.5
    
    @ObservedObject var viewModel: IndicatorViewModel
    @Environment(\.colorScheme) private var colorScheme
    
    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.24)
            : Color.white.opacity(0.24)
    }
    
    var body: some View {

        let rect = RoundedRectangle(cornerRadius: 24)
        
        VStack(spacing: 12) {
            switch viewModel.state {
            case .connecting:
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 24)
                    
                    Text("Connecting...")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
            case .recording:
                HStack(spacing: 8) {
                    RecordingIndicator(isBlinking: viewModel.isBlinking)
                        .frame(width: 24)
                    
                    if viewModel.isConfirmingCancel {
                        Text("Press Esc to cancel")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.orange)
                            .transition(.opacity)
                    } else {
                        Text("Recording...")
                            .font(.system(size: 13, weight: .semibold))
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeInOut(duration: 0.2), value: viewModel.isConfirmingCancel)
                
            case .decoding:
                HStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 24)
                    
                    Text("Transcribing...")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
            case .busy:
                HStack(spacing: 8) {
                    Image(systemName: "hourglass")
                        .foregroundColor(.orange)
                        .frame(width: 24)

                    Text("Processing...")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.orange)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .noMicrophone:
                HStack(spacing: 8) {
                    Image(systemName: "mic.slash")
                        .foregroundColor(.orange)
                        .frame(width: 24)

                    Text("No microphone")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.orange)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .incompatibleModel(let notice):
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "waveform.slash")
                        .foregroundColor(.orange)
                        .frame(width: 24)

                    // Three short lines rather than one: the card is 200pt wide
                    // with 24pt of padding a side, so a single sentence would be
                    // shrunk past reading. What the model cannot hear, the one
                    // action, and where the kept recording is.
                    VStack(alignment: .leading, spacing: 1) {
                        Text(notice.problem)
                        Text(notice.action)
                        Text(notice.location)
                    }
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.orange)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, 24)
        .frame(height: Self.cardSize.height)
        .background {
            rect
                .fill(backgroundColor)
                .background {
                    rect
                        .fill(Material.thinMaterial)
                }
        }
        .overlay(alignment: .bottom) {
            if viewModel.isConfirmingCancel {
                CancelConfirmationBar()
            }
        }
        .clipShape(rect)
        .frame(width: Self.cardSize.width)
        // The ideal size of the root view must match the panel: NSHostingView
        // resizes the window down to SwiftUI's ideal size, and a window sized
        // to the bare card clips the appear offset, bounce overshoot and shadow.
        .frame(width: Self.windowSize.width, height: Self.windowSize.height)
        // The appear/hide animation is NOT done in SwiftUI on purpose:
        // animating scaleEffect/offset/opacity re-rasterizes the card (material
        // + gradients + shadow) on the CPU every frame and stalls the main
        // thread in CABackingStoreUpdate/wait_for_synchronize (20-60 ms per
        // frame in traces). IndicatorWindowManager animates the hosting view's
        // layer with CASpringAnimation instead: content is drawn once and the
        // spring runs entirely in the render server on the GPU.
    }
}

struct IndicatorWindowPreview: View {
    @StateObject private var recordingVM = {
        let vm = IndicatorViewModel()
//        vm.startRecording()
        return vm
    }()
    
    @StateObject private var decodingVM = {
        let vm = IndicatorViewModel()
        vm.state = .decoding
        return vm
    }()
    
    var body: some View {
        VStack(spacing: 20) {
            IndicatorWindow(viewModel: recordingVM)
            IndicatorWindow(viewModel: decodingVM)
        }
        .padding()
        .frame(height: 200)
        .background(Color(.windowBackgroundColor))
    }
}

#Preview {
    IndicatorWindowPreview()
}
