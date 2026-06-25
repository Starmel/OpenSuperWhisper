import XCTest
@testable import OpenSuperWhisper

/// The record-start path used to query the focused app's caret rect via the
/// Accessibility API on every key-down — a synchronous IPC that can hang the
/// main thread (and with it the global hotkey tap). The caret is only needed to
/// anchor the indicator in "cursor" mode; every other position uses screen
/// geometry. This guards that decision so the expensive AX call is skipped
/// everywhere it isn't used.
final class CaretAnchorDecisionTests: XCTestCase {

    func testCaretAnchorOnlyInCursorMode() {
        XCTAssertTrue(FocusUtils.shouldAnchorToCaret(indicatorPosition: "cursor"))
    }

    func testNoCaretAnchorInNotchMode() {
        XCTAssertFalse(FocusUtils.shouldAnchorToCaret(indicatorPosition: "notch"))
    }

    func testNoCaretAnchorInTopCenterBottomModes() {
        XCTAssertFalse(FocusUtils.shouldAnchorToCaret(indicatorPosition: "top"))
        XCTAssertFalse(FocusUtils.shouldAnchorToCaret(indicatorPosition: "center"))
        XCTAssertFalse(FocusUtils.shouldAnchorToCaret(indicatorPosition: "bottom"))
    }

    func testUnknownPositionDoesNotAnchor() {
        XCTAssertFalse(FocusUtils.shouldAnchorToCaret(indicatorPosition: "something-else"))
    }
}
