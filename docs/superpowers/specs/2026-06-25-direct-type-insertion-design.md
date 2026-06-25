# Direct keyboard insertion (replace clipboard paste)

**Date:** 2026-06-25
**Status:** approved
**Fixes:** upstream issue [#153](https://github.com/Starmel/OpenSuperWhisper/issues/153) — copied text pasted in place of the transcription.

## Problem

After a transcription completes, the app inserts text by writing it to
`NSPasteboard`, simulating `Cmd+V`, then (in one configuration) restoring the
previous clipboard after a blind delay. `CGEvent.post()` is asynchronous: the
target app may consume the synthetic `Cmd+V` *after* the clipboard has already
been restored, so it pastes the **old** clipboard content instead of the
transcription. The transcription still shows correctly inside the app. This is
exactly the symptom reported in #153, and it is most reproducible in slow
targets like browser/Electron apps (e.g. ChatGPT).

Relevant current code:
- `ClipboardUtil.insertText()` — `Utils/ClipboardUtil.swift:23-43` (the
  save → set → paste → `Thread.sleep` → restore path; the race lives here).
- `ClipboardUtil.insertTextAndKeepInClipboard()` — `:15-20` (no restore, but
  still no `changeCount` guard).
- `IndicatorViewModel.insertText()` — `Indicator/IndicatorWindow.swift:256-278`
  (chooses the path based on `autoPasteTranscription` / `autoCopyToClipboard`).

## Decision

Stop inserting via the clipboard. Insert the transcription by **synthesizing
keyboard input** (`CGEvent.keyboardSetUnicodeString`), which never touches the
pasteboard, so the race and the clipboard restore both disappear. This becomes
the default and only insertion method (no method picker).

## Behavior

- **Auto-insert** (existing `autoPasteTranscription` toggle, default on):
  when enabled, the transcription is typed into the focused app via synthetic
  keyboard events. The toggle keeps its meaning ("insert automatically"); only
  the underlying mechanism changes.
- **Copy to Clipboard** (existing `autoCopyToClipboard` toggle, default on):
  stays, now **fully independent** of insertion. When on, the transcription is
  *also* placed on the clipboard (so the user can `⌘V` it elsewhere). When off,
  the clipboard is never touched.
- **Notify When No Paste Target** (`notifyWhenNoPasteTarget`): unchanged. When
  no editable field is focused we still surface the "copied — press ⌘V" notice;
  in that case we put the text on the clipboard so the notice is actionable,
  exactly as today.

Resulting matrix (replaces the old paste/restore matrix):

| autoPaste | autoCopy | target editable? | Action |
|---|---|---|---|
| on  | on  | yes | type into field **and** copy to clipboard |
| on  | off | yes | type into field only (clipboard untouched) |
| on  | any | no (and notify on) | copy to clipboard + show "press ⌘V" notice (no typing into a non-target) |
| off | on  | — | copy to clipboard only |
| off | off | — | nothing |

## Mechanism

New `ClipboardUtil` (or a new `TextInserter`) typing function:

1. **Unicode events, layout-independent.** Build keyboard events with
   `CGEvent(keyboardEventSource:virtualKey:keyDown:)` using `virtualKey: 0` and
   attach the text with `keyboardSetUnicodeString`. This bypasses keycode
   resolution entirely, so the `isQwertyCommandLayout` / `findKeycodeForCharacter`
   Cmd+V machinery is no longer on the insertion path.
2. **Chunking.** Send the string in small chunks (e.g. ~20 UTF-16 units per
   event) rather than one giant event, to stay within what apps reliably accept
   and to avoid dropped input. Each chunk is one keyDown+keyUp pair.
3. **Newlines stay literal.** Newlines are sent as the literal `\n` character
   inside the unicode string, **not** as a Return keycode. A literal newline
   inserts a line break as text; it does not trigger the "Enter submits" action
   in chat inputs like ChatGPT. This is the critical correctness point for #153's
   own use case.
4. **No inherited modifiers.** Force `flags = []` on every synthetic event so a
   still-held hotkey modifier cannot combine with the typed characters.
5. **No main-thread sleep.** The old `Thread.sleep(adaptiveRestoreDelay())` is
   gone; nothing in the insertion path blocks the main thread.

## Removed

- `ClipboardUtil.insertText()` (restore path) — deleted.
- `adaptiveRestoreDelay()` — deleted (only used by the restore path).
- `saveCurrentPasteboardContents()` / `restorePasteboardContents()` — deleted
  (only used by the restore path).
- `insertTextUsingPasteboard()` deprecated alias — deleted.

Kept: `copyToClipboard()` (used by the independent clipboard option), and the
input-source helpers used elsewhere/by tests.

## Edge cases

- **Secure input fields** (password fields): synthetic input is rejected, same
  as paste was. Acceptable, unchanged.
- **Apps that reject synthetic unicode keystrokes:** rare. There is no reliable
  signal to detect insertion failure, so no automatic paste fallback is
  attempted (it could not be triggered correctly anyway). The clipboard-copy
  option remains the manual escape hatch.
- **Empty / no-speech text:** already handled upstream of insertion in
  `startDecoding()`; the inserter is never called for it.

## Testing

- **Unit (pure logic):** chunking of a string into ≤N-unit pieces preserves the
  exact concatenation (incl. multi-byte/emoji and embedded newlines); newline
  normalization keeps `\n` as a text character. No real event posting needed.
- **Manual:** transcribe into ChatGPT (the #153 target) and confirm the
  transcription — not the prior clipboard — lands, and that a transcription
  containing a line break does **not** submit the chat. Verify a multi-line
  field (e.g. Notes, a code editor) receives the line breaks as text.

## Out of scope

The intermittent **recording-start freeze** (synchronous Accessibility calls on
the main thread in `ShortcutManager.handleKeyDown` / `FocusUtils`, with no AX
messaging timeout, which also stalls the main-runloop event tap) is a separate
bug. It will be fixed in the same branch as an independent change, not in this
spec.
