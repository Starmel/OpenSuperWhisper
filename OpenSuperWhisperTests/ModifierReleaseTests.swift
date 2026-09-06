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
            func send(_ key: ModifierKey, _ flags: CGEventFlags) throws {
                let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: key.keyCode, keyDown: true))
                event.type = .flagsChanged
                event.flags = flags
                monitor.handleFlagsChanged(event: event)
            }
            try send(bound, [bound.cgEventFlag, bound.physicalEventFlag])
            try send(other, [bound.cgEventFlag, bound.physicalEventFlag, other.physicalEventFlag])
            try send(bound, [other.cgEventFlag, other.physicalEventFlag])
            try send(other, [])
            await fulfillment(of: [down, up], timeout: 1)
        }
    }
}
