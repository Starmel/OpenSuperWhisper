import XCTest
@testable import OpenSuperWhisper

@MainActor
final class RecordingSessionTests: XCTestCase {
    func testAnotherTriggerStopsOriginalOwnerExactlyOnce() throws {
        let session = RecordingSessionController()
        var stops = 0
        let first = try XCTUnwrap(session.begin { stops += 1 })
        XCTAssertNil(session.begin { XCTFail("second owner") })
        session.requestStop()
        session.requestStop()
        XCTAssertEqual(stops, 1)
        XCTAssertNil(session.begin { XCTFail("start during decode") })
        session.finish(first)
        XCTAssertNotNil(session.begin {})
    }

    func testLateCompletionCannotReleaseNewRecording() throws {
        let session = RecordingSessionController()
        let old = try XCTUnwrap(session.begin {})
        session.finish(old)
        let new = try XCTUnwrap(session.begin {})
        session.finish(old)
        XCTAssertEqual(session.currentID, new)
        XCTAssertTrue(session.isCapturing)
    }
}
