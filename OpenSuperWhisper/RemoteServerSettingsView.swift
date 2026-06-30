import SwiftUI

/// Configuration UI for a custom remote (OpenAI-compatible) transcription server.
/// Shown under the "Custom" preset of the Remote engine section: free-text URL,
/// optional API key, a model list fetched from GET /v1/models, and a request
/// timeout. The Groq preset uses its own curated UI (see RemoteSettingsSection).
struct RemoteServerSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    @State private var testStatus: TestStatus = .idle
    @State private var availableModels: [RemoteModelInfo] = []
    @State private var isCustomModel: Bool = true
    // Server config + timeout live under disclosures so the model list stays the
    // focus once configured. Server opens by default only when nothing is set yet.
    @State private var serverExpanded: Bool = AppPreferences.shared.remoteServerURL.isEmpty
    @State private var timeoutExpanded: Bool = false
    @State private var showKeyEditor = false

    private var hasKey: Bool { !viewModel.remoteServerAPIKey.isEmpty }

    enum TestStatus: Equatable {
        case idle
        case testing
        case success(String)
        case failure(String)
    }

    struct RemoteModelInfo: Identifiable, Equatable {
        let id: String          // model id, e.g. "whisper-1"
        let ownedBy: String?    // OpenAI /v1/models "owned_by"
    }

    var body: some View {
        // No outer scroll: server config and timeout collapse under disclosures,
        // so the panel stays short enough to fit the window. The model list is the
        // one bounded scroll region (see modelSection), the way Whisper/Parakeet
        // present their model lists.
        VStack(alignment: .leading, spacing: 12) {
            Text("Remote Server")
                .font(.headline)
                .foregroundColor(.primary)

            Text("Use an OpenAI-compatible Whisper endpoint (speaches, LiteLLM, a local Ollama server, etc.) instead of a local model.")
                .font(.caption)
                .foregroundColor(.secondary)

            DisclosureGroup("Server settings", isExpanded: $serverExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    field(title: "Server URL", placeholder: "http://localhost:11434", text: $viewModel.remoteServerURL)

                    // Key entry lives behind the lock icon (popover), matching the
                    // Groq affordance — click the lock to add/edit the key.
                    HStack {
                        Text("API Key (optional)")
                            .font(.subheadline)
                        Spacer()
                        Button { showKeyEditor = true } label: {
                            Image(systemName: hasKey ? "key.fill" : "lock.fill")
                                .imageScale(.large)
                                .foregroundColor(hasKey ? .secondary : .orange)
                        }
                        .buttonStyle(.plain)
                        .help(hasKey ? "Edit API key" : "Add API key (open / no-auth servers need none)")
                        .popover(isPresented: $showKeyEditor, arrowEdge: .top) { keyEditor }
                    }
                }
                .padding(.top, 6)
            }

            modelSection

            DisclosureGroup("Request timeout", isExpanded: $timeoutExpanded) {
                timeoutBody
                    .padding(.top, 6)
            }

            HStack(spacing: 12) {
                Button("Test Connection") { runTest() }
                    .buttonStyle(.bordered)
                    .disabled(viewModel.remoteServerURL.isEmpty || testStatus == .testing)

                statusLabel
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .onAppear { fetchModels() }
    }

    // Inner content of the "Request timeout" disclosure. URLSession's 60s default
    // cuts off slow server-side pipelines; toggle off for no limit, or override
    // the seconds.
    // API key popover — opened from the lock icon, mirroring the Groq key editor.
    private var keyEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("API Key").font(.headline)
            SecureField("", text: $viewModel.remoteServerAPIKey,
                        prompt: Text("leave blank for no-auth servers"))
                .textFieldStyle(.roundedBorder)
            Text("Optional — only servers that require auth need a key. Stored in your Keychain.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding()
        .frame(width: 320)
    }

    private var timeoutBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Enforce a timeout", isOn: $viewModel.remoteServerTimeoutEnabled)

            if viewModel.remoteServerTimeoutEnabled {
                HStack(spacing: 8) {
                    Text("Seconds:").font(.caption).foregroundColor(.secondary)
                    TextField("", value: $viewModel.remoteServerTimeoutSeconds,
                              format: .number)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .frame(width: 80)
                    Stepper("", value: $viewModel.remoteServerTimeoutSeconds,
                            in: 1 ... 3600, step: 30)
                        .labelsHidden()
                }
                Text("Default 60s. Raise it for slow server-side pipelines, or switch the toggle off for no limit.")
                    .font(.caption2).foregroundColor(.secondary)
            } else {
                Text("No timeout — requests wait indefinitely for the server to respond.")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    // Model list styled like the local downloaded-model list: each model from
    // GET /v1/models is a selectable row, plus a "Custom" row that reveals a
    // free-text field (for servers that don't list models, or a wildcard "*").
    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Model").font(.subheadline)

            // Bounded scroll box (definite height): shows ~3 models and scrolls
            // for more, so a server with many models doesn't blow up the panel.
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(availableModels) { info in
                        modelRow(
                            name: info.id,
                            description: info.ownedBy.map { "Provided by \($0)" } ?? "Reported by the server",
                            selected: !isCustomModel && viewModel.remoteServerModel == info.id
                        ) {
                            viewModel.remoteServerModel = info.id
                            isCustomModel = false
                        }
                    }

                    modelRow(
                        name: "Custom",
                        description: "Don't see your model? Select here and enter it below.",
                        selected: isCustomModel
                    ) {
                        isCustomModel = true
                    }
                }
            }
            .frame(height: availableModels.isEmpty ? 70 : 200)
            // Key the list to the fetched model set so a delta (e.g. Test
            // Connection surfaces a newly-granted model) forces SwiftUI to rebuild.
            .id(availableModels.map(\.id).joined(separator: "|"))

            if isCustomModel {
                TextField("", text: $viewModel.remoteServerModel, prompt: Text("whisper-1"))
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .autocorrectionDisabled(true)
            }
        }
    }

    private func modelRow(name: String, description: String, selected: Bool,
                          onSelect: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.subheadline).fontWeight(.medium)
                Text(description).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .imageScale(.large)
            } else {
                Button("Select", action: onSelect)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(selected ? Color(.controlBackgroundColor).opacity(0.7) : Color(.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }

    private func field(title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline)
            // Use prompt: for the placeholder and hide the label. Inside a Form
            // the TextField label argument renders as a separate left-hand label,
            // which made the example string look like a stray second label.
            TextField("", text: text, prompt: Text(placeholder))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .autocorrectionDisabled(true)
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch testStatus {
        case .idle:
            EmptyView()
        case .testing:
            ProgressView().controlSize(.small)
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundColor(.green)
        case .failure(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundColor(.red)
        }
    }

    private func runTest() {
        testStatus = .testing
        let urlString = viewModel.remoteServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = viewModel.remoteServerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let endpoint = modelsEndpoint(from: urlString) else {
            testStatus = .failure("Invalid URL")
            return
        }

        Task {
            var request = URLRequest(url: endpoint)
            if !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                let models = (200..<300).contains(code) ? Self.parseModels(data) : []
                await MainActor.run {
                    if !models.isEmpty { applyFetched(models) }
                    if (200..<400).contains(code) {
                        testStatus = .success(models.isEmpty ? "Reachable" : "Reachable — \(models.count) models")
                    } else if code == 401 || code == 403 {
                        // Server is reachable; it just needs credentials.
                        testStatus = .success("Reachable — set the API key")
                    } else {
                        testStatus = .failure("HTTP \(code)")
                    }
                }
            } catch {
                await MainActor.run {
                    testStatus = .failure(error.localizedDescription)
                }
            }
        }
    }

    // Silent populate of the model list (no status side effects) — used when the
    // panel appears with a server already configured.
    private func fetchModels() {
        let urlString = viewModel.remoteServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = viewModel.remoteServerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !urlString.isEmpty, let endpoint = modelsEndpoint(from: urlString) else { return }
        Task {
            var request = URLRequest(url: endpoint)
            if !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) else { return }
            let models = Self.parseModels(data)
            await MainActor.run { if !models.isEmpty { applyFetched(models) } }
        }
    }

    // Store the fetched models and decide whether the current selection maps to a
    // listed model (row selected) or should be treated as custom (free-text shown).
    private func applyFetched(_ models: [RemoteModelInfo]) {
        availableModels = models
        // Cache for the menu-bar model picker, which has no live fetch of its own.
        AppPreferences.shared.cachedRemoteModels = models.map(\.id)
        let current = viewModel.remoteServerModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if models.contains(where: { $0.id == current }) {
            isCustomModel = false
        } else if !current.isEmpty {
            isCustomModel = true   // keep their typed value visible/editable
        } else {
            isCustomModel = false  // nothing chosen yet — let them pick a row
        }
    }

    private static func parseModels(_ data: Data) -> [RemoteModelInfo] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["data"] as? [[String: Any]] else { return [] }
        return arr.compactMap { item -> RemoteModelInfo? in
            guard let id = item["id"] as? String else { return nil }
            return RemoteModelInfo(id: id, ownedBy: item["owned_by"] as? String)
        }.sorted { $0.id < $1.id }
    }

    private func modelsEndpoint(from urlString: String) -> URL? {
        var base = urlString
        let lower = base.lowercased()
        if !lower.hasPrefix("http://") && !lower.hasPrefix("https://") {
            base = "http://" + base
        }
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/v1") { base.removeLast(3) }
        return URL(string: base + "/v1/models")
    }
}
