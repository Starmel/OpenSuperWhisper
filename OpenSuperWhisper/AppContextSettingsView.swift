import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Settings → App Context. One place to manage context-aware model selection:
/// the switching mode plus a list of every app/site → model rule, with inline
/// model pickers and add/remove controls. Rules are also created from the
/// menu-bar "Model" submenu; this tab shows and edits the same store.
struct AppContextSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var rules: [AppContextRuleRow] = []
    @State private var selectedID: String?
    /// All usable models right now, across engines — recomputed on appear and
    /// after edits. Context-aware selection only makes sense with 2+.
    @State private var availableModels: [DictationModelOption] = []

    private var hasChoice: Bool { availableModels.count > 1 }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if hasChoice {
                    modeCard
                    rulesCard
                } else {
                    singleModelNotice
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: AppContextModelRules.didChangeNotification)) { _ in
            reload()
        }
    }

    // MARK: - Single-model notice

    private var singleModelNotice: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up.slash")
                    .font(.title2)
                    .foregroundColor(.secondary)
                Text("App-Specific Models")
                    .font(.headline)
            }
            Text("Context-aware model selection switches the transcription model based on the app (or website) you're dictating in — so it only helps once you have more than one model to choose from.")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Please download or configure another model to enable app-specific model selection.")
                .font(.callout).bold()
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Add a model under Engine & Model (download a Whisper / Parakeet / SenseVoice model, or point the Remote engine at a server).")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor).opacity(0.3))
        .cornerRadius(12)
    }

    // MARK: - Mode card (moved here from Advanced)

    private var modeCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 5) {
                Text("Context-Aware Model")
                    .font(.headline)
                    .foregroundColor(.primary)
                InfoButton(text: "Bind a transcription model to an app (or a website, in supported browsers) so it switches automatically when you dictate there. Add a rule below (＋), or from the menu-bar “Model” submenu while that app is focused.\n\n• Ask on change — auto-switch by app, and ask the scope (System Default / this app / just once / forget) whenever you pick a model in the menu.\n• Auto · no prompt — auto-switch by app, but picking a model just sets the system default (no prompt). Set rules up in “Ask”, then switch here.\n• Off — no auto-switch and no prompts.")
            }

            HStack {
                Text("Mode")
                    .font(.subheadline)
                Spacer()
                Picker("", selection: $viewModel.contextAwareModelMode) {
                    ForEach(ContextAwareModelMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor).opacity(0.3))
        .cornerRadius(12)
    }

    // MARK: - Rules list card

    private var rulesCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("App & Site Rules")
                .font(.headline)
                .foregroundColor(.primary)

            VStack(spacing: 0) {
                if rules.isEmpty {
                    Text("No rules yet. Click ＋ to add an app, or bind a model from the menu-bar “Model” submenu while an app is focused.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                        .padding(.horizontal, 12)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(rules) { rule in
                                ruleRow(rule)
                                if rule.id != rules.last?.id { Divider() }
                            }
                        }
                    }
                    .frame(height: min(max(CGFloat(rules.count) * 48, 96), 320))
                }

                Divider()

                // Add / remove bar, anchored bottom-right of the list container.
                HStack(spacing: 2) {
                    Spacer()
                    Button(action: addApp) {
                        Image(systemName: "plus").frame(width: 24, height: 20)
                    }
                    .buttonStyle(.borderless)
                    .help("Add an application…")

                    Button(action: removeSelected) {
                        Image(systemName: "minus").frame(width: 24, height: 20)
                    }
                    .buttonStyle(.borderless)
                    .disabled(selectedID == nil)
                    .help("Remove the selected rule")
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
            }
            .background(Color(.controlBackgroundColor).opacity(0.5))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(.separatorColor), lineWidth: 1)
            )
            .cornerRadius(8)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.controlBackgroundColor).opacity(0.3))
        .cornerRadius(12)
    }

    private func ruleRow(_ rule: AppContextRuleRow) -> some View {
        let isSelected = rule.id == selectedID
        return HStack(spacing: 10) {
            Group {
                if let icon = rule.icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "app.dashed").resizable()
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(rule.appName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let host = rule.host {
                    Text(host)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            Picker("", selection: Binding(
                get: { rule.model },
                set: { newModel in
                    AppContextModelRules.set(newModel, for: rule.bundleID, host: rule.host)
                    reload()
                }
            )) {
                ForEach(modelOptions(including: rule.model), id: \.self) { m in
                    Text(m.displayName).tag(m)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { selectedID = rule.id }
    }

    // MARK: - Data

    private func reload() {
        availableModels = ModelCatalog.allAvailable()
        rules = AppContextRuleRow.loadAll()
        if let sel = selectedID, !rules.contains(where: { $0.id == sel }) {
            selectedID = nil
        }
    }

    /// Models offered in a row's picker: everything usable now, plus the rule's
    /// current model if it isn't currently available (so the choice is never lost).
    private func modelOptions(including current: DictationModelOption) -> [DictationModelOption] {
        var options = availableModels
        if !options.contains(current) { options.insert(current, at: 0) }
        return options
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose an Application"
        panel.prompt = "Add"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundleID = Bundle(url: url)?.bundleIdentifier else { return }

        // Default the new rule to whatever model is currently in effect.
        guard let defaultModel = ModelCatalog.activeOption() ?? availableModels.first else { return }
        AppContextModelRules.set(defaultModel, for: bundleID)
        reload()
        selectedID = bundleID
    }

    private func removeSelected() {
        guard let id = selectedID, let rule = rules.first(where: { $0.id == id }) else { return }
        AppContextModelRules.remove(bundleID: rule.bundleID, host: rule.host)
        selectedID = nil
        reload()
    }
}

/// One displayable app/site rule, resolved from the persisted store.
struct AppContextRuleRow: Identifiable {
    /// Storage key: "bundleID" (app-wide) or "bundleID|host" (per-site).
    let id: String
    let bundleID: String
    let host: String?
    let model: DictationModelOption
    let appName: String
    let icon: NSImage?

    static func loadAll() -> [AppContextRuleRow] {
        AppContextModelRules.all().map { key, model -> AppContextRuleRow in
            let (bundleID, host) = parse(key)
            let (name, icon) = appInfo(for: bundleID)
            return AppContextRuleRow(id: key, bundleID: bundleID, host: host,
                                     model: model, appName: name, icon: icon)
        }
        .sorted {
            if $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedSame {
                return ($0.host ?? "") < ($1.host ?? "")
            }
            return $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
        }
    }

    private static func parse(_ key: String) -> (bundleID: String, host: String?) {
        if let pipe = key.firstIndex(of: "|") {
            return (String(key[..<pipe]), String(key[key.index(after: pipe)...]))
        }
        return (key, nil)
    }

    /// Resolve an installed app's display name + icon; fall back to the bundle id
    /// (with a generic icon) when the app isn't installed any more.
    private static func appInfo(for bundleID: String) -> (name: String, icon: NSImage?) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return (bundleID, nil)
        }
        let name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        return (name, NSWorkspace.shared.icon(forFile: url.path))
    }
}
