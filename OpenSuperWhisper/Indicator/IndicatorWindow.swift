import Cocoa
import SwiftUI

enum RecordingState {
    case idle
    case recording
    case decoding
}

@MainActor
protocol IndicatorViewDelegate: AnyObject {
    
    func didFinishDecoding()
}

class IndicatorViewModel: ObservableObject {
    @Published var state: RecordingState = .idle
    @Published var isBlinking = false
    @Published var recorder: AudioRecorder = .shared
    @Published var isVisible = false
    
    var delegate: IndicatorViewDelegate?
    private var blinkTimer: Timer?
    
    var isRecording: Bool {
        recorder.isRecording
    }
    
    func startRecording() {
        state = .recording
        startBlinking()
        recorder.startRecording()
    }
    
    func startDecoding() {
        state = .decoding
        stopBlinking()
        
        if let url = recorder.stopRecording() {
            let transcription = TranscriptionService.shared
            
            Task { [weak self] in
                
                guard let self = self else { return }
                
                do {
                    
                    print("start decoding...")
                    let text = try await transcription.transcribeAudio(url: url, settings: .shared)
                    
                    insertTextUsingPasteboard(text)
                    print("Transcription result: \(text)")

                } catch {
                    print("Error transcribing audio: \(error)")
                }
                
                await self.delegate?.didFinishDecoding()
                
            }
        } else {
            
            print("!!! Not found record url !!!")
            
            Task {
                await self.delegate?.didFinishDecoding()
            }
        }
    }
    
    func insertTextUsingPasteboard(_ text: String) {
        // 1. Копируем текст в буфер обмена
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(text, forType: .string)
        
        // 2. Создаем источник событий
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            print("Не удалось создать источник событий")
            return
        }
        
        // Коды клавиш (в dec):
        // - Command (левая) — 55
        // - V — 9
        let keyCodeCmd: CGKeyCode = 55
        let keyCodeV: CGKeyCode = 9
        
        // Создаем события: нажатие Command, нажатие V, отпускание V, отпускание Command.
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeCmd, keyDown: true)
        
        // При нажатии V нужно выставить флаг Command
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: true)
        vDown?.flags = .maskCommand
        
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: false)
        vUp?.flags = .maskCommand
        
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeCmd, keyDown: false)
        
        // Определяем место отправки событий
        let eventTapLocation = CGEventTapLocation.cghidEventTap
        
        // Отправляем события в систему
        cmdDown?.post(tap: eventTapLocation)
        vDown?.post(tap: eventTapLocation)
        vUp?.post(tap: eventTapLocation)
        cmdUp?.post(tap: eventTapLocation)
    }

    func stop() {
        state = .idle
        stopBlinking()
    }
    
    private func startBlinking() {
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in
            self?.isBlinking.toggle()
        }
    }
    
    private func stopBlinking() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        isBlinking = false
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
        VStack(spacing: 12) {
            switch viewModel.state {
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
                    
                    Text("Decoding...")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                
            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, 24)
        .frame(height: 36)
        .background {
            RoundedRectangle(cornerRadius: 24)
                .fill(backgroundColor)
                .background {
                    RoundedRectangle(cornerRadius: 24)
                        .fill(Material.thinMaterial)
                }
                .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 4)
        }
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
        vm.startRecording()
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
