import XCTest
@testable import OpenSuperWhisper

final class GigaAMEngineTests: XCTestCase {
    /// 1 s of `0.3 sin(2π·8000·t²) + 0.3 sin(2π·440·t)`, the chirp covering every mel band.
    private func chirp() -> [Float] {
        (0..<16000).map { index in
            let t = Double(index) / 16000
            return Float(0.3 * sin(2 * .pi * 8000 * t * t) + 0.3 * sin(2 * .pi * 440 * t))
        }
    }

    func testLogMelMatchesTorchaudio() {
        let features = GigaAMFeatureExtractor.logMel(chirp())
        let frames = GigaAMFeatureExtractor.frameCount(sampleCount: 16000)
        XCTAssertEqual(frames, 99)
        XCTAssertEqual(features.count, 64 * frames)

        // torchaudio MelSpectrogram(sample_rate=16000, n_mels=64, win_length=320, hop_length=160,
        // n_fft=320, center=False, mel_scale="htk", norm=None) -> clamp(1e-9, 1e9).log()
        let reference: [(mel: Int, frame: Int, value: Float)] = [
            (0, 0, 2.30868), (10, 50, 4.43887), (63, 98, -20.72327), (17, 72, -6.88166),
            (8, 32, -3.11060), (15, 63, -3.79023), (57, 60, 2.85427), (48, 26, -0.76091),
            (12, 62, 6.09983), (3, 49, -9.84168),
        ]
        for point in reference {
            XCTAssertEqual(features[point.mel * frames + point.frame], point.value, accuracy: 2e-3,
                           "mel \(point.mel), frame \(point.frame)")
        }
    }

    func testThirtySecondWindowMatchesEncoderInput() {
        XCTAssertEqual(GigaAMEngine.windowFrames, 2999)
    }

    func testShortAudioIsSingleWindow() {
        let samples = [Float](repeating: 0.1, count: 16000 * 12)
        XCTAssertEqual(GigaAMEngine.windowRanges(for: samples), [0..<samples.count])
        XCTAssertEqual(GigaAMEngine.windowRanges(for: []), [])
    }

    func testLongAudioIsCutAtQuietestPoint() {
        // 70 s of tone with 300 ms of silence at 25 s.
        var samples = (0..<(16000 * 70)).map { Float(0.3 * sin(Double($0) * 0.1)) }
        let pause = (16000 * 25)..<(16000 * 25 + 4800)
        for index in pause { samples[index] = 0 }

        let ranges = GigaAMEngine.windowRanges(for: samples)
        XCTAssertEqual(ranges.first?.lowerBound, 0)
        XCTAssertEqual(ranges.last?.upperBound, samples.count)
        for (previous, next) in zip(ranges, ranges.dropFirst()) {
            XCTAssertEqual(previous.upperBound, next.lowerBound)
        }
        XCTAssertTrue(ranges.allSatisfy { $0.count <= GigaAMEngine.windowSamples })
        XCTAssertTrue(pause.contains(ranges[0].upperBound), "cut at \(ranges[0].upperBound)")
    }

    /// End-to-end check against the real model, downloading it if needed. Runs only when
    /// `GIGAAM_TEST_AUDIO` / `GIGAAM_TEST_EXPECTED` are set (pass them with the
    /// `TEST_RUNNER_` prefix through xcodebuild).
    func testTranscribesRussianSpeech() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard GigaAMModel.isSupported,
              let audioPath = environment["GIGAAM_TEST_AUDIO"],
              let expected = environment["GIGAAM_TEST_EXPECTED"] else {
            throw XCTSkip("GigaAM test audio not configured")
        }
        if !GigaAMModel.isInstalled {
            try await GigaAMModel.install { _ in }
        }
        let engine = GigaAMEngine()
        try await engine.initialize()
        let settings = await MainActor.run { Settings() }
        let text = try await engine.transcribeAudio(url: URL(fileURLWithPath: audioPath), settings: settings)
        XCTAssertTrue(text.contains(expected), text)
    }
}
