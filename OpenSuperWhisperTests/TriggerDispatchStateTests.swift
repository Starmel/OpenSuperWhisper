import XCTest
@testable import OpenSuperWhisper

final class TriggerDispatchStateTests: XCTestCase {
    func testSingleKeyDownThenUp() {
        var s = TriggerDispatchState(monitored: [63])
        XCTAssertEqual(s.handle(.flagsChanged(keyCode: 63, pressed: true)), .fireDown)
        XCTAssertEqual(s.handle(.flagsChanged(keyCode: 63, pressed: false)), .fireUp)
    }

    func testUnmonitoredKeyIgnored() {
        var s = TriggerDispatchState(monitored: [63])
        XCTAssertEqual(s.handle(.flagsChanged(keyCode: 54, pressed: true)), .none)
        XCTAssertEqual(s.handle(.keyDown(99)), .none)
    }

    func testOverlappingTriggersFireOnceDownAndOnceUp() {
        var s = TriggerDispatchState(monitored: [63, 61])
        XCTAssertEqual(s.handle(.flagsChanged(keyCode: 63, pressed: true)), .fireDown) // first down fires
        XCTAssertEqual(s.handle(.flagsChanged(keyCode: 61, pressed: true)), .none)     // second held, no fire
        XCTAssertEqual(s.handle(.flagsChanged(keyCode: 63, pressed: false)), .none)    // one still held
        XCTAssertEqual(s.handle(.flagsChanged(keyCode: 61, pressed: false)), .fireUp)  // last release fires
    }

    func testRepeatedDownDoesNotRefire() {
        var s = TriggerDispatchState(monitored: [40])
        XCTAssertEqual(s.handle(.keyDown(40)), .fireDown)
        XCTAssertEqual(s.handle(.keyDown(40)), .none) // autorepeat
        XCTAssertEqual(s.handle(.keyUp(40)), .fireUp)
    }
}
