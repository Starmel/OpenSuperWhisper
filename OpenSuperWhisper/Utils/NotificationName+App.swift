import Foundation

extension Notification.Name {
    /// Posted when a dictation could not be typed because macOS discarded the
    /// synthetic keystrokes: the Accessibility grant is missing. The permission
    /// surface re-checks live on this instead of trusting a cached value.
    static let accessibilityPermissionNeededForInjection = Notification.Name("AccessibilityPermissionNeededForInjection")
    static let hotkeySettingsChanged = Notification.Name("HotkeySettingsChanged")
    static let indicatorWindowDidHide = Notification.Name("IndicatorWindowDidHide")
    static let indicatorWindowWillShow = Notification.Name("IndicatorWindowWillShow")
    static let openSettings = Notification.Name("OpenSettings")
}

/// Which Settings card a caller wants on screen when it asks for Settings.
///
/// Carried in the `openSettings` notification's `userInfo`, so a surface
/// whose fix lives on a particular card opens the sheet on that card
/// instead of offering a door into the wrong room. A caller with no
/// opinion — the menu item, the hotkey notice — leaves it out and gets the
/// first card, exactly as before.
///
/// File scope rather than nested in `Notification.Name`: callers post and
/// read it as `SettingsDestination.userInfoKey`, and a nested type would
/// force every one of them to spell out `Notification.Name.` first.
enum SettingsDestination: Int {
    case shortcuts = 0
    case model = 1
    case transcription = 2
    case advanced = 3

    static let userInfoKey = "SettingsDestination"
}
