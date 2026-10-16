// Phonon-2 greedy decoder (compiled library).
#ifndef PHONON2_TDT_H
#define PHONON2_TDT_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
void *phonon2_tdt_create(int V, int E, int H, int nhead, int ndur, const int *durations, int blank, int max_sym,
                         const int8_t *emb_q, const uint16_t *emb_s,
                         const int8_t *ih0_q, const uint16_t *ih0_s, const uint16_t *bih0, const int8_t *hh0_q, const uint16_t *hh0_s, const uint16_t *bhh0,
                         const int8_t *ih1_q, const uint16_t *ih1_s, const uint16_t *bih1, const int8_t *hh1_q, const uint16_t *hh1_s, const uint16_t *bhh1,
                         const int8_t *proj_q, const uint16_t *proj_s, const uint16_t *proj_b,
                         const int8_t *head_q, const uint16_t *head_s, const uint16_t *head_b);
int phonon2_tdt_decode(void *h, const float *encp, int T, int32_t *out, int max_out);
/* token ids + the encoder frame each token was emitted at + its predicted duration (frames of 80 ms); handles are independent */
int phonon2_tdt_decode_timed(void *h, const float *encp, int T, int32_t *out, int32_t *out_frame, int32_t *out_dur, int max_out);
void phonon2_tdt_handle_threads(void *h, int n);
/* a handle sharing the weight tables of h (own state, scratch, pool); destroy clones before h */
void *phonon2_tdt_clone(void *h);
void phonon2_tdt_set_threads(int n);
void phonon2_tdt_destroy(void *h);
int phonon2_tdt_abi_version(void);
#ifdef __cplusplus
}
#endif
#endif

