import CoreGraphics
import SwiftUI

struct SingleKeyCaptureView: View {
    let onCapture: (TriggerKey) -> Void
    let existing: [TriggerKey]
    /// Key codes already bound as key combinations, to prevent a double-firing duplicate.
    let existingComboKeyCodes: Set<UInt16>
    @Environment(\.dismiss) private var dismiss

    @State private var captured: TriggerKey?
    @State private var warning: String?
    @State private var isListening = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Press the key you want to use")
                .font(.headline)

            Text(displayText)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: 56)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.4), lineWidth: 1)
                )

            if let warning {
                Text(warning)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
            }

            HStack {
                Button("Cancel") { stopAndDismiss() }
                Spacer()
                Button("Add") {
                    if let captured { onCapture(captured) }
                    stopAndDismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(captured == nil)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear { startCapture() }
        .onDisappear { CaptureMonitor.shared.stop() }
    }

    private var displayText: String {
        if let captured { return captured.displayName }
        return isListening ? "Listening…" : "Waiting for permission…"
    }

    private func startCapture() {
        guard CGPreflightListenEventAccess() else {
            isListening = false
            warning = "Grant Input Monitoring in System Settings, then reopen this dialog."
            return
        }
        isListening = true
        CaptureMonitor.shared.start { key in
            if key.keyCode == 53 { // Escape
                warning = "Esc is reserved for canceling recording."
                return
            }
            if existing.contains(where: { $0.id == key.id }) {
                warning = "That key is already added."
                return
            }
            if existingComboKeyCodes.contains(key.keyCode) {
                warning = "That key is already used by a key combination."
                return
            }
            if key.kind == .regular && CaptureMonitor.isTextProducing(key.keyCode) {
                warning = "Warning: this key will trigger recording globally while the app runs."
            } else {
                warning = nil
            }
            captured = key
        }
    }

    private func stopAndDismiss() {
        CaptureMonitor.shared.stop()
        dismiss()
    }
}

/// Temporary listen-only tap used only while the capture sheet is open.
final class CaptureMonitor {
    static let shared = CaptureMonitor()

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var onKey: ((TriggerKey) -> Void)?

    private init() {}

    /// Key codes that produce text/navigation (main block, excl. Esc which is rejected) —
    /// warn before binding, since they'd also trigger recording globally.
    static func isTextProducing(_ keyCode: UInt16) -> Bool {
        Set<UInt16>(0...53).subtracting([53]).contains(keyCode)
    }

    func start(onKey: @escaping (TriggerKey) -> Void) {
        stop()
        self.onKey = onKey

        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
                 | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)

        guard let t = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<CaptureMonitor>.fromOpaque(refcon).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                monitor.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return }

        tap = t
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, t, 0)
        if let source {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: t, enable: true)
        }
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        tap = nil
        source = nil
        onKey = nil
    }

    private func handle(type: CGEventType, event: CGEvent) {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let key: TriggerKey

        if type == .flagsChanged {
            // Capture a modifier only on press (its device bit set).
            guard let pressed = TriggerKey.isModifierPressed(
                keyCode: keyCode, flagsRawValue: event.flags.rawValue
            ), pressed else { return }
            guard let mk = ModifierKey.allCases.first(where: { $0.keyCode == keyCode }) else { return }
            key = TriggerKey(modifierKey: mk)
        } else {
            let label = TriggerKey.regularKeyLabel(forKeyCode: keyCode)
            key = TriggerKey(keyCode: keyCode, kind: .regular,
                             displayName: label.name, symbol: label.symbol)
        }

        DispatchQueue.main.async { [weak self] in self?.onKey?(key) }
    }
}
