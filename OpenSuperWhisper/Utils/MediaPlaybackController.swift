import Cocoa
import CoreAudio

/// Pauses whatever app is currently playing audio (music, video, browser) while
/// a recording is in progress, and resumes it afterwards.
///
/// The mechanism is intentionally player-agnostic: it simulates the hardware
/// media Play/Pause key, which the system routes to the current "Now Playing"
/// app. This works with Spotify, Apple Music, Safari/Chrome video, etc. without
/// any per-app scripting or extra permissions - the Accessibility permission
/// already granted for global hotkeys and paste covers posting the event, and
/// the app is not sandboxed.
///
/// The media key is a *toggle*, so we only pause when something is actually
/// playing (detected via CoreAudio) and only resume when we were the one who
/// paused it. That prevents a stray key press from starting music that was not
/// playing to begin with.
///
/// Threading: every entry point is invoked from AudioRecorder's serial
/// workQueue, so `didPauseMedia` is only ever touched from that one queue and
/// needs no additional locking.
final class MediaPlaybackController {
    static let shared = MediaPlaybackController()
    private init() {}

    /// True only while a recording-triggered pause is in effect.
    private var didPauseMedia = false

    /// NX_KEYTYPE_PLAY - the Play/Pause media key.
    private static let playPauseKey: Int32 = 16

    /// Pauses the current "Now Playing" app if the feature is enabled and audio
    /// is actually playing. Idempotent: a second call while already paused is a
    /// no-op, so the recorder's internal restart path never double-toggles.
    func pauseIfPlaying() {
        guard AppPreferences.shared.pauseMediaWhileRecording else { return }
        guard !didPauseMedia else { return }
        guard isSystemAudioPlaying() else { return }

        sendMediaPlayPauseKey()
        didPauseMedia = true
        print("MediaPlaybackController: paused media for recording")
    }

    /// Resumes playback only if this controller was the one that paused it.
    /// Safe to call unconditionally from every stop/cancel path.
    func resumeIfPaused() {
        guard didPauseMedia else { return }
        didPauseMedia = false

        sendMediaPlayPauseKey()
        print("MediaPlaybackController: resumed media after recording")
    }

    // MARK: - Playback detection

    /// Whether the default output device is currently in use by any process.
    /// Mirrors the CoreAudio property-query idiom used in MicrophoneService.
    private func isSystemAudioPlaying() -> Bool {
        guard let outputDeviceID = defaultOutputDeviceID() else { return false }

        var isRunning: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            outputDeviceID, &address, 0, nil, &propertySize, &isRunning
        )
        guard status == noErr else { return false }
        return isRunning != 0
    }

    private func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize, &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    // MARK: - Media key

    /// Posts a full press (down + up) of the Play/Pause media key. The system
    /// routes it to the current "Now Playing" app, toggling its playback.
    private func sendMediaPlayPauseKey() {
        postMediaKeyEvent(keyDown: true)
        postMediaKeyEvent(keyDown: false)
    }

    private func postMediaKeyEvent(keyDown: Bool) {
        // systemDefined media-key events pack the key code and up/down state
        // into data1; the flags field carries the same state in its high bits.
        let flags: NSEvent.ModifierFlags = keyDown
            ? NSEvent.ModifierFlags(rawValue: 0xa00)
            : NSEvent.ModifierFlags(rawValue: 0xb00)
        let state = keyDown ? 0xa : 0xb
        let data1 = (Int(Self.playPauseKey) << 16) | (state << 8)

        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        ) else { return }

        event.cgEvent?.post(tap: .cghidEventTap)
    }
}
