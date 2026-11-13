import Foundation

/// An English-only speech model that produced a transcript it cannot have heard.
///
/// This is the captain's first failure, made impossible to miss: his selected
/// model was `ggml-tiny.en.bin`, so whisper could not hear the Polish he spoke
/// and produced confident English instead ("There are some people who are going
/// to go to the airport."). Nothing warned him; nothing named the model.
///
/// There is no language setting left to compare against, so the evidence is the
/// transcript itself: an `.en` model cannot detect anything, and when the text
/// it produced is not English, what the user is looking at is a model writing
/// English over speech it never understood.
struct SpeechLanguageConflict: Equatable {
    /// The speech model's file name, e.g. `ggml-tiny.en.bin`.
    let modelName: String
    /// The language the transcript itself looks like, e.g. `pl`.
    let detectedLanguageCode: String
    /// That language in words, e.g. "Polish".
    let detectedLanguageName: String
    /// An already-installed multilingual model that fixes it, if there is one.
    let remedyModelName: String?
    let remedyModelPath: String?

    var title: String { "This dictation needs a multilingual model" }

    /// The whole story in one paragraph: the model, what the transcript looks
    /// like, what whisper did instead, and the fix — the file that is already on
    /// this machine when there is one.
    var message: String {
        var text = "\(modelName) understands English only, but this dictation is "
            + "\(detectedLanguageName). Whisper cannot transcribe \(detectedLanguageName) with that "
            + "model — it writes English sentences instead of what was said. Dictation is blocked "
            + "until this is fixed."
        if let remedyModelName {
            text += " Select \(remedyModelName) (already on this machine)."
        } else {
            text += " Download a multilingual model in Settings → Model."
        }
        return text
    }

    /// The fix offered in place, when there is an installed model to offer.
    var remedyButtonTitle: String? {
        remedyModelName.map { "Use \($0)" }
    }
}

/// What the decoder measured about the speech in the audio it was given.
///
/// The transcript cannot answer this. Whisper writes its most likely phrase
/// over anything it is handed — silence comes back as "Thank you for watching"
/// in text that reads exactly like speech — so the text is no evidence at all
/// that a voice was there. What is evidence is the VAD in front of the decoder
/// and the decoder's own `no_speech_prob` for the segments it produced, which
/// is why the engine puts its measurement here and the gate below refuses on
/// it. `nil` — no measurement — is not evidence and never refuses.
enum SpeechPresence: Equatable {
    /// The VAD found no speech segment at all: what the decoder was given could
    /// not have been words.
    case noSpeechSegment
    /// Speech was there, and this is what the segments the decoder produced look
    /// like to it: whisper's own `no_speech_prob`, averaged over them. It is the
    /// quantity the user's `noSpeechThreshold` is compared against inside
    /// whisper, so the same line decides here.
    case measured(meanNoSpeechProbability: Double)
}

/// A transcript produced from audio that held no speech.
///
/// This is the second way text appears out of nothing: the language conflict
/// above needs a model that cannot hear the language, but whisper invents a
/// fluent phrase over a room with no voice in it just as readily — and with a
/// multilingual model there is no language conflict to catch it. The refusal is
/// the same shape as the other one: nothing is published, nothing is pasted,
/// the audio is kept so nothing the user said is lost, and the message says
/// what the user has to act on — that no speech was detected.
struct SpeechPresenceConflict: Equatable {
    /// The speech model that produced the text, e.g. `ggml-tiny.en.bin`.
    let modelName: String
    /// What refused the transcript.
    let presence: SpeechPresence
    /// The user's `noSpeechThreshold`, the line the measurement was over.
    let noSpeechThreshold: Double

    var title: String { "No speech was detected" }

    /// The whole story, in the user's terms: no speech, not a language error,
    /// and what happened to the recording.
    var message: String {
        var text = "No speech was detected in this recording, so nothing was transcribed and nothing "
            + "was typed. \(modelName) wrote text over audio it heard no speech in — silence is where "
            + "a speech model invents phrases nobody said — so the transcript was discarded instead of "
            + "pasted."
        switch presence {
        case .noSpeechSegment:
            text += " The voice activity detector found no speech in this recording at all."
        case .measured(let meanNoSpeechProbability):
            text += String(
                format: " The segments it produced look like non-speech (no-speech probability "
                    + "%.2f, and your threshold is %.2f).",
                meanNoSpeechProbability,
                noSpeechThreshold
            )
        }
        return text + " The audio is kept, so the recording is not lost."
    }
}

/// A transcript the same audio, read a second time, does not contain.
///
/// This is the third way text appears that the user never said, and the only
/// one with a comparison behind it. The other two gates read one thing — the
/// transcript, and the decoder's own verdict on whether there was speech at
/// all — and a model that writes fluent English over Polish speech it never
/// understood passes both of them, because the text is exactly what an
/// English-only model produces and the audio really did hold speech.
///
/// What is evidence here is the reading itself: the same audio, the same model,
/// the same settings, decoded once more with the decoder prompt flipped. A
/// transcript that only exists while the decoder has been *handed text* is text
/// the model wrote, not words it heard — the second reading, which was given
/// different text, does not contain it. The refusal is the same shape as the
/// other two: nothing is published, nothing is pasted, the audio is kept.
struct SpeechCorroborationConflict: Equatable {
    /// The speech model that produced the first reading, e.g. `ggml-tiny.en.bin`.
    let modelName: String
    /// How many words the transcript is made of.
    let transcriptWordCount: Int
    /// How many of those words the second reading of the same audio contains.
    let corroboratedWordCount: Int

    var title: String { "This transcript is not in the recording" }

    /// The whole story in the user's terms: the recording was read twice, the
    /// two readings disagree, and what happened to the audio — never the
    /// language conflict above (that is a model that cannot hear the language)
    /// and never the no-speech refusal (that is a recording without a voice).
    var message: String {
        "\(modelName) was given this recording twice. Its first reading produced \(transcriptWordCount) "
            + "words, and a second reading of the same audio contains only \(corroboratedWordCount) of "
            + "them — text that only one reading of a recording has is text the decoder wrote, not words "
            + "it heard. Nothing was transcribed and nothing was typed. The audio is kept, so the "
            + "recording is not lost."
    }
}

/// The rule that refuses to keep a transcript only an English-only model could
/// have invented.
///
/// The model is English-only when the loaded context says
/// `whisper_is_multilingual() == 0`, and — for the window before a model is
/// loaded, and for the Settings card, where there is no engine at all — when its
/// file name declares it (`ggml-tiny.en.bin`, `ggml-base.en.bin`).
///
/// The language, now, is **read off the transcript**: with the manual language
/// picker gone there is no setting to compare against, and an English-only model
/// measures nothing — the text it produced is the only evidence in the app. The
/// existing `LanguageDetector` heuristic supplies the verdict, so a transcript
/// that looks Polish under a `.en` model is refused and named, and English
/// dictation can never be caught by this guard.
///
/// The verdict is only evidence from `languageConflictMinimumWords` words up —
/// the heuristic is a coin flip on one and two words, and refusing a dictation
/// on a coin flip tells an English one it is Polish. See the constant for the
/// measurement.
///
/// Nothing here changes a preference. The remedy is offered, and applied only
/// when the user takes it.
enum SpeechModelLanguageGate {

    /// The multilingual model the app prefers to offer, because it is the one
    /// the machine and the download list both know.
    static let preferredMultilingualModelName = "ggml-large-v3-turbo.bin"

    /// The shortest transcript this gate may refuse: **four words**.
    ///
    /// The heuristic answers Polish or English and nothing else, and on one or
    /// two words it is a coin flip — `LanguageDetector`'s own documentation says
    /// the same thing from its own measurement ("the rule is a coin flip on
    /// two-word input, so it must never be the only signal available"). Left
    /// unbounded, that coin flip is a refusal: an English dictation of *Miami*,
    /// *nowadays* or *brownie* — every one of them read as Polish — was refused
    /// and told it was Polish.
    ///
    /// Measured on the captain's own recordings plus the repository's labelled
    /// fixtures, pooled over 122 labelled items, the heuristic agrees with the
    /// truth **36.4%** of the time at one word, **54.2%** at two, **79.2%** at
    /// three, **92.9%** at four to five and **100%** at six to ten — the one
    /// miss above the floor is inside the fourteen four-to-five-word items. Four
    /// is where agreement stops being a coin flip, and below it this gate
    /// refuses nothing: the transcript goes on exactly as it did before the gate
    /// existed. The words are counted with `contentWords`, the same rule the
    /// rest of the app counts them by, so the floor and the measurement cannot
    /// drift apart.
    static let languageConflictMinimumWords = 4

    /// The conflict for this model and this transcript, or `nil` when there is
    /// nothing to refuse.
    static func conflict(
        modelPath: String?,
        isMultilingual: Bool?,
        transcript: String?,
        modelsDirectory: URL = WhisperModelManager.modelsDirectory,
        fileManager: FileManager = .default
    ) -> SpeechLanguageConflict? {
        guard isEnglishOnlyModel(modelPath: modelPath, isMultilingual: isMultilingual) else { return nil }

        // The transcript is the whole of the evidence, so no text — or text the
        // heuristic cannot place — is not a conflict. Neither is a transcript of
        // fewer than `languageConflictMinimumWords` words: at one and two words
        // the heuristic is wrong about as often as it is right, and a refusal it
        // gets wrong is an English dictation being told it is Polish.
        guard let transcript, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              contentWords(of: transcript).count >= languageConflictMinimumWords,
              let detected = LanguageDetector.detect(transcript).languageCode,
              detected != "en" else {
            return nil
        }

        let remedy = installedMultilingualModel(in: modelsDirectory, fileManager: fileManager)
        let modelName = modelPath
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            .flatMap { $0.isEmpty ? nil : $0 } ?? "The selected speech model"

        return SpeechLanguageConflict(
            modelName: modelName,
            detectedLanguageCode: detected,
            detectedLanguageName: LanguageUtil.languageNames[detected] ?? detected,
            remedyModelName: remedy?.lastPathComponent,
            remedyModelPath: remedy?.path
        )
    }

    /// The refusal for a transcript produced from audio with no speech in it, or
    /// `nil` when the audio held speech — and, just as important, when nothing
    /// measured either way.
    ///
    /// Only evidence refuses. The VAD finding no speech segment is evidence on
    /// its own; a measured no-speech probability is evidence against the user's
    /// own `noSpeechThreshold`, the same line whisper is handed
    /// (`params.no_speech_thold`). `nil` — an engine that measures nothing, a
    /// call site that does not populate it — is not evidence, so the transcript
    /// goes on to the language gate exactly as it did before.
    static func noSpeechConflict(
        presence: SpeechPresence?,
        noSpeechThreshold: Double,
        modelPath: String? = nil
    ) -> SpeechPresenceConflict? {
        guard let presence else { return nil }

        // Speech was there and the measurement is under the user's own line:
        // whatever produced this text, it was not silence.
        if case .measured(let meanNoSpeechProbability) = presence,
           meanNoSpeechProbability < noSpeechThreshold {
            return nil
        }

        let modelName = modelPath
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            .flatMap { $0.isEmpty ? nil : $0 } ?? "The selected speech model"

        return SpeechPresenceConflict(
            modelName: modelName,
            presence: presence,
            noSpeechThreshold: noSpeechThreshold
        )
    }

    /// The refusal for a transcript a second reading of the same audio does not
    /// contain, or `nil` when it does — and, just as important, when there is no
    /// second reading, when either side is too short to judge, or when the text
    /// is not made of whitespace-separated words at all.
    ///
    /// **The comparison, and the numbers behind it.** Two populations had to be
    /// told apart, and both were measured, on the captain's own recordings
    /// (`~/Library/Application Support/ru.starmel.OpenSuperWhisper/recordings/`,
    /// read-only) and on the repo's own fixtures, through the vendored
    /// whisper.cpp the app links, on 2026-09-28:
    ///
    /// * **Two legitimate readings agree.** Through the app's own decode path,
    ///   with the multilingual model on that machine, the second reading of his
    ///   speech contains **100%** of the first reading's words on six of eight
    ///   judged recordings, **96.1%** on the 51-word English one and **82.6%**
    ///   on the 23-word English one — the worst legitimate reading measured, 4
    ///   words missing. Under seven configurations of the same audio (greedy,
    ///   sampling, beam search, no temperature fallback, the un-trimmed VAD
    ///   path, a prompt in the wrong language, the app's own prompt) his Polish
    ///   agrees word for word: 35 pairs, no word lost. The long English fixture
    ///   (280 words) lands between them at 98.6%.
    /// * **An invented reading is not reproducible.** `ggml-tiny.en.bin` writing
    ///   English over that same Polish speech shares **0%** of its words with the
    ///   second reading on four of the five recordings and **50%** on the fifth
    ///   (the 2.4 s one, where it writes "This is today." twice in a row). The
    ///   two hallucinations the app actually stored for him — "I'll see you
    ///   later. Bye!" and "I'm not going to say that…" — share 0% with what the
    ///   same audio reads as today.
    ///
    /// So the floor is **0.7**, the middle of the measured gap: a refusal needs
    /// the second reading to hold fewer than 70% of the transcript's words,
    /// which leaves **12.6 points** of room above the worst legitimate reading
    /// measured and **20 points** below the closest invention. On his own
    /// recordings the measured false-refusal rate is **0 of 8 judged readings**
    /// (and 0 of the 35 legitimate pairs), so his dictation is not refused by
    /// this rule; every invention measured is refused by it.
    ///
    /// **The second condition is the short-text guard.** A ratio alone would
    /// refuse a three-word dictation that lost one word to a comma, so a
    /// refusal also needs at least `corroborationMissingWords` words to be
    /// missing: a short reading is not judged on a ratio it cannot support. And
    /// a transcript whose words cannot be split at all — Chinese, Japanese and
    /// Korean write without spaces, so one line is one word — never reaches the
    /// missing-word floor and is never refused by this rule.
    static func corroborationConflict(
        transcript: String?,
        secondReading: String?,
        modelPath: String? = nil
    ) -> SpeechCorroborationConflict? {
        guard let measurement = corroboration(of: transcript, in: secondReading),
              measurement.missing >= corroborationMissingWords,
              measurement.ratio < corroborationFloor else { return nil }

        let modelName = modelPath
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            .flatMap { $0.isEmpty ? nil : $0 } ?? "The selected speech model"

        return SpeechCorroborationConflict(
            modelName: modelName,
            transcriptWordCount: measurement.words,
            corroboratedWordCount: measurement.corroborated
        )
    }

    /// What a second reading contains of a transcript: how many of the
    /// transcript's words it has, out of how many the transcript is made of.
    /// The refusal is decided on this and nothing else, and it is what a
    /// measurement of the layer reports, so one run says both what happened and
    /// why.
    ///
    /// `nil` is "nothing to measure": no transcript, no second reading, a
    /// transcript below `corroborationMinimumWords`, or a reading with no words
    /// in it at all.
    struct Corroboration: Equatable {
        /// How many words the transcript is made of.
        let words: Int
        /// How many of those words the second reading contains.
        let corroborated: Int

        var missing: Int { words - corroborated }
        var ratio: Double { words > 0 ? Double(corroborated) / Double(words) : 0 }
    }

    /// The measurement `corroborationConflict` decides on: the words of the
    /// transcript counted against the words of the second reading, as
    /// multisets, so a word read twice has to be in the second reading twice.
    static func corroboration(of transcript: String?, in secondReading: String?) -> Corroboration? {
        guard let transcript, let secondReading, !secondReading.isEmpty else { return nil }

        let words = contentWords(of: transcript)
        var pool: [String: Int] = [:]
        for word in contentWords(of: secondReading) {
            pool[word, default: 0] += 1
        }
        guard words.count >= corroborationMinimumWords, !pool.isEmpty else { return nil }

        var corroborated = 0
        for word in words where pool[word, default: 0] > 0 {
            pool[word, default: 0] -= 1
            corroborated += 1
        }
        return Corroboration(words: words.count, corroborated: corroborated)
    }

    /// Whether a transcript is long enough for a second reading to be evidence
    /// about it at all.
    ///
    /// The engine reads this *before* spending a second decode: under
    /// `corroborationMinimumWords` no refusal is possible, so the reading would
    /// cost the user a decode and change nothing.
    static func canBeCorroborated(_ transcript: String?) -> Bool {
        guard let transcript else { return false }
        return contentWords(of: transcript).count >= corroborationMinimumWords
    }

    /// The words a transcript is made of: case-folded, with punctuation as a
    /// separator and an apostrophe kept inside a word, so "don't" is one word
    /// rather than two — and with the `[1.2->3.4] ` prefix *Show Timestamps* puts
    /// in front of every line dropped, because those numbers are not words
    /// anyone spoke.
    ///
    /// This is the app's one answer to "how many words is this text", so the two
    /// rules built on it cannot disagree: the language conflict's
    /// `languageConflictMinimumWords` and the second reading's
    /// `corroborationFloor` both count with it.
    static func contentWords(of text: String) -> [String] {
        var words: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var content = Substring(line)
            if content.hasPrefix("["), let close = content.firstIndex(of: "]") {
                content = content[content.index(after: close)...]
            }
            var current = ""
            for character in content.lowercased() {
                if character.isLetter || character.isNumber {
                    current.append(character)
                } else if character == "'" || character == "’" {
                    current.append("'")
                } else if !current.isEmpty {
                    words.append(current)
                    current = ""
                }
            }
            if !current.isEmpty { words.append(current) }
        }
        return words
    }

    /// The share of the transcript's words the second reading has to contain,
    /// set in the measured gap between the two readings it has to tell apart:
    /// 82.6% for the worst legitimate reading measured (his own 23-word English
    /// dictation) and 50% for the closest invention, on the captain's own
    /// recordings — see `corroborationConflict`.
    static let corroborationFloor = 0.7

    /// How many words may be missing before the ratio is even considered, so a
    /// short dictation is not refused over one word.
    static let corroborationMissingWords = 3

    /// The shortest transcript this rule judges. Below it there is too little
    /// text for a missing word to be evidence of anything, and the engine takes
    /// no second reading.
    static let corroborationMinimumWords = 3

    /// Whether this model can only speak English.
    ///
    /// The loaded context is authoritative when there is one; the file name is
    /// the only signal for a model that is not loaded yet.
    static func isEnglishOnlyModel(modelPath: String?, isMultilingual: Bool?) -> Bool {
        if let isMultilingual { return !isMultilingual }
        guard let path = modelPath, !path.isEmpty else { return false }
        return isEnglishOnlyFileName(URL(fileURLWithPath: path).lastPathComponent)
    }

    /// `ggml-tiny.en.bin`, `ggml-base.en.bin`, `ggml-small.en-xyz.bin`: the
    /// naming whisper.cpp uses for the English-only family.
    static func isEnglishOnlyFileName(_ fileName: String) -> Bool {
        let name = fileName.lowercased()
        return name.hasSuffix(".en.bin") || name.contains(".en-")
    }

    /// A usable multilingual whisper model already on this machine, preferring
    /// the one the app recommends. The silero VAD model next to the weights is
    /// not a speech model and is skipped.
    static func installedMultilingualModel(
        in directory: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return nil }

        let candidates = entries.filter { url in
            let name = url.lastPathComponent.lowercased()
            guard name.hasSuffix(".bin") else { return false }
            guard !name.hasPrefix("ggml-silero") else { return false }
            return !isEnglishOnlyFileName(name)
        }

        if let preferred = candidates.first(where: {
            $0.lastPathComponent == preferredMultilingualModelName
        }) {
            return preferred
        }
        return candidates.sorted { $0.lastPathComponent < $1.lastPathComponent }.first
    }

    /// The model the dictation runs on: the resolved one, unless it can only
    /// speak English and a multilingual model is installed next to it.
    ///
    /// An English-only model is not merely worse at other languages — it cannot
    /// hear them at all. It has nothing to detect (its language is `en` by
    /// construction), so Polish speech comes back as fluent English that was
    /// never said, and no gate can catch that: the text *is* English. Where a
    /// multilingual model is already on this machine, running the dictation
    /// through it is the only way the speech can come back as what was said.
    /// Where only English-only models exist, the resolved path stands — and the
    /// conflict gate above still refuses the transcript and names the remedy.
    ///
    /// Nothing is written down: this answers which file a model is loaded from,
    /// and the user's own selection is used unchanged the moment it can hear
    /// the language.
    static func preferredDictationModelPath(
        over resolvedPath: String?,
        modelsDirectory: URL = WhisperModelManager.modelsDirectory,
        fileManager: FileManager = .default
    ) -> String? {
        guard isEnglishOnlyModel(modelPath: resolvedPath, isMultilingual: nil),
              let multilingual = installedMultilingualModel(in: modelsDirectory, fileManager: fileManager)
        else { return resolvedPath }
        return multilingual.path
    }
}

/// Applying the offered fix.
///
/// The user pressed the button, so the selection changes as a deliberate act —
/// the one thing this whole guard must never do on its own is change the model
/// behind the user's back.
@MainActor
enum SpeechLanguageRemedy {
    /// Selects a multilingual model and shows the Settings card it belongs to,
    /// so the user sees both what changed and where.
    static func useMultilingualModel(atPath path: String) {
        TranscriptionService.shared.reloadModel(with: path)
        NotificationCenter.default.post(name: .openSettings, object: nil)
    }
}
