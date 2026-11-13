import AppKit
import Combine
import ApplicationServices
import Carbon
import Cocoa
import Foundation
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let toggleRecord = Self("toggleRecord", initial: .init(.backtick, modifiers: .option))

    /// Escape cancels the dictation on screen: the indicator enables the name
    /// while it is up and disables it again when it goes away.
    ///
    /// Declaring it is a write of its own — `Name.init` stores the initial
    /// combination in `UserDefaults.standard` when that key holds nothing
    /// (`KeyboardShortcuts.setInitialShortcutIfNeeded`) — and under test that
    /// domain is the one the app the developer is using reads, with nothing to
    /// put the key back. So a test process declares the name without a
    /// combination; `enable`, `disable` and reading a missing shortcut then only
    /// touch the library's in-memory state.
    static let escape = Self("escape", initial: OpenSuperWhisperApp.isRunningTests ? nil : .init(.escape))
}

@MainActor
class ShortcutManager {
    static let shared = ShortcutManager()

    private var triggerPermissions: PermissionsManager?
    private var permissionSubscription: AnyCancellable?
    private var activeVm: IndicatorViewModel?
    private var holdWorkItem: DispatchWorkItem?
    private let holdThreshold: TimeInterval = 0.3
    private var holdMode = false
    private var useModifierOnlyHotkey = false
    private var useMouseButtonHotkey = false

    init(registerShortcuts: Bool = true) {
        guard registerShortcuts else { return }
        print("ShortcutManager init")

        setupKeyboardShortcuts()
        setupRecordingTrigger()
        let permissions = PermissionsManager()
        triggerPermissions = permissions
        // Reconfigure the trigger when Accessibility changes: the modifier-only
        // hotkey is gated by it (the mouse button and the global key monitor
        // both are), so a fresh grant must rebuild the trigger.
        observeTriggerPermissions(permissions.$isAccessibilityPermissionGranted
            .map { $0 ? 1 : 0 }
            .eraseToAnyPublisher()) { [weak self] in self?.setupRecordingTrigger() }
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hotkeySettingsChanged),
            name: .hotkeySettingsChanged,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(indicatorWindowDidHide),
            name: .indicatorWindowDidHide,
            object: nil
        )
    }
    
    func observeTriggerPermissions(_ publisher: AnyPublisher<Int, Never>, reconfigure: @escaping () -> Void) {
        permissionSubscription = publisher
            .removeDuplicates()
            .dropFirst()
            .sink { _ in reconfigure() }
    }

    @objc private func indicatorWindowDidHide() {
        activeVm = nil
        holdMode = false
    }
    
    @objc private func hotkeySettingsChanged() {
        setupRecordingTrigger()
    }
    
    private func setupKeyboardShortcuts() {
        KeyboardShortcuts.onKeyDown(for: .toggleRecord) { [weak self] in
            self?.handleKeyDown()
        }

        KeyboardShortcuts.onKeyUp(for: .toggleRecord) { [weak self] in
            self?.handleKeyUp()
        }

        KeyboardShortcuts.onKeyUp(for: .escape) { [weak self] in
            Task { @MainActor in
                self?.handleEscape()
            }
        }
        KeyboardShortcuts.disable(.escape)
    }
    
    func handleEscape() {
        if IndicatorWindowManager.shared.requestCancel() {
            activeVm = nil
        }
    }

    private func setupRecordingTrigger() {
        let modifierKey = ModifierKey(rawValue: AppPreferences.shared.modifierOnlyHotkey) ?? .none
        let mouseButton = MouseButton(rawValue: AppPreferences.shared.mouseButtonHotkey) ?? .none

        // The three trigger modes are mutually exclusive. Tear all of them down
        // first, then enable exactly one. A configured mouse button takes priority
        // over a modifier key, which takes priority over the regular shortcut.
        ModifierKeyMonitor.shared.stop()
        MouseButtonMonitor.shared.stop()

        if mouseButton != .none {
            useMouseButtonHotkey = true
            useModifierOnlyHotkey = false
            KeyboardShortcuts.disable(.toggleRecord)

            MouseButtonMonitor.shared.onButtonDown = { [weak self] in
                self?.handleKeyDown()
            }

            MouseButtonMonitor.shared.onButtonUp = { [weak self] in
                self?.handleKeyUp()
            }

            MouseButtonMonitor.shared.start(mouseButton: mouseButton)
            print("ShortcutManager: Using mouse-button hotkey: \(mouseButton.displayName)")
        } else if modifierKey != .none {
            useMouseButtonHotkey = false
            useModifierOnlyHotkey = true
            KeyboardShortcuts.disable(.toggleRecord)

            ModifierKeyMonitor.shared.onKeyDown = { [weak self] in
                self?.handleKeyDown()
            }

            ModifierKeyMonitor.shared.onKeyUp = { [weak self] in
                self?.handleKeyUp()
            }

            ModifierKeyMonitor.shared.start(modifierKey: modifierKey)
            print("ShortcutManager: Using modifier-only hotkey: \(modifierKey.displayName)")
        } else {
            useMouseButtonHotkey = false
            useModifierOnlyHotkey = false
            // A stored `false` — what the library writes when a combination is
            // cleared — also stops `Name.init` from ever applying the initial
            // this app declares for `toggleRecord`, so this mode could be
            // selected with no shortcut behind it: no trigger at all, and
            // nothing on screen saying so. The mode is the one the user picked,
            // so it gets its declared combination instead of silence.
            if KeyboardShortcuts.getShortcut(for: .toggleRecord) == nil {
                KeyboardShortcuts.reset(.toggleRecord)
            }
            KeyboardShortcuts.enable(.toggleRecord)
            print("ShortcutManager: Using regular keyboard shortcut")
        }
    }
    
    private func handleKeyDown() {
        holdWorkItem?.cancel()
        holdMode = false
        
        let session = RecordingSessionController.shared
        if session.hasSession {
            session.requestStop()
            return
        }
        guard activeVm == nil else { return }
        let vm = IndicatorWindowManager.shared.prepare()
        activeVm = vm
        vm.startRecording()
        let cursorPosition = FocusUtils.getCurrentCursorPosition()
        Task { @MainActor in
            let anchorPoint = await Self.resolveAnchorPoint(timeoutNanoseconds: 150_000_000)
            let point = FocusUtils.chooseIndicatorPoint(resolvedInputAnchor: anchorPoint, cursorPosition: cursorPosition)
            IndicatorWindowManager.shared.presentWindow(for: vm, nearPoint: point)
        }
        if AppPreferences.shared.holdToRecord && session.isCapturing {
            let workItem = DispatchWorkItem { [weak self] in self?.holdMode = true }
            holdWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: workItem)
        }
    }

    /// Resolves the input anchor without letting a slow focused app delay the
    /// indicator: whichever finishes first wins — the AX resolution or the
    /// deadline. On timeout the caller falls back to the mouse position; the
    /// late AX result is simply discarded.
    private static func resolveAnchorPoint(timeoutNanoseconds: UInt64) async -> NSPoint? {
        await withCheckedContinuation { (continuation: CheckedContinuation<NSPoint?, Never>) in
            let gate = AnchorGate(continuation)
            Task.detached {
                let point = FocusUtils.getInputAnchorPoint()
                await gate.resume(point)
            }
            Task.detached {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                await gate.resume(nil)
            }
        }
    }
    
    private actor AnchorGate {
        private var continuation: CheckedContinuation<NSPoint?, Never>?
        
        init(_ continuation: CheckedContinuation<NSPoint?, Never>) {
            self.continuation = continuation
        }
        
        func resume(_ value: NSPoint?) {
            continuation?.resume(returning: value)
            continuation = nil
        }
    }
    
    private func handleKeyUp() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
        
        let holdToRecordEnabled = AppPreferences.shared.holdToRecord
        
        Task { @MainActor in
            if holdToRecordEnabled && self.holdMode && self.activeVm != nil {
                IndicatorWindowManager.shared.stopRecording()
            }
            self.holdMode = false
        }
    }
}
