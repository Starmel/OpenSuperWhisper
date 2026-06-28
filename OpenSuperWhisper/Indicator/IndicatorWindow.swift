import Cocoa
import Combine
import SwiftUI

enum RecordingState: Equatable {
    case idle
    case connecting
    case recording
    case decoding
    case busy
    case error(String)
    case info(String)
}

@MainActor
protocol IndicatorViewDelegate: AnyObject {
    
    func didFinishDecoding()
}

@MainActor
class IndicatorViewModel: ObservableObject {
    @Published var state: RecordingState = .idle
    @Published var isBlinking = false
    @Published var recorder: AudioRecorder = .shared
    @Published var isVisible = false
    
    var delegate: IndicatorViewDelegate?
    private var blinkTimer: Timer?
    private var hideTimer: Timer?
    private var liveStreamingActive = false
    private var cancellables = Set<AnyCancellable>()
    
    private let recordingStore: RecordingStore
    private let transcriptionService: TranscriptionService
    private let transcriptionQueue: TranscriptionQueue
    
    init() {
        self.recordingStore = RecordingStore.shared
        self.transcriptionService = TranscriptionService.shared
        self.transcriptionQueue = TranscriptionQueue.shared
        
        recorder.$isConnecting
            .receive(on: RunLoop.main)
            .sink { [weak self] isConnecting in
                guard let self = self else { return }
                if isConnecting {
                    self.state = .connecting
                    self.stopBlinking()
                }
            }
            .store(in: &cancellables)
        
        recorder.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] isRecording in
                guard let self = self else { return }
                if isRecording {
                    self.state = .recording
                    self.startBlinking()
                }
            }
            .store(in: &cancellables)
    }
    
    var isTranscriptionBusy: Bool {
        transcriptionService.isTranscribing || transcriptionQueue.isProcessing
    }
    
    func showBusyMessage() {
        state = .busy

        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.delegate?.didFinishDecoding()
            }
        }
    }

    func showError(_ message: String) {
        state = .error(message)

        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.delegate?.didFinishDecoding()
            }
        }
    }

    /// Brief, non-alarming notice (e.g. when there was no editable field to paste into).
    func showInfo(_ message: String) {
        state = .info(message)

        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.delegate?.didFinishDecoding()
            }
        }
    }
    
    func startRecording() {
        if isTranscriptionBusy {
            showBusyMessage()
            return
        }

        // No input device — surface it instead of optimistically showing "recording" and silently
        // capturing nothing (#157). `getActiveMicrophone()` reads the cached device, so this stays
        // off the blocking AVFoundation path that the hotkey tap must avoid (#freeze).
        guard MicrophoneService.shared.getActiveMicrophone() != nil else {
            showError("No microphone available")
            return
        }

        // Show recording immediately and optimistically. Whether the mic needs a
        // connection is decided off the main thread inside `recorder.startRecording()`
        // (it touches AVFoundation/CoreAudio, which can stall); the recorder then
        // publishes `isConnecting`/`isRecording` and the Combine bindings above
        // flip this to `.connecting` when needed. Querying it here would put that
        // blocking call on the main thread — and the hotkey tap runs there (#freeze).
        state = .recording
        startBlinking()

        Task.detached { [recorder] in
            recorder.startRecording()
        }

        // Live transcription (Parakeet only): stream in parallel with the WAV recorder so the
        // indicator can show the text as the user speaks. Falls back to the file pass on stop.
        if Self.shouldUseLiveStreaming {
            liveStreamingActive = true
            let terms = AppPreferences.shared.customDictionaryEnabled
                ? CustomDictionary.boostTerms(entries: AppPreferences.shared.customDictionaryEntries)
                : []
            Task { @MainActor in
                do {
                    try await StreamingTranscriptionController.shared.start(boostTerms: terms)
                } catch {
                    print("Live streaming start failed: \(error)")
                    self.liveStreamingActive = false
                }
            }
        }
    }

    static var shouldUseLiveStreaming: Bool {
        AppPreferences.shared.liveTranscriptionEnabled && AppPreferences.shared.selectedEngine == "fluidaudio"
    }

    func startDecoding() {
        stopBlinking()
        
        if isTranscriptionBusy {
            recorder.cancelRecording()
            showBusyMessage()
            return
        }
        
        state = .decoding
        
        if let tempURL = recorder.stopRecording() {
            Task { [weak self] in
                guard let self = self else { return }
                
                do {
                    print("start decoding...")
                    // Live streaming is a preview only; the inserted text always comes from the
                    // accurate file pass. Stop the preview, then transcribe the recording.
                    if self.liveStreamingActive {
                        self.liveStreamingActive = false
                        await StreamingTranscriptionController.shared.cancel()
                    }
                    let rawText = try await transcriptionService.transcribeAudio(url: tempURL, settings: Settings())
                    var text = AppPreferences.shared.cleanTranscription(rawText)

                    // Nothing intelligible was said: never paste the placeholder — just give a
                    // brief on-screen hint and finish (don't store an empty recording either).
                    if text == TranscriptionResult.noSpeech
                        || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        try? FileManager.default.removeItem(at: tempURL)
                        await MainActor.run { self.showInfo("No speech detected") }
                        return
                    }

                    // Optional LLM cleanup (no-op when disabled; returns the raw text on failure).
                    text = await LLMPostProcessor.process(text)

                    var hookAudioPath: String? = nil
                    if AppPreferences.shared.saveTranscriptionHistory {
                        // Create a new Recording instance
                        let timestamp = Date()
                        let fileName = "\(Int(timestamp.timeIntervalSince1970)).wav"
                        let recordingId = UUID()
                        let finalURL = Recording(
                            id: recordingId,
                            timestamp: timestamp,
                            fileName: fileName,
                            transcription: text,
                            duration: 0,
                            status: .completed,
                            progress: 1.0,
                            sourceFileURL: nil
                        ).url

                        // Move the temporary recording to final location
                        try recorder.moveTemporaryRecording(from: tempURL, to: finalURL)
                        hookAudioPath = finalURL.path

                        // Save the recording to store
                        await MainActor.run {
                            self.recordingStore.addRecording(Recording(
                                id: recordingId,
                                timestamp: timestamp,
                                fileName: fileName,
                                transcription: text,
                                duration: 0,
                                status: .completed,
                                progress: 1.0,
                                sourceFileURL: nil
                            ))
                        }
                    } else {
                        // Delete the temporary recording immediately
                        try? FileManager.default.removeItem(at: tempURL)
                    }

                    let pasteTargetMissing = insertText(text)
                    print("Transcription result: \(text)")
                    PostRecordHook.runIfEnabled(text: text, audioPath: hookAudioPath, timestamp: Date(), duration: 0)
                    await MainActor.run {
                        if pasteTargetMissing {
                            self.showInfo("Copied — press ⌘V to paste")
                        } else {
                            self.delegate?.didFinishDecoding()
                        }
                    }
                    return
                } catch {
                    print("Error transcribing audio: \(error)")
                    await MainActor.run {
                        self.showError("Transcription failed: \(error.localizedDescription)")
                    }
                    return
                }
            }
        } else {
            
            print("!!! Not found record url !!!")
            
            Task {
                await MainActor.run {
                    self.delegate?.didFinishDecoding()
                }
            }
        }
    }
    
    /// Returns `true` when auto-paste ran but no editable field was focused,
    /// so the caller can surface a "copied — press ⌘V" notice. When no target
    /// is found, typing is skipped and the text is left on the clipboard.
    @discardableResult
    func insertText(_ text: String) -> Bool {
        let finalText = Self.applyPostProcessing(text)
        let prefs = AppPreferences.shared

        // Optional, independent clipboard stash (never the insertion mechanism).
        if prefs.autoCopyToClipboard {
            ClipboardUtil.copyToClipboard(finalText)
        }

        guard prefs.autoPasteTranscription else { return false }

        if prefs.pasteInsteadOfTyping {
            // Paste is universal: ⌘V lands in any text field, including apps the accessibility
            // check can't read (Messages, Electron), and is a harmless no-op otherwise (the text
            // is on the clipboard). So no editable-target gate — it only ever produces false
            // negatives that wrongly suppress a valid paste (#paste-messages).
            if !prefs.autoCopyToClipboard { ClipboardUtil.copyToClipboard(finalText) }
            Diag.measure("TextInserter.paste") { TextInserter.paste() }
            return false
        }

        // Typing mode: synthetic keystrokes go wherever focus is, so only type when we're
        // confident there's an editable target; otherwise stash on the clipboard and notify ⌘V.
        let targetMissing = prefs.notifyWhenNoPasteTarget
            && Diag.measure("focusedElementIsEditable") { FocusUtils.focusedElementIsEditable() } == false
        if targetMissing {
            if !prefs.autoCopyToClipboard {
                ClipboardUtil.copyToClipboard(finalText)
            }
            return true
        }
        Diag.measure("TextInserter.type") { TextInserter.type(finalText) }
        return false
    }
    
    static func applyPostProcessing(_ text: String) -> String {
        guard AppPreferences.shared.addSpaceAfterSentence else { return text }
        // Some models emit run-on sentences with no space after the period ("regularly.Using" — #107).
        // Insert one when a lowercase word-end is immediately followed by sentence punctuation and an
        // uppercase letter; the lowercase/uppercase guard leaves decimals (3.14) and acronyms (U.S.A) alone.
        var result = text.replacingOccurrences(
            of: "([a-z])([.!?])([A-Z])",
            with: "$1$2 $3",
            options: .regularExpression)
        // Trailing space after a finished sentence so the next dictation doesn't run into it.
        if let lastChar = result.last, lastChar.isPunctuation {
            result += " "
        }
        return result
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
        hideTimer?.invalidate()
        hideTimer = nil
        cancellables.removeAll()
    }

    func cancelRecording() {
        hideTimer?.invalidate()
        hideTimer = nil
        recorder.cancelRecording()
        if liveStreamingActive {
            liveStreamingActive = false
            Task { await StreamingTranscriptionController.shared.cancel() }
        }
    }

    @MainActor
    func hideWithAnimation() async {
        await withCheckedContinuation { continuation in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                self.isVisible = false
            } completion: {
                continuation.resume()
            }
        }
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

struct IndicatorWindow: View {
    @ObservedObject var viewModel: IndicatorViewModel
    @ObservedObject private var streaming = StreamingTranscriptionController.shared
    @ObservedObject private var notch = NotchTuning.shared
    @Environment(\.colorScheme) private var colorScheme
    
    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.24)
            : Color.white.opacity(0.24)
    }

    /// Wider while live-recording so the growing caption fits inside the bubble; compact otherwise.
    private var bubbleWidth: CGFloat {
        if isNotchMode {
            // Idle width is tunable; it only expands once there is actual caption text to show.
            let hasCaption = !streaming.confirmedText.isEmpty || !streaming.volatileText.isEmpty
            return hasCaption ? max(notch.width, 440) : notch.width
        }
        let live = viewModel.state == .recording && IndicatorViewModel.shouldUseLiveStreaming
        return live ? 380 : 200
    }
    
    private var isNotchMode: Bool { AppPreferences.shared.indicatorPosition == "notch" }

    var body: some View {

        // Notch mode uses the real notch silhouette (concave top wings + rounded bottom).
        let rect: AnyShape = isNotchMode
            ? AnyShape(NotchShape(topRadius: notch.topRadius, bottomRadius: notch.bottomRadius))
            : AnyShape(RoundedRectangle(cornerRadius: 24))

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
                if streaming.confirmedText.isEmpty && streaming.volatileText.isEmpty {
                    // Before any text arrives, just the dot + label, vertically centered.
                    HStack(alignment: .center, spacing: 10) {
                        RecordingIndicator(isBlinking: viewModel.isBlinking)
                            .frame(width: 16)
                        Text("Recording…")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                } else {
                    // Once text starts, drop the label: just the dot + the text, which grows
                    // (the window resizes to fit it) so everything stays visible.
                    HStack(alignment: .top, spacing: 10) {
                        RecordingIndicator(isBlinking: viewModel.isBlinking)
                            .frame(width: 16)
                            .padding(.top, 3)
                        (Text(streaming.confirmedText).foregroundColor(.primary)
                            + Text(streaming.confirmedText.isEmpty ? "" : " ")
                            + Text(streaming.volatileText).foregroundColor(.secondary))
                            .font(.system(size: 14))
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(width: 300, alignment: .leading)
                    }
                }

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
                
            case .error(let message):
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .frame(width: 24)

                    Text(message)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.red)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .info(let message):
                HStack(spacing: 8) {
                    Image(systemName: "doc.on.clipboard")
                        .foregroundColor(.accentColor)
                        .frame(width: 24)

                    Text(message)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, isNotchMode ? 22 : 24)
        .padding(.vertical, isNotchMode ? 10 : 12)
        // Width must be set *before* the background so the bubble itself fills it (not just the
        // surrounding frame). Notch content is centred; the others stay leading.
        .frame(minHeight: isNotchMode ? notch.height : 36)
        .frame(width: bubbleWidth, alignment: isNotchMode ? .center : .leading)
        .background {
            if isNotchMode {
                rect
                    .fill(.black)
                    .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 3)
            } else {
                rect
                    .fill(backgroundColor)
                    .background {
                        rect
                            .fill(Material.thinMaterial)
                    }
                    .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 4)
            }
        }
        .clipShape(rect)
        .environment(\.colorScheme, isNotchMode ? .dark : colorScheme)
        // Notch drops in from the top edge; the others rise from below.
        .scaleEffect(viewModel.isVisible ? 1 : (isNotchMode ? 0.85 : 0.5), anchor: isNotchMode ? .top : .center)
        .offset(y: viewModel.isVisible ? 0 : (isNotchMode ? -20 : 20))
        .opacity(viewModel.isVisible ? 1 : 0)
        // Entrance only: scale/offset/opacity are render transforms that don't change the
        // view's layout size, so they're safe to animate.
        .animation(.spring(response: 0.35, dampingFraction: 0.72), value: viewModel.isVisible)
        // NOTE: Do NOT add implicit animations on values that change the bubble's *size*
        // (bubbleWidth, the streaming caption text, height, etc.). This window is hosted with
        // `sizingOptions = .preferredContentSize`, so it resizes to fit this content. Animating
        // the size makes SwiftUI drive an animated window resize (NSHostingView
        // .updateAnimatedWindowSize), which on macOS 26 re-enters layout synchronously and
        // recurses until the main-thread stack overflows (crash: "Thread stack size exceeded
        // due to excessive recursion"). Let size changes snap in a single layout pass instead.
        .onAppear {
            viewModel.isVisible = true
        }
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
        vm.startDecoding()
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
