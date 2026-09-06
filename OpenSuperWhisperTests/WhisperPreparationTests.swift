import Foundation
import AVFoundation
import XCTest
@testable import OpenSuperWhisper

private final class PreparingWhisperEngine: WhisperEngine {
    let entered: XCTestExpectation
    let release = DispatchSemaphore(value: 0)
    var preparationError: Error?
    private(set) var preparationCount = 0
    private(set) var decodeCount = 0

    init(entered: XCTestExpectation) { self.entered = entered }

    override func prepareForRecording() throws {
        preparationCount += 1
        entered.fulfill()
        guard release.wait(timeout: .now() + 5) == .success else {
            throw TranscriptionError.processingFailed
        }
        if let preparationError { throw preparationError }
    }

    override func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        decodeCount += 1
        return "prepared text"
    }
}

final class WhisperPreparationTests: XCTestCase {
    @MainActor
    func testServiceWaitsForPreparationAndDoesNotPrepareDuringDecode() async throws {
        let entered = expectation(description: "preparation started")
        let engine = PreparingWhisperEngine(entered: entered)
        let service = TranscriptionService(engine: engine)
        service.prepareForRecording()
        service.prepareForRecording()
        await fulfillment(of: [entered], timeout: 2)
        let task = Task {
            try await service.transcribeAudio(url: URL(fileURLWithPath: "/unused.wav"), settings: Settings())
        }
        while !service.isTranscribing { await Task.yield() }
        service.prepareForRecording()
        XCTAssertEqual(engine.decodeCount, 0)
        engine.release.signal()
        let result = try await task.value
        XCTAssertEqual(result, "prepared text")
        XCTAssertEqual(engine.preparationCount, 1)
        XCTAssertEqual(engine.decodeCount, 1)
    }

    @MainActor
    func testPreparationFailureIsReportedWithoutDecoding() async throws {
        let entered = expectation(description: "preparation started")
        let engine = PreparingWhisperEngine(entered: entered)
        engine.preparationError = TranscriptionError.contextInitializationFailed
        let service = TranscriptionService(engine: engine)
        service.prepareForRecording()
        await fulfillment(of: [entered], timeout: 2)
        engine.release.signal()
        do {
            _ = try await service.transcribeAudio(url: URL(fileURLWithPath: "/unused.wav"), settings: Settings())
            XCTFail("Preparation error was hidden")
        } catch {
            XCTAssertTrue(error is TranscriptionError)
        }
        XCTAssertEqual(engine.decodeCount, 0)
        XCTAssertFalse(service.isTranscribing)
    }

    func testPreparedStatePreservesTextAndIsReleasedAfterUse() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let model = root.appendingPathComponent("ggml-tiny.en.bin")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: model.path))
        let original = AppPreferences.shared.selectedWhisperModelPath
        AppPreferences.shared.selectedWhisperModelPath = model.path
        defer { AppPreferences.shared.selectedWhisperModelPath = original }
        let engine = WhisperEngine()
        try await engine.initialize()
        var settings = Settings()
        settings.selectedLanguage = "en"
        settings.initialPrompt = ""
        settings.useBeamSearch = false
        settings.temperature = 0
        let audio = root.appendingPathComponent("jfk.wav")
        let cold = try await engine.transcribeAudio(url: audio, settings: settings)
        XCTAssertFalse(engine.hasPreparedState)
        let silenceURL = FileManager.default.temporaryDirectory.appendingPathComponent("vad-silence-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: silenceURL) }
        do {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
            let file = try AVAudioFile(forWriting: silenceURL, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000))
            buffer.frameLength = 48000
            buffer.floatChannelData![0].initialize(repeating: 0, count: 48000)
            try file.write(from: buffer)
        }
        try engine.prepareForRecording()
        let silence = try await engine.transcribeAudio(url: silenceURL, settings: settings)
        XCTAssertEqual(silence, "")
        XCTAssertFalse(engine.hasPreparedState)
        let start = ContinuousClock.now
        try engine.prepareForRecording()
        print("[PREPARE] \(start.duration(to: .now))")
        XCTAssertTrue(engine.hasPreparedState)
        try engine.prepareForRecording()
        let prepared = try await engine.transcribeAudio(url: audio, settings: settings)
        XCTAssertEqual(prepared, cold)
        XCTAssertFalse(engine.hasPreparedState)
        try engine.prepareForRecording()
        XCTAssertTrue(engine.hasPreparedState)
    }
}
