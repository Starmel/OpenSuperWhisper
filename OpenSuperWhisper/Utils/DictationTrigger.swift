import Foundation

/// The spoken trigger that turns one dictation into an e-mail.
///
/// The phrase is *dictated*, not configured: the transcript's own opening picks
/// the mode, so nothing has to be switched in Settings and no second key has to
/// be held. The matcher is deliberately small and pure — the same family as
/// `LanguageDetector`, and for the same reason: it runs on every dictation and
/// has to be impossible to fool with an accent, a capital or a missing diacritic.
///
/// What it must survive is the **engine's** spelling, not the speaker's. A
/// 25-language ASR model writes "dyktuję maila" as readily as "Dyktuje mejla" or
/// "dyktuje meila", and a Polish dictation may even come back without diacritics
/// at all, so the comparison folds case, strips Polish diacritics and ignores
/// separators, and accepts the near-spellings the engines actually produce.
///
/// Only the opening counts, and only inside `windowWords` words: a mention of a
/// mail inside the body is content, not a mode change.
enum DictationTrigger {

    /// How far into the transcript the trigger's **verb** may start.
    ///
    /// Three words, because the phrase is spoken at the top of a dictation and
    /// dictation rarely starts clean: "no dobra, dyktuję maila…" is the phrase,
    /// with the filler in front of it. A false positive is expensive — "no więc
    /// słuchaj, napisz maila do klienta" is an ordinary sentence *about* a mail —
    /// and that sentence puts its verb fourth, so the verb window stops short of
    /// it. The noun may follow up to two words later, which is what catches
    /// "dyktuję teraz maila" and "napisz mi maila".
    static let windowWords = 3

    /// How many words the noun may trail the verb by.
    private static let nounTolerance = 2

    /// The verb half of the trigger, folded: what the user does with the mail.
    private static let verbs: Set<String> = [
        "dyktuje", "dyktuj", "podyktuje", "podyktuj", "napisze", "napisz", "napis",
        "tworze", "stworz", "zrob", "przygotuj", "przygotuje", "zredaguj", "sformuluj", "utworz",
        "dictate", "write", "compose", "draft", "make", "prepare", "send",
    ]

    /// The noun half, folded: what is being dictated.
    private static let nouns: Set<String> = [
        "maila", "mail", "mailu", "mejla", "mejl", "meila", "meil", "email", "e-mail", "emaila",
        "wiadomosc", "wiadomosci", "message",
    ]

    /// What the transcript says, and what is left of it once the trigger is taken
    /// off the front.
    struct Match: Equatable {
        /// The words the trigger consumed, as the engine wrote them.
        let spoken: String
        /// The rest of the transcript: the dictated body, trimmed. Empty when the
        /// user said nothing but the trigger.
        let body: String
    }

    /// The match, or `nil` when this dictation did not open with the trigger.
    static func email(in transcript: String) -> Match? {
        let words = transcript.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        guard words.count >= 2 else { return nil }

        let verbLimit = min(words.count, windowWords)
        for verbIndex in 0..<verbLimit {
            guard verbs.contains(fold(String(words[verbIndex]))) else { continue }
            // The noun normally follows the verb, but an engine may drop filler
            // between them ("dyktuję teraz maila", "napisz mi maila"), so the noun
            // is looked for inside `nounTolerance` words rather than the next one.
            let nounEnd = min(words.count, verbIndex + nounTolerance + 1)
            for nounIndex in (verbIndex + 1)..<nounEnd {
                guard nouns.contains(fold(String(words[nounIndex]))) else { continue }
                let consumed = words[verbIndex...nounIndex].joined(separator: " ")
                let body = words[(nounIndex + 1)...].joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?-–—"))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return Match(spoken: consumed, body: body)
            }
        }
        return nil
    }

    /// Case, Polish diacritics and separator punctuation folded away, so the
    /// comparison sees the word the user said and not the one the engine chose to
    /// spell.
    private static func fold(_ word: String) -> String {
        let stripped = word
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?()\"'«»-–—"))
            .lowercased()
        var out = ""
        for character in stripped {
            switch character {
            case "ą": out.append("a")
            case "ć": out.append("c")
            case "ę": out.append("e")
            case "ł": out.append("l")
            case "ń": out.append("n")
            case "ó": out.append("o")
            case "ś": out.append("s")
            case "ź", "ż": out.append("z")
            default: out.append(character)
            }
        }
        return out
    }
}
