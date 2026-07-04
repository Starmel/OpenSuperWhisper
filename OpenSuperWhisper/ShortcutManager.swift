import AppKit
import ApplicationServices
import Carbon
import Cocoa
import Foundation
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let toggleRecord = Self("toggleRecord", default: .init(.backtick, modifiers: .option))
    static let toggleRecord2 = Self("toggleRecord2")
    static let toggleRecord3 = Self("toggleRecord3")
    static let toggleRecord4 = Self("toggleRecord4")
    static let escape = Self("escape", default: .init(.escape))

    /// All combo slots, in display order. `.toggleRecord` is slot 1 (back-compat).
    static let recordComboPool: [KeyboardShortcuts.Name] = [
        .toggleRecord, .toggleRecord2, .toggleRecord3, .toggleRecord4,
    ]
}

class ShortcutManager {
    static let shared = ShortcutManager()

    private var activeVm: IndicatorViewModel?
    private var holdWorkItem: DispatchWorkItem?
    private let holdThreshold: TimeInterval = 0.3
    private var holdMode = false

    private init() {
        print("ShortcutManager init")

        setupKeyboardShortcuts()
        setupTriggerKeyMonitor()
        
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

        // Re-arm the single-key monitor when the app reactivates — e.g. after the
        // user grants Input Monitoring in System Settings and returns to the app.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @objc private func appDidBecomeActive() {
        // Only (re)start when single-key triggers exist, permission is now granted,
        // and the monitor isn't already running — the post-grant recovery case.
        let hasTriggers = !AppPreferences.shared.singleKeyTriggers.isEmpty
        if hasTriggers, !TriggerKeyMonitor.shared.isRunning, CGPreflightListenEventAccess() {
            setupTriggerKeyMonitor()
        }
    }
    
    @objc private func indicatorWindowDidHide() {
        activeVm = nil
        holdMode = false
    }
    
    @objc private func hotkeySettingsChanged() {
        setupTriggerKeyMonitor()
    }

    private func setupKeyboardShortcuts() {
        for name in KeyboardShortcuts.Name.recordComboPool {
            KeyboardShortcuts.onKeyDown(for: name) { [weak self] in self?.handleKeyDown() }
            KeyboardShortcuts.onKeyUp(for: name) { [weak self] in self?.handleKeyUp() }
        }

        KeyboardShortcuts.onKeyUp(for: .escape) { [weak self] in
            Task { @MainActor in
                if self?.activeVm != nil {
                    IndicatorWindowManager.shared.stopForce()
                    self?.activeVm = nil
                }
            }
        }
        KeyboardShortcuts.disable(.escape)
    }

    /// Combos (Carbon) are always active; the event-tap monitor runs only when
    /// single-key triggers are configured and Input Monitoring is granted.
    private func setupTriggerKeyMonitor() {
        let triggers = Set(AppPreferences.shared.singleKeyTriggers)

        guard !triggers.isEmpty else {
            TriggerKeyMonitor.shared.stop()
            return
        }

        guard CGPreflightListenEventAccess() else {
            TriggerKeyMonitor.shared.stop()
            print("ShortcutManager: single-key triggers configured but Input Monitoring not granted")
            return
        }

        TriggerKeyMonitor.shared.onKeyDown = { [weak self] in self?.handleKeyDown() }
        TriggerKeyMonitor.shared.onKeyUp = { [weak self] in self?.handleKeyUp() }
        TriggerKeyMonitor.shared.start(keys: triggers)
    }
    
    private func handleKeyDown() {
        holdWorkItem?.cancel()
        holdMode = false
        
        let holdToRecordEnabled = AppPreferences.shared.holdToRecord
        
        Task { @MainActor in
            if self.activeVm == nil {
                let cursorPosition = FocusUtils.getCurrentCursorPosition()
                let indicatorPoint: NSPoint?
                if let caret = FocusUtils.getCaretRect() {
                    indicatorPoint = FocusUtils.convertAXPointToCocoa(caret.origin)
                } else {
                    indicatorPoint = cursorPosition
                }
                let vm = IndicatorWindowManager.shared.show(nearPoint: indicatorPoint)
                vm.startRecording()
                self.activeVm = vm
            } else if !self.holdMode {
                IndicatorWindowManager.shared.stopRecording()
                self.activeVm = nil
            }
        }
        
        if holdToRecordEnabled {
            let workItem = DispatchWorkItem { [weak self] in
                self?.holdMode = true
            }
            holdWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + holdThreshold, execute: workItem)
        }
    }
    
    private func handleKeyUp() {
        holdWorkItem?.cancel()
        holdWorkItem = nil
        
        let holdToRecordEnabled = AppPreferences.shared.holdToRecord
        
        Task { @MainActor in
            if holdToRecordEnabled && self.holdMode {
                IndicatorWindowManager.shared.stopRecording()
                self.activeVm = nil
                self.holdMode = false
            }
        }
    }
}