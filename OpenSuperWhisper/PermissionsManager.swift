import Foundation
import AVFoundation
import AppKit

enum Permission {
    case microphone
    case accessibility
}

class PermissionsManager: ObservableObject {
    @Published var isMicrophonePermissionGranted = false
    @Published var isAccessibilityPermissionGranted = false
    
    init() {
        checkMicrophonePermission()
        checkAccessibilityPermission()
        
        // Monitor accessibility permission changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(accessibilityPermissionChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        
        // Request accessibility permission on launch
        requestAccessibilityPermission()
    }
    
    func checkMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            isMicrophonePermissionGranted = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.isMicrophonePermissionGranted = granted
                }
            }
        default:
            isMicrophonePermissionGranted = false
        }
    }
    
    func checkAccessibilityPermission() {
        isAccessibilityPermissionGranted = AXIsProcessTrusted()
    }
    
    private func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        let trusted = AXIsProcessTrustedWithOptions(options as CFDictionary)
        isAccessibilityPermissionGranted = trusted
    }
    
    @objc private func accessibilityPermissionChanged() {
        checkAccessibilityPermission()
    }
    
    func openSystemPreferences(for permission: Permission) {
        switch permission {
        case .microphone:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        case .accessibility:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }
} 