import AppKit
import KeyboardShortcuts
import QuartzCore
import SwiftUI

@MainActor
class IndicatorWindowManager: IndicatorViewDelegate {
    static let shared = IndicatorWindowManager()
    
    var window: NSWindow?
    var viewModel: IndicatorViewModel?
    
    private init() {}
    
    /// Creates the view model without presenting the window, so recording can
    /// start immediately while the caret position is being resolved.
    func prepare() -> IndicatorViewModel {
        NotificationCenter.default.post(name: .indicatorWindowWillShow, object: nil)
        KeyboardShortcuts.enable(.escape)
        
        let newViewModel = IndicatorViewModel()
        newViewModel.delegate = self
        viewModel = newViewModel
        
        // Build the panel and the SwiftUI hierarchy now, while the caret
        // position is being resolved in the background: materializing the
        // backing store, blur material and first layout during the appear
        // animation drops its first frames.
        ensureWindowContent(for: newViewModel)
        return newViewModel
    }
    
    func presentWindow(for presentedViewModel: IndicatorViewModel, nearPoint point: NSPoint?) {
        // The recording may already be cancelled/hidden by the time the caret
        // position is resolved.
        guard viewModel === presentedViewModel else { return }
        
        // Prefer the screen containing the point, then the screen of the window
        // with input focus (NSScreen.main is useless for a background app — it
        // degenerates to the primary screen). A point outside every screen
        // cannot be trusted for positioning and is ignored.
        let pointScreen = point.flatMap { FocusUtils.screenContaining(point: $0) }
        let targetScreen = pointScreen ?? FocusUtils.getFocusedWindowScreen() ?? NSScreen.screens.first
        let anchorPoint = pointScreen != nil ? point : nil
        
        // Never show the window without positioning it: an unpositioned panel
        // appears at its default origin (0,0) — the bottom-left corner.
        guard let screen = targetScreen else { return }
        
        // Normally prepared in prepare(); recreate only if hide() tore it down.
        if window?.contentView == nil {
            ensureWindowContent(for: presentedViewModel)
        }
        guard let window = window else { return }
        
        let windowFrame = window.frame
        let screenFrame = screen.frame
        
        // The card is centered inside a larger panel (margins for the appear
        // offset and shadow), so position the visible card, not the window.
        let cardBottomInset = (windowFrame.height - IndicatorWindow.cardSize.height) / 2
        
        var x: CGFloat
        var y: CGFloat
        
        if let point = anchorPoint {
            // Card bottom 20 points above cursor
            x = point.x - windowFrame.width / 2
            y = point.y + 20 - cardBottomInset
        } else {
            // Default: card top 100 points from the top center of screen
            x = screenFrame.midX - windowFrame.width / 2
            y = screenFrame.maxY - 100 - windowFrame.height + cardBottomInset
        }
        
        // Adjust if out of screen bounds
        x = max(screenFrame.minX, min(x, screenFrame.maxX - windowFrame.width))
        y = max(screenFrame.minY, min(y, screenFrame.maxY - windowFrame.height))
        
        window.setFrameOrigin(NSPoint(x: x, y: y))
        
        // The first committed frame must be fully transparent, otherwise the
        // card flashes at full size before the appear animation starts.
        if let layer = window.contentView?.layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.removeAllAnimations()
            layer.opacity = 0
            CATransaction.commit()
        }
        
        window.orderFront(nil)
        
        // Start the appear animation one runloop turn after the first
        // (fully transparent) frame is committed: springing a layer tree
        // that is still being built drops the opening frames.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.viewModel === presentedViewModel else { return }
            self.animateAppear()
        }
    }
    
    // MARK: - Layer animations
    
    // The appear/hide springs run on the hosting view's layer via Core
    // Animation, not via SwiftUI value animation: SwiftUI re-rasterizes the
    // card (material + gradients + shadow) on the CPU for every frame of an
    // animated scaleEffect and blocks the main thread in
    // CABackingStoreUpdate/wait_for_synchronize. A CASpringAnimation on the
    // layer transform scales the already-drawn texture in the render server.
    
    /// Matches SwiftUI .spring(response: 0.3, dampingFraction: 0.7).
    private static func springAnimation(keyPath: String, from: Any?, to: Any?) -> CASpringAnimation {
        let spring = CASpringAnimation(keyPath: keyPath)
        spring.mass = 1
        spring.stiffness = pow(2 * .pi / 0.3, 2)
        spring.damping = 0.7 * 2 * sqrt(spring.stiffness)
        spring.duration = spring.settlingDuration
        spring.fromValue = from
        spring.toValue = to
        return spring
    }
    
    /// Scaled down around the card center and pushed down towards the caret,
    /// so the appear animation rises bottom-up — the same start/end state the
    /// SwiftUI animation used. The layer transform works in Core Animation
    /// coordinates, which on macOS have +y pointing up regardless of the
    /// view's flippedness, so "down" is a negative y translation.
    static func hiddenTransform(for view: NSView) -> CATransform3D {
        let bounds = view.bounds
        let scale = IndicatorWindow.appearInitialScale
        var transform = CATransform3DMakeTranslation(bounds.midX, bounds.midY, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        transform = CATransform3DTranslate(transform, -bounds.midX, -bounds.midY, 0)
        return CATransform3DConcat(
            transform,
            CATransform3DMakeTranslation(0, -IndicatorWindow.appearOffset, 0)
        )
    }
    
    private func animateAppear() {
        guard let view = window?.contentView, let layer = view.layer else { return }
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAllAnimations()
        layer.transform = CATransform3DIdentity
        layer.opacity = 1
        layer.add(
            Self.springAnimation(keyPath: "transform", from: Self.hiddenTransform(for: view), to: CATransform3DIdentity),
            forKey: "transform"
        )
        layer.add(Self.springAnimation(keyPath: "opacity", from: 0, to: 1), forKey: "opacity")
        CATransaction.commit()
    }
    
    private func animateHide() async {
        guard let view = window?.contentView, let layer = view.layer, layer.opacity > 0 else { return }
        
        let hidden = Self.hiddenTransform(for: view)
        // Start from the interrupted mid-flight state if the appear spring is
        // still running.
        let currentTransform = layer.presentation()?.transform ?? layer.transform
        let currentOpacity = layer.presentation()?.opacity ?? layer.opacity
        
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            CATransaction.setCompletionBlock { continuation.resume() }
            layer.removeAllAnimations()
            layer.transform = hidden
            layer.opacity = 0
            layer.add(
                Self.springAnimation(keyPath: "transform", from: currentTransform, to: hidden),
                forKey: "transform"
            )
            layer.add(Self.springAnimation(keyPath: "opacity", from: currentOpacity, to: 0), forKey: "opacity")
            CATransaction.commit()
        }
    }
    
    /// Pre-creates the panel and orders it on screen once (fully transparent),
    /// so the first real appearance doesn't pay ~40 ms for window, backing
    /// store and blur material creation in the middle of the animation.
    func warmUp() {
        guard window == nil else { return }
        ensureWindowContent(for: IndicatorViewModel())
        guard let window = window else { return }
        
        window.alphaValue = 0
        window.orderFront(nil)
        DispatchQueue.main.async {
            window.orderOut(nil)
            window.alphaValue = 1
        }
    }
    
    /// Builds the panel and its SwiftUI hierarchy without showing anything,
    /// so the expensive first layout is done before the appear animation.
    private func ensureWindowContent(for presentedViewModel: IndicatorViewModel) {
        if window == nil {
            // Using NSPanel for full-screen compatibility
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: IndicatorWindow.windowSize),
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
        
        guard let window = window else { return }
        // Reuse the hosting view across sessions: rebuilding the SwiftUI
        // hierarchy (with its blur material) on every recording is wasted work.
        if let hostingView = window.contentView as? NSHostingView<IndicatorWindow> {
            hostingView.rootView = IndicatorWindow(viewModel: presentedViewModel)
        } else {
            let hostingView = NSHostingView(rootView: IndicatorWindow(viewModel: presentedViewModel))
            // Never let SwiftUI's ideal size drive the window frame: with the
            // default sizingOptions the hosting view shrinks the panel down to
            // the card size, and the window bounds then clip the animation —
            // the downward offset, the spring bounce overshoot and the shadow.
            hostingView.sizingOptions = []
            // The appear/hide springs animate this view's layer directly.
            hostingView.wantsLayer = true
            window.contentView = hostingView
        }
        window.setContentSize(IndicatorWindow.windowSize)
        window.contentView?.layoutSubtreeIfNeeded()
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
        // Capture the session being hidden: a new recording may start while
        // the hide animation runs, and tearing the window down then would
        // kill the fresh session's indicator.
        let hidingViewModel = viewModel
        
        Task {
            guard let viewModel = hidingViewModel, viewModel === self.viewModel else { return }
            
            await animateHide()
            viewModel.cleanup()
            
            guard self.viewModel === viewModel else { return }
            
            // Disabling the hotkey does synchronous WindowServer calls (up to
            // ~100 ms of SLSRemoveHotKey/SLSGetSymbolicHotKeyValue in traces),
            // so it must not run while the hide animation frames are drawn.
            // If a new session started during the animation, the guard above
            // already returned and the shortcut stays enabled for it.
            KeyboardShortcuts.disable(.escape)
            
            // The content view is kept alive and reused by the next session.
            self.window?.orderOut(nil)
            self.viewModel = nil
            
            NotificationCenter.default.post(name: .indicatorWindowDidHide, object: nil)
        }
    }
    
    func didFinishDecoding() {
        hide()
    }
}
