import Foundation

/// Collapses transcriptions into short single-line labels for menu items.
enum TranscriptionMenuFormatter {

    /// Longest label body shown in the status bar menu, before the ellipsis.
    static let maxTitleLength = 50

    /// Renders a transcription as a single short line suitable for an
    /// `NSMenuItem` title.
    ///
    /// Menu items render embedded newlines poorly and dictated text is often
    /// several sentences, so every run of whitespace collapses to one space and
    /// anything over `maxLength` is cut back to a word boundary and suffixed
    /// with an ellipsis.
    static func menuTitle(for transcription: String, maxLength: Int = maxTitleLength) -> String {
        guard maxLength > 0 else { return "" }

        let collapsed = transcription
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard collapsed.count > maxLength else { return collapsed }

        let cutoff = collapsed.index(collapsed.startIndex, offsetBy: maxLength)
        let head = collapsed[..<cutoff]

        // Prefer cutting at the last space so a word is not sliced in half.
        // A single word longer than the limit has no space to fall back to and
        // is hard-cut instead.
        if let lastSpace = head.lastIndex(of: " ") {
            return collapsed[..<lastSpace] + "…"
        }
        return head + "…"
    }
}
