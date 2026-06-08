import Foundation

/// A single custom-dictionary rule: whenever `original` is recognized in a
/// transcription it is rewritten to `replacement`. Useful for fixing proper
/// nouns, brand names and domain jargon that the speech models consistently
/// mis-transcribe (e.g. "git hub" -> "GitHub").
struct CustomDictionaryEntry: Codable, Identifiable, Equatable, Hashable {
    var id: UUID
    var original: String
    var replacement: String

    init(id: UUID = UUID(), original: String = "", replacement: String = "") {
        self.id = id
        self.original = original
        self.replacement = replacement
    }
}

enum CustomDictionary {

    /// Applies the user's dictionary replacements to a transcription.
    ///
    /// Matching is case-insensitive and constrained to word boundaries so that
    /// substrings inside larger words are left untouched (e.g. a rule for "cat"
    /// will not touch "category"). The replacement string is inserted verbatim,
    /// preserving the casing the user typed.
    static func apply(_ text: String, entries: [CustomDictionaryEntry]) -> String {
        guard !text.isEmpty, !entries.isEmpty else { return text }

        var result = text
        for entry in entries {
            let original = entry.original.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !original.isEmpty else { continue }

            let escaped = NSRegularExpression.escapedPattern(for: original)
            // Only add a \b assertion where the adjacent character of the search
            // term is itself a word character — otherwise the boundary never
            // matches for terms that start/end with punctuation (e.g. "C++").
            let leadingBoundary = isWordCharacter(original.first) ? "\\b" : ""
            let trailingBoundary = isWordCharacter(original.last) ? "\\b" : ""
            let pattern = leadingBoundary + escaped + trailingBoundary

            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }

            let range = NSRange(result.startIndex..., in: result)
            let template = NSRegularExpression.escapedTemplate(for: entry.replacement)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: template)
        }
        return result
    }

    /// Builds an initial-prompt fragment from the dictionary's replacement terms
    /// so a prompt-conditioned model (Whisper) is biased toward producing the
    /// correct spelling in the first place. Terms are de-duplicated, order
    /// preserved.
    static func promptBoost(entries: [CustomDictionaryEntry]) -> String {
        var seen = Set<String>()
        let terms = entries
            .map { $0.replacement.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        return terms.joined(separator: ", ")
    }

    private static func isWordCharacter(_ character: Character?) -> Bool {
        guard let character = character else { return false }
        return character.isLetter || character.isNumber || character == "_"
    }
}
