import AVFoundation
import AppKit
import Foundation

enum Permission: Hashable {
    case microphone
    case accessibility
}

class PermissionsManager: ObservableObject {
    @Published var isMicrophonePermissionGranted = false
    @Published var isAccessibilityPermissionGranted = false
    /// False until the first async TCC check completes; the UI must not show
    /// "permission missing" warnings while the actual status is still unknown,
    /// otherwise they flash on every settings screen open.
    @Published private(set) var hasCompletedInitialCheck = false

    // TCC status queries (AVCaptureDevice.authorizationStatus) are synchronous
    // XPC round-trips to tccd taking 40-100 ms — they must never run on the
    // main thread (traces showed them dropping animation frames every second
    // while the polling timer was active).
    private let checkQueue = DispatchQueue(label: "com.opensuperwhisper.permissions", qos: .utility)
    private var isCheckInFlight = false

    private var permissionCheckTimer: Timer?
    private var windowObservers: [NSObjectProtocol] = []
    /// Whether a main app window is key. The poll runs while it is, and keeps
    /// running while a permission is missing even when it is not: the grant
    /// usually lands while System Settings is frontmost, and the inline notice
    /// has to clear itself the moment the user comes back.
    private var isMainWindowKey = false
    /// Polling is paused for the whole indicator session (prepare → hidden):
    /// every millisecond of the main runloop there belongs to the animation.
    private var isIndicatorSessionActive = false

    init() {
        checkAllPermissions()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityPermissionChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )

        setupWindowObservers()
    }

    deinit {
        // Invalidate directly: stopPermissionCheckingIfIdle deliberately keeps
        // the timer alive while a permission is missing, and a timer that
        // outlived its owner would keep firing for the rest of the process.
        permissionCheckTimer?.invalidate()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func setupWindowObservers() {
        let showObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow,
                  AppDelegate.isMainAppWindow(window) else { return }
            self?.isMainWindowKey = true
            self?.startPermissionChecking()
            // A fresh value immediately, so a just-landed grant is not held
            // back by the polling interval.
            self?.checkAllPermissions()
        }

        let closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow,
                  AppDelegate.isMainAppWindow(window) else { return }
            self?.isMainWindowKey = false
            self?.stopPermissionCheckingIfIdle()
        }

        let hideObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow,
                  AppDelegate.isMainAppWindow(window) else { return }
            self?.isMainWindowKey = false
            self?.stopPermissionCheckingIfIdle()
        }

        // Coming back from System Settings is the moment a grant lands, so both
        // the poll and an immediate re-read start here rather than waiting for
        // the next tick of a timer that may have been stopped.
        let activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.startPermissionChecking()
            self?.checkAllPermissions()
        }

        let indicatorShowObserver = NotificationCenter.default.addObserver(
            forName: .indicatorWindowWillShow,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isIndicatorSessionActive = true
        }

        let indicatorHideObserver = NotificationCenter.default.addObserver(
            forName: .indicatorWindowDidHide,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isIndicatorSessionActive = false
        }

        let injectionTrustObserver = NotificationCenter.default.addObserver(
            forName: .accessibilityPermissionNeededForInjection,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkAccessibilityPermission()
        }

        windowObservers = [showObserver, closeObserver, hideObserver,
                           activationObserver, indicatorShowObserver, indicatorHideObserver,
                           injectionTrustObserver]

        if let window = NSApplication.shared.mainWindow, window.isKeyWindow {
            isMainWindowKey = true
            startPermissionChecking()
        }
    }

    private func startPermissionChecking() {
        guard permissionCheckTimer == nil else { return }
        // `.common` rather than the default mode: a menu or a scroll must not
        // stall the poll, since clearing an inline permission notice promptly
        // is the whole point of it.
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, !self.isIndicatorSessionActive else { return }
            self.checkAllPermissions()
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionCheckTimer = timer
    }

    /// The poll stops only when there is nothing left to watch: both grants are
    /// in place and no main window is open that needs its values refreshed. A
    /// missing grant keeps it alive even while another app is frontmost, which
    /// is what lets the inline notice clear itself once the user grants in
    /// System Settings and switches back.
    private func stopPermissionCheckingIfIdle() {
        guard !isMainWindowKey,
              isMicrophonePermissionGranted,
              isAccessibilityPermissionGranted
        else { return }
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
    }

    private func checkAllPermissions() {
        guard !isCheckInFlight else { return }
        isCheckInFlight = true

        checkQueue.async { [weak self] in
            let microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            let accessibility = AXIsProcessTrusted()

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isCheckInFlight = false
                self.isMicrophonePermissionGranted = microphone
                self.isAccessibilityPermissionGranted = accessibility
                self.hasCompletedInitialCheck = true
            }
        }
    }

    func checkMicrophonePermission() {
        checkQueue.async { [weak self] in
            let granted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            DispatchQueue.main.async {
                self?.isMicrophonePermissionGranted = granted
            }
        }
    }

    func checkAccessibilityPermission() {
        checkQueue.async { [weak self] in
            let granted = AXIsProcessTrusted()
            DispatchQueue.main.async {
                self?.isAccessibilityPermissionGranted = granted
            }
        }
    }

    /// A dictation was not typed because macOS discarded the keystrokes: the
    /// grant may have been lost while the app was running (rebuilding an
    /// ad-hoc-signed bundle invalidates it). The `.accessibilityPermissionNeededForInjection`
    /// observer re-reads it live instead of trusting a cached value.
    func requestAccessibilityPermissionOrOpenSystemPreferences() {
        if AXIsProcessTrusted() {
            isAccessibilityPermissionGranted = true
        } else {
            openSystemPreferences(for: .accessibility)
        }
        // The notice presses no "check again": the poll keeps re-reading while
        // the user is in System Settings, so it clears itself on the way back.
        startPermissionChecking()
    }

    func requestMicrophonePermissionOrOpenSystemPreferences() {

        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.isMicrophonePermissionGranted = granted
                }
            }
        case .authorized:
            self.isMicrophonePermissionGranted = true
        default:
            openSystemPreferences(for: .microphone)
        }

        // Same as Accessibility: the inline notice has to clear itself.
        startPermissionChecking()
    }

    @objc private func accessibilityPermissionChanged() {
        checkAccessibilityPermission()
    }

    func openSystemPreferences(for permission: Permission) {
        let urlString: String
        switch permission {
        case .microphone:
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case .accessibility:
            urlString =
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        }

        if let url = URL(string: urlString) {
            DispatchQueue.main.async {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

extension PermissionsManager {
    /// The inline notices the main window shows, in the order they are stacked.
    ///
    /// This is a notice, never a gate: the window renders its content whatever
    /// this returns. Two things make it self-clearing, and both are here rather
    /// than in a view so they can be read at a glance and tested:
    ///
    ///   * nothing is reported before the first TCC check answers, so no notice
    ///     flashes while the real status is still unknown;
    ///   * a granted permission is simply absent from the result, so the notice
    ///     for it disappears the moment the value flips - there is no "check
    ///     again" button and nothing to dismiss.
    static func notices(
        hasChecked: Bool,
        microphoneGranted: Bool,
        accessibilityGranted: Bool
    ) -> [Permission] {
        guard hasChecked else { return [] }
        // Accessibility first: it is the one that changes what a dictation does
        // (the text is saved but not typed), so it is the more surprising state.
        var notices: [Permission] = []
        if !accessibilityGranted { notices.append(.accessibility) }
        if !microphoneGranted { notices.append(.microphone) }
        return notices
    }
}
