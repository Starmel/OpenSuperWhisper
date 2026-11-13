import XCTest
import AppKit
@testable import OpenSuperWhisper

/// Interference safety: a transcript must never be typed into the wrong
/// application, and must never interleave with the user's own typing.
///
/// Both cases are produced here the way the machine produces them. The delivery
/// posts into whichever receiver is frontmost when the event is handed over, and
/// a competing keystroke reaches the receiver outside the delivery's own sink —
/// the one step a headless test must not take is posting the events through the
/// HID event tap for the window server to route.
///
/// Each case runs twice: once with a watch, which must stop the delivery at the
/// interference, and once without one, which is the behaviour before this
/// existed. The second run is not decoration: it is the same interference in the
/// same place, and it shows the assertion failing on the old behaviour — that is
/// what each test catches.
@MainActor
final class KeyboardSimulatorInterferenceTests: XCTestCase {

    /// Five blocks of twenty characters. The first sixty characters are the part
    /// a stopped delivery has typed; the rest is the tail that must never reach
    /// another application or be spliced into the user's typing.
    ///
    /// Every block is a letter no other block uses, so "the tail is absent" is a
    /// real assertion rather than an accident of a repetitive payload in which
    /// the tail happens to sit inside the typed prefix. The delivery is one
    /// character per key pair now, so the interference point is counted in
    /// characters: sixty of them, which is one hundred and twenty events.
    private static let payload = ["A", "B", "C", "D", "E"]
        .map { String(repeating: $0, count: 20) }
        .joined()
    private static let typedBeforeInterference = String(payload.prefix(60))
    private static let tail = String(payload.dropFirst(60))

    private static func receiver() -> TypingReceiverView {
        TypingReceiverView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    }

    /// Types the payload, routing every event to `frontmost`, and answers what
    /// the delivery did. `afterEachEvent` sees the number of events posted so
    /// far, which is where a test produces an interference at a chosen point.
    private static func deliver(
        to frontmost: @escaping () -> TypingReceiverView,
        watch: KeyboardSimulator.DeliveryWatch?,
        afterEachEvent: @escaping (Int) -> Void = { _ in }
    ) -> KeyboardSimulator.InjectionResult {
        var posted = 0
        return KeyboardSimulator.typeText(payload, trusted: true, watch: watch) { event in
            if let keyEvent = NSEvent(cgEvent: event) {
                frontmost().receive(keyEvent)
            }
            posted += 1
            afterEachEvent(posted)
        }
    }

    // MARK: - The frontmost application changes mid-delivery

    /// The user switches applications while the transcript is being typed: the
    /// delivery was aimed at `intended`, and after the sixtieth character the user
    /// is in `otherApplication`. What the live watch reads as a different frontmost
    /// process id is what this closure reports.
    func testDeliveryStopsWhenTheFrontmostApplicationChanges() {
        let intended = Self.receiver()
        let otherApplication = Self.receiver()
        var frontmost = intended

        let watch = KeyboardSimulator.DeliveryWatch { keyDownsPosted in
            if keyDownsPosted >= 60 { frontmost = otherApplication }
            return frontmost === intended ? nil : .focusChanged
        }

        let result = Self.deliver(to: { frontmost }, watch: watch)

        XCTAssertEqual(result.interruptedBy, .focusChanged, "the result must name the interference")
        XCTAssertEqual(result.deliveredCharacters, Self.typedBeforeInterference.count)
        XCTAssertEqual(result.eventsPosted, 120, "sixty character pairs were posted, and not one event more")
        XCTAssertEqual(
            intended.editor.string, Self.typedBeforeInterference,
            "what was typed before the switch must have arrived intact and in order"
        )

        // The acceptance for this mode: the tail of the transcript is absent
        // from the new target — not merely a flag saying the delivery stopped.
        XCTAssertEqual(
            otherApplication.editor.string, "",
            "nothing may reach the application that came to the front"
        )
        XCTAssertFalse(
            otherApplication.editor.string.contains(Self.tail),
            "the tail of the transcript reached the newly frontmost application: "
                + "\"\(otherApplication.editor.string)\""
        )

        // What that catches, run rather than claimed: the same switch at the same
        // point with no watch — today's behaviour — and the tail lands in the
        // other application.
        let unfixedIntended = Self.receiver()
        let unfixedOtherApplication = Self.receiver()
        var unfixedFrontmost = unfixedIntended
        let unfixed = Self.deliver(to: { unfixedFrontmost }, watch: nil) { posted in
            if posted == 120 { unfixedFrontmost = unfixedOtherApplication }
        }

        XCTAssertNil(unfixed.interruptedBy, "with no watch the whole transcript is posted")
        XCTAssertEqual(unfixed.eventsPosted, 200, "one pair per character of a hundred characters")
        XCTAssertEqual(unfixedIntended.editor.string, Self.typedBeforeInterference)
        XCTAssertEqual(
            unfixedOtherApplication.editor.string, Self.tail,
            "control: without a watch the remaining characters go to the new application"
        )
    }

    // MARK: - The user types mid-delivery

    /// The user's own keystroke: it reaches the focused application through the
    /// window server, not through this delivery's sink, and it arrives between
    /// the sixtieth and the sixty-first character. The watch reports it, so the
    /// delivery stops there instead of typing the tail around it.
    func testDeliveryStopsWhenTheUserTypesInsteadOfInterleaving() {
        let receiver = Self.receiver()

        let watch = KeyboardSimulator.DeliveryWatch { keyDownsPosted in
            guard keyDownsPosted >= 60 else { return nil }
            receiver.editor.insertText(
                "Q",
                replacementRange: NSRange(location: receiver.editor.string.utf16.count, length: 0)
            )
            return .userTyping
        }

        let result = Self.deliver(to: { receiver }, watch: watch)

        XCTAssertEqual(result.interruptedBy, .userTyping, "the result must name the interference")
        XCTAssertEqual(result.deliveredCharacters, Self.typedBeforeInterference.count)
        XCTAssertEqual(result.eventsPosted, 120, "sixty character pairs were posted, and not one event more")

        // Both streams did not mix: the transcript is one contiguous run, and the
        // user's own keystroke sits after it rather than between its characters.
        XCTAssertEqual(
            receiver.editor.string, Self.typedBeforeInterference + "Q",
            "expected the typed prefix and then the user's own keystroke, nothing between them"
        )
        XCTAssertFalse(
            receiver.editor.string.contains(Self.tail),
            "the tail of the transcript was typed after the user's keystroke: "
                + "\"\(receiver.editor.string)\""
        )

        // What that catches: the same keystroke at the same point with no watch,
        // where the two streams mix character by character.
        let unfixed = Self.receiver()
        let unfixedResult = Self.deliver(to: { unfixed }, watch: nil) { posted in
            guard posted == 120 else { return }
            unfixed.editor.insertText(
                "Q",
                replacementRange: NSRange(location: unfixed.editor.string.utf16.count, length: 0)
            )
        }

        XCTAssertNil(unfixedResult.interruptedBy)
        XCTAssertTrue(
            unfixed.editor.string.contains(Self.typedBeforeInterference + "Q" + Self.tail),
            "control: without a watch the user's keystroke lands between transcript characters: "
                + "\"\(unfixed.editor.string)\""
        )
    }

    // MARK: - The live watch's own readings

    /// The live watch's two probes, driven by stand-ins so the arithmetic that
    /// decides "the user typed" is exercised rather than assumed: what the
    /// session counted against what the delivery posted, and the frontmost
    /// application against the one the delivery was aimed at.
    func testTheLiveWatchTellsItsOwnKeystrokesFromTheUsers() {
        var frontmost: pid_t? = 501
        var seenByTheSession: UInt32 = 1_000
        let watch = KeyboardSimulator.DeliveryWatch.live(
            frontmostPID: { frontmost },
            keyDownCount: { seenByTheSession }
        )

        XCTAssertNil(watch.interference(keyDownsPosted: 0), "nothing posted, nothing seen: still safe")

        // The key down the delivery itself posted is not interference.
        seenByTheSession += 1
        XCTAssertNil(watch.interference(keyDownsPosted: 1))

        // A key down nobody in this delivery posted is the user typing.
        seenByTheSession += 1
        XCTAssertEqual(watch.interference(keyDownsPosted: 1), .userTyping)

        // An application that came to the front ends the delivery, whatever the
        // session's keystroke count says.
        seenByTheSession += 1
        frontmost = 502
        XCTAssertEqual(watch.interference(keyDownsPosted: 0), .focusChanged)

        // The quiet case, in the two shapes it can take: a session that counts
        // nothing this delivery posted, and a counter that went backwards. Both
        // have to be silence — this watch may never stop a delivery over the
        // events that delivery posted itself.
        let countingNothing = KeyboardSimulator.DeliveryWatch.live(
            frontmostPID: { 501 },
            keyDownCount: { 1_000 }
        )
        XCTAssertNil(
            countingNothing.interference(keyDownsPosted: 40),
            "the delivery stopped itself over keystrokes it posted and the session did not count"
        )
        let goneBackwards = KeyboardSimulator.DeliveryWatch.live(
            frontmostPID: { 501 },
            keyDownCount: { 999 }
        )
        XCTAssertNil(goneBackwards.interference(keyDownsPosted: 1))

        // A session with no frontmost application at all cannot report a focus
        // change, and must not treat its own ignorance as one.
        let unknownTarget = KeyboardSimulator.DeliveryWatch.live(
            frontmostPID: { nil },
            keyDownCount: { 1_000 }
        )
        XCTAssertNil(unknownTarget.interference(keyDownsPosted: 0))
    }

    /// Every key down the delivery posts is subtracted from the session's count,
    /// the Return and Tab ones included. Losing count of those would make the
    /// watch blame the delivery's own keystrokes and stop a healthy dictation.
    func testTheLiveWatchCountsTheKeyDownsOfControlCharacters() {
        var seenByTheSession: UInt32 = 0
        let watch = KeyboardSimulator.DeliveryWatch.live(
            frontmostPID: { 501 },
            keyDownCount: { seenByTheSession }
        )
        let text = "ab\ncd\tef"

        // A stand-in session that counts exactly what the delivery hands it.
        let result = KeyboardSimulator.typeText(text, trusted: true, watch: watch) { event in
            if event.type == .keyDown { seenByTheSession += 1 }
        }

        XCTAssertNil(result.interruptedBy, "the delivery stopped itself over its own keystrokes")
        XCTAssertEqual(result.deliveredCharacters, text.count)
        XCTAssertEqual(result.eventsPosted, 16, "eight characters, one pair each")
    }

    /// The quiet case end to end, against the real probes: with nothing
    /// competing, the live watch must leave the delivery completely alone.
    func testTheLiveWatchDoesNotStopADeliveryThatNothingInterferesWith() {
        let receiver = Self.receiver()

        let result = Self.deliver(to: { receiver }, watch: .live())

        XCTAssertNil(result.interruptedBy, "the live watch stopped a delivery nothing interfered with")
        XCTAssertEqual(result.deliveredCharacters, Self.payload.count)
        XCTAssertEqual(result.eventsPosted, 200, "one pair per character of a hundred characters")
        XCTAssertEqual(receiver.editor.string, Self.payload)
    }

    /// An empty transcript is not delivered, so nothing can interfere with it —
    /// and the watch must not even be asked, which is the one way this feature
    /// could have failed on the empty case.
    func testEmptyTextNeverConsultsTheWatch() {
        var checks = 0
        let watch = KeyboardSimulator.DeliveryWatch { _ in
            checks += 1
            return .userTyping
        }

        let result = KeyboardSimulator.typeText("", trusted: true, watch: watch) { _ in }

        XCTAssertEqual(checks, 0, "an empty transcript has nothing to interrupt")
        XCTAssertNil(result.interruptedBy)
        XCTAssertEqual(result.eventsPosted, 0)
        XCTAssertEqual(result.deliveredCharacters, 0)
    }
}
