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
    
    static func getCurrentCursorPosition() -> NSPoint {
        return NSEvent.mouseLocation
    }
    
    /// Every AX call is a synchronous IPC round-trip with a 6-second default
    /// timeout: a busy focused app freezes the whole anchor resolution and the
    /// indicator appears with a multi-second lag. Cap each call instead.
    private static let axCallTimeoutSeconds: Float = 0.25
    
    private static func getFocusedElement() -> AXUIElement? {
        let systemElement = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemElement, axCallTimeoutSeconds)
        
        var focusedElement: CFTypeRef?
        let errorFocused = AXUIElementCopyAttributeValue(systemElement,
                                                         kAXFocusedUIElementAttribute as CFString,
                                                         &focusedElement)
        
        print("errorFocused: \(errorFocused)")
        guard errorFocused == .success, let focusedElementCF = focusedElement else {
            print("Не удалось получить фокусированный элемент")
            return nil
        }
        
        let element = focusedElementCF as! AXUIElement
        AXUIElementSetMessagingTimeout(element, axCallTimeoutSeconds)
        return element
    }
    
    static func getCaretRect(for element: AXUIElement) -> CGRect? {
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
        
        let rangeValue = textRange as! AXValue
        
        // Границы самого диапазона каретки (пустого) — работает в большинстве приложений
        if let rect = boundsForRange(element, rangeValue), isValidCaretRect(rect) {
            return rect
        }
        
        // Terminal.app и некоторые поля не умеют считать границы пустого
        // диапазона (отдают w:0 h:0), но умеют для диапазона с реальным
        // символом. Берём символ сразу после каретки, иначе символ перед ней.
        var selectedRange = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &selectedRange) else { return nil }
        
        if let rect = boundsForCharacter(element, at: selectedRange.location) {
            // Каретка стоит перед этим символом — его левый край и есть позиция ввода.
            return CGRect(x: rect.minX, y: rect.minY, width: 0, height: rect.height)
        }
        if selectedRange.location > 0,
           let rect = boundsForCharacter(element, at: selectedRange.location - 1) {
            // Каретка стоит после этого символа — позиция ввода у его правого края.
            return CGRect(x: rect.maxX, y: rect.minY, width: 0, height: rect.height)
        }
        
        print("Не удалось получить границы каретки")
        return nil
    }
    
    private static func boundsForCharacter(_ element: AXUIElement, at location: CFIndex) -> CGRect? {
        var charRange = CFRange(location: location, length: 1)
        guard let charRangeValue = AXValueCreate(.cfRange, &charRange) else { return nil }
        guard let rect = boundsForRange(element, charRangeValue), isValidCaretRect(rect) else { return nil }
        return rect
    }
    
    private static func boundsForRange(_ element: AXUIElement, _ range: AXValue) -> CGRect? {
        var bounds: CFTypeRef?
        let errorBounds = AXUIElementCopyParameterizedAttributeValue(element,
                                                                     kAXBoundsForRangeParameterizedAttribute as CFString,
                                                                     range,
                                                                     &bounds)
        
        print("errorbounds: \(errorBounds), caretBounds \(String(describing: bounds))")
        guard errorBounds == .success, let boundsValue = bounds else { return nil }
        
        return (boundsValue as! AXValue).toCGRect()
    }
    
    /// Frame of the focused UI element (AX coordinates) — where input will go
    /// when the exact caret position is not available.
    static func getElementFrame(for element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionCF = positionValue, let sizeCF = sizeValue
        else {
            print("Не удалось получить фрейм фокусированного элемента")
            return nil
        }
        
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionCF as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeCF as! AXValue, .cgSize, &size)
        else {
            return nil
        }
        
        return CGRect(origin: position, size: size)
    }
    
    /// Anchor point (Cocoa coordinates) for the recording indicator:
    /// the exact caret position when the app reports it, otherwise the top
    /// center of the focused UI element — the place where input will happen.
    /// Returns nil when neither can be trusted.
    static func getInputAnchorPoint() -> NSPoint? {
        guard let primaryScreen = NSScreen.screens.first else { return nil }
        let primaryMaxY = primaryScreen.frame.maxY
        let screenFrames = NSScreen.screens.map { $0.frame }
        
        let start = CFAbsoluteTimeGetCurrent()
        defer {
            print("Input anchor resolved in \(Int((CFAbsoluteTimeGetCurrent() - start) * 1000)) ms")
        }
        
        // The focused element is fetched once and reused by both strategies:
        // it is an IPC round-trip, not a cheap accessor.
        guard let element = getFocusedElement() else { return nil }
        
        if let rect = getCaretRect(for: element),
           let point = validatedCaretPoint(fromAXRect: rect, primaryScreenMaxY: primaryMaxY, screenFrames: screenFrames) {
            return point
        }
        if let frame = getElementFrame(for: element),
           let point = validatedElementAnchorPoint(forAXFrame: frame, primaryScreenMaxY: primaryMaxY, screenFrames: screenFrames) {
            return point
        }
        return nil
    }
    
    /// Top center of the focused element converted to Cocoa coordinates,
    /// rejected when the element frame is degenerate or off-screen.
    static func validatedElementAnchorPoint(forAXFrame frame: CGRect, primaryScreenMaxY: CGFloat, screenFrames: [CGRect]) -> NSPoint? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        let point = convertAXPointToCocoa(CGPoint(x: frame.midX, y: frame.minY), primaryScreenMaxY: primaryScreenMaxY)
        guard frameIndex(containing: point, frames: screenFrames) != nil else { return nil }
        return point
    }
    
    static func validatedCaretPoint(fromAXRect rect: CGRect, primaryScreenMaxY: CGFloat, screenFrames: [CGRect]) -> NSPoint? {
        guard isValidCaretRect(rect) else {
            print("Каретка имеет нулевые границы — позиция невалидна")
            return nil
        }
        let point = convertAXPointToCocoa(rect.origin, primaryScreenMaxY: primaryScreenMaxY)
        guard frameIndex(containing: point, frames: screenFrames) != nil else {
            print("Позиция каретки \(point) вне всех экранов — позиция невалидна")
            return nil
        }
        return point
    }
    
    /// Many apps report .success for kAXBoundsForRangeParameterizedAttribute
    /// with a degenerate rect when the real bounds are unknown: all zeros
    /// (Chrome/Electron, empty fields) or a zero-size rect pinned to a screen
    /// edge — Terminal.app returns x:0 y:<screen height> w:0 h:0, which maps
    /// exactly to the bottom-left corner. A real caret always has a line
    /// height (width may be 0 for a collapsed caret), so a rect without
    /// height is garbage regardless of its position.
    static func isValidCaretRect(_ rect: CGRect) -> Bool {
        rect.height > 0
    }
    
    /// Converts a point from AX API coordinate system (Quartz: origin at top-left of primary screen, Y increases downward)
    /// to Cocoa coordinate system (origin at bottom-left of primary screen, Y increases upward)
    static func convertAXPointToCocoa(_ axPoint: CGPoint) -> NSPoint {
        guard let primaryScreen = NSScreen.screens.first else {
            return NSPoint(x: axPoint.x, y: axPoint.y)
        }
        return convertAXPointToCocoa(axPoint, primaryScreenMaxY: primaryScreen.frame.maxY)
    }
    
    // Primary screen maxY represents the total height in Cocoa coordinates
    // AX Y=0 is at Cocoa Y=maxY, so we subtract axPoint.y from maxY
    static func convertAXPointToCocoa(_ axPoint: CGPoint, primaryScreenMaxY: CGFloat) -> NSPoint {
        NSPoint(x: axPoint.x, y: primaryScreenMaxY - axPoint.y)
    }
    
    /// Finds the screen that contains the given point (in Cocoa coordinates).
    /// Points lying exactly on a screen edge count as contained.
    static func screenContaining(point: NSPoint) -> NSScreen? {
        let screens = NSScreen.screens
        guard let index = frameIndex(containing: point, frames: screens.map { $0.frame }) else {
            return nil
        }
        return screens[index]
    }
    
    /// Index of the first frame containing the point, edges included
    /// (NSRect.contains excludes the top and right edges, which loses points
    /// sitting exactly on a screen border).
    static func frameIndex(containing point: NSPoint, frames: [CGRect]) -> Int? {
        frames.firstIndex { frame in
            point.x >= frame.minX && point.x <= frame.maxX &&
            point.y >= frame.minY && point.y <= frame.maxY
        }
    }
    
    static func getFocusedWindowScreen() -> NSScreen? {
        // Called on the main thread from presentWindow: without a timeout an
        // unresponsive app would freeze the UI for up to 6 seconds per call.
        let systemWideElement = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWideElement, axCallTimeoutSeconds)
        
        var focusedWindow: AnyObject?
        let result = AXUIElementCopyAttributeValue(systemWideElement,
                                                   kAXFocusedWindowAttribute as CFString,
                                                   &focusedWindow)
        
        guard result == .success else {
            print("Не удалось получить сфокусированное окно")
            return NSScreen.main
        }
        let windowElement = focusedWindow as! AXUIElement
        AXUIElementSetMessagingTimeout(windowElement, axCallTimeoutSeconds)
        
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
