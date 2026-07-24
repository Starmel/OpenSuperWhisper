import XCTest
@testable import OpenSuperWhisper

final class TranscriptionInserterActionTests: XCTestCase {

    func testAction_autoPasteAndAutoCopy_pastesKeepingClipboard() {
        XCTAssertEqual(
            TranscriptionInserter.action(autoPaste: true, autoCopy: true, forcePaste: false),
            .pasteKeepingClipboard)
    }

    func testAction_autoPasteOnly_pastesRestoringClipboard() {
        XCTAssertEqual(
            TranscriptionInserter.action(autoPaste: true, autoCopy: false, forcePaste: false),
            .pasteRestoringClipboard)
    }

    func testAction_autoCopyOnly_copiesWithoutPasting() {
        XCTAssertEqual(
            TranscriptionInserter.action(autoPaste: false, autoCopy: true, forcePaste: false),
            .copyOnly)
    }

    func testAction_neitherEnabled_doesNothing() {
        XCTAssertEqual(
            TranscriptionInserter.action(autoPaste: false, autoCopy: false, forcePaste: false),
            .doNothing)
    }

    // forcePaste is the hotkey's contract: an explicit request always pastes,
    // even for a user who has turned automatic pasting off.
    func testAction_forcePaste_overridesDisabledAutoPaste() {
        XCTAssertEqual(
            TranscriptionInserter.action(autoPaste: false, autoCopy: false, forcePaste: true),
            .pasteRestoringClipboard)
    }

    func testAction_forcePaste_respectsKeepInClipboard() {
        XCTAssertEqual(
            TranscriptionInserter.action(autoPaste: false, autoCopy: true, forcePaste: true),
            .pasteKeepingClipboard)
    }

    func testAction_forcePaste_withAutoPasteAlreadyOn_isUnchanged() {
        XCTAssertEqual(
            TranscriptionInserter.action(autoPaste: true, autoCopy: false, forcePaste: true),
            .pasteRestoringClipboard)
    }
}
