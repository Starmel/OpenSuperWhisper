import Foundation

/// The language of a dictation, decided from its text alone.
///
/// This is the *fallback* signal for the transform gate. The whisper engine
/// reports the language of the utterance it just decoded (see
/// `WhisperEngine.DetailedTranscription.language`); only an engine that cannot
/// speak — Parakeet/FluidAudio, or a whisper model that is not multilingual and
/// was left on `auto` — falls back to this heuristic.
///
/// The rule set is deliberately tiny and pure: no model call, no I/O, no
/// dependency, microseconds of string work.
///
///   * Polish diacritics (`ąćęłńóśźż`) are the strongest single signal —
///     English never uses them. Any hit adds `3.0 + min(hits, 4)`.
///   * Polish-only function words add `1.5` each. The ambiguous ones that also
///     occur in English (`w`, `z`, `na`, `do`) additionally count as weak
///     Polish markers worth `0.5`, because those words never stand alone in
///     English.
///   * English function words add `1.0` each.
///   * Character bigrams add `0.5` per occurrence on both sides, which is what
///     decides diacritic-free Polish (`Zrob to`, `Wyslij maila do klienta`).
///
/// The higher score wins. Equal scores — and no signal at all — are `unknown`,
/// which is a useful answer rather than a failure: the gate then pastes the raw
/// transcript instead of guessing.
///
/// Measured (design study `fm-20260923-04` §2.1, reference implementation
/// `/tmp/fm04/heuristic.py`): 22/22 realistic sentences, 16/16 real engine
/// transcripts, 23/32 deliberately adversarial 1–3 word phrases — the rule is a
/// coin flip on two-word input, so it must never be the only signal available.
enum LanguageDetector {

    enum Verdict: Equatable {
        case polish
        case english
        /// No usable signal, or a tie between the two languages.
        case unknown

        /// The whisper language code for this verdict, or `nil` when the text
        /// carries no usable signal.
        var languageCode: String? {
            switch self {
            case .polish: return "pl"
            case .english: return "en"
            case .unknown: return nil
            }
        }

        /// The verdict for a whisper language code, or `nil` for a language
        /// this heuristic cannot stand behind (the gate only ever acts on
        /// Polish, so any third language is treated like `unknown`).
        init?(languageCode: String) {
            switch languageCode {
            case "pl": self = .polish
            case "en": self = .english
            default: return nil
            }
        }
    }

    /// Verdict for `text`; `unknown` when the two languages score equally or
    /// neither scores at all.
    static func detect(_ text: String) -> Verdict {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unknown }

        let lower = trimmed.lowercased()
        let words = lower
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: tokenEdgeCharacters) }
            .filter { !$0.isEmpty }

        var polish = 0.0
        var english = 0.0

        let diacriticHits = trimmed.reduce(into: 0) { hits, character in
            if polishDiacritics.contains(character) { hits += 1 }
        }
        if diacriticHits > 0 {
            polish += 3.0 + Double(min(diacriticHits, 4))
        }

        polish += 1.5 * Double(matches(in: words, of: polishWords))
        polish += 0.5 * Double(matches(in: words, of: weakPolishMarkers))
        english += 1.0 * Double(matches(in: words, of: englishWords))

        polish += 0.5 * Double(polishBigrams.reduce(0) { $0 + occurrences(of: $1, in: lower) })
        english += 0.5 * Double(englishBigrams.reduce(0) { $0 + occurrences(of: $1, in: lower) })

        if polish > english { return .polish }
        if english > polish { return .english }
        return .unknown
    }

    /// The whisper language code for `text`, or `nil` when unsure.
    static func languageCode(for text: String) -> String? {
        detect(text).languageCode
    }

    // MARK: - Rule set

    private static let tokenEdgeCharacters = CharacterSet(charactersIn: ".,!?;:\"'()")

    private static let polishDiacritics = Set("ąćęłńóśźżĄĆĘŁŃÓŚŹŻ")

    /// Polish-only words. English homographs (`a`, `o`, `to`, `i` as a letter)
    /// are excluded; the ambiguous short ones also appear in
    /// `weakPolishMarkers` and are worth 2.0 together.
    private static let polishWords: Set<String> = [
        "nie", "się", "że", "jest", "są", "było", "był", "była", "jak", "czy", "ale",
        "po", "za", "od", "dla", "tym", "tak", "bardzo", "już", "tylko", "jeszcze",
        "może", "muszę", "musi", "wiem", "chcesz", "chcę", "żeby", "który", "która",
        "które", "ten", "ta", "te", "mój", "moja", "moje", "twoje", "twoja", "mi",
        "mnie", "ciebie", "proszę", "dziękuję", "dzień", "dobry", "jutro", "wczoraj",
        "dzisiaj", "teraz", "wysłać", "wysłałem", "zrobić", "zrób", "kupić", "pomóc",
        "spotkanie", "raport", "wiadomość", "czas", "chleb", "mleko", "klient", "klienta",
        "na", "do", "w", "z", "i",
    ]

    /// Words that are Polish prepositions or particles and never English words,
    /// but too short to be conclusive on their own.
    private static let weakPolishMarkers: Set<String> = [
        "w", "z", "na", "do", "po", "za", "od", "że",
    ]

    private static let englishWords: Set<String> = [
        "the", "a", "an", "is", "are", "was", "were", "be", "of", "to", "in", "on",
        "at", "for", "with", "this", "that", "these", "those", "it", "you", "we",
        "they", "he", "she", "and", "but", "or", "not", "do", "does", "did", "can",
        "could", "would", "should", "will", "my", "your", "our", "their", "please",
        "thank", "thanks", "need", "want", "have", "has", "had", "send", "sent",
        "report", "meeting", "message", "time", "bread", "milk", "client", "help",
        "tomorrow", "yesterday", "today", "now", "very", "much", "know", "buy",
    ]

    private static let polishBigrams = [
        "cz", "sz", "rz", "dz", "ść", "prz", "trz", "się", "nie", "owa", "ego", "ych", "ami", "iem",
    ]

    private static let englishBigrams = ["th", "the", "ing", "ion", "you", "wh", "sh"]

    /// Occurrences of set members in `words` (multiplicity counts, matching the
    /// reference implementation).
    private static func matches(in words: [String], of set: Set<String>) -> Int {
        words.reduce(into: 0) { count, word in
            if set.contains(word) { count += 1 }
        }
    }

    /// Non-overlapping occurrences, matching the reference implementation's
    /// `str.count`.
    private static func occurrences(of needle: String, in haystack: String) -> Int {
        var count = 0
        var searchStart = haystack.startIndex
        while let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }
}
