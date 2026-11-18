import XCTest
import GRDB
import AVFoundation
@testable import OpenSuperWhisper

/// The regression: a failed dictation used to be stored with the failure's own
/// text as the row's transcript — a bare `TranscriptionError` bridges to
/// "The operation couldn’t be completed. (OpenSuperWhisper.TranscriptionError error 1.)",
/// which then read in history as if the user had dictated it. A failed row must
/// carry no transcript while the audio it was asked to keep stays on disk.
///
/// Where the files live is deliberate, not sloppiness — do not "tidy" it into a
/// seam: `saveFailedDictation` relocates failed audio into
/// `Recording.recordingsDirectory`, the app's own directory (derived from the
/// bundle id, not injectable), and keeps it there for a retry. That relocation
/// is the feature under test, and `FailedAudioPreservationTests` already takes
/// the same route. So: the database is a fresh in-memory `DatabaseQueue`, the
/// only file this test writes is a WAV inside its own temporary directory, and
/// the single copy production relocates is removed by `defer` at the exact URL
/// the call returned — never a glob, never the directory, so a failure here can
/// not delete anything else of the user's.
@MainActor
final class FailedDictationStoresNoTranscriptTests: XCTestCase {

    func testFailedDictationStoresNoErrorTextAsTranscript() async throws {
        // The failure the dictation path hands to the store, bridged to the very
        // message a real failed row contained ("… error 1.").
        let failure = TranscriptionError.audioConversionFailed
        // Do not pin the bridged NSError code: it is derived from the enum's case
        // index, so adding a case to `TranscriptionError` changes the message while
        // the defect this test guards - error text landing in the transcript - does
        // not. What matters is that the fixture carries the failure's own
        // description, and that none of it reaches the stored transcript.
        let failureText = failure.localizedDescription
        XCTAssertTrue(failureText.contains("TranscriptionError"),
                      "fixture must carry the failure's own description, got: \(failureText)")

        // In-memory database: the user's recordings.sqlite is never opened.
        let store = try RecordingStore(databaseQueue: DatabaseQueue())
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("failed-dictation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // Everything this test writes lives in its own scratch directory under the
        // system temp dir, created just above and removed just below.
        let source = scratch.appendingPathComponent("dictation.wav")
        let recorded = try recordedAudio(at: source)
        let audioBytes = try Data(contentsOf: source)
        XCTAssertGreaterThan(audioBytes.count, 44, "the throwaway file must be written audio")
        XCTAssertEqual(String(decoding: audioBytes.prefix(4), as: UTF8.self), "RIFF")

        let row = try await store.saveFailedDictation(recorded, error: failure)
        // The store keeps failed audio in its own recordings directory, so remove
        // exactly the file this call created — its returned URL, nothing broader.
        defer { try? FileManager.default.removeItem(at: row.url) }

        let stored = try await store.fetchRecordings(limit: 10, offset: 0)
        XCTAssertEqual(stored.map(\.id), [row.id])
        let saved = try XCTUnwrap(stored.first)

        XCTAssertTrue(saved.transcription.isEmpty,
                      "a failed dictation must carry no transcript at all, got: \(saved.transcription)")
        XCTAssertFalse(saved.transcription.contains(failureText),
                       "the failure message was stored as the transcript")
        // No fragment list: those two checks are the whole contract — nothing at
        // all, and never the failure's own description. A hand-picked list of
        // fragments goes stale as the bridged text changes (it did: "error 1"
        // had already stopped appearing in it while the defect it probed was
        // still possible), and a stale list passes with the defect present.
        XCTAssertEqual(saved.status, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.url.path),
                      "a failed dictation must keep its audio")
        XCTAssertEqual(saved.sourceFileURL, saved.url.path)
        XCTAssertEqual(try Data(contentsOf: saved.url), audioBytes)
    }

    /// A short but real 16 kHz mono PCM file — what `AudioRecorder` leaves behind
    /// when a dictation dies mid-write.
    private func recordedAudio(at url: URL) throws -> RecordedAudio {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let writer = try PCMRecordingWriter(url: url, inputFormat: format)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000))
        buffer.frameLength = 16000
        buffer.floatChannelData![0].initialize(repeating: 0.25, count: 16000)
        try writer.append(buffer)
        return writer.closeAfterFailure()
    }
}
