//
//  Llama.swift
//  OpenSuperWhisper
//
//  The transform engine, linked into the app the same way whisper.cpp is.
//
//  llama.cpp's ggml is the single ggml in this process: it is the copy the app
//  links, and libwhisper is compiled against it (WHISPER_USE_SYSTEM_GGML=ON).
//  Nothing here needs a port, a server process or Homebrew.
//

import Foundation

enum LlamaError: Error, LocalizedError {
    case modelLoadFailed(String)
    case contextCreationFailed
    case chatTemplateFailed
    case tokenizationFailed
    case promptTooLong(promptTokens: Int, contextSize: Int)
    case decodeFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let path):
            return "The transform model could not be loaded from \(path)."
        case .contextCreationFailed:
            return "The transform model loaded but no inference context could be created."
        case .chatTemplateFailed:
            return "The transform model does not carry a usable chat template."
        case .tokenizationFailed:
            return "The transform prompt could not be tokenized."
        case .promptTooLong(let promptTokens, let contextSize):
            return "The transform prompt (\(promptTokens) tokens) does not fit the \(contextSize)-token context."
        case .decodeFailed(let status):
            return "llama_decode failed with status \(status)."
        }
    }
}

/// One GGUF model plus its inference context, driven through the llama C API.
///
/// Single-threaded by contract: `TransformRuntime` owns the serialization, so
/// this type has no lock of its own.
final class LlamaModel {

    // MARK: - Tuning

    /// The context size the baseline this replaces was started with
    /// (`llama-server --ctx-size 4096`). Dictation prompts are a few hundred
    /// tokens, so this is headroom, not a limit anyone hits.
    static let defaultContextSize: UInt32 = 4096

    /// `--n-gpu-layers 99`: every layer on the GPU, exactly like the baseline.
    static let gpuLayers: Int32 = 99

    /// The temperature every transform has always sampled at, unchanged by the
    /// move in-process: the rewrite samples the same distribution it always did.
    static let temperature: Float = 0.2

    /// Never generate more than this in one transform. A dictation rewrite that
    /// ran past 1024 tokens would be a runaway, not a transcript.
    static let maxNewTokens = 1024

    /// Fixed so the same dictation transforms the same way twice.
    static let seed: UInt32 = 0

    // MARK: - State

    private var model: OpaquePointer?
    private var context: OpaquePointer?

    /// The context size the context was actually created with.
    private(set) var contextSize: UInt32 = 0

    var isLoaded: Bool { model != nil && context != nil }

    // MARK: - Lifecycle

    init(modelPath: String, contextSize: UInt32 = LlamaModel.defaultContextSize) throws {
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = Self.gpuLayers

        let loaded = modelPath.withCString { llama_model_load_from_file($0, modelParams) }
        guard let loaded else {
            throw LlamaError.modelLoadFailed(modelPath)
        }

        var contextParams = llama_context_default_params()
        contextParams.n_ctx = contextSize

        guard let created = llama_init_from_model(loaded, contextParams) else {
            llama_model_free(loaded)
            throw LlamaError.contextCreationFailed
        }

        self.model = loaded
        self.context = created
        self.contextSize = llama_n_ctx(created)
    }

    deinit {
        unload()
    }

    /// Frees the context and the model. Idempotent: unloading twice is fine, and
    /// a later request simply reloads.
    func unload() {
        if let context {
            llama_free(context)
            self.context = nil
        }
        if let model {
            llama_model_free(model)
            self.model = nil
        }
    }

    // MARK: - Generation

    /// Runs one chat completion and returns the raw generated text.
    ///
    /// `assistantPrefix` is what the model's own input contract requires the
    /// assistant turn to open with — S1-mini's empty think block, the one thing
    /// this build cannot ask for through a template kwarg (see
    /// `TransformPromptStyle.assistantPrefix`) — and `greedy` selects the
    /// deterministic chain such a model was trained for. Both are empty/false for
    /// the instruct models, whose prompt is the app's own.
    ///
    /// `isCancelled` is consulted between tokens, so a cancelled dictation stops
    /// generating immediately instead of finishing the rewrite.
    func complete(
        systemPrompt: String,
        userText: String,
        assistantPrefix: String = "",
        greedy: Bool = false,
        isCancelled: () -> Bool = { false }
    ) throws -> String {
        guard let model, let context else {
            throw LlamaError.modelLoadFailed("(no model loaded)")
        }
        // A cancelled dictation must not spend a second building Metal pipelines
        // before the first between-token check.
        if isCancelled() { throw CancellationError() }

        let vocab = llama_model_get_vocab(model)
        let prompt = try Self.chatPrompt(
            model: model,
            systemPrompt: systemPrompt,
            userText: userText,
            assistantPrefix: assistantPrefix
        )

        var promptTokens = Self.tokenize(vocab: vocab, text: prompt)
        guard !promptTokens.isEmpty else {
            throw LlamaError.tokenizationFailed
        }
        guard promptTokens.count < Int(contextSize) else {
            throw LlamaError.promptTooLong(
                promptTokens: promptTokens.count,
                contextSize: Int(contextSize)
            )
        }

        // A fresh sequence per request: positions restart at 0 below, so the
        // previous dictation's tokens must not still be in the cache.
        llama_memory_clear(llama_get_memory(context), true)

        let sampler = Self.makeSampler(greedy: greedy)
        defer { llama_sampler_free(sampler) }

        try Self.decode(context: context, tokens: &promptTokens)

        var generated: [UInt8] = []
        var piece = [CChar](repeating: 0, count: 256)
        let maxNewTokens = min(Self.maxNewTokens, Int(contextSize) - promptTokens.count)

        for _ in 0..<maxNewTokens {
            if isCancelled() { throw CancellationError() }

            let token = llama_sampler_sample(sampler, context, -1)
            llama_sampler_accept(sampler, token)
            if llama_vocab_is_eog(vocab, token) { break }

            var written = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            if written > Int32(piece.count) {
                piece = [CChar](repeating: 0, count: Int(written))
                written = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            }
            if written > 0 {
                generated.append(contentsOf: piece[0..<Int(written)].map { UInt8(bitPattern: $0) })
            }

            var next = [token]
            try Self.decode(context: context, tokens: &next)
        }

        // Tokens are byte pieces, so the text is decoded once at the end: a
        // multi-byte character split across two tokens must not be mangled.
        return String(decoding: generated, as: UTF8.self)
    }

    // MARK: - Prompt assembly

    /// Applies the model's own chat template (`llama-server` does the same for
    /// the HTTP path). A model whose template llama.cpp cannot detect falls back
    /// to ChatML, which is what `llama-server` uses when it has no template at
    /// all; only a failure of both is an error.
    ///
    /// `assistantPrefix` is appended after the assistant header the template
    /// ends with. A model that needs its assistant turn to open with a literal
    /// gets it here, because this build has no way to pass a template kwarg:
    /// `llama_chat_apply_template` (`include/llama.h`) takes a template, the
    /// messages and `add_ass`, and nothing else.
    static func chatPrompt(
        model: OpaquePointer,
        systemPrompt: String,
        userText: String,
        assistantPrefix: String = ""
    ) throws -> String {
        let systemRole = strdup("system")!
        let userRole = strdup("user")!
        let systemContent = strdup(systemPrompt)!
        let userContent = strdup(userText)!
        defer {
            free(systemRole)
            free(userRole)
            free(systemContent)
            free(userContent)
        }

        var messages = [
            llama_chat_message(role: systemRole, content: systemContent),
            llama_chat_message(role: userRole, content: userContent)
        ]

        let applied: String
        if let template = llama_model_chat_template(model, nil),
           let formatted = try? applyChatTemplate(template, messages: &messages) {
            applied = formatted
        } else if let formatted = try? applyChatTemplate(nil, messages: &messages) {
            // `nil` selects llama.cpp's built-in ChatML.
            applied = formatted
        } else {
            throw LlamaError.chatTemplateFailed
        }
        // `add_ass` is always true here, so the formatted prompt ends with the
        // assistant header — which makes appending the prefix the same thing as
        // "the assistant turn opens with this".
        return applied + assistantPrefix
    }

    private static func applyChatTemplate(
        _ template: UnsafePointer<CChar>?,
        messages: inout [llama_chat_message]
    ) throws -> String {
        // Ask for the size first, then format into an exact buffer.
        let needed = llama_chat_apply_template(
            template, &messages, messages.count, true, nil, 0
        )
        guard needed > 0 else { throw LlamaError.chatTemplateFailed }

        var buffer = [CChar](repeating: 0, count: Int(needed) + 1)
        let written = llama_chat_apply_template(
            template, &messages, messages.count, true, &buffer, Int32(buffer.count)
        )
        guard written > 0 else { throw LlamaError.chatTemplateFailed }
        return String(decoding: buffer[0..<Int(written)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Tokenizes with special-token parsing on, so a template's `<|im_start|>`
    /// markers become their single control tokens like they do in llama-server.
    static func tokenize(vocab: OpaquePointer?, text: String) -> [llama_token] {
        let utf8 = Array(text.utf8).map { CChar(bitPattern: $0) }
        // A NULL buffer of length 0 asks for the required capacity, which
        // llama_tokenize reports as the NEGATIVE of the token count
        // (`llama.h`: "Returns a negative number on failure - the number of
        // tokens that would have been returned"), so the capacity is its
        // magnitude, never the value itself. INT32_MIN is the overflow
        // sentinel and must not be negated.
        let probe = llama_tokenize(vocab, utf8, Int32(utf8.count), nil, 0, true, true)
        guard probe != Int32.min, probe != 0 else { return [] }
        let capacity = probe > 0 ? probe : -probe

        var tokens = [llama_token](repeating: 0, count: Int(capacity))
        let written = llama_tokenize(vocab, utf8, Int32(utf8.count), &tokens, capacity, true, true)
        guard written > 0, written <= capacity else { return [] }
        return Array(tokens.prefix(Int(written)))
    }

    // MARK: - Sampling

    /// The chain `llama-server` builds for an unspecified request: top-k 40,
    /// top-p 0.95, min-p 0.05, then the app's established temperature (0.2) and
    /// a distance sampler. Repeat penalty stays at the server default of 1.0
    /// (disabled), which is why it is not in the chain.
    ///
    /// `greedy` is the chain a normalizer's card requires instead of that one:
    /// "normalization is a deterministic transformation, and sampling only adds
    /// variance". Nothing is being overridden by doing that — llama.cpp does not
    /// read the file's own metadata either, so the temp 0.6 / top_p 0.95 / top_k
    /// 20 it carries are inert here, exactly as the app's 0.2 was.
    static func makeSampler(greedy: Bool = false) -> UnsafeMutablePointer<llama_sampler>? {
        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        if greedy {
            llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
            return sampler
        }
        llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.95, 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_min_p(0.05, 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(temperature))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(seed))
        return sampler
    }

    // MARK: - Decoding

    private static func decode(context: OpaquePointer, tokens: inout [llama_token]) throws {
        let status: Int32 = tokens.withUnsafeMutableBufferPointer { buffer in
            let batch = llama_batch_get_one(buffer.baseAddress, Int32(buffer.count))
            return llama_decode(context, batch)
        }
        guard status == 0 else {
            throw LlamaError.decodeFailed(status)
        }
    }
}
