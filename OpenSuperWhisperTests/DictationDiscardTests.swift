import XCTest
@testable import OpenSuperWhisper

final class DictationDiscardTests: XCTestCase {

    private var dictationURL: URL {
        AudioRecorder.temporaryRecordingsDirectory.appendingPathComponent("12345.wav")
    }

    private var importedFileURL: URL {
        URL(fileURLWithPath: "/Users/user/Movies/interview.mp4")
    }

    private func shouldDiscard(_ text: String, _ url: URL, saveHistory: Bool = true) -> Bool {
        TranscriptionQueue.shouldDiscardDictation(text: text, sourceURL: url, saveHistory: saveHistory)
    }

    // MARK: - Empty dictations

    func testEmptyTextFromDictation_isDiscarded() {
        XCTAssertTrue(shouldDiscard("", dictationURL))
    }

    func testEmptyTextFromImportedFile_isKept() {
        XCTAssertFalse(shouldDiscard("", importedFileURL))
    }

    func testNonEmptyTextFromDictation_isKept() {
        XCTAssertFalse(shouldDiscard("hello world", dictationURL))
    }

    func testNonEmptyTextFromImportedFile_isKept() {
        XCTAssertFalse(shouldDiscard("hello world", importedFileURL))
    }

    // MARK: - Transcript history turned off

    func testHistoryDisabled_dictationIsDiscarded() {
        XCTAssertTrue(shouldDiscard("hello world", dictationURL, saveHistory: false))
    }

    func testHistoryDisabled_importedFileIsStillKept() {
        XCTAssertFalse(shouldDiscard("hello world", importedFileURL, saveHistory: false),
                       "The history entry is the only place an imported file's transcription appears")
    }
}
