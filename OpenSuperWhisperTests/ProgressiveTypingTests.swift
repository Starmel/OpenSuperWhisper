import AppKit
import XCTest
@testable import OpenSuperWhisper

/// Progressive typing: the delivery half, which is the half that exists without a
/// text source.
///
/// What a source would have to provide is measured elsewhere (`ProgressiveTyping`'s
/// own note): nothing in the app produces partial text today, so these cases drive
/// committed segments by hand. What they pin is everything that does not depend on
/// where the text came from: that only the new tail is typed, that a repeat types
/// nothing, that a contradiction is refused rather than guessed at, that an
/// interruption stops the stream, and that the typing itself goes through the
/// per-character path with the layout's key and modifiers.
@MainActor
final class ProgressiveTypingTests: XCTestCase {

    /// A sink that records the events a stream posted.
    private func recorder() -> ((CGEvent) -> Void, () -> [CGEvent]) {
        var events: [CGEvent] = []
        return ({ events.append($0) }, { events })
    }

    // MARK: - The append-only rule

    func testCommittedSegmentsTypeOnlyTheirNewTail() {
        var stream = ProgressiveTyping.Stream()
        let (post, events) = recorder()

        var delivered: [Int] = []
        for segment in ["Ala", "Ala ma", "Ala ma kota"] {
            delivered.append(ProgressiveTyping.commit(segment, into: &stream, post: post).deliveredCharacters)
        }

        XCTAssertEqual(stream.typed, "Ala ma kota")
        XCTAssertEqual(delivered, [3, 3, 5],
                       "each commit types only what it added: \"Ala\", \" ma\", \" kota\"")
        XCTAssertEqual(events().count, 2 * (3 + 3 + 5), "one pair per character typed")
        XCTAssertFalse(stream.contradicted)
    }

    /// The case a naive implementation gets wrong: a segment already covered by
    /// what the target has must type nothing, not the whole segment again.
    func testARepeatedSegmentTypesNothing() {
        var stream = ProgressiveTyping.Stream()
        let (post, events) = recorder()

        XCTAssertEqual(ProgressiveTyping.commit("Ala ma kota", into: &stream, post: post).eventsPosted,
                       2 * "Ala ma kota".count)
        let repeated = ProgressiveTyping.commit("Ala ma kota", into: &stream, post: post)

        XCTAssertEqual(repeated.eventsPosted, 0, "a repeat must not be typed again")
        XCTAssertEqual(repeated.deliveredCharacters, 0)
        XCTAssertEqual(events().count, 2 * "Ala ma kota".count, "…and not one event more")
        XCTAssertFalse(stream.contradicted)
    }

    /// A committed segment that is not an extension of what the target holds is
    /// the case this design cannot express: it is refused and recorded, not
    /// guessed at, and never typed twice.
    func testASegmentThatIsNotAnExtensionIsRefusedAndRecorded() {
        var stream = ProgressiveTyping.Stream()
        let (post, events) = recorder()

        _ = ProgressiveTyping.commit("Ala ma kota", into: &stream, post: post)
        let eventsBefore = events().count
        let contradicted = ProgressiveTyping.commit("Ala ma psa", into: &stream, post: post)

        XCTAssertEqual(contradicted.eventsPosted, 0, "a contradiction types nothing")
        XCTAssertTrue(stream.contradicted, "…and is recorded, so a caller can report it")
        XCTAssertEqual(stream.typed, "Ala ma kota", "the target keeps what it has")
        XCTAssertEqual(events().count, eventsBefore)
    }

    /// An interruption stops the stream for good: nothing more is typed, whatever
    /// the source commits afterwards.
    func testAnInterruptedDeliveryStopsTheStream() {
        var stream = ProgressiveTyping.Stream()
        let (post, events) = recorder()
        let stop = KeyboardSimulator.DeliveryWatch { _ in .focusChanged }

        let first = ProgressiveTyping.commit("Ala ma", into: &stream, watch: stop, post: post)
        XCTAssertEqual(first.interruptedBy, .focusChanged)
        XCTAssertEqual(stream.stoppedBy, .focusChanged)
        XCTAssertFalse(stream.isHealthy)

        let eventsAfterStop = events().count
        let later = ProgressiveTyping.commit("Ala ma kota", into: &stream, watch: stop, post: post)
        XCTAssertEqual(later.eventsPosted, 0, "a stopped stream types nothing, ever")
        XCTAssertEqual(events().count, eventsAfterStop)
    }

    // MARK: - The typing itself

    /// The typing half is the same path a finished transcript uses: one
    /// keyDown/keyUp pair per character, with the layout's key and the modifiers
    /// that layer needs.
    func testTypedCharactersRideThePerCharacterPathWithTheirLayer() throws {
        var stream = ProgressiveTyping.Stream()
        let (post, events) = recorder()

        XCTAssertEqual(ProgressiveTyping.commit("Zażółć", into: &stream, post: post).deliveredCharacters,
                       "Zażółć".count)
        let keyDowns = events().filter { $0.type == .keyDown }
        XCTAssertEqual(keyDowns.count, "Zażółć".count, "one pair per character")
        let payloads = keyDowns.compactMap { event -> String? in
            var length = 0
            var buffer = [UniChar](repeating: 0, count: 32)
            event.keyboardGetUnicodeString(maxStringLength: buffer.count,
                                           actualStringLength: &length,
                                           unicodeString: &buffer)
            guard length > 0 else { return nil }
            return String(utf16CodeUnits: buffer, count: length)
        }
        XCTAssertEqual(payloads.joined(), "Zażółć")
        XCTAssertTrue(keyDowns.contains { $0.flags.contains(.maskAlternate) },
                      "the diacritics in this word need Option on this machine's layout")
    }

    /// An empty tail posts nothing at all.
    func testAnEmptyTailPostsNothing() {
        let (post, events) = recorder()
        let result = ProgressiveTyping.type("", post: post)
        XCTAssertEqual(result.eventsPosted, 0)
        XCTAssertTrue(events().isEmpty)
    }

    // MARK: - The pacing

    /// The delivery pauses between characters in production, and not under test.
    func testPacingIsSettableAndOffUnderTest() {
        XCTAssertEqual(KeyboardSimulator.defaultInterCharacterDelay, 0.002)
        XCTAssertEqual(KeyboardSimulator.interCharacterDelay, 0,
                       "a test host posts nothing, so it must not wait between events")
    }
}
