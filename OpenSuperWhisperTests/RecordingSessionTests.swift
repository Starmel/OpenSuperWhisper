import XCTest
@testable import OpenSuperWhisper

private final class FakeOutputVolumeController: OutputVolumeControlling {
    private(set) var muteCount = 0
    private(set) var restoreCount = 0

    func mute() { muteCount += 1 }
    func restore() { restoreCount += 1 }
}

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

    func testMutesOnBeginAndRestoresOnFinishWhenEnabled() throws {
        let volume = FakeOutputVolumeController()
        let session = RecordingSessionController(volumeController: volume, shouldMute: { true })

        let id = try XCTUnwrap(session.begin {})
        XCTAssertEqual(volume.muteCount, 1)
        XCTAssertEqual(volume.restoreCount, 0)

        session.finish(id)
        XCTAssertEqual(volume.restoreCount, 1)
    }

    func testDoesNotMuteWhenDisabled() throws {
        let volume = FakeOutputVolumeController()
        let session = RecordingSessionController(volumeController: volume, shouldMute: { false })

        let id = try XCTUnwrap(session.begin {})
        session.finish(id)

        XCTAssertEqual(volume.muteCount, 0)
        // Restoring an unmuted session is a no-op on the real controller, so it
        // is still safe to run unconditionally.
        XCTAssertEqual(volume.restoreCount, 1)
    }

    func testStaysMutedWhileDecodingAndRestoresOnlyWhenSessionFinishes() throws {
        let volume = FakeOutputVolumeController()
        let session = RecordingSessionController(volumeController: volume, shouldMute: { true })

        let id = try XCTUnwrap(session.begin {})
        session.requestStop()

        XCTAssertEqual(volume.restoreCount, 0, "Unmuting here would let playback leak back in during transcription")

        session.finish(id)
        XCTAssertEqual(volume.restoreCount, 1)
    }

    func testStaleFinishDoesNotUnmuteAnActiveSession() throws {
        let volume = FakeOutputVolumeController()
        let session = RecordingSessionController(volumeController: volume, shouldMute: { true })

        let old = try XCTUnwrap(session.begin {})
        session.finish(old)
        try XCTUnwrap(session.begin {})

        session.finish(old)

        XCTAssertEqual(volume.restoreCount, 1, "The new session muted again and must stay muted")
    }

    func testRejectedBeginDoesNotMuteTwice() throws {
        let volume = FakeOutputVolumeController()
        let session = RecordingSessionController(volumeController: volume, shouldMute: { true })

        try XCTUnwrap(session.begin {})
        XCTAssertNil(session.begin {})

        XCTAssertEqual(volume.muteCount, 1)
    }

    func testFinishWithNilOrUnknownIDDoesNotRestore() throws {
        let volume = FakeOutputVolumeController()
        let session = RecordingSessionController(volumeController: volume, shouldMute: { true })

        try XCTUnwrap(session.begin {})

        session.finish(nil)
        session.finish(UUID())

        XCTAssertEqual(volume.restoreCount, 0)
    }
}
