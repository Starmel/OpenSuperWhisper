//
//  Qwen3ASRBridge.h
//  OpenSuperWhisper
//
//  C interface to the Qwen3-ASR speech engine: the vendored llama.cpp (`libllama`)
//  plus its multimodal library (`libmtmd`, which supplies the audio encoder).
//
//  The weights are two GGUF files — a Qwen3-ASR text model and its `mmproj`
//  audio projector — and neither is usable without the other.
//
//  Strings this interface hands back are heap-allocated UTF-8 and belong to the
//  caller: free the transcript with `osw_qwen3asr_string_free` and the error
//  message with the same function. Every failure is a `NULL` return plus a
//  message in `*err`; nothing is printed to the console, and nothing aborts.
//

#ifndef OSW_QWEN3ASR_BRIDGE_H
#define OSW_QWEN3ASR_BRIDGE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Loads the weights. Returns a handle, or `NULL` with `*err` set.
///
/// `n_threads` is the CPU thread count for the parts that do not run on the
/// GPU; a value below 1 means "one thread per performance core".
void * osw_qwen3asr_load(const char * text_gguf,
                         const char * mmproj_gguf,
                         int n_threads,
                         char ** err);

/// Frees the handle and everything behind it. Passing `NULL` is allowed.
void osw_qwen3asr_free(void * handle);

/// Asks the decode in flight on this handle to stop.
///
/// Safe to call from another thread while `osw_qwen3asr_transcribe` is running:
/// generation is checked between tokens, so the call returns quickly. A
/// transcription that stopped this way fails with "cancelled".
void osw_qwen3asr_cancel(void * handle);

/// Transcribes one utterance and returns the transcript, or `NULL` with `*err`
/// set.
///
/// `pcm16k` is `n_samples` mono float samples at
/// `osw_qwen3asr_audio_sample_rate` (16 kHz). `language` is the language the
/// caller wants forced, or `NULL`/`""` for the default: Qwen3-ASR detects the
/// language of the audio itself and the detection is not steerable from the
/// prompt on these weights, so a non-empty hint seeds the `language <name>` the
/// model opens its answer with instead of leaving the choice to the decode.
char * osw_qwen3asr_transcribe(void * handle,
                               const float * pcm16k,
                               int n_samples,
                               const char * language,
                               char ** err);

/// The sample rate the audio input must be at, in Hz — 0 when `handle` is NULL.
int osw_qwen3asr_audio_sample_rate(void * handle);

/// Frees a string this interface returned. Passing `NULL` is allowed.
void osw_qwen3asr_string_free(char * text);

#ifdef __cplusplus
}
#endif

#endif /* OSW_QWEN3ASR_BRIDGE_H */
