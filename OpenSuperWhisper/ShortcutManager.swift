import AppKit
import ApplicationServices
import Carbon
import Cocoa
import Foundation
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let toggleRecord = Self("toggleRecord", default: .init(.backtick, modifiers: .option))
    static let escape = Self("escape", default: .init(.escape))
}

class ShortcutManager {
    static let shared = ShortcutManager()

    private var activeVm: IndicatorViewModel?
    private var holdWorkItem: DispatchWorkItem?
    private let holdThreshold: TimeInterval = 0.3
    private var holdMode = false
    private var useModifierOnlyHotkey = false

    private init() {
        print("ShortcutManager init")
        
        setupKeyboardShortcuts()
        setupModifierKeyMonitor()
        
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
    
    @objc private func indicatorWindowDidHide() {
        activeVm = nil
        holdMode = false
    }
    
    @objc private func hotkeySettingsChanged() {
        setupModifierKeyMonitor()
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
                if self?.activeVm != nil {
                    IndicatorWindowManager.shared.stopForce()
                    self?.activeVm = nil
                }
            }
        }
        KeyboardShortcuts.disable(.escape)
    }
    
    private func setupModifierKeyMonitor() {
        let modifierKeyString = AppPreferences.shared.modifierOnlyHotkey
        let modifierKey = ModifierKey(rawValue: modifierKeyString) ?? .none
        
        if modifierKey != .none {
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
            useModifierOnlyHotkey = false
            ModifierKeyMonitor.shared.stop()
            KeyboardShortcuts.enable(.toggleRecord)
            print("ShortcutManager: Using regular keyboard shortcut")
        }
    }
    
    private func handleKeyDown() {
        holdWorkItem?.cancel()
        holdMode = false
        
        let modifierKey = ModifierKey(rawValue: AppPreferences.shared.modifierOnlyHotkey) ?? .none
        let holdToRecordEnabled = AppPreferences.shared.holdToRecord && !modifierKey.isCommandOrOption
        
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
        
        let modifierKey = ModifierKey(rawValue: AppPreferences.shared.modifierOnlyHotkey) ?? .none
        let holdToRecordEnabled = AppPreferences.shared.holdToRecord && !modifierKey.isCommandOrOption
        
        Task { @MainActor in
            if holdToRecordEnabled && self.holdMode {
                IndicatorWindowManager.shared.stopRecording()
                self.activeVm = nil
                self.holdMode = false
            }
        }
    }
}