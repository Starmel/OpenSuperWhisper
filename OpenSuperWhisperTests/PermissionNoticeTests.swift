import XCTest
@testable import OpenSuperWhisper

/// The main window is never gated on a permission, so what a missing grant
/// costs is exactly this list: which inline notices are on screen. These are
/// the three states the captain's machine went through - a grant that is not in
/// place, a grant that has just landed, and the moment before the first TCC
/// check answers - and the regression they defend is a window that keeps
/// showing the notice after the switch was turned on.
final class PermissionNoticeTests: XCTestCase {
    func testNothingIsShownBeforeTheFirstCheckAnswers() {
        XCTAssertEqual(
            PermissionsManager.notices(
                hasChecked: false,
                microphoneGranted: false,
                accessibilityGranted: false),
            [],
            "a notice must not flash while the real status is still unknown")
    }

    func testTheMissingGrantIsReportedOnItsOwn() {
        XCTAssertEqual(
            PermissionsManager.notices(
                hasChecked: true,
                microphoneGranted: true,
                accessibilityGranted: false),
            [.accessibility])

        XCTAssertEqual(
            PermissionsManager.notices(
                hasChecked: true,
                microphoneGranted: false,
                accessibilityGranted: true),
            [.microphone])
    }

    func testBothMissingGrantsAreReportedAccessibilityFirst() {
        XCTAssertEqual(
            PermissionsManager.notices(
                hasChecked: true,
                microphoneGranted: false,
                accessibilityGranted: false),
            [.accessibility, .microphone])
    }

    func testTheNoticesClearThemselvesWhenTheGrantsLand() {
        XCTAssertEqual(
            PermissionsManager.notices(
                hasChecked: true,
                microphoneGranted: true,
                accessibilityGranted: true),
            [],
            "the Accessibility notice has to disappear on its own once the grant lands")
    }
}
