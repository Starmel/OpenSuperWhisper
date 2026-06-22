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
        
        if MicrophoneService.shared.isActiveMicrophoneRequiresConnection() {
            state = .connecting
            stopBlinking()
        } else {
            state = .recording
            startBlinking()
        }
        
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
                    let text = AppPreferences.shared.cleanTranscription(rawText)

                    // Nothing intelligible was said: never paste the placeholder — just give a
                    // brief on-screen hint and finish (don't store an empty recording either).
                    if text == TranscriptionResult.noSpeech
                        || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        try? FileManager.default.removeItem(at: tempURL)
                        await MainActor.run { self.showInfo("No speech detected") }
                        return
                    }

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
                        self.showError("Transcription failed")
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
    
    /// Returns `true` when auto-paste ran but no editable field was focused, so the
    /// caller can surface a "copied — press ⌘V" notice. The paste is always attempted
    /// (never suppressed), so a wrong detection can never swallow a working paste.
    @discardableResult
    func insertText(_ text: String) -> Bool {
        let finalText = Self.applyPostProcessing(text)
        let prefs = AppPreferences.shared

        if prefs.autoPasteTranscription {
            // Check the focus target BEFORE pasting (our own Cmd+V could change it).
            let targetMissing = prefs.notifyWhenNoPasteTarget
                && FocusUtils.focusedElementIsEditable() == false

            // Keep the text on the clipboard whenever we'll warn, so "press ⌘V" is
            // actionable even if "copy to clipboard" is turned off.
            if targetMissing || prefs.autoCopyToClipboard {
                ClipboardUtil.insertTextAndKeepInClipboard(finalText)
            } else {
                ClipboardUtil.insertText(finalText)
            }
            return targetMissing
        } else if prefs.autoCopyToClipboard {
            ClipboardUtil.copyToClipboard(finalText)
        }
        // If both are false, do nothing
        return false
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
        .animation(.spring(response: 0.35, dampingFraction: 0.72), value: viewModel.isVisible)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: bubbleWidth)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: streaming.confirmedText)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: streaming.volatileText)
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
