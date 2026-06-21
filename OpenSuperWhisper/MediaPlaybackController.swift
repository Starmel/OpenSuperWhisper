import Foundation

/// Controls system media playback via the private MediaRemote framework.
/// Sends explicit play/pause commands (not toggles), so pause is safe to call
/// even when nothing is playing.
final class MediaPlaybackController {
    static let shared = MediaPlaybackController()

    /// Tracks whether we sent a pause, so `resumeMedia` only resumes on stop.
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

    /// Pauses whatever the system "Now Playing" is.
    ///
    /// We send the explicit pause **unconditionally** — deliberately NOT probing
    /// "is something playing?" first. At the moment recording starts, the audio-session
    /// setup (switching the default input + starting `AVAudioRecorder`) transiently
    /// clears the system Now Playing `playing` flag, so a probe here falsely reports
    /// not-playing and the pause gets skipped (observed on macOS 27). The pause command
    /// is a harmless no-op when nothing is playing, so sending it unconditionally is
    /// both correct and reliable.
    func pauseMedia() {
        guard let sendCommand = sendCommand else { return }
        didPauseMedia = sendCommand(Self.kMRPause, nil)
    }

    /// Resumes playback, but only if we previously sent a pause.
    func resumeMedia() {
        guard didPauseMedia, let sendCommand = sendCommand else { return }
        _ = sendCommand(Self.kMRPlay, nil)
        didPauseMedia = false
    }
}
