import XCTest
import GRDB
@testable import OpenSuperWhisper

@MainActor
final class LatestTranscriptionTests: XCTestCase {
    func testLatestSuccessfulTranscriptionSkipsNewerUnsuccessfulAndBlankRecordings() async throws {
        let store = try RecordingStore(databaseQueue: DatabaseQueue())
        XCTAssertNil(try store.latestSuccessfulTranscription())

        let entries: [(String, RecordingStatus)] = [
            ("older result", .completed),
            ("  Latest result\nwith original formatting  ", .completed),
            (" \n\t ", .completed),
            ("unfinished", .transcribing),
            ("waiting", .pending),
            ("error message", .failed)
        ]
        for (index, entry) in entries.enumerated() {
            let id = UUID()
            try await store.addRecordingSync(Recording(
                id: id, timestamp: Date(timeIntervalSince1970: Double(index)),
                fileName: Recording.fileName(for: id), transcription: entry.0,
                duration: 1, status: entry.1, progress: 0
            ))
        }

        XCTAssertEqual(try store.latestSuccessfulTranscription(), entries[1].0)
        XCTAssertTrue(store.recordings.isEmpty)
    }
}
