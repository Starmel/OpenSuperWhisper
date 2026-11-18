import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import os

/// Delivers text to the focused application by simulating keyboard events.
///
/// This is the path that never touches `NSPasteboard`. Each character is
/// carried by a `CGEvent` via `keyboardSetUnicodeString`, which makes the output
/// Unicode-complete and independent of the active keyboard layout. It is the
/// mechanism `TextDelivery` uses for every native macOS target; for a target
/// that forwards input to a machine this one does not control it hands over to
/// the clipboard paste instead, because the Unicode string on an event does not
/// survive that hop — see `TextDelivery` for why that trade is made.
enum KeyboardSimulator {

    /// What one injection attempt observed and did.
    ///
    /// The trust value is read at the moment of injection, not cached: macOS
    /// re-evaluates an app's Accessibility grant while it runs, so a value read
    /// at launch (or at the previous dictation) can be wrong by the time the
    /// keystrokes are posted.
    struct InjectionResult: Equatable {
        /// Live `AXIsProcessTrusted()` observed immediately before posting.
        let trusted: Bool
        /// How many events were handed to `post`.
        let eventsPosted: Int

        /// What ended the delivery before the whole transcript had been posted,
        /// or `nil` when it was posted in full. `eventsPosted` keeps its meaning
        /// either way: how many events were handed to `post`.
        var interruptedBy: DeliveryInterruption?
        /// How many characters of the transcript had been handed to `post` when
        /// the delivery ended — the whole transcript when `interruptedBy` is
        /// `nil`. Counted over the text after CR/CRLF normalisation, and a
        /// The text after CR/CRLF normalisation is delivered one character at a
        /// time, so this is also the number of characters handed over.
        var deliveredCharacters: Int = 0
        /// Which of `TextDelivery`'s mechanisms produced these numbers. The
        /// caller logs it, so a dictation that arrived wrong can be traced to
        /// the path it took.
        var mechanism: DeliveryMechanism = .keystrokes
        /// The bundle identifier of the application the delivery was aimed at,
        /// when the caller can see it. Logged with the rest: which application
        /// was in front is the first thing a delivery that went wrong has to be
        /// asked about, and the answer is not recoverable afterwards.
        var targetBundleIdentifier: String?
        /// How well that application was known to redirect its input — the
        /// difference between a bundle identifier measured on this machine and a
        /// vendor-prefix guess. Logged, because the guess is the weak part of the
        /// target rule and a session that keeps receiving keystrokes has to be
        /// visible in the record rather than inferred from a wrong transcript.
        var targetMatch: TextDelivery.TargetMatch?

        /// Whether any keystroke was actually handed to the system.
        var injected: Bool { eventsPosted > 0 }
    }

    /// Why a delivery stopped before it had typed the whole transcript.
    enum DeliveryInterruption: Equatable, CustomStringConvertible {
        /// Another application came to the front: every remaining character
        /// would have been typed into that one instead of the intended target.
        case focusChanged
        /// The user typed while the transcript was being posted: continuing
        /// would have mixed the two streams character by character.
        case userTyping

        /// The token the one-line dictation record carries.
        var description: String {
            switch self {
            case .focusChanged: return "focus-changed"
            case .userTyping: return "user-typing"
            }
        }
    }

    /// Watches a delivery for the two interferences that make it unsafe to keep
    /// typing, and answers before each pair of events whether it may go out.
    ///
    /// The checks have to be synchronous queries of the login session's own
    /// state, because a delivery is one uninterrupted main-thread turn — a
    /// 1000-character transcript is posted in a fraction of a millisecond: an
    /// `NSEvent` monitor or an event tap is run-loop driven and cannot run its
    /// callback inside that turn, so it could only report a keystroke after the
    /// delivery was already over.
    struct DeliveryWatch {
        private let check: (_ keyDownsPosted: Int) -> DeliveryInterruption?

        /// A watch built from a check of the caller's own — how a test drives an
        /// interference a headless machine must not be made to produce.
        init(interference: @escaping (_ keyDownsPosted: Int) -> DeliveryInterruption?) {
            self.check = interference
        }

        /// Answers whether anything interfered once the delivery had posted
        /// `keyDownsPosted` key-down events; `nil` means "still safe".
        func interference(keyDownsPosted: Int) -> DeliveryInterruption? {
            check(keyDownsPosted)
        }

        /// A watch over the live login session.
        ///
        /// - Focus: the frontmost application is read once, when the watch is
        ///   made — that is the delivery target, because the watch is made as
        ///   the delivery begins — and compared with the frontmost application
        ///   at every checkpoint. A different process ends the delivery before
        ///   the next event goes out, so nothing reaches the application that
        ///   came to the front. A session with no frontmost application (or one
        ///   the probe cannot read) is treated as "unchanged" rather than as
        ///   interference: this check must never stop a delivery on its own
        ///   ignorance.
        /// - Typing: `CGEventSource.counterForEventType` reports how many key
        ///   downs have been seen in the combined session state. That table, in
        ///   CoreGraphics' words, "reflects the combined state of all event
        ///   sources posting to the current user login session", and this
        ///   process is one of them — it creates its events from a
        ///   `combinedSessionState` source — so the delivery's own key downs are
        ///   part of the number and subtracting the ones it posted leaves the
        ///   keystrokes somebody else made. A keystroke that is not part of this
        ///   delivery is interference whether it came from the keyboard or from
        ///   another process typing into the same application.
        ///
        /// Neither probe can misfire on the quiet case: with nothing competing,
        /// the surplus over the delivery's own posts is exactly zero, and a
        /// counter that has not counted this process's posts (or has gone
        /// backwards) makes the surplus negative, which is also silence. The
        /// arithmetic can never stop a delivery over the events that delivery
        /// itself posted; its failure mode is a missed stop, never a stopped
        /// dictation.
        ///
        /// Both probes are injectable for the same reason `trusted` and `post`
        /// are: a headless test must not produce a real interference, so it
        /// drives the readings instead (see `KeyboardSimulatorInterferenceTests`).
        static func live(
            frontmostPID: @escaping () -> pid_t? = {
                NSWorkspace.shared.frontmostApplication?.processIdentifier
            },
            keyDownCount: @escaping () -> UInt32 = {
                CGEventSource.counterForEventType(.combinedSessionState, eventType: .keyDown)
            }
        ) -> DeliveryWatch {
            let target = frontmostPID()
            let reference = keyDownCount()
            return DeliveryWatch { keyDownsPosted in
                if let target, let frontmost = frontmostPID(), frontmost != target {
                    return .focusChanged
                }
                let seenSinceDeliveryBegan = keyDownCount()
                guard seenSinceDeliveryBegan >= reference else { return nil }
                let keystrokes = Int(seenSinceDeliveryBegan - reference)
                return keystrokes > keyDownsPosted ? .userTyping : nil
            }
        }
    }

    /// The unified-log subsystem and category of the one-line-per-dictation
    /// injection record, readable with
    /// `log stream --predicate 'subsystem == "ru.starmel.OpenSuperWhisper"'`.
    static let logSubsystem = "ru.starmel.OpenSuperWhisper"
    static let logCategory = "keyboard-injection"
    private static let log = Logger(subsystem: logSubsystem, category: logCategory)

    /// Live answer to "may this process post synthetic keystrokes right now?".
    static var isTrustedForInjection: Bool { AXIsProcessTrusted() }

    /// Where production hands its events: the HID event tap.
    ///
    /// Under test it hands them nowhere. A test host is a real application with
    /// the app's own bundle identifier, so a suite that reaches the default sink
    /// types into whatever is frontmost on the machine — which is exactly what
    /// happened: the captain's unified log shows an app-hosted test process
    /// emitting `injected=1` keystrokes into his frontmost application at 14:32,
    /// 14:38, 14:41, 14:45, 14:51, 14:54 and 14:59 on the day this was written.
    /// A case that wants to see events passes its own sink, which is what every
    /// delivery case does; the default must be the one that cannot damage the
    /// machine it runs on.
    static let livePostSink: (CGEvent) -> Void = { event in
        guard !OpenSuperWhisperApp.isRunningTests else {
            eventsDroppedUnderTest += 1
            return
        }
        event.post(tap: .cghidEventTap)
    }

    /// How many events the default sink has refused to post because this process
    /// is a test host.
    ///
    /// Not decoration: it is the witness that the suite's deliveries went nowhere.
    /// The sink's only branch under test is the `return` above, and this count is
    /// what a run can report to show how many events took it — a case that types
    /// through the default sink under test leaves a number here rather than
    /// keystrokes in whatever is frontmost.
    static private(set) var eventsDroppedUnderTest = 0

    /// The delay between one character's event pair and the next one.
    ///
    /// The delivery used to be a single uninterrupted turn: the whole transcript
    /// posted as fast as the loop could build events, which for a redirected
    /// target means about a thousand events arriving in a fraction of a
    /// millisecond, with nothing between them. Two milliseconds per character is
    /// about 500 characters a second — an order of magnitude faster than a person
    /// types, slow enough that a client forwarding each event into a session is
    /// not asked to absorb a whole dictation inside one turn, and short enough
    /// that a 500-character dictation delays this app by about a second. An
    /// independent judgment put "pacing is required" at 0.64; the number is this
    /// file's choice and is settable.
    static let defaultInterCharacterDelay: TimeInterval = 0.002

    /// The delay the delivery actually uses, and `0` under test: a test host posts
    /// nothing, so waiting between events there would only make the suite slower.
    static var interCharacterDelay: TimeInterval =
        OpenSuperWhisperApp.isRunningTests ? 0 : defaultInterCharacterDelay

    /// Records exactly one line per dictation. `print` is invisible for an app
    /// launched by LaunchServices (its stdout is `/dev/null`), which is how the
    /// shipped app runs, so the line that explains a dropped dictation goes to
    /// the unified log with `privacy: .public` fields.
    ///
    /// `deliveredCharacters` and `interruptedBy` say what became of the
    /// transcript: how much of it was handed to the system, and what ended the
    /// delivery early when something did. `mechanism` says which of
    /// `TextDelivery`'s two paths carried it — the first thing to look at when a
    /// dictation arrived wrong.
    static func logDictation(
        trusted: Bool,
        characters: Int,
        injected: Bool,
        eventsPosted: Int,
        deliveredCharacters: Int = 0,
        interruptedBy: DeliveryInterruption? = nil,
        mechanism: DeliveryMechanism? = nil,
        target: String? = nil,
        match: TextDelivery.TargetMatch? = nil
    ) {
        log.notice("""
            dictation-injection trusted=\(trusted ? 1 : 0, privacy: .public) \
            chars=\(characters, privacy: .public) \
            injected=\(injected ? 1 : 0, privacy: .public) \
            events=\(eventsPosted, privacy: .public) \
            delivered=\(deliveredCharacters, privacy: .public) \
            interrupted=\(interruptedBy?.description ?? "none", privacy: .public) \
            mechanism=\(mechanism?.logToken ?? "none", privacy: .public) \
            target=\(target ?? "unknown", privacy: .public) \
            match=\(match.map(Self.token(for:)) ?? "unknown", privacy: .public)
            """)
    }

    /// The token the one-line dictation record carries for a target match.
    static func token(for match: TextDelivery.TargetMatch) -> String {
        switch match {
        case .verifiedClient: return "verified-client"
        case .vendorFamily: return "vendor-family"
        case .notAClient: return "not-a-client"
        }
    }

    /// Virtual key code for Return.
    static let returnKeyCode: CGKeyCode = 0x24

    /// Virtual key code for the space bar.
    static let spaceKeyCode: CGKeyCode = 0x31

    /// Virtual key code for Tab.
    static let tabKeyCode: CGKeyCode = 0x30

    /// The device-dependent flag that says **which** Option key is held.
    ///
    /// `CGEventFlags.maskAlternate` does not distinguish the sides; the low bits
    /// of the event's flags do — the classic `NX_DEVICERALTKEYMASK`, `0x40`
    /// (`NX_DEVICELALTKEYMASK` is `0x20`). Every Polish diacritic on this layout
    /// rides Option, and in the application the captain dictates into the *left*
    /// Option is taken by that application's own shortcut, so the character never
    /// arrives: his words are that the Polish characters have to go out with the
    /// right Option. A physical keyboard sends whichever side the hand pressed;
    /// the app has to pick one, and it picks the side that is free.
    static let rightOptionDeviceFlag = CGEventFlags(rawValue: 0x40)

    /// A key code the system defines no key for.
    ///
    /// Used for a character the active layout has no key for. 0x7F is past the end of
    /// the defined key codes: measured on this machine, an event carrying it
    /// still delivers its Unicode payload to a local text view, and with the
    /// Unicode field cleared it reads back as length zero, so nothing derives a
    /// character from it. A function key would not do: measured the same way, an
    /// event with F13's key code inserts *nothing* — AppKit treats a function key
    /// as a function key and ignores the Unicode payload on it.
    static let unmappedKeyCode: CGKeyCode = 0x7F

    /// The key and modifiers a text-carrying event is posted with, for one
    /// character.
    ///
    /// Key code 0 is not "no key": it is the `A` key on ANSI layouts, and a target
    /// that rebuilds characters from key codes instead of reading the Unicode
    /// string types `a` for it. Key code 0 was therefore the worst possible
    /// choice for a character whose text is only in the Unicode field: measured on
    /// this machine with the app's own events, a Citrix client taps the events,
    /// reads key codes and modifier flags, and links no Unicode-payload reader at
    /// all, so every character arrived as a key code it read as `a`.
    ///
    /// So the key comes from the active layout, for the character the event
    /// carries — one character per event now, so every character of the
    /// transcript gets its own key:
    ///
    /// * the layout produces it on some layer — that layer's key code and that
    ///   layer's modifiers (none, shift, option, or option+shift). A physical
    ///   keyboard sends exactly this pair, so a HID-forwarding client forwards
    ///   exactly this, which is the most a sender can do;
    /// * the layout produces it on no layer (`ą` used to land here, and so does
    ///   every CJK, Cyrillic and emoji character) — `unmappedKeyCode`, which no
    ///   target can turn into a character, with no modifiers.
    ///
    /// What the pair cannot fix, stated here because it matters more than the key
    /// code does: the target's own layout. Correct key and correct modifiers is
    /// what a real keyboard sends; if the target's layout is not this one, the
    /// character it produces is not the one dictated. The sender cannot see the
    /// target's layout and no key-code scheme can, which is why the clipboard path
    /// exists for the targets that are recognised.
    ///
    /// The Unicode field still carries the character, so a target that reads the
    /// field — every native macOS target — is unaffected by any of this.
    static func key(for character: String) -> ClipboardUtil.ResolvedKey {
        guard let first = character.first else {
            return ClipboardUtil.ResolvedKey(keyCode: unmappedKeyCode, flags: [])
        }
        // Whitespace is never a modified key. A dictated text carries whatever the
        // engine wrote, and that includes spaces with no key of their own (a
        // non-breaking or thin space): the layer walk answers those with an Option
        // combination, and a target that rebuilds characters from key codes
        // instead of reading the Unicode payload turns that into a character of
        // *its* layout — on a US layout Option+A is `å`, which is a character the
        // user never said, appearing at the end of a dictation. A space is typed
        // as a space, on every layer.
        if first.isWhitespace {
            return ClipboardUtil.ResolvedKey(keyCode: spaceKeyCode, flags: [])
        }
        guard let resolved = ClipboardUtil.findKey(for: first) else {
            return ClipboardUtil.ResolvedKey(keyCode: unmappedKeyCode, flags: [])
        }
        return resolved
    }

    /// The key code alone, for callers that only need that half.
    static func keyCode(for character: String) -> CGKeyCode {
        key(for: character).keyCode
    }

    /// Types `text` by posting synthetic key events.
    ///
    /// Each character is carried by one keyDown, with the key code and modifiers
    /// the active layout uses for it, followed by a keyUp that releases the same
    /// key and carries no text, and `interCharacterDelay` separates one
    /// character's pair from the next — a target that inserts the text on every event it is handed
    /// therefore receives the character once. Control characters are handled as
    /// dedicated key codes: newlines map to Return and tabs to Tab. Empty input
    /// posts nothing.
    ///
    /// With a `watch`, the delivery is checked before every pair of events and
    /// stops cleanly at the first interference instead of typing into the wrong
    /// place: no further event is posted, and the result carries what ended the
    /// delivery and how much of the transcript had gone out. Chunking, the
    /// events themselves and their timing are unaffected — the checks are two
    /// cheap reads of session state, not delays.
    ///
    /// - Parameters:
    ///   - text: The text to type.
    ///   - trusted: Whether this process may post synthetic events. Defaults to
    ///     the live `AXIsProcessTrusted()` answer, which is what production
    ///     uses; injectable so a test can pin the answer instead of depending on
    ///     whether the machine happens to hold the grant.
    ///   - watch: Interference check consulted between characters, or `nil` to post
    ///     the whole text unchecked. Production passes `.live()`.
    ///   - post: Sink for the generated events. Defaults to posting to the HID
    ///     event tap; tests inject a capture closure.
    /// - Returns: What was observed and posted, and whether the delivery stopped
    ///   early. When `trusted` is false the events are still handed to `post`,
    ///   but macOS discards every event an untrusted process posts, so the text
    ///   did not reach the focused app — the caller must tell the user instead of
    ///   discarding the text silently.
    @discardableResult
    static func typeText(
        _ text: String,
        trusted: Bool = isTrustedForInjection,
        watch: DeliveryWatch? = nil,
        post: (CGEvent) -> Void = KeyboardSimulator.livePostSink
    ) -> InjectionResult {
        var eventsPosted = 0
        var keyDownsPosted = 0
        var deliveredCharacters = 0
        var interruptedBy: DeliveryInterruption?

        guard !text.isEmpty else {
            return InjectionResult(trusted: trusted, eventsPosted: 0)
        }

        // Normalize CRLF and CR to a single newline so no line break is lost.
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var buffer = ""

        func emit(_ events: [CGEvent]) {
            for event in events {
                post(event)
                eventsPosted += 1
                if event.type == .keyDown {
                    // The live watch subtracts these from the session's own
                    // count, so every one of them has to be counted.
                    keyDownsPosted += 1
                }
            }
        }

        /// Asks the watch whether the delivery may continue, and posts one pair
        /// of events (or two, for a control character) when it may.
        ///
        /// - Returns: `false` once the delivery has stopped, so the caller stops
        ///   walking the transcript instead of posting the rest of it.
        func emitUnlessInterrupted(_ events: [CGEvent], characters: Int) -> Bool {
            if interruptedBy == nil, let watch {
                interruptedBy = watch.interference(keyDownsPosted: keyDownsPosted)
            }
            guard interruptedBy == nil else { return false }
            emit(events)
            deliveredCharacters += characters
            return true
        }

        /// Posts the buffered text, one character per event pair, unless
        /// something interfered.
        ///
        /// One character per keyDown/keyUp pair is what a physical keyboard
        /// emits, and it is the only shape a target that rebuilds characters
        /// from key codes can read: a pair carries exactly one key code, so
        /// anything the pair carries beyond that character's own key is lost to
        /// such a target. The cost is event volume — a character per pair rather
        /// than up to twenty per pair.
        @discardableResult
        func flushBuffer() -> Bool {
            if interruptedBy != nil { return false }
            guard !buffer.isEmpty else { return true }
            var isFirst = true
            for character in buffer {
                if !isFirst, interCharacterDelay > 0 {
                    Thread.sleep(forTimeInterval: interCharacterDelay)
                }
                isFirst = false
                guard emitUnlessInterrupted(makeUnicodeEvents(for: String(character)), characters: 1) else {
                    return false
                }
            }
            buffer = ""
            return true
        }

        characterLoop: for character in normalized {
            switch character {
            case "\n":
                guard flushBuffer() else { break characterLoop }
                // Shift+Enter, not Enter: see `makeKeyEvents(for:flags:)` — Enter
                // sends in a chat client, so a multi-line dictation arrived as
                // several messages.
                guard emitUnlessInterrupted(
                    makeKeyEvents(for: returnKeyCode, flags: .maskShift),
                    characters: 1
                ) else {
                    break characterLoop
                }
            case "\t":
                guard flushBuffer() else { break characterLoop }
                guard emitUnlessInterrupted(makeKeyEvents(for: tabKeyCode), characters: 1) else {
                    break characterLoop
                }
            default:
                buffer.append(character)
            }
        }

        flushBuffer()

        // The last three characters of what was typed, as code points, plus the
        // non-ASCII count — so a stray character at the end of a dictation can be
        // identified from the log instead of guessed at. The need is measured: a
        // character the user never said appeared at the end of a dictation twice,
        // and the record carried event counts only.
        if !normalized.isEmpty {
            let tail = normalized.suffix(3).unicodeScalars
                .map { String(format: "U+%04X", $0.value) }
                .joined(separator: " ")
            let nonASCII = normalized.filter { !$0.isASCII }.count
            log.notice("""
                typed tail \(tail, privacy: .public) \
                nonASCII=\(nonASCII, privacy: .public) \
                characters=\(normalized.count, privacy: .public)
                """)
        }

        return InjectionResult(
            trusted: trusted,
            eventsPosted: eventsPosted,
            interruptedBy: interruptedBy,
            deliveredCharacters: deliveredCharacters
        )
    }

    /// Builds the keyDown/keyUp pair that carries one character as a Unicode
    /// string.
    ///
    /// The character travels on the keyDown and on nothing else.
    ///
    /// Putting it on both events was a divergence from what the platform expects
    /// of a key pair, and it is a real duplication hazard: a target that inserts
    /// the text every event carries, rather than acting on the press alone,
    /// receives the character twice — the second copy landing at whatever caret
    /// the first one had already moved. No capture of the failing target's events
    /// exists, so this is fixed as a hazard rather than convicted as the cause:
    /// the pair now carries the text once whatever the target does with it.
    ///
    /// The keyUp is kept, and keeps the keyDown's key code *and its modifiers*:
    /// the pair is what a host that forwards input to another machine tracks as a
    /// press and a release, and a keyDown with no release leaves that key held in
    /// the guest — while a release without the modifiers the press carried is a
    /// different key to anything that tracks modifier state.
    ///
    /// Its Unicode string is cleared to length zero rather than left alone,
    /// because an event with the field unset is not an event without text: read
    /// back, an unset field reports the character the key code produces, and key
    /// code 0 is `a` (see `TextDelivery`, which is where a target that reads the
    /// field instead of the payload is sent). Clearing it says "no text here".
    ///
    /// Returns an empty array if `character` is empty or if event creation fails.
    static func makeUnicodeEvents(for character: String) -> [CGEvent] {
        guard !character.isEmpty else { return [] }
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return [] }

        let utf16 = Array(character.utf16)
        let resolved = key(for: character)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: resolved.keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: resolved.keyCode, keyDown: false)
        else { return [] }

        // The modifiers are the layer's and nothing else: assigning the flags
        // rather than adding to them also drops whatever the system had inherited,
        // so a still-held hotkey cannot turn the character into a shortcut (Command+A)
        // instead of plain text — while Option and Shift, which the character may
        // genuinely need, are what a physical keyboard would be holding.
        //
        // Which *side* of Option is held matters to the target, and the layer walk
        // cannot say: it answers with the generic `.maskAlternate`. An application
        // whose own shortcut owns the left Option swallows the character, which is
        // the captain's case — "polskie znaki muszą iść z prawym Option" — so the
        // option case is posted with the right key's device bit, the side that is
        // free, and never with the left one.
        var flags = resolved.flags
        if flags.contains(.maskAlternate) {
            flags.insert(rightOptionDeviceFlag)
        }
        keyDown.flags = flags
        keyUp.flags = flags

        keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        keyUp.keyboardSetUnicodeString(stringLength: 0, unicodeString: [])
        return [keyDown, keyUp]
    }

    /// Builds a keyDown/keyUp pair for a virtual key code (no Unicode), with
    /// `flags` held.
    ///
    /// Both events have their Unicode string cleared to length zero. Unset, the
    /// field reports the character the key code produces — Return on the Return
    /// key, Tab on the Tab key — so leaving it alone would hand a target that
    /// reads the field a second insertion of the very character the key press
    /// already makes. Cleared, the pair is what it says it is: a key press and
    /// its release. A target that needs the character derives it from the key
    /// code, which is what makes Return a newline in a text view and in a guest
    /// alike.
    ///
    /// `flags` exists for one caller, the line break. Enter *sends* in every chat
    /// client, so an e-mail's greeting, body and sign-off arrived as three
    /// separate messages; Shift+Enter breaks the line in the same client without
    /// sending. The break is therefore posted as a shifted Return — what the
    /// user's own hands would do — and the flags are set after the clear below,
    /// or they would be cleared themselves.
    static func makeKeyEvents(for keyCode: CGKeyCode, flags: CGEventFlags = []) -> [CGEvent] {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        else { return [] }

        // Clear inherited modifier flags so a still-held hotkey cannot turn
        // Return/Tab into a modified key, then hold exactly what the caller asked
        // for.
        keyDown.flags = flags
        keyUp.flags = flags

        keyDown.keyboardSetUnicodeString(stringLength: 0, unicodeString: [])
        keyUp.keyboardSetUnicodeString(stringLength: 0, unicodeString: [])
        return [keyDown, keyUp]
    }
}
