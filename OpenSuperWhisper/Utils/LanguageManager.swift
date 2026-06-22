import AppKit
import Foundation

/// In-app override of the interface language. Writes the standard `AppleLanguages` default so the
/// override persists in the app's own domain (independent of the system language); takes effect on
/// the next launch.
enum LanguageManager {
    /// "system" (follow the Mac), "en", or "fr".
    static var selected: String {
        get { UserDefaults.standard.string(forKey: "appLanguageOverride") ?? "system" }
        set {
            UserDefaults.standard.set(newValue, forKey: "appLanguageOverride")
            if newValue == "system" {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([newValue], forKey: "AppleLanguages")
            }
        }
    }

    /// Relaunch the app so the new language is loaded.
    static func relaunch() {
        let url = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
