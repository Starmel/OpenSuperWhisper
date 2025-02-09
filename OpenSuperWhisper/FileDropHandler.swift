import Foundation
import SwiftUI
import UniformTypeIdentifiers

class FileDropHandler: ObservableObject {
    static let shared = FileDropHandler()
    
    @Published var isDragging = false
    
    private let transcriptionService = TranscriptionService.shared
    private let recordingStore = RecordingStore.shared
    
    func handleDrop(of providers: [NSItemProvider]) async {
        guard let provider = providers.first else { return }
        
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
                
                print("start decoding...")
                let text = try await transcriptionService.transcribeAudio(
                    url: url, settings: .shared
                )
                
                // Create a new Recording instance
                let timestamp = Date()
                let fileName = "\(Int(timestamp.timeIntervalSince1970)).wav"
                let finalURL = Recording(
                    id: UUID(),
                    timestamp: timestamp,
                    fileName: fileName,
                    transcription: text,
                    duration: 0 // TODO: Get actual duration
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
                        duration: 0
                    ))
                
            } catch {
                print("Error processing dropped audio file: \(error)")
            }
        }
    }
}

// View modifier для добавления функционала drag-and-drop
struct FileDropOverlay: ViewModifier {
    @ObservedObject private var handler = FileDropHandler.shared
    
    func body(content: Content) -> some View {
        content
            .overlay {
                if handler.isDragging {
                    ZStack {
                        Color(NSColor.windowBackgroundColor)
                            .opacity(0.95)
                        VStack(spacing: 16) {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 48))
                                .foregroundColor(.accentColor)
                                .symbolEffect(.bounce, value: handler.isDragging)
                            Text("Drop audio file to transcribe")
                                .font(.headline)
                        }
                    }
                    .ignoresSafeArea()
                }
            }
            .onDrop(of: [.audio], isTargeted: $handler.isDragging) { providers in
                Task { @MainActor in
                    await handler.handleDrop(of: providers)
                }
                return true
            }
    }
}

extension View {
    func fileDropHandler() -> some View {
        modifier(FileDropOverlay())
    }
}
