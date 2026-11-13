//
//  Qwen3ASRBridge.cpp
//  OpenSuperWhisper
//
//  Qwen3-ASR through the vendored llama.cpp + libmtmd. Speech goes in as 16 kHz
//  mono float PCM and one greedy decode comes out.
//

#include "Qwen3ASRBridge.h"

#include "llama.h"
#include "mtmd.h"
#include "mtmd-helper.h"

#include <os/log.h>
#include <unistd.h>

#include <atomic>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <memory>
#include <string>
#include <vector>

namespace {

/// Context the weights are loaded with, in tokens.
///
/// The audio encoder emits one token per ~80 ms of audio (12.5/s), so this is
/// a bit over 20 minutes of speech plus the prompt around it. Qwen3-ASR's own
/// trained context is 65536, and the KV cache at this size costs ~67 MB — a
/// recording longer than this is refused with a message rather than decoded.
constexpr uint32_t kContextTokens = 16384;

/// Never generate more than this for one utterance. A transcript that ran past
/// this would be a runaway, not speech.
constexpr int kMaxNewTokens = 512;

/// Every layer on the GPU, exactly like the transform engine (llama.cpp's
/// `--n-gpu-layers 99`), and like whisper.cpp's Metal path next to it.
constexpr int32_t kGpuLayers = 99;

/// The app's own log, as the rest of the app uses it. llama.cpp and mtmd would
/// otherwise write their banners, per-batch timings and the "audio input is
/// experimental" warning to the console on every dictation — a menu-bar app has
/// nowhere to show that, so it goes to the unified log with the rest.
os_log_t osw_qwen3asr_log() {
    static os_log_t log = os_log_create("ru.starmel.OpenSuperWhisper", "Qwen3ASR");
    return log;
}

void osw_qwen3asr_log_callback(enum ggml_log_level level, const char * text, void * /* user_data */) {
    if (text == nullptr) {
        return;
    }
    const os_log_type_t type = level == GGML_LOG_LEVEL_ERROR ? OS_LOG_TYPE_ERROR
                             : level == GGML_LOG_LEVEL_WARN  ? OS_LOG_TYPE_DEFAULT
                                                             : OS_LOG_TYPE_DEBUG;
    os_log_with_type(osw_qwen3asr_log(), type, "%{public}s", text);
}

/// The state behind a handle. One utterance at a time: the Swift engine
/// serializes its calls, so nothing here locks.
struct Qwen3ASRHandle {
    llama_model * model = nullptr;
    llama_context * context = nullptr;
    mtmd_context * mmproj = nullptr;
    const llama_vocab * vocab = nullptr;
    std::atomic<bool> cancelled{false};
};

void set_error(char ** err, const std::string & message) {
    if (err == nullptr) {
        return;
    }
    *err = ::strdup(message.c_str());
}

/// The ChatML turn the weights were trained on — it is the exact template the
/// GGUF carries (`tokenizer.chat_template`), with the media marker standing
/// where libmtmd expands the audio tokens.
std::string chat_prompt(const char * language) {
    std::string prompt = "<|im_start|>user\n";
    prompt += mtmd_default_marker();
    prompt += "<|im_end|>\n<|im_start|>assistant\n";

    // Qwen3-ASR opens every answer with the language it heard, then this
    // literal, then the transcript. Seeding the two makes the decode continue
    // in the named language; left out, the model picks the language itself.
    if (language != nullptr && *language != '\0') {
        prompt += "language ";
        prompt += language;
        prompt += "<asr_text>";
    }
    return prompt;
}

/// The transcript out of the model's own answer.
///
/// The answer is `language <name><asr_text><transcript>`; everything before
/// the literal belongs to the model's language report, not to what was said.
/// An answer without the literal is returned as it came — a different shape is
/// a fact about this decode, not something to guess at.
std::string transcript_from_answer(const std::string & answer) {
    const std::string literal = "<asr_text>";
    const size_t at = answer.find(literal);
    if (at == std::string::npos) {
        return answer;
    }
    return answer.substr(at + literal.size());
}

/// One token's bytes. `llama_token_to_piece` reports the size it needs as a
/// negative return when the buffer is too small, so the buffer grows and the
/// call repeats instead of guessing at a fixed length.
bool token_piece(const llama_vocab * vocab, llama_token token, std::string & out) {
    std::vector<char> buffer(64);
    for (;;) {
        const int32_t written = llama_token_to_piece(vocab, token, buffer.data(),
                                                     static_cast<int32_t>(buffer.size()), 0, false);
        if (written >= 0) {
            out.append(buffer.data(), static_cast<size_t>(written));
            return true;
        }
        buffer.resize(static_cast<size_t>(-written));
    }
}

bool readable(const char * path) {
    return path != nullptr && ::access(path, R_OK) == 0;
}

} // namespace

void * osw_qwen3asr_load(const char * text_gguf,
                         const char * mmproj_gguf,
                         int n_threads,
                         char ** err) {
    if (err != nullptr) {
        *err = nullptr;
    }
    if (!readable(text_gguf)) {
        set_error(err, text_gguf == nullptr || *text_gguf == '\0'
                       ? std::string("The Qwen3-ASR model file path is empty.")
                       : std::string("The Qwen3-ASR model file is not readable at ") + text_gguf + ".");
        return nullptr;
    }
    if (!readable(mmproj_gguf)) {
        set_error(err, mmproj_gguf == nullptr || *mmproj_gguf == '\0'
                       ? std::string("The Qwen3-ASR audio projector path is empty.")
                       : std::string("The Qwen3-ASR audio projector is not readable at ") + mmproj_gguf + ".");
        return nullptr;
    }

    llama_log_set(osw_qwen3asr_log_callback, nullptr);
    mtmd_log_set(osw_qwen3asr_log_callback, nullptr);
    llama_backend_init();

    const int threads = n_threads > 0 ? n_threads : 4;

    try {
        auto handle = std::make_unique<Qwen3ASRHandle>();

        llama_model_params model_params = llama_model_default_params();
        model_params.n_gpu_layers = kGpuLayers;
        handle->model = llama_model_load_from_file(text_gguf, model_params);
        if (handle->model == nullptr) {
            set_error(err, std::string("The Qwen3-ASR model could not be loaded from ") + text_gguf
                            + " — the file is not a GGUF the vendored llama.cpp can read.");
            return nullptr;
        }

        llama_context_params context_params = llama_context_default_params();
        context_params.n_ctx = kContextTokens;
        context_params.n_threads = threads;
        context_params.n_threads_batch = threads;
        handle->context = llama_init_from_model(handle->model, context_params);
        if (handle->context == nullptr) {
            set_error(err, "The Qwen3-ASR model loaded but no inference context could be created.");
            return nullptr;
        }

        mtmd_context_params projector_params = mtmd_context_params_default();
        projector_params.use_gpu = true;
        projector_params.n_threads = threads;
        // The per-batch timings and the experimental-audio warning go to the
        // unified log through the callback above, not to the console.
        projector_params.print_timings = false;
        handle->mmproj = mtmd_init_from_file(mmproj_gguf, handle->model, projector_params);
        if (handle->mmproj == nullptr) {
            set_error(err, std::string("The Qwen3-ASR audio projector could not be loaded from ")
                            + mmproj_gguf + " — it does not match this model.");
            return nullptr;
        }
        if (!mtmd_support_audio(handle->mmproj)) {
            set_error(err, std::string("The projector at ") + mmproj_gguf
                            + " carries no audio encoder, so Qwen3-ASR cannot transcribe with it.");
            return nullptr;
        }

        handle->vocab = llama_model_get_vocab(handle->model);
        Qwen3ASRHandle * raw = handle.release();
        os_log_with_type(osw_qwen3asr_log(), OS_LOG_TYPE_INFO,
                         "Qwen3-ASR loaded: %{public}u-token context, %{public}d threads, audio at %{public}d Hz",
                         kContextTokens, threads, mtmd_get_audio_sample_rate(raw->mmproj));
        return raw;
    } catch (const std::exception & error) {
        set_error(err, std::string("The Qwen3-ASR engine failed to start: ") + error.what());
        return nullptr;
    } catch (...) {
        set_error(err, "The Qwen3-ASR engine failed to start.");
        return nullptr;
    }
}

void osw_qwen3asr_free(void * handle) {
    auto * state = static_cast<Qwen3ASRHandle *>(handle);
    if (state == nullptr) {
        return;
    }
    if (state->mmproj != nullptr) {
        mtmd_free(state->mmproj);
    }
    if (state->context != nullptr) {
        llama_free(state->context);
    }
    if (state->model != nullptr) {
        llama_model_free(state->model);
    }
    delete state;
}

void osw_qwen3asr_cancel(void * handle) {
    auto * state = static_cast<Qwen3ASRHandle *>(handle);
    if (state != nullptr) {
        state->cancelled.store(true);
    }
}

char * osw_qwen3asr_transcribe(void * handle,
                               const float * pcm16k,
                               int n_samples,
                               const char * language,
                               char ** err) {
    if (err != nullptr) {
        *err = nullptr;
    }
    auto * state = static_cast<Qwen3ASRHandle *>(handle);
    if (state == nullptr) {
        set_error(err, "The Qwen3-ASR engine is not loaded.");
        return nullptr;
    }
    if (pcm16k == nullptr || n_samples <= 0) {
        set_error(err, "No audio was handed to the Qwen3-ASR engine.");
        return nullptr;
    }

    state->cancelled.store(false);

    try {
        const std::string prompt = chat_prompt(language);

        mtmd_bitmap * audio = mtmd_bitmap_init_from_audio(static_cast<size_t>(n_samples), pcm16k);
        if (audio == nullptr) {
            set_error(err, "The audio could not be prepared for the Qwen3-ASR encoder.");
            return nullptr;
        }

        mtmd_input_text text{prompt.c_str(), prompt.size(), /* add_special */ true, /* parse_special */ true};
        const mtmd_bitmap * bitmaps[1] = {audio};
        std::unique_ptr<mtmd_input_chunks, decltype(&mtmd_input_chunks_free)> chunks(
            mtmd_input_chunks_init(), &mtmd_input_chunks_free);
        const int32_t tokenized = mtmd_tokenize(state->mmproj, chunks.get(), &text, bitmaps, 1);
        mtmd_bitmap_free(audio);
        if (tokenized != 0) {
            set_error(err, "The Qwen3-ASR prompt could not be tokenized (status "
                            + std::to_string(tokenized) + ").");
            return nullptr;
        }

        const size_t prompt_tokens = mtmd_helper_get_n_tokens(chunks.get());
        const uint32_t context_tokens = llama_n_ctx(state->context);
        if (prompt_tokens >= context_tokens) {
            set_error(err, "This recording is too long for the Qwen3-ASR context: "
                            + std::to_string(prompt_tokens) + " tokens against "
                            + std::to_string(context_tokens) + " available. Transcribe a shorter part of it.");
            return nullptr;
        }

        llama_memory_clear(llama_get_memory(state->context), true);

        llama_pos n_past = 0;
        const int32_t evaluated = mtmd_helper_eval_chunks(state->mmproj, state->context, chunks.get(),
                                                          0, 0, static_cast<int32_t>(llama_n_batch(state->context)),
                                                          true, &n_past);
        if (evaluated != 0) {
            set_error(err, "The Qwen3-ASR encoder or decoder failed on this audio (status "
                            + std::to_string(evaluated) + ").");
            return nullptr;
        }

        std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)> sampler(
            llama_sampler_chain_init(llama_sampler_chain_default_params()), &llama_sampler_free);
        llama_sampler_chain_add(sampler.get(), llama_sampler_init_greedy());

        std::string answer;
        for (int i = 0; i < kMaxNewTokens; ++i) {
            if (state->cancelled.load()) {
                set_error(err, "The Qwen3-ASR transcription was cancelled.");
                return nullptr;
            }

            const llama_token token = llama_sampler_sample(sampler.get(), state->context, -1);
            llama_sampler_accept(sampler.get(), token);
            if (llama_vocab_is_eog(state->vocab, token)) {
                break;
            }
            if (!token_piece(state->vocab, token, answer)) {
                set_error(err, "A Qwen3-ASR output token could not be decoded as text.");
                return nullptr;
            }

            llama_token next = token;
            if (llama_decode(state->context, llama_batch_get_one(&next, 1)) != 0) {
                set_error(err, "The Qwen3-ASR decoder failed while generating the transcript.");
                return nullptr;
            }
        }

        return ::strdup(transcript_from_answer(answer).c_str());
    } catch (const std::exception & error) {
        set_error(err, std::string("The Qwen3-ASR transcription failed: ") + error.what());
        return nullptr;
    } catch (...) {
        set_error(err, "The Qwen3-ASR transcription failed.");
        return nullptr;
    }
}

int osw_qwen3asr_audio_sample_rate(void * handle) {
    auto * state = static_cast<Qwen3ASRHandle *>(handle);
    if (state == nullptr || state->mmproj == nullptr) {
        return 0;
    }
    return mtmd_get_audio_sample_rate(state->mmproj);
}

void osw_qwen3asr_string_free(char * text) {
    std::free(text);
}
