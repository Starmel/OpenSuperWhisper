import AppKit
import FluidAudio
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

    /// Redux is a ternary re-training of v3 with the same tokenizer, so the list
    /// it may offer is v3's 25 languages — not v2's English-only one.
    func testSupportedLanguages_parakeetRedux_isTheV3List() {
        XCTAssertEqual(
            LanguageUtil.supportedLanguages(engine: "fluidaudio", fluidAudioModelVersion: "redux"),
            LanguageUtil.parakeetV3Languages
        )
    }
}

final class ParakeetModelVersionTests: XCTestCase {

    /// Every call site used to map a stored version with
    /// `version == "v2" ? .v2 : .v3`, which resolves every string that is not
    /// "v2" to v3 — including "redux", whose weights and cache directory are its
    /// own. The app would have downloaded, verified, measured and deleted v3's
    /// files under Redux's name.
    func testAsrVersion_redux_doesNotCollapseToV3() {
        guard case .redux = AsrModelVersion(storedParakeetVersion: "redux") else {
            return XCTFail("\"redux\" must resolve to FluidAudio's .redux, not to v3's weights")
        }
    }

    func testAsrVersion_namedVersions_resolveToThemselves() {
        guard case .v2 = AsrModelVersion(storedParakeetVersion: "v2") else {
            return XCTFail("\"v2\" must resolve to .v2")
        }
        guard case .v3 = AsrModelVersion(storedParakeetVersion: "v3") else {
            return XCTFail("\"v3\" must resolve to .v3")
        }
    }

    /// A preference written by a build that offered no third model stores a
    /// string this build still has to accept.
    func testAsrVersion_unknownStoredString_fallsBackToV3() {
        XCTAssertNil(ParakeetModelVersion(stored: "who-knows"))
        guard case .v3 = AsrModelVersion(storedParakeetVersion: "who-knows") else {
            return XCTFail("an unrecognised stored version must fall back to v3")
        }
    }

    /// Redux's weights are the 219 MB the settings row promises, and they come
    /// from the repo whose name FluidAudio downloads.
    func testReduxRow_describesTheTernaryWeights() {
        let row = try? XCTUnwrap(SettingsFluidAudioModels.availableModels.first { $0.version == "redux" })
        XCTAssertEqual(row?.size, 219)
        XCTAssertEqual(ParakeetModelVersion.redux.huggingFaceRepo, "parakeet-redux-coreml")
        XCTAssertEqual(ParakeetModelVersion.redux.displayName, "Parakeet Redux")
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

@MainActor
final class IndicatorPanelFullScreenTests: XCTestCase {

    func testIndicatorPanel_isVisibleOverFullScreenApps() throws {
        let manager = IndicatorWindowManager.shared
        manager.warmUp()

        let window = try XCTUnwrap(manager.window)

        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAuxiliary),
                      "Panel must join full-screen spaces as an auxiliary window")
        XCTAssertTrue(window.collectionBehavior.contains(.canJoinAllSpaces),
                      "Panel must follow the user across all spaces")
        XCTAssertGreaterThanOrEqual(window.level.rawValue, NSWindow.Level.statusBar.rawValue)
    }
}

final class ClipboardRestoreTests: XCTestCase {

    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("osw-clipboard-test-\(UUID().uuidString)"))
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    private func setString(_ string: String) -> Int {
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(string, forType: .string)
        return pasteboard.changeCount
    }

    func testRestoreIfUnchanged_pasteboardUntouched_restoresOriginal() throws {
        _ = setString("original")
        let saved = try XCTUnwrap(ClipboardUtil.saveCurrentPasteboardContents(from: pasteboard))

        let changeCount = setString("transcription")

        let restored = ClipboardUtil.restoreIfUnchanged(saved, expectedChangeCount: changeCount, pasteboard: pasteboard)

        XCTAssertTrue(restored)
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }

    func testRestoreIfUnchanged_pasteboardChangedMeanwhile_keepsNewContents() throws {
        _ = setString("original")
        let saved = try XCTUnwrap(ClipboardUtil.saveCurrentPasteboardContents(from: pasteboard))

        let changeCount = setString("transcription")
        _ = setString("copied by user during the delay")

        let restored = ClipboardUtil.restoreIfUnchanged(saved, expectedChangeCount: changeCount, pasteboard: pasteboard)

        XCTAssertFalse(restored)
        XCTAssertEqual(pasteboard.string(forType: .string), "copied by user during the delay")
    }

    func testRestoreDelay_coversSlowPasteConsumers() {
        XCTAssertGreaterThanOrEqual(ClipboardUtil.clipboardRestoreDelay, 1.0,
                                    "Browsers and Electron apps can service Cmd+V hundreds of ms after posting")
    }
}

@MainActor
final class MainWindowResolutionTests: XCTestCase {

    func testTitledWindow_isMainAppWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 650),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        XCTAssertTrue(AppDelegate.isMainAppWindow(window))
    }

    func testBorderlessPanel_isNotMainAppWindow() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        XCTAssertFalse(AppDelegate.isMainAppWindow(panel))
    }

    func testBorderlessWindow_isNotMainAppWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        XCTAssertFalse(AppDelegate.isMainAppWindow(window))
    }
}

final class StartHiddenPreferenceTests: XCTestCase {

    private let key = "startHiddenInMenuBar"
    private var originalValue: Any?

    override func setUp() {
        super.setUp()
        originalValue = AppPreferences.defaults.object(forKey: key)
        AppPreferences.defaults.removeObject(forKey: key)
    }

    override func tearDown() {
        if let originalValue {
            AppPreferences.defaults.set(originalValue, forKey: key)
        } else {
            AppPreferences.defaults.removeObject(forKey: key)
        }
        super.tearDown()
    }

    func testStartHiddenInMenuBar_defaultsToFalse() {
        XCTAssertFalse(AppPreferences.shared.startHiddenInMenuBar)
    }

    func testStartHiddenInMenuBar_persistsChanges() {
        AppPreferences.shared.startHiddenInMenuBar = true
        XCTAssertTrue(AppPreferences.shared.startHiddenInMenuBar)
        XCTAssertTrue(AppPreferences.defaults.bool(forKey: key))

        AppPreferences.shared.startHiddenInMenuBar = false
        XCTAssertFalse(AppPreferences.shared.startHiddenInMenuBar)
    }
}
