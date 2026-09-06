import AVFoundation
import Foundation
import XCTest
@testable import OpenSuperWhisper

final class PCMRecordingTests: XCTestCase {
    func testResamplingDoesNotDependOnInputChunkBoundaries() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        let frameCount = 65760
        let source = (0..<frameCount).map { Float(0.2 * sin(Double($0) * 2 * .pi * 937 / 48000)) }
        func record(chunkSize: Int) throws -> [Float] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pcm-chunks-\(UUID()).wav")
            defer { try? FileManager.default.removeItem(at: url) }
            let writer = try PCMRecordingWriter(url: url, inputFormat: format)
            for offset in stride(from: 0, to: frameCount, by: chunkSize) {
                let count = min(chunkSize, frameCount - offset)
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
                buffer.frameLength = AVAudioFrameCount(count)
                source.withUnsafeBufferPointer {
                    buffer.floatChannelData![0].update(from: $0.baseAddress! + offset, count: count)
                }
                try writer.append(buffer)
            }
            return try writer.finish().samples
        }
        let whole = try record(chunkSize: frameCount)
        for chunkSize in [17, 1024, 4096] {
            let chunked = try record(chunkSize: chunkSize)
            XCTAssertEqual(chunked.count, whole.count)
            XCTAssertLessThanOrEqual(zip(chunked, whole).map { abs($0 - $1) }.max() ?? 0, 1 / 32768)
        }
    }

    func testPreparedSamplesMatchSavedWAVAcrossRatesAndChannels() async throws {
        for (rate, channelCount, duration) in [(16000.0, 1, 1.37), (44100.0, 1, 1.37),
                                               (48000.0, 2, 12.345), (48000.0, 4, 12.345)] {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("pcm-\(UUID()).wav")
            defer { try? FileManager.default.removeItem(at: url) }
            let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channelCount)))
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                                    interleaved: false, channelLayout: layout))
            let writer = try PCMRecordingWriter(url: url, inputFormat: format)
            let frameCount = Int(rate * duration)
            let chunkSizes = [1, 333, 4096, 17, 8192]
            var offset = 0
            var chunk = 0
            while offset < frameCount {
                let count = min(chunkSizes[chunk % chunkSizes.count], frameCount - offset)
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
                buffer.frameLength = AVAudioFrameCount(count)
                for channel in 0..<channelCount {
                    for frame in 0..<count {
                        let time = Double(offset + frame) / rate
                        let amplitude = channel == 0 || time > duration / 2 ? 0.2 : 0.0
                        buffer.floatChannelData![channel][frame] = Float(amplitude * sin(time * Double(300 + channel * 137) * 2 * .pi))
                    }
                }
                try writer.append(buffer)
                offset += count
                chunk += 1
            }
            let recorded = try writer.finish()
            XCTAssertEqual(recorded.duration, duration, accuracy: 0.002)
            let tailEnergy = recorded.samples.suffix(160).reduce(Float(0)) { $0 + $1 * $1 }
            XCTAssertGreaterThan(tailEnergy, 0.01)
            let engine = WhisperEngine()
            let converted = try await engine.convertAudioToPCM(fileURL: url)
            let fromFile = try XCTUnwrap(converted)
            XCTAssertEqual(recorded.samples.count, fromFile.count)
            let difference = zip(recorded.samples, fromFile).map { abs($0 - $1) }.max() ?? 0
            XCTAssertEqual(difference, 0, "rate=\(rate), channels=\(channelCount)")
        }
    }

    @MainActor
    func testServiceDecodesPreparedAudioWithoutReadingTheFile() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let model = root.appendingPathComponent("ggml-tiny.en.bin")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: model.path))
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("pcm-speech-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: output) }
        let audio = try Self.prepare(file: root.appendingPathComponent("jfk.wav"), output: output)
        let original = AppPreferences.shared.selectedWhisperModelPath
        AppPreferences.shared.selectedWhisperModelPath = model.path
        defer { AppPreferences.shared.selectedWhisperModelPath = original }
        let engine = WhisperEngine()
        try await engine.initialize()
        var settings = Settings()
        settings.selectedLanguage = "en"
        settings.initialPrompt = ""
        settings.temperature = 0
        settings.useBeamSearch = false
        let fromFile = try await engine.transcribeAudio(url: output, settings: settings)
        let service = TranscriptionService(engine: engine)
        service.prepareForRecording()
        let fromPCM = try await service.transcribeAudio(
            url: output.appendingPathExtension("does-not-exist"), settings: settings, pcmSamples: audio.samples
        )
        XCTAssertEqual(fromPCM, fromFile)
        XCTAssertTrue(fromPCM.lowercased().contains("your country"))
        XCTAssertFalse(engine.hasPreparedState)
    }

    func testMicrophoneCaptureProducesPCMAndWAV() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OSW_TEST_MICROPHONE"] == "1")
        try XCTSkipUnless(AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                          "Microphone permission is required")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pcm-microphone-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let session = try PCMRecordingSession(url: url)
        try session.start()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let recording = try session.finish()
        XCTAssertGreaterThan(recording.duration, 1)
        let converted = try await WhisperEngine().convertAudioToPCM(fileURL: url)
        let fromFile = try XCTUnwrap(converted)
        XCTAssertEqual(recording.samples.count, fromFile.count)
        XCTAssertEqual(zip(recording.samples, fromFile).map { abs($0 - $1) }.max(), 0)
    }

    static func prepare(file input: URL, output: URL) throws -> RecordedAudio {
        let file = try AVAudioFile(forReading: input)
        let writer = try PCMRecordingWriter(url: output, inputFormat: file.processingFormat)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096))
        while file.framePosition < file.length {
            try file.read(into: buffer)
            if buffer.frameLength == 0 { break }
            try writer.append(buffer)
        }
        return try writer.finish()
    }
}
