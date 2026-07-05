import XCTest
@testable import OpenSuperWhisper

final class DiskSpaceUtilTests: XCTestCase {

    func testHasEnoughFreeSpace_aboveThreshold_returnsTrue() {
        XCTAssertTrue(DiskSpaceUtil.hasEnoughFreeSpace(freeSpace: 10_000_000_001))
    }

    func testHasEnoughFreeSpace_exactlyThreshold_returnsTrue() {
        XCTAssertTrue(DiskSpaceUtil.hasEnoughFreeSpace(freeSpace: 10_000_000_000))
    }

    func testHasEnoughFreeSpace_belowThreshold_returnsFalse() {
        XCTAssertFalse(DiskSpaceUtil.hasEnoughFreeSpace(freeSpace: 9_999_999_999))
        XCTAssertFalse(DiskSpaceUtil.hasEnoughFreeSpace(freeSpace: 0))
    }

    func testDiskSpaceError_hasUserFacingMessage() {
        let message = DiskSpaceError().errorDescription
        XCTAssertNotNil(message)
        XCTAssertTrue(message!.contains("10 GB"))
    }
}

final class RecordingRetentionTests: XCTestCase {

    func testRetentionCutoffDate_subtractsDays() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cutoff = try XCTUnwrap(RecordingStore.retentionCutoffDate(daysToKeep: 30, now: now))

        let expected = Calendar.current.date(byAdding: .day, value: -30, to: now)!
        XCTAssertEqual(cutoff, expected)
        XCTAssertLessThan(cutoff, now)
    }

    func testRetentionCutoffDate_separatesOldAndFreshRecordings() throws {
        let now = Date()
        let cutoff = try XCTUnwrap(RecordingStore.retentionCutoffDate(daysToKeep: 7, now: now))

        let oldTimestamp = now.addingTimeInterval(-8 * 24 * 3600)
        let freshTimestamp = now.addingTimeInterval(-6 * 24 * 3600)

        XCTAssertTrue(oldTimestamp < cutoff)
        XCTAssertFalse(freshTimestamp < cutoff)
    }

    func testRetentionCutoffDate_nonPositiveDays_returnsNil() {
        XCTAssertNil(RecordingStore.retentionCutoffDate(daysToKeep: 0))
        XCTAssertNil(RecordingStore.retentionCutoffDate(daysToKeep: -5))
    }

    func testIsDeletableRecordingURL_insideRecordingsDirectory_returnsTrue() {
        let url = Recording.recordingsDirectory.appendingPathComponent("recording.wav")
        XCTAssertTrue(RecordingStore.isDeletableRecordingURL(url))
    }

    func testIsDeletableRecordingURL_outsideRecordingsDirectory_returnsFalse() {
        XCTAssertFalse(RecordingStore.isDeletableRecordingURL(URL(fileURLWithPath: "/tmp/recording.wav")))
        XCTAssertFalse(RecordingStore.isDeletableRecordingURL(Recording.recordingsDirectory))

        let escaping = Recording.recordingsDirectory.appendingPathComponent("../../Documents/important.wav")
        XCTAssertFalse(RecordingStore.isDeletableRecordingURL(escaping))
    }
}

final class LanguageSupportTests: XCTestCase {

    func testSupportedLanguages_whisper_returnsFullListWithAuto() {
        let languages = LanguageUtil.supportedLanguages(engine: "whisper", fluidAudioModelVersion: "v3")
        XCTAssertEqual(languages, LanguageUtil.availableLanguages)
        XCTAssertTrue(languages.contains("auto"))
        XCTAssertTrue(languages.contains("zh"))
    }

    func testSupportedLanguages_parakeetV2_isEnglishOnly() {
        let languages = LanguageUtil.supportedLanguages(engine: "fluidaudio", fluidAudioModelVersion: "v2")
        XCTAssertEqual(languages, ["en"])
    }

    func testSupportedLanguages_parakeetV3_excludesUnsupportedLanguages() {
        let languages = LanguageUtil.supportedLanguages(engine: "fluidaudio", fluidAudioModelVersion: "v3")

        for unsupported in ["auto", "zh", "ja", "ko", "ar", "tr", "he", "hi", "id", "ca"] {
            XCTAssertFalse(languages.contains(unsupported), "\(unsupported) must not be offered for Parakeet v3")
        }
        for supported in ["en", "de", "ru", "uk", "pl", "mt"] {
            XCTAssertTrue(languages.contains(supported), "\(supported) must be offered for Parakeet v3")
        }
        XCTAssertEqual(languages.count, 25)
    }

    func testAllParakeetV3LanguagesHaveDisplayNames() {
        for code in LanguageUtil.parakeetV3Languages {
            XCTAssertNotNil(LanguageUtil.languageNames[code], "Missing display name for \(code)")
        }
    }

    func testFallbackLanguage() {
        XCTAssertEqual(LanguageUtil.fallbackLanguage(engine: "fluidaudio"), "en")
        XCTAssertEqual(LanguageUtil.fallbackLanguage(engine: "whisper"), "auto")
    }
}

final class CountLabelTests: XCTestCase {

    func testCountLabel_singularAndPlural() {
        XCTAssertEqual(countLabel(1, singular: "day", plural: "days"), "1 day")
        XCTAssertEqual(countLabel(7, singular: "day", plural: "days"), "7 days")
        XCTAssertEqual(countLabel(1, singular: "recording", plural: "recordings"), "1 recording")
        XCTAssertEqual(countLabel(0, singular: "recording", plural: "recordings"), "0 recordings")
    }
}
