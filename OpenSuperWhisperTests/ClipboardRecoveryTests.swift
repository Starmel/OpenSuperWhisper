import AppKit
import XCTest
@testable import OpenSuperWhisper

/// F6: the clipboard record that closes the hole the measurement proved.
///
/// `DeliveryMeasurementTests` shows what a paste delivery leaves behind when the
/// process dies between the copy and the restore: the transcription on the
/// clipboard and the user's previous contents gone. `ClipboardRecovery` is the
/// answer to that, and these cases prove the answer rather than describing it —
/// including one that kills a real child process running the app's own code and
/// then runs the recovery path the next launch runs.
///
/// An independent judgment put "the disk recovery closes the crash hole" at 0.47,
/// i.e. undecided, so the last case in this file states plainly which part of the
/// chain is proven here and which is not.
@MainActor
final class ClipboardRecoveryTests: XCTestCase {

    private var savedRecordURL: URL!

    override func setUp() {
        super.setUp()
        savedRecordURL = ClipboardRecovery.recordURL
        ClipboardRecovery.recordURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("osw-recovery-test-\(UUID().uuidString).plist")
    }

    override func tearDown() {
        ClipboardRecovery.clear()
        ClipboardRecovery.recordURL = savedRecordURL
        super.tearDown()
    }

    private func temporaryRecordURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("osw-recovery-child-\(UUID().uuidString).plist")
    }

    // MARK: - The ordinary paths

    /// A launch with no record pending does nothing at all — the state of every
    /// normal launch.
    func testALaunchWithNothingPendingTouchesNothing() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("osw-recovery-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("untouched", forType: .string)

        XCTAssertEqual(ClipboardRecovery.recoverIfNeeded(from: temporaryRecordURL(), on: pasteboard),
                       .nothingPending)
        XCTAssertEqual(pasteboard.string(forType: .string), "untouched")
    }

    /// The delivery writes the record **before** it touches the pasteboard, and
    /// the record holds what was there — the property the whole recovery rests on.
    func testTheRecordIsWrittenBeforeThePasteboardIsOverwrittenAndClearedAfterwards() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("osw-recovery-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("the user's own text", forType: .string)

        let payload = "the transcription \(UUID().uuidString)"
        ClipboardUtil.insertText(payload, postEvent: { _ in }, pasteboard: pasteboard)

        // Still inside the paste window: the pasteboard holds the transcription
        // and the record already holds what it displaced.
        XCTAssertEqual(pasteboard.string(forType: .string), payload)
        let record = ClipboardRecovery.pending(at: ClipboardRecovery.recordURL)
        XCTAssertNotNil(record, "the record has to exist while the transcription is on the clipboard")
        XCTAssertEqual(record?.writtenTextDigest, ClipboardRecovery.digest(of: payload))
        XCTAssertEqual(record?.data[NSPasteboard.PasteboardType.string.rawValue],
                       Data("the user's own text".utf8),
                       "the record holds what the pasteboard had, not the transcription")
        TestFixtures.report("[recovery] inside the paste window: record exists=\(record != nil) "
                            + "types=\(record?.types ?? []) (contents hashed, not printed)")

        // After the delivery's own restore, the record has done its job.
        RunLoop.current.run(until: Date().addingTimeInterval(ClipboardUtil.clipboardRestoreDelay + 0.6))
        XCTAssertEqual(pasteboard.string(forType: .string), "the user's own text")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ClipboardRecovery.recordURL.path),
                       "an ordinary delivery leaves no record behind")
    }

    // MARK: - The crash, end to end

    /// A real child process, built from the app's own `ClipboardUtil` and
    /// `ClipboardRecovery`, copies the text, then SIGKILLs itself before its
    /// restore can run. The next launch — this case calling the same entry point
    /// the launch calls — has to put the displaced contents back.
    ///
    /// The child and this case share a **named** pasteboard: one server-side
    /// object, so this is a real cross-process pasteboard and not a mock, and the
    /// machine's general clipboard is not used by this case at all. (Two of these
    /// classes on the general clipboard at once is a race this suite has already
    /// produced once: the child of this very case wrote over the round-trip
    /// case's window, and the round-trip case caught it. No case uses the general
    /// clipboard now, except one that reads its changeCount without writing it.)
    func testARecordLeftByAProcessThatDiedIsRecoveredOnTheNextLaunch() throws {
        let helper = try Self.buildDeathHelper()
        let recordURL = temporaryRecordURL()
        defer { try? FileManager.default.removeItem(at: recordURL) }

        let boardName = NSPasteboard.Name("osw-recovery-pasteboard-\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: boardName)
        defer { pasteboard.releaseGlobally() }
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("what the user had before the crash", forType: .string)
        let before = TestFixtures.snapshotClipboard(pasteboard)

        let payload = "OpenSuperWhisper recovery measurement \(UUID().uuidString)"

        let child = Process()
        child.executableURL = helper
        child.arguments = [payload, recordURL.path, boardName.rawValue]
        let pipe = Pipe()
        child.standardOutput = pipe
        try? child.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        TestFixtures.report("[recovery] the child ran the app's own paste step and died: status "
                            + "\(child.terminationStatus) (9 = SIGKILL), it reported: "
                            + String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))

        // What the dead process left behind.
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordURL.path),
                      "the record has to survive the process that wrote it")
        XCTAssertEqual(pasteboard.string(forType: .string), payload,
                       "…and the transcription is still on the clipboard, which is the hole being closed")
        let pending = try XCTUnwrap(ClipboardRecovery.pending(at: recordURL))
        XCTAssertEqual(pending.writtenTextDigest, ClipboardRecovery.digest(of: payload))

        // What the next launch does.
        let outcome = ClipboardRecovery.recoverIfNeeded(from: recordURL, on: pasteboard)
        let after = TestFixtures.snapshotClipboard(pasteboard)
        TestFixtures.report("[recovery] outcome: \(outcome); clipboard byte-identical to before the crash: "
                            + "\(after.items.map(\.data) == before.items.map(\.data)); record still there: "
                            + "\(FileManager.default.fileExists(atPath: recordURL.path))")

        guard case .restored = outcome else {
            return XCTFail("expected the recovery to restore the clipboard, got \(outcome)")
        }
        XCTAssertEqual(after.items.map(\.type), before.items.map(\.type),
                       "the recovered clipboard has to carry the same types")
        XCTAssertEqual(after.items.map(\.data), before.items.map(\.data),
                       "the recovered clipboard has to carry the same bytes")
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordURL.path),
                       "a record that has been recovered must not survive to fire again")
    }

    /// The other side of the same rule: if the clipboard no longer holds our text,
    /// the record is dropped and the clipboard is left alone — whoever wrote to it
    /// after the crash keeps their contents.
    func testARecordIsDiscardedWhenSomebodyElseHasTakenTheClipboard() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("osw-recovery-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        let payload = "the transcription that never got restored \(UUID().uuidString)"
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("what the user had", forType: .string)
        let record = try XCTUnwrap(ClipboardRecovery.record(for: pasteboard, writtenText: payload))
        XCTAssertTrue(ClipboardRecovery.write(record, to: ClipboardRecovery.recordURL))

        // The crash happened, and then somebody copied something new.
        pasteboard.clearContents()
        pasteboard.setString("copied after the crash", forType: .string)

        let outcome = ClipboardRecovery.recoverIfNeeded(from: ClipboardRecovery.recordURL, on: pasteboard)
        TestFixtures.report("[recovery] outcome with somebody else's clipboard: \(outcome)")
        XCTAssertEqual(outcome, .somebodyElseHasTheClipboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "copied after the crash")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ClipboardRecovery.recordURL.path))
    }

    /// A reboot comes back to an empty pasteboard — the pasteboard server keeps
    /// nothing — and the record is still on disk. The displaced contents go back
    /// into a board that holds nothing of anyone's.
    func testARecordIsRestoredIntoAnEmptyPasteboardAfterAReboot() throws {
        let boardName = NSPasteboard.Name("osw-reboot-\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: boardName)
        defer { pasteboard.releaseGlobally() }

        // What the delivery displaced, and what it wrote over it.
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("what the user had copied", forType: .string)
        let payload = "the transcription that was on the clipboard when the app died \(UUID().uuidString)"
        let record = try XCTUnwrap(ClipboardRecovery.record(for: pasteboard, writtenText: payload))
        XCTAssertTrue(ClipboardRecovery.write(record, to: ClipboardRecovery.recordURL))

        // …and then the machine restarts: the clipboard comes back empty.
        pasteboard.clearContents()
        XCTAssertTrue((pasteboard.types ?? []).isEmpty, "a cleared pasteboard reports no types")

        let outcome = ClipboardRecovery.recoverIfNeeded(from: ClipboardRecovery.recordURL, on: pasteboard)
        TestFixtures.report("[recovery] outcome after a reboot (empty pasteboard): \(outcome); "
                            + "board now holds: \(pasteboard.string(forType: .string) ?? "nil")")
        XCTAssertEqual(outcome, .restored(types: record.types.count))
        XCTAssertEqual(pasteboard.string(forType: .string), "what the user had copied")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ClipboardRecovery.recordURL.path))
    }

    /// …and a board holding anything that is not this app's text is still left
    /// alone, whether it is somebody's text or content of another type entirely.
    func testARecordIsDiscardedWhenTheBoardHoldsSomethingThatIsNotThisAppsText() throws {
        for (label, seed) in [("somebody's text", { (board: NSPasteboard) in
            board.declareTypes([.string], owner: nil)
            board.setString("copied by somebody else after the crash", forType: .string)
        }), ("a non-text item", { (board: NSPasteboard) in
            board.declareTypes([.tiff], owner: nil)
            board.setData(Data([0x00, 0x01, 0x02, 0x03]), forType: .tiff)
        })] {
            let boardName = NSPasteboard.Name("osw-not-ours-\(UUID().uuidString)")
            let pasteboard = NSPasteboard(name: boardName)
            defer { pasteboard.releaseGlobally() }

            pasteboard.declareTypes([.string], owner: nil)
            pasteboard.setString("what the user had", forType: .string)
            let record = try XCTUnwrap(ClipboardRecovery.record(
                for: pasteboard,
                writtenText: "the transcription \(UUID().uuidString)"
            ))
            XCTAssertTrue(ClipboardRecovery.write(record, to: ClipboardRecovery.recordURL))

            pasteboard.clearContents()
            seed(pasteboard)

            let outcome = ClipboardRecovery.recoverIfNeeded(from: ClipboardRecovery.recordURL, on: pasteboard)
            TestFixtures.report("[recovery] outcome with \(label) on the board: \(outcome)")
            XCTAssertEqual(outcome, .somebodyElseHasTheClipboard, "\(label) must not be overwritten")
            XCTAssertFalse(FileManager.default.fileExists(atPath: ClipboardRecovery.recordURL.path))
        }
    }

    /// A record nothing can read is removed rather than left to be retried.
    func testAnUnreadableRecordIsDiscarded() throws {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("osw-recovery-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("untouched", forType: .string)
        try Data("not a property list at all".utf8).write(to: ClipboardRecovery.recordURL)

        XCTAssertEqual(ClipboardRecovery.recoverIfNeeded(from: ClipboardRecovery.recordURL, on: pasteboard),
                       .unreadableRecord)
        XCTAssertEqual(pasteboard.string(forType: .string), "untouched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ClipboardRecovery.recordURL.path))
    }

    // MARK: - The launch step itself

    /// The decision a launch makes, both ways.
    ///
    /// What this covers: that the production branch recovers a pending record and
    /// that the test branch touches nothing. What it does NOT cover: that a real
    /// launch reaches the call, which is one line in
    /// `OpenSuperWhisperApp.applicationDidFinishLaunching` and is verified by
    /// reading it — a test cannot observe a launch of the app under test, and
    /// pretending otherwise is what this case exists to avoid claiming.
    func testTheLaunchStepRecoversInProductionAndDoesNothingUnderTest() throws {
        let boardName = NSPasteboard.Name("osw-launch-step-\(UUID().uuidString)")
        let pasteboard = NSPasteboard(name: boardName)
        defer { pasteboard.releaseGlobally() }

        // Production branch: a record is pending and the pasteboard still holds
        // this app's text, so the displaced contents come back.
        let payload = "a dictation that was never restored \(UUID().uuidString)"
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString("what the user had", forType: .string)
        let record = try XCTUnwrap(ClipboardRecovery.record(for: pasteboard, writtenText: payload))
        XCTAssertTrue(ClipboardRecovery.write(record, to: ClipboardRecovery.recordURL))
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)

        let outcome = ClipboardRecovery.launchStep(isRunningTests: false, on: pasteboard)
        XCTAssertEqual(outcome, .restored(types: record.types.count),
                       "a launch has to put back every type the record captured")
        XCTAssertEqual(pasteboard.string(forType: .string), "what the user had")
        XCTAssertFalse(FileManager.default.fileExists(atPath: ClipboardRecovery.recordURL.path))

        // Test branch: nothing is read, nothing is restored, the record stays.
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
        XCTAssertTrue(ClipboardRecovery.write(record, to: ClipboardRecovery.recordURL))

        XCTAssertNil(ClipboardRecovery.launchStep(isRunningTests: true, on: pasteboard),
                     "a test host does not recover, so a suite can never rewrite a clipboard")
        XCTAssertEqual(pasteboard.string(forType: .string), payload, "the board was left alone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ClipboardRecovery.recordURL.path),
                      "and the record is still there for the next real launch")
    }

    // MARK: - The child

    /// Compiles the child from the app's two clipboard files plus a few lines of
    /// main, so what dies is the app's own code path and not a re-implementation
    /// of it.
    private static func buildDeathHelper() throws -> URL {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OpenSuperWhisperTests
            .deletingLastPathComponent()   // repo root
        let sources = ["OpenSuperWhisper/Utils/ClipboardUtil.swift",
                       "OpenSuperWhisper/Utils/ClipboardRecovery.swift"]
            .map { repo.appendingPathComponent($0) }
        for source in sources where !FileManager.default.fileExists(atPath: source.path) {
            throw HelperError.missingSource(source.path)
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("osw-recovery-child-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let main = """
        import Cocoa

        // Compiled beside the app's own ClipboardUtil and ClipboardRecovery.
        let text = CommandLine.arguments[1]
        let recordPath = URL(fileURLWithPath: CommandLine.arguments[2])
        // A pasteboard of the case's own, reachable from this process and from the
        // case that started it: the same server-side object, so this is a real
        // cross-process pasteboard, and the machine's general clipboard is left
        // alone.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name(CommandLine.arguments[3]))
        ClipboardRecovery.recordURL = recordPath
        ClipboardUtil.insertText(text, postEvent: { _ in }, pasteboard: pasteboard)
        print("child: clipboard holds the text: \\(pasteboard.string(forType: .string) == text); "
              + "record written: \\(FileManager.default.fileExists(atPath: recordPath.path)); "
              + "record holds types: \\(ClipboardRecovery.pending(at: recordPath)?.types ?? [])")
        fflush(stdout)
        kill(getpid(), SIGKILL)
        """
        let mainURL = directory.appendingPathComponent("main.swift")
        try main.write(to: mainURL, atomically: true, encoding: .utf8)
        let binary = directory.appendingPathComponent("clipboard-recovery-child")

        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["swiftc", "-O"] + sources.map(\.path) + [mainURL.path, "-o", binary.path]
        let errors = Pipe()
        compiler.standardError = errors
        try compiler.run()
        let errorOutput = errors.fileHandleForReading.readDataToEndOfFile()
        compiler.waitUntilExit()
        guard compiler.terminationStatus == 0 else {
            // NOT a skip, for the reason the delivery-measurement helper states:
            // a case that cannot run is a failure of this file, not an
            // environment exclusion, and a skip here would be counted with the
            // layout-gated ones and never looked at again.
            throw HelperError.didNotBuild(String(String(decoding: errorOutput, as: UTF8.self).suffix(500)))
        }
        return binary
    }

    /// Why the child could not be built. Deliberately not `XCTSkip`.
    enum HelperError: Error, CustomStringConvertible {
        case missingSource(String)
        case didNotBuild(String)

        var description: String {
            switch self {
            case .missingSource(let path):
                return "the source the child compiles is not at \(path)"
            case .didNotBuild(let output):
                return "the child could not be built from the app's own sources: \(output)"
            }
        }
    }
}
