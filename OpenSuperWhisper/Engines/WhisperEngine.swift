import Foundation
import AVFoundation
import CoreAudioTypes

private class ProgressContext {
    var onProgress: ((Float) -> Void)?
    /// The share of the bar this decode owns, e.g. 0.10–0.55 for the first
    /// decode and 0.55–0.95 for the second reading. whisper reports 0–100% of
    /// its own work; the callback maps that into this range, so a decode that is
    /// still running keeps the bar moving instead of leaving it parked.
    let progressStart: Float
    let progressEnd: Float
    private var _lastReportedProgress: Float = 0.0
    private let lock = NSLock()

    init(start: Float, end: Float) {
        progressStart = start
        progressEnd = end
    }

    var lastReportedProgress: Float {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _lastReportedProgress
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _lastReportedProgress = newValue
        }
    }
}

/// The progress callback whisper calls during a decode.
///
/// It has no captures — a C function pointer cannot have any — so the range it
/// maps into comes from the `ProgressContext` the params carry, and the same
/// callback serves every decode the engine runs.
private let decodeProgressCallback: @convention(c) (
    OpaquePointer?,
    OpaquePointer?,
    Int32,
    UnsafeMutableRawPointer?
) -> Void = { _, _, progressPercent, userData in
    guard let userData = userData else { return }
    let ctx = Unmanaged<ProgressContext>.fromOpaque(userData).takeUnretainedValue()
    let normalizedProgress = ctx.progressStart
        + (Float(progressPercent) / 100.0) * (ctx.progressEnd - ctx.progressStart)
    // Report every progress update for smooth animation
    if normalizedProgress > ctx.lastReportedProgress {
        ctx.lastReportedProgress = normalizedProgress
        DispatchQueue.main.async {
            ctx.onProgress?(normalizedProgress)
        }
    }
}

/// Thread-safe cancellation flag. Owned by the engine for its whole lifetime,
/// so the pointer passed into whisper's C callback can never dangle.
private final class AbortFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _isSet = false
    
    var isSet: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _isSet
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _isSet = newValue
        }
    }
}

class WhisperEngine: TranscriptionEngine {
    private enum AudioInput {
        case file(URL)
        case pcm([Float])
    }
    struct DecodedSegment: Equatable {
        let text: String
        /// Where this segment begins and ends in the audio the decoder heard, in
        /// centiseconds. The pair is what says whether a measured pause fell
        /// *between* two segments or inside one of them.
        let startTimeCentiseconds: Int64
        let endTimeCentiseconds: Int64
    }

    /// How the engine re-stitches the VAD speech segments it hands the decoder,
    /// and what it does with the pauses it measured while stitching.
    ///
    /// The pauses are the one thing the VAD measures that the transcript cannot
    /// recover afterwards: the decoder hears a recording in which every pause
    /// has been replaced by a fixed 0.1-second breath, so its sentence
    /// boundaries rest on prosody alone. That is enough in English and not in
    /// Polish, where the model's punctuation is markedly weaker — a pause comes
    /// back either as a fragment (`Jestem.`) or as nothing at all, and two
    /// thoughts arrive joined.
    ///
    /// `restored` gives the decoder the pause itself back (up to `maxPause`) and
    /// lets `sentenceThreshold` close a sentence the decoder still left open.
    /// `upstream` is the behaviour every build before this had, and it is what
    /// the switch being off means: a fixed 0.1 s of zeros everywhere, no
    /// terminator, no word touched.
    struct PauseBoundaryPolicy: Equatable {
        /// Longest real pause kept for the decoder, in seconds. Zero keeps no
        /// real pause at all, which is upstream's stitched silence.
        let maxPause: TimeInterval
        /// Shortest silence between two speech segments, in seconds, exactly as
        /// upstream stitches it.
        let minPause: TimeInterval
        /// A pause at least this long ends the sentence.
        let sentenceThreshold: TimeInterval
        /// How close to the end of a pause a decoder segment has to start to be
        /// treated as beginning at the pause. A segment that starts earlier than
        /// this decoded straight through the pause, so its own text already
        /// mixes both sides of it and no boundary is inserted there: half the
        /// threshold is wide enough for whisper's own timestamp granularity and
        /// still far inside the pause.
        let boundaryTolerance: TimeInterval
        /// Whether a pause may close the sentence in the assembled text.
        let closesSentence: Bool

        /// Upstream whisper.cpp's stitching: 0.1 s of zeros at every pause.
        static let upstream = PauseBoundaryPolicy(
            maxPause: 0,
            minPause: 0.1,
            sentenceThreshold: .infinity,
            boundaryTolerance: 0,
            closesSentence: false
        )

        /// The pause is kept and a long one ends the sentence.
        ///
        /// The threshold is measured, not chosen: on his two Polish recordings
        /// the pauses the VAD measured in the audio the decoder hears separate
        /// into 0.52 s and below (pauses he talks straight through — the largest
        /// is the one inside "…o to, że żeś | spieprzył po całości") and 0.74 s
        /// and above (the boundaries the decoder itself punctuates, and every
        /// pause in the second recording, which are 1.15 s or longer). 0.6 s sits
        /// inside that band: above every pause he talks across, below the first
        /// one he does not.
        static let restored = PauseBoundaryPolicy(
            maxPause: 0.8,
            minPause: 0.1,
            sentenceThreshold: 0.6,
            boundaryTolerance: 0.25,
            closesSentence: true
        )

        static func from(settings: Settings) -> PauseBoundaryPolicy {
            settings.longPausesEndSentences ? .restored : .upstream
        }
    }

    struct DetailedTranscription {
        let text: String
        let segments: [DecodedSegment]
        /// The language of this utterance, as reported by the engine for this
        /// very `whisper_full` call. `nil` when the engine has no signal.
        let language: String?
        /// Whether the audio this utterance came from held speech, as measured
        /// by the pass that produced it (see `SpeechPresence`): the VAD's
        /// verdict, or whisper's own `no_speech_prob` averaged over the segments
        /// it produced. `nil` is "not measured" — the gate fails open on it, so
        /// a caller that does not populate this refuses nothing.
        var speechPresence: SpeechPresence? = nil
        /// The same audio read a second time, with the decoder prompt decision
        /// flipped (`secondReadingPrompt`). This is the only evidence in the app
        /// that can tell a transcript apart from text the decoder wrote over the
        /// audio — see `SpeechModelLanguageGate.corroborationConflict` for the
        /// comparison and the numbers. `nil` is "not read twice": no prompt to
        /// flip to, a transcript too short to judge, a failed second decode — and
        /// no evidence never refuses.
        var secondReading: String? = nil
    }

    var engineName: String { "Whisper" }
    
    /// Silero VAD model shipped in the app bundle; always used to drop
    /// non-speech audio before the encoder (faster, no hallucinations on silence).
    static let vadModelPath = Bundle(for: WhisperEngine.self)
        .path(forResource: "ggml-silero-v5.1.2", ofType: "bin")
    
    private var context: MyWhisperContext?
    private var vadContext: MyWhisperVadContext?
    private let abortFlag = AbortFlag()
    private var progressContext: ProgressContext?
    
    var onProgressUpdate: ((Float) -> Void)?
    
    var isModelLoaded: Bool {
        context != nil
    }

    /// Whether the loaded model can hear more than English, or `nil` when no
    /// model is loaded — `whisper_is_multilingual()` can only answer for a
    /// context that exists. Read by `SpeechModelLanguageGate`, which refuses to
    /// keep a transcript an English-only model cannot possibly have heard.
    var isModelMultilingual: Bool? {
        context?.isMultilingual
    }

    var hasPreparedState: Bool { context?.hasState == true }

    func prepareForRecording() throws {
        guard let context else {
            throw TranscriptionError.contextInitializationFailed
        }
        if !context.hasState && !context.initState() {
            throw TranscriptionError.contextInitializationFailed
        }
    }
    
    private let modelPath: String?

    init(modelPath: String? = nil) {
        self.modelPath = modelPath ?? AppPreferences.shared.selectedWhisperModelPath ?? AppPreferences.shared.selectedModelPath
    }

    func unload() {
        context = nil
        vadContext = nil
    }

    func initialize() async throws {
        guard let modelPath = modelPath else {
            throw TranscriptionError.contextInitializationFailed
        }
        
        let params = WhisperContextParams()
        // Load the model without a decoding state: a fresh whisper_state is
        // created per transcription, so recordings can share the model weights
        // while keeping their decoding context (prompt_past) fully isolated.
        context = MyWhisperContext.initFromFileNoState(path: modelPath, params: params)
        
        guard context != nil else {
            throw TranscriptionError.contextInitializationFailed
        }

        guard let path = Self.vadModelPath,
              let vad = MyWhisperVadContext(modelPath: path) else {
            throw TranscriptionError.contextInitializationFailed
        }
        vadContext = vad
    }
    
    func transcribeAudio(url: URL, settings: Settings) async throws -> String {
        try await transcribeAudioDetailed(url: url, settings: settings).text
    }

    /// Internal detailed result used by long-form regression tests. Production
    /// callers keep receiving only the final text through TranscriptionEngine.
    func transcribeAudioDetailed(
        url: URL,
        settings: Settings
    ) async throws -> DetailedTranscription {
        try await transcribe(
            input: .file(url),
            settings: settings,
            pausePolicy: .from(settings: settings)
        )
    }

    /// Internal detailed result with the pause policy named explicitly instead
    /// of derived from the setting, so one measurement run can decode the same
    /// recording under each policy. Production reaches the same path through
    /// `transcribeAudioDetailed(url:settings:)`.
    func transcribeAudioDetailed(
        url: URL,
        settings: Settings,
        pausePolicy: PauseBoundaryPolicy
    ) async throws -> DetailedTranscription {
        try await transcribe(input: .file(url), settings: settings, pausePolicy: pausePolicy)
    }

    /// Detailed result for the PCM path, which is the hotkey dictation path:
    /// alongside the text it carries the language the decoder measured, which
    /// decides whether the transcript is toned, cleaned up or pasted as-is —
    /// and which model does that work.
    func transcribeSamplesDetailed(
        _ samples: [Float],
        settings: Settings
    ) async throws -> DetailedTranscription {
        try await transcribe(
            input: .pcm(samples),
            settings: settings,
            pausePolicy: .from(settings: settings)
        )
    }

    private func transcribe(
        input: AudioInput,
        settings: Settings,
        pausePolicy: PauseBoundaryPolicy
    ) async throws -> DetailedTranscription {
        try await withTaskCancellationHandler {
            try await performTranscription(input: input, settings: settings, pausePolicy: pausePolicy)
        } onCancel: { [abortFlag] in
            abortFlag.isSet = true
        }
    }

    private func performTranscription(
        input: AudioInput,
        settings: Settings,
        pausePolicy: PauseBoundaryPolicy
    ) async throws -> DetailedTranscription {
        try Task.checkCancellation()

        guard let context = context else {
            throw TranscriptionError.contextInitializationFailed
        }
        defer { context.freeState() }
        
        abortFlag.isSet = false
        try Task.checkCancellation()
        
        // Setup progress context for the first decode's share of the bar. The
        // second reading owns the rest (0.55–0.95) and reports it itself, so a
        // dictation that pays for two decodes shows two stretches of work
        // instead of one and a stall.
        progressContext = ProgressContext(start: 0.10, end: 0.55)
        progressContext?.onProgress = onProgressUpdate
        
        defer {
            progressContext = nil
        }
        
        // Notify conversion start (0-10% is conversion phase)
        onProgressUpdate?(0.05)
        
        let converted: [Float]
        switch input {
        case .pcm(let samples):
            guard !samples.isEmpty else { throw TranscriptionError.audioConversionFailed }
            converted = samples
        case .file(let url):
            guard let samples = try await convertAudioToPCM(
                fileURL: url,
                cancellationCheck: { [abortFlag] in abortFlag.isSet }
            ) else {
                if abortFlag.isSet || Task.isCancelled { throw CancellationError() }
                throw TranscriptionError.audioConversionFailed
            }
            converted = samples
        }
        
        // Conversion done, now processing
        onProgressUpdate?(0.10)

        try Task.checkCancellation()
        
        // VAD pre-filter. Off by default (Jev 1.13.0 ruling), on measurement:
        // the speech-only audio the filter builds drops whole phrases on quiet
        // recordings. One 8.69 s dictation kept 0.86 s of speech and came out
        // "See you later." where the same audio with the filter off reads "All
        // right, I gotta go home. See you later and keep up."; across the four
        // worst of the captain's own recordings the filter off recovered 35
        // words with 0 still missing, against 0 recovered and 35 still missing
        // with it on. A threshold of 0.15 recovered 29 of those 35, and
        // min-silence, min-speech, speech-pad and beam size changed almost
        // nothing, so the product exposes off/on only and the parameters stay
        // internal. (whisper_full_with_state has no built-in VAD path —
        // params.vad works only through whisper_full, which would share
        // decoding state.)
        let usesVAD = settings.useVAD
        let speechSegments = usesVAD ? try detectSpeech(in: converted) : nil
        try Task.checkCancellation()
        if abortFlag.isSet { throw CancellationError() }
        if let speechSegments, speechSegments.isEmpty {
            // The VAD found nothing to decode, so the decoder never runs. This
            // empty utterance still carries the one fact the gate refuses on —
            // there was no speech in the recording — instead of leaving a
            // transcript nobody said. With the filter off this verdict does not
            // exist and is not guessed at: the decoder runs, and the no-speech
            // probability it measures over its own segments is what the gate
            // above reads instead.
            return DetailedTranscription(
                text: "",
                segments: [],
                language: nil,
                speechPresence: .noSpeechSegment
            )
        }
        // Timestamps of the trimmed audio would not match the original file,
        // so trimming is applied only when timestamps are not requested. The
        // stitching is also the only place the pauses are still measurable:
        // the decoder gets `pauses` back so a pause the speaker actually left
        // can end the sentence instead of being flattened into a breath.
        // With the pre-filter off there is nothing to trim and nothing to
        // stitch: the decoder hears the recording itself.
        let stitched: StitchedAudio
        if let speechSegments, !settings.showTimestamps {
            stitched = Self.stitch(from: converted, segments: speechSegments, policy: pausePolicy)
        } else {
            stitched = StitchedAudio(samples: converted, pauses: [])
        }
        let samples = stitched.samples
        
        let nThreads = max(2, min(ProcessInfo.processInfo.activeProcessorCount, 8))

        // The decoder prompt this transcription sends. The user's own is one
        // string and always wins; when they have set none and the switch is on,
        // it is the default its language has (`Self.decoderPrompt`) — which is
        // why the language is measured here, before the decoder is handed
        // anything, and only when the prompt is actually going to be the
        // table's: a switch off stays upstream's audio byte for byte.
        // The default prompt exists to serve the pause machinery, and only the
        // pre-filter measures a pause: with it off there is no pause to serve, so
        // the detect-only language pass and the language's default prompt both
        // stay off with it. That is also what the measurement asks for — a
        // Polish prompt on VAD-stitched input cost words rather than gaining
        // them, and the language is never forced.
        let spokenLanguage = settings.initialPrompt.isEmpty
            && pausePolicy.closesSentence
            && !settings.showTimestamps
            && usesVAD
            ? try measureLanguage(of: samples, nThreads: nThreads)
            : nil
        var effectiveSettings = settings
        effectiveSettings.initialPrompt = Self.decoderPrompt(
            userPrompt: settings.initialPrompt,
            longPausesEndSentences: pausePolicy.closesSentence,
            showsTimestamps: settings.showTimestamps,
            spokenLanguage: spokenLanguage
        )

        let initialPromptTokenCount = effectiveSettings.initialPrompt.isEmpty
            ? 0
            : context.tokenCount(text: effectiveSettings.initialPrompt)
        var params = Self.makeFullParams(
            settings: effectiveSettings,
            nThreads: nThreads,
            modelTextContext: context.nTextCtx,
            initialPromptTokenCount: initialPromptTokenCount
        )
        
        typealias GGMLAbortCallback = @convention(c) (UnsafeMutableRawPointer?) -> Bool
        let abortCallback: GGMLAbortCallback = { userData in
            guard let userData = userData else { return false }
            return Unmanaged<AbortFlag>.fromOpaque(userData).takeUnretainedValue().isSet
        }
        
        // whisper reports 0-100% of its own decode, and the context carries the
        // share of the bar this one owns: see `decodeProgressCallback`.
        let progressContextPtr = Unmanaged.passUnretained(progressContext!).toOpaque()
        params.progressCallback = decodeProgressCallback
        params.progressCallbackUserData = progressContextPtr
        
        if settings.useBeamSearch {
            params.beamSearchBeamSize = Int32(settings.beamSize)
        }
        
        var cParams = params.toC()
        cParams.abort_callback = abortCallback
        cParams.abort_callback_user_data = Unmanaged.passUnretained(abortFlag).toOpaque()
        
        try Task.checkCancellation()
        
        // Fresh decoding state per recording: isolates prompt_past between
        // recordings (a hallucination on silence cannot poison the next one).
        try prepareForRecording()
        
        guard context.full(samples: samples, params: &cParams) else {
            if abortFlag.isSet || Task.isCancelled {
                throw CancellationError()
            }
            throw TranscriptionError.processingFailed
        }

        // Read the language immediately: it lives in the decoding state, which
        // `defer` frees when this function returns, and no later step may touch
        // that state first.
        let language = Self.reportedLanguage(context: context)
        
        try Task.checkCancellation()
        
        var segmentTexts: [String] = []
        var decodedSegments: [DecodedSegment] = []
        var noSpeechProbabilitySum: Float = 0
        let nSegments = context.fullNSegments
        segmentTexts.reserveCapacity(nSegments)
        decodedSegments.reserveCapacity(nSegments)
        
        for i in 0..<nSegments {
            if i % 5 == 0 {
                try Task.checkCancellation()
            }
            
            // Whisper's own answer to "was this segment speech at all", summed
            // as the segments are walked: the quantity lives in the decoding
            // state, which `defer` frees when this function returns. Every
            // segment the decoder produced counts, including one whose text did
            // not survive.
            noSpeechProbabilitySum += context.fullGetSegmentNoSpeechProb(iSegment: i)
            
            guard let segmentText = context.fullGetSegmentText(iSegment: i) else { continue }
            let segmentStart = context.fullGetSegmentT0(iSegment: i)
            let segmentEnd = context.fullGetSegmentT1(iSegment: i)
            decodedSegments.append(
                DecodedSegment(
                    text: segmentText,
                    startTimeCentiseconds: segmentStart,
                    endTimeCentiseconds: segmentEnd
                )
            )
            
            if settings.showTimestamps {
                segmentTexts.append(
                    String(format: "[%.1f->%.1f] ", Float(segmentStart) / 100.0, Float(segmentEnd) / 100.0)
                        + segmentText
                )
            } else {
                segmentTexts.append(segmentText)
            }
        }
        
        // A pause the speaker left is a boundary the decoder was free to
        // ignore: the segment that ended just before it gets a terminator when
        // the decoder's own text did not close the sentence.
        let sentenceBoundaries = Self.sentenceBoundaries(
            decodedStartsCentiseconds: decodedSegments.map(\.startTimeCentiseconds),
            decodedEndCentiseconds: decodedSegments.map(\.endTimeCentiseconds),
            pauses: stitched.pauses,
            policy: pausePolicy,
            terminator: Self.sentenceTerminator(forLanguage: language)
        )
        let cleanedText = Self.assembleSegmentTexts(
            segmentTexts,
            showTimestamps: settings.showTimestamps,
            sentenceBoundaries: sentenceBoundaries
        )
            .replacingOccurrences(of: "[MUSIC]", with: "")
            .replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        var processedText = cleanedText
        if settings.shouldApplyAsianAutocorrect(detectedLanguage: language, text: cleanedText),
           !cleanedText.isEmpty {
            processedText = AutocorrectWrapper.format(cleanedText)
        }
        
        // The comparative layer: the same audio, the same model, read once more
        // with the decoder prompt decision flipped. Everything the first decode
        // measured has been read out of its state by now, so the second reading
        // starts from a state of its own — see `takeSecondReading` for why this
        // costs a decode on every dictation and what it is evidence of.
        let secondReading = try takeSecondReading(
            of: samples,
            transcript: processedText,
            language: language,
            settings: settings,
            primaryPrompt: effectiveSettings.initialPrompt,
            nThreads: nThreads,
            abortCallback: abortCallback
        )
        if secondReading == nil {
            // No second reading runs (or it did and produced nothing usable): the
            // decoding is over, so the bar goes to the end of the range the
            // decodes own instead of resting at the first decode's share.
            onProgressUpdate?(0.95)
        }
        
        return DetailedTranscription(
            text: processedText,
            segments: decodedSegments,
            language: language,
            // The mean over the segments the decoder produced is the one number
            // the user's `noSpeechThreshold` can be held against — at or above
            // it, the transcript is the decoder writing over noise it mistook
            // for a voice. No segment at all means nothing was measured, and no
            // evidence never refuses.
            speechPresence: nSegments > 0
                ? .measured(meanNoSpeechProbability: Double(noSpeechProbabilitySum) / Double(nSegments))
                : nil,
            secondReading: secondReading
        )
    }

    /// The same audio read a second time with the decoder prompt decision
    /// flipped, or `nil` when there is no second reading to take.
    ///
    /// This is the one thing in the app that can tell a transcript from text the
    /// decoder *wrote* over the audio: the first two refusals read the text and
    /// the decoder's own speech measurement, and fluent English over Polish
    /// speech that really was there passes both. A reading is reproducible when
    /// it came from the audio and not from the text the decoder was handed, so
    /// the second reading changes exactly the prompt and nothing else — same
    /// model, same settings, the same audio the first decode heard, the state it
    /// left behind left behind entirely (`prompt_past` and all).
    ///
    /// `nil` — and the dictation goes on exactly as it did before this layer
    /// existed — when the transcript is too short to judge
    /// (`SpeechModelLanguageGate.canBeCorroborated`), when the flip lands on the
    /// same empty prompt (`secondReadingPrompt`), when the model is gone, and
    /// when the second decode itself fails. Cancellation is not one of those:
    /// it still cancels the dictation, the same way the first decode does.
    private func takeSecondReading(
        of samples: [Float],
        transcript: String,
        language: String?,
        settings: Settings,
        primaryPrompt: String,
        nThreads: Int,
        abortCallback: @escaping @convention(c) (UnsafeMutableRawPointer?) -> Bool
    ) throws -> String? {
        guard SpeechModelLanguageGate.canBeCorroborated(transcript) else { return nil }
        guard let context else { return nil }
        guard let prompt = Self.secondReadingPrompt(
            primaryPrompt: primaryPrompt,
            spokenLanguage: language,
            isMultilingual: context.isMultilingual
        ) else { return nil }

        var secondSettings = settings
        secondSettings.initialPrompt = prompt
        let promptTokenCount = prompt.isEmpty ? 0 : context.tokenCount(text: prompt)
        var params = Self.makeFullParams(
            settings: secondSettings,
            nThreads: nThreads,
            modelTextContext: context.nTextCtx,
            initialPromptTokenCount: promptTokenCount
        )
        // The second reading is a decode of its own, so it reports progress in
        // its own share of the bar (0.55–0.95). Without it the bar rested at the
        // first decode's end through a whole second pass, and nothing showed
        // that work was still going. The context is held by the engine, so the
        // pointer whisper keeps cannot dangle.
        let secondProgress = ProgressContext(start: 0.55, end: 0.95)
        secondProgress.onProgress = onProgressUpdate
        progressContext = secondProgress
        params.progressCallback = decodeProgressCallback
        params.progressCallbackUserData = Unmanaged.passUnretained(secondProgress).toOpaque()
        var cParams = params.toC()
        cParams.abort_callback = abortCallback
        cParams.abort_callback_user_data = Unmanaged.passUnretained(abortFlag).toOpaque()

        try Task.checkCancellation()

        // A state of its own: the first decode's carries its `prompt_past`, and a
        // second reading that inherited it would not be a second reading.
        context.freeState()
        guard context.initState() else { return nil }

        guard context.full(samples: samples, params: &cParams) else {
            if abortFlag.isSet || Task.isCancelled {
                throw CancellationError()
            }
            return nil
        }
        try Task.checkCancellation()

        var segmentTexts: [String] = []
        segmentTexts.reserveCapacity(context.fullNSegments)
        for i in 0..<context.fullNSegments {
            guard let segmentText = context.fullGetSegmentText(iSegment: i) else { continue }
            segmentTexts.append(segmentText)
        }
        context.freeState()

        // Assembled the way the transcript is, minus the pause terminators: the
        // comparison is about words, and the punctuation a boundary adds is not
        // one. Timestamp mode's `[t0->t1] ` prefixes are not added here either,
        // and `SpeechModelLanguageGate.contentWords` drops them from the
        // transcript's side so the two readings are read the same way.
        return Self.assembleSegmentTexts(segmentTexts, showTimestamps: false, sentenceBoundaries: .none)
            .replacingOccurrences(of: "[MUSIC]", with: "")
            .replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The decoder prompt the second reading is sent: the flip the comparison
    /// rests on, or `nil` when there is nothing to flip to.
    ///
    /// A decoder prompt is text the model was *given*, and this app has exactly
    /// two prompt decisions: the one the user's settings ask for, and the
    /// default `decoderPrompt` chooses by the language that was spoken. The
    /// second reading takes the other one:
    ///
    /// * the transcription sent a prompt — the user's own, or the language's
    ///   default — so the second reading sends **none**: upstream's audio, byte
    ///   for byte;
    /// * the transcription sent none, so the second reading sends the default
    ///   **for the language the decoder heard**. A model that cannot hear a
    ///   language is English by construction (the same inference
    ///   `SpeechModelLanguageGate` makes), and that branch is the one that
    ///   catches the failure this layer exists for: an English-only model writes
    ///   fluent English with no prompt at all, and reading the same audio with
    ///   the default prompt its own language has is what shows the text was not
    ///   in the recording.
    ///
    /// `nil` when the flip lands on the same empty prompt (a language the table
    /// has no default for): there is no second reading, and no reading the app
    /// does not have ever refuses.
    static func secondReadingPrompt(
        primaryPrompt: String,
        spokenLanguage: String?,
        isMultilingual: Bool
    ) -> String? {
        guard primaryPrompt.isEmpty else { return "" }
        let language = spokenLanguage ?? (isMultilingual ? nil : "en")
        guard let language else { return nil }
        let prompt = defaultDecoderPrompt(forLanguage: language)
        return prompt.isEmpty ? nil : prompt
    }

    /// The language of the audio, measured **before** the decoder is given
    /// anything.
    ///
    /// `whisper_full` normally learns the language inside the transcription, and
    /// that answer arrives after the decoder has already been conditioned on its
    /// prompt. whisper.cpp will instead read the language off the encoder and
    /// return without decoding a single token when `detectLanguage` is set
    /// (`libwhisper/whisper.cpp/src/whisper.cpp:6861`: `if (params.detect_language)
    /// { return 0; }`), which is the only way to know the language *before* the
    /// prompt is written. The price is one encoder pass over the audio the
    /// decoder would have encoded anyway, measured on the captain's own
    /// recordings in `WhisperPauseBoundaryPairingTests`
    /// (`testTheCostOfALanguagePrePass`).
    ///
    /// An English-only model needs no pass at all: it cannot be multilingual, so
    /// the language is `en` by construction — the same inference
    /// `SpeechModelLanguageGate` makes. The decoding state is left free either
    /// way, and `prepareForRecording()` builds the fresh one the transcription
    /// itself uses, so nothing of this pass reaches the transcript.
    private func measureLanguage(of samples: [Float], nThreads: Int) throws -> String? {
        guard let context else { return nil }
        guard context.isMultilingual else { return "en" }
        defer { context.freeState() }
        guard context.initState() else { throw TranscriptionError.contextInitializationFailed }

        var params = WhisperFullParams()
        params.strategy = .greedy
        params.nThreads = Int32(nThreads)
        // Detection only: whisper computes the mel, encodes, reads the language
        // and returns. Nothing in this pass is transcribed, and `noTimestamps`
        // stays at the engine's own setting so the mel and the encoder are the
        // same shape they will be in the transcription.
        params.detectLanguage = true
        var cParams = params.toC()
        try Task.checkCancellation()
        guard context.full(samples: samples, params: &cParams) else { return nil }
        try Task.checkCancellation()
        return Self.reportedLanguage(context: context)
    }

    /// The language of the utterance that was just decoded, measured inside the
    /// `whisper_full` call above.
    ///
    /// The app has no language setting any more, so the decoder is never
    /// conditioned on one: it is always asked to measure the language of the
    /// audio it just heard. Only a multilingual model can, and its verdict is
    /// read off the decoding state — a non-multilingual (`.en`) model cannot
    /// measure anything, so the answer is `nil` and the transcript text is used
    /// as the fallback signal instead.
    ///
    /// `params.detectLanguage` must stay `false`: setting it makes whisper.cpp
    /// return right after detection, without transcribing anything.
    private static func reportedLanguage(context: MyWhisperContext) -> String? {
        guard context.isMultilingual else { return nil }
        let languageId = context.fullLangId
        guard languageId >= 0 else { return nil }
        return MyWhisperContext.langStr(id: languageId)
    }

    /// Where a real pause fell between two decoder segments, and what closes a
    /// sentence in the language that was spoken.
    struct SentenceBoundaries: Equatable {
        /// Indices of the segments after which the speaker paused long enough
        /// for the pause to end the sentence.
        var afterSegment: Set<Int> = []
        /// `.` for the languages that write one, `。` for the ones that do not.
        var terminator: String = "."

        /// The decoder's own punctuation is all there is.
        static let none = SentenceBoundaries()
    }

    /// Whisper segments are decoder boundaries, not paragraph boundaries.
    /// Their text already contains the token-level whitespace needed between
    /// adjacent segments, so adding a newline (or an inferred space) changes
    /// the dictated text. Timestamp mode remains line-oriented for readability.
    ///
    /// `sentenceBoundaries` is the one addition to that rule, and it is not
    /// inferred from the text: it says where the audio itself paused long
    /// enough for the pause to be the end of a sentence, so a thought cannot
    /// run into the next one. No word is ever changed and no punctuation is
    /// added inside a sentence — the terminator only closes a sentence the
    /// decoder itself left open.
    static func assembleSegmentTexts(
        _ segments: [String],
        showTimestamps: Bool,
        sentenceBoundaries: SentenceBoundaries = .none
    ) -> String {
        guard !showTimestamps else { return segments.joined(separator: "\n") }
        guard !sentenceBoundaries.afterSegment.isEmpty else { return segments.joined() }

        var result = ""
        for (index, segment) in segments.enumerated() {
            result += segment
            guard sentenceBoundaries.afterSegment.contains(index) else { continue }
            result = closingSentence(
                result,
                terminator: sentenceBoundaries.terminator,
                before: index + 1 < segments.count ? segments[index + 1] : ""
            )
        }
        return result
    }

    /// `text` with a terminator inserted where the sentence the pause fell after
    /// ended, when the text did not already close it.
    ///
    /// The insertion goes at the last non-whitespace character, so a decoder
    /// segment that is nothing but whitespace cannot push the terminator away
    /// from the words in front of it.
    private static func closingSentence(
        _ text: String,
        terminator: String,
        before next: String
    ) -> String {
        guard let contentEnd = text.lastIndex(where: { !$0.isWhitespace })
            .map({ text.index(after: $0) }),
            !endsSentence(String(text[text.startIndex..<contentEnd]))
        else { return text }

        // The text's own trailing whitespace — or the next segment's leading one
        // — is the join the decoder chose. Add a space only when neither side has
        // one, so the terminator never lands beside a stray space.
        let hasTrailingWhitespace = text[contentEnd...].contains { $0.isWhitespace }
        let hasLeadingWhitespace = next.first.map { $0.isWhitespace } ?? false
        let suffix = hasTrailingWhitespace || hasLeadingWhitespace
            ? terminator
            : terminator + " "

        var closed = text
        closed.insert(contentsOf: suffix, at: contentEnd)
        return closed
    }

    /// Whether `text` already ends a sentence — `.` `!` `?` `…` and the full
    /// width forms, with any closing quote or bracket after them counted as
    /// part of the ending.
    static func endsSentence(_ text: String) -> Bool {
        let terminators: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
        let closers: Set<Character> = ["\"", "'", "”", "’", "»", ")", "]", "}"]

        for character in text.reversed() {
            if character.isWhitespace { continue }
            if closers.contains(character) { continue }
            return terminators.contains(character)
        }
        return false
    }

    // MARK: - The decoder prompt

    /// The decoder prompt a language gets when the user has set none.
    ///
    /// `initialPrompt` is one string and it belongs to the user; this is the
    /// *default* that stands in for it, and it is chosen **by the language that
    /// was spoken**, because a prompt that suits one language is wrong for
    /// another: the switch's English side needs one at all (with no prompt the
    /// switch on invents a fragment in the English control that the switch off
    /// does not produce), and a Polish prompt on English audio pulls the decode
    /// the wrong way.
    ///
    /// Only languages measured on the captain's own recordings have an entry. A
    /// language with no entry gets **no** prompt, which is byte for byte what
    /// this app sent before the table existed. The two entries and the reason
    /// they are these two strings and not others are in
    /// `WhisperPauseBoundaryPairingTests` and `fleet/data/fm-20260925-14/report.md`.
    static func defaultDecoderPrompt(forLanguage language: String?) -> String {
        switch language {
        case "pl": return polishDefaultDecoderPrompt
        case "en": return englishDefaultDecoderPrompt
        default: return ""
        }
    }

    /// Polish dictation with full stops and a question mark and **no commas**, in
    /// his own register.
    ///
    /// Which Polish string this is was measured, not picked for looks: the
    /// comma-heavy candidates and the English one all prime the decoder into
    /// joining `pl-1`'s two clauses with a comma — "…inną drogą**,** bo tu
    /// chodzi…" — which **trades away the very sentence boundary the switch exists
    /// to gain** (`pl-1`: `win-words:NO(drogą.) boundary:NO(2->2)`), while this
    /// one keeps it ("…inną drogą. Bo tu chodzi…", `boundary:yes(2->3)`) and keeps
    /// `pl-2`'s "Open Super Whisper" and "Dodałem" as well. The tables are in
    /// `WhisperPauseBoundaryPairingTests` and `fleet/data/fm-20260925-14/report.md`.
    static let polishDefaultDecoderPrompt =
        "Zrobiłem to wczoraj. Sprawdzę to jutro. Możesz na to spojrzeć? Nie ma problemu."

    /// The English counterpart, for English audio and for an English-only model:
    /// the same shape of ordinary dictation, and the arm whose English result is
    /// the `-how -sentence +now +sentences` the captain accepted on 2026-09-25.
    static let englishDefaultDecoderPrompt =
        "Okay, one more time: I sent the report on Monday, but Anna hasn't replied. Can you check?"

    /// The decoder prompt one transcription sends.
    ///
    /// The rule, in full, and the reason each clause is there:
    ///
    /// * **The user's own prompt always wins, in any language and on any
    ///   switch.** A value the user set is a decision, and this app must not
    ///   second-guess it — not with the table above, not with the language.
    /// * **A switch off sends no default.** Off is upstream's audio byte for
    ///   byte, and the prompt exists to serve the switch; without this clause an
    ///   install that never turned the switch on would get a file that changed
    ///   for no measured reason.
    /// * **A switch on with no prompt of their own sends the default for the
    ///   language spoken**, or nothing at all when that language has no entry.
    /// * **Timestamp mode sends no default either.** With *Show Timestamps* on,
    ///   the decoder is handed the untrimmed audio and no pause is measured
    ///   (`performTranscription`), so the switch has nothing to serve there and a
    ///   prompt would be a decode change with no measured benefit attached.
    static func decoderPrompt(
        userPrompt: String,
        longPausesEndSentences: Bool,
        showsTimestamps: Bool,
        spokenLanguage: String?
    ) -> String {
        guard userPrompt.isEmpty, longPausesEndSentences, !showsTimestamps else { return userPrompt }
        return defaultDecoderPrompt(forLanguage: spokenLanguage)
    }

    /// The terminator the spoken language writes. Chinese, Japanese and Korean
    /// end a sentence with `。`; every other language whisper can transcribe
    /// uses `.`, and a language the engine could not measure gets `.` too.
    static func sentenceTerminator(forLanguage language: String?) -> String {
        guard let language, Settings.asianLanguages.contains(language) else { return "." }
        return "。"
    }

    /// Which decoder segments have a speaker's pause after them.
    ///
    /// The decoder's timestamps are read in the audio it was handed, so a pause
    /// belongs after the last segment that ended before the pause did — and only
    /// when the next segment really starts at the pause. A decoder segment that
    /// *starts* before the pause ends decoded straight through the pause: both
    /// sides of it are already inside that one segment's text, and where in that
    /// text the boundary belongs is not something the audio can say, so nothing
    /// is inserted there. A pause with no segment after it can close nothing
    /// either.
    static func pauseJunctions(
        decodedStartsCentiseconds: [Int64],
        decodedEndCentiseconds: [Int64],
        pauses: [StitchedPause],
        threshold: TimeInterval,
        tolerance: TimeInterval
    ) -> [Int] {
        guard !decodedEndCentiseconds.isEmpty else { return [] }

        let toleranceCs = Int64((tolerance * 100).rounded())
        var junctions: Set<Int> = []
        for pause in pauses where pause.seconds >= threshold {
            guard let index = decodedEndCentiseconds.lastIndex(where: { $0 <= pause.endCentiseconds }),
                  index + 1 < decodedEndCentiseconds.count,
                  index + 1 < decodedStartsCentiseconds.count,
                  decodedStartsCentiseconds[index + 1] >= pause.endCentiseconds - toleranceCs
            else { continue }
            junctions.insert(index)
        }
        return junctions.sorted()
    }

    /// The boundaries a policy asks the assembly for.
    static func sentenceBoundaries(
        decodedStartsCentiseconds: [Int64],
        decodedEndCentiseconds: [Int64],
        pauses: [StitchedPause],
        policy: PauseBoundaryPolicy,
        terminator: String
    ) -> SentenceBoundaries {
        guard policy.closesSentence else { return .none }

        let junctions = pauseJunctions(
            decodedStartsCentiseconds: decodedStartsCentiseconds,
            decodedEndCentiseconds: decodedEndCentiseconds,
            pauses: pauses,
            threshold: policy.sentenceThreshold,
            tolerance: policy.boundaryTolerance
        )
        guard !junctions.isEmpty else { return .none }
        return SentenceBoundaries(afterSegment: Set(junctions), terminator: terminator)
    }

    static func makeFullParams(
        settings: Settings,
        nThreads: Int,
        modelTextContext: Int,
        initialPromptTokenCount: Int
    ) -> WhisperFullParams {
        var params = WhisperFullParams()
        params.strategy = settings.useBeamSearch ? .beamSearch : .greedy
        params.nThreads = Int32(nThreads)
        // Match whisper.cpp defaults: on temperature fallback the decoder samples
        // best_of candidates and keeps the most probable one; with 1 the fallback
        // degenerates to a single random sample on hard audio.
        params.greedyBestOf = 5

        // A fresh state isolates recordings, while prompt_past must remain enabled
        // between the decoder's 30-second windows inside this recording.
        params.noContext = false
        // Advanced → Debug Options. whisper.cpp prints its verbose decode trace
        // to stdout when this is on; without it the toggle was inert.
        params.debugMode = settings.debugMode
        let rollingContextCapacity = max(1, modelTextContext / 2)
        params.nMaxTextCtx = Int32(clamping: rollingContextCapacity)
        // The decoder keeps producing timestamps even when the transcript does
        // not show them, and `showTimestamps` only decides the "[t0->t1] "
        // prefixes added below. whisper.cpp's long-form loop cannot tell how far
        // a window actually got without timestamp tokens: in no-timestamps mode
        // it advances `seek` by a whole 30-second chunk as soon as the decoder
        // ends the window (whisper.cpp: "if (params.single_segment ||
        // params.no_timestamps) { result_len = i + 1; seek_delta =
        // 100*WHISPER_CHUNK_SIZE; }"). A window the model finished early then
        // takes the rest of its audio with it - with large-v3-turbo the second
        // window of long_en decoded only its last sentence, and long_ru lost
        // "Первая контрольная фраза" at the 30-second seam and "по-прежнему" at
        // the 60-second one. With timestamps the seek follows the audio the
        // decoder really covered, so no speech is skipped.
        params.noTimestamps = false
        params.suppressBlank = settings.suppressBlankAudio
        // The pre-filter decision travels with the parameters so the exposure
        // test can see it. The engine reads the same setting itself, because the
        // VAD call happens before these parameters exist.
        params.vad = settings.useVAD
        params.vadParams = Self.vadParams
        // The language is never set: the app always lets the model detect it,
        // and nothing in the product may condition the decoder on a chosen
        // language. `detectLanguage` stays false as it must — setting it makes
        // whisper.cpp return right after detection, without transcribing.
        params.language = nil
        params.detectLanguage = false
        params.temperature = Float(settings.temperature)
        params.noSpeechThold = Float(settings.noSpeechThreshold)
        params.initialPrompt = settings.initialPrompt.isEmpty
            ? nil
            : settings.initialPrompt

        // A very long static prompt can otherwise consume the entire prompt
        // budget on every window and evict prompt_past. Carry it only while at
        // least half of the rolling budget remains available for prior speech.
        let maxCarriedPromptTokens = max(1, (rollingContextCapacity - 1) / 2)
        params.carryInitialPrompt = params.initialPrompt != nil
            && initialPromptTokenCount <= maxCarriedPromptTokens
        return params
    }
    
    func cancelTranscription() {
        abortFlag.isSet = true
    }
    
    // MARK: - VAD
    
    private func detectSpeech(in samples: [Float]) throws -> [WhisperVadSegment] {
        guard let vadContext else {
            throw TranscriptionError.contextInitializationFailed
        }
        guard let segments = vadContext.speechSegments(in: samples, params: Self.vadParams) else {
            throw TranscriptionError.processingFailed
        }
        return segments
    }

    /// The parameters the silero pre-filter runs with while `settings.useVAD` is
    /// on. Internal on purpose: no threshold beat turning the filter off, so the
    /// product exposes off/on and nothing else (see `WhisperVadParams`).
    static let vadParams = WhisperVadParams()
    
    /// Keeps only speech, mirroring upstream whisper_full VAD stitching:
    /// each segment (already padded by the VAD) gets 0.1s of the following
    /// audio as overlap and segments are separated by 0.1s of silence, so the
    /// decoder still sees natural pauses between phrases.
    ///
    /// This is the upstream behaviour, and it is what the policy asks for when
    /// `longPausesEndSentences` is off. The switch-on path is `stitch`, which
    /// keeps the pause the speaker actually left.
    static func speechOnlySamples(from samples: [Float], segments: [WhisperVadSegment]) -> [Float] {
        stitch(from: samples, segments: segments, policy: .upstream).samples
    }

    /// The audio the decoder hears, plus the pauses that were still measurable
    /// when it was assembled.
    struct StitchedAudio: Equatable {
        let samples: [Float]
        /// One entry per pause between two retained speech segments, in the
        /// order they occur.
        let pauses: [StitchedPause]
    }

    /// A pause the VAD found between two speech segments.
    struct StitchedPause: Equatable {
        /// The silence the decoder was given none of: the VAD's gap between the
        /// two segments less the 0.1 s overlap upstream already carries into the
        /// next segment. This is the quantity `maxPause` caps and
        /// `sentenceThreshold` is compared against.
        let seconds: TimeInterval
        /// Where the pause sits in the audio the decoder hears, in centiseconds
        /// — the clock the decoder's own segment timestamps use.
        let startCentiseconds: Int64
        let endCentiseconds: Int64
    }

    /// Rebuilds the speech-only audio the decoder is handed, and measures the
    /// pauses on the way through.
    ///
    /// Upstream replaces every pause with a fixed 0.1 s of zeros, which is a
    /// breath: the decoder then has prosody and nothing else to decide sentence
    /// boundaries from, and that is enough in English and not in Polish. Under
    /// `policy` the pause itself is kept, up to its cap, so the decoder can hear
    /// silence that is really there; `pauses` carries the measurements out so
    /// the assembled text can close a sentence the decoder still left open.
    static func stitch(
        from samples: [Float],
        segments: [WhisperVadSegment],
        policy: PauseBoundaryPolicy = .upstream
    ) -> StitchedAudio {
        let samplesPerCs = 160 // 16 kHz / 100
        let overlapSamples = 1600 // 0.1 s
        let minPauseSamples = Int((policy.minPause * 16000).rounded())
        let maxPauseSamples = Int((policy.maxPause * 16000).rounded())

        var result = [Float]()
        var pauses = [StitchedPause]()
        for (index, segment) in segments.enumerated() {
            let start = min(max(0, Int(segment.startCs) * samplesPerCs), samples.count)
            var end = min(Int(segment.endCs) * samplesPerCs, samples.count)
            if index < segments.count - 1 {
                end = min(end + overlapSamples, samples.count)
            }
            guard end > start else { continue }

            if index > 0 {
                // The silence between the speech the decoder already has and the
                // speech that starts here, minus the 0.1 s overlap both sides
                // carry into each other.
                let gapStart = max(
                    0,
                    min(Int(segments[index - 1].endCs) * samplesPerCs + overlapSamples, start)
                )
                let kept = min(start - gapStart, maxPauseSamples)
                let pauseStartCs = Int64(result.count / samplesPerCs)
                // Zeros only ever pad a short pause up to upstream's minimum; a
                // longer pause is the speaker's own silence, never a synthetic
                // block the decoder could latch onto.
                result.append(contentsOf: repeatElement(0, count: max(0, minPauseSamples - kept)))
                if kept > 0 {
                    result.append(contentsOf: samples[(start - kept)..<start])
                }
                pauses.append(
                    StitchedPause(
                        seconds: Double(start - gapStart) / 16000,
                        startCentiseconds: pauseStartCs,
                        endCentiseconds: Int64(result.count / samplesPerCs)
                    )
                )
            }

            result.append(contentsOf: samples[start..<end])
        }
        return StitchedAudio(samples: result, pauses: pauses)
    }
    
    func getSupportedLanguages() -> [String] {
        return LanguageUtil.availableLanguages
    }
    
    private nonisolated func resolveFileURL(_ fileURL: URL) throws -> (URL, Bool) {
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        guard data.count >= 12 else { return (fileURL, false) }

        let ext = fileURL.pathExtension.lowercased()

        let isMP4Header = data[4...7].elementsEqual([0x66, 0x74, 0x79, 0x70]) // "ftyp"
        if isMP4Header && ext != "m4a" && ext != "mp4" && ext != "m4b" && ext != "aac" {
            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("m4a")
            try FileManager.default.copyItem(at: fileURL, to: tmpURL)
            return (tmpURL, true)
        }

        return (fileURL, false)
    }

    nonisolated func convertAudioToPCM(
        fileURL: URL,
        cancellationCheck: @escaping () -> Bool = { false }
    ) async throws -> [Float]? {
        return try await Task.detached(priority: .userInitiated) {
            if cancellationCheck() { throw CancellationError() }
            let (resolvedURL, isTempFile) = try self.resolveFileURL(fileURL)
            defer {
                if isTempFile { try? FileManager.default.removeItem(at: resolvedURL) }
            }
            let audioFile = try AVAudioFile(forReading: resolvedURL)
            let sourceFormat = audioFile.processingFormat
            let totalFrames = audioFile.length
            if cancellationCheck() { throw CancellationError() }
            
            guard let targetFormat = self.makeTargetFormat(channelCount: sourceFormat.channelCount) else {
                return nil
            }
            
            let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
            
            // Use parallel processing for large files (> 10 seconds of audio)
            // Benchmarked: 4 cores = +339%, 8 cores = +609% improvement
            let minFramesForParallel = AVAudioFramePosition(sourceFormat.sampleRate * 10)
            let workerCount = totalFrames > minFramesForParallel ? ProcessInfo.processInfo.activeProcessorCount : 1
            
            if workerCount == 1 {
                let result = try self.convertSegment(
                    fileURL: resolvedURL,
                    sourceFormat: sourceFormat,
                    targetFormat: targetFormat,
                    ratio: ratio,
                    startFrame: 0,
                    frameCount: totalFrames,
                    inputChunkSize: 1_048_576,
                    cancellationCheck: cancellationCheck
                )
                return result.isEmpty ? nil : result
            }
            
            // Parallel processing: each worker converts its own frame range with an
            // independent converter (flushed at the end), results are concatenated in
            // worker order so no samples are lost or overwritten at boundaries.
            let framesPerWorker = totalFrames / AVAudioFramePosition(workerCount)
            var segmentResults = [[Float]?](repeating: nil, count: workerCount)
            let resultLock = NSLock()
            
            let group = DispatchGroup()
            let queue = DispatchQueue(label: "audio.conversion.parallel", attributes: .concurrent)
            
            for workerIndex in 0..<workerCount {
                group.enter()
                queue.async {
                    defer { group.leave() }
                    
                    let startFrame = AVAudioFramePosition(workerIndex) * framesPerWorker
                    let endFrame = workerIndex == workerCount - 1 ? totalFrames : startFrame + framesPerWorker
                    
                    let segment = try? self.convertSegment(
                        fileURL: resolvedURL,
                        sourceFormat: sourceFormat,
                        targetFormat: targetFormat,
                        ratio: ratio,
                        startFrame: startFrame,
                        frameCount: endFrame - startFrame,
                        inputChunkSize: 262_144,
                        cancellationCheck: cancellationCheck
                    )
                    
                    resultLock.lock()
                    segmentResults[workerIndex] = segment
                    resultLock.unlock()
                }
            }
            
            group.wait()

            if cancellationCheck() { throw CancellationError() }
            
            guard !segmentResults.contains(where: { $0 == nil }) else { return nil }
            
            // Release each segment right after it is appended, so the peak stays
            // near 1x of the total instead of holding both copies until the end.
            var result = [Float]()
            result.reserveCapacity(segmentResults.reduce(0) { $0 + ($1?.count ?? 0) })
            for index in segmentResults.indices {
                if cancellationCheck() { throw CancellationError() }
                result.append(contentsOf: segmentResults[index]!)
                segmentResults[index] = nil
            }
            
            return result.isEmpty ? nil : result
        }.value
    }
    
    nonisolated func convertSegment(
        fileURL: URL,
        sourceFormat: AVAudioFormat,
        targetFormat: AVAudioFormat,
        ratio: Double,
        startFrame: AVAudioFramePosition,
        frameCount: AVAudioFramePosition,
        inputChunkSize: AVAudioFrameCount,
        cancellationCheck: @escaping () -> Bool
    ) throws -> [Float] {
        if cancellationCheck() { throw CancellationError() }
        let audioFile = try AVAudioFile(forReading: fileURL)
        audioFile.framePosition = startFrame
        
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw TranscriptionError.audioConversionFailed
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        
        // Buffers hold Float32 per channel, so cap the chunk by bytes: a chunk sized
        // in frames alone balloons for multi-channel sources (8ch = 32 MB per buffer).
        let maxChunkBytes = 8 * 1024 * 1024
        let bytesPerFrame = Int(sourceFormat.channelCount) * MemoryLayout<Float>.size
        let chunkFrames = min(inputChunkSize, AVAudioFrameCount(max(maxChunkBytes / bytesPerFrame, 65536)))
        
        let outputChunkSize = AVAudioFrameCount(Double(chunkFrames) * ratio) + 256
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: chunkFrames),
              let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputChunkSize) else {
            throw TranscriptionError.audioConversionFailed
        }
        
        var result = [Float]()
        result.reserveCapacity(Int(Double(frameCount) * ratio) + 256)
        
        var framesRead: AVAudioFramePosition = 0
        
        while framesRead < frameCount {
            if cancellationCheck() { throw CancellationError() }
            let framesToRead = min(AVAudioFrameCount(frameCount - framesRead), chunkFrames)
            inputBuffer.frameLength = 0
            try audioFile.read(into: inputBuffer, frameCount: framesToRead)
            
            if inputBuffer.frameLength == 0 { break }
            framesRead += AVAudioFramePosition(inputBuffer.frameLength)
            
            var inputConsumed = false
            var convError: NSError?
            
            outputBuffer.frameLength = 0
            converter.convert(to: outputBuffer, error: &convError) { _, outStatus in
                if inputConsumed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                inputConsumed = true
                outStatus.pointee = .haveData
                return inputBuffer
            }
            
            if let convError = convError {
                throw convError
            }
            
            appendMixedSamples(from: outputBuffer, to: &result)
        }
        
        // Flush the resampler: without an .endOfStream pass its internal latency
        // (the last few milliseconds of audio) is silently dropped.
        var status = AVAudioConverterOutputStatus.haveData
        while status == .haveData {
            if cancellationCheck() { throw CancellationError() }
            var convError: NSError?
            outputBuffer.frameLength = 0
            status = converter.convert(to: outputBuffer, error: &convError) { _, outStatus in
                outStatus.pointee = .endOfStream
                return nil
            }
            if convError != nil { break }
            appendMixedSamples(from: outputBuffer, to: &result)
        }
        
        return result
    }
    
    private nonisolated func appendMixedSamples(from buffer: AVAudioPCMBuffer, to output: inout [Float]) {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0, let channelData = buffer.floatChannelData else { return }
        
        let channelCount = Int(buffer.format.channelCount)
        if channelCount == 1 {
            let mono = UnsafeBufferPointer(start: channelData[0], count: frameCount)
            output.append(contentsOf: mono)
            return
        }
        
        let activityThreshold: Float = 0.0001
        var activeChannels: [Int] = []
        activeChannels.reserveCapacity(channelCount)
        
        for channel in 0..<channelCount {
            let channelSamples = UnsafeBufferPointer(start: channelData[channel], count: frameCount)
            var energy: Float = 0
            for sample in channelSamples {
                energy += sample * sample
            }
            let rms = sqrtf(energy / Float(frameCount))
            if rms > activityThreshold {
                activeChannels.append(channel)
            }
        }
        
        if activeChannels.isEmpty {
            activeChannels = Array(0..<channelCount)
        }
        
        let normalization = 1.0 / Float(activeChannels.count)
        output.reserveCapacity(output.count + frameCount)
        
        for frame in 0..<frameCount {
            var mixed: Float = 0
            for channel in activeChannels {
                mixed += channelData[channel][frame]
            }
            output.append(mixed * normalization)
        }
    }
    
    nonisolated func makeTargetFormat(channelCount: AVAudioChannelCount) -> AVAudioFormat? {
        guard channelCount > 0 else { return nil }
        
        let layoutTag = AudioChannelLayoutTag(kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channelCount))
        guard let channelLayout = AVAudioChannelLayout(layoutTag: layoutTag) else { return nil }
        
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            interleaved: false,
            channelLayout: channelLayout
        )
    }
}
