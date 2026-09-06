import XCTest
import Combine
@testable import OpenSuperWhisper

@MainActor
final class TriggerPermissionTests: XCTestCase {
    func testPermissionGrantAndRevocationReconfigureTriggerOnce() {
        let permissions = CurrentValueSubject<Int, Never>(0)
        let manager = ShortcutManager(registerShortcuts: false)
        var changes = 0
        manager.observeTriggerPermissions(permissions.eraseToAnyPublisher()) { changes += 1 }
        permissions.send(0)
        XCTAssertEqual(changes, 0)
        permissions.send(1)
        permissions.send(1)
        XCTAssertEqual(changes, 1)
        permissions.send(3)
        permissions.send(0)
        permissions.send(3)
        XCTAssertEqual(changes, 4)
    }
}
