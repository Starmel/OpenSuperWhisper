import XCTest
import WhisperCore

final class OpenSuperWhisper_iOSTests: XCTestCase {

    func testWhisperCoreImport() {
        // Verify WhisperCore types are accessible from the iOS test target
        XCTAssertNotNil(TranscriptionService.shared)
        XCTAssertNotNil(RecordingStore.shared)
        XCTAssertNotNil(WhisperModelManager.shared)
    }

    func testRecordingStateEnum() {
        let state = RecordingState.idle
        XCTAssertEqual(state, RecordingState.idle)
        XCTAssertNotEqual(state, RecordingState.recording)
    }

    func testTranscriptionSettings() {
        let settings = TranscriptionSettings()
        XCTAssertFalse(settings.translateToEnglish)
        XCTAssertTrue(settings.suppressBlankAudio)
    }

    func testLanguageUtil() {
        XCTAssertFalse(LanguageUtil.availableLanguages.isEmpty)
        XCTAssertTrue(LanguageUtil.availableLanguages.contains("en"))
        XCTAssertEqual(LanguageUtil.languageNames["en"], "English")
    }

    func testTextUtil() {
        XCTAssertEqual(TextUtil.wordCount("hello world"), 2)
        XCTAssertEqual(TextUtil.wordCount(""), 0)
    }
}
