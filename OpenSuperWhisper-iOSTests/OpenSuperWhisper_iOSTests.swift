import XCTest
import WhisperCore

final class OpenSuperWhisper_iOSTests: XCTestCase {

    func testWhisperCoreImport() {
        // Verify WhisperCore types are accessible from the iOS test target
        XCTAssertNotNil(TranscriptionService.shared)
        XCTAssertNotNil(RecordingStore.shared)
        XCTAssertNotNil(WhisperModelManager.shared)
    }
}

// MARK: - RecordingState Tests

final class RecordingStateiOSTests: XCTestCase {
    func testAllCasesAreDistinct() {
        let allCases: [RecordingState] = [.idle, .connecting, .recording, .decoding, .busy]
        for i in 0..<allCases.count {
            for j in (i + 1)..<allCases.count {
                XCTAssertNotEqual(allCases[i], allCases[j],
                    "\(allCases[i]) should not equal \(allCases[j])")
            }
        }
    }

    func testEquality() {
        XCTAssertEqual(RecordingState.idle, RecordingState.idle)
        XCTAssertEqual(RecordingState.recording, RecordingState.recording)
        XCTAssertEqual(RecordingState.connecting, RecordingState.connecting)
        XCTAssertEqual(RecordingState.decoding, RecordingState.decoding)
        XCTAssertEqual(RecordingState.busy, RecordingState.busy)
    }

    func testInequality() {
        XCTAssertNotEqual(RecordingState.idle, RecordingState.recording)
        XCTAssertNotEqual(RecordingState.recording, RecordingState.decoding)
        XCTAssertNotEqual(RecordingState.connecting, RecordingState.busy)
    }
}

// MARK: - TranscriptionSettings Tests

final class TranscriptionSettingsiOSTests: XCTestCase {
    func testDefaultValues() {
        let settings = TranscriptionSettings()
        XCTAssertFalse(settings.translateToEnglish)
        XCTAssertTrue(settings.suppressBlankAudio)
        XCTAssertFalse(settings.showTimestamps)
        XCTAssertFalse(settings.useBeamSearch)
    }

    func testIsAsianLanguage_japanese() {
        var settings = TranscriptionSettings()
        settings.selectedLanguage = "ja"
        XCTAssertTrue(settings.isAsianLanguage)
    }

    func testIsAsianLanguage_chinese() {
        var settings = TranscriptionSettings()
        settings.selectedLanguage = "zh"
        XCTAssertTrue(settings.isAsianLanguage)
    }

    func testIsAsianLanguage_korean() {
        var settings = TranscriptionSettings()
        settings.selectedLanguage = "ko"
        XCTAssertTrue(settings.isAsianLanguage)
    }

    func testIsAsianLanguage_english() {
        var settings = TranscriptionSettings()
        settings.selectedLanguage = "en"
        XCTAssertFalse(settings.isAsianLanguage)
    }

    func testShouldApplyAsianAutocorrect_asianWithAutocorrectOn() {
        var settings = TranscriptionSettings()
        settings.selectedLanguage = "ja"
        settings.useAsianAutocorrect = true
        XCTAssertTrue(settings.shouldApplyAsianAutocorrect)
    }

    func testShouldApplyAsianAutocorrect_asianWithAutocorrectOff() {
        var settings = TranscriptionSettings()
        settings.selectedLanguage = "ja"
        settings.useAsianAutocorrect = false
        XCTAssertFalse(settings.shouldApplyAsianAutocorrect)
    }

    func testShouldApplyAsianAutocorrect_nonAsianLanguage() {
        var settings = TranscriptionSettings()
        settings.selectedLanguage = "en"
        settings.useAsianAutocorrect = true
        XCTAssertFalse(settings.shouldApplyAsianAutocorrect)
    }

    func testAsianLanguagesSetContainsExpectedCodes() {
        XCTAssertEqual(TranscriptionSettings.asianLanguages, Set(["zh", "ja", "ko"]))
    }
}

// MARK: - NoOpTextPostProcessor Tests

final class NoOpTextPostProcessoriOSTests: XCTestCase {
    func testReturnsInputUnchanged() {
        let processor = NoOpTextPostProcessor()
        XCTAssertEqual(processor.process("hello world", language: "en"), "hello world")
    }

    func testReturnsEmptyStringUnchanged() {
        let processor = NoOpTextPostProcessor()
        XCTAssertEqual(processor.process("", language: "en"), "")
    }

    func testReturnsUnicodeUnchanged() {
        let processor = NoOpTextPostProcessor()
        XCTAssertEqual(processor.process("こんにちは世界", language: "ja"), "こんにちは世界")
    }
}

// MARK: - LanguageUtil Tests

final class LanguageUtiliOSTests: XCTestCase {
    func testAvailableLanguagesNotEmpty() {
        XCTAssertFalse(LanguageUtil.availableLanguages.isEmpty)
    }

    func testAvailableLanguagesContainsEnglish() {
        XCTAssertTrue(LanguageUtil.availableLanguages.contains("en"))
    }

    func testAvailableLanguagesContainsAutoDetect() {
        XCTAssertTrue(LanguageUtil.availableLanguages.contains("auto"))
    }

    func testAvailableLanguagesContainsAsianLanguages() {
        XCTAssertTrue(LanguageUtil.availableLanguages.contains("zh"))
        XCTAssertTrue(LanguageUtil.availableLanguages.contains("ja"))
        XCTAssertTrue(LanguageUtil.availableLanguages.contains("ko"))
    }

    func testLanguageNamesHasEntryForEachLanguage() {
        for lang in LanguageUtil.availableLanguages {
            XCTAssertNotNil(LanguageUtil.languageNames[lang],
                "Missing language name for code: \(lang)")
        }
    }

    func testLanguageNameLookup() {
        XCTAssertEqual(LanguageUtil.languageNames["en"], "English")
        XCTAssertEqual(LanguageUtil.languageNames["auto"], "Auto-detect")
        XCTAssertEqual(LanguageUtil.languageNames["ja"], "Japanese")
    }

    func testLanguageNameForUnknownCodeIsNil() {
        XCTAssertNil(LanguageUtil.languageNames["xx"])
    }

    func testGetSystemLanguageReturnsValidCode() {
        let systemLang = LanguageUtil.getSystemLanguage()
        XCTAssertFalse(systemLang.isEmpty)
        // Should be either a known language code or "en" as fallback
        let knownCodes = Set(LanguageUtil.availableLanguages + ["eng"])
        XCTAssertTrue(knownCodes.contains(systemLang),
            "getSystemLanguage() returned unexpected code: \(systemLang)")
    }
}

// MARK: - TextUtil Tests

final class TextUtiliOSTests: XCTestCase {
    // Word count tests
    func testWordCount_emptyString() {
        XCTAssertEqual(TextUtil.wordCount(""), 0)
    }

    func testWordCount_singleWord() {
        XCTAssertEqual(TextUtil.wordCount("hello"), 1)
    }

    func testWordCount_multipleWords() {
        XCTAssertEqual(TextUtil.wordCount("hello world"), 2)
    }

    func testWordCount_leadingTrailingWhitespace() {
        XCTAssertEqual(TextUtil.wordCount("  hello world  "), 2)
    }

    func testWordCount_multipleSpaces() {
        XCTAssertEqual(TextUtil.wordCount("hello    world"), 2)
    }

    func testWordCount_newlines() {
        XCTAssertEqual(TextUtil.wordCount("hello\nworld\nfoo"), 3)
    }

    func testWordCount_whitespaceOnly() {
        XCTAssertEqual(TextUtil.wordCount("   "), 0)
    }

    // Duration formatting tests
    func testFormatDuration_zero() {
        XCTAssertEqual(TextUtil.formatDuration(0), "0s")
    }

    func testFormatDuration_seconds() {
        XCTAssertEqual(TextUtil.formatDuration(30), "30s")
    }

    func testFormatDuration_minutesAndSeconds() {
        XCTAssertEqual(TextUtil.formatDuration(65), "1m 5s")
    }

    func testFormatDuration_exactMinutes() {
        XCTAssertEqual(TextUtil.formatDuration(120), "2m 0s")
    }

    func testFormatDuration_hoursMinutesSeconds() {
        XCTAssertEqual(TextUtil.formatDuration(3661), "1h 1m 1s")
    }

    func testFormatDuration_exactHours() {
        XCTAssertEqual(TextUtil.formatDuration(3600), "1h 0m 0s")
    }
}
