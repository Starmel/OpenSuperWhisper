import SwiftUI

/// SenseVoice model row (Settings → Engine & Model when browsing SenseVoice). One model; clicking
/// the row downloads it if needed, then activates SenseVoice — same interaction as every other engine.
struct SenseVoiceModelSection: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var isDownloading = false
    @State private var progress: Double = 0
    @State private var isDownloaded = SenseVoiceModelManager.shared.isDownloaded
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SenseVoice Model")
                .font(.headline)
            Text("Multilingual (Chinese, Cantonese, English, Japanese, Korean), fully on-device. Click to download & use.")
                .font(.caption)
                .foregroundColor(.secondary)

            row

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundColor(.red)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }

    private var row: some View {
        let active = viewModel.selectedEngine == "sensevoice" && isDownloaded
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("SenseVoice")
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text("zh · yue · en · ja · ko · \(SenseVoiceModelManager.shared.downloadSizeString)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if isDownloading {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(height: 6)
                        .padding(.top, 2)
                }
            }

            Spacer()

            if active {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .imageScale(.large)
            } else if isDownloading {
                ProgressView().controlSize(.small)
            } else if isDownloaded {
                Image(systemName: "checkmark.circle")
                    .foregroundColor(.secondary)
                    .imageScale(.large)
            } else {
                Image(systemName: "arrow.down.circle")
                    .foregroundColor(.blue)
                    .imageScale(.large)
            }
        }
        .padding(12)
        .background(Color(.controlBackgroundColor).opacity(active ? 0.8 : 0.4))
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture { select() }
    }

    private func select() {
        guard !isDownloading else { return }
        errorMessage = nil
        if isDownloaded {
            viewModel.selectedEngine = "sensevoice"
        } else {
            isDownloading = true
            progress = 0
            Task {
                do {
                    try await SenseVoiceModelManager.shared.download { p in
                        Task { @MainActor in progress = p }
                    }
                    await MainActor.run {
                        isDownloaded = true
                        isDownloading = false
                        viewModel.selectedEngine = "sensevoice"
                    }
                } catch {
                    await MainActor.run {
                        isDownloading = false
                        errorMessage = "Download failed. Check your connection and try again."
                    }
                }
            }
        }
    }
}
