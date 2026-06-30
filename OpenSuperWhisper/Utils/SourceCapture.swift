import AppKit
import ApplicationServices
import Foundation

/// Best-effort capture of "where" a dictation happened, beyond the app name: the
/// focused window's title (Accessibility) and, for supported browsers, the active
/// tab's URL (AppleScript — triggers a one-time automation permission per app).
enum SourceCapture {
    /// Title of the system-wide focused window (e.g. a browser tab or document).
    static func focusedWindowTitle() -> String? {
        // These AX calls are synchronous IPC to the frontmost app and run on the
        // main thread at record-start / menu-open; a wedged target would freeze the
        // recording hotkey without a timeout (#freeze). Bound every request, exactly
        // as FocusUtils does.
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, FocusUtils.axMessagingTimeout)
        var windowRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            system, kAXFocusedWindowAttribute as CFString, &windowRef
        ) == .success, let windowRef else { return nil }

        let window = windowRef as! AXUIElement
        AXUIElementSetMessagingTimeout(window, FocusUtils.axMessagingTimeout)
        var titleRef: AnyObject?
        guard AXUIElementCopyAttributeValue(
            window, kAXTitleAttribute as CFString, &titleRef
        ) == .success else { return nil }

        let title = titleRef as? String
        return (title?.isEmpty == false) ? title : nil
    }

    /// AppleScript to read the active tab/document URL, keyed by bundle id.
    private static let browserScripts: [String: String] = [
        "com.google.Chrome": "tell application \"Google Chrome\" to return URL of active tab of front window",
        "com.google.Chrome.beta": "tell application \"Google Chrome Beta\" to return URL of active tab of front window",
        "com.brave.Browser": "tell application \"Brave Browser\" to return URL of active tab of front window",
        "com.microsoft.edgemac": "tell application \"Microsoft Edge\" to return URL of active tab of front window",
        "com.vivaldi.Vivaldi": "tell application \"Vivaldi\" to return URL of active tab of front window",
        "company.thebrowser.Browser": "tell application \"Arc\" to return URL of active tab of front window",
        "com.apple.Safari": "tell application \"Safari\" to return URL of front document",
    ]

    /// Active-tab URL for a known browser bundle id, or nil (not a browser, no
    /// window, or automation permission denied). Synchronous — call on the main
    /// thread (NSAppleScript requirement).
    static func browserURL(bundleID: String) -> String? {
        guard let source = browserScripts[bundleID],
              let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return nil }
        let url = result.stringValue
        return (url?.isEmpty == false) ? url : nil
    }

    /// Host of a URL string, "www." stripped — e.g. "github.com". For display and
    /// (later) per-site rules.
    static func host(of urlString: String?) -> String? {
        guard let urlString,
              let host = URLComponents(string: urlString)?.host,
              !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
