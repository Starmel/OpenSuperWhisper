import Foundation

/// The deterministic half of the dictation clean-up: the disfluencies a speech
/// recogniser puts on the page, removed without asking a model anything.
///
/// This layer is a pure function of the transcript, which is why it can be
/// tested on fixed inputs, why it costs nothing, and why it works in every
/// direction — Polish → English, English → Polish, and a same-language
/// dictation with no transform at all. It removes only text that cannot be a
/// word the speaker meant:
///
/// * standalone fillers the recogniser writes as if they were words — the
///   captain's "hmmmm" and "aaaaa", and the Polish "yyy"/"eee" families;
/// * a stutter or false start that runs straight into the word it breaks
///   ("pro- problem", "p-problem");
/// * a word, phrase or whole sentence repeated immediately, which is what a
///   decoder loop looks like on the page ("First test of translation." ×7);
/// * the recogniser's own annotations — "(speaking in foreign language)",
///   "(music)" — which are the model talking about the audio, not the user.
///
/// What it deliberately does *not* do is edit words. It never removes a word
/// because of its part of speech: "like", "no", "you know", "wiesz", "jakby"
/// and "eh" as a question tag stay, because deleting one of those changes what
/// was said. It never reorders, never re-inflects and never changes letter
/// case — punctuation, articles, agreement and word order belong to the
/// grammar layer, which rides on the transform call.
///
/// A transcript that was nothing but fillers or annotations comes back empty.
/// The dictation path reads an empty transcript as "nothing was said" and
/// discards it, exactly as it already does for silence.
enum DictationScrubber {

    /// What one scrub did, so the dictation report can show it.
    struct Result: Equatable {
        /// The cleaned transcript.
        let text: String
        /// Standalone filler tokens dropped.
        let removedFillers: Int
        /// Repeated words, stutters and repeated phrases collapsed.
        let removedRepetitions: Int
        /// Recogniser annotations dropped.
        let removedAnnotations: Int

        var removedAnything: Bool {
            removedFillers + removedRepetitions + removedAnnotations > 0
        }
    }

    /// Filler tokens, matched case-insensitively against a whole word.
    ///
    /// Only non-lexical vocalisations are here. Words that look like filler but
    /// carry an answer — "mhm", "uh-huh", "no" ("no" is Polish for "yeah"),
    /// "ah", "eh" as a tag — are deliberately absent; deleting one of those
    /// would delete meaning.
    private static let fillers: Set<String> = [
        // English
        "hmm", "hmmm", "hmmmm", "hm",
        "uh", "uhh", "uhhh", "uhhhh",
        "um", "umm", "ummm", "ummmm",
        "er", "err", "erm", "mmm", "mmmm",
        // Polish, and the same sounds spelled the Polish way
        "yy", "yyy", "yyyy", "yyyyy", "yyyyyy",
        "eee", "eeee", "eeeee", "eeeeee",
        "aaa", "aaaa", "aaaaa", "aaaaaa",
    ]

    /// The opening words of a recogniser annotation. A bracketed phrase that
    /// starts with one of these is the model describing the audio, not the
    /// speaker's words, so the whole bracketed phrase goes.
    private static let annotationOpeners: [String] = [
        "music", "applause", "laughter", "laughs", "sighs", "coughs",
        "silence", "inaudible", "unintelligible", "indistinct",
        "foreign language", "speaking in", "speaks in", "noise", "background",
        "blank_audio", "blank audio", "beep", "sound effect", "wind",
    ]

    // MARK: - Entry point

    static func scrub(_ text: String) -> Result {
        guard !text.isEmpty else {
            return Result(text: text, removedFillers: 0, removedRepetitions: 0, removedAnnotations: 0)
        }

        let (unannotated, removedAnnotations) = removeAnnotations(text)
        guard !unannotated.isEmpty else {
            return Result(
                text: "",
                removedFillers: 0,
                removedRepetitions: 0,
                removedAnnotations: max(1, removedAnnotations)
            )
        }

        let tokens = collapseFalseStarts(tokenize(unannotated))
        let wordCount = tokens.filter { !$0.word.isEmpty }.count
        let (withoutFillers, removedFillers) = removeFillers(tokens)
        let deduped = collapseImmediateRepeats(withoutFillers)

        let rendered = collapseRepeatedSentences(render(deduped))
        let cleaned = tidy(rendered)
        let remainingWords = tokenize(cleaned).filter { !$0.word.isEmpty }.count
        let removedRepetitions = max(0, wordCount - removedFillers - remainingWords)

        return Result(
            text: cleaned,
            removedFillers: removedFillers,
            removedRepetitions: removedRepetitions,
            removedAnnotations: removedAnnotations
        )
    }

    /// Convenience for callers that only want the text.
    static func cleaned(_ text: String) -> String {
        scrub(text).text
    }

    // MARK: - Recogniser annotations

    /// Drops bracketed phrases that are the recogniser describing the audio.
    /// A bracket that does not start with one of `annotationOpeners` is the
    /// speaker's own aside and is left alone.
    private static func removeAnnotations(_ text: String) -> (text: String, removed: Int) {
        let characters = Array(text)
        var result = ""
        var removed = 0
        var index = 0

        while index < characters.count {
            let character = characters[index]
            guard character == "(" || character == "[" else {
                result.append(character)
                index += 1
                continue
            }
            let closer: Character = character == "(" ? ")" : "]"
            guard let closeOffset = characters[(index + 1)...].firstIndex(of: closer),
                  closeOffset - index <= 80 else {
                result.append(character)
                index += 1
                continue
            }

            let content = String(characters[(index + 1)..<closeOffset])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let words = content.split(whereSeparator: { $0 == " " || $0 == "_" })
            let isAnnotation = !content.isEmpty && words.count <= 8
                && annotationOpeners.contains { opener in
                    content == opener
                        || content.hasPrefix(opener + " ")
                        || content.hasPrefix(opener + "_")
                }

            index = isAnnotation ? closeOffset + 1 : index + 1
            if isAnnotation {
                removed += 1
            } else {
                result.append(character)
            }
        }
        return (result, removed)
    }

    // MARK: - Token model

    /// One word plus everything between it and the previous word.
    private struct Token {
        var separator: String
        var word: String

        var isEmpty: Bool { word.isEmpty }
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "'" || character == "\u{2019}"
    }

    /// A hyphen between two word characters is part of the word ("uh-huh",
    /// "e-mail"), so a filler cannot be carved out of it. A hyphen anywhere else
    /// is a separator, which is what a false start looks like on the page
    /// ("p- problem").
    private static func hyphenJoins(_ characters: [Character], at index: Int) -> Bool {
        guard characters[index] == "-", index > 0, index + 1 < characters.count else { return false }
        return isWordCharacter(characters[index - 1]) && isWordCharacter(characters[index + 1])
    }

    private static func tokenize(_ text: String) -> [Token] {
        let characters = Array(text)
        var tokens: [Token] = []
        var separator = ""
        var word = ""

        for (index, character) in characters.enumerated() {
            if isWordCharacter(character) || hyphenJoins(characters, at: index) {
                word.append(character)
                continue
            }
            if !word.isEmpty {
                tokens.append(Token(separator: separator, word: word))
                separator = ""
                word = ""
            }
            separator.append(character)
        }
        if !word.isEmpty {
            tokens.append(Token(separator: separator, word: word))
        } else if !separator.isEmpty {
            // Trailing punctuation with nothing after it.
            tokens.append(Token(separator: separator, word: ""))
        }
        return tokens
    }

    private static func render(_ tokens: [Token]) -> String {
        tokens.map { $0.separator + $0.word }.joined()
    }

    private static func normalizedWord(_ word: String) -> String {
        word.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?\u{2026}\"()[]"))
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }

    private static func hasTerminalPunctuation(_ separator: String) -> Bool {
        separator.contains(".") || separator.contains("!")
            || separator.contains("?") || separator.contains("\u{2026}")
    }

    /// Only whitespace and a comma may sit between two tokens for them to count
    /// as an immediate repeat; a full stop means the speaker finished a thought.
    private static func isWeakSeparator(_ separator: String) -> Bool {
        !hasTerminalPunctuation(separator)
    }

    // MARK: - False starts

    /// "p-problem" and "pro- problem" become "problem". A fragment only counts
    /// as a false start when it is short, is followed by the word it breaks, and
    /// a hyphen is what joins them: "to Toronto" is a phrase, not a stutter.
    private static func collapseFalseStarts(_ tokens: [Token]) -> [Token] {
        var result: [Token] = []
        var index = 0

        while index < tokens.count {
            var token = tokens[index]

            if token.word.contains("-"), !token.word.hasPrefix("-"), !token.word.hasSuffix("-") {
                let parts = token.word.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
                if parts.count >= 2 {
                    let fragment = parts[0]
                    let rest = parts.dropFirst().joined(separator: "-")
                    if fragment.count <= 4, isPrefix(fragment, of: rest), rest.count >= fragment.count * 2 {
                        token.word = rest
                    }
                }
            }

            if !token.isEmpty, index + 1 < tokens.count,
               token.word.count <= 4,
               tokens[index + 1].separator.contains("-"),
               isPrefix(token.word, of: tokens[index + 1].word) {
                var next = tokens[index + 1]
                // The hyphen is the false-start mark itself: it arrived with
                // the fragment ("pro- problem"), so taking the fragment has to
                // take the mark with it, or a stray "-" is left where the
                // stutter was. A dash the speaker meant is not in this
                // separator — it would have to be followed by word characters
                // to join a token, and this one is not.
                next.separator = token.separator
                    + next.separator.replacingOccurrences(of: "-", with: "")
                result.append(next)
                index += 2
                continue
            }

            result.append(token)
            index += 1
        }
        return result
    }

    private static func isPrefix(_ fragment: String, of word: String) -> Bool {
        let fragment = normalizedWord(fragment)
        let word = normalizedWord(word)
        guard !fragment.isEmpty, fragment.count < word.count else { return false }
        return word.hasPrefix(fragment)
    }

    // MARK: - Fillers

    private static func removeFillers(_ tokens: [Token]) -> ([Token], Int) {
        var removed = 0
        var result: [Token] = []
        var carry = ""

        for token in tokens {
            if !token.isEmpty, fillers.contains(normalizedWord(token.word)) {
                removed += 1
                carry += token.separator
                continue
            }
            var token = token
            token.separator = carry + token.separator
            carry = ""
            result.append(token)
        }
        if !carry.isEmpty, !result.isEmpty {
            result[result.count - 1].separator += carry
        }
        return (result, removed)
    }

    // MARK: - Repetition

    /// "the the airport", "się się", "no no no" — one copy survives. A repeated
    /// *phrase* ("I saw him, I saw him yesterday") collapses the same way.
    ///
    /// The repeated copy is dropped, never the first one: the speaker's opening
    /// words are the ones the sentence was built on.
    private static func collapseImmediateRepeats(_ tokens: [Token]) -> [Token] {
        var result: [Token] = []
        var index = 0
        var carry = ""

        while index < tokens.count {
            let longest = min(6, (tokens.count - index) / 2)
            var repeatLength = 0

            if longest >= 1 {
                for length in stride(from: longest, through: 1, by: -1) {
                    if isImmediateRepeat(tokens, at: index, length: length) {
                        repeatLength = length
                        break
                    }
                }
            }

            guard repeatLength > 0 else {
                var token = tokens[index]
                token.separator = carry + token.separator
                carry = ""
                result.append(token)
                index += 1
                continue
            }

            var consumed = index + repeatLength
            while consumed + repeatLength <= tokens.count,
                  isImmediateRepeat(tokens, at: consumed - repeatLength, length: repeatLength) {
                consumed += repeatLength
            }

            // The dropped copies' separators are punctuation the speaker left
            // behind (a comma before the stutter); it is carried onto whatever
            // follows the copy that survives.
            for dropped in (index + repeatLength)..<consumed {
                carry += tokens[dropped].separator
            }

            let kept = Array(tokens[index..<(index + repeatLength)])
            var first = kept[0]
            first.separator = carry + first.separator
            carry = ""
            result.append(first)
            result.append(contentsOf: kept.dropFirst())
            index = consumed
        }

        if !carry.isEmpty, !result.isEmpty {
            result[result.count - 1].separator += carry
        }
        return result
    }

    /// True when the `length` tokens at `start` repeat immediately after
    /// themselves. A purely numeric token never counts: "3 3 3" is a score, not
    /// a stutter, and dropping a digit drops meaning.
    private static func isImmediateRepeat(_ tokens: [Token], at start: Int, length: Int) -> Bool {
        let second = start + length
        guard length >= 1, second + length <= tokens.count else { return false }
        for offset in 0..<length {
            let first = tokens[start + offset]
            let other = tokens[second + offset]
            guard !first.isEmpty, !other.isEmpty,
                  isWeakSeparator(other.separator),
                  !isNumeric(first.word),
                  normalizedWord(first.word) == normalizedWord(other.word) else { return false }
        }
        return true
    }

    private static func isNumeric(_ word: String) -> Bool {
        let normalized = normalizedWord(word)
        return !normalized.isEmpty && normalized.allSatisfy { $0.isNumber }
    }

    /// A whole sentence or utterance repeated back to back — the decoder loop the
    /// captain hit on a 56-second recording ("First test of translation." ×7) —
    /// keeps its first copy. Matched on the rendered text, where the sentence's
    /// own punctuation is, and run to a fixed point so any number of copies
    /// collapses. The 10-character floor keeps a two-word echo ("No. No.") out
    /// of this pass; those are handled word by word above.
    private static func collapseRepeatedSentences(_ text: String) -> String {
        guard text.count >= 20 else { return text }

        let pattern = "(?is)(.{10,300}?[.!?\u{2026}])\\s*\\1"
        var result = text
        var previous = ""
        var passes = 0

        while result != previous, passes < 8 {
            previous = result
            result = result.replacingOccurrences(of: pattern, with: "$1", options: .regularExpression)
            passes += 1
        }
        return result
    }

    // MARK: - Tidy

    private static func tidy(_ text: String) -> String {
        var result = text
            .replacingOccurrences(of: "[ \t]{2,}", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " +([,.;:!?])", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "([,;:])([,;:])+", with: "$1", options: .regularExpression)
            // A comma left stranded in front of a full stop by a dropped
            // filler or a dropped repeat (", ." and ",.").
            .replacingOccurrences(of: ",\\s*([.!?\u{2026}])", with: "$1", options: .regularExpression)

        // A leftover separator in front of the first word (a dropped opener).
        result = result.replacingOccurrences(of: "^[ ,;:.!?\\-]+", with: "", options: .regularExpression)
        // A leftover comma run at the end.
        result = result.replacingOccurrences(of: "[ ,;:]+$", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "^[ \t]+", with: "", options: .regularExpression)

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
