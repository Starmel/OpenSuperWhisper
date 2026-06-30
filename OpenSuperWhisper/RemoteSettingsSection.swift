import SwiftUI
import AppKit

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
            Label("Audio is uploaded to the remote server — not necessarily on-device.",
                  systemImage: "cloud")
                .font(.caption)
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)

            // Compact preset dropdown. Default is Custom; Groq prefills the Groq URL
            // and model list (leaving the key for the user). "Request a preset…" opens
            // the issue tracker so people can ask for a new built-in provider.
            HStack(spacing: 8) {
                Text("Preset").foregroundColor(.secondary)
                Menu {
                    Button("Custom") { preset = .custom }
                    Button("Groq") { preset = .groq }
                    Divider()
                    Button("Request a preset…") {
                        if let url = URL(string: "https://github.com/my-monkeys/OpenSuperWhisper/issues") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                } label: {
                    Text(preset.label)
                }
                .fixedSize()
                .onChange(of: preset) { _, newValue in applyPreset(newValue) }
                Spacer()
            }

            // One uniform config UI; the preset menu just prefills its fields.
            RemoteServerSettingsView(viewModel: viewModel)
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

