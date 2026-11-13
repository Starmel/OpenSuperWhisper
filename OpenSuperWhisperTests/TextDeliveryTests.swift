import AppKit
import XCTest
@testable import OpenSuperWhisper

/// The delivery mechanism: which one carries the transcript, and what that costs.
///
/// The captain dictates into a native macOS terminal, where the text arrives
/// whole, and into his Parallels guest, where it did not. `TextDelivery` answers
/// the two with two mechanisms. A design judgment, not an observation, decides
/// that split — what a guest received cannot be observed from this side at all —
/// so these cases pin the choice and everything it does on this side of the
/// boundary: the mechanism selected for a given application and preference, the
/// ⌘V pair that goes out, the state of the pasteboard while the paste is made,
/// and the previous contents coming back afterwards. Whether the guest then pastes
/// the transcript is not claimed here and cannot be tested in this suite.
///
/// Every case here uses a pasteboard of its own, named with a fresh UUID. The
/// general pasteboard is one system-wide object shared with every other process
/// on the machine, so a case that asserted a restore through it would race
/// whatever else is running — `StorageAndLanguageSettingsTests` already pins the
/// restore-on-a-changeCount contract, and these cases pin the delivery path that
/// uses it.
@MainActor
final class TextDeliveryTests: XCTestCase {

    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("osw-delivery-test-\(UUID().uuidString)"))
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        pasteboard = nil
        super.tearDown()
    }

    /// The transcript the captain would dictate: longer than one chunk, and
    /// carrying the Polish diacritics a guest's own layout cannot rebuild.
    private static let transcript = "Zażółć gęślą jaźń, ówdzie łan — 中文 ok"

    /// The clipboard the user already had when the dictation happened.
    private static let usersClipboard = "something the captain copied before dictating"

    private func seedClipboard(_ contents: String) {
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(contents, forType: .string)
    }

    private func clipboardContents() -> String? {
        pasteboard.string(forType: .string)
    }

    /// Runs the run loop until the clipboard holds `contents`, or the timeout
    /// passes, and answers what it holds then. The restore is scheduled on the
    /// main queue by `ClipboardUtil`, so a test that slept instead of running
    /// the loop would wait for something that cannot happen.
    private func waitForClipboard(_ contents: String, timeout: TimeInterval = 6) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if clipboardContents() == contents { return contents }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return clipboardContents()
    }

    // MARK: - The mechanism the target calls for

    /// The captain's case: an application that forwards input to a guest is
    /// delivered through the clipboard, because nothing about what such a target
    /// does with forwarded events can be observed from here, while the clipboard
    /// carries the text itself.
    ///
    /// What it asserts is that the transcript reaches a reader that pastes from
    /// the board the delivery wrote — a real `NSTextView` reading the pasteboard —
    /// rather than only counting characters the delivery computed from its own
    /// input. The character count is reported, not asserted: it is a counter of
    /// what was handed over, not evidence of arrival.
    func testAVirtualMachineTargetIsDeliveredThroughTheClipboard() {
        seedClipboard(Self.usersClipboard)
        var posted: [CGEvent] = []

        let result = TextDelivery.deliver(
            Self.transcript,
            trusted: true,
            preference: .automatic,
            frontmostBundleIdentifier: "com.parallels.desktop.console",
            pasteboard: pasteboard,
            post: { posted.append($0) }
        )

        XCTAssertEqual(result.mechanism, .clipboardPaste)
        XCTAssertTrue(result.injected)
        // The ⌘V pair, and nothing else: the text is not spelled out in key
        // codes, so there is nothing for a guest to rebuild wrong.
        XCTAssertEqual(posted.map(\.type), [.keyDown, .keyUp])
        for event in posted {
            XCTAssertTrue(event.flags.contains(.maskCommand), "the paste is ⌘V")
        }
        XCTAssertEqual(clipboardContents(), Self.transcript,
                       "the transcript has to be on the clipboard for the paste to carry it")

        // Arrival, through a reader that pastes from that board.
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        editor.isRichText = false
        XCTAssertTrue(editor.readSelection(from: pasteboard), "the paste has to be serviceable")
        XCTAssertEqual(editor.string, Self.transcript,
                       "a target that services the paste receives the transcript, character for character")
        TestFixtures.report("[delivery] paste outcome: mechanism=\(result.mechanism) "
                            + "deliveredCharacters=\(result.deliveredCharacters) "
                            + "(a counter of what was handed over, not evidence of arrival), "
                            + "arrived in a text view: \(editor.string == Self.transcript)")

        // Drained so the scheduled restore has run before the pasteboard is
        // released; the restore itself is asserted by the case below.
        XCTAssertEqual(waitForClipboard(Self.usersClipboard), Self.usersClipboard)
    }

    /// …and the clipboard promise, kept: the contents the captain already had
    /// come back once the target has had its chance to paste.
    func testThePreviousClipboardContentsComeBackAfterAPasteDelivery() {
        seedClipboard(Self.usersClipboard)

        TextDelivery.deliver(
            Self.transcript,
            trusted: true,
            preference: .clipboardPaste,
            frontmostBundleIdentifier: "com.apple.Terminal",
            pasteboard: pasteboard,
            post: { _ in }
        )

        XCTAssertEqual(clipboardContents(), Self.transcript,
                       "the transcript is on the clipboard while the paste is being made")
        XCTAssertEqual(
            waitForClipboard(Self.usersClipboard), Self.usersClipboard,
            "the clipboard the user had must be restored after the paste"
        )
    }

    /// A native macOS target keeps the path this fork has always used, and its
    /// clipboard is never written.
    func testANativeTargetIsDeliveredByKeystrokesWithoutTouchingTheClipboard() {
        seedClipboard(Self.usersClipboard)
        let changeCountBefore = pasteboard.changeCount
        var posted: [CGEvent] = []

        let result = TextDelivery.deliver(
            Self.transcript,
            trusted: true,
            preference: .automatic,
            frontmostBundleIdentifier: "com.apple.Terminal",
            pasteboard: pasteboard,
            post: { posted.append($0) }
        )

        XCTAssertEqual(result.mechanism, .keystrokes)
        XCTAssertTrue(result.injected)
        XCTAssertEqual(result.deliveredCharacters, Self.transcript.count)
        XCTAssertEqual(result.eventsPosted, posted.count)
        XCTAssertGreaterThan(result.eventsPosted, 2, "the text is spelled out, not pasted")
        XCTAssertFalse(
            posted.contains { $0.flags.contains(.maskCommand) },
            "no ⌘V on the keystroke path"
        )
        XCTAssertEqual(pasteboard.changeCount, changeCountBefore, "the clipboard is not touched")
        XCTAssertEqual(clipboardContents(), Self.usersClipboard)
    }

    /// The preference is the user's override, and it wins over what the
    /// application in front is — in both directions.
    func testThePreferenceOverridesTheApplicationInFront() {
        XCTAssertEqual(
            TextDelivery.mechanism(preference: .keystrokes,
                                   frontmostBundleIdentifier: "com.parallels.desktop.console"),
            .keystrokes
        )
        XCTAssertEqual(
            TextDelivery.mechanism(preference: .clipboardPaste,
                                   frontmostBundleIdentifier: "com.apple.Terminal"),
            .clipboardPaste
        )
        // No application in front is not a virtual machine: the keystroke path
        // is the one that cannot be wrong about the target.
        XCTAssertEqual(
            TextDelivery.mechanism(preference: .automatic, frontmostBundleIdentifier: nil),
            .keystrokes
        )
    }

    // MARK: - Giving up safely

    /// An interrupted delivery writes nothing at all: the check runs before the
    /// clipboard is touched, so a delivery that stops itself leaves the user's
    /// clipboard as it found it rather than carrying the transcript until the
    /// restore delay.
    func testAStoppedDeliveryNeverWritesTheClipboard() {
        seedClipboard(Self.usersClipboard)
        var posted: [CGEvent] = []
        let watch = KeyboardSimulator.DeliveryWatch { _ in .focusChanged }

        let result = TextDelivery.deliver(
            Self.transcript,
            trusted: true,
            preference: .automatic,
            frontmostBundleIdentifier: "com.parallels.desktop.console",
            watch: watch,
            pasteboard: pasteboard,
            post: { posted.append($0) }
        )

        XCTAssertEqual(result.mechanism, .clipboardPaste)
        XCTAssertEqual(result.interruptedBy, .focusChanged)
        XCTAssertFalse(result.injected)
        XCTAssertEqual(result.deliveredCharacters, 0)
        XCTAssertTrue(posted.isEmpty, "nothing may go out once the target changed")
        XCTAssertEqual(clipboardContents(), Self.usersClipboard)
    }

    /// An empty transcript is nothing to deliver on either path.
    func testAnEmptyTranscriptPostsNothing() {
        let result = TextDelivery.deliver(
            "",
            trusted: true,
            preference: .clipboardPaste,
            frontmostBundleIdentifier: "com.parallels.desktop.console",
            pasteboard: pasteboard,
            post: { _ in }
        )

        XCTAssertFalse(result.injected)
        XCTAssertEqual(result.eventsPosted, 0)
        XCTAssertEqual(result.deliveredCharacters, 0)
    }

    // MARK: - The clipboard is a hazard, measured

    /// The cost of the paste path, demonstrated rather than asserted away.
    ///
    /// This case does NOT pin desired behaviour. It measures the hazard the
    /// delivery path carries for its users: the clipboard is put back on a timer
    /// (1.5 s), so a target that services the ⌘V it was handed *after* that timer
    /// has run pastes the restored contents — the user's own previous clipboard —
    /// into their document in place of the dictation. Browsers, Electron apps and
    /// remote sessions are exactly the slow consumers the delay exists for.
    ///
    /// It stands as documentation of a known limitation of the mechanism, not as
    /// a contract: if the delivery ever stops restoring on a timer (by handing
    /// the target the text some other way, or by waiting for the paste to be
    /// serviced), this case's assertion is what should change — its scenario is
    /// still what a slow target does.
    func testAPasteThatLandsAfterTheRestoreDeliversTheOldClipboardInsteadOfTheTranscript() {
        seedClipboard(Self.usersClipboard)
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        editor.isRichText = false

        // The delivery posts ⌘V, and this case does not service it: it stands in
        // for a target that is still busy when the events arrive.
        var posted: [CGEvent] = []
        TextDelivery.deliver(
            Self.transcript,
            trusted: true,
            preference: .clipboardPaste,
            frontmostBundleIdentifier: "com.citrix.receiver.icaviewer.mac",
            pasteboard: pasteboard,
            post: { posted.append($0) }
        )
        XCTAssertEqual(posted.count, 2, "the ⌘V pair went out")

        // The restore timer fires while the slow target is still busy.
        let restored = waitForClipboard(Self.usersClipboard)
        TestFixtures.report(
            "[delivery] hazard probe: seeded with \(String(reflecting: Self.usersClipboard)), "
            + "after the restore delay the pasteboard holds \(String(reflecting: restored))"
        )
        XCTAssertEqual(restored, Self.usersClipboard, "the restore ran while the target was busy")

        // …and now the target services the paste it was handed. The paste reads
        // the clipboard the delivery wrote to, which is what any target does —
        // AppKit's own `paste:` reads the general pasteboard, so this case reads
        // its own board explicitly to say which clipboard the slow target saw.
        let didPaste = editor.readSelection(from: pasteboard)

        TestFixtures.report(
            "[delivery] a paste serviced after the restore delay inserted "
            + "\(editor.string.count) characters (\(didPaste ? "paste accepted" : "paste refused")); "
            + "the dictation was \(Self.transcript.count): the target received "
            + "\(editor.string == Self.transcript ? "the transcript" : "the restored clipboard")"
        )
        XCTAssertEqual(
            editor.string, Self.usersClipboard,
            "a target that services the paste after the restore delay gets the user's old clipboard — "
            + "the measured cost of the clipboard mechanism, not a desired outcome"
        )
        XCTAssertNotEqual(editor.string, Self.transcript, "the dictation never reached it")
    }

    /// The other half of the same hazard: there is nothing to restore when the
    /// clipboard had nothing on it, so the transcription used to stay there with
    /// nothing scheduled to take it off — the user's dictation left in a
    /// clipboard any application can read.
    ///
    /// `ClipboardUtil` now clears the clipboard in that case, under the same
    /// changeCount guard it uses for a restore, so the clipboard ends up where it
    /// started: empty.
    func testATranscriptPastedOntoAnEmptyClipboardDoesNotStayOnIt() {
        pasteboard.clearContents()
        XCTAssertNil(ClipboardUtil.saveCurrentPasteboardContents(from: pasteboard),
                     "an empty pasteboard has nothing to save")

        TextDelivery.deliver(
            Self.transcript,
            trusted: true,
            preference: .clipboardPaste,
            frontmostBundleIdentifier: "com.citrix.receiver.icaviewer.mac",
            pasteboard: pasteboard,
            post: { _ in }
        )
        XCTAssertEqual(clipboardContents(), Self.transcript,
                       "the transcript is on the clipboard while the paste is being made")

        // Well past the restore delay.
        RunLoop.current.run(until: Date().addingTimeInterval(ClipboardUtil.clipboardRestoreDelay + 0.4))
        TestFixtures.report(
            "[delivery] paste onto an empty clipboard: after \(ClipboardUtil.clipboardRestoreDelay) s the "
            + "pasteboard holds \(String(reflecting: clipboardContents()))"
        )
        XCTAssertNil(
            clipboardContents(),
            "with nothing saved to put back, the transcript must not be left on the clipboard"
        )
    }

    /// …and the guard still holds when somebody else takes the clipboard while
    /// the paste is being made: whoever wrote last keeps their contents, whether
    /// the app had something to restore or nothing at all.
    func testAClipboardTakenBySomeoneElseIsNeverOverwritten() {
        // Nothing saved, so the delivery would clear — unless the clipboard is
        // no longer ours by the time that runs.
        pasteboard.clearContents()
        TextDelivery.deliver(
            Self.transcript,
            trusted: true,
            preference: .clipboardPaste,
            frontmostBundleIdentifier: "com.citrix.receiver.icaviewer.mac",
            pasteboard: pasteboard,
            post: { _ in }
        )
        seedClipboard("copied by the user during the paste")

        RunLoop.current.run(until: Date().addingTimeInterval(ClipboardUtil.clipboardRestoreDelay + 0.4))
        XCTAssertEqual(
            clipboardContents(), "copied by the user during the paste",
            "a changeCount that moved means the clipboard is somebody else's and must be left alone"
        )
    }

    /// The delivery records which application it was aimed at, because that is
    /// the first question a delivery that went wrong has to answer and it is not
    /// recoverable afterwards — it is what will say whether the frontmost bundle
    /// during a real Citrix dictation is the Viewer, the Workspace UI, or
    /// neither.
    func testTheOutcomeRecordsTheApplicationTheDeliveryWasAimedAt() {
        // Seeded so the paste path schedules its restore, which this case drains
        // before the pasteboard is released; what is asserted here is the record.
        seedClipboard(Self.usersClipboard)
        let result = TextDelivery.deliver(
            Self.transcript,
            trusted: true,
            preference: .automatic,
            frontmostBundleIdentifier: "com.citrix.receiver.icaviewer.mac",
            pasteboard: pasteboard,
            post: { _ in }
        )

        XCTAssertEqual(result.targetBundleIdentifier, "com.citrix.receiver.icaviewer.mac")
        XCTAssertEqual(result.mechanism, .clipboardPaste)
        XCTAssertEqual(waitForClipboard(Self.usersClipboard), Self.usersClipboard)
    }

    // MARK: - Which applications get the paste

    /// The two tiers of the target rule, on the identifiers verified from the
    /// installed clients rather than on invented ones.
    ///
    /// The exact tier is measured on this machine and switches the mechanism; the
    /// vendor-prefix tier is a judgement (an independent reading put it at 0.36)
    /// and therefore does NOT switch anything unless the user asks for it.
    func testTheTargetRuleDistinguishesWhatIsMeasuredFromWhatIsGuessed() {
        // Measured: the three Citrix bundles seen running on this machine, the
        // session window among them.
        XCTAssertEqual(TextDelivery.targetMatch("com.citrix.receiver.icaviewer.mac"), .verifiedClient)
        XCTAssertEqual(TextDelivery.targetMatch("com.citrix.receiver.nomas"), .verifiedClient)
        XCTAssertEqual(TextDelivery.targetMatch("com.citrix.HdxRtcEngine"), .verifiedClient)
        XCTAssertEqual(TextDelivery.targetMatch("com.parallels.desktop.console"), .verifiedClient)
        XCTAssertEqual(TextDelivery.targetMatch("com.apple.ScreenSharing"), .verifiedClient)

        // A guess: another bundle from a client family we know.
        XCTAssertEqual(TextDelivery.targetMatch("com.citrix.receiver.helper"), .vendorFamily)
        XCTAssertEqual(TextDelivery.targetMatch("com.teamviewer.TeamViewer"), .vendorFamily)

        // Not a client at all — including a bundle that merely starts the same.
        XCTAssertEqual(TextDelivery.targetMatch("com.apple.Terminal"), .notAClient)
        XCTAssertEqual(TextDelivery.targetMatch("com.googlecode.iterm2"), .notAClient)
        XCTAssertEqual(TextDelivery.targetMatch("com.citrixsux.example"), .notAClient)
        XCTAssertEqual(TextDelivery.targetMatch(nil), .notAClient)

        // …and the mechanism follows the tier, not the prefix on its own.
        XCTAssertEqual(
            TextDelivery.mechanism(preference: .automatic,
                                   frontmostBundleIdentifier: "com.citrix.receiver.nomas",
                                   pasteIntoRecognisedVendors: false),
            .clipboardPaste,
            "a measured bundle pastes without being asked"
        )
        XCTAssertEqual(
            TextDelivery.mechanism(preference: .automatic,
                                   frontmostBundleIdentifier: "com.citrix.receiver.helper",
                                   pasteIntoRecognisedVendors: false),
            .keystrokes,
            "a vendor-prefix guess fails toward the behaviour that does not touch the clipboard"
        )
        XCTAssertEqual(
            TextDelivery.mechanism(preference: .automatic,
                                   frontmostBundleIdentifier: "com.citrix.receiver.helper",
                                   pasteIntoRecognisedVendors: true),
            .clipboardPaste,
            "…and pastes once the user has asked for the wider rule"
        )
        XCTAssertFalse(TextDelivery.redirectsInput("com.citrix.receiver.helper",
                                                  pasteIntoRecognisedVendors: false))
        XCTAssertTrue(TextDelivery.redirectsInput("com.citrix.receiver.helper",
                                                 pasteIntoRecognisedVendors: true))
    }
}
