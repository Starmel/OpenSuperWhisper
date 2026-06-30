//
//  FocusUtils.swift
//  OpenSuperWhisper
//
//  Created by user on 07.02.2025.
//

import AppKit
import ApplicationServices
import Carbon
import Cocoa
import Foundation
import KeyboardShortcuts
import SwiftUI

class FocusUtils {

    /// Hard ceiling for any synchronous Accessibility request. These calls are
    /// IPC to the frontmost app; without a timeout a wedged target (a busy
    /// browser/Electron app) blocks the calling thread — and since the global
    /// hotkey tap runs on the main run loop, that freezes the whole app and the
    /// recording shortcut (#freeze). Half a second is far longer than a healthy
    /// AX reply and short enough to fall back gracefully. Shared with SourceCapture.
    static let axMessagingTimeout: Float = 0.5

    static func getCurrentCursorPosition() -> NSPoint {
        return NSEvent.mouseLocation
    }

    /// The indicator only needs the text caret position in "cursor" mode; every
    /// other position anchors to screen geometry. Used to skip the costly AX
    /// caret query (a main-thread hang risk) when it would be discarded anyway.
    static func shouldAnchorToCaret(indicatorPosition: String) -> Bool {
        return indicatorPosition == "cursor"
    }

    static func getCaretRect() -> CGRect? {
        // Получаем системный элемент для доступа ко всему UI
        let systemElement = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemElement, axMessagingTimeout)

        // Получаем фокусированный элемент
        var focusedElement: CFTypeRef? // Keep as CFTypeRef? if you prefer
        let errorFocused = AXUIElementCopyAttributeValue(systemElement,
                                                         kAXFocusedUIElementAttribute as CFString,
                                                         &focusedElement)
        
        print("errorFocused: \(errorFocused)")
        guard errorFocused == .success else {
            print("Не удалось получить фокусированный элемент")
            return nil
        }
        
        guard let focusedElementCF = focusedElement else { // Optional binding to safely unwrap CFTypeRef
            print("Не удалось получить фокусированный элемент (CFTypeRef is nil)") // Extra safety check, though unlikely
            return nil
        }
        
        let element = focusedElementCF as! AXUIElement
        AXUIElementSetMessagingTimeout(element, axMessagingTimeout)
        // Получаем выделенный текстовый диапазон у фокусированного элемента
        var selectedTextRange: AnyObject?
        let errorRange = AXUIElementCopyAttributeValue(element,
                                                       kAXSelectedTextRangeAttribute as CFString,
                                                       &selectedTextRange)
        guard errorRange == .success,
              let textRange = selectedTextRange
        else {
            print("Не удалось получить диапазон выделенного текста")
            return nil
        }
        
        // Используем параметризованный атрибут для получения границ диапазона (положение каретки)
        var caretBounds: CFTypeRef?
        let errorBounds = AXUIElementCopyParameterizedAttributeValue(element,
                                                                     kAXBoundsForRangeParameterizedAttribute as CFString,
                                                                     textRange,
                                                                     &caretBounds)
        
        print("errorbounds: \(errorBounds), caretBounds \(String(describing: caretBounds))")
        guard errorBounds == .success else {
            print("Не удалось получить границы каретки")
            return nil
        }
        
        let rect = caretBounds as! AXValue
        
        return rect.toCGRect()
    }
    
    /// Converts a point from AX API coordinate system (Quartz: origin at top-left of primary screen, Y increases downward)
    /// to Cocoa coordinate system (origin at bottom-left of primary screen, Y increases upward)
    static func convertAXPointToCocoa(_ axPoint: CGPoint) -> NSPoint {
        guard let primaryScreen = NSScreen.screens.first else {
            return NSPoint(x: axPoint.x, y: axPoint.y)
        }
        // Primary screen maxY represents the total height in Cocoa coordinates
        // AX Y=0 is at Cocoa Y=maxY, so we subtract axPoint.y from maxY
        let cocoaY = primaryScreen.frame.maxY - axPoint.y
        return NSPoint(x: axPoint.x, y: cocoaY)
    }
    
    /// Finds the screen that contains the given point (in Cocoa coordinates)
    static func screenContaining(point: NSPoint) -> NSScreen? {
        for screen in NSScreen.screens {
            if screen.frame.contains(point) {
                return screen
            }
        }
        return NSScreen.main
    }
    
    static func getFocusedWindowScreen() -> NSScreen? {
        let systemWideElement = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWideElement, axMessagingTimeout)

        var focusedWindow: AnyObject?
        let result = AXUIElementCopyAttributeValue(systemWideElement,
                                                   kAXFocusedWindowAttribute as CFString,
                                                   &focusedWindow)
        
        guard result == .success else {
            print("Не удалось получить сфокусированное окно")
            return NSScreen.main
        }
        let windowElement = focusedWindow as! AXUIElement
        
        var windowFrameValue: CFTypeRef?
        let frameResult = AXUIElementCopyAttributeValue(windowElement,
                                                        
                                                        "AXFrame" as CFString,
                                                        &windowFrameValue)
        
        guard frameResult == .success else {
            print("Не удалось получить фрейм окна")
            return NSScreen.main
        }
        let frameValue = windowFrameValue as! AXValue
        
        var windowFrame = CGRect.zero
        guard AXValueGetValue(frameValue, AXValueType.cgRect, &windowFrame) else {
            print("Не удалось извлечь CGRect из AXValue")
            return NSScreen.main
        }
        
        for screen in NSScreen.screens {
            if screen.frame.intersects(windowFrame) {
                return screen
            }
        }

        return NSScreen.main
    }

    // MARK: - Paste target detection

    static let editableRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
    ]

    static let nonEditableRoles: Set<String> = [
        kAXButtonRole as String,
        kAXWindowRole as String,
        kAXImageRole as String,
        kAXMenuRole as String,
        kAXMenuItemRole as String,
        kAXMenuBarRole as String,
        kAXCheckBoxRole as String,
        kAXRadioButtonRole as String,
        kAXSliderRole as String,
        kAXStaticTextRole as String,
    ]

    /// Pure decision from observed accessibility facts (unit-testable).
    /// Biased toward `true`: only returns `false` when we are confident there is
    /// no editable text target, so callers never warn spuriously.
    static func classifyEditability(hasFocusedElement: Bool, valueIsSettable: Bool, role: String?) -> Bool {
        if !hasFocusedElement { return false }
        if valueIsSettable { return true }
        if let role = role {
            if editableRoles.contains(role) { return true }
            if nonEditableRoles.contains(role) { return false }
        }
        return true
    }

    /// Best-effort check of whether the system-wide focused element can receive
    /// pasted text. Returns `nil` when undeterminable (no Accessibility trust).
    static func focusedElementIsEditable() -> Bool? {
        guard AXIsProcessTrusted() else { return nil }

        let systemElement = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemElement, axMessagingTimeout)
        var focused: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(systemElement,
                                                kAXFocusedUIElementAttribute as CFString,
                                                &focused)
        guard err == .success, let focusedCF = focused else {
            return classifyEditability(hasFocusedElement: false, valueIsSettable: false, role: nil)
        }
        let element = focusedCF as! AXUIElement
        AXUIElementSetMessagingTimeout(element, axMessagingTimeout)

        var settable: DarwinBoolean = false
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)

        var roleRef: CFTypeRef?
        let role: String?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success {
            role = roleRef as? String
        } else {
            role = nil
        }

        return classifyEditability(hasFocusedElement: true,
                                   valueIsSettable: settable.boolValue,
                                   role: role)
    }

}

private extension AXValue {
    func toCGRect() -> CGRect? {
        var rect = CGRect.zero
        let type: AXValueType = AXValueGetType(self)
        
        guard type == .cgRect else {
            print("AXValue is not of type CGRect, but \(type)") // More informative error
            return nil
        }
        
        let success = AXValueGetValue(self, .cgRect, &rect)
        
        guard success else {
            print("Failed to get CGRect value from AXValue")
            return nil
        }
        return rect
    }
}
