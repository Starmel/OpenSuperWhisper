import XCTest
@testable import OpenSuperWhisper

final class SingleKeyMonitorTests: XCTestCase {
    private let quote = 39 // kVK_ANSI_Quote

    func testBoundKeyIsConsumedAndOtherKeysPassThrough() {
        let monitor = SingleKeyMonitor(keyCode: quote)
        XCTAssertFalse(monitor.handle(isDown: true, keyCode: 0, flags: [], isRepeat: false))
        XCTAssertTrue(monitor.handle(isDown: true, keyCode: quote, flags: [], isRepeat: false))
        XCTAssertTrue(monitor.handle(isDown: true, keyCode: quote, flags: [], isRepeat: true))
        XCTAssertTrue(monitor.handle(isDown: false, keyCode: quote, flags: [], isRepeat: false))
        XCTAssertFalse(monitor.handle(isDown: false, keyCode: quote, flags: [], isRepeat: false))
    }

    func testBoundKeyWithModifierStillTypes() {
        let monitor = SingleKeyMonitor(keyCode: quote)
        XCTAssertFalse(monitor.handle(isDown: true, keyCode: quote, flags: .maskShift, isRepeat: false))
        XCTAssertFalse(monitor.handle(isDown: false, keyCode: quote, flags: .maskShift, isRepeat: false))
        XCTAssertFalse(monitor.handle(isDown: true, keyCode: quote, flags: .maskCommand, isRepeat: false))
    }
}
