import Foundation

/// Pauses/resumes system media playback via the private MediaRemote framework.
///
/// macOS lets a normal app *send* play/pause commands but not reliably *read* the Now
/// Playing state from inside the process, so we can't tell whether something was actually
/// playing. We therefore always pause on record and always resume on stop. The trade-off:
/// if media was already paused when you start recording, it will resume on stop — accepted.
final class MediaPlaybackController {
    static let shared = MediaPlaybackController()

    /// Whether we sent a pause this cycle, so `resumeMedia` only acts after `pauseMedia`.
    private(set) var didPauseMedia = false

    private static let kMRPlay: UInt32 = 0
    private static let kMRPause: UInt32 = 1

    private let sendCommand: (@convention(c) (UInt32, UnsafeRawPointer?) -> Bool)?

    private init() {
        guard
            let bundle = CFBundleCreate(
                kCFAllocatorDefault,
                NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
            ),
            let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSendCommand" as CFString)
        else {
            sendCommand = nil
            return
        }
        sendCommand = unsafeBitCast(ptr, to: (@convention(c) (UInt32, UnsafeRawPointer?) -> Bool).self)
    }

    /// Sends an explicit pause (a harmless no-op when nothing is playing).
    func pauseMedia() {
        guard let sendCommand = sendCommand else { return }
        didPauseMedia = sendCommand(Self.kMRPause, nil)
    }

    /// Sends play, but only if we previously paused this cycle.
    func resumeMedia() {
        guard didPauseMedia, let sendCommand = sendCommand else { return }
        _ = sendCommand(Self.kMRPlay, nil)
        didPauseMedia = false
    }
}
