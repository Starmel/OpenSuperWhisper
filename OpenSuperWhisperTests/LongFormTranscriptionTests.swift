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
        settings.selectedLanguage = "ru"
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

    func testLongEnglishAndRussianAudioKeepsLanguageContextAndTail() async throws {
        let modelURL = try multilingualModelURL()
        let originalModelPath = AppPreferences.shared.selectedWhisperModelPath
        AppPreferences.shared.selectedWhisperModelPath = modelURL.path
        defer {
            AppPreferences.shared.selectedWhisperModelPath = originalModelPath
        }

        let engine = WhisperEngine()
        try await engine.initialize()

        for fixture in [
            (
                name: "long_en",
                language: "en",
                middleAnchor: "quiet",
                tailAnchor: "silver",
                boundaryLeft: "middle",
                boundaryRight: "recording",
                lateBoundaryLeft: "during",
                lateBoundaryRight: "conversion",
                seamAnchors: [String]()
            ),
            (
                name: "long_ru",
                language: "ru",
                middleAnchor: "тихая",
                tailAnchor: "серебряный",
                boundaryLeft: "прежнему",
                boundaryRight: "обсуждаем",
                lateBoundaryLeft: "последнее",
                lateBoundaryRight: "контрольная",
                seamAnchors: [
                    "модель", "внутренний", "сегмент", "теперь", "запись",
                    "продолжается", "обычного", "окна", "прежнему", "обсуждаем",
                ]
            ),
        ] {
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
            settings.selectedLanguage = fixture.language
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
                "\(fixture.name) must exercise multiple decoder windows"
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

            let internalWindowEnds = decodedSegments
                .dropLast()
                .map(\.endTimeCentiseconds)
            XCTAssertTrue(
                internalWindowEnds.contains(where: { (2_500...3_500).contains($0) }),
                "\(fixture.name) did not expose its first ~30-second boundary"
            )
            XCTAssertTrue(
                internalWindowEnds.contains(where: { (5_500...6_500).contains($0) }),
                "\(fixture.name) did not expose its second ~30-second boundary"
            )
            XCTAssertTrue(
                internalWindowEnds.contains(where: { (8_500...9_500).contains($0) }),
                "\(fixture.name) did not expose its third ~30-second boundary"
            )

            XCTAssertTrue(
                hasAdjacentBoundaryPhrase(
                    left: fixture.boundaryLeft,
                    right: fixture.boundaryRight,
                    segments: decodedSegments
                ),
                "\(fixture.name) lost its phrase across an adjacent 30-second boundary"
            )
            XCTAssertTrue(
                hasAdjacentBoundaryPhrase(
                    left: fixture.lateBoundaryLeft,
                    right: fixture.lateBoundaryRight,
                    segments: decodedSegments
                ),
                "\(fixture.name) lost its phrase across the final decoder boundary"
            )

            let referenceWords = normalizedWords(reference)
            let resultWords = normalizedWords(result)
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

            let middleAnchor = try XCTUnwrap(
                normalizedWords(fixture.middleAnchor).first
            )
            let middleIndex = try XCTUnwrap(
                resultWords.firstIndex(of: middleAnchor),
                "\(fixture.name) lost its middle checkpoint"
            )
            let middlePosition = relativePosition(
                index: middleIndex,
                count: resultWords.count
            )
            XCTAssertGreaterThan(middlePosition, 0.35)
            XCTAssertLessThan(middlePosition, 0.75)

            let tailAnchor = try XCTUnwrap(
                normalizedWords(fixture.tailAnchor).first
            )
            let tailIndex = try XCTUnwrap(
                resultWords.lastIndex(of: tailAnchor),
                "\(fixture.name) lost its final checkpoint"
            )
            XCTAssertGreaterThan(
                relativePosition(index: tailIndex, count: resultWords.count),
                0.75,
                "\(fixture.name) final checkpoint is not in the final part of the transcription"
            )

            if !fixture.seamAnchors.isEmpty {
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

                for uniqueAnchor in ["сегмент", "обычного", "прежнему"] {
                    XCTAssertEqual(
                        resultWords.filter { $0 == uniqueAnchor }.count,
                        1,
                        "\(fixture.name) duplicated or lost '\(uniqueAnchor)' at a decoder seam"
                    )
                }
            }
        }
    }

    private func multilingualModelURL() throws -> URL {
        let candidates = [
            ProcessInfo.processInfo.environment["OSW_TEST_MULTILINGUAL_MODEL"]
                .map(URL.init(fileURLWithPath:)),
            Self.repoRoot
                .appendingPathComponent(".build/test-models/ggml-tiny.bin"),
            Self.repoRoot.appendingPathComponent("ggml-tiny.bin"),
        ].compactMap { $0 }

        guard let modelURL = candidates.first(where: {
            guard let size = try? $0.resourceValues(
                forKeys: [.fileSizeKey]
            ).fileSize else {
                return false
            }
            return size > 10_000_000
        }) else {
            throw XCTSkip(
                "Set OSW_TEST_MULTILINGUAL_MODEL to a real multilingual ggml model"
            )
        }
        return modelURL
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

    private func hasAdjacentBoundaryPhrase(
        left: String,
        right: String,
        segments: [WhisperEngine.DecodedSegment]
    ) -> Bool {
        let normalizedLeft = normalizedWords(left).first
        let normalizedRight = normalizedWords(right).first
        guard let normalizedLeft, let normalizedRight else { return false }

        return segments.indices.dropLast().contains { index in
            normalizedWords(segments[index].text)
                .suffix(12)
                .contains(normalizedLeft)
                && normalizedWords(segments[index + 1].text)
                    .prefix(12)
                    .contains(normalizedRight)
        }
    }

    private func orderedMatchIndices(
        anchors: [String],
        words: [String]
    ) -> [Int] {
        var searchStart = words.startIndex
        var matches: [Int] = []

        for anchor in anchors {
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
