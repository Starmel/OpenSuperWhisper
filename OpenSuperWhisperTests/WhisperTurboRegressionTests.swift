import Foundation
import XCTest
@testable import OpenSuperWhisper

final class WhisperTurboRegressionTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()

    func testTurboBeamSearchPreservesLongDictation() async throws {
        guard let modelPath = ProcessInfo.processInfo.environment["OSW_TEST_TURBO_MODEL"] else {
            throw XCTSkip("Set OSW_TEST_TURBO_MODEL to large-v3-turbo")
        }
        let originalPath = AppPreferences.shared.selectedWhisperModelPath
        AppPreferences.shared.selectedWhisperModelPath = modelPath
        defer { AppPreferences.shared.selectedWhisperModelPath = originalPath }
        let engine = WhisperEngine()
        try await engine.initialize()

        for language in ["en", "ru"] {
            let fixture = Self.repoRoot.appendingPathComponent("OpenSuperWhisperTests/Fixtures/long_\(language)")
            let reference = try String(contentsOf: fixture.appendingPathExtension("txt"), encoding: .utf8)
            var settings = Settings()
            settings.selectedLanguage = language
            settings.showTimestamps = false
            settings.initialPrompt = ""
            settings.useBeamSearch = true
            settings.beamSize = 5
            settings.temperature = 0
            settings.noSpeechThreshold = 0.6
            settings.suppressBlankAudio = true
            let start = ContinuousClock.now
            let text = try await engine.transcribeAudio(url: fixture.appendingPathExtension("m4a"), settings: settings)
            let errorRate = Self.wordErrorRate(reference: reference, transcription: text)
            print("[TURBO-\(language)] elapsed=\(start.duration(to: .now)) WER=\(errorRate) text=\(text)")
            XCTAssertLessThan(errorRate, 0.25, text)
            XCTAssertTrue(text.lowercased().contains(language == "ru" ? "серебряный" : "silver"), text)
        }
    }

    static func wordErrorRate(reference: String, transcription: String) -> Double {
        let words: (String) -> [String] = { $0.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) }
        let expected = words(reference)
        let actual = words(transcription)
        var previous = Array(0...actual.count)
        for (i, word) in expected.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: actual.count)
            for (j, candidate) in actual.enumerated() {
                current[j + 1] = min(current[j] + 1, previous[j + 1] + 1, previous[j] + (word == candidate ? 0 : 1))
            }
            previous = current
        }
        return Double(previous[actual.count]) / Double(max(1, expected.count))
    }
}
