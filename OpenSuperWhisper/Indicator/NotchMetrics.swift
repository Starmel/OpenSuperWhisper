import AppKit

/// Notch geometry for the menu-bar indicator. On Macs with a notch it reports the physical
/// notch size (so the pill aligns with it); on Macs without one it reports a simulated size so
/// the same "notch" pill can be drawn. Mirrors the approach used by MewNotch / boring.notch.
enum NotchMetrics {
    static func hasNotch(_ screen: NSScreen) -> Bool {
        screen.safeAreaInsets.top > 0
    }

    /// Width/height of the physical notch, or a simulated size on Macs without one.
    static func notchSize(_ screen: NSScreen) -> CGSize {
        let menuBarHeight = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)

        if hasNotch(screen),
           let left = screen.auxiliaryTopLeftArea?.width,
           let right = screen.auxiliaryTopRightArea?.width {
            return CGSize(width: screen.frame.width - left - right, height: screen.safeAreaInsets.top)
        }

        // No physical notch: a sensible faux-notch pill the height of the menu bar.
        return CGSize(width: 190, height: menuBarHeight)
    }

    static var mainScreenNotchSize: CGSize {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return .zero }
        return notchSize(screen)
    }
}
