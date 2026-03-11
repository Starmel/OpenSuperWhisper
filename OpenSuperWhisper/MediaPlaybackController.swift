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
    private let getIsPlaying: (@convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void)?

    private init() {
        guard let bundle = CFBundleCreate(
            kCFAllocatorDefault,
            NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
        ) else {
            sendCommand = nil
            getIsPlaying = nil
            return
        }

        if let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSendCommand" as CFString) {
            sendCommand = unsafeBitCast(ptr, to: (@convention(c) (UInt32, UnsafeRawPointer?) -> Bool).self)
        } else {
            sendCommand = nil
        }

        if let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying" as CFString) {
            getIsPlaying = unsafeBitCast(ptr, to: (@convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void).self)
        } else {
            getIsPlaying = nil
        }
    }

    /// Check if media is playing, then pause if so. The check runs on a
    /// background thread to avoid deadlocking the main run loop.
    @discardableResult
    func pauseMedia() -> Bool {
        guard let sendCommand = sendCommand else { return false }

        guard let getIsPlaying = getIsPlaying else {
            // No way to check — send pause anyway (safe, it's a no-op if nothing plays)
            didPauseMedia = sendCommand(Self.kMRPause, nil)
            return didPauseMedia
        }

        var wasPlaying = false
        let semaphore = DispatchSemaphore(value: 0)

        // Dispatch the check off the main thread so the callback can complete
        DispatchQueue.global(qos: .userInteractive).async {
            getIsPlaying(DispatchQueue.global()) { playing in
                wasPlaying = playing
                semaphore.signal()
            }
        }

        _ = semaphore.wait(timeout: .now() + 0.5)

        if wasPlaying {
            didPauseMedia = sendCommand(Self.kMRPause, nil)
        } else {
            didPauseMedia = false
        }
        return didPauseMedia
    }

    /// Send an explicit play command, but only if we previously paused.
    func resumeMedia() {
        guard didPauseMedia, let sendCommand = sendCommand else { return }
        _ = sendCommand(Self.kMRPlay, nil)
        didPauseMedia = false
    }
}
