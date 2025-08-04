import AVFoundation
import AppKit
import Foundation

enum Permission {
    case microphone
    case accessibility
}

class PermissionsManager: ObservableObject {
    @Published var isMicrophonePermissionGranted = false
    @Published var isAccessibilityPermissionGranted = false

    private var permissionCheckTimer: Timer?

    init() {
        checkMicrophonePermission()
        checkAccessibilityPermission()

        // Monitor accessibility permission changes using NSWorkspace's notification center
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityPermissionChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )

        // Start continuous permission checking
        startPermissionChecking()
    }

    deinit {
        stopPermissionChecking()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func startPermissionChecking() {
        // Timer is scheduled on the main run loop
        permissionCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkMicrophonePermission()
            self?.checkAccessibilityPermission()
        }
    }

    private func stopPermissionChecking() {
        permissionCheckTimer?.invalidate()
        permissionCheckTimer = nil
    }

    func checkMicrophonePermission() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        DispatchQueue.main.async { [weak self] in
            switch status {
            case .authorized:
                self?.isMicrophonePermissionGranted = true
            default:
                self?.isMicrophonePermissionGranted = false
            }
        }
    }

    func checkAccessibilityPermission() {
        let granted = AXIsProcessTrusted()
        
        // Debug logging for accessibility permission
        if AppPreferences.shared.debugMode {
            print("🔐 [Accessibility] Permission check: \(granted ? "GRANTED" : "DENIED")")
            
            // Additional debugging info
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
            let options = [promptKey: false] as CFDictionary
            let trustedWithPrompt = AXIsProcessTrustedWithOptions(options)
            print("🔐 [Accessibility] Trusted with options: \(trustedWithPrompt)")
        }
        
        DispatchQueue.main.async { [weak self] in
            self?.isAccessibilityPermissionGranted = granted
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
    
    func requestAccessibilityPermissionOrOpenSystemPreferences() {
        let currentlyGranted = AXIsProcessTrusted()
        
        if AppPreferences.shared.debugMode {
            print("🔐 [Accessibility] Current status: \(currentlyGranted ? "GRANTED" : "DENIED")")
        }
        
        if !currentlyGranted {
            // First, try to prompt for permission
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
            let options = [promptKey: true] as CFDictionary
            let trustedWithPrompt = AXIsProcessTrustedWithOptions(options)
            
            if AppPreferences.shared.debugMode {
                print("🔐 [Accessibility] Requested permission with prompt: \(trustedWithPrompt)")
            }
            
            // If still not granted after prompt attempt, open System Preferences
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                if !AXIsProcessTrusted() {
                    self?.openSystemPreferences(for: .accessibility)
                }
            }
        }
        
        // Update our state
        DispatchQueue.main.async { [weak self] in
            self?.isAccessibilityPermissionGranted = currentlyGranted
        }
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
