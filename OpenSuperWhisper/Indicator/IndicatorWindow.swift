import Cocoa
import Combine
import SwiftUI

enum RecordingState {
    case idle
    case connecting
    case recording
    case decoding
    case busy
    case noMicrophone
}

@MainActor
protocol IndicatorViewDelegate: AnyObject {
    
    func didFinishDecoding()
}

@MainActor
class IndicatorViewModel: ObservableObject {
    static let cancelConfirmationThreshold: TimeInterval = 10.0
    static let cancelConfirmationWindow: TimeInterval = 5.0
    
    @Published var state: RecordingState = .idle
    @Published var isBlinking = false
    @Published var isConfirmingCancel = false
    @Published var recorder: AudioRecorder = .shared

    /// Live preview shown while recording. `liveCommitted` is stable text,
    /// `livePending` is the still-changing tail. Empty unless the live streaming
    /// preview is enabled and producing output.
    @Published var liveCommitted = ""
    @Published var livePending = ""

    var hasLivePreview: Bool {
        !liveCommitted.isEmpty || !livePending.isEmpty
    }

    private var streamingEngine: StreamingWhisperEngine?

    var recordingStartedAt: Date?
    
    var delegate: IndicatorViewDelegate?
    private var blinkTimer: Timer?
    private var hideTimer: Timer?
    private var confirmCancelTimer: Timer?
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
        showAutoDismissingMessage(.busy)
    }

    private func showAutoDismissingMessage(_ message: RecordingState) {
        state = message

        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
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

        // getActiveMicrophone() only reads the cached currentMicrophone, so
        // this guard costs no CoreAudio HAL round-trip on the main thread.
        guard MicrophoneService.shared.getActiveMicrophone() != nil else {
            showAutoDismissingMessage(.noMicrophone)
            return
        }
        
        // Optimistically assume recording: querying the microphone here costs
        // CoreAudio HAL round-trips on the main thread right before the appear
        // animation. The recorder resolves the real state on its own queue and
        // publishes isConnecting/isRecording, which the sinks above translate
        // into .connecting/.recording.
        state = .recording
        startBlinking()
        recordingStartedAt = Date()

        recorder.startRecording()
        startLivePreview()
    }

    /// Starts the optional live preview alongside recording. Whisper engine only;
    /// any failure is logged and ignored so the recording itself is never affected.
    private func startLivePreview() {
        guard AppPreferences.shared.liveStreamingPreview,
              AppPreferences.shared.selectedEngine == "whisper" else { return }

        liveCommitted = ""
        livePending = ""

        let engine = StreamingWhisperEngine()
        engine.onUpdate = { [weak self] committed, pending in
            guard let self = self, self.state == .recording else { return }
            self.liveCommitted = committed
            self.livePending = pending
        }
        if engine.start() {
            streamingEngine = engine
        }
    }

    private func stopLivePreview() {
        streamingEngine?.stop()
        streamingEngine = nil
        liveCommitted = ""
        livePending = ""
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
        // A second stop request (double hotkey press, hold-mode key-up) must not
        // restart decoding or hide the window while transcription is in flight.
        guard state == .recording || state == .connecting else { return }

        resetCancelConfirmation()
        stopBlinking()
        stopLivePreview()
        
        if isTranscriptionBusy {
            // The engine is busy with another transcription: keep the user's audio
            // and put it into the queue instead of deleting it.
            Task { [weak self] in
                guard let self = self else { return }
                if let tempURL = await self.recorder.stopRecording() {
                    await self.transcriptionQueue.addFileToQueue(url: tempURL)
                }
            }
            showBusyMessage()
            return
        }
        
        state = .decoding
        
        Task { [weak self] in
            guard let self = self else { return }
            
            if let tempURL = await self.recorder.stopRecording() {
                do {
                    print("start decoding...")
                    let duration = await AudioUtil.audioDuration(url: tempURL)
                    let text = try await transcriptionService.transcribeAudio(url: tempURL, settings: Settings())
                    
                    if text.isEmpty {
                        try? FileManager.default.removeItem(at: tempURL)
                        print("No speech detected, dictation discarded")
                    } else {
                        let timestamp = Date()
                        let fileName = "\(Int(timestamp.timeIntervalSince1970)).wav"
                        let recordingId = UUID()
                        let newRecording = Recording(
                            id: recordingId,
                            timestamp: timestamp,
                            fileName: fileName,
                            transcription: text,
                            duration: duration,
                            status: .completed,
                            progress: 1.0,
                            sourceFileURL: nil
                        )
                        
                        try recorder.moveTemporaryRecording(from: tempURL, to: newRecording.url)
                        
                        await MainActor.run {
                            self.recordingStore.addRecording(newRecording)
                        }
                        
                        insertText(text)
                        print("Transcription result: \(text)")
                    }
                } catch {
                    print("Error transcribing audio: \(error)")
                    try? FileManager.default.removeItem(at: tempURL)
                }
                
                await MainActor.run {
                    self.delegate?.didFinishDecoding()
                }
            } else {
                print("!!! Not found record url !!!")
                
                await MainActor.run {
                    self.delegate?.didFinishDecoding()
                }
            }
        }
    }
    
    func insertText(_ text: String) {
        guard !text.isEmpty else { return }
        let finalText = Self.applyPostProcessing(text)
        let prefs = AppPreferences.shared

        if prefs.autoPasteTranscription {
            if prefs.autoCopyToClipboard {
                // Paste and keep in clipboard
                ClipboardUtil.insertTextAndKeepInClipboard(finalText)
            } else {
                // Paste but restore original clipboard (legacy behavior)
                ClipboardUtil.insertText(finalText)
            }
        } else if prefs.autoCopyToClipboard {
            // Only copy to clipboard, don't paste
            ClipboardUtil.copyToClipboard(finalText)
        }
        // If both are false, do nothing

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
        stopLivePreview()
        resetCancelConfirmation()
        recordingStartedAt = nil
        hideTimer?.invalidate()
        hideTimer = nil
        cancellables.removeAll()
    }

    func cancelRecording() {
        hideTimer?.invalidate()
        hideTimer = nil
        stopLivePreview()
        recorder.cancelRecording()
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

struct LiveTextView: View {
    let committed: String
    let pending: String

    private var text: Text {
        let committedText = Text(committed)
            .foregroundColor(.primary)
        guard !pending.isEmpty else { return committedText }
        let separator = committed.isEmpty ? "" : " "
        return committedText + Text(separator + pending).foregroundColor(.secondary)
    }

    var body: some View {
        text
            .font(.system(size: 11))
            .lineLimit(2)
            // Keep the newest words visible: the tail is what the user just said.
            .truncationMode(.head)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
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
    /// Taller card used when the live preview is visible. Kept small enough that
    /// the card still fits inside the fixed panel (windowSize) without clipping.
    static let expandedCardHeight: CGFloat = 76
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
                VStack(alignment: .leading, spacing: 6) {
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

                    if viewModel.hasLivePreview && !viewModel.isConfirmingCancel {
                        LiveTextView(committed: viewModel.liveCommitted, pending: viewModel.livePending)
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

            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, 24)
        // Grows to fit the two-line live preview while staying inside the panel,
        // so the card is not clipped and needs no window repositioning.
        .frame(height: viewModel.hasLivePreview && viewModel.state == .recording ? Self.expandedCardHeight : Self.cardSize.height)
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
