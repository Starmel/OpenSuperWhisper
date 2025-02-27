import Foundation
import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

@MainActor
class FileDropHandler: ObservableObject {
    static let shared = FileDropHandler()
    
    @Published var isDragging = false
    @Published var isTranscribing = false
    @Published var fileDuration: TimeInterval = 0
    @Published var errorMessage: String? = nil
    
    // Store references to services at initialization time
    private let transcriptionService: TranscriptionService
    private let recordingStore: RecordingStore
    
    var isLongFile: Bool {
        fileDuration > 10.0
    }
    
    private init() {
        self.transcriptionService = TranscriptionService.shared
        self.recordingStore = RecordingStore.shared
    }
    
    func showProcessingError() {
        errorMessage = "Already processing a file. Please wait."
        
        // Clear error message after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.errorMessage = nil
        }
    }
    
    func cancelTranscription() {
        transcriptionService.cancelTranscription()
        
        // Reset state
        isTranscribing = false
        fileDuration = 0
    }
    
    func handleDrop(of providers: [NSItemProvider]) async {
        guard let provider = providers.first else { return }
        
        // Double-check we're not already processing
        if isTranscribing {
            showProcessingError()
            return
        }
        
        if provider.hasItemConformingToTypeIdentifier(UTType.audio.identifier) {
            do {
                // Create a continuation to handle the non-Sendable NSItemProvider
                let url = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL?, Error>) in
                    provider.loadItem(forTypeIdentifier: UTType.audio.identifier) { item, error in
                        if let error = error {
                            continuation.resume(throwing: error)
                            return
                        }
                        continuation.resume(returning: item as? URL)
                    }
                }
                
                guard let url = url else {
                    print("Error loading item: not a URL")
                    return
                }
                
                print("url: \(url)")
                
                // Get audio duration
                let asset = AVAsset(url: url)
                let duration = try await asset.load(.duration)
                let durationInSeconds = CMTimeGetSeconds(duration)
                
                self.fileDuration = durationInSeconds
                self.isTranscribing = true
                
                print("start decoding...")
                let text = try await transcriptionService.transcribeAudio(
                    url: url, settings: Settings()
                )
                
                // Create a new Recording instance
                let timestamp = Date()
                let fileName = "\(Int(timestamp.timeIntervalSince1970)).wav"
                let finalURL = Recording(
                    id: UUID(),
                    timestamp: timestamp,
                    fileName: fileName,
                    transcription: text,
                    duration: fileDuration
                ).url
                
                // Copy the file for playback
                try FileManager.default.copyItem(at: url, to: finalURL)
                
                // Save the recording to store
                self.recordingStore.addRecording(
                    Recording(
                        id: UUID(),
                        timestamp: timestamp,
                        fileName: fileName,
                        transcription: text,
                        duration: self.fileDuration
                    ))
                
            } catch {
                print("Error processing dropped audio file: \(error)")
            }
            
            self.isTranscribing = false
            self.fileDuration = 0
        }
    }
}

// View modifier for adding drag-and-drop functionality
struct FileDropOverlay: ViewModifier {
    @ObservedObject private var handler: FileDropHandler
    @ObservedObject private var transcriptionService: TranscriptionService
    
    init() {
        self.handler = FileDropHandler.shared
        self.transcriptionService = TranscriptionService.shared
    }
    
    func body(content: Content) -> some View {
        content
            .overlay {
                if handler.isDragging {
                    ZStack {
                        Color(NSColor.windowBackgroundColor)
                            .opacity(0.95)
                        VStack(spacing: 16) {
                            if handler.isTranscribing {
                                // Show warning when trying to drop while already processing
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.system(size: 48))
                                    .foregroundColor(.orange)
                                Text("Please wait until current file is processed")
                                    .font(.headline)
                                    .foregroundColor(.orange)
                            } else {
                                Image(systemName: "arrow.down.circle")
                                    .font(.system(size: 48))
                                    .foregroundColor(.accentColor)
                                    .symbolEffect(.bounce, value: handler.isDragging)
                                Text("Drop audio file to transcribe")
                                    .font(.headline)
                            }
                        }
                    }
                    .ignoresSafeArea()
                }
                
                // Show transcription progress for dropped files
                if handler.isTranscribing && handler.isLongFile {
                    ZStack {
                        // Add blur background effect
                        Color(NSColor.windowBackgroundColor)
                            .opacity(0.7)
                            .blur(radius: 10)
                        
                        VStack(spacing: 16) {
                            ProgressView(value: transcriptionService.progress)
                                .progressViewStyle(LinearProgressViewStyle())
                                .frame(width: 200)
                            
                            Text("Transcribing audio... \(Int(transcriptionService.progress * 100))%")
                                .foregroundColor(.primary)
                                .font(.headline)
                            
                            if !transcriptionService.currentSegment.isEmpty {
                                Text(transcriptionService.currentSegment)
                                    .foregroundColor(.primary.opacity(0.8))
                                    .font(.subheadline)
                                    .multilineTextAlignment(.center)
                                    .frame(maxWidth: 300)
                                    .lineLimit(2)
                            }
                            
                            Button(action: {
                                handler.cancelTranscription()
                            }) {
                                HStack(spacing: 8) {
                                    Image(systemName: "xmark.circle.fill")
                                    Text("Cancel")
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.red.opacity(0.8))
                                .foregroundColor(.white)
                                .cornerRadius(8)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .padding(.top, 8)
                        }
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(NSColor.controlBackgroundColor))
                                .shadow(color: Color.black.opacity(0.2), radius: 10)
                        )
                    }
                    .ignoresSafeArea()
                }
                
                // Show error message if present - now at the top
                if let errorMessage = handler.errorMessage {
                    VStack {
                        Text(errorMessage)
                            .font(.subheadline.bold())
                            .foregroundColor(.white)
                            .padding()
                            .background(Color.red.opacity(0.8))
                            .cornerRadius(8)
                            .padding(.top, 20)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        Spacer()
                    }
                    .animation(.easeInOut, value: handler.errorMessage != nil)
                    .zIndex(100) // Ensure it's above other overlays
                }
            }
            .onDrop(of: [.audio], isTargeted: $handler.isDragging) { providers in
                // Only process the drop if we're not already transcribing
                if !handler.isTranscribing {
                    Task {
                        await handler.handleDrop(of: providers)
                    }
                    return true
                } else {
                    // Show error message when trying to drop while processing
                    handler.showProcessingError()
                    // Return true to indicate the drop was handled, even though we're ignoring it
                    // This prevents the OS from trying to handle the drop in other ways
                    return true
                }
            }
    }
}

extension View {
    func fileDropHandler() -> some View {
        modifier(FileDropOverlay())
    }
}
