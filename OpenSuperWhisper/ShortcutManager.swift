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

    private init() {
        print("ShortcutManager init")
        
        var activeVm: IndicatorViewModel?

        KeyboardShortcuts.onKeyUp(for: .toggleRecord) {
            // Run on the main actor to safely interact with actor-isolated methods
            Task { @MainActor in
                if activeVm != nil {
                    IndicatorWindowManager.shared.stopRecording()
                    activeVm = nil
                } else {
                    let cursorPosition = FocusUtils.getCurrentCursorPosition()

                    let indicatorPoint: NSPoint?

                    if let carretPosition = FocusUtils.getCaretRect(), let screen = FocusUtils.getFocusedWindowScreen() {
                        
                        let screenHeight = screen.frame.height
                        indicatorPoint = NSPoint(x: carretPosition.origin.x, y: screenHeight - carretPosition.origin.y)
                    } else {
                        indicatorPoint = cursorPosition
                    }

                    let vm = IndicatorWindowManager.shared.show(nearPoint: indicatorPoint)
                    vm.startRecording()
                        
                    activeVm = vm
                }
            }
        }

        KeyboardShortcuts.onKeyUp(for: .escape) {
            // Run on the main actor to safely interact with actor-isolated methods
            Task { @MainActor in
                if activeVm != nil {
                    IndicatorWindowManager.shared.stopForce()
                    activeVm = nil
                }
            }
        }
        KeyboardShortcuts.disable(.escape)
    }

}