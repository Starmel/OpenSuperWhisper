//
// Created by user on 07.02.2025.
//

import Foundation

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
    public var print_realtime: Bool = false
    public var maxTokens: Int32 = 0
    public var debugMode: Bool = false
    public var audioCtx: Int32 = 0
    public var tdrzEnable: Bool = false
    public var suppressRegex: String?
    public var initialPrompt: String?
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
        cParams.print_realtime = print_realtime
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
