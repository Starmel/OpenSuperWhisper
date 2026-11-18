import XCTest
@testable import OpenSuperWhisper

/// The UID → `AudioDeviceID` lookup must not hand out `kAudioObjectUnknown` (0) as if
/// it were a device: writing 0 into the system default input is what left recording
/// pointed at nothing. Only lookups that cannot touch the real default input are used.
@MainActor
final class MicrophoneDeviceIDTests: XCTestCase {

    func testUnknownUIDIsNotADeviceAndZeroIsRejected() {
        let mics = MicrophoneService.shared
        let bogus = MicrophoneService.AudioDevice(
            id: "com.opensuperwhisper.tests.no-such-microphone-uid",
            name: "No Such Microphone",
            manufacturer: nil,
            isBuiltIn: false
        )

        XCTAssertNil(mics.getCoreAudioDeviceID(for: bogus),
                     "a UID with no device behind it must not resolve to a device id")
        XCTAssertFalse(mics.isValidInputDeviceID(0),
                       "0 is kAudioObjectUnknown, not a usable input device")
    }
}
