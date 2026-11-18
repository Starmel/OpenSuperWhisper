import AppKit
import SwiftUI
import Vision
import XCTest

@testable import OpenSuperWhisper

/// The History row — `RecordingRow` — rendered offscreen for each of the four
/// states the failed-dictation change touches, one PNG per state, so a human can
/// look at them rather than reason from the view code.
///
/// What is asserted here is only what a machine can settle on its own: that each
/// capture was produced, and that the empty failed row reads "No transcript" and
/// not "Transcription failed". The words are read back out of the rendered row —
/// out of the capture with Vision, and out of the accessibility labels SwiftUI
/// publishes for the very `Text` views it drew — not out of the source that was
/// supposed to draw them. How any of it *looks* — the neutral grey, the absence
/// of the warning triangle, the ordinary rows being untouched — is what the PNGs
/// are for; no assertion here claims it.
///
/// Rendering is hosted-window + `cacheDisplay`, the route
/// `SettingsLayoutSnapshotTests` uses: `ImageRenderer` cannot draw this row (its
/// buttons, its transcription area and its text are AppKit-backed), and
/// `cacheDisplay` draws the hierarchy rather than the screen, so no visible
/// window, no screenshot and no screen-recording permission is involved.
///
/// Nothing outside the four PNGs is written: the rows are plain `Recording`
/// values that never reach a store, and no audio file, database or preference is
/// read or written.
@MainActor
final class HistoryRowSnapshotTests: XCTestCase {

    // MARK: - The states

    /// One fixed instant for every row: the PNGs are evidence, and a timestamp
    /// that moved between runs would make two images of the same state differ
    /// for a reason that is not the state.
    private static let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

    private static let duration: TimeInterval = 3.4

    private func recording(_ status: RecordingStatus, _ transcription: String) -> Recording {
        let id = UUID()
        return Recording(id: id,
                         timestamp: Self.timestamp,
                         fileName: Recording.fileName(for: id),
                         transcription: transcription,
                         duration: Self.duration,
                         status: status,
                         progress: status == .completed ? 1 : 0)
    }

    /// A failed row with no transcript: what a failed dictation leaves behind
    /// now, and the state the change is about.
    private var failedWithoutTranscript: Recording { recording(.failed, "") }

    /// The legacy shape: a row written before the transcript column stopped
    /// carrying the failure's own text still has one, and keeps its wording.
    private var failedWithTranscript: Recording {
        recording(.failed, "The operation couldn’t be completed. "
                  + "(OpenSuperWhisper.TranscriptionError error 1.)")
    }

    /// An ordinary successful dictation.
    private var completedWithText: Recording {
        recording(.completed, "Remind me to call the dentist at four.")
    }

    /// A successful dictation that carried nothing.
    private var completedWithoutText: Recording { recording(.completed, "") }

    // MARK: - Tests

    func testFailedRowWithoutTranscriptReadsNeutral() throws {
        let rendered = try render(failedWithoutTranscript, named: "1-failed-empty-transcript")
        print("[history-row] 1-failed-empty-transcript reads: \(rendered.asRead)")

        XCTAssertTrue(rendered.says("notranscript"),
                      "the empty failed row did not render \"No transcript\"; it read: \(rendered.asRead)")
        // Spelled out rather than trusted to one reader: Vision has already been
        // seen to read a word a letter out ("failed" as "falled"), so this half
        // of the pair is the accessibility label, which is the string itself.
        XCTAssertFalse(rendered.says("transcriptionfailed"),
                       "the empty failed row still rendered \"Transcription failed\"; it read: \(rendered.asRead)")

        // The alarm colour, which the legacy row below is the control for: this
        // asserts the *absence* of red, so it is worth something only if the
        // same detector finds red where red is still drawn — which is exactly
        // what testFailedRowWithTranscriptKeepsTheLegacyWording checks. It is
        // also the exact backstop for the check above: a reader that misreads a
        // word cannot hide a warning triangle or red text.
        XCTAssertFalse(try hasAlarmRed(rendered.image),
                       "the empty failed row still draws alarm red — a warning triangle or red text survived")
    }

    func testFailedRowWithTranscriptKeepsTheLegacyWording() throws {
        let rendered = try render(failedWithTranscript, named: "2-failed-legacy-transcript")
        print("[history-row] 2-failed-legacy-transcript reads: \(rendered.asRead)")

        // The control for the check above: red is still drawn here, so an image
        // reporting no red says something about the row, not about the probe.
        XCTAssertTrue(try hasAlarmRed(rendered.image),
                      "the legacy failed row no longer draws its red warning — the no-red check in "
                      + "testFailedRowWithoutTranscriptReadsNeutral has nothing to be true against")
    }

    func testCompletedRowWithText() throws {
        let rendered = try render(completedWithText, named: "3-completed-with-text")
        print("[history-row] 3-completed-with-text reads: \(rendered.asRead)")
    }

    func testCompletedRowWithoutText() throws {
        let rendered = try render(completedWithoutText, named: "4-completed-without-text")
        print("[history-row] 4-completed-without-text reads: \(rendered.asRead)")
    }

    // MARK: - Output

    /// `fleet/` sits beside the checkout rather than inside it, so the evidence
    /// directory is found by walking up from this file until a `fleet/data`
    /// exists. `OSW_HISTORY_ROW_EVIDENCE_DIR` overrides that, and when neither is
    /// there the capture still happens and lands in `build/HistoryRowSnapshots`.
    private static var outputDirectory: URL {
        let checkout = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OpenSuperWhisperTests
            .deletingLastPathComponent()   // the checkout
        if let override = ProcessInfo.processInfo.environment["OSW_HISTORY_ROW_EVIDENCE_DIR"],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        var ancestor = checkout
        for _ in 0..<3 {
            ancestor = ancestor.deletingLastPathComponent()
            let fleetData = ancestor.appendingPathComponent("fleet/data", isDirectory: true)
            if FileManager.default.fileExists(atPath: fleetData.path) {
                return fleetData.appendingPathComponent("evidence/history-row", isDirectory: true)
            }
        }
        return checkout.appendingPathComponent("build/HistoryRowSnapshots/latest", isDirectory: true)
    }

    private enum SnapshotError: Error, CustomStringConvertible {
        case renderFailed(String)
        case contextFailed

        var description: String {
            switch self {
            case .renderFailed(let name): return "the capture produced no image for \(name)"
            case .contextFailed: return "could not create a bitmap context for the snapshot"
            }
        }
    }

    // MARK: - What a rendered row says

    /// One rendered row: its pixels, and every string that can be read back out
    /// of it without a human.
    private struct Rendered {
        let image: CGImage
        /// What Vision read off the capture.
        let fromPixels: String
        /// What SwiftUI published as accessibility labels for the row.
        let fromAccessibility: [String]

        var asRead: String {
            "from the pixels: \"\(fromPixels)\"; "
            + "from the accessibility labels: \(fromAccessibility.map { "\"\($0)\"" }.joined(separator: ", "))"
        }

        /// Whether anything the row says contains `needle`, compared with
        /// spacing and punctuation collapsed away — the two readers punctuate
        /// differently, and neither difference is a difference in the row.
        func says(_ needle: String) -> Bool {
            ([fromPixels] + fromAccessibility).contains { $0.comparable.contains(needle) }
        }
    }

    // MARK: - Rendering

    /// Renders one row the way the history list shows it, writes it to
    /// `outputDirectory`, and returns the pixels and the strings.
    private func render(_ recording: Recording, named name: String) throws -> Rendered {
        let (image, accessibility) = try capture(historyList(recording), named: name)

        let directory = Self.outputDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw SnapshotError.renderFailed(name)
        }
        try png.write(to: url)

        XCTAssertGreaterThan(image.width, 0, "\(name): the capture has no width")
        XCTAssertGreaterThan(image.height, 0, "\(name): the capture has no height")
        XCTAssertGreaterThan(png.count, 0, "\(name): the PNG is empty")

        // Freshly re-read rather than trusted: this is the file the human opens.
        let onDisk = try Data(contentsOf: url)
        XCTAssertEqual(onDisk.count, png.count,
                       "\(name): the PNG on disk is not the one that was measured")
        print("[history-row] \(name).png \(image.width)x\(image.height)px -> \(url.path)")

        return Rendered(image: image,
                        fromPixels: try recognisedText(in: image),
                        fromAccessibility: accessibility)
    }

    /// The row inside the list's own insets, in a window 450 pt wide — the width
    /// `AppDelegate` pins the app's window to — on the window background, in the
    /// light appearance the shipped default draws.
    private func historyList(_ recording: Recording) -> some View {
        VStack(spacing: 8) {
            RecordingRow(recording: recording, searchQuery: "", onDelete: {}, onRegenerate: {})
        }
        .padding(.horizontal, 16)   // the history list's own padding
        .padding(.vertical, 12)
        .frame(width: 450)
        .background(ThemePalette.windowBackground(.light))
        .environment(\.colorScheme, .light)
    }

    /// Hosts `view` in a borderless window sized to what the view itself says it
    /// needs, draws it with `cacheDisplay`, and reads the accessibility labels
    /// off the hosted tree while it is still alive.
    private func capture<V: View>(_ view: V, named name: String) throws -> (CGImage, [String]) {
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: 40, y: 40),
                                                  size: CGSize(width: 450, height: 240)),
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        // The evidence must not depend on the machine's dark-mode setting.
        window.appearance = NSAppearance(named: .aqua)
        let hosting = NSHostingView(rootView: view)
        // `.intrinsicContentSize` rather than `[]` (the sheet snapshots size
        // their window explicitly): the row *is* the content here, so its own
        // height is what the capture must be, and a hand-measured number would
        // go stale the first time the row grows a line.
        hosting.sizingOptions = [.intrinsicContentSize]
        window.contentView = hosting
        window.orderFrontRegardless()
        runLoopTurn(0.4)

        // A state's text wraps in stages, so a size read after one pass can be a
        // size the row has already outgrown — the capture would then clip the
        // last line, which reads as a row that never had it. Wait for two
        // consecutive passes to agree.
        var size = window.contentRect(forFrameRect: window.frame).size
        var previous = CGSize(width: -1, height: -1)
        var settled = 0
        for _ in 0..<20 {
            window.contentView?.layoutSubtreeIfNeeded()
            let fitting = hosting.fittingSize
            size = CGSize(width: max(450, fitting.width), height: max(1, fitting.height))
            if size == previous {
                settled += 1
                if settled >= 2 { break }
            } else {
                settled = 0
            }
            previous = size
            window.setContentSize(size)
            runLoopTurn(0.1)
        }
        window.setContentSize(size)
        runLoopTurn(0.2)
        window.contentView?.layoutSubtreeIfNeeded()

        guard size.height > 1 else {
            window.close()
            throw SnapshotError.renderFailed("\(name): the hosted row never reported a height "
                                             + "(last fitting size \(size))")
        }

        let bounds = hosting.bounds
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: bounds) else {
            window.close()
            throw SnapshotError.renderFailed("\(name): no bitmap for the hosted row")
        }
        hosting.cacheDisplay(in: bounds, to: rep)
        guard let image = rep.cgImage else {
            window.close()
            throw SnapshotError.renderFailed("\(name): cacheDisplay produced no image")
        }
        let accessibility = accessibilityStrings(in: hosting)
        window.close()
        runLoopTurn(0.1)
        return (image, accessibility)
    }

    private func runLoopTurn(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: - Reading the capture back

    /// What the row says, read out of the capture with Vision: the same pixels
    /// the human will look at, rather than the source that was supposed to draw
    /// them. Language correction is on — without it Vision reads a rendered word
    /// a letter out ("failed" came back as "falled"), which is a fact about the
    /// reader and not about the row.
    private func recognisedText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw SnapshotError.renderFailed("Vision could not read the capture back: \(error)")
        }
        return (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .joined(separator: " ")
    }

    /// Every string SwiftUI published for the row: the accessibility labels of
    /// the `Text` views it drew, which are the strings themselves rather than a
    /// reading of their pixels.
    private func accessibilityStrings(in root: NSView) -> [String] {
        var found: [String] = []
        var pending: [Any] = [root]
        while let object = pending.popLast() {
            if let view = object as? NSView {
                found.append(contentsOf: strings(of: view))
                pending.append(contentsOf: view.subviews)
                if let children = view.accessibilityChildren() { pending.append(contentsOf: children) }
            } else if let element = object as? NSAccessibilityElement {
                found.append(contentsOf: strings(of: element))
                if let children = element.accessibilityChildren() { pending.append(contentsOf: children) }
            }
        }
        return found
    }

    private func strings(of element: NSView) -> [String] {
        [element.accessibilityLabel(), element.accessibilityValue() as? String, element.accessibilityTitle()]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
    }

    private func strings(of element: NSAccessibilityElement) -> [String] {
        [element.accessibilityLabel(), element.accessibilityValue() as? String, element.accessibilityTitle()]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
    }

    /// 8-bit sRGB pixels of the capture, top row first.
    private func bitmap(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        guard let context = CGContext(data: &pixels,
                                      width: image.width,
                                      height: image.height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw SnapshotError.contextFailed }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }

    /// Whether the capture contains the row's alarm colour at all: a pixel that
    /// is unmistakably red (`Color.red` is drawn on white, so its own pixels stay
    /// saturated and only its antialiased edge blends).
    private func hasAlarmRed(_ image: CGImage) throws -> Bool {
        let pixels = try bitmap(image)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let red = Int(pixels[offset]), green = Int(pixels[offset + 1])
            let blue = Int(pixels[offset + 2]), alpha = Int(pixels[offset + 3])
            if alpha > 200, red > 150, green < 120, blue < 120 { return true }
        }
        return false
    }
}

private extension String {
    /// Lowercased, with every run of anything that is not a letter or a digit
    /// collapsed away: what the row says compared with what it must say, without
    /// depending on how a reader decided to space or punctuate it.
    var comparable: String {
        lowercased()
            .filter { $0.isLetter || $0.isNumber || $0 == " " }
            .split(separator: " ")
            .joined()
    }
}
