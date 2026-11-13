import XCTest
import AppKit
@testable import OpenSuperWhisper

@MainActor
final class ModifierReleaseTests: XCTestCase {
    func testReleasingBoundSideWhileOtherSideIsHeldEndsHold() async throws {
        let pairs: [(ModifierKey, ModifierKey)] = [(.leftCommand, .rightCommand), (.rightCommand, .leftCommand),
            (.leftShift, .rightShift), (.leftOption, .rightOption), (.leftControl, .rightControl)]
        for (bound, other) in pairs {
            let monitor = ModifierKeyMonitor(modifierKey: bound)
            let down = expectation(description: "down")
            let up = expectation(description: "up")
            monitor.onKeyDown = { down.fulfill() }
            monitor.onKeyUp = { up.fulfill() }
            func send(_ key: ModifierKey, _ flags: NSEvent.ModifierFlags) {
                monitor.handleFlagsChanged(keyCode: key.keyCode, flags: flags)
            }
            send(bound, [bound.modifierFlag])
            send(other, [bound.modifierFlag, other.modifierFlag])
            send(bound, [other.modifierFlag])
            send(other, [])
            await fulfillment(of: [down, up], timeout: 1)
        }
    }
}
