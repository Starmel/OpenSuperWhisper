#include "llama_grammar_helper.h"
#include "llama.h"

#include <string>
#include <vector>
#include <cstring>
#include <cstdio>
#include <algorithm>

// ---------------------------------------------------------------------------
// Internal engine state
// ---------------------------------------------------------------------------

struct LlamaGrammarEngine {
    llama_model   * model   = nullptr;
    llama_context * ctx     = nullptr;
};

// ---------------------------------------------------------------------------
// Default fallback system prompt
// ---------------------------------------------------------------------------

static const char * DEFAULT_SYSTEM_PROMPT =
    "You are a grammar correction assistant. Fix grammar, punctuation, "
    "capitalization, and spelling in the following text. Make only the "
    "minimum changes needed to correct errors — do not rephrase, rewrite, "
    "add explanations, or alter the meaning in any way. Return only the "
    "corrected text with no labels, comments, or extra content.";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

// Build a ChatML-formatted prompt. Works for Qwen3 and most modern models.
static std::string build_chatml_prompt(const std::string & system_msg,
                                       const std::string & user_text) {
    return
        "<|im_start|>system\n" + system_msg + "<|im_end|>\n"
        "<|im_start|>user\n"   + user_text  + "<|im_end|>\n"
        // Empty thinking block silences Qwen3 chain-of-thought mode
        "<|im_start|>assistant\n<think>\n\n</think>\n";
}

// Strip any residual <think>...</think> blocks from model output.
static std::string strip_think_blocks(const std::string & s) {
    std::string result = s;
    while (true) {
        auto start = result.find("<think>");
        if (start == std::string::npos) break;
        auto end = result.find("</think>", start);
        if (end == std::string::npos) {
            result.erase(start);
            break;
        }
        result.erase(start, end + 8 - start);
    }
    // Trim leading/trailing whitespace
    size_t b = result.find_first_not_of(" \t\n\r");
    if (b == std::string::npos) return "";
    size_t e = result.find_last_not_of(" \t\n\r");
    return result.substr(b, e - b + 1);
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

LlamaGrammarEngineRef llama_grammar_engine_create(const char * model_path) {
    llama_backend_init();

    llama_model_params mparams = llama_model_default_params();
    mparams.n_gpu_layers = 99; // offload everything to Metal on Apple Silicon

    llama_model * model = llama_model_load_from_file(model_path, mparams);
    if (!model) {
        fprintf(stderr, "[GrammarEngine] Failed to load model: %s\n", model_path);
        llama_backend_free();
        return nullptr;
    }

    llama_context_params cparams = llama_context_default_params();
    cparams.n_ctx   = 4096;
    cparams.n_batch = 512;

    llama_context * ctx = llama_init_from_model(model, cparams);
    if (!ctx) {
        fprintf(stderr, "[GrammarEngine] Failed to create context.\n");
        llama_model_free(model);
        llama_backend_free();
        return nullptr;
    }

    LlamaGrammarEngine * engine = new LlamaGrammarEngine();
    engine->model = model;
    engine->ctx   = ctx;
    return engine;
}

void llama_grammar_engine_free(LlamaGrammarEngineRef engine) {
    if (!engine) return;
    llama_free(engine->ctx);
    llama_model_free(engine->model);
    delete engine;
    llama_backend_free();
}

char * llama_grammar_engine_fix(LlamaGrammarEngineRef engine,
                                 const char * text,
                                 const char * system_prompt) {
    if (!engine || !text) return nullptr;

    const std::string sys = (system_prompt && system_prompt[0] != '\0')
                            ? std::string(system_prompt)
                            : std::string(DEFAULT_SYSTEM_PROMPT);

    const std::string prompt = build_chatml_prompt(sys, std::string(text));

    // Tokenise prompt
    const llama_vocab * vocab = llama_model_get_vocab(engine->model);

    std::vector<llama_token> prompt_tokens(4096);
    int32_t n_prompt = llama_tokenize(
        vocab,
        prompt.c_str(), static_cast<int32_t>(prompt.size()),
        prompt_tokens.data(), static_cast<int32_t>(prompt_tokens.size()),
        /* add_special */ true, /* parse_special */ true
    );
    if (n_prompt <= 0) return nullptr;
    prompt_tokens.resize(n_prompt);

    // Clear KV cache for a fresh generation
    llama_memory_t mem = llama_get_memory(engine->ctx);
    if (mem) llama_memory_clear(mem, true);

    // Encode prompt in chunks — never exceed n_batch tokens per call
    const int32_t max_batch = 512;
    for (int32_t i = 0; i < n_prompt; i += max_batch) {
        int32_t n = std::min(max_batch, n_prompt - i);
        llama_batch batch = llama_batch_get_one(prompt_tokens.data() + i, n);
        if (llama_decode(engine->ctx, batch) != 0) return nullptr;
    }

    // Sampler: low temperature for near-deterministic correction
    llama_sampler_chain_params sparams = llama_sampler_chain_default_params();
    llama_sampler * smpl = llama_sampler_chain_init(sparams);
    llama_sampler_chain_add(smpl, llama_sampler_init_temp(0.15f));
    llama_sampler_chain_add(smpl, llama_sampler_init_dist(42));

    // Generate response tokens
    std::string result;
    for (int32_t i = 0; i < 512; ++i) {
        llama_token token = llama_sampler_sample(smpl, engine->ctx, -1);
        llama_sampler_accept(smpl, token);

        if (llama_vocab_is_eog(vocab, token)) break;

        char piece[256] = {};
        int32_t n_piece = llama_token_to_piece(vocab, token, piece, sizeof(piece), 0, false);
        if (n_piece > 0) result.append(piece, n_piece);

        // Feed generated token back for next step
        llama_batch next = llama_batch_get_one(&token, 1);
        if (llama_decode(engine->ctx, next) != 0) break;
    }

    llama_sampler_free(smpl);

    std::string cleaned = strip_think_blocks(result);

    // If output is empty, return the original text unchanged
    if (cleaned.empty()) return strdup(text);

    return strdup(cleaned.c_str());
}
