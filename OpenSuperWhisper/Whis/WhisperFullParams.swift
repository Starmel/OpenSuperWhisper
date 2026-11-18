//
// Created by user on 07.02.2025.
//

import Foundation

/// The silero VAD's parameters, mirroring `whisper_vad_params`.
///
/// The VAD is the engine's own pre-filter (`WhisperEngine.detectSpeech`), not
/// whisper_full's built-in `params.vad` path, so its parameters go to
/// `whisper_vad_segments_from_samples` directly instead of through
/// `whisper_full_params`.
///
/// A default-constructed value is byte for byte what the engine used to call
/// implicitly: every field is read from `whisper_vad_default_params()`, so this
/// type cannot drift from upstream's defaults. The values stay internal — what
/// the product exposes is only whether the pre-filter runs at all
/// (`WhisperFullParams.vad`), because the measurement found no threshold that
/// beats switching it off:
///
/// * VAD off recovered 35 words with 0 still missing across the four worst
///   dictations; today's defaults recovered 0 and still missed 35.
/// * A threshold of 0.15 recovered 29 of those 35 and still missed 8.
/// * Min-silence (0.5 s, 1.0 s), min-speech and speech-pad changed almost
///   nothing (5–6 of 35), and part of what they recovered was invention.
public struct WhisperVadParams {
    /// Probability threshold to consider as speech.
    public var threshold: Float
    /// Min duration for a valid speech segment.
    public var minSpeechDurationMs: Int32
    /// Min silence duration to consider speech as ended.
    public var minSilenceDurationMs: Int32
    /// Max duration of a speech segment before forcing a new segment.
    public var maxSpeechDurationS: Float
    /// Padding added before and after speech segments.
    public var speechPadMs: Int32
    /// Overlap in seconds when copying audio samples from speech segment.
    public var samplesOverlap: Float

    public init() {
        let defaults = whisper_vad_default_params()
        threshold = defaults.threshold
        minSpeechDurationMs = defaults.min_speech_duration_ms
        minSilenceDurationMs = defaults.min_silence_duration_ms
        maxSpeechDurationS = defaults.max_speech_duration_s
        speechPadMs = defaults.speech_pad_ms
        samplesOverlap = defaults.samples_overlap
    }

    public func toC() -> whisper_vad_params {
        var params = whisper_vad_params()
        params.threshold = threshold
        params.min_speech_duration_ms = minSpeechDurationMs
        params.min_silence_duration_ms = minSilenceDurationMs
        params.max_speech_duration_s = maxSpeechDurationS
        params.speech_pad_ms = speechPadMs
        params.samples_overlap = samplesOverlap
        return params
    }
}

public struct WhisperFullParams {
    public var strategy: WhisperSamplingStrategy = .greedy
    public var nThreads: Int32 = 1
    public var nMaxTextCtx: Int32 = 16384
    public var offsetMs: Int32 = 0
    public var durationMs: Int32 = 0
    public var translate: Bool = false
    public var noContext: Bool = true
    public var noTimestamps: Bool = false
    public var singleSegment: Bool = false
    public var printSpecial: Bool = false
    public var printProgress: Bool = false
    public var printRealtime: Bool = false
    public var printTimestamps: Bool = true
    public var tokenTimestamps: Bool = false
    public var tholdPt: Float = 0.01
    public var tholdPtsum: Float = 0.01
    public var maxLen: Int32 = 0
    public var splitOnWord: Bool = false
    public var maxTokens: Int32 = 0
    public var debugMode: Bool = false
    public var audioCtx: Int32 = 0
    public var tdrzEnable: Bool = false
    public var suppressRegex: String?
    public var initialPrompt: String?
    public var carryInitialPrompt: Bool = false
    public var promptTokens: [WhisperToken]?
    public var language: String?
    public var detectLanguage: Bool = false
    public var suppressBlank: Bool = true
    public var suppressNst: Bool = false
    public var temperature: Float = 0.0
    public var maxInitialTs: Float = 1.0
    public var lengthPenalty: Float = -1.0
    public var temperatureInc: Float = 0.2
    public var entropyThold: Float = 2.4
    public var logprobThold: Float = -1.0
    public var noSpeechThold: Float = 0.6
    public var greedyBestOf: Int32 = 1
    public var beamSearchBeamSize: Int32 = 1
    public var beamSearchPatience: Float = 0.0
    public var newSegmentCallback: (@convention(c) (OpaquePointer?, OpaquePointer?, Int32, UnsafeMutableRawPointer?) -> Void)?
    public var newSegmentCallbackUserData: UnsafeMutableRawPointer?
    public var progressCallback: (@convention(c) (OpaquePointer?, OpaquePointer?, Int32, UnsafeMutableRawPointer?) -> Void)?
    public var progressCallbackUserData: UnsafeMutableRawPointer?
    public var encoderBeginCallback: (@convention(c) (OpaquePointer?, OpaquePointer?, UnsafeMutableRawPointer?) -> Bool)?
    public var encoderBeginCallbackUserData: UnsafeMutableRawPointer?
    public var abortCallback: (@convention(c) (UnsafeMutableRawPointer?) -> Bool)?
    public var abortCallbackUserData: UnsafeMutableRawPointer?
    public var logitsFilterCallback: (@convention(c) (OpaquePointer?, OpaquePointer?, UnsafePointer<whisper_token_data>?, Int32, UnsafeMutablePointer<Float>?, UnsafeMutableRawPointer?) -> Void)?
    public var logitsFilterCallbackUserData: UnsafeMutableRawPointer?
    public var grammarRules: [UnsafePointer<whisper_grammar_element>?]?
    public var iStartRule: Int = 0
    public var grammarPenalty: Float = 0.0

    /// Whether the engine's own silero pre-filter runs before the decoder.
    ///
    /// This is **not** whisper_full's `params.vad`: that path only exists in
    /// `whisper_full`, which shares decoding state the engine must keep per
    /// recording, so the engine runs the VAD itself and stitches the speech back
    /// together. The flag therefore stays out of `toC()` on purpose — copy it
    /// into `whisper_full_params.vad` and the audio would be filtered twice.
    ///
    /// **Off by default**, on measurement: the speech-only audio the pre-filter
    /// builds dropped whole phrases on quiet recordings, and switching it off
    /// recovered 35 words with 0 still missing across the four worst of the
    /// captain's own dictations, against 0 recovered and 35 still missing with
    /// it on. See `WhisperVadParams` for the rest of the numbers, and
    /// `AppPreferences.useVAD` for where the setting comes from.
    public var vad: Bool = false

    /// The parameters the pre-filter is called with while `vad` is on. Internal:
    /// no threshold beat turning the pre-filter off, so none is exposed.
    public var vadParams: WhisperVadParams = WhisperVadParams()

    public init() {}

    mutating func toC() -> whisper_full_params {
        var cParams = whisper_full_params()

        cParams.strategy = whisper_sampling_strategy(rawValue: UInt32(strategy.rawValue))
        cParams.n_threads = nThreads
        cParams.n_max_text_ctx = nMaxTextCtx
        cParams.offset_ms = offsetMs
        cParams.duration_ms = durationMs
        cParams.translate = translate
        cParams.no_context = noContext
        cParams.no_timestamps = noTimestamps
        cParams.single_segment = singleSegment
        cParams.print_special = printSpecial
        cParams.print_progress = printProgress
        cParams.print_realtime = printRealtime
        cParams.print_timestamps = printTimestamps
        cParams.token_timestamps = tokenTimestamps
        cParams.thold_pt = tholdPt
        cParams.thold_ptsum = tholdPtsum
        cParams.max_len = maxLen
        cParams.split_on_word = splitOnWord
        cParams.max_tokens = maxTokens
        cParams.debug_mode = debugMode
        cParams.audio_ctx = audioCtx
        cParams.tdrz_enable = tdrzEnable

        if let suppressRegex = suppressRegex {
            cParams.suppress_regex = UnsafePointer(strdup(suppressRegex))
        }

        if let initialPrompt = initialPrompt {
            cParams.initial_prompt = UnsafePointer(strdup(initialPrompt))
        }
        cParams.carry_initial_prompt = carryInitialPrompt

        if let promptTokens = promptTokens, !promptTokens.isEmpty {
            let count = promptTokens.count
            let ptr = UnsafeMutablePointer<WhisperToken>.allocate(capacity: count)
            ptr.initialize(from: promptTokens, count: count)
            cParams.prompt_tokens = UnsafePointer(ptr)
            cParams.prompt_n_tokens = Int32(count)
        }

        if let language = language {
            cParams.language = UnsafePointer(strdup(language))
        }

        cParams.detect_language = detectLanguage
        cParams.suppress_blank = suppressBlank
        cParams.suppress_nst = suppressNst
        cParams.temperature = temperature
        cParams.max_initial_ts = maxInitialTs
        cParams.length_penalty = lengthPenalty
        cParams.temperature_inc = temperatureInc
        cParams.entropy_thold = entropyThold
        cParams.logprob_thold = logprobThold
        cParams.no_speech_thold = noSpeechThold

        cParams.greedy.best_of = greedyBestOf
        cParams.beam_search.beam_size = beamSearchBeamSize
        cParams.beam_search.patience = beamSearchPatience

        if let callback = newSegmentCallback {
            cParams.new_segment_callback = callback
            cParams.new_segment_callback_user_data = newSegmentCallbackUserData
        }

        if let callback = progressCallback {
            cParams.progress_callback = callback
            cParams.progress_callback_user_data = progressCallbackUserData
        }

        if let callback = encoderBeginCallback {
            cParams.encoder_begin_callback = callback
            cParams.encoder_begin_callback_user_data = encoderBeginCallbackUserData
        }
        
        if let callback = abortCallback {
            cParams.abort_callback = callback
            cParams.abort_callback_user_data = abortCallbackUserData
        }

        if let callback = logitsFilterCallback {
            cParams.logits_filter_callback = callback
            cParams.logits_filter_callback_user_data = logitsFilterCallbackUserData
        }

        if let grammarRules = grammarRules, !grammarRules.isEmpty {
            let count = grammarRules.count
            let ptr = UnsafeMutablePointer<UnsafePointer<whisper_grammar_element>?>.allocate(capacity: count)
            ptr.initialize(from: grammarRules, count: count)
            cParams.grammar_rules = ptr
            cParams.n_grammar_rules = Int(count)
        }

        cParams.i_start_rule = Int(iStartRule)
        cParams.grammar_penalty = grammarPenalty

        return cParams
    }

    mutating func free() {
        var params = toC()
        whisper_free_params(&params)
    }
}
