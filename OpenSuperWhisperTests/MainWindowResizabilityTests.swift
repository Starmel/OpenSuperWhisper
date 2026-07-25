import AppKit
import XCTest
@testable import OpenSuperWhisper

@MainActor
final class MainWindowResizabilityTests: XCTestCase {

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 650),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
    }

    // The bug: maxSize.width was pinned to the same 450 as minSize.width, so
    // AppKit refused horizontal resizing no matter what SwiftUI declared.
    func testSizeLimits_allowHorizontalResizing() {
        let window = makeWindow()
        AppDelegate.applyMainWindowSizeLimits(to: window)

        XCTAssertGreaterThan(window.maxSize.width, window.minSize.width,
                             "Main window must be widenable: max width has to exceed min width")
    }

    func testSizeLimits_preserveMinimumWidth() {
        let window = makeWindow()
        AppDelegate.applyMainWindowSizeLimits(to: window)

        XCTAssertEqual(window.minSize.width, 450,
                       "Minimum width is existing behavior and must not change")
    }

    // The decisive bug: windowWillResize rewrote every proposed width to 450,
    // which overrides minSize/maxSize because AppKit consults the delegate on
    // each resize. Height passed through untouched, which is why the window
    // resized vertically but never horizontally.
    func testWindowWillResize_honorsProposedWidth() {
        let delegate = AppDelegate()
        let result = delegate.windowWillResize(makeWindow(), to: NSSize(width: 900, height: 650))

        XCTAssertEqual(result.width, 900,
                       "windowWillResize must not override the user's horizontal drag")
    }

    func testWindowWillResize_leavesHeightUntouched() {
        let delegate = AppDelegate()
        let result = delegate.windowWillResize(makeWindow(), to: NSSize(width: 900, height: 720))

        XCTAssertEqual(result.height, 720, "height handling is unchanged by this fix")
    }

    func testSizeLimits_preserveHeightRange() {
        let window = makeWindow()
        AppDelegate.applyMainWindowSizeLimits(to: window)

        XCTAssertEqual(window.minSize.height, 400)
        XCTAssertEqual(window.maxSize.height, 900,
                       "The height cap is existing intentional behavior; this change is width-only")
    }
}
