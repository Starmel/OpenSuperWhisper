import SwiftUI
import WhisperCore

@main
struct OpenSuperWhisperIOSApp: App {
    var body: some Scene {
        WindowGroup {
            Text("OpenSuperWhisper iOS")
                .onAppear {
                    // Verify WhisperCore is linked and accessible
                    print("WhisperCore loaded. Engine types available.")
                    print("RecordingStore: \(RecordingStore.shared)")
                }
        }
    }
}
