import AppKit
import CoreGraphics

/// Controls system media playback by simulating media key events.
/// Works with any media player (Feisch, Spotify, Apple Music, etc.)
/// by sending system-level play/pause key events.
final class MediaPlaybackController {
    static let shared = MediaPlaybackController()

    /// Tracks whether we paused media so we only resume what we paused.
    private(set) var didPauseMedia = false

    private init() {}

    // MARK: - NX_KEYTYPE constants from IOKit/hidsystem
    private static let NX_KEYTYPE_PLAY: UInt32 = 16

    /// Pause currently playing media. Only sends a play/pause key if there
    /// is an active "Now Playing" app, so we don't accidentally start playback.
    func pauseMedia() {
        guard isMediaCurrentlyPlaying() else {
            didPauseMedia = false
            return
        }
        sendMediaKey(Self.NX_KEYTYPE_PLAY)
        didPauseMedia = true
    }

    /// Resume media playback, but only if we previously paused it.
    func resumeMedia() {
        guard didPauseMedia else { return }
        sendMediaKey(Self.NX_KEYTYPE_PLAY)
        didPauseMedia = false
    }

    /// Toggle play/pause regardless of state tracking.
    func togglePlayPause() {
        sendMediaKey(Self.NX_KEYTYPE_PLAY)
    }

    // MARK: - Private

    /// Check if any app is currently playing media via the system Now Playing info.
    private func isMediaCurrentlyPlaying() -> Bool {
        // Use MRMediaRemoteGetNowPlayingInfo via the private MediaRemote framework
        // to detect if media is playing. Falls back to assuming media is playing
        // if the check is unavailable, to avoid missing a pause.
        guard let bundle = CFBundleCreate(
            kCFAllocatorDefault,
            NSURL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework")
        ) else {
            return true // Conservative: assume playing if we can't check
        }

        // MRMediaRemoteGetNowPlayingApplicationIsPlaying
        guard let pointer = CFBundleGetFunctionPointerForName(
            bundle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying" as CFString
        ) else {
            return true
        }

        typealias MRIsPlayingFunc = @convention(c) (DispatchQueue, @escaping (Bool) -> Void) -> Void
        let isPlayingFunc = unsafeBitCast(pointer, to: MRIsPlayingFunc.self)

        var isPlaying = false
        let semaphore = DispatchSemaphore(value: 0)

        isPlayingFunc(DispatchQueue.global()) { playing in
            isPlaying = playing
            semaphore.signal()
        }

        // Wait briefly — this should return almost immediately
        _ = semaphore.wait(timeout: .now() + 0.1)
        return isPlaying
    }

    /// Send a system-defined media key event (key down + key up).
    private func sendMediaKey(_ key: UInt32) {
        func postKeyEvent(down: Bool) {
            let flags: UInt32 = down ? 0x0a00 : 0x0b00
            let data1 = Int((key << 16) | UInt32(flags))

            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            )

            event?.cgEvent?.post(tap: .cghidEventTap)
        }

        postKeyEvent(down: true)
        postKeyEvent(down: false)
    }
}
