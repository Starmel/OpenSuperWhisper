import AppKit
import SwiftUI
import XCTest

@testable import OpenSuperWhisper

/// Renders the Settings sheet offscreen — as a real sheet on a window the size of
/// the app's main window, and as each tab body hosted in a window of a given
/// viewport size — writes PNGs for visual review, and checks the layout
/// invariants the settings UI lives or dies by: cards are separate bands of
/// pixels, and no card is cut off at the edges of what is showing it.
///
/// `ImageRenderer` cannot draw this UI: `TabView` and `ScrollView` are AppKit
/// backed, and it renders them as a placeholder or as blank. Hosting the views in
/// a real `NSWindow` and drawing them with `cacheDisplay` needs no visible window,
/// no screenshot and no permission for it.
///
/// The PNGs land in `build/SettingsLayoutSnapshots/latest/`; the runner copies
/// that directory aside to keep a before/after pair.
@MainActor
final class SettingsLayoutSnapshotTests: XCTestCase {

    private static let tabs: [(name: String, index: Int)] = [
        ("shortcuts", 0), ("model", 1), ("transcription", 2), ("advanced", 3),
    ]

    /// The app's main window: `OpenSuperWhisperApp` fixes its width at 450 pt
    /// and `AppDelegate` clamps its height to 400…900 pt.
    private static let windowSizes: [(String, CGSize)] = [
        ("450x400", CGSize(width: 450, height: 400)),
        ("450x650", CGSize(width: 450, height: 650)),
        ("450x900", CGSize(width: 450, height: 900)),
    ]

    /// The sheet's natural size, using the same formula as `SettingsView`.
    private static var sheetSize: CGSize {
        let visibleFrame = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1280, height: 800)
        return CGSize(width: min(450, visibleFrame.width - 40), height: min(500, visibleFrame.height - 60))
    }

    /// What a tab body is handed inside the sheet: the sheet minus its 16 pt page
    /// padding and the tab strip above the content.
    private static var currentTabViewport: CGSize {
        let sheet = sheetSize
        return CGSize(width: sheet.width - 32, height: sheet.height - 32 - Self.tabStripHeight)
    }

    /// The segmented tab strip: 12 pt above, 24 pt of control, 8 pt below.
    private static let tabStripHeight: CGFloat = 44

    /// The three viewport sizes the brief asks for: what the sheet uses today,
    /// and the two reference sizes.
    private static var viewports: [(name: String, size: CGSize)] {
        [("current", currentTabViewport), ("520x560", CGSize(width: 520, height: 560)),
         ("520x900", CGSize(width: 520, height: 900))]
    }

    private static var outputDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // OpenSuperWhisperTests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("build/SettingsLayoutSnapshots/latest", isDirectory: true)
    }

    // MARK: - Errors

    private enum SnapshotError: Error, CustomStringConvertible {
        case renderFailed(String)
        case contextFailed

        var description: String {
            switch self {
            case .renderFailed(let name): return "the snapshot capture produced no image for \(name)"
            case .contextFailed: return "could not create a bitmap context for the snapshot"
            }
        }
    }

    // MARK: - PNG output

    /// Emptied once per test run, so the directory is exactly this run's set and
    /// a stale PNG can never pass for evidence.
    private static var outputDirectoryIsFresh = false

    @discardableResult
    private func writePNG(_ image: CGImage, named name: String) throws -> CGImage {
        let directory = Self.outputDirectory
        if !Self.outputDirectoryIsFresh {
            Self.outputDirectoryIsFresh = true
            try? FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw SnapshotError.renderFailed(name)
        }
        try png.write(to: url)
        print("[snapshot] \(name).png \(image.width)x\(image.height)px -> \(url.path)")
        return image
    }

    /// Hosts `view` in a window of `size`, lets it lay out, optionally scrolls the
    /// first scroll view to the bottom, and captures it with `cacheDisplay`.
    @discardableResult
    private func captureHosted(_ view: some View, size: CGSize, named name: String,
                               scrolledToBottom: Bool = false,
                               fullContent: Bool = false) throws -> (image: CGImage, size: CGSize) {
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: 40, y: 40), size: size),
                              styleMask: [.borderless],
                              backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        window.contentView = hosting
        window.setContentSize(size)
        window.orderFrontRegardless()
        runLoopTurn(0.4)

        if scrolledToBottom, let scrollView = firstScrollView(in: hosting) {
            let clip = scrollView.contentView
            let bottom = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
            clip.scroll(to: NSPoint(x: 0, y: bottom))
            scrollView.reflectScrolledClipView(clip)
            runLoopTurn(0.3)
        }

        // The whole tab, however tall it is: drawing the scroll view's document
        // view covers every card without guessing a window size, so the test
        // does not depend on how much content the current build has.
        if fullContent {
            // The hosted tree is not always built by the time the first run-loop
            // turn is over — XCTest loads test classes in parallel, and a class
            // still waking up has no scroll view yet. Skipping the wait quietly
            // dropped the capture through to the window fallback below, whose
            // shorter window clips the last card: that is how a capture that was
            // never a tab capture reported a card missing its 16 pt page padding.
            // So wait for the scroll view's document view, and fail loudly if the
            // hosted tree never materialises.
            let waitBudget: TimeInterval = 5
            var document: NSView?
            for _ in 0..<50 {
                if let documentView = firstScrollView(in: hosting)?.documentView {
                    document = documentView
                    break
                }
                runLoopTurn(0.1)
            }
            guard let document else {
                window.close()
                throw SnapshotError.renderFailed("\(name): no scroll view after "
                                                 + "\(waitBudget) s — the hosted tree never materialised")
            }

            // The document view only reaches its content's height after a few
            // layout passes, and a capture taken between passes draws the last
            // card clipped at the image edge — which reads exactly like a card
            // that is missing its page padding. Wait until the height stops
            // changing — for half a second, not one sample: a single tall Text
            // measures in stages, so two consecutive samples can agree in the
            // middle of the growth.
            var previousHeight: CGFloat = -1
            var settledSamples = 0
            for _ in 0..<60 {
                let height = document.bounds.height
                if height > 0, height == previousHeight {
                    settledSamples += 1
                    if settledSamples >= 5 { break }
                } else {
                    settledSamples = 0
                }
                previousHeight = height
                runLoopTurn(0.1)
            }

            // A settled height is not yet a settled *draw*: a capture taken while
            // AppKit has just changed the scroll view's usable width (the
            // scrollbar appearing re-wraps every caption, so the stack grows
            // downwards) comes back with the last card clipped at the image edge,
            // and that reads exactly like a card that is missing its page
            // padding. So: force the pending layout, draw, and accept a capture
            // only when both the rect and the raster it produced are unchanged
            // from the previous pass. Under a loaded machine the first pass or
            // two are not enough — this case has gone red that way inside a
            // suite and green every time on its own.
            var rect = document.bounds
            var previousRect = CGRect.null
            var previousPixels: [UInt8]?
            var documentImage: CGImage?
            // Converges in two passes when the layout is already settled — which
            // is the normal case — and keeps drawing while it is not. The budget
            // is time, not attempts-only: a few seconds of a loaded machine is
            // cheaper than a red suite caused by a capture taken mid-convergence.
            for _ in 0..<60 {
                // The whole tree, not just the document: the scroll view is what
                // decides how wide the content gets (its scroller's space), and
                // that decision is what re-wraps the cards.
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                rect = document.bounds
                guard let documentRep = document.bitmapImageRepForCachingDisplay(in: rect) else {
                    window.close()
                    throw SnapshotError.renderFailed("\(name): no bitmap for the tab's content")
                }
                document.cacheDisplay(in: rect, to: documentRep)
                guard let image = documentRep.cgImage else {
                    window.close()
                    throw SnapshotError.renderFailed("\(name): cacheDisplay produced no content image")
                }
                documentImage = image
                let pixels = try bitmap(image)
                if pixels == previousPixels, rect == previousRect { break }
                previousPixels = pixels
                previousRect = rect
                runLoopTurn(0.05)
            }
            guard let documentImage else {
                window.close()
                throw SnapshotError.renderFailed("\(name): the capture produced no content image")
            }
            let capture = try writePNG(documentImage, named: name)
            window.close()
            runLoopTurn(0.1)
            return (capture, rect.size)
        }

        let visible = hosting.bounds
        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: visible) else {
            window.close()
            throw SnapshotError.renderFailed("\(name): no bitmap for the hosted view")
        }
        hosting.cacheDisplay(in: visible, to: rep)
        guard let image = rep.cgImage else {
            window.close()
            throw SnapshotError.renderFailed("\(name): cacheDisplay produced no image")
        }
        let capture = try writePNG(image, named: name)
        window.close()
        runLoopTurn(0.1)
        return (capture, size)
    }

    /// Every segmented control in the sheet's view tree: the tab strip is one of
    /// these, and a strip that is not laid out shows up as a zero-size frame.
    private func segmentedControls(in view: NSView?) -> [NSView] {
        guard let view else { return [] }
        var found: [NSView] = []
        if String(describing: type(of: view)).contains("SegmentedControl") { found.append(view) }
        for subview in view.subviews {
            found.append(contentsOf: segmentedControls(in: subview))
        }
        return found
    }

    /// The AppKit views behind the SwiftUI sheet, with frames in the sheet's
    /// content coordinates: the tab strip is a real AppKit view, and this shows
    /// how much room it actually got.
    private func viewTree(_ view: NSView, depth: Int = 0, into lines: inout [String]) {
        guard depth < 8, lines.count < 120 else { return }
        let frame = view.convert(view.bounds, to: view.window?.contentView)
        let visible = view.window?.contentView.map { $0.bounds.intersection(frame) } ?? frame
        lines.append(String(repeating: "  ", count: depth)
                     + "\(type(of: view)) frame=\(frame) visible=\(visible)")
        for subview in view.subviews {
            viewTree(subview, depth: depth + 1, into: &lines)
        }
    }

    /// Scrolls every scroll view in the tree to the bottom; returns how many.
    @discardableResult
    private func scrollEveryScrollViewToBottom(in view: NSView) -> Int {
        var count = 0
        if let scrollView = view as? NSScrollView {
            let clip = scrollView.contentView
            let bottom = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: bottom))
            scrollView.reflectScrolledClipView(clip)
            count += 1
        }
        for subview in view.subviews {
            count += scrollEveryScrollViewToBottom(in: subview)
        }
        return count
    }

    /// The scroll view inside a SwiftUI `ScrollView`, for scrolling it in a test.
    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }

    // MARK: - The sheet as AppKit presents it

    /// Presents the real sheet on a parent window of `parentSize` — exactly how
    /// `ContentView` presents it — and captures the pixels inside the sheet's
    /// content area. `cacheDisplay` draws the view hierarchy rather than the
    /// screen, so no screen-recording permission is involved.
    private func capturePresentedSheet(tabIndex: Int, parentSize: CGSize, named name: String,
                                       host: AnyView? = nil,
                                       scrollSheetToBottom: Bool = false)
    throws -> (image: CGImage, sheetSize: CGSize, sheetBounds: CGRect,
               strips: [(className: String, frame: CGRect)],
               scroll: (document: CGFloat, clip: CGFloat)) {
        // Mirrors how OpenSuperWhisperApp/AppDelegate configure the main window:
        // hidden title bar, width pinned to 450, height clamped to 400…900.
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: 60, y: 60), size: parentSize),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 450, height: 400)
        window.maxSize = NSSize(width: 450, height: 900)
        window.delegate = pinnedWidthDelegate
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: host ?? AnyView(SettingsSheetHost(tabIndex: tabIndex)))
        hosting.sizingOptions = []
        window.contentView = hosting
        window.setContentSize(parentSize)
        window.orderFrontRegardless()

        var sheet: NSWindow?
        let deadline = Date().addingTimeInterval(6)
        while sheet == nil, Date() < deadline {
            runLoopTurn(0.05)
            sheet = window.attachedSheet
        }
        guard let sheet else {
            window.close()
            throw SnapshotError.renderFailed("\(name): the sheet never appeared on a "
                                             + "\(Int(parentSize.width))x\(Int(parentSize.height)) parent window")
        }
        // Let the presentation animation settle before measuring.
        runLoopTurn(0.8)

        let contentSize = sheet.contentRect(forFrameRect: sheet.frame).size
        print("[snapshot] \(name): parent window \(window.frame) content \(window.contentRect(forFrameRect: window.frame))\n"
              + "[snapshot]     sheet window \(sheet.frame), content area \(contentSize), hosting \(hosting.frame.size)")

        let sheetView = sheet.contentView
        let strips = segmentedControls(in: sheetView).map { control in
            (className: String(describing: type(of: control)),
             frame: control.convert(control.bounds, to: sheetView))
        }
        let sheetBounds = sheetView?.bounds ?? .zero
        let scroller = sheetView.flatMap { firstScrollView(in: $0) }
        let scroll = (document: scroller?.documentView?.frame.height ?? 0,
                      clip: scroller?.contentView.bounds.height ?? 0)

        if let sheetView {
            var lines: [String] = []
            viewTree(sheetView, into: &lines)
            print("[snapshot] \(name): sheet view tree\n" + lines.joined(separator: "\n"))
        }

        // Capture the sheet's own content view: the sheet lives in its own window,
        // so the parent's hosting view knows nothing about it. The capture is
        // clipped to the window's content area, which is what the user can see.
        guard let sheetView else {
            window.endSheet(sheet)
            sheet.close()
            window.close()
            throw SnapshotError.renderFailed("\(name): the sheet has no content view")
        }
        let visible = NSRect(origin: .zero,
                             size: CGSize(width: min(contentSize.width, sheetView.bounds.width),
                                          height: min(contentSize.height, sheetView.bounds.height)))
        guard let rep = sheetView.bitmapImageRepForCachingDisplay(in: visible) else {
            window.endSheet(sheet)
            sheet.close()
            window.close()
            throw SnapshotError.renderFailed("\(name): no bitmap for the sheet")
        }
        sheetView.cacheDisplay(in: visible, to: rep)
        guard let image = rep.cgImage else {
            window.endSheet(sheet)
            sheet.close()
            window.close()
            throw SnapshotError.renderFailed("\(name): cacheDisplay produced no image")
        }
        let capture = try writePNG(image, named: name)

        // The window the sheet hangs on: with the permission notices merged into
        // the tip, that is part of what the captain sees around the sheet.
        if host != nil {
            let windowRect = hosting.bounds
            if let windowRep = hosting.bitmapImageRepForCachingDisplay(in: windowRect) {
                hosting.cacheDisplay(in: windowRect, to: windowRep)
                if let windowImage = windowRep.cgImage {
                    try writePNG(windowImage, named: "\(name)-window")
                }
            }
        }

        // The cards below the fold are only reachable if the sheet's scroll view
        // scrolls: capture the bottom of the tab as well.
        if scrollSheetToBottom {
            let scrolled = scrollEveryScrollViewToBottom(in: sheetView)
            runLoopTurn(0.4)
            print("[snapshot] \(name): scrolled \(scrolled) scroll view(s) to the bottom")
            let bottomRep = sheetView.bitmapImageRepForCachingDisplay(in: visible)
            if let bottomRep {
                sheetView.cacheDisplay(in: visible, to: bottomRep)
                if let bottomImage = bottomRep.cgImage {
                    try writePNG(bottomImage, named: "\(name)-scrolled")
                }
            }
        }

        window.endSheet(sheet)
        sheet.close()
        window.close()
        runLoopTurn(0.2)

        return (capture, contentSize, sheetBounds, strips, scroll)
    }

    /// `AppDelegate.windowWillResize` pins the width to 450; the harness window does too.
    private final class PinnedWidthDelegate: NSObject, NSWindowDelegate {
        func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
            NSSize(width: 450, height: frameSize.height)
        }
    }

    private lazy var pinnedWidthDelegate = PinnedWidthDelegate()

    private func runLoopTurn(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: - Card band analysis

    private struct Band {
        let start: Int
        let end: Int
        var height: Int { end - start + 1 }
    }

    /// A column 20 pt in from the left: past the 16 pt page padding, inside the
    /// card chrome and left of any card content. At scale 2 that is pixel 40.
    private static let probeColumn = 40

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

    private func color(_ pixels: [UInt8], _ image: CGImage, _ x: Int, _ y: Int) -> (Int, Int, Int) {
        let offset = (y * image.width + x) * 4
        return (Int(pixels[offset]), Int(pixels[offset + 1]), Int(pixels[offset + 2]))
    }

    private func distance(_ a: (Int, Int, Int), _ b: (Int, Int, Int)) -> Int {
        abs(a.0 - b.0) + abs(a.1 - b.1) + abs(a.2 - b.2)
    }

    /// How many rows/columns of pure page background the image keeps at each edge.
    /// A zero on a side means something is drawn through that edge, i.e. the view
    /// is wider or taller than the sheet that is showing it.
    private func edgeMargins(in image: CGImage, inside rect: CGRect? = nil) throws
    -> (left: Int, right: Int, top: Int, bottom: Int) {
        let pixels = try bitmap(image)
        let area = rect ?? CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let background = color(pixels, image, Int(area.minX) + 8, Int(area.minY) + 8)
        func isBackground(_ x: Int, _ y: Int) -> Bool {
            distance(color(pixels, image, x, y), background) <= 3
        }

        var left = 0
        while CGFloat(left) < area.width, (Int(area.minY)..<Int(area.maxY)).allSatisfy({ isBackground(Int(area.minX) + left, $0) }) {
            left += 1
        }
        var right = 0
        while CGFloat(right) < area.width, (Int(area.minY)..<Int(area.maxY)).allSatisfy({ isBackground(Int(area.maxX) - 1 - right, $0) }) {
            right += 1
        }
        var top = 0
        while CGFloat(top) < area.height, (Int(area.minX)..<Int(area.maxX)).allSatisfy({ isBackground($0, Int(area.minY) + top) }) {
            top += 1
        }
        var bottom = 0
        while CGFloat(bottom) < area.height, (Int(area.minX)..<Int(area.maxX)).allSatisfy({ isBackground($0, Int(area.maxY) - 1 - bottom) }) {
            bottom += 1
        }
        return (left, right, top, bottom)
    }

    /// Splits the image into runs of rows whose probe pixel differs from the page
    /// background — one run per card. Two cards drawn over each other show up as
    /// a single run, and cards that touch leave no gap between runs.
    private func cardBands(in image: CGImage) throws
    -> (bands: [Band], gaps: [Int], background: (Int, Int, Int), pixels: [UInt8]) {
        let pixels = try bitmap(image)
        let x = min(Self.probeColumn, image.width - 1)
        // The page background is sampled from the tab's own left page padding,
        // and at three heights. Row 8 at the probe column — what this used to
        // read — is page only in a capture of the *top* of a tab: in one scrolled
        // to the bottom it is inside a card, so the "background" comes back as the
        // card colour and then every gap in the image reads as a card and every
        // card as a gap. That is how a correct tab was reported as cards drawn
        // into each other ("gaps [1, 1]", background (30, 30, 30) — the card
        // colour) once a longer caption moved the scroll geometry. The padding
        // column is page for the whole height of a tab capture at any scroll
        // offset; the three heights are there so a capture whose padding column is
        // not page still falls back to the probe column's row 8.
        let paddingColumn = max(0, Int(Self.pagePadding) / 4)
        let paddingSamples = [min(8, image.height - 1), image.height / 2, max(0, image.height - 8)]
            .map { color(pixels, image, paddingColumn, $0) }
        let background = paddingSamples.dropFirst().allSatisfy { distance($0, paddingSamples[0]) <= 2 }
            ? paddingSamples[0]
            : color(pixels, image, x, min(8, image.height - 1))
        func isBackground(_ y: Int) -> Bool {
            distance(color(pixels, image, x, y), background) <= 3
        }

        var bands: [Band] = []
        var gaps: [Int] = []
        var start: Int?
        var gapStart: Int?
        for y in 0..<image.height {
            if isBackground(y) {
                if let s = start {
                    bands.append(Band(start: s, end: y - 1))
                    start = nil
                    gapStart = y
                }
            } else {
                if let g = gapStart {
                    gaps.append(y - g)
                    gapStart = nil
                }
                if start == nil { start = y }
            }
        }
        if let s = start { bands.append(Band(start: s, end: image.height - 1)) }

        return (bands.filter { $0.height > 6 }, gaps, background, pixels)
    }

    // MARK: - Tests

    /// The size sweep the brief asks for: every tab body hosted at the sheet's
    /// current content size and at 520x560 and 520x900.
    func testSettingsTabsLayOutAsSeparateCards() throws {
        print("[snapshot] NSScreen.main.visibleFrame = "
              + (NSScreen.main.map { "\($0.visibleFrame)" } ?? "nil"))
        print("[snapshot] sheet frame = \(Self.sheetSize), tab viewport upper bound = \(Self.currentTabViewport)")

        let sheet = SettingsView()
        for (sizeName, size) in Self.viewports {
            let suffix = "\(sizeName)-\(Int(size.width))x\(Int(size.height))"
            for (tab, _) in Self.tabs {
                let capture = try captureHosted(Self.body(tab, of: sheet), size: size,
                                                named: "tab-\(tab)-\(suffix)")
                try assertCardsSeparated(in: capture.image, name: "tab-\(tab)-\(suffix)")
            }
        }
    }

    /// Every tab's cards have to lay out intact — nothing crushed, nothing
    /// running through an edge — whatever the switches are set to. The
    /// Tone & Clean-up card grows rows with the tone picker and the models, so
    /// the tab's height is not a constant this test may assume: the whole tab is
    /// drawn from the scroll view's document view, and the assertions are the
    /// shape of the stack rather than a card count for today's content.
    ///
    /// This is also where the tabs' contents are captured whole, so the PNGs
    /// show every section the Model, Shortcuts and Advanced tabs now carry.
    func testEveryTabLaysOutItsCardsWhateverTheSwitchesSay() throws {
        let savedTone = AppPreferences.shared.toneEnabled
        let savedCleanUp = AppPreferences.shared.cleanUpEnabled
        defer {
            AppPreferences.shared.toneEnabled = savedTone
            AppPreferences.shared.cleanUpEnabled = savedCleanUp
        }

        // The transcription tab, in both switch states, plus every other tab.
        let cases: [(tab: String, suffix: String, tone: Bool, cleanUp: Bool)] = [
            ("transcription", "transforms-off", false, false),
            ("transcription", "tone-only", true, false),
            ("transcription", "transforms-on", true, true),
            ("shortcuts", "default", savedTone, savedCleanUp),
            ("model", "default", savedTone, savedCleanUp),
            ("advanced", "default", savedTone, savedCleanUp),
        ]

        for state in cases {
            AppPreferences.shared.toneEnabled = state.tone
            AppPreferences.shared.cleanUpEnabled = state.cleanUp

            let name = "tab-\(state.tab)-content-\(state.suffix)"
            let capture = try captureHosted(Self.body(state.tab, of: SettingsView()),
                                            size: CGSize(width: 520, height: 600),
                                            named: name, fullContent: true)

            // The Model tab is one card with rows inside it rather than a stack
            // of separate cards, so the shape checked below does not describe it.
            // Its layout is covered by the three-size sweep in
            // testSettingsTabsLayOutAsSeparateCards; the capture above is for the
            // images.
            guard Self.stackShapedTabs.contains(state.tab) else { continue }

            let bands = try assertCardsSeparated(in: capture.image, name: name)

            // The page padding has to be there at both ends of the stack, which
            // it cannot be if a card is drawn through the top or bottom edge.
            let topPadding = bands.first?.start ?? -1
            let bottomPadding = capture.image.height - 1 - (bands.last?.end ?? -1)
            // The capture and its bands go into the message: a red run has to
            // say *what* it measured, or the next reader is left guessing.
            let shape = "\(capture.image.width)x\(capture.image.height) img, capture \(capture.size), "
                + "bands \(bands.map { "\($0.start)-\($0.end)" })"
            XCTAssertEqual(topPadding, Int(Self.pagePadding), accuracy: 2,
                           "\(name): the card stack starts \(topPadding) pt into the tab, "
                           + "expected the \(Int(Self.pagePadding)) pt page padding — \(shape)")
            XCTAssertEqual(bottomPadding, Int(Self.pagePadding), accuracy: 2,
                           "\(name): the card stack ends \(bottomPadding) pt before the end of the tab, "
                           + "expected the \(Int(Self.pagePadding)) pt page padding — \(shape)")

            // A settings tab with a handful of cards; the count is only here to
            // catch a stack that collapsed to one or two bands.
            XCTAssertGreaterThanOrEqual(bands.count, 3,
                                        "\(name): only \(bands.count) card bands are drawn")

            for band in bands {
                XCTAssertGreaterThanOrEqual(band.height, Int(Self.minimumCardHeightPoints),
                                            "\(name): a card at rows \(band.start)-\(band.end) is only "
                                            + "\(band.height) pt tall — its content is crushed")
            }
        }
    }

    /// The controls under the fold are reachable: scrolling the transcription tab
    /// to the bottom brings up the cards past the first screenful.
    func testTranscriptionTabScrollsToItsLastCard() throws {
        let size = CGSize(width: 518, height: 468)
        let top = try captureHosted(Self.body("transcription", of: SettingsView()), size: size,
                                    named: "tab-transcription-scroll-top")
        let bottom = try captureHosted(Self.body("transcription", of: SettingsView()), size: size,
                                       named: "tab-transcription-scroll-bottom", scrolledToBottom: true)

        let topBands = try assertCardsSeparated(in: top.image, name: "tab-transcription-scroll-top")
        let bottomBands = try assertCardsSeparated(in: bottom.image, name: "tab-transcription-scroll-bottom")
        XCTAssertNotEqual(topBands.map { $0.start }, bottomBands.map { $0.start },
                          "scrolling to the bottom did not move the cards; the rest of the tab is unreachable")
    }

    /// One card per contiguous run of non-background rows at the probe column,
    /// with page background in between. Cards drawn on top of each other merge
    /// into one run; cards that touch leave no gap.
    @discardableResult
    private func assertCardsSeparated(in image: CGImage, name: String,
                                      file: StaticString = #filePath, line: UInt = #line) throws -> [Band] {
        let (bands, gaps, background, _) = try cardBands(in: image)
        let summary = bands.map { "\($0.start)-\($0.end)" }.joined(separator: ", ")
        // Through `report`, not `print`: xcodebuild drops a test process's
        // stdout, so a run that fails here would leave no trace of *what* the
        // capture contained. With the variable unset this only prints.
        TestFixtures.report("[snapshot] \(name) \(image.width)x\(image.height): bg=\(background) bands=[\(summary)] gaps=\(gaps)")

        XCTAssertFalse(bands.isEmpty, "\(name): no card is drawn at all", file: file, line: line)
        XCTAssertTrue(gaps.allSatisfy { $0 >= Int(Self.minimumCardGapPoints) },
                      "\(name): cards are less than \(Self.minimumCardGapPoints) pt apart (gaps \(gaps)); "
                      + "cards drawn into each other leave no page background between them", file: file, line: line)
        return bands
    }

    /// The captain's case: the sheet AppKit presents on the app's main window,
    /// pinned to 450 pt wide and 400…900 pt tall.
    func testSettingsSheetIsNotClippedByItsParentWindow() throws {
        for (tab, index) in Self.tabs {
            for (sizeName, size) in Self.windowSizes {
                let name = "presented-\(tab)-\(sizeName)"
                let capture = try capturePresentedSheet(tabIndex: index, parentSize: size, named: name)
                let image = capture.image
                let scale = CGFloat(image.width) / capture.sheetSize.width
                let minimum = Int(Self.minimumPagePaddingPoints * scale)

                let margins = try edgeMargins(in: image)
                print("[snapshot] \(name) \(image.width)x\(image.height) scale \(scale): "
                      + "page background left=\(margins.left) right=\(margins.right) "
                      + "top=\(margins.top) bottom=\(margins.bottom)")

                XCTAssertGreaterThanOrEqual(margins.left, minimum,
                                            "\(name): the sheet is cut off at its left edge")
                XCTAssertGreaterThanOrEqual(margins.right, minimum,
                                            "\(name): the sheet is cut off at its right edge — whatever sits "
                                            + "on the right of a card, every switch and every picker, is off-panel")
                XCTAssertGreaterThanOrEqual(margins.top, minimum,
                                            "\(name): the sheet is cut off at its top edge — the tab strip "
                                            + "lives there, so the tabs are half visible")
                // Card boundaries are invisible against macOS's own content
                // background inside a sheet, so the pixel check that cards stay
                // separate runs on the tab bodies (testSettingsTabsLayOut...).
                // What matters here is that the rest of the tab is reachable: the
                // scroll view has to hold more than it shows.
                if tab == "transcription" {
                    XCTAssertGreaterThan(capture.scroll.document, capture.scroll.clip + 20,
                                         "\(name): the tab's scroll view holds \(capture.scroll.document) pt "
                                         + "in a \(capture.scroll.clip) pt viewport — the cards below the fold, "
                                         + "the tone controls among them, have nowhere to scroll from")
                }
            }
        }
    }

    /// The tone card sits below the fold of the sheet. It has to come up when the
    /// sheet is scrolled; this captures the sheet before and after scrolling.
    func testTheToneCardComesUpWhenTheSheetIsScrolled() throws {
        let size = CGSize(width: 450, height: 650)
        let capture = try capturePresentedSheet(tabIndex: 2, parentSize: size,
                                                named: "presented-transcription-450x650-scrollcheck",
                                                scrollSheetToBottom: true)
        let scrolledURL = Self.outputDirectory.appendingPathComponent("presented-transcription-450x650-scrollcheck-scrolled.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: scrolledURL.path),
                      "the sheet did not produce a scrolled capture")
        _ = capture
    }

    /// The sheet as `ContentView` presents it, through the same
    /// `.sheet(isPresented: $isSettingsPresented)` the app uses, so the real
    /// presenter — including the permission check that switches its content —
    /// is in the loop.
    func testSheetPresentedFromContentView() throws {
        let capture = try capturePresentedSheet(
            tabIndex: 2,
            parentSize: CGSize(width: 450, height: 650),
            named: "presented-from-contentview-transcription",
            host: AnyView(AppMainWindowContent()))
        print("[snapshot] presented-from-contentview-transcription sheet \(capture.sheetSize)")
    }

    /// The captain's blocker: on this macOS a `TabView`'s own tab strip gets no
    /// size at all inside a sheet, so the four tab labels are drawn on top of
    /// each other and nothing can be clicked. Whatever draws the strip has to
    /// occupy a real, visible rectangle.
    func testTheTabStripIsUsableInThePresentedSheet() throws {
        for (tab, index) in Self.tabs {
            let name = "presented-\(tab)-450x650"
            _ = try capturePresentedSheet(tabIndex: index, parentSize: CGSize(width: 450, height: 650),
                                          named: name)
        }

        let capture = try capturePresentedSheet(tabIndex: 2, parentSize: CGSize(width: 450, height: 650),
                                                named: "presented-transcription-tabstrip")
        XCTAssertFalse(capture.strips.isEmpty,
                       "no tab strip control was found in the sheet at all")

        let strip = capture.strips[0].frame
        print("[snapshot] presented-transcription-tabstrip: strip frames "
              + capture.strips.map { "\($0.className) \($0.frame)" }.joined(separator: ", "))
        XCTAssertGreaterThanOrEqual(strip.width, 120,
                                    "the tab strip is \(strip.width) pt wide — the four tab labels are "
                                    + "drawn on top of each other, which is the unreadable mess the captain "
                                    + "reported")
        XCTAssertGreaterThanOrEqual(strip.height, 12,
                                    "the tab strip is \(strip.height) pt tall — its labels are crushed, "
                                    + "and a control that size cannot be clicked")
        XCTAssertTrue(capture.sheetBounds.contains(strip),
                      "the tab strip at \(strip) is outside the sheet's visible area \(capture.sheetBounds)")
    }

    /// 4 pt of page background: the least padding a card can keep at an edge and
    /// still look inset. Anything less means the content is running through it.
    private static let minimumPagePaddingPoints: CGFloat = 4

    /// The tabs whose content is a stack of separate cards. The Model tab is a
    /// single card holding rows, so the stack shape does not apply to it.
    private static let stackShapedTabs: Set<String> = ["transcription", "shortcuts", "advanced"]

    /// The page padding the tab bodies put around their card stack.
    private static let pagePadding: CGFloat = 16

    /// A card holds a headline and at least one row of content; anything much
    /// shorter than this has been compressed by its neighbours.
    private static let minimumCardHeightPoints: CGFloat = 40

    /// 4 pt: anything less and the rounded card outlines touch.
    private static let minimumCardGapPoints: CGFloat = 4

    private static func tabBodies(of sheet: SettingsView) -> [(String, AnyView)] {
        [("shortcuts", AnyView(sheet.shortcutSettings)),
         ("model", AnyView(sheet.modelSettings)),
         ("transcription", AnyView(sheet.transcriptionSettings)),
         ("advanced", AnyView(sheet.advancedSettings))]
    }

    /// The Advanced tab reads the app state (it can reset the welcome flow), so
    /// every rendered view is given one, as the app's window does.
    private static func body(_ name: String, of sheet: SettingsView) -> AnyView {
        AnyView(tabBodies(of: sheet).first { $0.0 == name }!.1.environmentObject(AppState()))
    }
}

/// Hosts `SettingsView` in a window so SwiftUI presents it as a real sheet.
private struct SettingsSheetHost: View {
    let tabIndex: Int

    var body: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .sheet(isPresented: .constant(true)) {
                SettingsView(selectedTab: tabIndex)
                    .environmentObject(AppState())
            }
    }
}

/// `ContentView` in a window shaped like the app's main window, presenting the
/// Settings sheet as soon as it appears — the same path the Settings… menu item
/// (⌘,) takes, without needing input automation.
private struct AppMainWindowContent: View {
    @StateObject private var appState = AppState()

    var body: some View {
        ContentView()
            .environmentObject(appState)
            .frame(width: 450)
            .frame(minHeight: 400, maxHeight: 900)
            .onAppear {
                NotificationCenter.default.post(name: .openSettings, object: nil)
            }
    }
}
