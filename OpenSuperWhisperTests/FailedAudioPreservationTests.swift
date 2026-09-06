import XCTest
import GRDB
import AVFoundation
@testable import OpenSuperWhisper

@MainActor
final class FailedAudioPreservationTests: XCTestCase {
    func testFailedDictationKeepsAudioAndCanBeRetried() async throws {
        let store = try RecordingStore(databaseQueue: DatabaseQueue())
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let bytes = Data([1, 2, 3, 4])
        try bytes.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let row = try await store.saveFailedDictation(RecordedAudio(url: source, samples: [Float](repeating: 0, count: 16000)),
                                                       error: TranscriptionError.processingFailed)
        defer { try? FileManager.default.removeItem(at: row.url) }
        XCTAssertEqual(row.status, .failed)
        XCTAssertEqual(row.sourceFileURL, row.url.path)
        XCTAssertEqual(try Data(contentsOf: row.url), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        let stored = try await store.fetchRecordings(limit: 10, offset: 0)
        XCTAssertEqual(stored.map(\.id), [row.id])
    }

    func testDatabaseFailureStillKeepsRecoverableAudio() async throws {
        let db = try DatabaseQueue()
        let store = try RecordingStore(databaseQueue: db)
        try await db.write { db in
            try db.execute(sql: "CREATE TRIGGER reject_insert BEFORE INSERT ON recordings BEGIN SELECT RAISE(ABORT, 'test refusal'); END")
        }
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data([7]).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        do {
            _ = try await store.saveFailedDictation(RecordedAudio(url: source, samples: []), error: TranscriptionError.processingFailed)
            XCTFail("Expected storage error")
        } catch let error as PreservedAudioError {
            defer { try? FileManager.default.removeItem(at: error.url) }
            XCTAssertEqual(try Data(contentsOf: error.url), Data([7]))
            XCTAssertTrue(error.localizedDescription.contains(error.url.path))
        }
    }

    func testClosingFailedPCMWriterPreservesAlreadyWrittenFrames() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let writer = try PCMRecordingWriter(url: url, inputFormat: format)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000))
        buffer.frameLength = 16000
        buffer.floatChannelData![0].initialize(repeating: 0.25, count: 16000)
        try writer.append(buffer)
        let audio = writer.closeAfterFailure()
        XCTAssertFalse(audio.samples.isEmpty)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(Int(file.length), audio.samples.count)
        XCTAssertGreaterThan(audio.duration, 0)
    }
}
