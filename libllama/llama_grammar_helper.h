#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#define LLAMA_GRAMMAR_API __attribute__((visibility("default")))

// Opaque handle for a loaded grammar engine (llama context).
typedef struct LlamaGrammarEngine * LlamaGrammarEngineRef;

// Load a GGUF model from disk and return a ready-to-use engine.
// Returns NULL on failure. Blocking – call from a background thread.
LLAMA_GRAMMAR_API LlamaGrammarEngineRef llama_grammar_engine_create(const char * model_path);

// Release all resources held by the engine.
LLAMA_GRAMMAR_API void llama_grammar_engine_free(LlamaGrammarEngineRef engine);

// Fix grammar/punctuation/clarity of 'text'.
// system_prompt: custom instruction string, or NULL to use the built-in fallback.
// Returns a malloc'd C string that the caller must free(), or NULL on error.
LLAMA_GRAMMAR_API char * llama_grammar_engine_fix(LlamaGrammarEngineRef engine,
                                                   const char * text,
                                                   const char * system_prompt);

#ifdef __cplusplus
}
#endif
