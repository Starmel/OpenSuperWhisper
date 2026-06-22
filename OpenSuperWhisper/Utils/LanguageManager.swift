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

    /// Relaunch the app so the new language is loaded. A detached shell waits for this process to
    /// fully exit, then reopens the app — guaranteeing a single fresh instance (no race / no double
    /// instance from launching a second copy while the first is still alive).
    static func relaunch() {
        let path = Bundle.main.bundlePath
        let pid = ProcessInfo.processInfo.processIdentifier
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while /bin/kill -0 \(pid) >/dev/null 2>&1; do /bin/sleep 0.1; done; /usr/bin/open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}
