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
            
            print("Toggle record, active = \(activeVm)")
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

        KeyboardShortcuts.onKeyUp(for: .escape) {
            
            print("active \(activeVm)")
            if let vm = activeVm {
                
//                if vm.isRecording {
                IndicatorWindowManager.shared.stopForce()
                activeVm = nil

//                } else {
//                    IndicatorWindowManager.shared.stopRecording()
//                    activeVm = nil
//
//                }
            }
        }
    }

}

extension IndicatorWindowManager {
    func show(nearPoint point: NSPoint) -> IndicatorViewModel {
        // Create new view model
        let newViewModel = IndicatorViewModel()
        self.viewModel = newViewModel
        
        if self.window == nil {
            // Create window if it doesn't exist
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            
            window.level = .floating
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.ignoresMouseEvents = true
            
            self.window = window
        }
        
        // Position window near cursor
        if let window = self.window, let screen = NSScreen.main {
            let windowFrame = window.frame
            let screenFrame = screen.frame
            
            // Try to position above cursor
            var x = point.x - windowFrame.width / 2
            var y = point.y + 10 // 20 points above cursor
            
            // Adjust if out of screen bounds
            x = max(screenFrame.minX, min(x, screenFrame.maxX - windowFrame.width))
            y = max(screenFrame.minY, min(y, screenFrame.maxY - windowFrame.height))
            
            window.setFrameOrigin(NSPoint(x: x, y: y))
            
            // Set content view
            let hostingView = NSHostingView(rootView: IndicatorWindow(viewModel: newViewModel))
            window.contentView = hostingView
        }
        
        self.window?.orderFront(nil)
        return newViewModel
    }
}
