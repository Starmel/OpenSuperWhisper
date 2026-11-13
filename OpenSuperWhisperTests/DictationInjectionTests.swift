import Foundation
import GRDB
import XCTest
@testable import OpenSuperWhisper

/// Returns one prepared transcript per call, so two consecutive dictations can
/// be told apart without a model.
private final class ScriptedTranscriptionEngine: TranscriptionEngine {
    var isModelLoaded: Bool { true }
    var engineName: String { "Scripted test engine" }

    private let lock = NSLock()
    private var remaining: [String]

    init(transcripts: [String]) { remaining = transcripts }

    func initialize() async throws {}

    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard !remaining.isEmpty else { return "" }
        return remaining.removeFirst()
    }

    func cancelTranscription() {}

    func getSupportedLanguages() -> [String] { ["en"] }
}

/// Hands out the recording URLs the view model will stop, in order. The decode
/// pipeline moves each one into the recordings directory, so every dictation
/// needs its own source file.
private final class RecordingURLQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL]

    init(count: Int) {
        urls = (0..<count).map { _ in
            FileManager.default.temporaryDirectory
                .appendingPathComponent("osw-injection-\(UUID().uuidString).wav")
        }
    }

    var createdURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }

    func next() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return urls.isEmpty ? nil : urls.removeFirst()
    }
}

/// The captain's failure: transcription is saved every time, but the synthetic
/// keystrokes stop arriving after the first dictation. These tests drive the
/// real decode pipeline through `IndicatorViewModel` with a stubbed engine, so
/// the question "does the app reach the injection call on the second
/// dictation?" is answered deterministically instead of by dictating.
@MainActor
final class DictationInjectionTests: XCTestCase {
    private var temporaryFiles: [URL] = []

    override func setUp() {
        // The dictation pipeline reads one shared recording session, so a
        // session left behind by another test would redirect `startDecoding()`
        // into someone else's stop closure.
        RecordingSessionController.shared.finish(RecordingSessionController.shared.currentID)
        super.setUp()
    }

    override func tearDown() {
        for url in temporaryFiles {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryFiles = []
        AppErrorCenter.shared.issue = nil
        super.tearDown()
    }

    private func makeStore() throws -> RecordingStore {
        try RecordingStore(databaseQueue: DatabaseQueue())
    }

    /// These tests are about the injection hook, not about the transform gate.
    /// An identity transform keeps them independent of the user's tone and
    /// clean-up switches — and of whether any transform weights are installed.
    private static let passthroughTransform: (String, String?, Bool) async -> TransformService.TransformOutcome = { text, _, _ in
        TransformService.TransformOutcome(text: text, policy: nil, didRunModel: false)
    }

    /// Auto-paste must be on for the injection path to run. Pin it, but write
    /// nothing when the domain already holds what the test needs: a test host
    /// without a distinct bundle id would otherwise write the preferences of the
    /// app someone is using.
    private func pinAutoPasteOn() -> () -> Void {
        let preferences = AppPreferences.shared
        guard !preferences.autoPasteTranscription else { return {} }
        preferences.autoPasteTranscription = true
        return { preferences.autoPasteTranscription = false }
    }

    private func makeSourceFiles(count: Int) -> RecordingURLQueue {
        let queue = RecordingURLQueue(count: count)
        for url in queue.createdURLs {
            try? Data([1, 2, 3, 4]).write(to: url)
            temporaryFiles.append(url)
        }
        return queue
    }

    /// Drives one full dictation through the real pipeline and waits for its
    /// injection. Returns without asserting, so the caller decides what the
    /// observable outcome should be.
    private func dictate(_ viewModel: IndicatorViewModel) async throws {
        viewModel.state = .recording
        viewModel.startDecoding()
    }

    private func waitForInjections(_ count: Int, _ injected: () -> [String]) async throws {
        for _ in 0..<200 {
            if injected().count >= count { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    func testTwoConsecutiveDictationsBothReachTheInjectionHook() async throws {
        let transcripts = ["first dictation", "second dictation"]
        let store = try makeStore()
        let sources = makeSourceFiles(count: transcripts.count)
        var injected: [String] = []

        // The injection path is only taken when auto-paste is on.
        let restoreAutoPaste = pinAutoPasteOn()
        defer { restoreAutoPaste() }

        let viewModel = IndicatorViewModel(
            transcriptionService: TranscriptionService(
                engine: ScriptedTranscriptionEngine(transcripts: transcripts)
            ),
            recordingStore: store,
            stopRecording: {
                guard let url = sources.next() else { return nil }
                return RecordedAudio(url: url, samples: [])
            },
            cancelAudioRecording: {},
            injectText: { text in
                injected.append(text)
                return KeyboardSimulator.InjectionResult(trusted: true, eventsPosted: 4)
            },
            transformText: Self.passthroughTransform
        )
        defer { viewModel.cleanup() }

        try await dictate(viewModel)
        try await waitForInjections(1, { injected })
        try await dictate(viewModel)
        try await waitForInjections(2, { injected })

        XCTAssertEqual(
            injected, transcripts,
            "Every dictation must reach the injection hook, not just the first one"
        )

        // The product contract on both counts: saved in history AND typed.
        let rows = try await store.fetchRecordings(limit: 10, offset: 0)
        temporaryFiles.append(contentsOf: rows.map(\.url))
        XCTAssertEqual(rows.count, transcripts.count)
        XCTAssertEqual(Set(rows.map(\.transcription)), Set(transcripts))
        XCTAssertTrue(rows.allSatisfy { $0.status == .completed })
    }

    /// When macOS is discarding the keystrokes the transcript must not look
    /// like it vanished: the user is told, the permission surface is asked to
    /// re-check, and the recording is still saved.
    func testUntrustedInjectionIsReportedToTheUserAndTheDictationIsStillSaved() async throws {
        let store = try makeStore()
        let sources = makeSourceFiles(count: 1)
        var injected: [String] = []

        let restoreAutoPaste = pinAutoPasteOn()
        defer { restoreAutoPaste() }

        let viewModel = IndicatorViewModel(
            transcriptionService: TranscriptionService(
                engine: ScriptedTranscriptionEngine(transcripts: ["nobody received this"])
            ),
            recordingStore: store,
            stopRecording: {
                guard let url = sources.next() else { return nil }
                return RecordedAudio(url: url, samples: [])
            },
            cancelAudioRecording: {},
            injectText: { text in
                injected.append(text)
                return KeyboardSimulator.InjectionResult(trusted: false, eventsPosted: 0)
            },
            transformText: Self.passthroughTransform
        )
        defer { viewModel.cleanup() }
        AppErrorCenter.shared.issue = nil

        let recheck = expectation(description: "permission surface asked to re-check")
        let observer = NotificationCenter.default.addObserver(
            forName: .accessibilityPermissionNeededForInjection,
            object: nil,
            queue: .main
        ) { _ in recheck.fulfill() }
        defer { NotificationCenter.default.removeObserver(observer) }

        try await dictate(viewModel)
        try await waitForInjections(1, { injected })
        await fulfillment(of: [recheck], timeout: 2)

        XCTAssertEqual(injected, ["nobody received this"])
        let issue = try XCTUnwrap(
            AppErrorCenter.shared.issue,
            "A dictation that was not typed must be reported, never dropped silently"
        )
        XCTAssertTrue(issue.message.contains("Accessibility"))

        let rows = try await store.fetchRecordings(limit: 10, offset: 0)
        temporaryFiles.append(contentsOf: rows.map(\.url))
        XCTAssertEqual(rows.map(\.transcription), ["nobody received this"])
    }

    /// The third way a delivery reaches nowhere, and the one that looks
    /// delivered because there is nothing to see afterwards: the app is trusted,
    /// the target never changed, and the mechanism still handed the system no
    /// event at all — no keystrokes, or no ⌘V. The user is told which mechanism
    /// could not be built, and the dictation is still in the history.
    func testADeliveryThatPostedNothingIsReportedToTheUser() async throws {
        let store = try makeStore()
        let sources = makeSourceFiles(count: 1)
        var injected: [String] = []

        let restoreAutoPaste = pinAutoPasteOn()
        defer { restoreAutoPaste() }

        let viewModel = IndicatorViewModel(
            transcriptionService: TranscriptionService(
                engine: ScriptedTranscriptionEngine(transcripts: ["typed nowhere"])
            ),
            recordingStore: store,
            stopRecording: {
                guard let url = sources.next() else { return nil }
                return RecordedAudio(url: url, samples: [])
            },
            cancelAudioRecording: {},
            injectText: { text in
                injected.append(text)
                return KeyboardSimulator.InjectionResult(trusted: true,
                                                        eventsPosted: 0,
                                                        mechanism: .clipboardPaste)
            },
            transformText: Self.passthroughTransform
        )
        defer { viewModel.cleanup() }
        AppErrorCenter.shared.issue = nil

        try await dictate(viewModel)
        try await waitForInjections(1, { injected })

        XCTAssertEqual(injected, ["typed nowhere"])
        let issue = try XCTUnwrap(
            AppErrorCenter.shared.issue,
            "a trusted, uninterrupted delivery that posted nothing reached nowhere and must say so"
        )
        XCTAssertTrue(issue.title.contains("not typed"), "unexpected title: \(issue.title)")
        XCTAssertTrue(
            issue.message.contains("⌘V"),
            "the report has to name what could not be built for the mechanism that ran: \(issue.message)"
        )
        XCTAssertTrue(
            issue.message.contains("History"),
            "the report has to say where the transcript is: \(issue.message)"
        )

        let rows = try await store.fetchRecordings(limit: 10, offset: 0)
        temporaryFiles.append(contentsOf: rows.map(\.url))
        XCTAssertEqual(rows.map(\.transcription), ["typed nowhere"])
    }

    /// The clipboard path's failure mode is invisible from this side: a session
    /// whose clipboard is not shared receives nothing at all, and nothing this app
    /// can observe says so. So the first dictation that goes through the clipboard
    /// says what happened, why, and where the switch is — once, not on every
    /// dictation.
    func testTheFirstClipboardDeliveryIsAnnouncedAndOnlyTheFirst() async throws {
        let store = try makeStore()
        let sources = makeSourceFiles(count: 2)
        var injected: [String] = []

        let restoreAutoPaste = pinAutoPasteOn()
        defer { restoreAutoPaste() }
        let explainedBefore = AppPreferences.shared.clipboardDeliveryExplained
        AppPreferences.shared.clipboardDeliveryExplained = false
        defer { AppPreferences.shared.clipboardDeliveryExplained = explainedBefore }

        let viewModel = IndicatorViewModel(
            transcriptionService: TranscriptionService(
                engine: ScriptedTranscriptionEngine(transcripts: ["first", "second"])
            ),
            recordingStore: store,
            stopRecording: {
                guard let url = sources.next() else { return nil }
                return RecordedAudio(url: url, samples: [])
            },
            cancelAudioRecording: {},
            injectText: { text in
                injected.append(text)
                return KeyboardSimulator.InjectionResult(trusted: true,
                                                        eventsPosted: 2,
                                                        mechanism: .clipboardPaste)
            },
            transformText: Self.passthroughTransform
        )
        defer { viewModel.cleanup() }
        AppErrorCenter.shared.issue = nil

        try await dictate(viewModel)
        try await waitForInjections(1, { injected })

        let issue = try XCTUnwrap(
            AppErrorCenter.shared.issue,
            "the first dictation through the clipboard has to say so: its failure mode is silent"
        )
        XCTAssertTrue(issue.title.contains("clipboard"), "unexpected title: \(issue.title)")
        XCTAssertTrue(
            issue.message.contains("Keystrokes only"),
            "the notice has to name the switch that turns the clipboard path off: \(issue.message)"
        )
        XCTAssertEqual(AppPreferences.shared.clipboardDeliveryExplained, true)

        // The second delivery says nothing more: the switch and the record carry
        // it from here.
        AppErrorCenter.shared.issue = nil
        try await dictate(viewModel)
        try await waitForInjections(2, { injected })
        XCTAssertNil(AppErrorCenter.shared.issue, "the notice is once per install, not per dictation")

        let rows = try await store.fetchRecordings(limit: 10, offset: 0)
        temporaryFiles.append(contentsOf: rows.map(\.url))
        XCTAssertEqual(rows.count, 2)
    }

    /// An interference that stopped the delivery has to reach the user the same
    /// way the untrusted case does — which interference ended it and how much of
    /// the dictation got through — instead of leaving a truncated paste with no
    /// explanation. Both kinds are driven, because each one has its own sentence
    /// in the report.
    func testInterruptedInjectionIsReportedToTheUser() async throws {
        let store = try makeStore()
        let sources = makeSourceFiles(count: 2)

        let restoreAutoPaste = pinAutoPasteOn()
        defer { restoreAutoPaste() }

        let cases: [(KeyboardSimulator.DeliveryInterruption, String)] = [
            (.focusChanged, "Another application came to the front"),
            (.userTyping, "You started typing"),
        ]

        for (interruption, whatHappened) in cases {
            var injected: [String] = []
            let viewModel = IndicatorViewModel(
                transcriptionService: TranscriptionService(
                    engine: ScriptedTranscriptionEngine(transcripts: ["a dictation that was stopped"])
                ),
                recordingStore: store,
                stopRecording: {
                    guard let url = sources.next() else { return nil }
                    return RecordedAudio(url: url, samples: [])
                },
                cancelAudioRecording: {},
                injectText: { text in
                    injected.append(text)
                    return KeyboardSimulator.InjectionResult(
                        trusted: true,
                        eventsPosted: 6,
                        interruptedBy: interruption,
                        deliveredCharacters: 3
                    )
                },
                transformText: Self.passthroughTransform
            )
            defer { viewModel.cleanup() }
            AppErrorCenter.shared.issue = nil

            try await dictate(viewModel)
            try await waitForInjections(1, { injected })

            let issue = try XCTUnwrap(
                AppErrorCenter.shared.issue,
                "a delivery stopped by \(interruption) must be reported, never left looking truncated"
            )
            XCTAssertTrue(
                issue.title.contains("not typed in full"),
                "unexpected title: \(issue.title)"
            )
            XCTAssertTrue(
                issue.message.contains(whatHappened),
                "the report must say which interference ended the delivery: \(issue.message)"
            )
            XCTAssertTrue(
                issue.message.contains("3 of the dictation's"),
                "the report must say how much of the dictation was delivered: \(issue.message)"
            )
            XCTAssertTrue(
                issue.message.contains("History"),
                "the report must say where the rest of the dictation is: \(issue.message)"
            )
        }
    }

    /// The pipeline, made visible. After a dictation the app has to be able to
    /// show which language the engine heard, the raw transcript it saved, what
    /// the clean-up removed, and what was actually pasted — the captain could
    /// see none of it, which is why an English-only model inventing English
    /// looked exactly like a broken translation.
    func testTheDictationReportCarriesTheLanguageAndTheRawToFinalTrio() async throws {
        let store = try makeStore()
        let sources = makeSourceFiles(count: 1)
        var injected: [String] = []

        let restoreAutoPaste = pinAutoPasteOn()
        defer { restoreAutoPaste() }

        let reports = DictationReportCenter()
        let raw = "So hmm, uh, this is the first dictation."
        let cleaned = "So, this is the first dictation."
        let pasted = "So this is the first dictation."

        let viewModel = IndicatorViewModel(
            transcriptionService: TranscriptionService(
                engine: StubLanguageWhisperEngine(text: raw, language: "en")
            ),
            recordingStore: store,
            stopRecording: {
                guard let url = sources.next() else { return nil }
                return RecordedAudio(url: url, samples: [])
            },
            cancelAudioRecording: {},
            injectText: { text in
                injected.append(text)
                return KeyboardSimulator.InjectionResult(trusted: true, eventsPosted: 4)
            },
            transformText: { _, _, _ in
                TransformService.TransformOutcome(
                    text: pasted,
                    policy: .cleanUp(language: .english),
                    didRunModel: true
                )
            },
            cleanUp: { DictationScrubber.scrub($0) },
            cleanUpEnabled: { true },
            reportCenter: reports
        )
        defer { viewModel.cleanup() }

        try await dictate(viewModel)
        try await waitForInjections(1, { injected })

        // The clean-up ran on the raw transcript and the transform ran on what
        // it left, so the three texts are all different on purpose. What reached
        // the keyboard is the transform's output, not the raw transcript — the
        // trailing space is the app's separate "add a space after a sentence"
        // switch (on by default), which is not what this test is about.
        XCTAssertEqual(injected.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }, [pasted])
        let report = try XCTUnwrap(reports.last, "every dictation must publish a report")
        XCTAssertEqual(report.language, "en")
        XCTAssertEqual(report.languageLabel, "English")
        XCTAssertEqual(report.raw, raw)
        XCTAssertEqual(report.cleaned, cleaned)
        XCTAssertEqual(report.final, pasted)
        XCTAssertEqual(report.policy, .cleanUp(language: .english))
        XCTAssertTrue(report.didRunModel)
        XCTAssertTrue(report.changedAnything)
        XCTAssertEqual(report.removedFillers, 2)
        XCTAssertEqual(report.scrubSummary, "removed 2 fillers")
        XCTAssertEqual(report.transformLabel, "English, clean-up only")

        // History keeps the raw transcript, not the cleaned or the pasted text.
        let rows = try await store.fetchRecordings(limit: 10, offset: 0)
        temporaryFiles.append(contentsOf: rows.map(\.url))
        XCTAssertEqual(rows.map(\.transcription), [raw])
    }

    /// A tone answer the guard throws away is **visible**. Before this the
    /// rejection was recorded in the service and dropped on the way to the
    /// surface: the report named the tone policy as if it had run (`didRunModel:
    /// true`) and the notice — the user's only explanation for their own words
    /// coming back — was never shown with the dictation.
    func testTheDictationReportCarriesAGuardedRejection() async throws {
        let store = try makeStore()
        let sources = makeSourceFiles(count: 1)
        var injected: [String] = []

        let restoreAutoPaste = pinAutoPasteOn()
        defer { restoreAutoPaste() }

        let reports = DictationReportCenter()
        let raw = "Please send the report to the client today."
        let rejection = TransformGuardRejection.assistantFrame("sure")
        let policy = TransformPolicy.tone(language: .english, tone: .formal)

        let viewModel = IndicatorViewModel(
            transcriptionService: TranscriptionService(
                engine: StubLanguageWhisperEngine(text: raw, language: "en")
            ),
            recordingStore: store,
            stopRecording: {
                guard let url = sources.next() else { return nil }
                return RecordedAudio(url: url, samples: [])
            },
            cancelAudioRecording: {},
            injectText: { text in
                injected.append(text)
                return KeyboardSimulator.InjectionResult(trusted: true, eventsPosted: 4)
            },
            // The service's own outcome when the guard refuses the answer: the
            // transcript is what was pasted, with the reason kept.
            transformText: { _, _, _ in
                TransformService.TransformOutcome(
                    text: raw,
                    policy: policy,
                    didRunModel: true,
                    guardRejection: rejection
                )
            },
            cleanUp: { DictationScrubber.scrub($0) },
            cleanUpEnabled: { false },
            reportCenter: reports
        )
        defer { viewModel.cleanup() }

        try await dictate(viewModel)
        try await waitForInjections(1, { injected })

        XCTAssertEqual(injected.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }, [raw])
        let report = try XCTUnwrap(reports.last, "every dictation must publish a report")
        XCTAssertEqual(report.guardRejection, rejection, "the reason the answer was thrown away")
        XCTAssertEqual(report.guardNotice, rejection.notice, "the notice the user saw")
        XCTAssertFalse(report.changedAnything, "the user's own words came back")
        XCTAssertNotEqual(
            report.transformLabel,
            policy.summary,
            "a rejected answer must not read as the tone policy having run"
        )
    }
}
