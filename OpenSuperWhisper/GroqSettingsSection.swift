import SwiftUI

/// Groq cloud engine (Settings → Engine & Model when browsing Groq). The two Groq models are shown
/// as rows like every other engine; without an API key each row is locked (🔒) and tapping it opens
/// the key editor. With a key set, tapping a row selects that model and activates Groq.
struct GroqSettingsSection: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var apiKey = AppPreferences.shared.groqAPIKey ?? ""
    @State private var model = AppPreferences.shared.groqModel
    @State private var showKeyEditor = false

    private struct GroqModel: Identifiable {
        let id: String
        let desc: String
    }
    private let models = [
        GroqModel(id: "whisper-large-v3-turbo", desc: "Fastest — transcription only"),
        GroqModel(id: "whisper-large-v3", desc: "Supports Translate to English"),
    ]

    private var hasKey: Bool { !apiKey.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Groq")
                    .font(.headline)
                Spacer()
                Button { showKeyEditor = true } label: {
                    Image(systemName: hasKey ? "key.fill" : "lock.fill")
                        .imageScale(.large)
                        .foregroundColor(hasKey ? .secondary : .orange)
                }
                .buttonStyle(.plain)
                .help(hasKey ? "Edit API key" : "Add API key")
                .popover(isPresented: $showKeyEditor, arrowEdge: .top) { keyEditor }
            }

            // The one engine that leaves the device — say so loudly.
            Label("Audio is uploaded to Groq's servers — this engine is not on-device.",
                  systemImage: "cloud")
                .font(.caption)
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(models) { groqModel in
                row(for: groqModel)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }

    private func row(for groqModel: GroqModel) -> some View {
        let active = viewModel.selectedEngine == "groq" && model == groqModel.id
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(groqModel.id)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(groqModel.desc)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if !hasKey {
                Image(systemName: "lock.fill")
                    .foregroundColor(.secondary)
                    .imageScale(.large)
            } else if active {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .imageScale(.large)
            } else {
                Image(systemName: "checkmark.circle")
                    .foregroundColor(.secondary)
                    .imageScale(.large)
            }
        }
        .padding(12)
        .background(Color(.controlBackgroundColor).opacity(active ? 0.8 : 0.4))
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture {
            if !hasKey {
                showKeyEditor = true
            } else {
                model = groqModel.id
                AppPreferences.shared.groqModel = groqModel.id
                viewModel.selectedEngine = "groq"
            }
        }
    }

    private var keyEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Groq API Key").font(.headline)
                Spacer()
                Link("Get a free key", destination: URL(string: "https://console.groq.com/keys")!)
                    .font(.caption)
            }
            SecureField("gsk_…", text: $apiKey)
                .textFieldStyle(.roundedBorder)
                .onChange(of: apiKey) { _, newValue in
                    AppPreferences.shared.groqAPIKey = newValue
                }
            Text("Stored in your Keychain. Then pick a model in the list.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(width: 320)
    }
}
