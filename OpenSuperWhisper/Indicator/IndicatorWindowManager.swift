import AppKit
import KeyboardShortcuts
import SwiftUI

@MainActor
class IndicatorWindowManager: IndicatorViewDelegate {
    static let shared = IndicatorWindowManager()
    
    var window: NSWindow?
    var viewModel: IndicatorViewModel?

    // The window auto-sizes to its content (so the live caption pill grows with the text).
    // We keep the bottom edge anchored near the caret so it grows upward, not over the caret.
    private var anchorBottomY: CGFloat = 0
    private var anchorCenterX: CGFloat = 0
    // Notch mode anchors the *top* edge instead (the pill hangs from the screen top, growing down).
    private var anchorFromTop = false
    private var anchorTopY: CGFloat = 0
    private var resizeObserver: NSObjectProtocol?

    private init() {}
    
    func show(nearPoint point: NSPoint? = nil) -> IndicatorViewModel {
        
        KeyboardShortcuts.enable(.escape)
        
        // Create new view model
        let newViewModel = IndicatorViewModel()
        newViewModel.delegate = self
        viewModel = newViewModel
        
        if window == nil {
            // Create window if it doesn't exist - using NSPanel for full-screen compatibility
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            
            panel.isFloatingPanel = true
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.hidesOnDeactivate = false
            
            self.window = panel
        }
        
        // Host with a controller that resizes the window to fit the SwiftUI content.
        let hostingController = NSHostingController(rootView: IndicatorWindow(viewModel: newViewModel))
        hostingController.sizingOptions = [.preferredContentSize]
        window?.contentViewController = hostingController

        // Position window - use the screen containing the point, or main screen as fallback
        let targetScreen = point.flatMap { FocusUtils.screenContaining(point: $0) } ?? NSScreen.main
        if let window = window, let screen = targetScreen {
            let screenFrame = screen.frame

            anchorFromTop = false
            switch AppPreferences.shared.indicatorPosition {
            case "notch":
                // Hang from the very top-center, growing downward — sitting in/around the notch
                // on notched Macs, or as a faux-notch pill on Macs without one.
                anchorFromTop = true
                anchorCenterX = screenFrame.midX
                anchorTopY = screenFrame.maxY
            case "top":
                anchorCenterX = screenFrame.midX
                anchorBottomY = screenFrame.maxY - 140
            case "center":
                anchorCenterX = screenFrame.midX
                anchorBottomY = screenFrame.midY
            case "bottom":
                anchorCenterX = screenFrame.midX
                anchorBottomY = screenFrame.minY + 120
            default: // "cursor": sit just above the caret, falling back to a band near the top
                if let point = point {
                    anchorBottomY = point.y + 20
                    anchorCenterX = point.x
                } else {
                    anchorBottomY = screenFrame.maxY - 260
                    anchorCenterX = screenFrame.midX
                }
            }

            reposition(window: window, screen: screen)

            // Keep the bottom edge anchored as the content (and window) grows upward.
            if resizeObserver == nil {
                resizeObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.didResizeNotification, object: window, queue: .main
                ) { [weak self, weak window] _ in
                    guard let self, let window, let screen = window.screen ?? NSScreen.main else { return }
                    self.reposition(window: window, screen: screen)
                }
            }
        }

        // Notch mode must draw *over* the menu bar (which sits above the normal floating level),
        // otherwise the menu bar clips the top of the pill and it looks like it's hanging too low.
        // Same recipe the MewNotch / boring.notch projects use.
        if anchorFromTop {
            window?.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
            window?.collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
        } else {
            // .fullScreenAuxiliary lets the indicator appear over apps in full-screen spaces;
            // without it the recording dialog is invisible there (#52). statusBar level keeps it
            // above the full-screen app's content.
            window?.level = .statusBar
            window?.collectionBehavior = [.fullScreenAuxiliary, .stationary, .canJoinAllSpaces, .ignoresCycle]
        }

        window?.orderFront(nil)
        return newViewModel
    }

    private func reposition(window: NSWindow, screen: NSScreen) {
        let w = window.frame.width
        let h = window.frame.height
        let screenFrame = screen.frame
        let x = max(screenFrame.minX, min(anchorCenterX - w / 2, screenFrame.maxX - w))
        // Notch mode pins the top edge (grows down); everything else pins the bottom (grows up).
        let y = anchorFromTop
            ? max(screenFrame.minY, anchorTopY - h)
            : max(screenFrame.minY, min(anchorBottomY, screenFrame.maxY - h))
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }

    /// Briefly shows the indicator at the configured position (without recording) so the user
    /// can see where it will appear. Used by the position picker's "Preview" button.
    func preview() {
        guard viewModel == nil else { return } // don't interfere with a live recording
        let vm = show(nearPoint: FocusUtils.getCurrentCursorPosition())
        vm.state = .recording
        vm.isBlinking = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.hide()
        }
    }

    func stopRecording() {
        viewModel?.startDecoding()
    }
    
    func stopForce() {
        viewModel?.cancelRecording()
        viewModel?.cleanup()
        hide()
    }

    func hide() {
        KeyboardShortcuts.disable(.escape)
        
        Task {
            guard let viewModel = self.viewModel else { return }
            
            await viewModel.hideWithAnimation()
            viewModel.cleanup()
            
            self.window?.contentView = nil
            self.window?.orderOut(nil)
            self.viewModel = nil
            
            NotificationCenter.default.post(name: .indicatorWindowDidHide, object: nil)
        }
    }
    
    func didFinishDecoding() {
        hide()
    }
}
