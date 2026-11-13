import Foundation

/// Takes the profanity out of a dictation **before** any model sees it.
///
/// The requirement behind this file is absolute, and it is the captain's: under a
/// formal tone the word he said in anger must not survive into the text he sends
/// to a client. A model cannot be trusted with that — measured across five
/// candidates from 135 M to 7 B, the Polish profanity survived in most of them,
/// and a model that removes the word today may leave it tomorrow. So the
/// guarantee is a function: the words are replaced before the transform runs,
/// which is the same kind of machinery as `DictationScrubber` — deterministic, no
/// model call, and therefore incapable of hallucinating.
///
/// The replacement is **neutral, not polite**: it has to carry the same meaning,
/// so that the rewrite which follows is still about the same thing ("ten plik
/// jest do dupy" → "ten plik jest nie do przyjęcia"). Cutting the word out and
/// leaving a hole would delete meaning, which this app does not do.
struct ProfanityScrubber {

    /// What came out of the dictation, and what the model is given instead.
    struct Result: Equatable {
        let text: String
        /// The words the scrub replaced, for the dictation report.
        let replaced: [String]
        var didChange: Bool { !replaced.isEmpty }
    }

    /// Longest phrase first: "do dupy" has to be tried before "dupy", and "go
    /// fuck yourself" before "fuck", or the shorter rule eats the longer one and
    /// leaves a broken sentence behind.
    ///
    /// Word boundaries, so "kurwa" inside a name and "shit" inside "shiitake" are
    /// left alone. Case-insensitive, because the engines write what they hear.
    private static let rules: [(pattern: String, replacement: String)] = [
        // Polish
        (#"\bkurwa\s+ma[cć]\b"#, ""),
        (#"\bdo\s+dupy\b"#, "nie do przyjęcia"),
        (#"\bpierdol\s+si[ęe]\b"#, "nie życzę sobie takiego traktowania"),
        (#"\bspierdalaj\b"#, "zostaw mnie w spokoju"),
        (#"\bjeban[aeyi]?\b"#, "wadliwy"),
        (#"\bgówn[oa]?\b"#, "problem"),
        (#"\bkurw[aęy]\b"#, ""),
        (#"\bcholera\b"#, ""),
        // English
        (#"\bgo\s+fuck\s+yourself\b"#, "I am not going to continue this conversation"),
        (#"\bfucked\s+up\b"#, "made a mistake with"),
        (#"\bfuck\s+you\b"#, "I am not going to continue this conversation"),
        (#"\bbullshit\b"#, "nonsense"),
        (#"\bshit\b"#, "problem"),
        (#"\bfucking\b"#, ""),
        (#"\bfuck\b"#, ""),
        (#"\bdamn\b"#, "very"),
    ]

    /// The text the model is given, with the profanity replaced.
    static func scrub(_ text: String) -> Result {
        var out = text
        var replaced: [String] = []
        for rule in rules {
            guard let regex = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            let matches = regex.matches(in: out, options: [], range: range)
            guard !matches.isEmpty else { continue }
            for match in matches.reversed() {
                guard let matchRange = Range(match.range, in: out) else { continue }
                replaced.append(String(out[matchRange]))
                out.replaceSubrange(matchRange, with: rule.replacement)
            }
        }
        // The replacements leave double spaces and orphaned commas behind.
        let tidied = out
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(text: tidied, replaced: replaced)
    }
}

/// Composes the part of an e-mail that must never be missing.
///
/// The model writes the prose; the *envelope* is a function. Measured, the
/// shape is the first thing the instruction model drops — runs came back as a
/// bare body with no greeting and no sign-off — and the mode's promise ("the
/// formatting is handled") cannot rest on that. So a missing greeting or
/// closing is added here, in the dictation's language, and one the model did
/// write is kept as it is: the app owns the envelope, the model owns the
/// sentences in between.
enum EmailEnvelope {

    private static let greetings = ["dzień dobry", "dzien dobry", "szanowni", "szanowna", "cześć",
                                    "witam", "hello", "hi ", "dear", "good morning", "good afternoon"]
    private static let closings = ["z poważaniem", "z powazaniem", "pozdrawiam", "z wyrazami",
                                   "z ukłonami", "regards", "sincerely", "best wishes", "thank you", "thanks"]

    static func greeting(for language: TransformLanguage) -> String {
        language == .polish ? "Dzień dobry," : "Hello,"
    }

    static func closing(for language: TransformLanguage) -> String {
        language == .polish ? "Z poważaniem" : "Best regards"
    }

    /// The answer with whatever half of the envelope it is missing.
    static func apply(to answer: String, language: TransformLanguage) -> String {
        let lines = answer
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let body = lines.drop { $0.isEmpty }
        guard !body.isEmpty else { return answer }

        let head = body.first!.lowercased()
        let tail = body.count > 1
            ? body.suffix(2).joined(separator: " ").lowercased()
            : body.first!.lowercased()

        var out: [String] = []
        if !greetings.contains(where: { head.hasPrefix($0) }) {
            out.append(greeting(for: language))
            out.append("")
        }
        out.append(contentsOf: body)
        if !closings.contains(where: { tail.contains($0) }) {
            out.append("")
            out.append(closing(for: language))
        }
        return out.joined(separator: "\n")
    }
}

/// Deterministic checks for an answer that is *about* the job instead of doing
/// it. Both were measured on the shipped instruction model, and the guard cannot
/// see either: a refusal greets nobody, labels nothing and announces nothing, so
/// every rule in `TransformGuard` passes it while the dictation is gone.
enum TransformAnswerCheck {

    /// Openings a refusal starts with, in the languages the transform serves.
    private static let refusalOpenings = [
        "nie mogę", "nie moge", "nie jestem w stanie", "przepraszam, ale", "przykro mi, ale",
        "i cannot", "i can't", "i'm sorry", "i am sorry", "i'm unable",
    ]

    /// A bracketed placeholder the model invented ("[Twoje Imię]", "[Name]").
    private static let placeholder = try? NSRegularExpression(pattern: #"\[[^\]]{2,40}\]"#)

    /// The reason this answer cannot be pasted, or `nil` when it stands.
    static func unusableAnswer(of output: String, for input: String) -> String? {
        let answer = output.trimmingCharacters(in: .whitespacesAndNewlines)

        if let placeholder,
           placeholder.firstMatch(in: answer, range: NSRange(answer.startIndex..<answer.endIndex, in: answer)) != nil {
            return "the answer invented a placeholder the dictation never carried"
        }

        let lowered = answer.lowercased()
        guard let opening = refusalOpenings.first(where: { lowered.hasPrefix($0) }) else { return nil }
        // A dictation that is itself about declining ("I cannot attend") keeps its
        // words: the rule fires only when the answer shares nothing with what was
        // dictated beyond that opening.
        let inputWords = Set(input.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
        let answerWords = Set(lowered.split(whereSeparator: { !$0.isLetter }).map(String.init))
        let shared = answerWords.intersection(inputWords).count
        guard shared <= 2 else { return nil }
        return "the answer refused the job (\"\(opening)…\") instead of rewriting the dictation"
    }
}
