import AppKit
import Foundation

/// How context-aware model selection behaves.
enum ContextAwareModelMode: String, CaseIterable {
    /// Auto-switch by app, and prompt (System Default / app / once / forget) when
    /// you change the model in the menu.
    case ask
    /// Auto-switch by app, but changing the model in the menu just sets the
    /// system default — no prompt. Set up app rules in "Ask", then switch here to
    /// stop the per-change prompts.
    case auto
    /// No auto-switch and no prompts.
    case off

    var label: String {
        switch self {
        case .ask: return "Ask on change"
        case .auto: return "Auto · no prompt"
        case .off: return "Off"
        }
    }

    /// Auto-switch to an app's bound model at record-start?
    var autoSwitches: Bool { self != .off }
    /// Prompt for scope when the model changes in the menu?
    var prompts: Bool { self == .ask }
}

/// The app the user is currently targeting — refreshed at record-start and when
/// the menu-bar picker opens — so binding a model maps to the right app.
/// Runtime-only.
final class RecordingContext {
    static let shared = RecordingContext()
    private(set) var appName: String?
    private(set) var bundleID: String?
    /// URL host for supported browsers (e.g. "docs.google.com") — enables
    /// per-site rules. nil for non-browsers or when the URL is unavailable.
    private(set) var host: String?
    /// Full active-tab URL for supported browsers (for transcript metadata).
    private(set) var fullURL: String?
    /// Focused window title at capture time (for transcript metadata).
    private(set) var windowTitle: String?
    private init() {}

    func update(appName: String?, bundleID: String?, host: String? = nil,
                fullURL: String? = nil, windowTitle: String? = nil) {
        self.appName = appName
        self.bundleID = bundleID
        self.host = host
        self.fullURL = fullURL
        self.windowTitle = windowTitle
    }

    /// A label for the most specific bindable scope: the site host if we have
    /// one, otherwise the app name.
    var scopeLabel: String? { host ?? appName }

    /// Capture the current frontmost app (browser site + URL + window title) as
    /// the active context. Opening a status-bar menu doesn't steal focus, so this
    /// is the app the cursor is in. If our own app is frontmost, keep the previous
    /// context.
    func captureFrontmost() {
        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundle = front.bundleIdentifier,
              bundle != Bundle.main.bundleIdentifier
        else { return }
        let url = SourceCapture.browserURL(bundleID: bundle)
        let host = SourceCapture.host(of: url)
        let title = SourceCapture.focusedWindowTitle()
        update(appName: front.localizedName, bundleID: bundle, host: host,
               fullURL: url, windowTitle: title)
    }

    // One-time model override. "Just This Time" makes the *next* recording in an
    // app use the picked model instead of the app's rule, then reverts —
    // otherwise the rule re-applies at record-start and clobbers the one-off.
    private var oneTimeBundleID: String?
    private var oneTimeModel: DictationModelOption?

    func setOneTimeModel(_ model: DictationModelOption, for bundleID: String) {
        oneTimeBundleID = bundleID
        oneTimeModel = model
    }

    func clearOneTimeModel(for bundleID: String) {
        if oneTimeBundleID == bundleID {
            oneTimeBundleID = nil
            oneTimeModel = nil
        }
    }

    /// Return and clear a pending one-time model for this app, if any.
    func consumeOneTimeModel(for bundleID: String) -> DictationModelOption? {
        guard oneTimeBundleID == bundleID, let model = oneTimeModel else { return nil }
        oneTimeBundleID = nil
        oneTimeModel = nil
        return model
    }
}

/// Per-app default model rules: bundle id → model. Persisted as JSON in
/// AppPreferences. Rules are created only when the user confirms the menu-bar
/// prompt, so this holds deliberate choices — never every app touched.
enum AppContextModelRules {
    /// Posted after any rule is added, changed, or removed (from this tab or the
    /// menu-bar "Model" submenu), so open UI can refresh live.
    static let didChangeNotification = Notification.Name("AppContextModelRulesDidChange")

    static func all() -> [String: DictationModelOption] {
        let data = AppPreferences.shared.appModelRulesData
        guard !data.isEmpty,
              let rules = try? JSONDecoder().decode(
                  [String: DictationModelOption].self, from: data
              )
        else { return [:] }
        return rules
    }

    /// Composite key: "bundleID|host" for a per-site rule, "bundleID" for an
    /// app-wide rule.
    static func key(bundleID: String, host: String?) -> String {
        if let host, !host.isEmpty { return "\(bundleID)|\(host)" }
        return bundleID
    }

    /// Resolved rule for the current context: a site-specific rule wins, else the
    /// app-level rule.
    static func rule(for bundleID: String, host: String? = nil) -> DictationModelOption? {
        let rules = all()
        if let host, !host.isEmpty, let site = rules["\(bundleID)|\(host)"] { return site }
        return rules[bundleID]
    }

    /// The rule stored at exactly this scope (site if a host is given, else app)
    /// — for the "Forget" option and to know what a bind would replace.
    static func exactRule(for bundleID: String, host: String?) -> DictationModelOption? {
        all()[key(bundleID: bundleID, host: host)]
    }

    static func set(_ option: DictationModelOption, for bundleID: String, host: String? = nil) {
        var rules = all()
        rules[key(bundleID: bundleID, host: host)] = option
        save(rules)
    }

    static func remove(bundleID: String, host: String? = nil) {
        var rules = all()
        rules.removeValue(forKey: key(bundleID: bundleID, host: host))
        save(rules)
    }

    private static func save(_ rules: [String: DictationModelOption]) {
        if let data = try? JSONEncoder().encode(rules) {
            AppPreferences.shared.appModelRulesData = data
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }
}

/// Applies context-aware model selection at record-start. Kept here so the main
/// window and the indicator recording paths share one implementation.
enum ContextModelSwitcher {
    /// Switch to the model bound to the current app/site (if any), honoring a
    /// pending one-time override. No-op when the mode doesn't auto-switch or when
    /// the bound model is already active. Reads the live `RecordingContext`, so
    /// call `RecordingContext.shared.captureFrontmost()` first.
    static func applyForCurrentContext() {
        guard AppPreferences.shared.contextAwareModelMode.autoSwitches,
              let bundleID = RecordingContext.shared.bundleID else { return }
        let host = RecordingContext.shared.host

        // A "Just This Time" override wins for exactly the next recording.
        if let once = RecordingContext.shared.consumeOneTimeModel(for: bundleID) {
            if ModelCatalog.activeOption() != once { ModelCatalog.activate(once) }
            return
        }

        guard let rule = AppContextModelRules.rule(for: bundleID, host: host) else { return }
        if ModelCatalog.activeOption() != rule {
            ModelCatalog.activate(rule)
        }
    }
}
