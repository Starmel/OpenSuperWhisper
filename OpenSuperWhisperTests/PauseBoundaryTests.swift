import Foundation
import XCTest

@testable import OpenSuperWhisper

/// The switch that keeps a pause instead of dissolving it.
///
/// The assembly is a pure function of the segments the decoder produced and the
/// gaps the VAD measured, so every rule the fix rests on is pinned here without
/// weights: a gap over the threshold closes the sentence, a short one does not,
/// no word is touched, and timestamp mode is unchanged.
final class WhisperPauseBoundaryTests: XCTestCase {

    // MARK: - Stitching

    /// 16 kHz mono samples: the recording's own room tone everywhere, `speech`
    /// where the two speech blocks are. The floor is deliberately not zero, so a
    /// test can tell the recording's silence from a synthetic block of zeros.
    private func audio(
        sampleCount: Int,
        speech: [(start: Int, end: Int)]
    ) -> [Float] {
        var samples = [Float](repeating: 0.02, count: sampleCount)
        for range in speech {
            for index in range.start..<range.end {
                samples[index] = 0.5
            }
        }
        return samples
    }

    /// VAD segments, from speech blocks given in samples: centiseconds, as the
    /// VAD reports them.
    private func segments(_ ranges: [(start: Int, end: Int)]) -> [WhisperVadSegment] {
        ranges.map { WhisperVadSegment(startCs: Int64($0.start / 160), endCs: Int64($0.end / 160)) }
    }

    /// Two one-second speech blocks with three seconds of silence between them.
    private let threeSecondPause: [(start: Int, end: Int)] = [(0, 16_000), (64_000, 80_000)]

    func testUpstreamStitchingKeepsADecisecondOfZerosAtEveryPause() {
        let samples = audio(sampleCount: 80_000, speech: threeSecondPause)
        let segmentList = segments(threeSecondPause)

        let stitched = WhisperEngine.stitch(from: samples, segments: segmentList, policy: .upstream)

        // Segment 0 plus upstream's 0.1 s of overlap, 0.1 s of zeros, segment 1.
        XCTAssertEqual(stitched.samples.count, 17_600 + 1_600 + 16_000)
        XCTAssertTrue(
            stitched.samples[17_600..<19_200].allSatisfy { $0 == 0 },
            "upstream's stitched pause is zeros, not the recording"
        )
        XCTAssertEqual(stitched.pauses.count, 1)
        XCTAssertEqual(
            stitched.pauses[0].seconds,
            2.9,
            accuracy: 0.001,
            "the silence the decoder did not get: the 3 s gap minus the 0.1 s overlap upstream carries"
        )
        XCTAssertEqual(
            stitched.pauses[0].endCentiseconds,
            120,
            "17,600 + 1,600 samples is where the decoder's next segment starts"
        )
        XCTAssertEqual(
            stitched.pauses[0].startCentiseconds,
            110,
            "the pause begins where the previous segment's audio ends, overlap included"
        )
    }

    func testTheSwitchOnKeepsThePauseTheSpeakerActuallyLeft() {
        let samples = audio(sampleCount: 80_000, speech: threeSecondPause)
        let segmentList = segments(threeSecondPause)

        let stitched = WhisperEngine.stitch(from: samples, segments: segmentList, policy: .restored)

        XCTAssertEqual(
            stitched.samples.count,
            17_600 + Int(0.8 * 16_000) + 16_000,
            "the kept pause is capped at the policy's 0.8 s"
        )
        let kept = stitched.samples[17_600..<(17_600 + Int(0.8 * 16_000))]
        XCTAssertEqual(
            kept.count,
            12_800
        )
        XCTAssertTrue(
            kept.allSatisfy { $0 == 0.02 },
            "the audio at the pause is the recording's own silence, not a synthetic block"
        )
        XCTAssertEqual(stitched.pauses[0].seconds, 2.9, accuracy: 0.001)
        XCTAssertEqual(stitched.pauses[0].endCentiseconds, 190)
    }

    func testAShortPauseIsPaddedUpToTheMinimumAndNoFurther() {
        // A 0.05 s gap between two segments: less than upstream's minimum.
        let speech = [(0, 16_000), (16_800, 32_800)]
        let samples = audio(sampleCount: 32_800, speech: speech)

        let stitched = WhisperEngine.stitch(
            from: samples,
            segments: segments(speech),
            policy: .restored
        )

        XCTAssertEqual(
            stitched.samples.count,
            17_600 + 1_600 + 16_000,
            "a pause shorter than the minimum is padded to the minimum, never longer"
        )
        XCTAssertTrue(stitched.samples[17_600..<19_200].allSatisfy { $0 == 0 })
        XCTAssertEqual(stitched.pauses.count, 1)
        XCTAssertEqual(
            stitched.pauses[0].seconds,
            0,
            accuracy: 0.001,
            "the overlap upstream adds already covers a gap this short"
        )
    }

    func testAPauseIsNeverLongerThanTheCapHoweverLongTheSilenceWas() {
        let speech = [(0, 16_000), (160_000, 176_000)]
        let samples = audio(sampleCount: 176_000, speech: speech)

        let stitched = WhisperEngine.stitch(
            from: samples,
            segments: segments(speech),
            policy: .restored
        )

        XCTAssertEqual(stitched.samples.count, 17_600 + Int(0.8 * 16_000) + 16_000)
        XCTAssertEqual(stitched.pauses[0].seconds, 8.9, accuracy: 0.01)
    }

    func testTheUpstreamWrapperIsThePolicyOffStitching() {
        let samples = audio(sampleCount: 80_000, speech: threeSecondPause)
        let segmentList = segments(threeSecondPause)

        XCTAssertEqual(
            WhisperEngine.speechOnlySamples(from: samples, segments: segmentList),
            WhisperEngine.stitch(from: samples, segments: segmentList, policy: .upstream).samples
        )
    }

    /// The body this replaced, kept here as the reference the switch off has to
    /// reproduce: every speech segment, 0.1 s of the following audio as overlap,
    /// and exactly 0.1 s of zeros between consecutive segments.
    private func legacySpeechOnlySamples(
        from samples: [Float],
        segments: [WhisperVadSegment]
    ) -> [Float] {
        let samplesPerCs = 160
        let overlapSamples = 1600
        let gapSamples = 1600

        var result = [Float]()
        for (index, segment) in segments.enumerated() {
            let start = min(max(0, Int(segment.startCs) * samplesPerCs), samples.count)
            var end = min(Int(segment.endCs) * samplesPerCs, samples.count)
            if index < segments.count - 1 {
                end = min(end + overlapSamples, samples.count)
            }
            guard end > start else { continue }

            result.append(contentsOf: samples[start..<end])
            if index < segments.count - 1 {
                result.append(contentsOf: repeatElement(0, count: gapSamples))
            }
        }
        return result
    }

    /// Every segmentation the VAD can produce (it never emits a segment shorter
    /// than its own 250 ms minimum), so "off" is the old audio exactly.
    func testTheSwitchOffIsTheOldStitchingByteForByte() {
        let layouts: [[(startCs: Int64, endCs: Int64)]] = [
            [(0, 100), (400, 500)],
            [(0, 100), (140, 240), (490, 590)],
            [(0, 100), (400, 500), (520, 620), (900, 1000)],
            [(0, 100), (105, 205)],
            [(50, 150)],
        ]

        for layout in layouts {
            let last = layout.map(\.endCs).max() ?? 0
            let sampleCount = Int(last) * 160
            let blocks: [(start: Int, end: Int)] = layout.map {
                (start: Int($0.startCs) * 160, end: Int($0.endCs) * 160)
            }
            let samples = audio(sampleCount: sampleCount, speech: blocks)
            let segmentList = layout.map { WhisperVadSegment(startCs: $0.startCs, endCs: $0.endCs) }

            XCTAssertEqual(
                WhisperEngine.stitch(from: samples, segments: segmentList, policy: .upstream).samples,
                legacySpeechOnlySamples(from: samples, segments: segmentList),
                "switch off changed the audio for \(layout)"
            )
        }
    }

    // MARK: - The policy follows the switch

    func testThePolicyFollowsTheLongPausesSwitch() {
        var settings = Settings()
        settings.longPausesEndSentences = true
        XCTAssertEqual(WhisperEngine.PauseBoundaryPolicy.from(settings: settings), .restored)
        XCTAssertTrue(WhisperEngine.PauseBoundaryPolicy.from(settings: settings).closesSentence)
        XCTAssertGreaterThan(
            WhisperEngine.PauseBoundaryPolicy.from(settings: settings).maxPause,
            0,
            "the switch on has to keep real pause audio; that is the half the decoder can hear"
        )

        settings.longPausesEndSentences = false
        XCTAssertEqual(WhisperEngine.PauseBoundaryPolicy.from(settings: settings), .upstream)
        XCTAssertEqual(
            WhisperEngine.PauseBoundaryPolicy.from(settings: settings).maxPause,
            0,
            "the switch off is upstream's stitching exactly: zeros, no real pause, no terminator"
        )
        XCTAssertFalse(WhisperEngine.PauseBoundaryPolicy.from(settings: settings).closesSentence)
    }

    func testTheSettingsSnapshotCarriesTheStoredSwitch() {
        let saved = AppPreferences.shared.longPausesEndSentences
        defer { AppPreferences.shared.longPausesEndSentences = saved }

        AppPreferences.shared.longPausesEndSentences = false
        XCTAssertFalse(Settings().longPausesEndSentences, "the dictation reads the preference")

        AppPreferences.shared.longPausesEndSentences = true
        XCTAssertTrue(Settings().longPausesEndSentences)
    }

    // MARK: - Where the boundary lands

    func testAPauseBelongsAfterTheSegmentThatEndedBeforeIt() {
        let pauses = [
            WhisperEngine.StitchedPause(seconds: 1.4, startCentiseconds: 290, endCentiseconds: 300),
            WhisperEngine.StitchedPause(seconds: 0.6, startCentiseconds: 690, endCentiseconds: 700),
        ]

        let boundaries = WhisperEngine.sentenceBoundaries(
            decodedStartsCentiseconds: [10, 300, 500, 700],
            decodedEndCentiseconds: [290, 480, 690, 900],
            pauses: pauses,
            policy: .restored,
            terminator: "."
        )

        XCTAssertEqual(
            boundaries.afterSegment,
            [0, 2],
            "the pause at 300 cs closed the segment that ended at 290, the one at 700 the segment at 690"
        )
        XCTAssertEqual(boundaries.terminator, ".")
    }

    func testAPauseTheDecoderDecodedStraightThroughGetsNoTerminator() {
        let pauses = [
            WhisperEngine.StitchedPause(seconds: 2.0, startCentiseconds: 250, endCentiseconds: 700),
        ]

        let junctions = WhisperEngine.pauseJunctions(
            // The second segment starts at 200 cs: before the pause ended, so it
            // is the segment that decoded across the silence. Both thoughts are
            // already inside its text, and nothing here can say where to split.
            decodedStartsCentiseconds: [10, 200],
            decodedEndCentiseconds: [290, 900],
            pauses: pauses,
            threshold: WhisperEngine.PauseBoundaryPolicy.restored.sentenceThreshold,
            tolerance: WhisperEngine.PauseBoundaryPolicy.restored.boundaryTolerance
        )

        XCTAssertEqual(junctions, [], "a decoder that ran the two thoughts together is left alone")
    }

    func testASegmentStartingAtThePauseCountsAsTheBoundary() {
        let pauses = [
            WhisperEngine.StitchedPause(seconds: 2.0, startCentiseconds: 250, endCentiseconds: 700),
        ]

        let junctions = WhisperEngine.pauseJunctions(
            decodedStartsCentiseconds: [10, 700],
            decodedEndCentiseconds: [290, 900],
            pauses: pauses,
            threshold: WhisperEngine.PauseBoundaryPolicy.restored.sentenceThreshold,
            tolerance: WhisperEngine.PauseBoundaryPolicy.restored.boundaryTolerance
        )

        XCTAssertEqual(junctions, [0])
    }

    func testAPauseBelowTheThresholdLeavesTheDecoderAlone() {
        let pauses = [
            WhisperEngine.StitchedPause(
                seconds: WhisperEngine.PauseBoundaryPolicy.restored.sentenceThreshold - 0.2,
                startCentiseconds: 290,
                endCentiseconds: 300
            ),
        ]

        let boundaries = WhisperEngine.sentenceBoundaries(
            decodedStartsCentiseconds: [10, 300],
            decodedEndCentiseconds: [290, 900],
            pauses: pauses,
            policy: .restored,
            terminator: "."
        )

        XCTAssertEqual(
            boundaries,
            .none,
            "a pause 0.2 s under the threshold: no terminator is added"
        )
    }

    func testTheThresholdItselfCounts() {
        let threshold = WhisperEngine.PauseBoundaryPolicy.restored.sentenceThreshold

        let atThreshold = WhisperEngine.sentenceBoundaries(
            decodedStartsCentiseconds: [10, 300],
            decodedEndCentiseconds: [290, 900],
            pauses: [
                WhisperEngine.StitchedPause(seconds: threshold, startCentiseconds: 290, endCentiseconds: 300),
            ],
            policy: .restored,
            terminator: "."
        )
        XCTAssertEqual(atThreshold.afterSegment, [0], "the threshold counts as a long pause")

        let underThreshold = WhisperEngine.sentenceBoundaries(
            decodedStartsCentiseconds: [10, 300],
            decodedEndCentiseconds: [290, 900],
            pauses: [
                WhisperEngine.StitchedPause(
                    seconds: threshold - 0.001,
                    startCentiseconds: 290,
                    endCentiseconds: 300
                ),
            ],
            policy: .restored,
            terminator: "."
        )
        XCTAssertEqual(underThreshold, .none)
    }

    func testAPauseWithNoSegmentLeftAfterItClosesNothing() {
        let pauses = [
            WhisperEngine.StitchedPause(seconds: 3, startCentiseconds: 980, endCentiseconds: 990),
        ]

        let boundaries = WhisperEngine.sentenceBoundaries(
            decodedStartsCentiseconds: [10, 300],
            decodedEndCentiseconds: [290, 980],
            pauses: pauses,
            policy: .restored,
            terminator: "."
        )

        XCTAssertEqual(boundaries, .none, "there is no sentence after the last one to separate")
    }

    func testThePolicyOffMeasuresPausesButNeverClosesASentence() {
        let boundaries = WhisperEngine.sentenceBoundaries(
            decodedStartsCentiseconds: [10, 300],
            decodedEndCentiseconds: [290, 980],
            pauses: [
                WhisperEngine.StitchedPause(seconds: 3, startCentiseconds: 290, endCentiseconds: 300),
            ],
            policy: .upstream,
            terminator: "."
        )

        XCTAssertEqual(boundaries, .none, "the switch off is the transcript every earlier build produced")
    }

    // MARK: - The assembly

    func testAGapOverTheThresholdEndsTheSentenceAndNoWordChanges() {
        let segments = [
            "Dobra wiadomość jest taka, że odzyskałem swój polski.",
            " Udało mi się zrobić fork.",
        ]

        let before = WhisperEngine.assembleSegmentTexts(segments, showTimestamps: false)
        let after = WhisperEngine.assembleSegmentTexts(
            segments,
            showTimestamps: false,
            sentenceBoundaries: .init(afterSegment: [0], terminator: ".")
        )

        XCTAssertEqual(before, "Dobra wiadomość jest taka, że odzyskałem swój polski. Udało mi się zrobić fork.")
        XCTAssertEqual(
            after,
            before,
            "a segment that already ended its sentence is left exactly as it was"
        )
    }

    func testAnOpenSentenceIsClosedWhereThePauseWas() {
        let segments = ["Dałem drugi model", " Jestem", " Znowu po polsku."]

        let before = WhisperEngine.assembleSegmentTexts(segments, showTimestamps: false)
        let after = WhisperEngine.assembleSegmentTexts(
            segments,
            showTimestamps: false,
            sentenceBoundaries: .init(afterSegment: [0], terminator: ".")
        )

        XCTAssertEqual(before, "Dałem drugi model Jestem Znowu po polsku.")
        XCTAssertEqual(
            after,
            "Dałem drugi model. Jestem Znowu po polsku.",
            "the boundary lands where the pause was and nothing is reordered"
        )
        XCTAssertEqual(
            after.replacingOccurrences(of: ". ", with: " "),
            before,
            "inserting the terminator is the only difference: no word is altered"
        )
    }

    func testAShortGapAddsNoTerminator() {
        let segments = ["Dałem drugi model", " i poszedłem dalej."]
        let withNoBoundaries = WhisperEngine.assembleSegmentTexts(
            segments,
            showTimestamps: false,
            sentenceBoundaries: .none
        )

        XCTAssertEqual(withNoBoundaries, segments.joined())
    }

    func testTheTerminatorNeverLandsBesideAStraySpace() {
        // The decoder put its own trailing space at the end of the segment.
        let segments = ["Dałem drugi model ", "Jestem."]

        XCTAssertEqual(
            WhisperEngine.assembleSegmentTexts(
                segments,
                showTimestamps: false,
                sentenceBoundaries: .init(afterSegment: [0], terminator: ".")
            ),
            "Dałem drugi model. Jestem."
        )
    }

    func testASpaceIsAddedWhenNeitherSegmentCarriesOne() {
        let segments = ["Dałem drugi model", "Jestem."]

        XCTAssertEqual(
            WhisperEngine.assembleSegmentTexts(
                segments,
                showTimestamps: false,
                sentenceBoundaries: .init(afterSegment: [0], terminator: ".")
            ),
            "Dałem drugi model. Jestem."
        )
    }

    func testTheDecoderPunctuationIsNotDoubled() {
        for ending in [".", "!", "?", "…", "…", "。", "！", "？", "..."] {
            XCTAssertTrue(
                WhisperEngine.endsSentence("Dałem drugi model\(ending)"),
                "\(ending) ends a sentence"
            )
        }
        XCTAssertTrue(WhisperEngine.endsSentence("Powiedział: \"skończone.\""))
        XCTAssertTrue(WhisperEngine.endsSentence("(skończone.)"))
        XCTAssertFalse(WhisperEngine.endsSentence("Dałem drugi model,"))
        XCTAssertFalse(WhisperEngine.endsSentence("Dałem drugi model"))
        XCTAssertFalse(WhisperEngine.endsSentence(""))
        XCTAssertFalse(WhisperEngine.endsSentence("   "))
    }

    func testOnlyOneTerminatorIsEverInsertedPerBoundary() {
        let segments = ["Dałem drugi model", " Jestem"]

        let after = WhisperEngine.assembleSegmentTexts(
            segments,
            showTimestamps: false,
            sentenceBoundaries: .init(afterSegment: [0, 0], terminator: ".")
        )

        XCTAssertEqual(after, "Dałem drugi model. Jestem")
    }

    func testAWhitespaceOnlySegmentNeverCarriesTheTerminatorItself() {
        let segments = ["Dałem drugi model", " ", "Jestem"]

        let after = WhisperEngine.assembleSegmentTexts(
            segments,
            showTimestamps: false,
            sentenceBoundaries: .init(afterSegment: [0, 1], terminator: ".")
        )

        XCTAssertEqual(
            after,
            "Dałem drugi model. Jestem",
            "the terminator lands after the words, not after whitespace of its own"
        )
    }

    func testNoTerminatorIsAddedWhenThereIsNothingToClose() {
        XCTAssertEqual(
            WhisperEngine.assembleSegmentTexts(
                [" ", " Jestem"],
                showTimestamps: false,
                sentenceBoundaries: .init(afterSegment: [0], terminator: ".")
            ),
            "  Jestem",
            "a boundary with no text in front of it has no sentence to close"
        )
    }

    func testTimestampModeIsUnchangedByTheBoundaries() {
        let segments = [
            "[0.0->4.0] Dałem drugi model",
            "[4.0->8.0] Jestem",
        ]

        XCTAssertEqual(
            WhisperEngine.assembleSegmentTexts(
                segments,
                showTimestamps: true,
                sentenceBoundaries: .init(afterSegment: [0], terminator: ".")
            ),
            segments.joined(separator: "\n"),
            "timestamp mode stays line-oriented: one decoder segment per line, untouched"
        )
    }

    func testCJKKeepsItsOwnFullWidthTerminator() {
        XCTAssertEqual(WhisperEngine.sentenceTerminator(forLanguage: "zh"), "。")
        XCTAssertEqual(WhisperEngine.sentenceTerminator(forLanguage: "ja"), "。")
        XCTAssertEqual(WhisperEngine.sentenceTerminator(forLanguage: "ko"), "。")
        XCTAssertEqual(WhisperEngine.sentenceTerminator(forLanguage: "pl"), ".")
        XCTAssertEqual(WhisperEngine.sentenceTerminator(forLanguage: "en"), ".")
        XCTAssertEqual(
            WhisperEngine.sentenceTerminator(forLanguage: nil),
            ".",
            "a language the engine could not measure gets the ASCII full stop"
        )

        XCTAssertEqual(
            WhisperEngine.assembleSegmentTexts(
                ["他很好", " 我很好。"],
                showTimestamps: false,
                sentenceBoundaries: .init(afterSegment: [0], terminator: "。")
            ),
            "他很好。 我很好。"
        )
    }

    func testTheWholePathFromPausesToTextClosesOneSentencePerLongPause() {
        let pauses = [
            WhisperEngine.StitchedPause(seconds: 1.2, startCentiseconds: 190, endCentiseconds: 200),
            WhisperEngine.StitchedPause(seconds: 0.2, startCentiseconds: 390, endCentiseconds: 400),
            WhisperEngine.StitchedPause(seconds: 2.6, startCentiseconds: 690, endCentiseconds: 700),
        ]
        let segments = ["pierwsza myśl", " druga myśl", " trzecia myśl", " czwarta myśl."]

        let boundaries = WhisperEngine.sentenceBoundaries(
            decodedStartsCentiseconds: [10, 200, 400, 700],
            decodedEndCentiseconds: [190, 390, 690, 900],
            pauses: pauses,
            policy: .restored,
            terminator: "."
        )
        let text = WhisperEngine.assembleSegmentTexts(
            segments,
            showTimestamps: false,
            sentenceBoundaries: boundaries
        )

        XCTAssertEqual(
            text,
            "pierwsza myśl. druga myśl trzecia myśl. czwarta myśl.",
            "the long pauses closed sentences 1 and 3; the 0.2 s pause left sentence 2 alone"
        )
        XCTAssertEqual(
            text.replacingOccurrences(of: ". ", with: " "),
            segments.joined(),
            "no word changed anywhere on the path"
        )
    }
}
