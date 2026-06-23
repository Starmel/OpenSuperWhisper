import SwiftUI

/// Moonshine model catalog (Settings → Engine & Model when browsing Moonshine): one row per
/// language, searchable, in the same style as the Whisper/Parakeet lists. Clicking a row downloads
/// the model if needed, then activates Moonshine with that language — browsing/searching alone
/// never changes the active model.
struct MoonshineModelSection: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var languageFilter = "all"
    @State private var downloadingLang: String?
    @State private var progress: Double = 0
    @State private var errorMessage: String?

    private var filtered: [MoonshineModelManager.Language] {
        guard languageFilter != "all" else { return MoonshineModelManager.languages }
        return MoonshineModelManager.languages.filter { $0.code == languageFilter }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Moonshine Model")
                    .font(.headline)
                Spacer()
                Menu {
                    Picker("Language", selection: $languageFilter) {
                        Text("All languages").tag("all")
                        ForEach(MoonshineModelManager.languages) { lang in
                            Text(lang.name).tag(lang.code)
                        }
                    }
                    // A size filter (tiny / base) will live here once both sizes ship.
                } label: {
                    Image(systemName: languageFilter == "all"
                          ? "line.3.horizontal.decrease.circle"
                          : "line.3.horizontal.decrease.circle.fill")
                        .imageScale(.large)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Filter")
            }
            Text("Tiny, fast on-device models — one per language. Click a row to download & use it.")
                .font(.caption)
                .foregroundColor(.secondary)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(filtered) { lang in
                        row(for: lang)
                    }
                }
            }
            .frame(maxHeight: 220)

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundColor(.red)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }

    private func row(for lang: MoonshineModelManager.Language) -> some View {
        let mgr = MoonshineModelManager.shared
        let downloaded = mgr.isDownloaded(lang.code)
        let active = viewModel.selectedEngine == "moonshine" && AppPreferences.shared.moonshineLanguage == lang.code
        let isDownloading = downloadingLang == lang.code

        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(lang.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text("base · \(mgr.downloadSizeString)")
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
            } else if downloaded {
                Image(systemName: "checkmark.circle")
                    .foregroundColor(.secondary)
                    .imageScale(.large)
            } else {
                Label("\(mgr.downloadSizeString)", systemImage: "arrow.down.circle")
                    .font(.caption)
                    .foregroundColor(.blue)
                    .labelStyle(.iconOnly)
                    .imageScale(.large)
            }
        }
        .padding(12)
        .background(Color(.controlBackgroundColor).opacity(active ? 0.8 : 0.4))
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture { select(lang.code, downloaded: downloaded) }
    }

    private func select(_ lang: String, downloaded: Bool) {
        guard downloadingLang == nil else { return }
        errorMessage = nil
        AppPreferences.shared.moonshineLanguage = lang
        if downloaded {
            // Re-assigning activates Moonshine and reloads with this language.
            viewModel.selectedEngine = "moonshine"
        } else {
            downloadingLang = lang
            progress = 0
            Task {
                do {
                    try await MoonshineModelManager.shared.download(lang) { p in
                        Task { @MainActor in progress = p }
                    }
                    await MainActor.run {
                        downloadingLang = nil
                        viewModel.selectedEngine = "moonshine"
                    }
                } catch {
                    await MainActor.run {
                        downloadingLang = nil
                        errorMessage = "Download failed. Check your connection and try again."
                    }
                }
            }
        }
    }
}
