import Foundation

/// Pauses whatever app is currently playing audio (music, video, browser) while
/// a recording is in progress, and resumes it afterwards.
///
/// The mechanism is player-agnostic and, crucially, uses *discrete* pause/play
/// commands rather than a play/pause toggle. macOS 15.4+ only lets Apple
/// platform binaries use the private MediaRemote framework, so we cannot call it
/// from our own process (an unentitled app gets empty/false state back). Instead
/// we shell out to `/usr/bin/perl` (a platform binary), which loads our small
/// `libOSWMediaHelper.dylib` into its entitled process via `osw-media-remote.pl`
/// and calls MediaRemote there. Both files are bundled with the app; the dylib
/// is never linked into it.
///
/// Why discrete matters: the previous implementation simulated the hardware
/// Play/Pause media *key*, which is a toggle, gated on a CoreAudio "output device
/// is running" check. Browsers keep that device running even while paused, so the
/// check false-positived and the toggle *started* paused audio on record-start.
/// A discrete `pause` is a no-op when nothing is playing, so it can never start
/// audio; a discrete `play` is only ever sent to resume media we ourselves paused.
///
/// Threading: every entry point hops onto this controller's own serial
/// `mediaQueue`. `didPauseMedia` and the lazily-resolved bundle paths are only
/// ever touched there, so no additional locking is needed, and the (subprocess)
/// work never runs on AudioRecorder's workQueue where it could delay capture.
final class MediaPlaybackController {
    static let shared = MediaPlaybackController()
    private init() {}

    /// Serial queue that owns all helper interaction and `didPauseMedia`.
    private let mediaQueue = DispatchQueue(label: "com.opensuperwhisper.mediaplayback")

    /// True only while a recording-triggered pause is in effect.
    private var didPauseMedia = false

    /// Hard cap on any single helper invocation so a wedged helper can never
    /// wedge `mediaQueue`. The helper's own MediaRemote waits are ~2 s; this is
    /// the outer bound including perl startup.
    private static let helperTimeout: TimeInterval = 5

    private let perlURL = URL(fileURLWithPath: "/usr/bin/perl")

    /// Bundled perl launcher; resolved lazily and only from `mediaQueue`.
    private lazy var scriptURL = Bundle.main.url(
        forResource: "osw-media-remote", withExtension: "pl"
    )

    /// Bundled helper dylib (in Contents/Frameworks); perl loads it, our app
    /// never links or loads it.
    private lazy var helperURL = Bundle.main.privateFrameworksURL?
        .appendingPathComponent("libOSWMediaHelper.dylib")

    // MARK: - Public API (called from AudioRecorder's workQueue)

    /// Pauses the current "Now Playing" app if the feature is enabled and audio
    /// is actually playing. Idempotent: a second call while already paused is a
    /// no-op, so the recorder's internal restart path never double-pauses.
    func pauseIfPlaying() {
        guard AppPreferences.shared.pauseMediaWhileRecording else { return }
        mediaQueue.async { [self] in
            guard !didPauseMedia else { return }
            // Only claim ownership (and thus later resume) if something is truly
            // playing. Sending pause itself is harmless when nothing plays, but
            // we must not resume media that the user had already paused.
            guard queryPlaying() else { return }
            runHelper("pause")
            didPauseMedia = true
            print("MediaPlaybackController: paused media for recording")
        }
    }

    /// Resumes playback only if this controller was the one that paused it.
    /// Safe to call unconditionally from every stop/cancel path. Intentionally
    /// does not check the preference: if the user toggled the feature off mid
    /// recording, we still owe them the resume of what we paused.
    func resumeIfPaused() {
        mediaQueue.async { [self] in
            guard didPauseMedia else { return }
            didPauseMedia = false
            runHelper("play")
            print("MediaPlaybackController: resumed media after recording")
        }
    }

    // MARK: - Helper

    /// Whether an app is currently playing, per the helper's `get`. Fails safe:
    /// any missing binary, error, timeout, or unexpected output yields `false`,
    /// so we never pause/resume on bad data.
    private func queryPlaying() -> Bool {
        guard let data = runHelper("get") else { return false }
        let output = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output == "true"
    }

    /// Runs `/usr/bin/perl <script> <helper-dylib> <command>` and returns stdout,
    /// or `nil` on any failure. Must be called on `mediaQueue`.
    ///
    /// We wait on process exit (with a timeout) *before* draining stdout. The
    /// helper's output is tiny (well under the pipe buffer), so the child always
    /// exits on its own; the timeout only guards a pathological hang.
    @discardableResult
    private func runHelper(_ command: String) -> Data? {
        guard let scriptURL, let helperURL else {
            print("MediaPlaybackController: helper not bundled")
            return nil
        }

        let process = Process()
        process.executableURL = perlURL
        process.arguments = [scriptURL.path, helperURL.path, command]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }

        do {
            try process.run()
        } catch {
            print("MediaPlaybackController: failed to launch perl: \(error)")
            return nil
        }

        if finished.wait(timeout: .now() + Self.helperTimeout) == .timedOut {
            process.terminate()
            print("MediaPlaybackController: helper timed out")
            return nil
        }

        guard process.terminationStatus == 0 else {
            print("MediaPlaybackController: helper exited \(process.terminationStatus)")
            return nil
        }

        return stdout.fileHandleForReading.readDataToEndOfFile()
    }
}
