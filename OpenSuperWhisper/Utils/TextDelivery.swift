import AppKit
import Foundation

/// Which of the two delivery mechanisms carried a dictation.
///
/// The mechanism is a property of the *target*, not a preference of the app, so
/// the choice itself lives in `TextDelivery` and this type only names the
/// outcome. The raw value is the token the one-line dictation record carries.
enum DeliveryMechanism: String, CaseIterable, Equatable {
    /// Unicode-carrying synthetic keystrokes, posted to the HID event tap.
    case keystrokes
    /// The transcript is put on the pasteboard and pasted with ⌘V, and the
    /// clipboard is put back the way it was afterwards.
    case clipboardPaste = "clipboard-paste"

    /// The token `KeyboardSimulator.logDictation` prints.
    var logToken: String { rawValue }
}

/// What the user asked delivery to do, which is the only thing that can override
/// the mechanism `TextDelivery` picks for the application being typed into.
enum DeliveryPreference: String, CaseIterable, Equatable {
    /// Keystrokes, except for an application that forwards input to a machine
    /// this one does not control — see `TextDelivery`.
    case automatic
    /// Keystrokes into every target, whatever it is.
    case keystrokes
    /// The clipboard paste into every target, whatever it is.
    case clipboardPaste = "clipboard-paste"

    var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .keystrokes: return "Keystrokes only"
        case .clipboardPaste: return "Clipboard paste"
        }
    }

    /// One line per choice, naming what actually happens — which targets get
    /// which mechanism, and what the clipboard path costs.
    var explanation: String {
        switch self {
        case .automatic:
            return "Keystrokes everywhere except Citrix, virtual machines and remote desktops, "
                + "which get the clipboard"
        case .keystrokes:
            return "Never touches the clipboard, and cannot deliver into a Citrix session "
                + "or a remote desktop"
        case .clipboardPaste:
            return "Pastes through the clipboard for every target, restoring it afterwards"
        }
    }
}

/// Hands a finished transcript to the focused application.
///
/// # Why there are two mechanisms
///
/// There are two kinds of target, and no single mechanism is correct for both.
///
/// A **native macOS target** (TextEdit, Terminal, a browser) receives key events
/// from the window server and inserts the Unicode string the event carries. One
/// keyDown per chunk is exactly one insertion, which is what
/// `KeyboardSimulator.typeText` posts and what this fork has always done. It is
/// independent of the active keyboard layout, it never touches the clipboard,
/// and the captain's own dictation into a native terminal proves it: that text
/// arrives whole.
///
/// A **HID-forwarded target** — a virtual machine, a remote desktop, a VNC
/// viewer — is not reached by the window server's text at all: the host
/// application forwards what it receives on to a machine with its own input
/// stack, and the guest types what *it* makes of it. The text field on a
/// `CGEvent` is an Apple extension that nothing obliges a guest to look at, and
/// the key code the keystroke path carries its text on is 0 — `a` on any layout.
///
/// What a given host does with the events it captures has never been observed
/// from this side: there is no trace of the failing target's event stream, and
/// what a guest received cannot be read back from the host at all. This design
/// therefore does not rest on which of those two things the guest does. It rests
/// on the one mechanism whose transport *is* the text — see below.
///
/// # What the alternatives cost, and why this is the ladder
///
/// - **Real per-character key codes.** Rejected, and it cannot be made to work
///   in general. A key code names a *physical* key; the character it produces is
///   the guest's business. The machine this was fixed on has `PolishPro` active,
///   where all nine of `ą ć ę ł ń ó ś ź ż` sit behind Option (`0`→ą, `8`→ć,
///   `14`→ę, `37`→ł, and so on) — so `ClipboardUtil.findKeycodeForCharacter`,
///   which walks the layout's base layer, finds no key code for any of them, and
///   an implementation would have to send Option combinations instead. The guest
///   re-translates those under *its* layout: on a US guest layout, Option-plus-key
///   is `å`, `©`, `ß`… The code would be right only for the one pair of layouts
///   it was written against and wrong — silently, character by character — for
///   every other pair. The one thing per-character key codes can be relied on to
///   do is produce *some* text, which is how a wrong answer is delivered as if it
///   were a right one.
/// - **Accessibility insertion** (`kAXSelectedTextAttribute` on the focused
///   element). Not available for this: the guest holds the text, and the host
///   side of a virtual machine window exposes no text element, no selected
///   range, and no insertion point — `FocusUtils` reads AX only to place the
///   indicator, and the writes it would need do not exist in this tree. It could
///   not reach the target that is broken, so it is not a fallback.
/// - **The clipboard paste.** It is the mechanism that does not depend on the
///   unknown, and it is the reason this file exists. A virtual machine shares the
///   clipboard with the guest by default — clipboard sharing is on in both of the
///   guest machines on the Mac this was fixed on (`ClipboardSync/Enabled = 1` in
///   the `.pvm` configs) — the text travels as *text* (not as key codes), and ⌘V
///   is the one command every guest understands. It costs the fork its stated
///   doctrine — "the clipboard is never used" is no longer unconditionally true,
///   and the `Readme` and the Settings copy say so — plus a write-and-restore of
///   the user's clipboard. It also has a failure mode keystrokes do not: if the
///   guest's clipboard sharing is off, the paste does nothing and this app
///   cannot tell, because the only thing it can observe is its own pasteboard,
///   not what the guest did with it. `ClipboardUtil` writes the previous
///   contents back after `ClipboardUtil.clipboardRestoreDelay`, and only if the
///   clipboard is still the transcript it wrote.
///
///   An independent judgment (Jev, on this same evidence) put the clipboard
///   paste at 0.96 for a redirected target against 0.03 for a heuristic ladder,
///   0.01 for the fixed Unicode events and 0.00 for per-character key codes. The
///   ladder below still exists because its redirected-target branch *is* that
///   paste: what the target-aware rule decides is when the clipboard gets
///   written, and the alternative — pasting into every target, native ones
///   included, whose keystrokes are already known to arrive — would spend the
///   user's clipboard on every dictation to fix a case that only concerns some
///   of them. A user who wants the paste everywhere can say so:
///   `DeliveryPreference.clipboardPaste`.
///
///   **The restore is not a solution, and the code below says so rather than
///   implying otherwise.** Save-and-restore was judged sufficient at 0.22. What
///   has been measured on this side, and what it leaves open:
///
///   * *A target that services the paste late gets the wrong text.* The restore
///     runs on a timer (`ClipboardUtil.clipboardRestoreDelay`, 1.5 s). A target
///     that services the synthesized ⌘V after that — browsers, Electron apps and
///     remote sessions are exactly the slow consumers the delay exists for —
///     pastes whatever the clipboard holds *then*: the user's previous clipboard
///     contents, put into their document in place of the dictation. The measured
///     case in `TextDeliveryTests` demonstrates it rather than asserting it away.
///     There is no fix in this design: the app cannot know when the target
///     serviced the paste, and the clipboard cannot hold the transcript
///     indefinitely either.
///   * *An empty clipboard used to keep the transcript.* There was nothing to
///     save, so nothing was scheduled to put the clipboard back and the
///     dictation stayed there with no way off. `ClipboardUtil` now clears the
///     clipboard in that case, under the same changeCount guard, which is
///     measured too.
///   * *The app dying between the copy and the restore* leaves the transcript on
///     the clipboard with nothing scheduled to take it off. There is no
///     mitigation in this code: the restore is an in-process block with no
///     checkpoint, so a crash inside that 1.5 s window leaves the user's words in
///     a clipboard any application can read, and whatever they had copied gone.
///
///   What keeps this from being a silent default is the visibility, not the
///   design: `DeliveryPreference` is a control in Settings, its caption names
///   the target classes that get the clipboard, every dictation's log line
///   records `mechanism=clipboard-paste`, and "Keystrokes only" turns the path
///   off entirely. An independent judgment leaned the same way (0.63) — the
///   paste would ideally be opt-in per target family rather than switched on by
///   detection — which is not what ships: the captain's own case is a session
///   that gets no text at all without it, so the default fixes the reported
///   failure and the off-switch is one click away.
/// - **A ladder that prefers keystrokes and falls back at run time.** There is
///   nothing for a fallback to trigger on. Whether a target reconstructs from
///   key codes or takes the Unicode payload is a property of the target, and the
///   only observable on this side is the pasteboard the app wrote itself; a
///   guest that received nothing tells the host nothing about it. So the ladder
///   is decided *before* the events go out, from what the application in front
///   is, and `DeliveryPreference` is the user's override when the guess is
///   wrong.
///
/// # What is verified, and what is not
///
/// Verified on this side: the events a delivery posts, the shape of the pair,
/// what the Unicode field on each event reads back as, which mechanism the
/// ladder selects for a given application and preference, that the ⌘V pair is
/// posted, and that the pasteboard holds the transcript and gets its previous
/// contents back. That the text then *arrives* is verified for a native macOS
/// target, through a real `NSTextView` driven by AppKit's own key bindings.
///
/// Not verified, and not verifiable on this machine: what a virtual machine's
/// guest received. There is no guest in the test suite and nothing about the
/// guest is observable from the host — an independent judgment put "only
/// host-side transport can be tested in-process" at 0.65 against 0.34 for the
/// paste's transport being the one provable case, and both agree that guest
/// arrival is out of reach here. Proving it needs a capture inside the guest: a
/// dictation into a guest text field with the guest's own text dumped before and
/// after, or a trace of the host-side forwarding showing what the guest was
/// handed and what it typed back.
///
/// # The rule
///
/// Keystrokes by default, because that is the path that reaches every native
/// macOS application and keeps the clipboard untouched. The clipboard paste for
/// an application that redirects the input it receives into a session or another
/// machine — and this app can see that application: the frontmost bundle
/// identifier is read at delivery time, the same moment the interference watch
/// captures its target. That is what makes this a decision about a target rather
/// than a guess.
///
/// The rule has two tiers, and the difference between them is written down
/// because one of them is measured and the other is not: the bundle identifiers
/// measured on this machine (`verifiedRemoteClientBundleIdentifiers`) switch the
/// mechanism, while a vendor-prefix match (`remoteClientVendorPrefixes`) is a
/// judgement that an independent reading put at 0.36 and therefore does not
/// switch anything unless the user asks for it. `DeliveryPreference` overrides
/// the outcome either way.
enum TextDelivery {

    /// The bundle identifiers measured on **this machine**, each one an
    /// application that redirects the input it receives into a session or another
    /// machine. A match here is what switches the mechanism.
    ///
    /// These were read out of the installed applications and out of the live
    /// running ones (see `DeliveryMeasurementTests` and the Readme): Citrix
    /// Workspace ships the Viewer that draws and drives the session
    /// (`com.citrix.receiver.icaviewer.mac` — measured in front, `active=true`,
    /// while a session was up), the Workspace UI (`com.citrix.receiver.nomas`) and
    /// the engine beside them (`com.citrix.HdxRtcEngine`), all three running and
    /// visible to `NSWorkspace` at once.
    static let verifiedRemoteClientBundleIdentifiers: Set<String> = [
        "com.citrix.receiver.icaviewer.mac",  // Citrix Viewer: the session window itself
        "com.citrix.receiver.nomas",          // Citrix Workspace UI
        "com.citrix.HdxRtcEngine",            // the engine the client runs beside the session
        "com.parallels.desktop.console",      // Parallels Desktop
        "com.apple.ScreenSharing",            // macOS Screen Sharing
    ]

    /// Vendor prefixes of the same clients' *families*.
    ///
    /// A client ships more bundles than anyone can enumerate in advance, and the
    /// one in front during a session is not predictable from outside it, so a
    /// prefix is the only way to recognise "some other bundle from a client we
    /// know". It is **not trusted on its own**, and the reason is written here
    /// rather than left to the reader:
    ///
    /// * an independent judgment put "a prefix rule is safe" at 0.36 — it leans
    ///   against;
    /// * a prefix that matches too much costs a clipboard write and a paste into
    ///   an application that did not need one (an updater, an uninstaller, a
    ///   helper window), which is exactly the cost this design exists to avoid;
    /// * a prefix that matches too little leaves the keystroke path in a session,
    ///   which is the case that is broken.
    ///
    /// So a prefix-only match **fails toward the safer behaviour**: it does not
    /// paste unless the user has asked for it
    /// (`AppPreferences.shared.pasteIntoRecognisedVendors`), and the delivery
    /// record says which kind of match it was, so a session that is not being
    /// reached by a keystroke delivery can be seen in the log instead of guessed
    /// at. The exact list above is the part that is measured; this is the part
    /// that is a judgement, and it is labelled as one.
    static let remoteClientVendorPrefixes: [String] = [
        // Citrix: Workspace UI, Viewer, helper, session manager, overlay, engine.
        "com.citrix.",
        // Virtual machines.
        "com.parallels.",                    // Parallels Desktop and its helpers
        "com.vmware.fusion",                 // VMware Fusion
        "org.virtualbox.app.",               // VirtualBox
        "com.utmapp.",                       // UTM
        "com.apple.qemu",                    // QEMU
        // Remote desktops and screen sharing, which deliver key codes the same
        // way. The ones with a Unicode channel of their own (RDP, Citrix HDX in
        // its Unicode mode) would accept either mechanism; they are not worth a
        // second list.
        "com.apple.ScreenSharing",           // macOS Screen Sharing
        "com.microsoft.rdc",                 // Microsoft Remote Desktop
        "com.p5sys.jump",                    // Jump Desktop
        "com.edovia.screens",                // Screens
        "com.realvnc.",                      // RealVNC
        "com.tigervnc.",                     // TigerVNC
        "com.teamviewer.",                   // TeamViewer
        "com.philandro.anydesk",             // AnyDesk
        "com.parsecgaming.",                 // Parsec
        "com.carriez.rustdesk",              // RustDesk
        "com.google.chrome.remote_desktop",  // Chrome Remote Desktop
        "com.nomachine.",                    // NoMachine
    ]

    /// How well the application in front is known to redirect its input.
    enum TargetMatch: Equatable {
        /// One of the bundle identifiers measured on this machine.
        case verifiedClient
        /// A vendor's family, from a prefix — a judgement, not a measurement.
        case vendorFamily
        /// Not a client: a native macOS application, or something unreadable.
        case notAClient
    }

    /// What is known about `bundleIdentifier` as a target.
    static func targetMatch(_ bundleIdentifier: String?) -> TargetMatch {
        guard let bundleIdentifier else { return .notAClient }
        if verifiedRemoteClientBundleIdentifiers.contains(bundleIdentifier) { return .verifiedClient }
        if remoteClientVendorPrefixes.contains(where: { bundleIdentifier.hasPrefix($0) }) { return .vendorFamily }
        return .notAClient
    }

    /// Whether an application redirects the input it receives elsewhere, given
    /// the user's answer on the part of the rule that is a judgement.
    ///
    /// Kept for the callers that only need the yes/no — the delivery uses
    /// `targetMatch` so it can record which kind of match it acted on.
    static func redirectsInput(_ bundleIdentifier: String,
                               pasteIntoRecognisedVendors: Bool = AppPreferences.shared.pasteIntoRecognisedVendors) -> Bool {
        switch targetMatch(bundleIdentifier) {
        case .verifiedClient: return true
        case .vendorFamily: return pasteIntoRecognisedVendors
        case .notAClient: return false
        }
    }

    /// The bundle identifier of the application a delivery would go to now.
    static func currentFrontmostBundleIdentifier() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    /// The mechanism for one delivery, from the preference and the application
    /// in front.
    static func mechanism(
        preference: DeliveryPreference,
        frontmostBundleIdentifier: String?,
        pasteIntoRecognisedVendors: Bool = AppPreferences.shared.pasteIntoRecognisedVendors
    ) -> DeliveryMechanism {
        switch preference {
        case .keystrokes:
            return .keystrokes
        case .clipboardPaste:
            return .clipboardPaste
        case .automatic:
            switch targetMatch(frontmostBundleIdentifier) {
            case .verifiedClient:
                return .clipboardPaste
            case .vendorFamily:
                // The match is a judgement, so it pastes only when the user has
                // said so; otherwise the target is typed into as before.
                return pasteIntoRecognisedVendors ? .clipboardPaste : .keystrokes
            case .notAClient:
                return .keystrokes
            }
        }
    }

    /// Delivers `text` to the focused application by the mechanism the target
    /// calls for.
    ///
    /// The parameters mirror `KeyboardSimulator.typeText`: `trusted` is the live
    /// Accessibility answer (production uses the default), `watch` is the
    /// interference check, `post` is the event sink a test replaces with a
    /// capture closure. `preference`, `frontmostBundleIdentifier` and
    /// `pasteboard` are the seams the choice is made at, and are read live in
    /// production: the preference from `AppPreferences`, the application from
    /// the frontmost one, the pasteboard from the general one.
    ///
    /// - Returns: What was observed and posted, including which mechanism ran
    ///   and whether the delivery stopped early. A `trusted: false` answer means
    ///   macOS discarded whatever was posted; a `injected: false` answer means
    ///   nothing was posted at all. Neither is a delivery, and the caller owes
    ///   the user the difference — the transcript is in the history either way.
    @discardableResult
    static func deliver(
        _ text: String,
        trusted: Bool = KeyboardSimulator.isTrustedForInjection,
        preference: DeliveryPreference = AppPreferences.shared.deliveryPreference,
        frontmostBundleIdentifier: String? = TextDelivery.currentFrontmostBundleIdentifier(),
        pasteIntoRecognisedVendors: Bool = AppPreferences.shared.pasteIntoRecognisedVendors,
        watch: KeyboardSimulator.DeliveryWatch? = nil,
        pasteboard: NSPasteboard = .general,
        post: (CGEvent) -> Void = KeyboardSimulator.livePostSink
    ) -> KeyboardSimulator.InjectionResult {
        let match = targetMatch(frontmostBundleIdentifier)
        let mechanism = mechanism(preference: preference,
                                  frontmostBundleIdentifier: frontmostBundleIdentifier,
                                  pasteIntoRecognisedVendors: pasteIntoRecognisedVendors)

        func described(_ result: KeyboardSimulator.InjectionResult) -> KeyboardSimulator.InjectionResult {
            var result = result
            result.targetBundleIdentifier = frontmostBundleIdentifier
            result.targetMatch = match
            return result
        }

        guard !text.isEmpty else {
            return described(KeyboardSimulator.InjectionResult(trusted: trusted,
                                                              eventsPosted: 0,
                                                              mechanism: mechanism))
        }

        switch mechanism {
        case .keystrokes:
            return described(KeyboardSimulator.typeText(text, trusted: trusted, watch: watch, post: post))
        case .clipboardPaste:
            return described(paste(text, trusted: trusted, watch: watch, pasteboard: pasteboard, post: post))
        }
    }

    /// Puts `text` on the pasteboard, posts ⌘V, and restores the clipboard.
    ///
    /// The interference check runs before anything is written, so a delivery
    /// that stops itself leaves the clipboard exactly as it found it. Everything
    /// after that is `ClipboardUtil.insertText`, which saves the previous
    /// contents, writes the transcript, posts the ⌘V pair through `post`, and
    /// puts the saved contents back after its restore delay — the mechanism the
    /// upstream app used, kept for exactly this case.
    private static func paste(
        _ text: String,
        trusted: Bool,
        watch: KeyboardSimulator.DeliveryWatch?,
        pasteboard: NSPasteboard,
        post: (CGEvent) -> Void
    ) -> KeyboardSimulator.InjectionResult {
        if let watch, let interruption = watch.interference(keyDownsPosted: 0) {
            return KeyboardSimulator.InjectionResult(trusted: trusted,
                                                    eventsPosted: 0,
                                                    interruptedBy: interruption,
                                                    mechanism: .clipboardPaste)
        }

        // Counted rather than assumed: the ⌘V pair is two events when the paste
        // path could build them, and none when it could not — the difference
        // between a delivery and a transcript that went nowhere.
        var eventsPosted = 0
        ClipboardUtil.insertText(text, postEvent: { event in
            eventsPosted += 1
            post(event)
        }, pasteboard: pasteboard)

        return KeyboardSimulator.InjectionResult(
            trusted: trusted,
            eventsPosted: eventsPosted,
            deliveredCharacters: eventsPosted > 0 ? text.count : 0,
            mechanism: .clipboardPaste
        )
    }
}
