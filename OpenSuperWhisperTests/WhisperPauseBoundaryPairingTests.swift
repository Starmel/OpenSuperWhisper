import Foundation
import XCTest

@testable import OpenSuperWhisper

/// fm-20260925-14: does a deliberate decoder prompt **pair** with "long pauses
/// end the sentence"?
///
/// This harness answered that question on the captain's own recordings and got
/// **refused with evidence**: with the switch on the English control is never
/// word-identical to the switch-off/none control, and the shortest difference any
/// prompt reaches is two words (`-how -sentence +now +sentences`), present in the
/// arm that sends no prompt at all. The captain was given the measurement and
/// chose **option (a)** — "pause fix everywhere, English takes a 2-word change" —
/// accepted on **2026-09-25** with those numbers in front of him. So the switch
/// ships on with a decoder prompt chosen by the language spoken (the detect-only
/// pre-pass), and the change this file now pins is the accepted one rather than a
/// clean English control: the criterion case at the bottom asserts the two-word
/// English delta exactly, so a future change that quietly widens it fails.
///
/// The measurement itself is unchanged: the switch on with a deliberate decoder
/// prompt as the arm, and the **switch-off/none** arm — the app as it shipped
/// before this decision — as the baseline every arm is diffed against, word by
/// word. A prompt that fixes the punctuation by changing the words is not a win,
/// so the deltas are words, not marks.
///
/// Opt-in twice over, exactly like the pause measurement: `OSW_TEST_CAPTAIN_RECORDINGS`
/// has to name the directory and a multilingual model has to be available. With
/// either missing the cases skip, which is the state CI runs in.
///
/// The arms, per recording:
///
/// * `off / none` — the control: today's app. Everything else is a delta against it.
/// * `on / none`, `on / attributed`, `on / c1 (pl)`, `on / c2 (pl)`,
///   `on / c3 (pl, no commas)`, `on / c1 EN` — the switch on with each prompt.
/// * `off / attributed`, `off / c1 (pl)`, `off / c1 EN` — the prompt on its own,
///   so a change can be attributed to the prompt rather than the switch.
/// * `on / none`, decoded twice, as the determinism anchor.
///
/// **On the shipped engine an empty stored prompt is not "no prompt".** With the
/// switch on and no prompt of the user's own, `performTranscription` measures the
/// language and sends the default that language has, so the `none` column of a
/// switch-**on** arm in these tables *is* that default (Polish: `c3 (pl)`;
/// English: `c1 EN`), and the arms differ only in what reached the decoder. The
/// switch-**off** control is unaffected — off sends no prompt at all — which is
/// why it is still the baseline every arm is diffed against.
///
/// Everything judgemental (which prompt is better, how wide an arm's English
/// delta is) is **reported**, not asserted; the assertions are the structural
/// ones — the engine's transcript is the assembler's output and no long pause is
/// left inside a sentence on an `on` arm — plus the one configuration the app
/// actually ships, whose accepted English delta is pinned exactly.
final class WhisperPauseBoundaryPairingTests: XCTestCase {

    // MARK: - His recordings

    private struct CaptainRecording {
        let label: String
        let fileName: String
        /// The Polish win the brief states, exactly: what has to survive for a
        /// pairing to pass on this recording. `nil` on the English control, whose
        /// criterion is the accepted two-word change instead — see
        /// `acceptedEnglishChange`.
        let win: Win?
        /// The transcript the app itself stored for it — the check that this
        /// harness really is the app's own decode path.
        let storedTranscript: String
    }

    /// The words the brief requires a pairing to keep.
    private struct Win {
        /// Substrings that must appear. Case-sensitive on purpose: `Dodałem` is
        /// the word the dissolved pause cost, and `dałem` is the word it left.
        let mustContain: [String]
        /// The arm has to read one more sentence than the switch-off/none
        /// control: `pl-1` gains the boundary at the long pause.
        let mustGainASentence: Bool
    }

    private static let recordings = [
        CaptainRecording(
            label: "pl-1 (12.1 s)",
            fileName: "5C68BFAC-5EC8-45CC-8239-3B5659272C1A.wav",
            win: Win(mustContain: ["drogą."], mustGainASentence: true),
            storedTranscript: "Dobra ziameczku tak nie możesz tego zrobić. Musisz pójść zupełnie inną drogą. "
                + "Bo tu chodzi o to że żeś pieprzył po całości."
        ),
        CaptainRecording(
            label: "pl-2 (23.3 s)",
            fileName: "B2EA9010-97C9-40AB-A7A2-746323A45297.wav",
            win: Win(mustContain: ["Open Super Whisper", "Dodałem"], mustGainASentence: false),
            storedTranscript: "Dobra wiadomość jest taka, że odzyskałem swój polski. Udało mi się zrobić fork. "
                + "Ben super whisper. Dałem drugi model. Jestem. Znowu po polsku."
        ),
        CaptainRecording(
            label: "en control (33.0 s)",
            fileName: "D92A0B10-EB8D-4D47-80B9-A9F3A88C112F.wav",
            win: nil,
            storedTranscript: "Also add feature to ignore pauses. Basically how it creates a sentence without "
                + "a sense because of my long pauses. The pauses need to be ignored."
        ),
    ]

    // MARK: - The decoder prompts, as arms

    private struct PromptArm {
        let label: String
        let prompt: String
    }

    /// The instruction-shaped string the earlier brief reported finding in his
    /// preferences. It is **not** in the app (no commit ever contained it, the
    /// code default is the empty string) and this brief forbids shipping it as a
    /// default however well it scores, because it is exactly the shape this
    /// project documented as a hallucination trigger. It is measured here
    /// because it is one of the four arms the brief names.
    private static let attributedPrompt =
        "You are a transcriber. Your role is just to clean up the text and make it look pretty and attractive. "
        + "Do not change the sense of the sentences."

    /// Ordinary Polish dictation with full punctuation, a proper noun, a comma, a
    /// colon and a question mark — no instruction and no meta-commentary.
    private static let candidateOne = "Dobra, jeszcze raz: wysłałem raport w poniedziałek, ale Anna nie "
        + "odpowiedziała. Możesz to sprawdzić?"
    private static let candidateTwo = "Tak, zgadza się. Kiedy? Nie wiem, ale sprawdzę to jutro."

    /// The English counterpart of candidate one, for the English control.
    private static let candidateOneEnglish = "Okay, one more time: I sent the report on Monday, but Anna hasn't "
        + "replied. Can you check?"

    /// **The knock-out probe for the comma hypothesis.** Candidate 1 and 2 are
    /// comma-heavy, and on `pl-1` both *add* commas and merge the boundary the
    /// switch had gained. The attributed string does the opposite — it loses the
    /// commas — so if the attributed arm is the only one that keeps `pl-1`'s
    /// boundary, the cause may be comma priming rather than instruction. This
    /// prompt is text-shaped Polish dictation with full stops and questions and
    /// **no commas at all**, so the two explanations can be told apart.
    private static let candidateThree = "Zrobiłem to wczoraj. Sprawdzę to jutro. Możesz na to spojrzeć? "
        + "Nie ma problemu."

    private static let promptArms: [PromptArm] = [
        PromptArm(label: "none (the shipped default)", prompt: ""),
        PromptArm(label: "attributed (instruction-shaped)", prompt: attributedPrompt),
        PromptArm(label: "c1 (pl)", prompt: candidateOne),
        PromptArm(label: "c2 (pl)", prompt: candidateTwo),
        PromptArm(label: "c3 (pl, no commas)", prompt: candidateThree),
        PromptArm(label: "c1 EN", prompt: candidateOneEnglish),
    ]

    /// The key every arm is diffed against: today's app, byte for byte the audio
    /// every earlier build decoded.
    private static let controlLabel = "off / none (control)"

    /// The English change the captain accepted on **2026-09-25** with the
    /// measurement in front of him — option (a), "pause fix everywhere, English
    /// takes a 2-word change".
    ///
    /// With the switch on the English control reads "Basically **now** it creates
    /// **a sentences**" where the switch off reads "Basically **how** it creates
    /// **a sentence**". The change is the switch's own audio half rather than the
    /// prompt's: it is there in the arm that sends no prompt at all, it is
    /// identical for two different prompts, and none of the six prompts moves it —
    /// which is exactly why the choice was this and not a cleaner control. The
    /// shipped configuration is asserted against **exactly** these two words, so a
    /// future change that widens the English damage fails the suite instead of
    /// passing it quietly.
    private static let acceptedEnglishChange = (
        removed: ["how", "sentence"],
        added: ["now", "sentences"]
    )

    /// The policies. The control is upstream's audio (`maxPause: 0`, the 0.1 s of
    /// zeros) with the shipped threshold and tolerance kept so the *junctions*
    /// are measurable on it too — the same construction the pause measurement
    /// used, so these tables and its tables are directly comparable.
    private static let controlPolicy = WhisperEngine.PauseBoundaryPolicy(
        maxPause: WhisperEngine.PauseBoundaryPolicy.upstream.maxPause,
        minPause: WhisperEngine.PauseBoundaryPolicy.upstream.minPause,
        sentenceThreshold: WhisperEngine.PauseBoundaryPolicy.restored.sentenceThreshold,
        boundaryTolerance: WhisperEngine.PauseBoundaryPolicy.restored.boundaryTolerance,
        closesSentence: false
    )

    private static let switchOnPolicy = WhisperEngine.PauseBoundaryPolicy.restored

    // MARK: - Fixtures

    private func recordingsDirectory() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["OSW_TEST_CAPTAIN_RECORDINGS"], !path.isEmpty else {
            throw XCTSkip(
                "OSW_TEST_CAPTAIN_RECORDINGS is not set: the captain's recordings are not on this machine"
            )
        }
        let directory = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip("OSW_TEST_CAPTAIN_RECORDINGS points at no directory: \(path)")
        }
        return directory
    }

    /// His settings, as they reach the decoder. The pause policy and the decoder
    /// prompt are the arm, not the preference, so one process measures all of
    /// them.
    private func captainSettings(initialPrompt: String, longPausesEndSentences: Bool) -> Settings {
        var settings = Settings()
        settings.showTimestamps = false
        settings.temperature = 0
        settings.noSpeechThreshold = 0.6
        settings.suppressBlankAudio = true
        settings.useBeamSearch = false
        settings.initialPrompt = initialPrompt
        settings.longPausesEndSentences = longPausesEndSentences
        return settings
    }

    /// Whisper's own cleaning, as `performTranscription` applies it.
    private func cleaned(_ text: String) -> String {
        text
            .replacingOccurrences(of: "[MUSIC]", with: "")
            .replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sentences(_ text: String) -> [String] {
        let terminators: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if terminators.contains(character) {
                let sentence = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sentence.isEmpty { result.append(sentence) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(tail) }
        return result
    }

    private func wordCount(_ sentence: String) -> Int {
        sentence.split(whereSeparator: { $0.isWhitespace }).count
    }

    private func punctuationCounts(_ text: String) -> String {
        let marks: [Character] = [".", ",", "?", "!", ":", ";", "…", "—", "\""]
        return marks
            .map { mark in "\(mark)\(text.filter { $0 == mark }.count)" }
            .joined(separator: " ")
    }

    /// The words in `text` that are not in `baseline` and the ones that are,
    /// counted so a repeated word counts once per repetition. Punctuation and
    /// case are ignored: this is about which *words* an arm moved.
    private func wordDelta(baseline: String, text: String) -> (removed: [String], added: [String]) {
        func words(_ value: String) -> [String] {
            value.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
        }

        var counts: [String: Int] = [:]
        for word in words(baseline) { counts[word, default: 0] += 1 }
        for word in words(text) { counts[word, default: 0] -= 1 }

        let removed = counts.filter { $0.value > 0 }.sorted { $0.key < $1.key }
            .flatMap { Array(repeating: $0.key, count: $0.value) }
        let added = counts.filter { $0.value < 0 }.sorted { $0.key < $1.key }
            .flatMap { Array(repeating: $0.key, count: -$0.value) }
        return (removed, added)
    }

    private func wordsEqual(_ lhs: String, _ rhs: String) -> Bool {
        let delta = wordDelta(baseline: lhs, text: rhs)
        return delta.removed.isEmpty && delta.added.isEmpty
    }

    /// How many long pauses the transcript ran straight through, using the
    /// engine's own junction rule rather than a copy of it.
    private func junctionsLeftOpen(
        in assembly: String,
        texts: [String],
        starts: [Int64],
        endCentiseconds: [Int64],
        pauses: [WhisperEngine.StitchedPause],
        policy: WhisperEngine.PauseBoundaryPolicy,
        terminator: String
    ) -> Int {
        let junctions = WhisperEngine.pauseJunctions(
            decodedStartsCentiseconds: starts,
            decodedEndCentiseconds: endCentiseconds,
            pauses: pauses,
            threshold: policy.sentenceThreshold,
            tolerance: policy.boundaryTolerance
        )
        var open = 0
        for index in junctions {
            let upTo = cleaned(
                WhisperEngine.assembleSegmentTexts(Array(texts[0...index]), showTimestamps: false)
            )
            guard assembly.hasPrefix(upTo) else {
                open += 1
                continue
            }
            let after = assembly.dropFirst(upTo.count)
            if !(WhisperEngine.endsSentence(upTo) || after.hasPrefix(terminator)) {
                open += 1
            }
        }
        return open
    }

    // MARK: - The measurement

    private struct ArmResult {
        let arm: String
        let prompt: String
        let text: String
        let sentences: Int
        let milliseconds: Int
        /// The language this arm's own decode measured — what the shipped path's
        /// pre-pass is compared against.
        let languageAtDecode: String?
    }

    func testTheSwitchPairedWithADecoderPrompt() async throws {
        let directory = try recordingsDirectory()
        let modelURL = try TestFixtures.multilingualModel()
        let vadModelPath = try XCTUnwrap(
            WhisperEngine.vadModelPath,
            "Silero VAD model must be bundled with the app"
        )

        let engine = WhisperEngine(modelPath: modelURL.path)
        try await engine.initialize()
        let vad = try XCTUnwrap(MyWhisperVadContext(modelPath: vadModelPath))

        TestFixtures.report("[pair] ============================================================")
        TestFixtures.report("[pair] model \(modelURL.path)")
        TestFixtures.report("[pair] vad \(vadModelPath)")
        TestFixtures.report(
            "[pair] the control is the switch off with no prompt: upstream's 0.1 s of zeros at every pause. "
                + "Every arm below is diffed against it, word by word."
        )
        TestFixtures.report(
            "[pair] on a switch-on arm an empty stored prompt sends the engine's own default for the language it "
                + "measures (pl: '\(WhisperEngine.defaultDecoderPrompt(forLanguage: "pl"))'; "
                + "en: '\(WhisperEngine.defaultDecoderPrompt(forLanguage: "en"))') — the `none` rows of this "
                + "run's tables are that default, and the switch-off control above sends nothing at all."
        )

        // What each (recording, on-arm) produced, for the verdict table at the end.
        var onTexts: [String: [String: String]] = [:]
        var controlSentences: [String: Int] = [:]
        var controlTexts: [String: String] = [:]

        for recording in Self.recordings {
            let audioURL = directory.appendingPathComponent(recording.fileName)
            guard FileManager.default.fileExists(atPath: audioURL.path) else {
                throw XCTSkip("\(recording.fileName) is not in \(directory.path)")
            }

            let converted = try await engine.convertAudioToPCM(fileURL: audioURL)
            let samples = try XCTUnwrap(converted, "\(recording.fileName) did not convert to PCM")
            let segments = try XCTUnwrap(vad.speechSegments(in: samples))
            reportPauses(recording: recording, samples: samples, segments: segments)

            var results: [ArmResult] = []

            // 1. The control: today's app, byte for byte.
            let control = try await measure(
                engine: engine,
                audioURL: audioURL,
                policy: Self.controlPolicy,
                arm: Self.controlLabel,
                prompt: "",
                recording: recording,
                samples: samples,
                segments: segments,
                baseline: nil,
            )
            controlTexts[recording.label] = control.text
            controlSentences[recording.label] = control.sentences
            results.append(control)
            TestFixtures.report(
                "[pair] \(recording.label) switch-off/none text == the app's stored transcript: "
                    + "\(control.text == recording.storedTranscript)"
            )

            // 2. The switch on with each prompt.
            var on: [String: String] = [:]
            for arm in Self.promptArms {
                let result = try await measure(
                    engine: engine,
                    audioURL: audioURL,
                    policy: Self.switchOnPolicy,
                    arm: "on / \(arm.label)",
                    prompt: arm.prompt,
                    recording: recording,
                    samples: samples,
                    segments: segments,
                    baseline: control.text,
                )
                on[arm.label] = result.text
                results.append(result)
            }
            onTexts[recording.label] = on

            // 3. The prompt on its own, switch off: so a change on an `on` arm
            //    can be attributed to the prompt rather than to the switch.
            for arm in Self.promptArms where !arm.prompt.isEmpty {
                results.append(
                    try await measure(
                        engine: engine,
                        audioURL: audioURL,
                        policy: Self.controlPolicy,
                        arm: "off / \(arm.label)",
                        prompt: arm.prompt,
                        recording: recording,
                        samples: samples,
                        segments: segments,
                        baseline: control.text,
                    )
                )
            }

            // 4. The determinism anchor: whisper is seeded by its own parameters,
            //    so the same arm twice has to be the same text, or a difference
            //    above is sampling rather than the arm.
            let repeatResult = try await measure(
                engine: engine,
                audioURL: audioURL,
                policy: Self.switchOnPolicy,
                arm: "on / none (repeated)",
                prompt: "",
                recording: recording,
                samples: samples,
                segments: segments,
                baseline: control.text,
            )
            results.append(repeatResult)
            let switchOnNone = on["none (the shipped default)"] ?? ""
            TestFixtures.report(
                "[pair] \(recording.label) the same arm twice is identical: "
                    + "\(repeatResult.text == switchOnNone)"
            )

            // 5. The arm under test, reported as one line per recording so the
            //    verdict can be read without the tables.
            reportVerdict(
                recording: recording,
                control: control.text,
                controlSentences: control.sentences,
                on: on
            )

            TestFixtures.report(
                "[pair] \(recording.label) arms decoded: \(results.count) | "
                    + "slowest \(results.map(\.milliseconds).max() ?? 0) ms"
            )
        }

        // The pairing table: every (Polish prompt, English prompt) configuration
        // the app could ship, judged on the brief's own criterion.
        reportConfigurationTable(onTexts: onTexts, controlTexts: controlTexts, controls: controlSentences)
    }

    /// The Polish win and the English cleanliness, per recording, in one place.
    private func reportVerdict(
        recording: CaptainRecording,
        control: String,
        controlSentences: Int,
        on: [String: String]
    ) {
        TestFixtures.report("[pair] ------------------------------------------------------------")
        for (label, text) in on.sorted(by: { $0.key < $1.key }) {
            let delta = wordDelta(baseline: control, text: text)
            let read = sentences(text)
            var flags: [String] = []
            if let win = recording.win {
                let missing = win.mustContain.filter { !text.contains($0) }
                flags.append(missing.isEmpty ? "win-words:yes" : "win-words:NO(\(missing.joined(separator: ",")))")
                if win.mustGainASentence {
                    flags.append(
                        read.count > controlSentences
                            ? "boundary:yes(\(controlSentences)->\(read.count))"
                            : "boundary:NO(\(controlSentences)->\(read.count))"
                    )
                }
            } else {
                let clean = delta.removed.isEmpty && delta.added.isEmpty
                flags.append(clean ? "english-clean:yes" : "english-clean:NO")
            }
            TestFixtures.report(
                "[pair] \(recording.label) | \(label) | sentences \(read.count) | "
                    + "punctuation \(punctuationCounts(text)) | words -\(delta.removed.count) +\(delta.added.count) "
                    + "| \(flags.joined(separator: " "))"
            )
        }
        TestFixtures.report("[pair] ------------------------------------------------------------")
    }

    /// The decision table the brief asks for: for every pair of (Polish prompt,
    /// English prompt) that could ship, does the English control stay clean **and**
    /// the Polish win survive?
    private func reportConfigurationTable(
        onTexts: [String: [String: String]],
        controlTexts: [String: String],
        controls: [String: Int]
    ) {
        let polishLabels = ["none (the shipped default)", "attributed (instruction-shaped)", "c1 (pl)",
                            "c2 (pl)", "c3 (pl, no commas)", "c1 EN"]
        let englishLabels = ["none (the shipped default)", "attributed (instruction-shaped)", "c1 (pl)",
                             "c2 (pl)", "c3 (pl, no commas)", "c1 EN"]
        let englishControl = Self.recordings.first { $0.win == nil }!
        let polishRecordings = Self.recordings.filter { $0.win != nil }

        TestFixtures.report("[pair] ===================== THE PAIRING TABLE =====================")
        TestFixtures.report(
            "[pair] pl prompt × en prompt | english control words vs control | pl-1 boundary | pl-2 words | verdict"
        )
        for polishLabel in polishLabels {
            for englishLabel in englishLabels {
                let englishText = onTexts[englishControl.label]?[englishLabel] ?? ""
                let englishControlText = controlTexts[englishControl.label] ?? ""
                let englishDelta = wordDelta(baseline: englishControlText, text: englishText)
                let englishClean = englishDelta.removed.isEmpty && englishDelta.added.isEmpty

                var polishPass = true
                var columns: [String] = []
                for recording in polishRecordings {
                    guard let win = recording.win else { continue }
                    let text = onTexts[recording.label]?[polishLabel] ?? ""
                    let missing = win.mustContain.filter { !text.contains($0) }
                    let gained = !win.mustGainASentence
                        || sentences(text).count > (controls[recording.label] ?? 0)
                    let passed = missing.isEmpty && gained
                    polishPass = polishPass && passed
                    columns.append(passed ? "yes" : "NO")
                }

                TestFixtures.report(
                    "[pair] \(polishLabel) × \(englishLabel) | "
                        + "\(englishClean ? "clean" : "NO -\(englishDelta.removed.count) +\(englishDelta.added.count)") | "
                        + columns.joined(separator: " | ") + " | "
                        + (englishClean && polishPass ? "PASS" : "FAIL")
                )
            }
        }
        TestFixtures.report("[pair] ============================================================")
    }

    // MARK: - One arm

    @discardableResult
    private func measure(
        engine: WhisperEngine,
        audioURL: URL,
        policy: WhisperEngine.PauseBoundaryPolicy,
        arm: String,
        prompt: String,
        recording: CaptainRecording,
        samples: [Float],
        segments: [WhisperVadSegment],
        baseline: String?
    ) async throws -> ArmResult {
        let stitched = WhisperEngine.stitch(from: samples, segments: segments, policy: policy)
        let started = Date()
        let detailed = try await engine.transcribeAudioDetailed(
            url: audioURL,
            settings: captainSettings(
                initialPrompt: prompt,
                longPausesEndSentences: policy.closesSentence
            ),
            pausePolicy: policy
        )
        let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
        let text = cleaned(detailed.text)
        let texts = detailed.segments.map(\.text)
        let starts = detailed.segments.map(\.startTimeCentiseconds)
        let ends = detailed.segments.map(\.endTimeCentiseconds)
        let terminator = WhisperEngine.sentenceTerminator(forLanguage: detailed.language)
        let boundaries = WhisperEngine.sentenceBoundaries(
            decodedStartsCentiseconds: starts,
            decodedEndCentiseconds: ends,
            pauses: stitched.pauses,
            policy: policy,
            terminator: terminator
        )
        let runOn = cleaned(WhisperEngine.assembleSegmentTexts(texts, showTimestamps: false))
        let withBoundaries = cleaned(
            WhisperEngine.assembleSegmentTexts(texts, showTimestamps: false, sentenceBoundaries: boundaries)
        )
        let read = sentences(text)
        let junctions = WhisperEngine.pauseJunctions(
            decodedStartsCentiseconds: starts,
            decodedEndCentiseconds: ends,
            pauses: stitched.pauses,
            threshold: policy.sentenceThreshold,
            tolerance: policy.boundaryTolerance
        )
        let ignoredByTheDecoder = junctionsLeftOpen(
            in: runOn,
            texts: texts,
            starts: starts,
            endCentiseconds: ends,
            pauses: stitched.pauses,
            policy: policy,
            terminator: terminator
        )
        let stillOpen = junctionsLeftOpen(
            in: withBoundaries,
            texts: texts,
            starts: starts,
            endCentiseconds: ends,
            pauses: stitched.pauses,
            policy: policy,
            terminator: terminator
        )

        TestFixtures.report("[pair] \(recording.label) | \(arm) | \(milliseconds) ms")
        TestFixtures.report(
            "[pair]   language \(detailed.language ?? "unknown") | decoder segments \(texts.count) | "
                + "pauses measured \(stitched.pauses.count) | long "
                + "\(stitched.pauses.filter { $0.seconds >= policy.sentenceThreshold }.count) | junctions "
                + "\(junctions.count) | the decoder closed \(junctions.count - ignoredByTheDecoder) | "
                + "the pause closed \(ignoredByTheDecoder - stillOpen) | left open \(stillOpen)"
        )
        TestFixtures.report(
            "[pair]   sentences \(read.count) | fragments (<=2 words) "
                + "\(read.filter { wordCount($0) <= 2 }.count) | punctuation \(punctuationCounts(text))"
        )
        if let baseline {
            let delta = wordDelta(baseline: baseline, text: text)
            TestFixtures.report(
                "[pair]   word delta vs the switch-off/none control: -\(delta.removed.count) \(delta.removed) "
                    + "+\(delta.added.count) \(delta.added) | unchanged "
                    + "\(delta.removed.isEmpty && delta.added.isEmpty)"
            )
        }
        TestFixtures.report("[pair]   text: \(text)")
        for (index, segment) in texts.enumerated() {
            TestFixtures.report("[pair]   seg \(index) \(starts[index])->\(ends[index])cs: \(segment)")
        }

        if policy.closesSentence {
            XCTAssertEqual(
                withBoundaries,
                text,
                "\(recording.label) | \(arm): the engine's transcript is not the assembler's output for this audio"
            )
            XCTAssertEqual(
                stillOpen,
                0,
                "\(recording.label) | \(arm): a long pause is still inside a sentence in the transcript"
            )
        } else {
            XCTAssertEqual(
                runOn,
                text,
                "\(recording.label) | \(arm): nothing may be added to the decoder's own text on this arm"
            )
        }

        return ArmResult(
            arm: arm,
            prompt: prompt,
            text: text,
            sentences: read.count,
            milliseconds: milliseconds,
            languageAtDecode: detailed.language
        )
    }

    private func reportPauses(
        recording: CaptainRecording,
        samples: [Float],
        segments: [WhisperVadSegment]
    ) {
        TestFixtures.report("[pair] ============================================================")
        TestFixtures.report(
            "[pair] \(recording.label) | \(recording.fileName) | "
                + "\(samples.count) samples (\(Double(samples.count) / 16000) s) | VAD segments \(segments.count)"
        )
        for index in 1..<max(1, segments.count) {
            let vadGapCs = segments[index].startCs - segments[index - 1].endCs
            let decoderVisible = Double(
                Int(segments[index].startCs) * 160 - (Int(segments[index - 1].endCs) * 160 + 1600)
            ) / 16000
            TestFixtures.report(
                "[pair]   gap \(index): VAD \(vadGapCs) cs (\(Double(vadGapCs) / 100) s) | "
                    + "decoder-visible under the switch \(String(format: "%.2f", decoderVisible)) s"
            )
        }
    }

    // MARK: - What a language pre-pass would cost

    /// The price of the honest design, measured.
    ///
    /// A decoder prompt chosen by the language *spoken* has to know the language
    /// before the prompt is handed to the decoder, and this engine's only
    /// language signal — `whisper_full`'s own auto-detection — arrives during a
    /// decode. whisper.cpp offers exactly one way out: with `detect_language`
    /// set, `whisper_full` computes the mel and the encoder, reads the language
    /// off the encoder output and returns without decoding a token
    /// (`libwhisper/whisper.cpp/src/whisper.cpp:6849-6865`). That is a real pass
    /// over the audio, so it is measured here — same model, same context
    /// parameters (`useGPU`, flash attention), same stitched audio, same
    /// threads as a transcription — against the full decode of that same audio.
    ///
    /// Everything about this case is reported, nothing asserted beyond the
    /// pre-pass succeeding and agreeing with the engine: whether the price is
    /// worth paying is a product decision, and this is the number it turns on.
    func testTheCostOfALanguagePrePass() async throws {
        let directory = try recordingsDirectory()
        let modelURL = try TestFixtures.multilingualModel()
        let vadModelPath = try XCTUnwrap(WhisperEngine.vadModelPath, "Silero VAD model must be bundled")

        // A context configured exactly as `WhisperEngine.initialize()` configures
        // the app's own, with no decoding state of its own.
        let params = WhisperContextParams()
        guard let context = MyWhisperContext.initFromFileNoState(path: modelURL.path, params: params) else {
            XCTFail("the model did not load: \(modelURL.path)")
            return
        }
        guard let vad = MyWhisperVadContext(modelPath: vadModelPath) else {
            XCTFail("the VAD model did not load")
            return
        }
        let converter = WhisperEngine(modelPath: modelURL.path)
        let nThreads = max(2, min(ProcessInfo.processInfo.activeProcessorCount, 8))

        TestFixtures.report("[pair] ============ the cost of a language pre-pass ============")
        TestFixtures.report("[pair] model \(modelURL.path) | threads \(nThreads) | detect = mel + encoder, no token")

        for recording in Self.recordings {
            let audioURL = directory.appendingPathComponent(recording.fileName)
            guard FileManager.default.fileExists(atPath: audioURL.path) else { continue }
            let converted = try await converter.convertAudioToPCM(fileURL: audioURL)
            let samples = try XCTUnwrap(converted, "\(recording.fileName) did not convert to PCM")
            let segments = try XCTUnwrap(vad.speechSegments(in: samples))
            let stitched = WhisperEngine.stitch(from: samples, segments: segments, policy: Self.switchOnPolicy)

            let settings = captainSettings(initialPrompt: "", longPausesEndSentences: true)
            var detectMs: [Int] = []
            var detectedLanguage: String?
            var fullMs: [Int] = []
            var fullLanguage: String?

            for _ in 0..<2 {
                guard context.initState() else {
                    XCTFail("a fresh decoding state could not be created")
                    return
                }
                var detect = WhisperEngine.makeFullParams(
                    settings: settings,
                    nThreads: nThreads,
                    modelTextContext: context.nTextCtx,
                    initialPromptTokenCount: 0
                )
                detect.detectLanguage = true
                detect.initialPrompt = nil
                var cDetect = detect.toC()
                let startedDetect = Date()
                let detected = context.full(samples: stitched.samples, params: &cDetect)
                let detectMilliseconds = Int(Date().timeIntervalSince(startedDetect) * 1000)
                let language = context.fullLangId >= 0
                    ? MyWhisperContext.langStr(id: context.fullLangId)
                    : nil
                XCTAssertTrue(detected, "\(recording.label): the detection pass failed")
                detectMs.append(detectMilliseconds)
                detectedLanguage = language

                guard context.initState() else {
                    XCTFail("a fresh decoding state could not be created")
                    return
                }
                var full = WhisperEngine.makeFullParams(
                    settings: settings,
                    nThreads: nThreads,
                    modelTextContext: context.nTextCtx,
                    initialPromptTokenCount: 0
                )
                var cFull = full.toC()
                let startedFull = Date()
                let decoded = context.full(samples: stitched.samples, params: &cFull)
                let fullMilliseconds = Int(Date().timeIntervalSince(startedFull) * 1000)
                XCTAssertTrue(decoded, "\(recording.label): the full decode failed")
                fullMs.append(fullMilliseconds)
                fullLanguage = context.fullLangId >= 0 ? MyWhisperContext.langStr(id: context.fullLangId) : nil
            }

            let detectBest = detectMs.min() ?? 0
            let fullBest = fullMs.min() ?? 0
            TestFixtures.report(
                "[pair] \(recording.label) | audio the decoder hears "
                    + "\(String(format: "%.1f", Double(stitched.samples.count) / 16000)) s | "
                    + "language pre-pass \(detectMs) ms (language \(detectedLanguage ?? "unknown")) | "
                    + "full decode \(fullMs) ms (language \(fullLanguage ?? "unknown")) | "
                    + "pre-pass is \(fullBest > 0 ? String(format: "%.0f", 100.0 * Double(detectBest) / Double(fullBest)) : "?")% "
                    + "of a decode (\((detectBest + fullBest)) ms together vs \(fullBest) ms)"
            )
            XCTAssertEqual(
                detectedLanguage,
                fullLanguage,
                "\(recording.label): the pre-pass measured a different language than the decode"
            )
        }
        TestFixtures.report("[pair] ============================================================")
    }

    // MARK: - The shipped configuration

    /// The configuration the app now ships, asserted: the Polish win, and the
    /// **accepted** English change and nothing wider.
    ///
    /// Everything else in this class measures arms; this case measures the app:
    /// `initialPrompt` empty (a new install, and the captain's domain) with the
    /// switch on (a new install) is the configuration a dictation now runs in, so
    /// the prompt the decoder is handed comes from `WhisperEngine.decoderPrompt`
    /// and the language is the engine's own measurement of the utterance — the
    /// pre-pass — not a value this test names.
    ///
    /// Three things are asserted, and the third is what keeps the accepted damage
    /// from widening quietly:
    ///
    /// * the Polish win: `pl-1` reads one sentence more than the control *and* ends
    ///   the sentence at the pause, and `pl-2` carries `Open Super Whisper` and
    ///   `Dodałem`;
    /// * the shipped path is the arm the table names: the same audio decoded with
    ///   the language's prompt written out by hand must give the same text, which
    ///   is also the evidence that the language pre-pass changes nothing about the
    ///   transcription it precedes;
    /// * the English control's words are the switch-off control's words **plus and
    ///   minus exactly the two the captain accepted on 2026-09-25**
    ///   (`acceptedEnglishChange`) — not "clean", which no prompt achieves, and not
    ///   open-ended, which is how a regression would slip through.
    func testTheShippedConfigurationKeepsThePolishWinAndOnlyTheAcceptedEnglishChange() async throws {
        let directory = try recordingsDirectory()
        let modelURL = try TestFixtures.multilingualModel()
        let vadModelPath = try XCTUnwrap(WhisperEngine.vadModelPath, "Silero VAD model must be bundled")

        let engine = WhisperEngine(modelPath: modelURL.path)
        try await engine.initialize()
        let vad = try XCTUnwrap(MyWhisperVadContext(modelPath: vadModelPath))

        TestFixtures.report("[pair] ================= the shipped configuration =================")
        for recording in Self.recordings {
            let audioURL = directory.appendingPathComponent(recording.fileName)
            guard FileManager.default.fileExists(atPath: audioURL.path) else {
                throw XCTSkip("\(recording.fileName) is not in \(directory.path)")
            }
            let converted = try await engine.convertAudioToPCM(fileURL: audioURL)
            let samples = try XCTUnwrap(converted, "\(recording.fileName) did not convert to PCM")
            let segments = try XCTUnwrap(vad.speechSegments(in: samples))

            // 1. The control: the switch off, which sends no prompt at all.
            let control = try await measure(
                engine: engine,
                audioURL: audioURL,
                policy: Self.controlPolicy,
                arm: Self.controlLabel,
                prompt: "",
                recording: recording,
                samples: samples,
                segments: segments,
                baseline: nil
            )

            // 2. The shipped configuration: no stored prompt, the switch on, and
            //    the language measured by the engine itself.
            let shipped = try await measure(
                engine: engine,
                audioURL: audioURL,
                policy: Self.switchOnPolicy,
                arm: "shipped (no stored prompt, switch on)",
                prompt: "",
                recording: recording,
                samples: samples,
                segments: segments,
                baseline: control.text
            )

            // 3. The same audio with the language's prompt written out by hand,
            //    which the table has to reproduce.
            let language = shipped.languageAtDecode
            let namedPrompt = WhisperEngine.defaultDecoderPrompt(forLanguage: language)
            TestFixtures.report(
                "[pair] \(recording.label) shipped | the engine measured \(language ?? "unknown") | "
                    + "the table's prompt for it: \(namedPrompt.isEmpty ? "none" : namedPrompt)"
            )
            let named = try await measure(
                engine: engine,
                audioURL: audioURL,
                policy: Self.switchOnPolicy,
                arm: "shipped: the same prompt, written out",
                prompt: namedPrompt,
                recording: recording,
                samples: samples,
                segments: segments,
                baseline: control.text
            )
            XCTAssertEqual(
                shipped.text,
                named.text,
                "\(recording.label): the shipped path did not send the prompt its language names"
            )

            // 4. The criterion itself: the Polish win, and in English exactly the
            //    change the captain accepted — no more, and no less.
            if let win = recording.win {
                let missing = win.mustContain.filter { !shipped.text.contains($0) }
                XCTAssertTrue(
                    missing.isEmpty,
                    "\(recording.label): the shipped configuration lost \(missing) — \(shipped.text)"
                )
                if win.mustGainASentence {
                    XCTAssertGreaterThan(
                        shipped.sentences,
                        control.sentences,
                        "\(recording.label): the shipped configuration did not gain the pause's boundary"
                    )
                }
            } else {
                let delta = wordDelta(baseline: control.text, text: shipped.text)
                XCTAssertEqual(
                    delta.removed,
                    Self.acceptedEnglishChange.removed,
                    "\(recording.label): the switch on lost different words than the captain accepted on "
                        + "2026-09-25 — \(shipped.text)"
                )
                XCTAssertEqual(
                    delta.added,
                    Self.acceptedEnglishChange.added,
                    "\(recording.label): the switch on invented different words than the captain accepted on "
                        + "2026-09-25 — \(shipped.text)"
                )
            }
        }
        TestFixtures.report("[pair] ============================================================")
    }
}
