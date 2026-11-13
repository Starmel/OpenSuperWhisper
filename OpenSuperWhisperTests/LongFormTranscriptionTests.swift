import Foundation
import XCTest
@testable import OpenSuperWhisper

final class WhisperLongFormSegmentAssemblyTests: XCTestCase {

    func testDecoderSegmentsDoNotBecomeParagraphs() {
        let segments = [
            "This is the first decoder segment.",
            " This is the second decoder segment.",
            " And this is the final segment.",
        ]

        let result = WhisperEngine.assembleSegmentTexts(
            segments,
            showTimestamps: false
        )

        XCTAssertEqual(
            result,
            "This is the first decoder segment. This is the second decoder segment. And this is the final segment."
        )
        XCTAssertFalse(
            result.contains("\n"),
            "Internal Whisper segment boundaries must not create paragraphs"
        )
    }

    func testLongEnglishAndRussianTextIsNotLostAtSegmentBoundaries() {
        let englishSegments = (0..<240).map { " English segment \($0)." }
        let russianSegments = (0..<240).map { " Русский сегмент \($0)." }

        for segments in [englishSegments, russianSegments] {
            let result = WhisperEngine.assembleSegmentTexts(
                segments,
                showTimestamps: false
            )

            XCTAssertEqual(result, segments.joined())
            XCTAssertFalse(result.contains("\n"))
            XCTAssertTrue(result.contains(segments.first!))
            XCTAssertTrue(result.contains(segments[120]))
            XCTAssertTrue(result.hasSuffix(segments.last!))
        }
    }

    func testTimestampModeKeepsOneSegmentPerLine() {
        let segments = [
            "[0.0->4.0] First segment.",
            "[4.0->8.0] Second segment.",
        ]

        XCTAssertEqual(
            WhisperEngine.assembleSegmentTexts(segments, showTimestamps: true),
            "[0.0->4.0] First segment.\n[4.0->8.0] Second segment."
        )
    }

    func testLongFormParametersPreserveRollingContext() {
        var settings = Settings()
        settings.initialPrompt = "short vocabulary hint"

        let params = WhisperEngine.makeFullParams(
            settings: settings,
            nThreads: 4,
            modelTextContext: 448,
            initialPromptTokenCount: 111
        )

        XCTAssertFalse(
            params.noContext,
            "Decoder windows must share prompt_past within one recording"
        )
        XCTAssertEqual(params.nMaxTextCtx, 224)
        XCTAssertTrue(params.carryInitialPrompt)
        XCTAssertFalse(
            params.noTimestamps,
            """
            The decoder must keep emitting timestamps: in no-timestamps mode \
            whisper.cpp advances the long-form seek by a whole 30-second chunk \
            whenever a window ends, which skips the rest of that window's audio
            """
        )

        let longPromptParams = WhisperEngine.makeFullParams(
            settings: settings,
            nThreads: 4,
            modelTextContext: 448,
            initialPromptTokenCount: 112
        )
        XCTAssertFalse(
            longPromptParams.carryInitialPrompt,
            "A long static prompt must not evict all rolling speech context"
        )
    }
}

final class WhisperLongFormMediaFixtureTests: XCTestCase {

    func testEnglishAndRussianFixturesAreLongEnoughToCrossWhisperWindows() async throws {
        for fixtureName in ["long_en", "long_ru"] {
            let fixtureURL = try XCTUnwrap(
                Bundle(for: Self.self).url(
                    forResource: fixtureName,
                    withExtension: "m4a"
                ),
                "Missing \(fixtureName).m4a test fixture"
            )

            let duration = await AudioUtil.audioDuration(url: fixtureURL)
            XCTAssertGreaterThan(
                duration,
                60,
                "\(fixtureName) must cross at least two 30-second Whisper windows"
            )
            XCTAssertLessThan(duration, 180)
        }
    }
}

final class WhisperLongFormLanguageIntegrationTests: XCTestCase {
    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// What one long-form fixture has to prove, whatever multilingual model
    /// decodes it.
    ///
    /// The fixtures were recorded from the adjacent `*.txt` references, so the
    /// expectations are content: checkpoints the speaker reads out at roughly a
    /// quarter, half and three quarters of the recording, phrases read across the
    /// decoder's ~30 s and ~90 s boundaries, and one passage that runs across the
    /// ~60 s boundary.
    ///
    /// Whisper decides for itself where its own segments end - the app just joins
    /// them verbatim - so nothing here is asserted against a *particular* segment
    /// pair: a faithful transcript of this audio must satisfy all of it with any
    /// multilingual model, and a transcript that lost or replayed words across a
    /// window seam fails it.
    private struct LongFormExpectation {
        let name: String
        let language: String
        /// Checkpoint phrases, in recording order. The early one is a word from
        /// the opening checkpoint passage rather than its rare adjective: the
        /// point is that the beginning of the recording was decoded at all, and
        /// this word survives even a tiny model's spelling.
        let earlyAnchor: String
        let middleAnchor: String
        let tailAnchor: String
        /// Phrases read across a window boundary, checked in the joined
        /// transcript rather than in a segment pair.
        let crossingPhrases: [(left: String, right: String)]
        /// A passage that runs across the ~60 s boundary, in order.
        let seamAnchors: [String]
        /// Words that occur exactly once in that passage's reference text. A
        /// second copy in the transcript is a replayed window, not a mishearing.
        let seamWordsExpectedOnce: [String]
    }

    private static let expectations: [LongFormExpectation] = [
        LongFormExpectation(
            name: "long_en",
            language: "en",
            earlyAnchor: "project",
            middleAnchor: "quiet",
            tailAnchor: "silver",
            // "It appears before the middle of the recording" straddles the
            // first ~30 s boundary; "clipped during conversion" the ~90 s one.
            crossingPhrases: [
                (left: "middle", right: "recording"),
                (left: "during", right: "conversion"),
            ],
            // "Now the recording continues beyond a typical 30-second window.
            // The same report is still being discussed, so the words that follow
            // belong to the same dictation." - the passage around the ~60 s seam.
            seamAnchors: [
                "continues", "beyond", "typical", "second", "window", "same",
                "report", "being", "discussed", "follow", "belong", "dictation",
            ],
            seamWordsExpectedOnce: [
                "continues", "beyond", "typical", "being", "discussed",
                "follow", "belong",
            ]
        ),
        LongFormExpectation(
            name: "long_ru",
            language: "ru",
            earlyAnchor: "проект",
            middleAnchor: "тихая",
            tailAnchor: "серебряный",
            // "Мы по-прежнему обсуждаем" straddles the ~60 s boundary;
            // "Последняя контрольная фраза" the ~90 s one.
            crossingPhrases: [
                (left: "прежнему", right: "обсуждаем"),
                (left: "последняя", right: "контрольная"),
            ],
            // "…модель создала очередной внутренний сегмент. Теперь запись
            // продолжается дольше обычного тридцатисекундного окна. Мы
            // по-прежнему обсуждаем…" - the passage around the ~60 s seam.
            seamAnchors: [
                "модель", "внутренний", "сегмент", "теперь", "запись",
                "продолжается", "обычного", "окна", "прежнему", "обсуждаем",
            ],
            seamWordsExpectedOnce: [
                "сегмент", "обычного", "прежнему", "обсуждаем",
            ]
        ),
    ]

    func testLongEnglishAndRussianAudioKeepsLanguageContextAndTail() async throws {
        let modelURL = try TestFixtures.multilingualModel()

        // The engine is handed the model: this test must not read, or write, the
        // machine's selected model to get one.
        let engine = WhisperEngine(modelPath: modelURL.path)
        try await engine.initialize()

        for fixture in Self.expectations {
            let audioURL = try fixtureURL(
                fixture.name,
                fileExtension: "m4a"
            )
            let referenceURL = try fixtureURL(
                fixture.name,
                fileExtension: "txt"
            )
            let reference = try String(contentsOf: referenceURL, encoding: .utf8)

            var settings = Settings()
            settings.showTimestamps = false
            settings.initialPrompt = ""
            settings.useBeamSearch = false
            settings.temperature = 0
            settings.noSpeechThreshold = 0.6
            settings.suppressBlankAudio = true

            let detailedResult = try await engine.transcribeAudioDetailed(
                url: audioURL,
                settings: settings
            )
            let result = detailedResult.text
            let decodedSegments = detailedResult.segments

            print("[LONG-\(fixture.language.uppercased())] \(result)")
            XCTAssertFalse(result.isEmpty)
            XCTAssertGreaterThanOrEqual(
                decodedSegments.count,
                4,
                "\(fixture.name) must exercise several decoder windows"
            )
            XCTAssertFalse(
                result.contains("\n") || result.contains("\r"),
                "\(fixture.name) contains artificial paragraph breaks"
            )

            let assembledSegments = WhisperEngine.assembleSegmentTexts(
                decodedSegments.map(\.text),
                showTimestamps: false
            )
                .replacingOccurrences(of: "[MUSIC]", with: "")
                .replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertEqual(
                result,
                assembledSegments,
                "\(fixture.name) changed text while joining decoder windows"
            )

            // A seam may not cut a word. The app joins decoder segments verbatim,
            // so the characters on both sides of every boundary stay adjacent in
            // the transcript: a word whisper split across two segments is put
            // back together, and no boundary gains a separator of its own.
            for index in decodedSegments.indices.dropLast() {
                let left = decodedSegments[index].text
                    .replacingOccurrences(of: "[MUSIC]", with: "")
                    .replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
                let right = decodedSegments[index + 1].text
                    .replacingOccurrences(of: "[MUSIC]", with: "")
                    .replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
                XCTAssertTrue(
                    result.contains(String(left.suffix(12)) + String(right.prefix(12))),
                    """
                    \(fixture.name) seam \(index) (\(left.suffix(12))|\(right.prefix(12))) \
                    was not joined verbatim
                    """
                )
            }

            let referenceWords = normalizedWords(reference)
            let resultWords = normalizedWords(result)

            for crossing in fixture.crossingPhrases {
                XCTAssertTrue(
                    phraseSurvives(
                        left: crossing.left,
                        right: crossing.right,
                        words: resultWords
                    ),
                    """
                    \(fixture.name) lost "\(crossing.left) \(crossing.right)": the phrase \
                    read across a 30-second window boundary is not in the transcript
                    """
                )
            }

            let replayRuns = repeatedWordRuns(in: resultWords, length: 4)
            XCTAssertTrue(
                replayRuns.isEmpty,
                """
                \(fixture.name) replayed a passage (\(replayRuns.prefix(3).joined(separator: " / "))); \
                a window seam duplicated words instead of continuing the dictation
                """
            )

            let overallRecall = wordRecall(
                reference: referenceWords,
                transcription: resultWords
            )
            XCTAssertGreaterThan(
                overallRecall,
                0.60,
                "\(fixture.name) lost too much long-form context; unique-word recall was \(overallRecall)"
            )

            let tailReference = Array(
                referenceWords.suffix(max(45, referenceWords.count / 4))
            )
            let tailTranscription = Array(
                resultWords.suffix(max(45, resultWords.count / 4))
            )
            let tailRecall = wordRecall(
                reference: tailReference,
                transcription: tailTranscription
            )
            let segmentDiagnostics = decodedSegments.enumerated().map {
                index, segment in
                "segment[\(index)] end=\(Double(segment.endTimeCentiseconds) / 100.0)s text=\(segment.text)"
            }.joined(separator: "\n")
            let diagnostics = XCTAttachment(
                string: """
                language=\(fixture.language)
                overallUniqueWordRecall=\(overallRecall)
                tailUniqueWordRecall=\(tailRecall)
                replayedWordRuns=\(replayRuns)
                decoderSegments:
                \(segmentDiagnostics)
                transcription:
                \(result)
                """
            )
            diagnostics.name = "\(fixture.name)-transcription"
            diagnostics.lifetime = .keepAlways
            add(diagnostics)

            XCTAssertGreaterThan(
                tailRecall,
                0.50,
                "\(fixture.name) appears clipped near the end; tail recall was \(tailRecall)"
            )

            // The three checkpoints, in order and spread across the transcript:
            // this is what proves the decoder walked the whole recording, and it
            // does not depend on where whisper put its own segment boundaries.
            let earlyIndex = try XCTUnwrap(
                checkpointIndex(
                    fixture.earlyAnchor,
                    in: resultWords
                ),
                "\(fixture.name) lost its early checkpoint"
            )
            let middleIndex = try XCTUnwrap(
                checkpointIndex(
                    fixture.middleAnchor,
                    in: resultWords
                ),
                "\(fixture.name) lost its middle checkpoint"
            )
            let tailIndex = try XCTUnwrap(
                checkpointIndex(
                    fixture.tailAnchor,
                    in: resultWords
                ),
                "\(fixture.name) lost its final checkpoint"
            )
            XCTAssertLessThan(
                relativePosition(index: earlyIndex, count: resultWords.count),
                0.35,
                "\(fixture.name) early checkpoint is not in the first part of the transcription"
            )
            let middlePosition = relativePosition(
                index: middleIndex,
                count: resultWords.count
            )
            XCTAssertGreaterThan(middlePosition, 0.35)
            XCTAssertLessThan(middlePosition, 0.75)
            XCTAssertGreaterThan(
                relativePosition(index: tailIndex, count: resultWords.count),
                0.75,
                "\(fixture.name) final checkpoint is not in the final part of the transcription"
            )

            // The passage around the ~60 s seam must still read as one passage:
            // most of it present, in order, inside one short span...
            let matchedSeamIndices = orderedMatchIndices(
                anchors: fixture.seamAnchors,
                words: resultWords
            )
            XCTAssertGreaterThanOrEqual(
                matchedSeamIndices.count,
                8,
                "\(fixture.name) lost ordered context around its 60-second seam"
            )
            if let first = matchedSeamIndices.first,
               let last = matchedSeamIndices.last {
                XCTAssertLessThan(
                    last - first,
                    45,
                    "\(fixture.name) seam anchors are no longer one continuous passage"
                )
            }

            // ...and it must not replay: these words are read once, so a second
            // copy in the transcript is a duplicated window seam.
            for uniqueAnchor in fixture.seamWordsExpectedOnce {
                let anchor = try XCTUnwrap(normalizedWords(uniqueAnchor).first)
                XCTAssertLessThanOrEqual(
                    resultWords.filter { $0 == anchor }.count,
                    1,
                    "\(fixture.name) duplicated '\(uniqueAnchor)' at a decoder seam"
                )
            }
        }
    }

    @MainActor
    func testCancellingLongWhisperDecodeStopsNativeOperation() async throws {
        let modelURL = try TestFixtures.multilingualModel()

        let engine = WhisperEngine(modelPath: modelURL.path)
        try await engine.initialize()
        let service = TranscriptionService(engine: engine)
        let operationID = UUID()
        let audioURL = try fixtureURL("long_en", fileExtension: "m4a")

        var settings = Settings()
        settings.showTimestamps = false
        settings.initialPrompt = ""
        settings.useBeamSearch = false
        settings.temperature = 0
        settings.noSpeechThreshold = 0.6
        settings.suppressBlankAudio = true

        let transcription = Task {
            try await service.transcribeAudio(
                url: audioURL,
                settings: settings,
                operationID: operationID
            )
        }

        var nativeDecodeStarted = false
        // Reaching the native decoder is a load-dependent event: conversion, the
        // VAD pass and whisper.cpp's own initialization all run first, and other
        // model-backed cases in the same run compete for the machine. This used
        // to be a fixed number of polls (1_000 × 20 ms ≈ 20 s), which turned
        // load into a red test: the case failed in a full-suite run and passed
        // alone in 159.5 s. The wait is therefore a wall-clock budget — waiting
        // longer cannot make a wrong result pass, because the assertion below is
        // still "the decoder really started", and cancelling before it starts
        // would prove nothing — it only stops the *wait* from failing the case.
        let decodeStartDeadline = Date().addingTimeInterval(600)
        while Date() < decodeStartDeadline {
            if service.progress > 0.12 {
                nativeDecodeStarted = true
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(
            nativeDecodeStarted,
            "The fixture never reached whisper.cpp decoding"
        )

        service.cancelTranscription(operationID: operationID)

        do {
            _ = try await transcription.value
            XCTFail("A native Whisper abort must surface as cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(service.isTranscribing)
        XCTAssertEqual(service.progress, 0.0)
    }


    private func fixtureURL(
        _ name: String,
        fileExtension: String
    ) throws -> URL {
        if let bundled = Bundle(for: Self.self).url(
            forResource: name,
            withExtension: fileExtension,
            subdirectory: "Fixtures"
        ) ?? Bundle(for: Self.self).url(
            forResource: name,
            withExtension: fileExtension
        ) {
            return bundled
        }

        let repositoryFixture = Self.repoRoot
            .appendingPathComponent("OpenSuperWhisperTests/Fixtures")
            .appendingPathComponent(name)
            .appendingPathExtension(fileExtension)
        return try XCTUnwrap(
            FileManager.default.fileExists(atPath: repositoryFixture.path)
                ? repositoryFixture
                : nil,
            "Missing \(name).\(fileExtension) test fixture"
        )
    }

    private func normalizedWords(_ text: String) -> [String] {
        text
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .components(
                separatedBy: CharacterSet.alphanumerics.inverted
            )
            .filter { $0.count >= 4 }
    }

    private func wordRecall(
        reference: [String],
        transcription: [String]
    ) -> Double {
        let expected = Set(reference)
        guard !expected.isEmpty else { return 0 }
        let actual = Set(transcription)
        return Double(expected.intersection(actual).count)
            / Double(expected.count)
    }

    private func relativePosition(index: Int, count: Int) -> Double {
        guard count > 1 else { return 0 }
        return Double(index) / Double(count - 1)
    }

    /// The checkpoint word as the transcript would spell it.
    private func checkpointIndex(
        _ anchor: String,
        in words: [String]
    ) -> Int? {
        guard let anchor = normalizedWords(anchor).first else { return nil }
        return words.firstIndex(of: anchor)
    }

    /// Whether the transcript still carries a phrase the speaker read across a
    /// window boundary. The words have to survive close together and in order;
    /// which decoder segment they ended up in is whisper's business, not the
    /// app's, so that is deliberately not asserted.
    private func phraseSurvives(
        left: String,
        right: String,
        words: [String],
        within distance: Int = 6
    ) -> Bool {
        guard let left = normalizedWords(left).first,
              let right = normalizedWords(right).first,
              words.count > 1 else {
            return false
        }
        for index in words.indices.dropLast() {
            guard words[index] == left else { continue }
            let limit = min(words.count - 1, index + distance)
            if index + 1 <= limit,
               words[(index + 1)...limit].contains(right) {
                return true
            }
        }
        return false
    }

    /// Word runs of `length` that occur more than once. The fixtures read every
    /// passage once, so a repeat is the decoder replaying a window (the failure
    /// the rolling prompt causes when a seam is not anchored to audio), not a
    /// phrase the speaker repeated.
    private func repeatedWordRuns(
        in words: [String],
        length: Int
    ) -> [String] {
        guard length > 0, words.count >= length else { return [] }
        var seen = Set<[String]>()
        var repeated = Set<[String]>()
        for start in 0...(words.count - length) {
            let run = Array(words[start..<(start + length)])
            if !seen.insert(run).inserted {
                repeated.insert(run)
            }
        }
        return repeated.map { $0.joined(separator: " ") }.sorted()
    }

    private func orderedMatchIndices(
        anchors: [String],
        words: [String]
    ) -> [Int] {
        var searchStart = words.startIndex
        var matches: [Int] = []

        for anchor in anchors {
            guard let anchor = normalizedWords(anchor).first else { continue }
            guard searchStart < words.endIndex,
                  let index = words[searchStart...].firstIndex(of: anchor) else {
                continue
            }
            matches.append(index)
            searchStart = words.index(after: index)
        }
        return matches
    }
}
