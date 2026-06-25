# Direct keyboard insertion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Insert the transcription into the focused app by synthesizing keyboard input instead of clipboard + Cmd+V, fixing the clipboard race in issue #153.

**Architecture:** A new `TextInserter` enum sends the text as Unicode keyboard events (`CGEvent.keyboardSetUnicodeString`), layout-independent and never touching the pasteboard. `IndicatorViewModel.insertText` is rewired to type via `TextInserter` while the `autoCopyToClipboard` toggle becomes an independent clipboard stash. All the obsolete Cmd+V/clipboard-restore machinery (and the layout tests that exercised it) is deleted.

**Tech Stack:** Swift, AppKit, CoreGraphics (`CGEvent`), XCTest. macOS app built with Xcode 16 (file-system-synchronized project — new `.swift` files under the source folders are auto-included, no `.pbxproj` editing needed).

## Global Constraints

- New source files go under `OpenSuperWhisper/` (auto-included by the synchronized project group); test files under `OpenSuperWhisperTests/`.
- Run a single test class: `xcodebuild test -scheme OpenSuperWhisper -destination 'platform=macOS' -only-testing:OpenSuperWhisperTests/<ClassName>`
- Run the whole test target: `xcodebuild test -scheme OpenSuperWhisper -destination 'platform=macOS' -only-testing:OpenSuperWhisperTests`
- Follow existing test style: `import XCTest` + `@testable import OpenSuperWhisper`, pure-logic assertions (real event posting is verified manually, never in unit tests).
- Newlines are always sent as the literal `\n` character inside the Unicode string — never as a Return keycode — so a transcription with a line break never submits a chat input.
- Clipboard is never used as the insertion mechanism; it is only an optional independent stash gated by `autoCopyToClipboard`.

---

### Task 1: `TextInserter.chunks` — pure UTF-16 chunking

Splits text into UTF-16 unit groups of a bounded size without ever splitting a surrogate pair (so emoji survive). This is the only unit-testable part of the inserter.

**Files:**
- Create: `OpenSuperWhisper/Utils/TextInserter.swift`
- Test: `OpenSuperWhisperTests/TextInserterTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum TextInserter { static func chunks(of text: String, maxUnits: Int = 20) -> [[UniChar]] }` — returns the text's UTF-16 units grouped into arrays each ≤ `maxUnits` units, except a group may be one longer when extended to keep a surrogate pair intact. Concatenating every group's units back into a string reproduces `text` exactly. Empty text returns `[]`.

- [ ] **Step 1: Write the failing test**

Create `OpenSuperWhisperTests/TextInserterTests.swift`:

```swift
import XCTest
@testable import OpenSuperWhisper

final class TextInserterTests: XCTestCase {

    /// Decode a list of UTF-16 chunks back into a single String.
    private func reconstruct(_ chunks: [[UniChar]]) -> String {
        chunks.map { String(utf16CodeUnits: $0, count: $0.count) }.joined()
    }

    func testEmptyStringProducesNoChunks() {
        XCTAssertEqual(TextInserter.chunks(of: "").count, 0)
    }

    func testShortStringIsOneChunk() {
        let chunks = TextInserter.chunks(of: "hello", maxUnits: 20)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(reconstruct(chunks), "hello")
    }

    func testReconstructionMatchesOriginal() {
        for text in ["hello world", "café crème", "line1\nline2\nline3", "a👍b🎉c"] {
            let chunks = TextInserter.chunks(of: text, maxUnits: 3)
            XCTAssertEqual(reconstruct(chunks), text, "round-trip failed for \(text)")
        }
    }

    func testNoChunkExceedsMaxForPlainText() {
        let chunks = TextInserter.chunks(of: String(repeating: "x", count: 50), maxUnits: 20)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 20 })
        XCTAssertEqual(chunks.count, 3) // 20 + 20 + 10
    }

    func testSurrogatePairIsNeverSplit() {
        // "a👍b": utf16 = [a, high, low, b]. With maxUnits 2 the boundary would
        // fall mid-emoji; the chunker must keep the pair together.
        let chunks = TextInserter.chunks(of: "a👍b", maxUnits: 2)
        XCTAssertEqual(reconstruct(chunks), "a👍b")
        for chunk in chunks {
            if let last = chunk.last {
                XCTAssertFalse((0xD800...0xDBFF).contains(last),
                               "chunk must not end on an unpaired high surrogate")
            }
        }
    }

    func testNewlineIsPreservedAsAUnit() {
        let chunks = TextInserter.chunks(of: "a\nb", maxUnits: 20)
        XCTAssertEqual(reconstruct(chunks), "a\nb")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme OpenSuperWhisper -destination 'platform=macOS' -only-testing:OpenSuperWhisperTests/TextInserterTests`
Expected: FAIL to build / "cannot find 'TextInserter' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `OpenSuperWhisper/Utils/TextInserter.swift`:

```swift
import CoreGraphics
import Foundation

/// Inserts text into the frontmost app by synthesizing Unicode keyboard input.
/// Never touches the pasteboard, so there is no clipboard race or restore.
enum TextInserter {

    /// Splits `text` into UTF-16 unit groups of at most `maxUnits` units each,
    /// never splitting a surrogate pair (a group may be one unit longer when it
    /// has to absorb a trailing low surrogate). Concatenating the groups
    /// reproduces `text` exactly.
    static func chunks(of text: String, maxUnits: Int = 20) -> [[UniChar]] {
        let units = Array(text.utf16)
        guard !units.isEmpty else { return [] }

        var result: [[UniChar]] = []
        var start = 0
        while start < units.count {
            var end = min(start + maxUnits, units.count)
            // A high surrogate must keep its following low surrogate in the same
            // chunk, or the emoji is torn in half.
            if end < units.count, (0xD800...0xDBFF).contains(units[end - 1]) {
                end += 1
            }
            result.append(Array(units[start..<end]))
            start = end
        }
        return result
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme OpenSuperWhisper -destination 'platform=macOS' -only-testing:OpenSuperWhisperTests/TextInserterTests`
Expected: PASS (all 6 tests).

- [ ] **Step 5: Commit**

```bash
git add OpenSuperWhisper/Utils/TextInserter.swift OpenSuperWhisperTests/TextInserterTests.swift
git commit -m "feat: add TextInserter.chunks UTF-16 chunking (surrogate-safe)"
```

---

### Task 2: `TextInserter.type` — post the Unicode keyboard events

Posts the chunked text as synthetic keyboard events. Not unit-testable (it injects real system events); verified by the build plus manual checks.

**Files:**
- Modify: `OpenSuperWhisper/Utils/TextInserter.swift`

**Interfaces:**
- Consumes: `TextInserter.chunks(of:maxUnits:)` from Task 1.
- Produces: `static func type(_ text: String)` — types `text` into whatever app currently has keyboard focus, as Unicode key events with no modifier flags.

- [ ] **Step 1: Add the posting function**

Append inside the `TextInserter` enum in `OpenSuperWhisper/Utils/TextInserter.swift`:

```swift
    /// Types `text` into the focused app as Unicode keyboard events. Each chunk
    /// is sent as one key-down/key-up pair carrying the Unicode string; modifier
    /// flags are cleared so a still-held hotkey can't combine with the input.
    static func type(_ text: String) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }

        for chunk in chunks(of: text) {
            guard
                let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }

            var units = chunk
            keyDown.flags = []
            keyUp.flags = []
            keyDown.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            keyUp.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)

            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)
        }
    }
```

- [ ] **Step 2: Verify it builds**

Run: `xcodebuild build -scheme OpenSuperWhisper -destination 'platform=macOS'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Re-run the chunking tests (regression)**

Run: `xcodebuild test -scheme OpenSuperWhisper -destination 'platform=macOS' -only-testing:OpenSuperWhisperTests/TextInserterTests`
Expected: PASS (unchanged — Task 1 tests still green).

- [ ] **Step 4: Commit**

```bash
git add OpenSuperWhisper/Utils/TextInserter.swift
git commit -m "feat: TextInserter.type posts Unicode keyboard events (no clipboard)"
```

---

### Task 3: Rewire insertion to typing + independent clipboard

Replace the clipboard-paste branches in `IndicatorViewModel.insertText` with `TextInserter.type`, make `autoCopyToClipboard` an independent stash, and refresh the Settings help text so it matches the new mechanism.

**Files:**
- Modify: `OpenSuperWhisper/Indicator/IndicatorWindow.swift:256-278`
- Modify: `OpenSuperWhisper/Settings.swift:1526-1544` (help copy only)

**Interfaces:**
- Consumes: `TextInserter.type(_:)` (Task 2); `ClipboardUtil.copyToClipboard(_:)` (existing); `FocusUtils.focusedElementIsEditable()` (existing); `AppPreferences.shared.{autoPasteTranscription, autoCopyToClipboard, notifyWhenNoPasteTarget}` (existing).
- Produces: `IndicatorViewModel.insertText(_ text: String) -> Bool` keeps the same signature and return contract (returns `true` when there was no editable paste target, so the caller shows the "Copied — press ⌘V" notice).

- [ ] **Step 1: Replace the body of `insertText`**

In `OpenSuperWhisper/Indicator/IndicatorWindow.swift`, replace the current method (lines 255-278):

```swift
    @discardableResult
    func insertText(_ text: String) -> Bool {
        let finalText = Self.applyPostProcessing(text)
        let prefs = AppPreferences.shared

        if prefs.autoPasteTranscription {
            // Check the focus target BEFORE pasting (our own Cmd+V could change it).
            let targetMissing = prefs.notifyWhenNoPasteTarget
                && FocusUtils.focusedElementIsEditable() == false

            // Keep the text on the clipboard whenever we'll warn, so "press ⌘V" is
            // actionable even if "copy to clipboard" is turned off.
            if targetMissing || prefs.autoCopyToClipboard {
                ClipboardUtil.insertTextAndKeepInClipboard(finalText)
            } else {
                ClipboardUtil.insertText(finalText)
            }
            return targetMissing
        } else if prefs.autoCopyToClipboard {
            ClipboardUtil.copyToClipboard(finalText)
        }
        // If both are false, do nothing
        return false
    }
```

with:

```swift
    @discardableResult
    func insertText(_ text: String) -> Bool {
        let finalText = Self.applyPostProcessing(text)
        let prefs = AppPreferences.shared

        // Optional, independent clipboard stash (never the insertion mechanism).
        if prefs.autoCopyToClipboard {
            ClipboardUtil.copyToClipboard(finalText)
        }

        guard prefs.autoPasteTranscription else { return false }

        // Decide whether there is an editable target BEFORE inserting. Biased
        // toward "present": only `false` when we are confident there is none.
        let targetMissing = prefs.notifyWhenNoPasteTarget
            && FocusUtils.focusedElementIsEditable() == false

        if targetMissing {
            // No field to type into: make sure the text is on the clipboard so the
            // "press ⌘V" notice is actionable, then skip typing into a non-target.
            if !prefs.autoCopyToClipboard {
                ClipboardUtil.copyToClipboard(finalText)
            }
            return true
        }

        TextInserter.type(finalText)
        return false
    }
```

- [ ] **Step 2: Update the Settings help text**

In `OpenSuperWhisper/Settings.swift`, update the two captions (around lines 1526-1544) to describe the new behavior. Change:

```swift
                                Text("Copy to Clipboard")
                                    .font(.subheadline)
                                Text("Keep transcription in clipboard after recording")
```
to:
```swift
                                Text("Copy to Clipboard")
                                    .font(.subheadline)
                                Text("Also place the transcription on the clipboard")
```

and change:

```swift
                                Text("Auto-paste Transcription")
                                    .font(.subheadline)
                                Text("Automatically paste into the focused app")
```
to:
```swift
                                Text("Auto-paste Transcription")
                                    .font(.subheadline)
                                Text("Type the transcription into the focused app")
```

- [ ] **Step 3: Verify it builds**

Run: `xcodebuild build -scheme OpenSuperWhisper -destination 'platform=macOS'`
Expected: BUILD SUCCEEDED. (`ClipboardUtil.insertText` / `insertTextAndKeepInClipboard` are now unused by the app — still defined, so this compiles. They are removed in Task 4.)

- [ ] **Step 4: Manual verification (the #153 case)**

Build and run the app, then with default settings (both toggles on):
1. Put distinctive text on the clipboard (e.g. copy "OLDCLIPBOARD").
2. Dictate a phrase into a ChatGPT message box.
Expected: the **transcription** appears in the box (never "OLDCLIPBOARD"), and a transcription containing a line break does **not** submit the chat.
3. Dictate into a multi-line field (Notes / a code editor) with a phrase that includes a newline — the line break lands as text.

- [ ] **Step 5: Commit**

```bash
git add OpenSuperWhisper/Indicator/IndicatorWindow.swift OpenSuperWhisper/Settings.swift
git commit -m "feat: insert transcription via direct typing; clipboard copy now independent (#153)"
```

---

### Task 4: Delete the obsolete Cmd+V/clipboard-restore machinery and its tests

Remove the now-unused paste/layout code and the two test classes that exercised it. Layout detection is no longer needed because Unicode insertion is layout-independent.

**Files:**
- Modify: `OpenSuperWhisper/Utils/ClipboardUtil.swift`
- Modify: `OpenSuperWhisperTests/OpenSuperWhisperTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: a slimmed `ClipboardUtil` exposing only `copyToClipboard(_:)`.

- [ ] **Step 1: Delete the obsolete test classes**

In `OpenSuperWhisperTests/OpenSuperWhisperTests.swift`, delete two entire classes (they call the functions being removed):
- `final class ClipboardUtilKeyboardLayoutTests` (starts at line 169, ends just before `final class MicrophoneServiceContinuityTests` at line 286).
- `final class ClipboardUtilPasteIntegrationTests` (starts at line 409, ends just before `final class KeyboardLayoutProviderTests` at line 911).

Keep every other class — in particular `KeyboardLayoutProviderTests` (tests `KeyboardLayoutProvider`, an unrelated on-screen-keyboard helper) stays.

- [ ] **Step 2: Slim down `ClipboardUtil`**

Replace the entire contents of `OpenSuperWhisper/Utils/ClipboardUtil.swift` with:

```swift
import Cocoa

enum ClipboardUtil {
    /// Copies text to the clipboard. Used only as an optional independent stash;
    /// insertion into the focused app is done by `TextInserter`, not the clipboard.
    static func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(text, forType: .string)
    }
}
```

This removes: `insertText`, `insertTextAndKeepInClipboard`, `simulatePaste`, `sendCmdV`, `adaptiveRestoreDelay`, `isQwertyCommandLayout`, `findKeycodeForCharacter`, `saveCurrentPasteboardContents`, `restorePasteboardContents`, `insertTextUsingPasteboard`, and the input-source helpers `getCurrentInputSourceID` / `switchToInputSource` / `getAvailableInputSources` (only the deleted tests used them).

- [ ] **Step 3: Verify the whole test target builds and passes**

Run: `xcodebuild test -scheme OpenSuperWhisper -destination 'platform=macOS' -only-testing:OpenSuperWhisperTests`
Expected: BUILD SUCCEEDED and all remaining tests PASS (no references to the deleted symbols remain).

- [ ] **Step 4: Confirm no stale references remain**

Run: `grep -rn "insertTextAndKeepInClipboard\|ClipboardUtil.insertText\|isQwertyCommandLayout\|findKeycodeForCharacter\|switchToInputSource\|adaptiveRestoreDelay" --include="*.swift" .`
Expected: no output.

- [ ] **Step 5: Commit**

```bash
git add OpenSuperWhisper/Utils/ClipboardUtil.swift OpenSuperWhisperTests/OpenSuperWhisperTests.swift
git commit -m "refactor: remove obsolete Cmd+V paste + keyboard-layout machinery"
```

---

## Self-Review

**Spec coverage:**
- "Insert by synthesizing keyboard input (`keyboardSetUnicodeString`)" → Tasks 1–2.
- "Default & only insertion method, no picker" → Task 3 (no new setting added).
- "Auto-insert toggle keeps meaning" → Task 3 keeps `autoPasteTranscription` gating.
- "Copy to Clipboard independent" → Task 3 (clipboard stash gated solely by `autoCopyToClipboard`).
- "Notify When No Paste Target unchanged; stash + notice when no target" → Task 3 `targetMissing` branch.
- "Chunking ~20 units; surrogate-safe" → Task 1.
- "Newlines literal, no Return keycode" → Tasks 1–2 (never uses a Return keycode) + chunking test.
- "No inherited modifiers" → Task 2 (`flags = []`).
- "No main-thread sleep" → Task 4 removes `adaptiveRestoreDelay`/`Thread.sleep`.
- "Remove insertText/adaptiveRestoreDelay/save+restore/deprecated alias; keep copyToClipboard" → Task 4.
- "Secure fields / no auto fallback / empty text handled upstream" → no code needed; behavior preserved.
- "Unit tests for chunking + newline; manual ChatGPT verification" → Task 1 tests + Task 3 manual step.

**Placeholder scan:** none — every code step contains complete code.

**Type consistency:** `TextInserter.chunks(of:maxUnits:) -> [[UniChar]]` and `TextInserter.type(_:)` used consistently across Tasks 1–3; `ClipboardUtil.copyToClipboard(_:)` matches existing signature; `insertText(_:) -> Bool` signature unchanged.

**Out of scope (tracked separately):** the recording-start freeze (AX-on-main-thread). Not in this plan.
