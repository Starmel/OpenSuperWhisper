//
//  Whis.swift
//  OpenSuperWhisper
//
//  Created by user on 07.02.2025.
//

import Foundation

// MARK: - C Type Wrappers

public typealias WhisperPos = Int32
public typealias WhisperToken = Int32
public typealias WhisperSeqId = Int32

// MARK: - Wrapper Class

public class MyWhisperContext {
    
    private var ctx: OpaquePointer?
    private var state: OpaquePointer?
    
    init(context: OpaquePointer?, state: OpaquePointer? = nil) {
        self.ctx = context
        self.state = state
    }
    
    deinit {
        freeContext()
        if let state = state {
            whisper_free_state(state)
            self.state = nil
        }
    }
    
    // MARK: - Initialization
    
    public static func initFromFile(path: String, params: WhisperContextParams) -> MyWhisperContext? {
        let cParams = params.toC()
        let context = path.withCString { whisper_init_from_file_with_params($0, cParams) }
        guard let context = context else { return nil }
        return MyWhisperContext(context: context)
    }
    
    public static func initFromBuffer(buffer: UnsafeRawPointer, size: Int, params: WhisperContextParams) -> MyWhisperContext? {
        let cParams = params.toC()
        let context = whisper_init_from_buffer_with_params(UnsafeMutableRawPointer(mutating: buffer), size, cParams)
        guard let context = context else { return nil }
        return MyWhisperContext(context: context)
    }
    
    public static func initFromFileNoState(path: String, params: WhisperContextParams) -> MyWhisperContext? {
        let cParams = params.toC()
        let context = path.withCString { whisper_init_from_file_with_params_no_state($0, cParams) }
        guard let context = context else { return nil }
        return MyWhisperContext(context: context)
    }
    
    public static func initFromBufferNoState(buffer: UnsafeRawPointer, size: Int, params: WhisperContextParams) -> MyWhisperContext? {
        let cParams = params.toC()
        let context = whisper_init_from_buffer_with_params_no_state(UnsafeMutableRawPointer(mutating: buffer), size, cParams)
        guard let context = context else { return nil }
        return MyWhisperContext(context: context)
    }
    
    public static func initWith(loader: WhisperModelLoader, params: WhisperContextParams) -> MyWhisperContext? {
        var cLoader = loader.toC()
        let cParams = params.toC()
        
        let context = whisper_init_with_params(&cLoader, cParams)
        guard let context = context else { return nil }
        return MyWhisperContext(context: context)
    }
    
    public func initState() -> Bool {
        guard let ctx = ctx else { return false }
        let state = whisper_init_state(ctx)
        if let state = state {
            self.state = state
            return true
        }
        return false
    }
    
    // MARK: - OpenVINO

    public func initOpenVINOEncoder(modelPath: String? = nil, device: String = "CPU", cacheDir: String? = nil) -> Bool {
        guard let ctx = ctx else { return false }
        
        let modelPathCStr = modelPath?.withCString { strdup($0) } ?? nil
        let deviceCStr = device.withCString { strdup($0) }
        let cacheDirCStr = cacheDir.map { $0.withCString { strdup($0) } } ?? nil
        
        defer {
            free(modelPathCStr)
            free(deviceCStr)
            free(cacheDirCStr)
        }
        
        let result: Int32
        if let state = state {
            result = whisper_ctx_init_openvino_encoder_with_state(ctx, state, modelPathCStr, deviceCStr, cacheDirCStr)
        } else {
            result = whisper_ctx_init_openvino_encoder(ctx, modelPathCStr, deviceCStr, cacheDirCStr)
        }
        return result == 0
    }
    
    // MARK: - Freeing

    private func freeContext() {
        if let ctx = ctx {
            whisper_free(ctx)
            self.ctx = nil
        }
    }
    
    // MARK: - Processing
    
    public func pcmToMel(samples: [Float], nSamples: Int, nThreads: Int) -> Bool {
        guard let ctx = ctx else { return false }
        let result = samples.withUnsafeBufferPointer { buffer in
            if let state = state {
                return whisper_pcm_to_mel_with_state(ctx, state, buffer.baseAddress, Int32(nSamples), Int32(nThreads))
            }
            return whisper_pcm_to_mel(ctx, buffer.baseAddress, Int32(nSamples), Int32(nThreads))
        }
        return result == 0
    }
    
    public func setMel(data: [Float], nLen: Int, nMel: Int) -> Bool {
        guard let ctx = ctx else { return false }
        let result = data.withUnsafeBufferPointer { buffer in
            if let state = state {
                return whisper_set_mel_with_state(ctx, state, buffer.baseAddress, Int32(nLen), Int32(nMel))
            }
            return whisper_set_mel(ctx, buffer.baseAddress, Int32(nLen), Int32(nMel))
        }
        return result == 0
    }
    
    public func encode(offset: Int, nThreads: Int) -> Bool {
        guard let ctx = ctx else { return false }
        if let state = state {
            return whisper_encode_with_state(ctx, state, Int32(offset), Int32(nThreads)) == 0
        }
        return whisper_encode(ctx, Int32(offset), Int32(nThreads)) == 0
    }
    
    public func decode(tokens: [WhisperToken], nTokens: Int, nPast: Int, nThreads: Int) -> Bool {
        guard let ctx = ctx else { return false }
        let result = tokens.withUnsafeBufferPointer { buffer in
            if let state = state {
                return whisper_decode_with_state(ctx, state, buffer.baseAddress, Int32(nTokens), Int32(nPast), Int32(nThreads))
            }
            return whisper_decode(ctx, buffer.baseAddress, Int32(nTokens), Int32(nPast), Int32(nThreads))
        }
        return result == 0
    }
    
    public func tokenize(text: String, tokens: inout [WhisperToken], nMaxTokens: Int) -> Int {
        guard let ctx = ctx else { return -1 }
        return Int(text.withCString {
            whisper_tokenize(ctx, $0, &tokens, Int32(nMaxTokens))
        })
    }
    
    public func tokenCount(text: String) -> Int {
        guard let ctx = ctx else { return 0 }
        return Int(text.withCString { whisper_token_count(ctx, $0) })
    }
    
    // MARK: - Language Handling

    public static func langMaxId() -> Int {
        return Int(whisper_lang_max_id())
    }
    
    public static func langId(lang: String) -> Int {
        return Int(lang.withCString { whisper_lang_id($0) })
    }
    
    public static func langStr(id: Int) -> String? {
        guard let cStr = whisper_lang_str(Int32(id)) else { return nil }
        return String(cString: cStr)
    }
    
    public static func langStrFull(id: Int) -> String? {
        guard let cStr = whisper_lang_str_full(Int32(id)) else { return nil }
        return String(cString: cStr)
    }
    
    public func langAutoDetect(offsetMs: Int, nThreads: Int, langProbs: inout [Float]) -> Int {
        guard let ctx = ctx else { return -1 }
        if let state = state {
            return Int(whisper_lang_auto_detect_with_state(ctx, state, Int32(offsetMs), Int32(nThreads), &langProbs))
        }
        return Int(whisper_lang_auto_detect(ctx, Int32(offsetMs), Int32(nThreads), &langProbs))
    }
    
    // MARK: - Getters

    public var nLen: Int {
        guard let ctx = ctx else { return 0 }
        if let state = state {
            return Int(whisper_n_len_from_state(state))
        }
        return Int(whisper_n_len(ctx))
    }
    
    public var nVocab: Int {
        guard let ctx = ctx else { return 0 }
        return Int(whisper_n_vocab(ctx))
    }
    
    public var nTextCtx: Int {
        guard let ctx = ctx else { return 0 }
        return Int(whisper_n_text_ctx(ctx))
    }
    
    public var nAudioCtx: Int {
        guard let ctx = ctx else { return 0 }
        return Int(whisper_n_audio_ctx(ctx))
    }
    
    public var isMultilingual: Bool {
        guard let ctx = ctx else { return false }
        return whisper_is_multilingual(ctx) != 0
    }
    
    public var modelNVocab: Int {
        guard let ctx = ctx else { return 0 }
        return Int(whisper_model_n_vocab(ctx))
    }
    
    public var modelNAudioCtx: Int {
        guard let ctx = ctx else { return 0 }
        return Int(whisper_model_n_audio_ctx(ctx))
    }
    
    public var modelNAudioState: Int {
        guard let ctx = ctx else { return 0 }
        return Int(whisper_model_n_audio_state(ctx))
    }
    
    public var modelNAudioHead: Int {
        guard let ctx = ctx else { return 0 }
        return Int(whisper_model_n_audio_head(ctx))
    }
    
    public var modelNAudioLayer: Int {
        guard let ctx = ctx else { return 0 }
        return Int(whisper_model_n_audio_layer(ctx))
    }
    
    public var modelNTextCtx: Int {
        guard let ctx = ctx else { return 0 }
        return Int(whisper_model_n_text_ctx(ctx))
    }
    
    public var modelNTextState: Int {
        guard let ctx = ctx else { return 0 }
        return Int(whisper_model_n_text_state(ctx))
    }
    
    public var modelNTextHead: Int {
        guard let ctx = ctx else { return 0 }
        return Int(whisper_model_n_text_head(ctx))
    }
    
    public var modelNTextLayer: Int {
        guard let ctx = ctx else { return 0 }
        return Int(whisper_model_n_text_layer(ctx))
    }
    
    public var modelNMels: Int {
        guard let ctx = ctx else { return 0 }
        return Int(whisper_model_n_mels(ctx))
    }
    
    public var modelFtype: Int {
        guard let ctx = ctx else { return 0 }
        return Int(whisper_model_ftype(ctx))
    }
    
    public var modelType: Int {
        guard let ctx = ctx else { return 0 }
        return Int(whisper_model_type(ctx))
    }
    
    public var logits: [Float]? {
        guard let ctx = ctx else { return nil }
        
        let logitsPtr: UnsafeMutablePointer<Float>?
        if let state = state {
            logitsPtr = whisper_get_logits_from_state(state)
        } else {
            logitsPtr = whisper_get_logits(ctx)
        }
        
        guard let ptr = logitsPtr else { return nil }
        
        let nTokens = Int(whisper_full_n_tokens(ctx, 0))
        let nVocab = self.nVocab
        
        let buffer = UnsafeBufferPointer(start: ptr, count: nTokens * nVocab)
        return Array(buffer)
    }
    
    public func tokenToStr(token: WhisperToken) -> String? {
        guard let ctx = ctx else { return nil }
        guard let cStr = whisper_token_to_str(ctx, token) else { return nil }
        return String(cString: cStr)
    }
    
    public func modelTypeReadable() -> String? {
        guard let ctx = ctx else { return nil }
        guard let cStr = whisper_model_type_readable(ctx) else { return nil }
        return String(cString: cStr)
    }
    
    // MARK: - Special Tokens

    public var tokenEot: WhisperToken {
        guard let ctx = ctx else { return 0 } // Or another appropriate default value
        return whisper_token_eot(ctx)
    }
    
    public var tokenSot: WhisperToken {
        guard let ctx = ctx else { return 0 }
        return whisper_token_sot(ctx)
    }
    
    public var tokenSolm: WhisperToken {
        guard let ctx = ctx else { return 0 }
        return whisper_token_solm(ctx)
    }
    
    public var tokenPrev: WhisperToken {
        guard let ctx = ctx else { return 0 }
        return whisper_token_prev(ctx)
    }
    
    public var tokenNosp: WhisperToken {
        guard let ctx = ctx else { return 0 }
        return whisper_token_nosp(ctx)
    }
    
    public var tokenNot: WhisperToken {
        guard let ctx = ctx else { return 0 }
        return whisper_token_not(ctx)
    }
    
    public var tokenBeg: WhisperToken {
        guard let ctx = ctx else { return 0 }
        return whisper_token_beg(ctx)
    }
    
    public func tokenLang(langId: Int) -> WhisperToken {
        guard let ctx = ctx else { return 0 }
        return whisper_token_lang(ctx, Int32(langId))
    }
    
    public var tokenTranslate: WhisperToken {
        guard let ctx = ctx else { return 0 }
        return whisper_token_translate(ctx)
    }
    
    public var tokenTranscribe: WhisperToken {
        guard let ctx = ctx else { return 0 }
        return whisper_token_transcribe(ctx)
    }
    
    // MARK: Performance
    
    func getTimings() -> WhisperTimings? {
        guard let ctx = ctx else { return nil }
        guard let cTimings = whisper_get_timings(ctx) else { return nil }
        return WhisperTimings.fromC(cTimings.pointee)
    }
    
    public func printTimings() {
        guard let ctx = ctx else { return }
        whisper_print_timings(ctx)
    }
    
    public func resetTimings() {
        guard let ctx = ctx else { return }
        whisper_reset_timings(ctx)
    }
    
    // MARK: - System Info

    public static func printSystemInfo() -> String {
        return String(cString: whisper_print_system_info())
    }
    
    // MARK: Context Default Params
    
    public static func contextDefaultParams() -> WhisperContextParams {
        let cParams = whisper_context_default_params()
        var params = WhisperContextParams()
        params.useGPU = cParams.use_gpu
        params.flashAttention = cParams.flash_attn
        params.gpuDevice = cParams.gpu_device
        params.dtwTokenTimestamps = cParams.dtw_token_timestamps
        if let preset = WhisperAlignmentHeadsPreset(rawValue: Int32(cParams.dtw_aheads_preset.rawValue)) {
            params.dtwAheadsPreset = preset
        }
        params.dtwNTop = cParams.dtw_n_top
        params.dtwAheads = WhisperAheads.fromC(cParams.dtw_aheads)
        params.dtwMemSize = cParams.dtw_mem_size
        return params
    }
    
    public static func contextDefaultParamsByRef() -> UnsafeMutablePointer<WhisperContextParams>? {
        guard var defaultParams = whisper_context_default_params_by_ref()?.pointee else { return nil }
        
        // Allocate memory for a new WhisperContextParams instance
        let swiftParamsPointer = UnsafeMutablePointer<WhisperContextParams>.allocate(capacity: 1)
        
        // Map fields
        var params = WhisperContextParams()
        params.useGPU = defaultParams.use_gpu
        params.flashAttention = defaultParams.flash_attn
        params.gpuDevice = defaultParams.gpu_device
        params.dtwTokenTimestamps = defaultParams.dtw_token_timestamps
        if let preset = WhisperAlignmentHeadsPreset(rawValue: Int32(defaultParams.dtw_aheads_preset.rawValue)) {
            params.dtwAheadsPreset = preset
        }
        params.dtwNTop = defaultParams.dtw_n_top
        params.dtwAheads = WhisperAheads.fromC(defaultParams.dtw_aheads)
        params.dtwMemSize = defaultParams.dtw_mem_size
        
        // Initialize the allocated memory with the mapped data
        swiftParamsPointer.initialize(to: params)
        
        return swiftParamsPointer
    }
    
    public static func freeContextParams(params: UnsafeMutablePointer<WhisperContextParams>?) {
        guard let params = params else { return }
        params.deallocate()
    }
    
    // MARK: - Full Decoding
    
    public static func fullDefaultParams(strategy: WhisperSamplingStrategy) -> WhisperFullParams {
        let cParams = whisper_full_default_params(whisper_sampling_strategy(rawValue: UInt32(strategy.rawValue)))
        return mapWhisperFullParams(from: cParams)
    }
    
    // NOTE: This is replicating the functionality from the objective-c implementation in the question.
    public static func fullDefaultParamsByRef(strategy: WhisperSamplingStrategy) -> UnsafeMutablePointer<WhisperFullParams>? {
        guard let defaultParams = whisper_full_default_params_by_ref(whisper_sampling_strategy(rawValue: UInt32(strategy.rawValue)))?.pointee else { return nil }
        
        let swiftParamsPointer = UnsafeMutablePointer<WhisperFullParams>.allocate(capacity: 1)
        var params = WhisperFullParams()
        
        params.strategy = WhisperSamplingStrategy(rawValue: Int32(defaultParams.strategy.rawValue)) ?? .greedy
        params.nThreads = defaultParams.n_threads
        params.nMaxTextCtx = defaultParams.n_max_text_ctx
        params.offsetMs = defaultParams.offset_ms
        params.durationMs = defaultParams.duration_ms
        params.translate = defaultParams.translate
        params.noContext = defaultParams.no_context
        params.noTimestamps = defaultParams.no_timestamps
        params.singleSegment = defaultParams.single_segment
        params.printSpecial = defaultParams.print_special
        params.printProgress = defaultParams.print_progress
        params.printRealtime = defaultParams.print_realtime
        params.printTimestamps = defaultParams.print_timestamps
        params.tokenTimestamps = defaultParams.token_timestamps
        params.tholdPt = defaultParams.thold_pt
        params.tholdPtsum = defaultParams.thold_ptsum
        params.maxLen = defaultParams.max_len
        params.splitOnWord = defaultParams.split_on_word
        params.maxTokens = defaultParams.max_tokens
        params.debugMode = defaultParams.debug_mode
        params.audioCtx = defaultParams.audio_ctx
        params.tdrzEnable = defaultParams.tdrz_enable
        
        if let cStr = defaultParams.suppress_regex {
            params.suppressRegex = String(cString: cStr)
        }
        
        if let cStr = defaultParams.initial_prompt {
            params.initialPrompt = String(cString: cStr)
        }
        
        if let promptTokens = defaultParams.prompt_tokens, defaultParams.prompt_n_tokens > 0 {
            let count = Int(defaultParams.prompt_n_tokens)
            let buffer = UnsafeBufferPointer(start: promptTokens, count: count)
            params.promptTokens = Array(buffer)
        }
        
        if let cStr = defaultParams.language {
            params.language = String(cString: cStr)
        }
        
        params.detectLanguage = defaultParams.detect_language
        params.suppressBlank = defaultParams.suppress_blank
        params.suppressNst = defaultParams.suppress_nst
        params.temperature = defaultParams.temperature
        params.maxInitialTs = defaultParams.max_initial_ts
        params.lengthPenalty = defaultParams.length_penalty
        params.temperatureInc = defaultParams.temperature_inc
        params.entropyThold = defaultParams.entropy_thold
        params.logprobThold = defaultParams.logprob_thold
        params.noSpeechThold = defaultParams.no_speech_thold
        params.greedyBestOf = defaultParams.greedy.best_of
        params.beamSearchBeamSize = defaultParams.beam_search.beam_size
        params.beamSearchPatience = defaultParams.beam_search.patience
        params.newSegmentCallback = defaultParams.new_segment_callback
        params.newSegmentCallbackUserData = defaultParams.new_segment_callback_user_data
        params.progressCallback = defaultParams.progress_callback
        params.progressCallbackUserData = defaultParams.progress_callback_user_data
        params.encoderBeginCallback = defaultParams.encoder_begin_callback
        params.encoderBeginCallbackUserData = defaultParams.encoder_begin_callback_user_data
        
        // Convert abort callback to proper type
//        if let abortCallback = defaultParams.abort_callback {
//            params.abortCallback = { userData in
//                _ = abortCallback(userData)
//            }
//        }
        params.abortCallbackUserData = defaultParams.abort_callback_user_data
        
        params.logitsFilterCallback = defaultParams.logits_filter_callback
        params.logitsFilterCallbackUserData = defaultParams.logits_filter_callback_user_data
        
        if let grammarRules = defaultParams.grammar_rules, defaultParams.n_grammar_rules > 0 {
            let count = Int(defaultParams.n_grammar_rules)
            let buffer = UnsafeBufferPointer(start: grammarRules, count: count)
            params.grammarRules = Array(buffer)
        }
        
        params.iStartRule = Int(defaultParams.i_start_rule)
        params.grammarPenalty = defaultParams.grammar_penalty
        
        swiftParamsPointer.initialize(to: params)
        return swiftParamsPointer
    }
    
    private static func mapWhisperFullParams(from cParams: whisper_full_params) -> WhisperFullParams {
        var params = WhisperFullParams()
        params.strategy = WhisperSamplingStrategy(rawValue: Int32(cParams.strategy.rawValue)) ?? .greedy
        params.nThreads = cParams.n_threads
        params.nMaxTextCtx = cParams.n_max_text_ctx
        params.offsetMs = cParams.offset_ms
        params.durationMs = cParams.duration_ms
        params.translate = cParams.translate
        params.noContext = cParams.no_context
        params.noTimestamps = cParams.no_timestamps
        params.singleSegment = cParams.single_segment
        params.printSpecial = cParams.print_special
        params.printProgress = cParams.print_progress
        params.printRealtime = cParams.print_realtime
        params.printTimestamps = cParams.print_timestamps
        params.tokenTimestamps = cParams.token_timestamps
        params.tholdPt = cParams.thold_pt
        params.tholdPtsum = cParams.thold_ptsum
        params.maxLen = cParams.max_len
        params.splitOnWord = cParams.split_on_word
        params.maxTokens = cParams.max_tokens
        params.debugMode = cParams.debug_mode
        params.audioCtx = cParams.audio_ctx
        params.tdrzEnable = cParams.tdrz_enable
        
        if let cStr = cParams.suppress_regex {
            params.suppressRegex = String(cString: cStr)
            free(UnsafeMutablePointer(mutating: cStr)) // Free the duplicated string.
            
        }
        if let cStr = cParams.initial_prompt {
            params.initialPrompt = String(cString: cStr)
            free(UnsafeMutablePointer(mutating: cStr)) // Free the duplicated string.
        }
        if let promptTokens = cParams.prompt_tokens, cParams.prompt_n_tokens > 0 {
            let count = Int(cParams.prompt_n_tokens)
            let buffer = UnsafeBufferPointer(start: promptTokens, count: count)
            params.promptTokens = Array(buffer)
        }
        if let cStr = cParams.language {
            params.language = String(cString: cStr)
            free(UnsafeMutablePointer(mutating: cStr)) // Free the duplicated string.
        }
        params.detectLanguage = cParams.detect_language
        params.suppressBlank = cParams.suppress_blank
        params.suppressNst = cParams.suppress_nst
        params.temperature = cParams.temperature
        params.maxInitialTs = cParams.max_initial_ts
        params.lengthPenalty = cParams.length_penalty
        params.temperatureInc = cParams.temperature_inc
        params.entropyThold = cParams.entropy_thold
        params.logprobThold = cParams.logprob_thold
        params.noSpeechThold = cParams.no_speech_thold
        params.greedyBestOf = cParams.greedy.best_of
        params.beamSearchBeamSize = cParams.beam_search.beam_size
        params.beamSearchPatience = cParams.beam_search.patience
        params.newSegmentCallback = cParams.new_segment_callback
        params.newSegmentCallbackUserData = cParams.new_segment_callback_user_data
        params.progressCallback = cParams.progress_callback
        params.progressCallbackUserData = cParams.progress_callback_user_data
        params.encoderBeginCallback = cParams.encoder_begin_callback
        params.encoderBeginCallbackUserData = cParams.encoder_begin_callback_user_data
//        params.abortCallback = cParams.abort_callback
        params.abortCallbackUserData = cParams.abort_callback_user_data
        params.logitsFilterCallback = cParams.logits_filter_callback
        params.logitsFilterCallbackUserData = cParams.logits_filter_callback_user_data
        
        if let grammarRules = cParams.grammar_rules, cParams.n_grammar_rules > 0 {
            let count = Int(cParams.n_grammar_rules)
            let buffer = UnsafeBufferPointer(start: grammarRules, count: count)
            params.grammarRules = Array(buffer)
        }
        
        params.iStartRule = cParams.i_start_rule
        params.grammarPenalty = cParams.grammar_penalty
        return params
    }
    
    public func full(samples: [Float], params: inout WhisperFullParams) -> Bool {
        guard let ctx = ctx else { return false }
        let result = samples.withUnsafeBufferPointer { buffer in
            var cParams = params.toC() // Convert to C struct here.
            let result: Int32
            if let state = state {
                result = whisper_full_with_state(ctx, state, cParams, buffer.baseAddress, Int32(samples.count))
            } else {
                result = whisper_full(ctx, cParams, buffer.baseAddress, Int32(samples.count))
            }
            
            // Free c-allocated strings
            if let suppressRegex = cParams.suppress_regex {
                free(UnsafeMutablePointer(mutating: suppressRegex))
            }
            if let initialPrompt = cParams.initial_prompt {
                free(UnsafeMutablePointer(mutating: initialPrompt))
            }
            if let language = cParams.language {
                free(UnsafeMutablePointer(mutating: language))
            }
            
            // Free the allocated memory for grammar_rules
            if let baseAddress = cParams.grammar_rules {
                free(UnsafeMutableRawPointer(mutating: baseAddress))
            }
            return result
        }
        
        return result == 0
    }
    
    public func fullParallel(samples: [Float], params: inout WhisperFullParams, nProcessors: Int) -> Bool {
        guard let ctx = ctx else { return false }
        var cParams = params.toC()
        let result = samples.withUnsafeBufferPointer { buffer in
            whisper_full_parallel(ctx, cParams, buffer.baseAddress, Int32(samples.count), Int32(nProcessors))
        }
        // Free c-allocated strings
        if let suppressRegex = cParams.suppress_regex {
            free(UnsafeMutablePointer(mutating: suppressRegex))
        }
        if let initialPrompt = cParams.initial_prompt {
            free(UnsafeMutablePointer(mutating: initialPrompt))
        }
        if let language = cParams.language {
            free(UnsafeMutablePointer(mutating: language))
        }
        // Free the allocated memory for grammar_rules
        if let baseAddress = cParams.grammar_rules {
            free(UnsafeMutableRawPointer(mutating: baseAddress))
        }
        return result == 0
    }
    
    // MARK: - Segment Info
    
    public var fullNSegments: Int {
        guard let ctx = ctx else { return 0 }
        if let state = state {
            return Int(whisper_full_n_segments_from_state(state))
        }
        return Int(whisper_full_n_segments(ctx))
    }
    
    public var fullLangId: Int {
        guard let ctx = ctx else { return -1 }
        if let state = state {
            return Int(whisper_full_lang_id_from_state(state))
        }
        return Int(whisper_full_lang_id(ctx))
    }
    
    public func fullGetSegmentT0(iSegment: Int) -> Int64 {
        guard let ctx = ctx else { return 0 }
        if let state = state {
            return whisper_full_get_segment_t0_from_state(state, Int32(iSegment))
        }
        return whisper_full_get_segment_t0(ctx, Int32(iSegment))
    }
    
    public func fullGetSegmentT1(iSegment: Int) -> Int64 {
        guard let ctx = ctx else { return 0 }
        if let state = state {
            return whisper_full_get_segment_t1_from_state(state, Int32(iSegment))
        }
        return whisper_full_get_segment_t1(ctx, Int32(iSegment))
    }
    
    public func fullGetSegmentSpeakerTurnNext(iSegment: Int) -> Bool {
        guard let ctx = ctx else { return false }
        if let state = state {
            return whisper_full_get_segment_speaker_turn_next_from_state(state, Int32(iSegment))
        }
        return whisper_full_get_segment_speaker_turn_next(ctx, Int32(iSegment))
    }
    
    public func fullGetSegmentText(iSegment: Int) -> String? {
        guard let ctx = ctx else { return nil }
        let cStr: UnsafePointer<CChar>?
        if let state = state {
            cStr = whisper_full_get_segment_text_from_state(state, Int32(iSegment))
        } else {
            cStr = whisper_full_get_segment_text(ctx, Int32(iSegment))
        }
        
        guard let cStr = cStr else { return nil }
        return String(cString: cStr)
    }
    
    public func fullNTokens(iSegment: Int) -> Int {
        guard let ctx = ctx else { return 0 }
        if let state = state {
            return Int(whisper_full_n_tokens_from_state(state, Int32(iSegment)))
        }
        return Int(whisper_full_n_tokens(ctx, Int32(iSegment)))
    }
    
    public func fullGetTokenText(iSegment: Int, iToken: Int) -> String? {
        guard let ctx = ctx else { return nil }
        let cStr: UnsafePointer<CChar>?
        if let state = state {
            cStr = whisper_full_get_token_text_from_state(ctx, state, Int32(iSegment), Int32(iToken))
        } else {
            cStr = whisper_full_get_token_text(ctx, Int32(iSegment), Int32(iToken))
        }
        
        guard let cStr = cStr else { return nil }
        return String(cString: cStr)
    }
    
    public func fullGetTokenId(iSegment: Int, iToken: Int) -> WhisperToken {
        guard let ctx = ctx else { return 0 } // Return a default value, e.g., 0 or -1
        if let state = state {
            return whisper_full_get_token_id_from_state(state, Int32(iSegment), Int32(iToken))
        }
        return whisper_full_get_token_id(ctx, Int32(iSegment), Int32(iToken))
    }
    
    public func fullGetTokenData(iSegment: Int, iToken: Int) -> WhisperTokenData {
        if let state = state {
            return WhisperTokenData.fromC(whisper_full_get_token_data_from_state(state, Int32(iSegment), Int32(iToken)))
        }
        guard let ctx = ctx else { return WhisperTokenData(id: 0, tid: 0, p: 0, plog: 0, pt: 0, ptsum: 0, t0: 0, t1: 0, tDtw: 0, vlen: 0) }
        return WhisperTokenData.fromC(whisper_full_get_token_data(ctx, Int32(iSegment), Int32(iToken)))
    }
    
    public func fullGetTokenP(iSegment: Int, iToken: Int) -> Float {
        guard let ctx = ctx else { return 0.0 } // Return a default value
        if let state = state {
            return whisper_full_get_token_p_from_state(state, Int32(iSegment), Int32(iToken))
        }
        return whisper_full_get_token_p(ctx, Int32(iSegment), Int32(iToken))
    }
    
    public func fullGetSegmentNoSpeechProb(iSegment: Int) -> Float {
        guard let ctx = ctx else { return 0.0 } // Return a default value.
        if let state = state {
            return whisper_full_get_segment_no_speech_prob_from_state(state, Int32(iSegment))
        }
        return whisper_full_get_segment_no_speech_prob(ctx, Int32(iSegment))
    }
    
    // MARK: - Benchmarks (For completeness)

    public static func benchMemcpy(nThreads: Int) -> Int {
        return Int(whisper_bench_memcpy(Int32(nThreads)))
    }
    
    public static func benchMemcpyStr(nThreads: Int) -> String {
        return String(cString: whisper_bench_memcpy_str(Int32(nThreads)))
    }
    
    public static func benchGgmlMulMat(nThreads: Int) -> Int {
        return Int(whisper_bench_ggml_mul_mat(Int32(nThreads)))
    }
    
    public static func benchGgmlMulMatStr(nThreads: Int) -> String {
        return String(cString: whisper_bench_ggml_mul_mat_str(Int32(nThreads)))
    }
    
    // MARK: - Log
    
    public static func whisperLogSet(logCallback: @escaping ggml_log_callback, userData: UnsafeMutableRawPointer?) {
        whisper_log_set(logCallback, userData)
    }
}
