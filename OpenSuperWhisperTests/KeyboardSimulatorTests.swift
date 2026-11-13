import XCTest
import AppKit
@testable import OpenSuperWhisper

final class KeyboardSimulatorTests: XCTestCase {

    // MARK: - Event production

    /// The character travels on the keyDown and on nothing else.
    ///
    /// This used to assert the opposite — that both events carried the character —
    /// which is the duplication hazard this pair was carrying: a target that
    /// inserts the text every event carries receives the character twice. What the
    /// keyUp must be is a release of the same key that says "no text here", and
    /// the payload has to be *cleared* to say that: an event whose Unicode string
    /// was never set reads back as whatever its key code produces, and key code 0
    /// is `a`.
    func testShortStringPostsOnePayloadCarryingKeyDownPerCharacter() throws {
        var events: [CGEvent] = []
        KeyboardSimulator.typeText("Hé!") { events.append($0) }

        // One pair per character: "H", "é", "!".
        XCTAssertEqual(events.count, 6)
        let keyDown = try XCTUnwrap(events.first)
        let keyUp = try XCTUnwrap(events[1])
        XCTAssertEqual(keyDown.type, .keyDown)
        XCTAssertEqual(keyUp.type, .keyUp)

        XCTAssertEqual(Self.unicodeString(of: keyDown), "H", "each keyDown carries one character")
        let characters = events.enumerated()
            .filter { $0.offset % 2 == 0 }
            .compactMap { Self.unicodeString(of: $0.element) }
        XCTAssertEqual(characters, ["H", "é", "!"])
        XCTAssertNil(
            Self.unicodeString(of: keyUp),
            "the keyUp must carry no text: a target that inserts what each event carries would "
            + "otherwise insert the character a second time"
        )
        // …and it stays the release of the key the character was pressed with, so a
        // target tracking key state sees a press and a release, not a stuck key.
        XCTAssertEqual(keyUp.getIntegerValueField(.keyboardEventKeycode),
                       keyDown.getIntegerValueField(.keyboardEventKeycode))
    }

    func testLongStringPostsTwoEventsPerCharacterInOrder() throws {
        let text = String(repeating: "x", count: 45)
        var events: [CGEvent] = []
        KeyboardSimulator.typeText(text) { events.append($0) }

        XCTAssertEqual(events.count, 90)
        for index in stride(from: 0, to: events.count, by: 2) {
            XCTAssertEqual(events[index].type, .keyDown)
            XCTAssertEqual(events[index + 1].type, .keyUp)
        }
        let typed = events.enumerated()
            .filter { $0.offset % 2 == 0 }
            .compactMap { Self.unicodeString(of: $0.element) }
            .joined()
        XCTAssertEqual(typed, text)
    }

    // MARK: - Control characters

    /// The flags that are not about *which side* of a modifier is held.
    ///
    /// `NSEvent.ModifierFlags.deviceIndependentFlagsMask` is `0xFFFF0000`; the low
    /// sixteen bits are the device-dependent ones (`0x20` left Option, `0x40`
    /// right Option), and `CGEventFlags` has no named constant for the mask.
    static let deviceIndependentFlags = CGEventFlags(rawValue: 0xFFFF0000)

    /// A Polish diacritic rides the **right** Option.
    ///
    /// The layout produces all nine of them with Option, and the application the
    /// captain dictates into owns the left Option for a shortcut of its own, so a
    /// generic (left) Option never delivers the character there. The posted pair
    /// carries the right key's device bit and never the left one's.
    func testDiacriticsRideTheRightOptionKey() {
        var events: [CGEvent] = []
        KeyboardSimulator.typeText("ą") { events.append($0) }

        XCTAssertEqual(events.count, 2, "one character, one key pair")
        for event in events {
            XCTAssertTrue(event.flags.contains(KeyboardSimulator.rightOptionDeviceFlag),
                          "the diacritic has to be posted with the right Option: \(event.flags)")
            XCTAssertEqual(event.flags.rawValue & 0x20, 0,
                           "the left Option bit must never be set: \(event.flags)")
        }
        TestFixtures.report("[keyboard] diacritic flags: \(events[0].flags.rawValue)")
    }

    /// A space with no key of its own is typed as a plain space, never as an
    /// Option combination.
    ///
    /// The layer walk answers a non-breaking or thin space with Option+Space or
    /// worse, and a target that rebuilds characters from key codes rather than
    /// reading the Unicode payload turns that into a character of its own layout
    /// — `å` on a US layout, which is the stray character that appeared at the end
    /// of a dictation twice.
    func testWhitespaceNeverRidesAModifiedLayer() {
        for space in [" ", "\u{00A0}", "\u{2009}", "\u{202F}"] {
            let resolved = KeyboardSimulator.key(for: space)
            XCTAssertEqual(resolved.keyCode, KeyboardSimulator.spaceKeyCode,
                           "\(space.debugDescription) has to be typed as a space")
            XCTAssertEqual(resolved.flags, [], "\(space.debugDescription) must carry no modifiers")
        }
        // …and the diacritics keep their layer: this is a whitespace rule, not a
        // retreat from the layout walk.
        XCTAssertEqual(KeyboardSimulator.key(for: "Ś").flags, [.maskAlternate, .maskShift])
    }

    /// A line break travels as **Shift+Return**, not Return.
    ///
    /// Return *sends* in every chat client — an e-mail dictated as greeting,
    /// body and sign-off arrived as three separate messages — while Shift+Return
    /// breaks the line in the same client without sending. The break is therefore
    /// posted the way the user's own hands would post it, and the flag is on both
    /// events of the pair: a client that tracks modifier state across the press
    /// and its release reads a different key if only one of them carries it.
    func testNewlineMapsToShiftedReturnKeyCode() throws {
        var events: [CGEvent] = []
        KeyboardSimulator.typeText("\n") { events.append($0) }

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].type, .keyDown)
        XCTAssertEqual(events[1].type, .keyUp)
        for event in events {
            XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode),
                           Int64(KeyboardSimulator.returnKeyCode))
            XCTAssertEqual(event.flags, .maskShift,
                           "a bare Return sends in a chat client; the line break has to be shifted")
        }
    }

    /// Tab keeps no modifiers: nothing about a tab sends a message.
    func testTabMapsToTabKeyCodeWithNoModifiers() throws {
        var events: [CGEvent] = []
        KeyboardSimulator.typeText("\t") { events.append($0) }

        XCTAssertEqual(events.count, 2)
        for event in events {
            XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode),
                           Int64(KeyboardSimulator.tabKeyCode))
            XCTAssertEqual(event.flags, [])
        }
    }

    /// Return and Tab travel as key codes with no text on them, press and
    /// release alike. An event whose Unicode string is merely left unset still
    /// reads back as the character its key code produces, so a target that
    /// inserts the text each event carries would insert the newline twice — once
    /// for the press and once for the release.
    func testReturnAndTabEventsCarryNoUnicodeText() {
        for control in ["\n", "\t"] {
            var events: [CGEvent] = []
            KeyboardSimulator.typeText(control) { events.append($0) }

            XCTAssertEqual(events.count, 2)
            for event in events {
                XCTAssertNil(
                    Self.unicodeString(of: event),
                    "\(control.debugDescription) has to travel as a key code alone, not as text"
                )
            }
        }

        // …and the key codes are still the ones that make the characters, in
        // press/release order.
        var events: [CGEvent] = []
        KeyboardSimulator.typeText("\n\t") { events.append($0) }
        XCTAssertEqual(events.map { $0.getIntegerValueField(.keyboardEventKeycode) },
                       [Int64(KeyboardSimulator.returnKeyCode),
                        Int64(KeyboardSimulator.returnKeyCode),
                        Int64(KeyboardSimulator.tabKeyCode),
                        Int64(KeyboardSimulator.tabKeyCode)])
    }

    /// A character the layout produces only with modifiers carries
    /// those modifiers, and with them a key a target can actually use.
    ///
    /// The key code alone was never the whole story: on this machine's layout all
    /// nine Polish diacritics are Option combinations, so before this every one of
    /// them rode key code `0x7F` — the code for no key at all — with no modifiers.
    /// A physical keyboard presses Option+A for `ą`; a target that rebuilds
    /// characters from key codes (a Citrix session, a virtual machine, a remote
    /// desktop) can do nothing with 0x7F and can read Option+A.
    func testADiacriticLedTextCarriesTheModifiersItsKeyNeeds() throws {
        // The layout is switched to the one whose mapping was measured, and put
        // back afterwards, because these cases run in parallel with classes that
        // switch layouts themselves — the active source is machine-wide, and a
        // first attempt at this assertion failed intermittently for exactly that
        // reason. A machine without that layout skips, like the other
        // layout-dependent cases in this suite.
        let original = ClipboardUtil.getCurrentInputSourceID()
        let target = "com.apple.keylayout.PolishPro"
        defer {
            if let original { _ = ClipboardUtil.switchToInputSource(withID: original) }
        }
        guard ClipboardUtil.switchToInputSource(withID: target) else {
            throw XCTSkip("layout \(target) not available on this machine")
        }
        TestFixtures.report("[keyboard] key-modifier case running on \(ClipboardUtil.getCurrentInputSourceID() ?? "nil")")

        var events: [CGEvent] = []
        KeyboardSimulator.typeText("ąb", trusted: true, post: { events.append($0) })

        let keyDown = try XCTUnwrap(events.first)
        XCTAssertEqual(keyDown.type, .keyDown)
        XCTAssertEqual(Self.unicodeString(of: keyDown), "ą", "the payload carries the character")
        XCTAssertTrue(
            keyDown.flags.contains(.maskAlternate),
            "a character this layout only produces with Option has to carry Option; "
            + "flags were \(keyDown.flags.rawValue) and the key code was "
            + "\(keyDown.getIntegerValueField(.keyboardEventKeycode))"
        )
        XCTAssertNotEqual(
            keyDown.getIntegerValueField(.keyboardEventKeycode),
            Int64(KeyboardSimulator.unmappedKeyCode),
            "…and a real key rather than the code for no key at all"
        )
        // The flags are exactly the layer's: a still-held Command must not turn
        // the character into a shortcut.
        XCTAssertFalse(keyDown.flags.contains(.maskCommand))

        // The layers around it, on the same layout: an uppercase diacritic needs
        // option *and* shift, an uppercase letter needs shift alone, and a plain
        // lowercase letter needs nothing.
        let uppercaseDiacritic = KeyboardSimulator.key(for: "Ś")
        XCTAssertEqual(uppercaseDiacritic.flags, [.maskAlternate, .maskShift])
        XCTAssertEqual(uppercaseDiacritic.keyCode, ClipboardUtil.findKey(for: "Ś")?.keyCode)
        XCTAssertEqual(KeyboardSimulator.key(for: "Z").flags, .maskShift)
        XCTAssertEqual(KeyboardSimulator.key(for: "z").flags, [])
    }

    /// …and a character led by a character no layout produces keeps the unmapped code
    /// and no modifiers, because there is no key to press for it.
    func testACharacterNoLayoutCanProduceKeepsTheUnmappedKeyCodeAndNoModifiers() throws {
        var events: [CGEvent] = []
        KeyboardSimulator.typeText("中文測試", trusted: true, post: { events.append($0) })

        let keyDown = try XCTUnwrap(events.first)
        XCTAssertEqual(keyDown.getIntegerValueField(.keyboardEventKeycode),
                       Int64(KeyboardSimulator.unmappedKeyCode))
        XCTAssertEqual(keyDown.flags, [])
    }

    // MARK: - The key code a text event carries

    /// Key code 0 is the `A` key, not "no key".
    ///
    /// A target that rebuilds characters from key codes instead of reading the
    /// Unicode string — a Citrix session above all: its viewer links no
    /// Unicode-payload reader at all — types `a` once per event for key code 0,
    /// which is the worst thing a text event can carry. Every character now rides
    /// its own event with the key and the modifiers the active layout produces it
    /// with, and a character no layer of the layout produces carries a code no
    /// key is defined for.
    func testEveryCharacterRidesTheKeyAndModifiersItsLayoutLayerNeeds() throws {
        // The layout is switched to the measured one and put back afterwards: the
        // active source is machine-wide and other classes in this suite switch it,
        // which made this case fail intermittently — the events were built under
        // one layout and looked up under another.
        let original = ClipboardUtil.getCurrentInputSourceID()
        let target = "com.apple.keylayout.PolishPro"
        defer { if let original { _ = ClipboardUtil.switchToInputSource(withID: original) } }
        guard ClipboardUtil.switchToInputSource(withID: target) else {
            throw XCTSkip("layout \(target) not available on this machine")
        }
        TestFixtures.report("[keyboard] per-character key case running on "
                            + "\(ClipboardUtil.getCurrentInputSourceID() ?? "nil")")

        var events: [CGEvent] = []
        // Every character of this payload starts with a base-layer character: "Z",
        // "ó" (Option+o), "j"… — the common shape of dictated text.
        KeyboardSimulator.typeText("Zażółć gęślą jaźń — 中文測試 Ж їß 😀 ok\n\ttail") { events.append($0) }

        let keyDowns = events.filter { $0.type == .keyDown }
        XCTAssertFalse(keyDowns.isEmpty)

        for keyDown in keyDowns {
            let keyCode = CGKeyCode(keyDown.getIntegerValueField(.keyboardEventKeycode))
            // A Return or Tab event is its own key; the rest carry text.
            if keyCode == KeyboardSimulator.returnKeyCode || keyCode == KeyboardSimulator.tabKeyCode {
                continue
            }
            guard let character = Self.unicodeString(of: keyDown), let first = character.first else {
                XCTFail("a text event carries no text at all")
                continue
            }
            // Four layers now: a character the base layer lacks may still be
            // reachable with shift or option, and that layer's key is what the
            // event has to carry.
            let resolved = ClipboardUtil.findKey(for: first)
            XCTAssertEqual(
                keyCode, resolved?.keyCode ?? KeyboardSimulator.unmappedKeyCode,
                "character \(String(reflecting: character)) is posted with the key the layout produces "
                + "\(String(reflecting: first)) with, or with the unmapped code"
            )
            let flags = keyDown.flags
            // The *device* bits say which side of a modifier is held, and the app
            // deliberately posts the right Option for a diacritic — the target
            // application owns the left one for a shortcut of its own — so the
            // layer comparison drops the device-dependent bits and the side is
            // asserted on its own right after.
            XCTAssertEqual(
                flags.intersection(Self.deviceIndependentFlags),
                (resolved?.flags ?? []).intersection(Self.deviceIndependentFlags),
                "…and with the modifiers that layer needs, and no others"
            )
            if (resolved?.flags ?? []).contains(.maskAlternate) {
                XCTAssertTrue(
                    flags.contains(KeyboardSimulator.rightOptionDeviceFlag),
                    "an Option layer has to ride the right Option key: \(flags)"
                )
                XCTAssertEqual(
                    flags.rawValue & 0x20, 0,
                    "the left Option bit must never be set: \(flags)"
                )
            }
            // No assertion about key code 0 here. Which key produces which
            // character is the layout's business: on the layout active on this
            // machine 0 is the `a` key, and on a Polish typewriter layout the
            // same key code produces `ą`. What has to hold is the pair above —
            // the key and the modifiers are the ones this layout uses for this
            // character — and that is layout-independent by construction.
        }
    }

    /// A character the layout produces on no layer — CJK, Cyrillic, emoji —
    /// carries `unmappedKeyCode`, so no target can turn it into a character the
    /// user did not dictate.
    func testACharacterTheLayoutCannotTypeCarriesTheUnmappedKeyCode() {
        // No layer of any layout produces these with one key.
        XCTAssertEqual(KeyboardSimulator.keyCode(for: "中文測試"), KeyboardSimulator.unmappedKeyCode)
        XCTAssertEqual(KeyboardSimulator.keyCode(for: "Ж їß"), KeyboardSimulator.unmappedKeyCode)
        XCTAssertEqual(KeyboardSimulator.keyCode(for: "😀 ok"), KeyboardSimulator.unmappedKeyCode)
        XCTAssertEqual(KeyboardSimulator.unmappedKeyCode, 0x7F)
        XCTAssertNotEqual(KeyboardSimulator.unmappedKeyCode, KeyboardSimulator.returnKeyCode)
        XCTAssertNotEqual(KeyboardSimulator.unmappedKeyCode, KeyboardSimulator.tabKeyCode)

        // The Polish diacritics are *not* in this list any more — this machine's
        // layout produces them with Option, so they resolve to a key and that
        // layer's modifiers. That is pinned by
        // `testADiacriticLedChunkCarriesTheModifiersItsKeyNeeds`, which switches
        // the layout itself and so does not race the classes that switch layouts
        // in parallel with this one; asserting it here from whatever layout is
        // active failed intermittently for exactly that reason.
    }

    func testCarriageReturnAndCRLFMapToSingleReturn() {
        var crEvents: [CGEvent] = []
        KeyboardSimulator.typeText("\r") { crEvents.append($0) }
        XCTAssertEqual(crEvents.count, 2)

        var crlfEvents: [CGEvent] = []
        KeyboardSimulator.typeText("\r\n") { crlfEvents.append($0) }
        XCTAssertEqual(crlfEvents.count, 2)
        for event in crlfEvents {
            XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode),
                           Int64(KeyboardSimulator.returnKeyCode))
        }
    }

    func testMixedContentSplitsAroundControlCharacter() throws {
        var events: [CGEvent] = []
        KeyboardSimulator.typeText("ab\ncd") { events.append($0) }

        // "a", "b", Return, "c", "d": one pair each.
        XCTAssertEqual(events.count, 10)
        XCTAssertEqual(Self.unicodeString(of: events[0]), "a")
        XCTAssertEqual(Self.unicodeString(of: events[2]), "b")
        XCTAssertEqual(events[4].getIntegerValueField(.keyboardEventKeycode),
                       Int64(KeyboardSimulator.returnKeyCode))
        XCTAssertEqual(Self.unicodeString(of: events[6]), "c")
        XCTAssertEqual(Self.unicodeString(of: events[8]), "d")
    }

    // MARK: - Empty input

    func testEmptyStringPostsNothing() {
        var events: [CGEvent] = []
        KeyboardSimulator.typeText("") { events.append($0) }
        XCTAssertTrue(events.isEmpty)
    }

    /// The default sink posts nothing under test, and counts what it refused.
    ///
    /// This is the mechanism behind the suite's inertness: a case that reaches the
    /// default sink — a view model built with its default arguments, say — hands
    /// its events to a closure whose only branch here is `return`. What a run can
    /// report afterwards is the number of events that took that branch.
    func testTheDefaultSinkRefusesToPostUnderTestAndCountsWhatItRefused() {
        let before = KeyboardSimulator.eventsDroppedUnderTest
        let (post, _) = { () -> ((CGEvent) -> Void, () -> [CGEvent]) in
            var events: [CGEvent] = []
            return ({ events.append($0) }, { events })
        }()
        // The default sink itself, by calling it through the parameter default.
        _ = KeyboardSimulator.typeText("ab")

        XCTAssertEqual(KeyboardSimulator.eventsDroppedUnderTest, before + 4,
                       "four events for two characters, all refused")
        // And a case that wants to see them still can.
        KeyboardSimulator.typeText("ab", post: post)
        XCTAssertEqual(KeyboardSimulator.eventsDroppedUnderTest, before + 4,
                       "an explicit sink is not the default one, so nothing more is refused")
        TestFixtures.report("[keyboard] default sink has refused "
                            + "\(KeyboardSimulator.eventsDroppedUnderTest) events under test so far")
    }

    // MARK: - Clipboard isolation

    func testTypeTextDoesNotTouchPasteboard() {
        let changeCountBefore = NSPasteboard.general.changeCount
        KeyboardSimulator.typeText("clipboard must stay untouched 😀\n") { _ in }
        XCTAssertEqual(NSPasteboard.general.changeCount, changeCountBefore)
    }

    // MARK: - Reported outcome

    /// The outcome is what the one-line dictation log and the user-facing
    /// warning are built from, so it must report the trust state the injection
    /// actually saw and count the events it actually posted.
    func testTypeTextReportsLiveTrustAndPostedEventCount() {
        var events: [CGEvent] = []
        let result = KeyboardSimulator.typeText("Hé!") { events.append($0) }

        XCTAssertEqual(result.eventsPosted, events.count)
        XCTAssertEqual(result.eventsPosted, 6, "one pair per character of \"Hé!\"")
        XCTAssertTrue(result.injected)
        XCTAssertEqual(result.trusted, KeyboardSimulator.isTrustedForInjection)
    }

    func testTypeTextReportsNothingPostedForEmptyText() {
        let result = KeyboardSimulator.typeText("") { _ in }

        XCTAssertEqual(result.eventsPosted, 0)
        XCTAssertFalse(result.injected)
    }

    /// The trust answer is injectable, so a test can pin it instead of depending
    /// on whether the host process happens to hold the Accessibility grant.
    func testTypeTextHonoursAnInjectedTrustValue() {
        var events: [CGEvent] = []
        let result = KeyboardSimulator.typeText("pinned", trusted: false) { events.append($0) }

        XCTAssertFalse(result.trusted)
        XCTAssertEqual(result.eventsPosted, events.count)
        XCTAssertEqual(result.eventsPosted, 12)
    }

    // MARK: - Helpers

    /// True when a character's UTF-16 round-trips losslessly and contains no
    /// replacement character (which would signal a lone/unpaired surrogate).
    private static func decodesCleanly(_ character: String) -> Bool {
        let units = Array(character.utf16)
        let decoded = String(decoding: units, as: UTF16.self)
        return Array(decoded.utf16) == units
            && !decoded.unicodeScalars.contains { $0.value == 0xFFFD }
    }

    /// Reads the Unicode string stored on a synthetic keyboard event.
    private static func unicodeString(of event: CGEvent) -> String? {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 64)
        event.keyboardGetUnicodeString(maxStringLength: buffer.count,
                                      actualStringLength: &length,
                                      unicodeString: &buffer)
        guard length > 0 else { return nil }
        return String(utf16CodeUnits: buffer, count: length)
    }
}

// MARK: - End-to-end delivery

/// The smallest receiver that can host real key events: it is handed the events
/// the delivery path posts and gives each one to AppKit's key-binding machinery,
/// and every insertion goes through a real `NSTextView` — the characters, the
/// Return and the Tab are inserted by AppKit, not by this class.
///
/// It is a plain `NSView` rather than a subclass of `NSTextView` because
/// `NSTextView.keyDown` routes through its window's input context, and a
/// headless test has no key window; a bare view's `interpretKeyEvents` uses the
/// same standard key bindings (Return resolves to `insertNewline:`, Tab to
/// `insertTab:`).
final class TypingReceiverView: NSView {
    let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))

    override var acceptsFirstResponder: Bool { true }

    /// Hands one event of the posted stream to the receiver, the way the window
    /// server would after routing it to the focused application.
    func receive(_ event: NSEvent) {
        switch event.type {
        case .keyDown: keyDown(with: event)
        case .keyUp: keyUp(with: event)
        default: break
        }
    }

    override func keyDown(with event: NSEvent) {
        interpretKeyEvents([event])
    }

    override func keyUp(with event: NSEvent) {}

    override func insertText(_ string: Any) {
        switch string {
        case let text as String:
            editor.insertText(text, replacementRange: caretAtEnd())
        case let attributed as NSAttributedString:
            editor.insertText(attributed.string, replacementRange: caretAtEnd())
        default:
            break
        }
    }

    override func insertNewline(_ sender: Any?) {
        _ = caretAtEnd()
        editor.insertNewline(sender)
    }

    override func insertTab(_ sender: Any?) {
        _ = caretAtEnd()
        editor.insertTab(sender)
    }

    /// Puts the caret after the last character and answers where that is.
    @discardableResult
    private func caretAtEnd() -> NSRange {
        let end = NSRange(location: editor.string.utf16.count, length: 0)
        editor.setSelectedRange(end)
        return end
    }
}

/// A receiver for the class of target whose behaviour cannot be observed from
/// this side — the virtual-machine guest the captain dictates into by way of a
/// host application that forwards its input.
///
/// It is a model, not a capture. It reads the events the delivery path posts the
/// way a HID-forwarding host reads them: it takes the text the event itself
/// carries (`kCGEventKeyboardUnicodeString`, the field `keyboardSetUnicodeString`
/// fills) and inserts it for **every event that carries one, keyUp included**,
/// because what a guest receives from such a host is a stream of insertions, not
/// a stream of key transitions. Nothing here says the captain's target behaves
/// this way — nothing ever recorded what it received — and the case that drives
/// this receiver is written as a guard on the event shape for exactly that
/// reason.
///
/// An event with no text on it is reconstructed from its key code, the way a
/// guest with a keyboard layout of its own does; a keyUp with no text is a
/// release and inserts nothing.
///
/// The difference from `TypingReceiverView` above is what makes this one worth
/// having: that receiver goes through AppKit's key bindings and therefore ignores
/// keyUp exactly as the framework's own text system does, so it could not see a
/// character posted twice no matter how the events were built.
final class HidForwardedReceiverView: NSView {
    /// Everything the target ended up with, in the order it inserted it.
    private(set) var inserted = ""

    override var acceptsFirstResponder: Bool { true }

    /// Hands one event of the posted stream to this target.
    func receive(_ event: CGEvent) {
        if let payload = Self.unicodePayload(of: event), !payload.isEmpty {
            inserted += payload
            return
        }
        // No text on the event: a guest inserts from the key code it was given,
        // under its own layout. Only a key *press* inserts; a release does not.
        guard event.type == .keyDown else { return }
        switch event.getIntegerValueField(.keyboardEventKeycode) {
        case Int64(KeyboardSimulator.returnKeyCode):
            // A chat client's rule, which is the rule this target models: a bare
            // Return sends the message, a shifted Return breaks the line. So the
            // receiver marks a send instead of inserting a newline, and an
            // unshifted Return anywhere in the delivery fails the round-trip
            // assertion below — which is exactly the defect it exists to catch.
            if event.flags.contains(.maskShift) {
                inserted += "\n"
            } else {
                inserted += "<sent>"
            }
        case Int64(KeyboardSimulator.tabKeyCode):
            inserted += "\t"
        default:
            // Whatever this key code means in the guest's own layout — the
            // character the delivery never asked for.
            inserted += "«\(event.getIntegerValueField(.keyboardEventKeycode))»"
        }
    }

    /// The text an event carries, or `nil` when it carries none.
    static func unicodePayload(of event: CGEvent) -> String? {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 512)
        event.keyboardGetUnicodeString(maxStringLength: buffer.count,
                                       actualStringLength: &length,
                                       unicodeString: &buffer)
        guard length > 0 else { return nil }
        return String(utf16CodeUnits: buffer, count: length)
    }
}

/// The path the captain dictates through every day — the transcript reaches the
/// focused application as synthetic keystrokes, the clipboard untouched — end to
/// end and without naming a keyboard layout.
///
/// `ClipboardUtilPasteIntegrationTests` is gated on layouts a normal machine does
/// not have, so on the machine the app ships to it proves nothing about delivered
/// text. This case reads the input source that is *active* at run time, never
/// switches it, and types a payload the active layout has no keys for, so a
/// delivery path that consulted the layout is caught here on any machine; that is
/// the layout-independence the layout-gated cases above can only check on the
/// machines that have their layout.
///
/// Not covered: the HID event tap and the window server's routing of the posted
/// events to the frontmost application, the one step a headless test must not
/// take. Everything from the posted event onwards is real.
@MainActor
final class KeyboardSimulatorDeliveryTests: XCTestCase {

    /// Multi-character and multi-script: longer than
    /// several characters and several scripts, and carrying
    /// characters no single layout produces (CJK, Cyrillic, emoji) plus a
    /// newline and a tab.
    private static let payload = "Zažółć gęślą jaźń — 中文測試 Ж їß 😀 ok\n\ttail"

    /// The payload's single-scalar BMP characters: `findKeycodeForCharacter`
    /// reads one UTF-16 unit, so the emoji and the control characters are left
    /// out of the layout probe rather than fed to it.
    private static let payloadCharacters: [Character] = Array(payload).filter { character in
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first,
              scalar.value <= 0xFFFF
        else { return false }
        return !character.isWhitespace && !character.isNewline
    }

    func testTypesTheExactTextThroughTheActiveInputSource() throws {
        // Resolved at run time and never switched: whatever layout this machine
        // has active is the layout the typing happens under.
        let activeSourceID = try XCTUnwrap(
            ClipboardUtil.getCurrentInputSourceID(),
            "a machine in a GUI session always has an active input source"
        )

        let receiver = TypingReceiverView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        var posted: [CGEvent] = []

        // The one step replaced: the app posts each event to the HID event tap
        // for the window server to route to the focused application; here the
        // event goes straight to the receiver.
        let result = KeyboardSimulator.typeText(Self.payload, trusted: true) { event in
            posted.append(event)
            guard let keyEvent = NSEvent(cgEvent: event) else { return }
            receiver.receive(keyEvent)
        }

        XCTAssertTrue(result.injected)
        XCTAssertEqual(result.eventsPosted, posted.count)
        XCTAssertEqual(
            receiver.editor.string, Self.payload,
            "the focused application must receive the transcript character for character"
        )
        // The other half of this path's contract — the clipboard stays untouched
        // — is asserted by `KeyboardSimulatorTests.testTypeTextDoesNotTouchPasteboard`
        // and deliberately not repeated here: the pasteboard is process-wide and
        // the paste cases run in parallel with this one.

        // Layout independence, shown at run time rather than assumed: the
        // payload carries characters the active layout has no key for, so the
        // delivered text above cannot have come from that layout's key codes.
        let untypedByTheLayout = Self.payloadCharacters.filter {
            ClipboardUtil.findKeycodeForCharacter($0) == nil
        }
        XCTAssertFalse(
            untypedByTheLayout.isEmpty,
            "the active input source (\(activeSourceID)) has a key for every payload character, "
            + "so this case would not show that delivery ignores the layout"
        )
        TestFixtures.report(
            "keyboard delivery: active input source \(activeSourceID), \(result.eventsPosted) events, "
            + "payload characters that layout cannot type: "
            + untypedByTheLayout.map(String.init).joined()
        )
    }

    /// The event shape, pinned against the hazard it carried: a target that
    /// inserts the text every event carries must receive each character once, not
    /// once per posted event.
    ///
    /// This is a guard, not a reproduction. Nothing ever captured the events the
    /// captain's failing target received, so no claim is made here that his
    /// target inserts on both transitions — what the case pins is that the pair
    /// this app posts does not hand the same text over twice, whatever the target
    /// does with the events. It failed against the old shape, where the character
    /// travelled on the keyUp as well as the keyDown: 80 characters received for
    /// a 40-character payload.
    func testATargetThatInsertsOnBothEventsReceivesEachCharacterOnce() {
        let receiver = HidForwardedReceiverView()

        let result = KeyboardSimulator.typeText(Self.payload, trusted: true) { receiver.receive($0) }

        XCTAssertTrue(result.injected)
        XCTAssertEqual(
            receiver.inserted, Self.payload,
            "a target that inserts what each event carries has to receive the transcript once; "
            + "it received \(receiver.inserted.count) characters for a \(Self.payload.count)-character payload"
        )
    }

    /// The captain's own case: a dictated e-mail is three lines, and it has to
    /// arrive as **one** message.
    ///
    /// The target here is the chat client's rule — a bare Return sends, a shifted
    /// Return breaks the line — so this fails with `<sent>` in place of a
    /// newline if the break ever goes out unshifted again, which is exactly what
    /// happened: greeting, body and sign-off arrived as three messages.
    func testAMultiLineEmailArrivesAsOneMessage() {
        let email = "Dzień dobry,\n\nprzesuwam wdrożenie na poniedziałek.\n\nZ poważaniem"
        let receiver = HidForwardedReceiverView()

        let result = KeyboardSimulator.typeText(email, trusted: true) { receiver.receive($0) }

        XCTAssertTrue(result.injected)
        XCTAssertEqual(receiver.inserted, email,
                       "a three-paragraph e-mail has to arrive whole")
        XCTAssertFalse(receiver.inserted.contains("<sent>"),
                       "no line break may be sent as a bare Return: \(receiver.inserted)")
        XCTAssertEqual(receiver.inserted.filter { $0 == "\n" }.count, 4,
                       "all four line breaks of the e-mail have to survive")
        TestFixtures.report("[keyboard] multi-line e-mail delivered as one message, "
                            + "\(result.eventsPosted) events")
    }
}
