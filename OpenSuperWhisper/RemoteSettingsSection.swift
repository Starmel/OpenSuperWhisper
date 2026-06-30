import SwiftUI

/// Built-in presets for the generic remote (OpenAI-compatible) engine. Groq is a
/// preset that points the remote engine at Groq's API with a curated model list;
/// "Custom" exposes the full URL/model/timeout controls for any other server.
enum RemotePreset: String, CaseIterable, Identifiable {
    case groq
    case custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .groq: return "Groq"
        case .custom: return "Custom"
        }
    }
}

/// Groq preset constants. Groq is the OpenAI-compatible remote engine pointed at
/// Groq's API; only the base URL and the curated model list are fixed.
enum GroqPreset {
    static let baseURL = "https://api.groq.com/openai/v1"
    static let defaultModel = "whisper-large-v3-turbo"
    /// Only the full model translates to English; turbo is transcription-only.
    static let translatingModel = "whisper-large-v3"

    static func isGroqURL(_ url: String) -> Bool {
        url.lowercased().contains("api.groq.com")
    }

    struct Model: Identifiable {
        let id: String
        let desc: String
    }
    static let models = [
        Model(id: "whisper-large-v3-turbo", desc: "Fastest — transcription only"),
        Model(id: "whisper-large-v3", desc: "Supports Translate to English"),
    ]
}

/// Remote engine settings (Settings → Engine & Model when browsing "Remote"). A
/// preset picker switches between Groq (curated, pre-filled) and a fully custom
/// OpenAI-compatible server. Both write the same `remoteServer*` preferences and
/// activate the single `"remote"` engine; the preset is just a convenience prefill.
struct RemoteSettingsSection: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var preset: RemotePreset

    init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
        // Infer the preset from the configured URL so re-opening Settings shows
        // the right tab (Groq users land on Groq).
        _preset = State(initialValue:
            GroqPreset.isGroqURL(viewModel.remoteServerURL) ? .groq : .custom)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Remote (OpenAI-compatible) Engine")
                .font(.headline)
                .foregroundColor(.primary)

            // The one engine family that leaves the device — say so once, here.
            Label("Audio is uploaded to the remote server — these engines are not on-device.",
                  systemImage: "cloud")
                .font(.caption)
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Provider", selection: $preset) {
                ForEach(RemotePreset.allCases) { p in
                    Text(p.label).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: preset) { _, newValue in applyPreset(newValue) }

            if preset == .groq {
                GroqPresetView(viewModel: viewModel)
            } else {
                RemoteServerSettingsView(viewModel: viewModel)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }

    /// Prefill (Groq) or clear (Custom) the server config when the preset changes.
    /// Selecting a model/activating the engine happens in the sub-views.
    private func applyPreset(_ p: RemotePreset) {
        switch p {
        case .groq:
            if !GroqPreset.isGroqURL(viewModel.remoteServerURL) {
                viewModel.remoteServerURL = GroqPreset.baseURL
            }
            if !GroqPreset.models.contains(where: { $0.id == viewModel.remoteServerModel }) {
                viewModel.remoteServerModel = GroqPreset.defaultModel
            }
        case .custom:
            // Leaving Groq: clear the Groq URL/model so the user can enter their own.
            if GroqPreset.isGroqURL(viewModel.remoteServerURL) {
                viewModel.remoteServerURL = ""
                viewModel.remoteServerModel = ""
            }
        }
    }
}

/// Groq preset UI: the two curated Groq models as rows (like every other engine),
/// locked (🔒) until an API key is entered. Tapping a row with a key set selects
/// that model and activates the remote engine pointed at Groq. Mirrors the former
/// GroqSettingsSection but writes the shared `remoteServer*` preferences.
struct GroqPresetView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var showKeyEditor = false

    private var hasKey: Bool { !viewModel.remoteServerAPIKey.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Groq")
                    .font(.subheadline)
                    .fontWeight(.medium)
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

            ForEach(GroqPreset.models) { model in
                row(for: model)
            }
        }
    }

    private func row(for model: GroqPreset.Model) -> some View {
        let active = viewModel.selectedEngine == "remote"
            && GroqPreset.isGroqURL(viewModel.remoteServerURL)
            && viewModel.remoteServerModel == model.id
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.id)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(model.desc)
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
                viewModel.remoteServerURL = GroqPreset.baseURL
                viewModel.remoteServerModel = model.id
                viewModel.selectedEngine = "remote"
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
            SecureField("gsk_…", text: $viewModel.remoteServerAPIKey)
                .textFieldStyle(.roundedBorder)
            Text("Stored in your Keychain. Then pick a model in the list.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(width: 320)
    }
}
