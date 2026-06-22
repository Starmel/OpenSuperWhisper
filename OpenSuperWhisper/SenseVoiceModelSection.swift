import SwiftUI

/// Model status + download for the SenseVoice engine (shown in Settings → Model when SenseVoice
/// is the selected engine).
struct SenseVoiceModelSection: View {
    @State private var isDownloading = false
    @State private var progress: Double = 0
    @State private var isDownloaded = SenseVoiceModelManager.shared.isDownloaded
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SenseVoice Model")
                .font(.headline)
            Text("Multilingual (Chinese, Cantonese, English, Japanese, Korean), fully on-device.")
                .font(.caption)
                .foregroundColor(.secondary)

            if isDownloaded {
                Label("Model ready", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundColor(.green)
            } else if isDownloading {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: progress)
                    Text("Downloading… \(Int(progress * 100))%")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } else {
                HStack {
                    Text("Not downloaded · \(SenseVoiceModelManager.shared.downloadSizeString)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Download") { startDownload() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundColor(.red)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }

    private func startDownload() {
        isDownloading = true
        errorMessage = nil
        progress = 0
        Task {
            do {
                try await SenseVoiceModelManager.shared.download { p in
                    Task { @MainActor in progress = p }
                }
                await MainActor.run { isDownloaded = true; isDownloading = false }
            } catch {
                await MainActor.run {
                    errorMessage = "Download failed. Check your connection and try again."
                    isDownloading = false
                }
            }
        }
    }
}
