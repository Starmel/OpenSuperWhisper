import FluidAudio
import XCTest
@testable import OpenSuperWhisper

/// Redux — moondream's ternary re-training of v3 — through the row's own path:
/// the stored version string, the app's mapping, FluidAudio's loader, the engine.
///
/// The weights are never downloaded here. Like the other model-backed cases in
/// this suite, the test skips when they are not on the machine (they come from
/// **Settings → Model → Download Models**, through the same
/// `AsrModels.downloadAndLoad(version:)` this engine calls), so a machine that
/// never picked Redux pays nothing and one that did re-runs the whole path.
final class ParakeetReduxTranscriptionTests: XCTestCase {

    func testReduxWeightsInTheCache_decodeThroughTheStoredVersionString() async throws {
        let directory = AsrModels.defaultCacheDirectory(for: .redux)
        guard AsrModels.modelsExist(at: directory, version: .redux) else {
            throw XCTSkip("no Redux weights at \(directory.path) — download them in Settings first")
        }

        // The whole reason the version string became one mapping: "redux" has to
        // reach FluidAudio's `.redux`, not fall back to v3's weights.
        let engine = FluidAudioEngine(modelVersion: "redux")
        try await engine.initialize()
        XCTAssertTrue(engine.isModelLoaded, "the Redux weights did not load")

        let audio = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("jfk.wav")
        guard FileManager.default.fileExists(atPath: audio.path) else {
            throw XCTSkip("jfk.wav is not in the checkout")
        }

        let started = Date()
        let text = try await engine.transcribeAudio(url: audio, settings: Settings())
        let seconds = String(format: "%.2f", Date().timeIntervalSince(started))

        TestFixtures.report("[redux] \(seconds)s :: \(text)")
        XCTAssertFalse(
            text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "11 s of English speech decoded to nothing"
        )

        // The row the user clicks reads the same cache through the same version
        // mapping: with the weights on disk it has to offer the model as
        // installed, not as another 219 MB download.
        await MainActor.run {
            let viewModel = SettingsViewModel()
            viewModel.initializeFluidAudioModels()

            let row = viewModel.downloadableFluidAudioModels.first { $0.version == "redux" }
            XCTAssertNotNil(row, "the Parakeet list has no Redux row")
            XCTAssertEqual(row?.isDownloaded, true, "the cached Redux weights must show as installed")
            XCTAssertEqual(row?.isSupportedOnThisMac, true, "Redux is supported on this Mac")
            XCTAssertEqual(row?.name, "Parakeet Redux")
        }
    }
}
