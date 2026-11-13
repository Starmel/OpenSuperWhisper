import XCTest

@testable import OpenSuperWhisper

/// The speech-only pre-filter is off by default and its switch reaches the
/// decoder's parameters.
///
/// The measurement that decided that default is **not** asserted here and cannot
/// be: it lives on the captain's own recordings, which are decoded outside the
/// test suite, and CI has no audio to re-verify it with. The numbers and the
/// reason are in `AppPreferences.useVAD` and `WhisperVadParams`; what the suite
/// can hold is the wiring those numbers depend on — a fresh install must not run
/// the pre-filter, and the switch must actually reach the parameters it is
/// supposed to change.
@MainActor
final class WhisperVadExposureTests: XCTestCase {

    private var savedUseVAD: Bool!

    override func setUp() {
        super.setUp()
        savedUseVAD = AppPreferences.shared.useVAD
    }

    override func tearDown() {
        AppPreferences.shared.useVAD = savedUseVAD
        super.tearDown()
    }

    private func params() -> WhisperFullParams {
        WhisperEngine.makeFullParams(settings: Settings(), nThreads: 4,
                                     modelTextContext: 448, initialPromptTokenCount: 0)
    }

    /// The state a fresh install ships in. The stored preference is removed
    /// first, so what this reads is the wrapper's fallback and not something an
    /// earlier test wrote.
    func testAFreshInstallDoesNotRunThePreFilter() {
        AppPreferences.defaults.removeObject(forKey: "useVAD")
        XCTAssertFalse(AppPreferences.shared.useVAD,
                       "a fresh install must not pay for the pre-filter that drops quiet speech")
        XCTAssertFalse(Settings().useVAD, "the per-dictation settings read that default")
        XCTAssertFalse(params().vad, "…and the decoder's parameters carry it")
    }

    /// The switch has to change the thing it names, in both directions:
    /// `SettingsExposureTests` holds Debug Mode to the same rule.
    func testTheSwitchReachesTheDecodersParameters() {
        AppPreferences.shared.useVAD = true
        XCTAssertTrue(Settings().useVAD, "the per-dictation settings read the preference")
        XCTAssertTrue(params().vad, "the switch has to turn the pre-filter on")

        AppPreferences.shared.useVAD = false
        XCTAssertFalse(Settings().useVAD)
        XCTAssertFalse(params().vad, "…and off again when the switch is off")
    }

    /// The pre-filter is this engine's own call, not whisper_full's built-in
    /// `params.vad` path: that path belongs to `whisper_full`, which shares the
    /// decoding state the engine keeps per recording. A `vad` flag copied into
    /// the C parameters would filter the audio a second time and change every
    /// decode, so it must stay out of `toC()`.
    func testThePreFilterStaysOutOfTheCParameters() {
        AppPreferences.shared.useVAD = true
        var full = params()
        full.vad = true
        XCTAssertFalse(full.toC().vad,
                       "whisper_full's own VAD must stay off: the engine filters the audio itself")
    }
}
