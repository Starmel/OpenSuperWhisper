import AVFoundation
import AppKit
import Foundation
import IOKit.hid

enum Permission {
    case microphone
    case accessibility
    case inputMonitoring
}

class PermissionsManager: ObservableObject {
    @Published var isMicrophonePermissionGranted = false
    @Published var isAccessibilityPermissionGranted = false
    @Published var isInputMonitoringPermissionGranted = false
    /// False until the first async TCC check completes; the UI must not show
    /// "permission missing" warnings while the actual status is still unknown,
    /// otherwise they flash on every settings screen open.
    @Published private(set) var hasCompletedInitialCheck = false

    // TCC status queries (AVCaptureDevice.authorizationStatus, IOHIDCheckAccess)
    // are synchronous XPC round-trips to tccd taking 40-100 ms — they must
    // never run on the main thread (traces showed them dropping animation
    // frames every second while the polling timer was active).
    private let checkQueue = DispatchQueue(label: "com.opensuperwhisper.permissions", qos: .utility)
    private var isCheckInFlight = false

    private var permissionCheckTimer: Timer?
    private var windowObservers: [NSObjectProtocol] = []
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
        stopPermissionChecking()
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
        ) { [weak self] _ in
            self?.startPermissionChecking()
        }

        let closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.stopPermissionChecking()
        }

        let hideObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.stopPermissionChecking()
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

        windowObservers = [showObserver, closeObserver, hideObserver,
                           indicatorShowObserver, indicatorHideObserver]

        if let window = NSApplication.shared.mainWindow, window.isKeyWindow {
            startPermissionChecking()
        }
    }

    private func startPermissionChecking() {
        guard permissionCheckTimer == nil else { return }
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, !self.isIndicatorSessionActive else { return }
            self.checkAllPermissions()
        }
    }

    private func stopPermissionChecking() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
    }

    private func checkAllPermissions() {
        guard !isCheckInFlight else { return }
        isCheckInFlight = true

        checkQueue.async { [weak self] in
            let microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
            let accessibility = AXIsProcessTrusted()
            let inputMonitoring = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted

            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isCheckInFlight = false
                self.isMicrophonePermissionGranted = microphone
                self.isAccessibilityPermissionGranted = accessibility
                self.isInputMonitoringPermissionGranted = inputMonitoring
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

    func checkInputMonitoringPermission() {
        checkQueue.async { [weak self] in
            let granted = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
            DispatchQueue.main.async {
                self?.isInputMonitoringPermissionGranted = granted
            }
        }
    }

    func requestAccessibilityPermissionOrOpenSystemPreferences() {
        if AXIsProcessTrusted() {
            isAccessibilityPermissionGranted = true
        } else {
            openSystemPreferences(for: .accessibility)
        }
    }

    /// Shows the system Input Monitoring prompt if it hasn't been decided yet,
    /// otherwise opens System Settings so the user can grant it manually.
    func requestInputMonitoringPermissionOrOpenSystemPreferences() {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted:
            isInputMonitoringPermissionGranted = true
        case kIOHIDAccessTypeUnknown:
            let granted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            DispatchQueue.main.async { [weak self] in
                self?.isInputMonitoringPermissionGranted = granted
            }
        default:
            openSystemPreferences(for: .inputMonitoring)
        }
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
        case .inputMonitoring:
            urlString =
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        }

        if let url = URL(string: urlString) {
            DispatchQueue.main.async {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
