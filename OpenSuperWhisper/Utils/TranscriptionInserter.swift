import Foundation

/// How a transcription should reach the user's cursor and clipboard.
enum InsertionAction: Equatable {
    /// Paste, and leave the transcription on the clipboard.
    case pasteKeepingClipboard
    /// Paste, and restore the user's previous clipboard afterwards.
    case pasteRestoringClipboard
    /// Copy to the clipboard without pasting.
    case copyOnly
    /// Do nothing. Named `doNothing` rather than `none` so it can never be
    /// confused with `Optional.none` at a call site.
    case doNothing
}

/// The single entry point for putting a transcription in front of the user.
/// Both the record-time path and the paste-last-transcription hotkey route
/// through here so their behavior can never drift apart.
@MainActor
enum TranscriptionInserter {

    /// Pure routing rule.
    ///
    /// `forcePaste` is used by the explicit paste-last-transcription hotkey:
    /// an on-demand request to paste should paste even when the user has
    /// turned automatic pasting off, because pasting is the entire point of
    /// pressing it.
    ///
    /// `nonisolated` so plain `XCTestCase` classes can exercise it directly,
    /// matching `RecordingStore.retentionCutoffDate`.
    nonisolated static func action(autoPaste: Bool, autoCopy: Bool, forcePaste: Bool) -> InsertionAction {
        if autoPaste || forcePaste {
            return autoCopy ? .pasteKeepingClipboard : .pasteRestoringClipboard
        }
        return autoCopy ? .copyOnly : .doNothing
    }

    /// Appends a trailing space after terminal punctuation when the user has
    /// that preference enabled.
    static func applyPostProcessing(_ text: String) -> String {
        guard AppPreferences.shared.addSpaceAfterSentence,
              let lastChar = text.last,
              lastChar.isPunctuation else {
            return text
        }
        return text + " "
    }

    static func insert(_ text: String, forcePaste: Bool = false) {
        guard !text.isEmpty else { return }

        let finalText = applyPostProcessing(text)
        let prefs = AppPreferences.shared

        switch action(autoPaste: prefs.autoPasteTranscription,
                      autoCopy: prefs.autoCopyToClipboard,
                      forcePaste: forcePaste) {
        case .pasteKeepingClipboard:
            ClipboardUtil.insertTextAndKeepInClipboard(finalText)
        case .pasteRestoringClipboard:
            ClipboardUtil.insertText(finalText)
        case .copyOnly:
            ClipboardUtil.copyToClipboard(finalText)
        case .doNothing:
            break
        }
    }
}
