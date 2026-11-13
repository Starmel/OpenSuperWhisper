import AppKit
import KeyboardShortcuts
import XCTest
@testable import OpenSuperWhisper

/// The suite must not be able to change — or be changed by — the state of the
/// machine it runs on: the preferences of the app the developer is running, those
/// of another suite running in parallel, or the whisper model that app has
/// selected.
///
/// Both are the same defect one level apart. For preferences it is a property of
/// *where* `AppPreferences` reads and writes, so it is asserted here instead of
/// being re-checked in every test that touches a switch: with the app's own
/// domain behind it, two suites that inject different `GateSettings` would
/// disagree about `toneEnabled` depending on which process wrote last, and a
/// test that flips a switch would be flipping it for every other class running
/// in parallel. For the
/// model it is a property of how a test gets one: the tests hand their fixture to
/// `WhisperEngine(modelPath:)`, because `selectedWhisperModelPath` describes the
/// machine, not the test.
final class PreferenceIsolationTests: XCTestCase {
    func testTheSuiteDoesNotRunAgainstTheApplicationsOwnPreferences() {
        XCTAssertFalse(
            AppPreferences.defaults === UserDefaults.standard,
            "the suite is reading and writing the app's own preference domain")
    }

    func testAPreferenceWrittenUnderTestStaysOutOfTheApplicationDomain() {
        let key = "preferenceIsolationProbe"
        AppPreferences.defaults.set("scratch", forKey: key)

        XCTAssertEqual(AppPreferences.defaults.string(forKey: key), "scratch")
        XCTAssertNil(
            UserDefaults.standard.object(forKey: key),
            "a preference written by the suite must never reach the app's own domain")
    }

    /// The two writers `AppPreferences.defaults` cannot cover are off under test.
    ///
    /// `AppPreferences` says *where* the app's own values live; these two are not
    /// app values and hard-code `UserDefaults.standard` themselves. The
    /// `KeyboardShortcuts` library stores a name's declared combination there the
    /// first time the name is touched (`setInitialShortcutIfNeeded`), and AppKit
    /// autosaves `NSWindow Frame …` for any window a process shows with an
    /// autosave name. Under the app's bundle id — which is where the test bundle
    /// runs — that is the domain the app the developer is using reads, and no test
    /// puts either of them back. So neither may be written: the escape name
    /// declares no combination under test, and no window of a test process keeps
    /// the autosave name SwiftUI gives it.
    @MainActor
    func testTheAppWritesNeitherShortcutCombinationsNorWindowFramesIntoTheApplicationDomain() {
        // What the app itself does to the escape name: declare it, and (from
        // `ShortcutManager.setupKeyboardShortcuts` and the indicator) disable it.
        let storedEscape = UserDefaults.standard.object(forKey: "KeyboardShortcuts_escape")
        XCTAssertNil(
            KeyboardShortcuts.Name.escape.initialShortcut,
            "the escape name declares a combination under test; the library stores it in the app's own domain")
        _ = KeyboardShortcuts.Name.escape
        KeyboardShortcuts.disable(.escape)
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: "KeyboardShortcuts_escape"),
            storedEscape as? String,
            "touching the escape shortcut wrote it into the app's own domain")

        // The window the app puts on screen is the one SwiftUI gives an autosave
        // name to, and the name is what lets AppKit write a frame into the same
        // domain when that window moves, closes, or the process quits.
        let autosaved = NSApplication.shared.windows
            .map(\.frameAutosaveName)
            .filter { !$0.isEmpty }
        XCTAssertTrue(
            autosaved.isEmpty,
            "a window of this process still autosaves its frame: \(autosaved.joined(separator: ", "))")
    }

    /// The model a test transcribes with is an argument, never a preference.
    ///
    /// `selectedWhisperModelPath` belongs to whoever last ran the app (the
    /// captain's is a multilingual model, chosen because the English-only one
    /// hallucinated English from his Polish speech). A test that resolved its
    /// model from it would measure that machine instead of the fixture — and an
    /// engine handed an explicit model must ignore it even when it is set to
    /// something unusable.
    func testAnEngineWithAnExplicitModelIgnoresTheSelectedModelPreference() async throws {
        let key = "selectedWhisperModelPath"
        let planted = AppPreferences.defaults.string(forKey: key)
        AppPreferences.defaults.set("/nonexistent/model-from-the-machine.bin", forKey: key)
        defer {
            if let planted {
                AppPreferences.defaults.set(planted, forKey: key)
            } else {
                AppPreferences.defaults.removeObject(forKey: key)
            }
        }

        let engine = WhisperEngine(modelPath: try TestFixtures.tinyEnglishModel().path)
        // Would throw contextInitializationFailed if the engine had used the
        // preference instead of the model it was given.
        try await engine.initialize()
        XCTAssertTrue(engine.isModelLoaded)
        engine.unload()
    }

    /// The fixtures resolve from the test's own opt-in and the checkout, so a
    /// machine whose selection is unusable still runs the same tests.
    func testTheFixturesResolveWithoutAnyPreference() throws {
        let key = "selectedWhisperModelPath"
        let planted = AppPreferences.defaults.string(forKey: key)
        AppPreferences.defaults.set("/nonexistent/model-from-the-machine.bin", forKey: key)
        defer {
            if let planted {
                AppPreferences.defaults.set(planted, forKey: key)
            } else {
                AppPreferences.defaults.removeObject(forKey: key)
            }
        }

        let english = try TestFixtures.tinyEnglishModel()
        XCTAssertTrue(FileManager.default.fileExists(atPath: english.path))
        XCTAssertTrue(english.lastPathComponent.hasPrefix("ggml-tiny.en"))
    }
}
