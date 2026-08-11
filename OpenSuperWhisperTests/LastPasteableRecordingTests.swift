import XCTest
@testable import OpenSuperWhisper

final class LastPasteableRecordingTests: XCTestCase {

    private func makeRecording(_ transcription: String,
                               status: RecordingStatus = .completed,
                               secondsAgo: TimeInterval) -> Recording {
        Recording(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_800_000_000 - secondsAgo),
            fileName: "\(UUID().uuidString).wav",
            transcription: transcription,
            duration: 1.0,
            status: status,
            progress: 1.0,
            sourceFileURL: nil
        )
    }

    func testLastPasteable_emptyInput_returnsNil() {
        XCTAssertNil(RecordingStore.lastPasteable(from: []))
    }

    func testLastPasteable_picksMostRecent() throws {
        let recordings = [
            makeRecording("older", secondsAgo: 100),
            makeRecording("newest", secondsAgo: 10),
            makeRecording("oldest", secondsAgo: 500),
        ]
        let result = try XCTUnwrap(RecordingStore.lastPasteable(from: recordings))
        XCTAssertEqual(result.transcription, "newest")
    }

    func testLastPasteable_ignoresIncompleteStatuses() throws {
        let recordings = [
            makeRecording("done", secondsAgo: 100),
            makeRecording("in flight", status: .transcribing, secondsAgo: 10),
            makeRecording("queued", status: .pending, secondsAgo: 5),
            makeRecording("broken", status: .failed, secondsAgo: 1),
        ]
        let result = try XCTUnwrap(RecordingStore.lastPasteable(from: recordings))
        XCTAssertEqual(result.transcription, "done")
    }

    func testLastPasteable_ignoresEmptyAndWhitespaceOnly() throws {
        let recordings = [
            makeRecording("real text", secondsAgo: 100),
            makeRecording("", secondsAgo: 20),
            makeRecording("   \n\t ", secondsAgo: 10),
        ]
        let result = try XCTUnwrap(RecordingStore.lastPasteable(from: recordings))
        XCTAssertEqual(result.transcription, "real text")
    }

    func testLastPasteable_noUsableCandidates_returnsNil() {
        let recordings = [
            makeRecording("", secondsAgo: 20),
            makeRecording("pending text", status: .pending, secondsAgo: 10),
        ]
        XCTAssertNil(RecordingStore.lastPasteable(from: recordings))
    }

    // MARK: - recentPasteable (menu bar list)

    func testRecentPasteable_returnsNewestFirst() {
        let recordings = [
            makeRecording("middle", secondsAgo: 50),
            makeRecording("newest", secondsAgo: 10),
            makeRecording("oldest", secondsAgo: 500),
        ]
        let result = RecordingStore.recentPasteable(from: recordings, limit: 5)

        XCTAssertEqual(result.map(\.transcription), ["newest", "middle", "oldest"])
    }

    func testRecentPasteable_respectsLimit() {
        let recordings = (1...10).map { makeRecording("item \($0)", secondsAgo: TimeInterval($0)) }
        let result = RecordingStore.recentPasteable(from: recordings, limit: 5)

        XCTAssertEqual(result.count, 5)
        XCTAssertEqual(result.first?.transcription, "item 1", "smallest secondsAgo is newest")
    }

    func testRecentPasteable_fewerAvailableThanLimit_returnsAll() {
        let recordings = [makeRecording("only one", secondsAgo: 10)]
        XCTAssertEqual(RecordingStore.recentPasteable(from: recordings, limit: 5).count, 1)
    }

    func testRecentPasteable_appliesSameFiltersAsLastPasteable() {
        let recordings = [
            makeRecording("good", secondsAgo: 100),
            makeRecording("", secondsAgo: 20),
            makeRecording("  \n ", secondsAgo: 15),
            makeRecording("still working", status: .transcribing, secondsAgo: 10),
        ]
        XCTAssertEqual(RecordingStore.recentPasteable(from: recordings, limit: 5).map(\.transcription),
                       ["good"])
    }

    func testRecentPasteable_zeroLimit_returnsEmpty() {
        let recordings = [makeRecording("something", secondsAgo: 10)]
        XCTAssertTrue(RecordingStore.recentPasteable(from: recordings, limit: 0).isEmpty)
    }

    // lastPasteable must stay consistent with the list rule, not drift from it.
    func testLastPasteable_matchesFirstOfRecentPasteable() {
        let recordings = [
            makeRecording("older", secondsAgo: 100),
            makeRecording("newest", secondsAgo: 10),
        ]
        XCTAssertEqual(RecordingStore.lastPasteable(from: recordings)?.transcription,
                       RecordingStore.recentPasteable(from: recordings, limit: 1).first?.transcription)
    }

    // The rule must not depend on the caller having pre-sorted the array.
    func testLastPasteable_doesNotRelyOnInputOrdering() throws {
        let ascending = [
            makeRecording("oldest", secondsAgo: 500),
            makeRecording("newest", secondsAgo: 10),
        ]
        let descending: [Recording] = ascending.reversed()

        XCTAssertEqual(try XCTUnwrap(RecordingStore.lastPasteable(from: ascending)).transcription, "newest")
        XCTAssertEqual(try XCTUnwrap(RecordingStore.lastPasteable(from: descending)).transcription, "newest")
    }
}
