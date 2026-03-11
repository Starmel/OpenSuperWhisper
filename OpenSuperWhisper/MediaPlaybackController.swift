import Foundation

/// Controls system media playback via the MediaRemote framework.
/// Sends explicit pause/play commands (not toggles), so pause is safe
/// to call even when nothing is playing.
final class MediaPlaybackController {
    static let shared = MediaPlaybackController()

    /// Tracks whether we paused media so we only resume what we paused.
    private(set) var didPauseMedia = false

    private static let kMRPlay: UInt32 = 0
    private static let kMRPause: UInt32 = 1

    private let sendCommand: (@convention(c) (UInt32, UnsafeRawPointer?) -> Bool)?

    private init() {
        guard let bundle = CFBundleCreate(
            kCFAllocatorDefault,
            NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
        ), let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSendCommand" as CFString) else {
            sendCommand = nil
            return
        }
        sendCommand = unsafeBitCast(ptr, to: (@convention(c) (UInt32, UnsafeRawPointer?) -> Bool).self)
    }

    /// Send an explicit pause command. Safe to call when nothing is playing.
    @discardableResult
    func pauseMedia() -> Bool {
        guard let sendCommand = sendCommand else { return false }
        didPauseMedia = sendCommand(Self.kMRPause, nil)
        return didPauseMedia
    }

    /// Send an explicit play command, but only if we previously paused.
    func resumeMedia() {
        guard didPauseMedia, let sendCommand = sendCommand else { return }
        _ = sendCommand(Self.kMRPlay, nil)
        didPauseMedia = false
    }
}
