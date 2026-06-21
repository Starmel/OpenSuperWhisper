import XCTest
import ApplicationServices
@testable import OpenSuperWhisper

/// Unit tests for the pure editability decision used by the "notify when no
/// paste target" feature. The AX I/O itself is environment-dependent and is
/// verified manually; this covers the decision logic, which is biased toward
/// `true` so the app never warns spuriously.
final class PasteTargetDetectionTests: XCTestCase {

    func testNoFocusedElementIsNotEditable() {
        XCTAssertFalse(
            FocusUtils.classifyEditability(hasFocusedElement: false, valueIsSettable: false, role: nil),
            "Nothing focused → paste has no target")
    }

    func testSettableValueIsEditable() {
        // A settable value wins even over a non-editable-looking role.
        XCTAssertTrue(
            FocusUtils.classifyEditability(hasFocusedElement: true, valueIsSettable: true,
                                           role: kAXButtonRole as String))
    }

    func testTextFieldRoleIsEditable() {
        XCTAssertTrue(
            FocusUtils.classifyEditability(hasFocusedElement: true, valueIsSettable: false,
                                           role: kAXTextFieldRole as String))
    }

    func testTextAreaRoleIsEditable() {
        XCTAssertTrue(
            FocusUtils.classifyEditability(hasFocusedElement: true, valueIsSettable: false,
                                           role: kAXTextAreaRole as String))
    }

    func testButtonRoleIsNotEditable() {
        XCTAssertFalse(
            FocusUtils.classifyEditability(hasFocusedElement: true, valueIsSettable: false,
                                           role: kAXButtonRole as String))
    }

    func testStaticTextRoleIsNotEditable() {
        XCTAssertFalse(
            FocusUtils.classifyEditability(hasFocusedElement: true, valueIsSettable: false,
                                           role: kAXStaticTextRole as String))
    }

    func testUnknownRoleDefaultsToEditable() {
        // Bias toward not warning when we can't be sure.
        XCTAssertTrue(
            FocusUtils.classifyEditability(hasFocusedElement: true, valueIsSettable: false,
                                           role: "AXSomeUnknownRole"))
    }

    func testNilRoleWithFocusDefaultsToEditable() {
        XCTAssertTrue(
            FocusUtils.classifyEditability(hasFocusedElement: true, valueIsSettable: false, role: nil))
    }
}
