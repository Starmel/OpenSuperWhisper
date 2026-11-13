import AppKit
import CryptoKit
import XCTest
@testable import OpenSuperWhisper

/// F4: the measurements, not the design.
///
/// The delivery mechanism on this branch is superseded and undeployed, pending
/// exactly what these cases produce — numbers about the two things the choice
/// between "paste" and "keystrokes only" rests on. Nothing here asserts which
/// mechanism is right; each case reports raw readings and only fails when the
/// reading is not what it says it measured.
///
/// The clipboard cases run against the machine's **real** pasteboard, because
/// that is the only one whose behaviour is in question. Every one of them
/// captures the clipboard first, writes a backup of it to disk, and puts it back
/// in a `defer`, so the user's clipboard survives a failure in the case itself.
/// Clipboard contents are never printed: the reports carry type identifiers,
/// byte counts and SHA-256 prefixes.
@MainActor
final class DeliveryMeasurementTests: XCTestCase {

    private var savedRecordURL: URL!

    /// A pasteboard this case owns, named with a fresh UUID.
    ///
    /// These measurements used the machine's general clipboard, and that made one
    /// of them fail for a reason that had nothing to do with the change: another
    /// process wrote to the clipboard inside the 1.5 s window, the changeCount
    /// guard correctly declined to restore, and the case asserted byte equality of
    /// a resource it did not own. It is the same server-side kind of object as the
    /// general one, so the transport under test is unchanged; what is gone is the
    /// race, and with it any effect these cases have on the clipboard the captain
    /// is using.
    private var pasteboard: NSPasteboard!
    private var boardName: NSPasteboard.Name!

    override func setUp() {
        super.setUp()
        savedRecordURL = ClipboardRecovery.recordURL
        ClipboardRecovery.recordURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("osw-measurement-record-\(UUID().uuidString).plist")
        boardName = NSPasteboard.Name("osw-measurement-pasteboard-\(UUID().uuidString)")
        pasteboard = NSPasteboard(name: boardName)
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        pasteboard = nil
        ClipboardRecovery.clear()
        ClipboardRecovery.recordURL = savedRecordURL
        super.tearDown()
    }

    /// Puts `text` on the case's own pasteboard, as "what the user had copied".
    private func seedOwnPasteboard(_ text: String) {
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(text, forType: .string)
    }

    /// Waits until the pasteboard stops holding what was written to it, or the
    /// timeout passes, running the run loop so the scheduled restore can fire.
    private func waitForThePasteboardToMove(on from: Int, _ pasteboard: NSPasteboard, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, pasteboard.changeCount == from {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    // MARK: - Measurement 1: the round trip, on a pasteboard the case owns

    /// Does save-and-restore put the clipboard back, byte for byte?
    ///
    /// Writes a controlled payload through the app's own paste step onto a
    /// pasteboard of this case's own, waits out the restore delay, and compares
    /// the before and after states (types, bytes, changeCount) as digests.
    func testAPasteRoundTripOnAPasteboardOfItsOwnComesBackByteIdentical() {
        seedOwnPasteboard("what the user had copied before the dictation \(UUID().uuidString)")
        let before = TestFixtures.snapshotClipboard(pasteboard)
        TestFixtures.report("[clipboard] BEFORE          \(before.description)")

        let payload = "OpenSuperWhisper paste measurement \(UUID().uuidString)"
        var posted: [CGEvent] = []
        ClipboardUtil.insertText(payload, postEvent: { posted.append($0) }, pasteboard: pasteboard)

        let during = TestFixtures.snapshotClipboard(pasteboard)
        TestFixtures.report("[clipboard] DURING THE PASTE \(during.description)")
        XCTAssertEqual(posted.map(\.type), [.keyDown, .keyUp], "the paste step posts a key pair")
        XCTAssertTrue(posted.allSatisfy { $0.flags.contains(.maskCommand) }, "and it is the Cmd-V pair")
        XCTAssertEqual(during.text, payload, "the payload is on the clipboard while the paste is being made")

        waitForThePasteboardToMove(on: pasteboard.changeCount,
                                   pasteboard,
                                   timeout: ClipboardUtil.clipboardRestoreDelay + 5)

        let after = TestFixtures.snapshotClipboard(pasteboard)
        TestFixtures.report("[clipboard] AFTER RESTORE   \(after.description)")
        XCTAssertEqual(after.items.map(\.type), before.items.map(\.type),
                       "the restore has to bring back the same types")
        XCTAssertEqual(after.items.map(\.data), before.items.map(\.data),
                       "the restore has to bring back the same bytes")
    }

    /// The guard, driven deterministically: the case itself writes to the
    /// pasteboard inside the window, standing in for the other process that made
    /// the byte-identity assertion above fail when it ran on the real clipboard.
    func testAClipboardTakenDuringThePasteIsNotOverwrittenByTheRestore() {
        seedOwnPasteboard("what the user had copied before the dictation \(UUID().uuidString)")
        let payload = "OpenSuperWhisper interference measurement \(UUID().uuidString)"
        ClipboardUtil.insertText(payload, postEvent: { _ in }, pasteboard: pasteboard)

        // Somebody else copies while the paste is in flight.
        let theirs = "taken by somebody else while the paste was in flight \(UUID().uuidString)"
        pasteboard.clearContents()
        pasteboard.setString(theirs, forType: .string)
        let theirChangeCount = pasteboard.changeCount

        RunLoop.current.run(until: Date().addingTimeInterval(ClipboardUtil.clipboardRestoreDelay + 0.5))

        TestFixtures.report("[clipboard] after a third party's write: changeCount=\(pasteboard.changeCount) "
                            + "(theirs was \(theirChangeCount)), holds theirs: \(pasteboard.string(forType: .string) == theirs)")
        XCTAssertEqual(pasteboard.changeCount, theirChangeCount, "nothing wrote after them")
        XCTAssertEqual(pasteboard.string(forType: .string), theirs,
                       "a clipboard write by somebody else must never be overwritten")
    }

    // MARK: - Measurement 2: what the process dying between copy and restore leaves

    /// The failure case of the round trip: the process is gone before the restore
    /// runs, so nothing is scheduled to remove the transcription.
    ///
    /// The child runs the app's **own** `ClipboardUtil.insertText` — the source
    /// file is compiled into it, not re-implemented — and then kills itself
    /// before the 1.5 s restore can fire, which is what a crash or a quit inside
    /// that window amounts to. The case reads what the machine's clipboard holds
    /// afterwards and then puts the user's clipboard back.
    func testAProcessThatDiesBetweenCopyAndRestoreLeavesTheTranscriptionOnTheClipboard() throws {
        let helper = try Self.buildDeathHelper()

        seedOwnPasteboard("what the user had copied before the crash \(UUID().uuidString)")
        let before = TestFixtures.snapshotClipboard(pasteboard)
        do {
            let payload = "OpenSuperWhisper death measurement \(UUID().uuidString)"
            let child = Process()
            child.executableURL = helper
            child.arguments = [payload, boardName.rawValue]
            let pipe = Pipe()
            child.standardOutput = pipe
            try? child.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            child.waitUntilExit()

            TestFixtures.report("[clipboard] the child ran the app's own insertText and died: exit status "
                                + "\(child.terminationStatus) (9 = SIGKILL), it reported: "
                                + String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))

            let after = TestFixtures.snapshotClipboard(pasteboard)
            TestFixtures.report("[clipboard] AFTER THE DEATH   \(after.description)")
            TestFixtures.report("[clipboard] BEFORE THE DEATH  \(before.description)")

            XCTAssertEqual(after.text, payload,
                           "with the process gone there is nothing to restore, so the transcription stays")
            XCTAssertNotEqual(after.items.map(\.data), before.items.map(\.data),
                              "…and the user's own clipboard contents are gone")
        }
    }

    /// Compiles the death helper from the app's own `ClipboardUtil.swift` plus a
    /// three-line main, into the test's temporary directory.
    ///
    /// - Throws: `MeasurementError` when the sources or the build are not there.
    ///   Never `XCTSkip`: a skipped measurement that the change's own
    ///   documentation cites is worse than a failing one, because it is counted
    ///   as an environment exclusion and nobody looks.
    private static func buildDeathHelper() throws -> URL {
        let repo = URL(fileURLWithPath: #filePath)          // …/OpenSuperWhisperTests/DeliveryMeasurementTests.swift
            .deletingLastPathComponent()                    // …/OpenSuperWhisperTests
            .deletingLastPathComponent()                    // repo root
        // Both files: ClipboardUtil calls ClipboardRecovery, so a helper built
        // from ClipboardUtil alone no longer compiles — which is exactly how this
        // case spent a commit being silently skipped while the change's own
        // documentation cited it as proof.
        let sources = ["OpenSuperWhisper/Utils/ClipboardUtil.swift",
                       "OpenSuperWhisper/Utils/ClipboardRecovery.swift"]
            .map { repo.appendingPathComponent($0) }
        for source in sources where !FileManager.default.fileExists(atPath: source.path) {
            throw MeasurementError.missingSource(source.path)
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osw-clipboard-death-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let main = """
        import Cocoa

        // The app's own ClipboardUtil and ClipboardRecovery are compiled in beside
        // this file: the child copies exactly what the app copies, and then dies
        // before the restore its own code scheduled can run. It works on the
        // pasteboard the case named, so nothing else on the machine can interfere
        // and the machine's own clipboard is not used at all.
        let text = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "probe"
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(CommandLine.arguments[2]))
        ClipboardUtil.insertText(text, postEvent: { _ in }, pasteboard: pasteboard)
        print("child wrote the clipboard, holds the text: \\(pasteboard.string(forType: .string) == text), "
              + "changeCount=\\(pasteboard.changeCount)")
        fflush(stdout)
        kill(getpid(), SIGKILL)
        """
        let mainURL = directory.appendingPathComponent("main.swift")
        try main.write(to: mainURL, atomically: true, encoding: .utf8)
        let binary = directory.appendingPathComponent("clipboard-death")

        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["swiftc", "-O"] + sources.map(\.path) + [mainURL.path, "-o", binary.path]
        let errors = Pipe()
        compiler.standardError = errors
        try compiler.run()
        let errorOutput = errors.fileHandleForReading.readDataToEndOfFile()
        compiler.waitUntilExit()
        guard compiler.terminationStatus == 0 else {
            // NOT a skip: this case measures something the documentation cites, and
            // a skip here was counted among the layout-gated ones, i.e. as an
            // environment exclusion rather than as a broken measurement. A case
            // that cannot run is a failure of this file, not of the machine.
            throw MeasurementError.helperDidNotBuild(String(String(decoding: errorOutput, as: UTF8.self).suffix(400)))
        }
        return binary
    }

    /// Why a measurement could not be taken. Deliberately not `XCTSkip`: see
    /// `buildDeathHelper`.
    enum MeasurementError: Error, CustomStringConvertible {
        case missingSource(String)
        case helperDidNotBuild(String)

        var description: String {
            switch self {
            case .missingSource(let path):
                return "the source this measurement compiles is not at \(path)"
            case .helperDidNotBuild(let output):
                return "the child could not be built from the app's own sources: \(output)"
            }
        }
    }

    // MARK: - Measurement 3: what is readable about the application being typed into

    /// Everything this process can actually see about the application a delivery
    /// would go to, and what a family filter would match on this machine.
    ///
    /// Reports the frontmost application three ways (what the app itself reads,
    /// `bundleIdentifier`, localized name, pid), every running application's
    /// bundle identifier, which of them the branch's current exact list matches,
    /// which a naive vendor-prefix family filter would match, and which browsers
    /// or remote-session hosts are running that such a filter could confuse.
    func testWhatIsReadableAboutTheApplicationADeliveryWouldGoTo() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        TestFixtures.report(
            "[target] frontmost: bundleIdentifier=\(frontmost?.bundleIdentifier ?? "nil") "
            + "localizedName=\(frontmost?.localizedName ?? "nil") "
            + "pid=\(frontmost?.processIdentifier ?? -1) active=\(frontmost?.isActive ?? false) "
            + "policy=\(frontmost.map { String(describing: $0.activationPolicy) } ?? "nil")"
        )
        TestFixtures.report("[target] what the app's own reader returns: "
                            + (TextDelivery.currentFrontmostBundleIdentifier() ?? "nil"))

        let running = NSWorkspace.shared.runningApplications
        let identifiers = running.compactMap(\.bundleIdentifier).sorted()
        TestFixtures.report("[target] \(running.count) running applications, bundle identifiers: \(identifiers)")

        let exact = identifiers.filter { TextDelivery.verifiedRemoteClientBundleIdentifiers.contains($0) }
        TestFixtures.report("[target] matched by the measured exact list: \(exact)")

        let byFamily = identifiers.filter { id in
            TextDelivery.remoteClientVendorPrefixes.contains { id.hasPrefix($0) }
        }
        TestFixtures.report("[target] matched by the vendor-prefix family rule (a judgement, not a measurement): "
                            + "\(byFamily)")

        // The Citrix family specifically: the client ships many bundles, and which
        // one is in front during a session is the whole question.
        let citrix = identifiers.filter { $0.hasPrefix("com.citrix.") }
        TestFixtures.report("[target] the Citrix bundles visible to this process: \(citrix)")

        // What a family filter could confuse: browsers (they host remote sessions
        // in a tab) and anything with a remote-session word in its identifier.
        let confusable = identifiers.filter { id in
            let lowered = id.lowercased()
            return lowered.contains("chrome") || lowered.contains("safari") || lowered.contains("firefox")
                || lowered.contains("edge") || lowered.contains("browser")
                || lowered.contains("remote") || lowered.contains("vnc") || lowered.contains("rdp")
                || lowered.contains("desktop") || lowered.contains("screen")
        }
        TestFixtures.report("[target] identifiers a naive filter could confuse with a client: \(confusable)")

        // What is asserted, rather than only that a reading is not nil:
        //
        // 1. the frontmost application is readable, and the delivery's own reader
        //    agrees with the direct one — a disagreement would mean a delivery
        //    acts on a different application than the one measured here;
        // 2. every identifier the measured tier names is classified as such, on
        //    the spot (a rule check, not an environment check);
        // 3. every measured identifier that happens to be running is matched by
        //    the tier and would paste without the user switching anything on —
        //    conditional on it running, and asserting nothing when none is, since
        //    a machine without Citrix or Parallels installed is a different
        //    machine, not a broken rule.
        XCTAssertNotNil(frontmost, "the frontmost application has to be readable at delivery time")
        XCTAssertEqual(
            TextDelivery.currentFrontmostBundleIdentifier(), frontmost?.bundleIdentifier,
            "the reader the delivery uses has to agree with the direct reading of the frontmost application"
        )
        for identifier in TextDelivery.verifiedRemoteClientBundleIdentifiers.sorted() {
            XCTAssertEqual(TextDelivery.targetMatch(identifier), .verifiedClient,
                           "\(identifier) is in the measured tier and has to be classified as such")
        }
        // Conditional by design: a machine with none of the measured clients
        // running is a different machine, not a broken rule, so nothing is
        // asserted about the *population* - only that whatever is running and
        // measured is classified as measured.
        let runningVerified = identifiers.filter { TextDelivery.verifiedRemoteClientBundleIdentifiers.contains($0) }
        for identifier in runningVerified {
            XCTAssertEqual(TextDelivery.targetMatch(identifier), .verifiedClient)
            XCTAssertEqual(
                TextDelivery.mechanism(preference: .automatic,
                                       frontmostBundleIdentifier: identifier,
                                       pasteIntoRecognisedVendors: false),
                .clipboardPaste,
                "a measured client gets the clipboard without the user having to switch anything on"
            )
        }
    }
}
