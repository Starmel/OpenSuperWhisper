import Cocoa
import Combine
import SwiftUI

enum RecordingState {
    case idle
    case connecting
    case recording
    case decoding
    case busy
}

@MainActor
protocol IndicatorViewDelegate: AnyObject {

    func didFinishDecoding(for viewModel: IndicatorViewModel)
}

@MainActor
class IndicatorViewModel: ObservableObject {
    @Published var state: RecordingState = .idle
    @Published var isBlinking = false
    @Published var recorder: AudioRecorder = .shared
    @Published var isVisible = false

    private let streamingEngine = StreamingWhisperEngine.shared
    private var liveModeActive = false

    /// Live streaming only applies to the whisper engine and when the user opted in.
    private var useLiveStreaming: Bool {
        AppPreferences.shared.liveStreamingEnabled && AppPreferences.shared.selectedEngine == "whisper"
    }

    var delegate: IndicatorViewDelegate?
    private var blinkTimer: Timer?
    private var hideTimer: Timer?
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

        // Warm up the streaming model so the tap can start immediately on record
        // (otherwise model load would drop the lead-in of the live transcription).
        if useLiveStreaming {
            Task.detached { [streamingEngine] in
                try? streamingEngine.initialize()
            }
        }
    }
    
    var isTranscriptionBusy: Bool {
        transcriptionService.isTranscribing || transcriptionQueue.isProcessing
    }
    
    func showBusyMessage() {
        state = .busy
        
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                self.delegate?.didFinishDecoding(for: self)
            }
        }
    }
    
    func startRecording() {
        // In live mode the streaming engine has its own serial queue and a separate
        // context, so a new recording can start while a previous one is still
        // finalizing/transcribing — work is queued, not blocked. The file path shares
        // a single context, so it must still block to avoid concurrent whisper_full.
        if !useLiveStreaming && isTranscriptionBusy {
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

        // Live streaming runs in parallel to the file recorder: the WAV is still
        // written (playback / re-transcribe stay intact); on stop we use the live
        // text instead of a fresh file-based pass.
        if useLiveStreaming {
            liveModeActive = true
            let settings = Settings()
            streamingEngine.melNormMode = .window
            Task.detached { [streamingEngine] in
                do {
                    // start() loads the model on its serial queue and buffers audio
                    // meanwhile, so recording is instant and no lead-in is lost.
                    try streamingEngine.start(settings: settings)
                } catch {
                    print("Live streaming start failed: \(error)")
                }
            }
        }
    }

    func startDecoding() {
        stopBlinking()
        
        // Live mode never blocks: the streaming engine queues this finalize behind any
        // previous one (serial queue), so recordings are finalized and inserted strictly
        // in the order they were made.
        if liveModeActive {
            liveModeActive = false
            state = .decoding
            let tempURL = recorder.stopRecording()
            Task { [weak self] in
                guard let self = self else { return }
                // Flush the trailing <30s window off the main actor. stop() blocks on the
                // engine's serial queue, so it waits for the previous recording's finalize
                // -> ordered transcription + ordered insertion.
                let text = await Task.detached { [streamingEngine = self.streamingEngine] in
                    streamingEngine.stop()
                }.value
                await self.persist(text: text, tempURL: tempURL)
                self.delegate?.didFinishDecoding(for: self)
            }
            return
        }

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
                    let text = try await transcriptionService.transcribeAudio(url: tempURL, settings: Settings())
                    
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
                    
                    insertText(text)
                    print("Transcription result: \(text)")
                } catch {
                    print("Error transcribing audio: \(error)")
                    try? FileManager.default.removeItem(at: tempURL)
                }
                
                await MainActor.run {
                    self.delegate?.didFinishDecoding(for: self)
                }
            }
        } else {
            
            print("!!! Not found record url !!!")
            
            Task {
                await MainActor.run {
                    self.delegate?.didFinishDecoding(for: self)
                }
            }
        }
    }
    
    /// Saves the transcription (moving the recorded WAV to its final location when present)
    /// and inserts/copies the text. Used by the live streaming path.
    private func persist(text: String, tempURL: URL?) async {
        if let tempURL = tempURL {
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

            do {
                try recorder.moveTemporaryRecording(from: tempURL, to: finalURL)
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
            } catch {
                print("Error saving live recording: \(error)")
                try? FileManager.default.removeItem(at: tempURL)
            }
        }
        insertText(text)
    }

    func insertText(_ text: String) {
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
        hideTimer?.invalidate()
        hideTimer = nil
        cancellables.removeAll()
    }

    func cancelRecording() {
        hideTimer?.invalidate()
        hideTimer = nil
        recorder.cancelRecording()
        if liveModeActive {
            streamingEngine.cancel()
            liveModeActive = false
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
                    
                    Text("Recording...")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
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
                
            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 36)
        .background {
            rect
                .fill(backgroundColor)
                .background {
                    rect
                        .fill(Material.thinMaterial)
                }
                .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 4)
        }
        .clipShape(rect)
        .frame(width: 200)
        .scaleEffect(viewModel.isVisible ? 1 : 0.5)
        .offset(y: viewModel.isVisible ? 0 : 20)
        .opacity(viewModel.isVisible ? 1 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: viewModel.isVisible)
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
