import Foundation

/// Why a tone result was thrown away in favour of the raw transcript.
///
/// Every case is decided from the *text alone*: the guard makes no model call
/// and runs no second pass, so it cannot itself hallucinate. It exists because
/// the small shipped model answered a dictation as if it were a chat request and
/// prefixed the rewrite with an acknowledgement; the prompt makes that rarer,
/// the larger instruction-follower made it rarer still, and this makes the
/// class impossible. The same
/// reasoning covers the second measured leak: the model returning the prompt's
/// own `TRANSCRIPT`/`TRANSKRYPCJA` delimiter around a short dictation.
enum TransformGuardRejection: Equatable {
    /// The answer opens by addressing the user as an assistant would.
    case assistantFrame(String)
    /// The answer carries the transform prompt's own user-turn delimiter — the
    /// `<<<TRANSCRIPT … TRANSCRIPT>>>` the prompt wraps the dictation in (the
    /// Polish `TRANSKRYPCJA` is what the model answers a Polish dictation with)
    /// — instead of, or around, the text.
    case promptMarker(String)
    /// The answer carries a label line (`Register:`/`Output:`) or announces the
    /// rewritten text instead of being it.
    case label(String)
    /// The dictation carried a sentence and the answer is a fragment of it.
    case stub(wordsIn: Int, wordsOut: Int)
    /// The answer holds no word of the language that went in, although the text
    /// that went in had content words.
    case languageFlip(expected: TransformLanguage)

    /// What the notice under the transcript says.
    var notice: String {
        switch self {
        case .assistantFrame(let frame):
            return "The model answered with an acknowledgement (\"\(frame)\") instead of rewriting "
                + "the dictation, so your own words were used instead."
        case .promptMarker(let marker):
            return "The model returned the transform prompt's own marker (\"\(marker)\") instead of "
                + "the text, so your own words were used instead."
        case .label(let label):
            return "The model wrapped the rewrite in a label (\"\(label)\") instead of returning the "
                + "text alone, so your own words were used instead."
        case .stub:
            return "The model returned a small fragment of the dictation instead of rewriting it, so "
                + "your own words were used instead."
        case .languageFlip(let expected):
            return "The model answered in another language instead of keeping \(expected.displayName), "
                + "so your own words were used instead."
        }
    }
}

/// The deterministic rejection the app applies to a tone result before it can
/// reach the transcript.
///
/// It reads text only — no model call, no second pass. What it catches is the
/// class a user actually notices and cannot repair: an assistant frame, the
/// prompt's own delimiter, a label, a stub, a language flip. What it cannot
/// catch is subtle content drift (an article dropped, a noun invented); that is
/// the prompt's and the model's job, and it is stated as a limit rather than papered
/// over.
///
/// A frame or a label is judged against the dictation as well as the answer: the
/// model has to have **added** it. The same words in the dictation's own opening
/// (`Here is the summary, …`, `I've already …`) are the user's, and throwing
/// them away would replace a good rewrite with the raw transcript.
enum TransformGuard {
    /// Openings an assistant uses when it is answering rather than rewriting.
    /// Matched on the first words of the first non-empty line, after markdown
    /// and quote marks are stripped, case-insensitively — **and only when the
    /// dictation did not open with the same words**, which is what separates a
    /// frame the model added from the user's own opening (`assistantFrame`).
    static let assistantFrames: [String] = [
        "sure", "certainly", "of course", "understood", "here is", "here's",
        "i've", "oczywiście", "oto", "jasne"
    ]

    /// Phrases that announce a rewrite instead of being one — in both languages,
    /// because the frame list already carries Polish entries and a Polish
    /// preamble is the same failure in the other language. Ignored when the
    /// dictation already said the phrase.
    static let announcingPhrases: [String] = [
        "rewritten text", "rewritten version",
        "przepisany tekst", "przepisana wersja", "oto przepisany"
    ]

    /// Label prefixes that may open a line (`Register: formal`). Ignored when
    /// the dictation itself carried the label.
    static let labelPrefixes: [String] = ["register:", "output:"]

    /// The dictation is handed to the model inside the prompt's own delimiter,
    /// and the answer sometimes comes back *as* it. Measured on the captain's own
    /// library (`fm-20260925-15` §8): five short dictations returned the frame
    /// instead of, or around, the text, and none of the guard's four existing
    /// rules could see it.
    ///
    /// These are the words the app's own prompt composes, in the case the frame
    /// is written in. The prompt writes `TRANSCRIPT` in both languages, but a
    /// Polish dictation was measured coming back with the Polish word, so both
    /// are listed and the match stays case-sensitive: the ordinary lowercase word
    /// in `I need the transcript by Friday.` is the user's own and is delivered.
    static let promptMarkerWords: [String] = ["TRANSCRIPT", "TRANSKRYPCJA"]

    /// The least letters a word attached to `<<<`/`>>>` must carry to count as a
    /// marker, so a stray `<<<A` is not one.
    static let promptMarkerMinimumLetters = 2

    /// A dictation with fewer words than this is not "a sentence", so the stub
    /// rule never applies to it — a two-word dictation or a fragment comes back
    /// as it is. Measured against the cases in `fm-20260924-10`: the collapse
    /// the small model produced at temperature 0 replaced a 12-word run-on with
    /// `Understood.` (1 word).
    static let stubMinimumInputWords = 8
    /// The answer must keep at least this fraction of the dictation's words.
    /// `Understood.` keeps 1/12; a legitimate register rewrite keeps almost all.
    ///
    /// Known limit, deferred rather than papered over: this counts **fillers**
    /// as words. A legitimate tone+clean-up that strips heavy stutter can fall
    /// under the floor and be rejected, and the fix needs a language-specific
    /// filler list — which this guard deliberately does not carry.
    static let stubMinimumKeptFraction = 0.25

    /// A flip is only claimed when the text that went in carried content words:
    /// a one-word or number-only dictation gives the detector nothing to hold on
    /// to, and an unchanged short text is never a flip.
    ///
    /// Known limit, deferred rather than widened: the rule needs the *engine's*
    /// language to agree with the detector's. Mixed or technical dictation the
    /// engine called "pl" and the detector calls "en" cannot be caught at all —
    /// the first condition fails before the answer is looked at.
    static let flipMinimumInputWords = 3

    /// The rejection for this answer, or `nil` when it may be delivered.
    static func rejection(
        of output: String,
        for input: String,
        language: TransformLanguage
    ) -> TransformGuardRejection? {
        let answer = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return nil }

        // Already in register: the model is allowed — expected — to return the
        // dictation unchanged. Nothing below can be true of the user's own text,
        // and the language rule in particular must not be read as a flip.
        if answer == input.trimmingCharacters(in: .whitespacesAndNewlines) { return nil }

        if let marker = promptMarker(in: answer) {
            return .promptMarker(marker)
        }
        if let frame = assistantFrame(in: answer, input: input) {
            return .assistantFrame(frame)
        }
        if let label = label(in: answer, input: input) {
            return .label(label)
        }
        if let stub = stub(output: answer, input: input) {
            return stub
        }
        if let flip = languageFlip(output: answer, input: input, language: language) {
            return flip
        }
        return nil
    }

    /// The frame the answer opens with, if any — and only when **the model added
    /// it**.
    ///
    /// Two conditions together, because "assistant-shaped" is not the same as
    /// "the model is answering":
    ///
    /// * the answer opens with the frame (only the opening counts: a dictation
    ///   may legitimately carry "sure" or an "I've" further in, and rejecting
    ///   that would throw away good output), and
    /// * the dictation did not **open** with the same words. `Here is the
    ///   summary, …` and `I've already deployed the backend …` are ordinary
    ///   *dictated* openings, and a rewrite that keeps them is the user's own
    ///   words, not an acknowledgement.
    ///
    /// A frame in the middle of the dictation does not excuse an answer that
    /// opens with one: `I'm not sure, maybe we ship Friday` answered with
    /// `Sure, we ship Friday.` is the measured failure, still caught.
    static func assistantFrame(in answer: String, input: String) -> String? {
        guard let opening = firstContentLine(of: answer)?.lowercased() else { return nil }
        let inputOpening = firstContentLine(of: input)?.lowercased()
        for frame in assistantFrames {
            guard opens(with: frame, in: opening) else { continue }
            if let inputOpening, opens(with: frame, in: inputOpening) { continue }
            return frame
        }
        return nil
    }

    /// Whether `line` is `frame`, or continues after it as a separate word
    /// (`Sure, …`, `Here is how …`).
    private static func opens(with frame: String, in line: String) -> Bool {
        if line == frame { return true }
        guard line.hasPrefix(frame) else { return false }
        let next = line[line.index(line.startIndex, offsetBy: frame.count)]
        return next == "," || next == "!" || next == "." || next == ":" || next == " "
    }

    /// The prompt's own delimiter in the answer, if any — the frame the model was
    /// told not to repeat and repeated anyway.
    ///
    /// Two shapes, both measured on the captain's recordings:
    ///
    /// * a line whose entire content is an all-caps marker word —
    ///   `keyboard simulation output is working.\nTRANSCRIPT` ends with exactly
    ///   that line, and so do `Now speaking English` and `Use of pickguard`. The
    ///   case sensitivity is the safety margin: `I need the transcript by
    ///   Friday.` and `Send the transcript.` carry the ordinary lowercase word
    ///   and are delivered;
    /// * a marker attached to the angle brackets (`<<<TRANSCRIPT`,
    ///   `TRANSKRYPCJA>>>`) — the whole of the Polish answer (`<<<TRANSKRYPCJA`,
    ///   then `font`, then `TRANSKRYPCJA>>>`) and of the English one (`<<<TRANSCRIPT`,
    ///   `Continue with fixes.`, `TRANSCRIPT>>>`). The brackets cannot arrive in dictated speech, and a
    ///   model that invents a different all-caps word inside them has still
    ///   returned the frame rather than the text, so any all-caps word there
    ///   counts.
    ///
    /// Unlike the frame and the label rules this takes no view of the dictation:
    /// there is nothing a person dictates that comes back as a lone all-caps
    /// marker line. It is checked first because it is the most specific — the
    /// marker is the app's own string, not an inference about tone.
    static func promptMarker(in answer: String) -> String? {
        for line in answer.components(separatedBy: .newlines) {
            let stripped = stripMarkup(line).trimmingCharacters(in: .whitespaces)
            guard !stripped.isEmpty else { continue }
            if let word = promptMarkerWord(in: stripped) { return word }
            if let bracketed = bracketedPromptMarker(in: stripped) { return bracketed }
        }
        return nil
    }

    /// The marker word the line *is*, allowing sentence punctuation after it.
    ///
    /// Measured gap in the first version of this rule: the comparison was exact,
    /// so `TRANSCRIPT.` and `TRANSCRIPT:` — the same marker with a full stop or a
    /// colon the model added — were delivered instead of rejected. Trailing
    /// `. , : ; ! ?` is stripped before the comparison, and the match stays
    /// case-sensitive, so the dictated lowercase word in `I need the transcript
    /// by Friday.` is still the user's own and still delivered.
    static func promptMarkerWord(in line: String) -> String? {
        let word = line.trimmingCharacters(in: CharacterSet(charactersIn: ".,:;!?"))
        return promptMarkerWords.contains(word) ? word : nil
    }

    /// The all-caps word a `<<<` or `>>>` on this line is attached to, if there
    /// is one: the word after an opening bracket, the word before a closing one.
    private static func bracketedPromptMarker(in line: String) -> String? {
        let characters = Array(line)
        var index = 0
        while index < characters.count {
            let bracket = characters[index]
            guard bracket == "<" || bracket == ">" else {
                index += 1
                continue
            }
            // The frame is written `<<<`/`>>>`; a single bracket is the same
            // marker, so the whole run is consumed either way.
            var runEnd = index
            while runEnd < characters.count, characters[runEnd] == bracket { runEnd += 1 }
            var marker: [Character] = []
            if bracket == "<" {
                var cursor = runEnd
                while cursor < characters.count, characters[cursor].isLetter {
                    marker.append(characters[cursor])
                    cursor += 1
                }
            } else {
                var cursor = index - 1
                while cursor >= 0, characters[cursor].isLetter {
                    marker.append(characters[cursor])
                    cursor -= 1
                }
                marker.reverse()
            }
            let word = String(marker)
            if word.count >= promptMarkerMinimumLetters, word == word.uppercased() {
                return word
            }
            index = runEnd
        }
        return nil
    }

    /// The label the answer carries, if any — again only when the model added it.
    ///
    /// Two shapes: a line that opens with a label prefix, and an announcement
    /// phrase anywhere (`Sure, here's the rewritten text in a casual register:` —
    /// the measured 1.5B preamble; its opening is caught by the frame rule as
    /// well, this catches the same sentence when the opener differs).
    ///
    /// Each is ignored when the dictation already carried it: text *about* the
    /// "rewritten text", or one that dictated a `Register:` line itself, is not
    /// the model labelling its answer.
    static func label(in answer: String, input: String) -> String? {
        let lowered = answer.lowercased()
        let dictation = input.lowercased()
        for phrase in announcingPhrases where lowered.contains(phrase) {
            guard !dictation.contains(phrase) else { continue }
            return phrase
        }
        for line in answer.components(separatedBy: .newlines) {
            let trimmed = stripMarkup(line).trimmingCharacters(in: .whitespaces)
            let lineLowered = trimmed.lowercased()
            for prefix in labelPrefixes where lineLowered.hasPrefix(prefix) {
                guard !dictation.contains(prefix) else { continue }
                return prefix
            }
        }
        return nil
    }

    /// The stub, if the answer is a small fragment of a dictation that carried a
    /// sentence.
    static func stub(output: String, input: String) -> TransformGuardRejection? {
        let inWords = words(in: input).count
        guard inWords >= stubMinimumInputWords else { return nil }
        let outWords = words(in: output).count
        let floor = Int((Double(inWords) * stubMinimumKeptFraction).rounded(.down))
        guard outWords < max(1, floor) else { return nil }
        return .stub(wordsIn: inWords, wordsOut: outWords)
    }

    /// The flip, when the answer holds no word of the language that went in.
    ///
    /// The app's own `LanguageDetector` decides, which is also what classifies
    /// the dictation in the first place. Three things must hold before a flip is
    /// claimed, so the legitimate cases stay untouched:
    ///
    /// * the *dictation* itself classifies as the language the policy pinned —
    ///   a text that mixes in a technical term from another language does not,
    ///   and an answer to it is never called a flip (measured: "We deploy the
    ///   backend na produkcję every Friday evening." classifies as Polish);
    /// * the answer classifies as the other language (or the detector cannot
    ///   place it, in which case it is not a flip either — "cannot place" is not
    ///   "flipped");
    /// * the answer shares no content word with the dictation. A rewrite that
    ///   keeps any of the user's own words has not flipped wholesale.
    static func languageFlip(
        output: String,
        input: String,
        language: TransformLanguage
    ) -> TransformGuardRejection? {
        guard words(in: input).count >= flipMinimumInputWords else { return nil }
        guard let inputVerdict = TransformLanguage(verdict: LanguageDetector.detect(input)),
              inputVerdict == language else { return nil }
        guard let outputVerdict = TransformLanguage(verdict: LanguageDetector.detect(output)),
              outputVerdict != language else { return nil }
        let inputWords = Set(words(in: input).map { $0.lowercased() })
        let shared = words(in: output).contains { inputWords.contains($0.lowercased()) }
        guard !shared else { return nil }
        return .languageFlip(expected: language)
    }

    // MARK: - Text helpers

    /// The first line that carries something other than markdown or quotes.
    private static func firstContentLine(of text: String) -> String? {
        for line in text.components(separatedBy: .newlines) {
            let stripped = stripMarkup(line).trimmingCharacters(in: .whitespaces)
            if !stripped.isEmpty { return stripped }
        }
        return nil
    }

    /// Removes the decoration a chat model wraps around its answer: markdown
    /// emphasis, bullets and surrounding quote marks.
    private static func stripMarkup(_ line: String) -> String {
        var result = line.replacingOccurrences(of: "**", with: "")
        result = result.replacingOccurrences(of: "*", with: "")
        result = result.replacingOccurrences(of: "#", with: "")
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'“”„«»-—–•"))
        return result
    }

    /// The words of `text`: runs of letters, which is what both the stub rule
    /// and the flip rule need. Numbers are deliberately not words — a list of
    /// numbers is not a sentence and must not be measured as one.
    static func words(in text: String) -> [String] {
        text.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
    }
}
