import SwiftUI

/// Settings for the Groq cloud engine (shown in Settings → Model when Groq is selected): API key
/// (stored in the Keychain), model choice, and an unmissable cloud/privacy notice.
struct GroqSettingsSection: View {
    @State private var apiKey: String = AppPreferences.shared.groqAPIKey ?? ""
    @State private var model: String = AppPreferences.shared.groqModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Groq")
                .font(.headline)

            // The one engine that leaves the device — say so loudly.
            Label("Audio is uploaded to Groq's servers — this engine is not on-device.",
                  systemImage: "cloud")
                .font(.caption)
                .foregroundColor(.orange)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("API Key").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Link("Get a free key", destination: URL(string: "https://console.groq.com/keys")!)
                        .font(.caption)
                }
                SecureField("gsk_…", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: apiKey) { _, newValue in
                        AppPreferences.shared.groqAPIKey = newValue
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                Picker("Model", selection: $model) {
                    Text("whisper-large-v3-turbo — fastest").tag("whisper-large-v3-turbo")
                    Text("whisper-large-v3 — supports translation").tag("whisper-large-v3")
                }
                .onChange(of: model) { _, newValue in
                    AppPreferences.shared.groqModel = newValue
                }
                Text("Turbo is fastest (transcription only). whisper-large-v3 also honours Translate to English.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }
}
