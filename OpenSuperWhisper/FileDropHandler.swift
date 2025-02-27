import Foundation
import SwiftUI
import UniformTypeIdentifiers
import AVFoundation

class FileDropHandler: ObservableObject {
    static let shared = FileDropHandler()
    
    @Published var isDragging = false
    @Published var isTranscribing = false
    @Published var fileDuration: TimeInterval = 0
    @Published var errorMessage: String? = nil
    
    private let transcriptionService = TranscriptionService.shared
    private let recordingStore = RecordingStore.shared
    
    var isLongFile: Bool {
        fileDuration > 10.0
    }
    
    func showProcessingError() {
        errorMessage = "Already processing a file. Please wait."
        
        // Clear error message after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.errorMessage = nil
        }
    }
    
    func cancelTranscription() {
        Task { @MainActor in
            transcriptionService.cancelTranscription()
        }
        
        // Reset state
        isTranscribing = false
        fileDuration = 0
    }
    
    func handleDrop(of providers: [NSItemProvider]) async {
        guard let provider = providers.first else { return }
        
        // Double-check we're not already processing
        if isTranscribing {
            await MainActor.run {
                showProcessingError()
            }
            return
        }
        
        if provider.hasItemConformingToTypeIdentifier(UTType.audio.identifier) {
            do {
                // Get the file URL from the provider
                let url = try await provider.loadItem(
                    forTypeIdentifier: UTType.audio.identifier) as? URL
                
                print("url: \(String(describing: url))")
                
                guard let url = url else {
                    print("Error loading item")
                    return
                }
                
                // Get audio duration
                let asset = AVAsset(url: url)
                let duration = try await asset.load(.duration)
                let durationInSeconds = CMTimeGetSeconds(duration)
                
                await MainActor.run {
                    self.fileDuration = durationInSeconds
                    self.isTranscribing = true
                }
                
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
                await recordingStore.addRecording(
                    Recording(
                        id: UUID(),
                        timestamp: timestamp,
                        fileName: fileName,
                        transcription: text,
                        duration: fileDuration
                    ))
                
            } catch {
                print("Error processing dropped audio file: \(error)")
            }
            
            await MainActor.run {
                self.isTranscribing = false
                self.fileDuration = 0
            }
        }
    }
}

// View modifier для добавления функционала drag-and-drop
struct FileDropOverlay: ViewModifier {
    @ObservedObject private var handler = FileDropHandler.shared
    @ObservedObject private var transcriptionService = TranscriptionService.shared
    
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
                    Task { @MainActor in
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
