#pragma once
#include "../../android/native/pcm_ring.h"

// One serialized producer; one real-time consumer. The storage remains the
// shared PCM ring. Logical capacity matches ring_ms despite power-of-two storage.
struct s2a_ohos_pcm_output {
    struct s2a_pcm_ring ring;
    uint32_t logical_bytes, cushion_frames, max_hold_frames;
    _Atomic int reset;
    // Consumer-owned, never changed by the producer/control thread.
    int buffering;
    uint32_t held_frames;
};
int s2a_ohos_pcm_init(struct s2a_ohos_pcm_output *, int format, int rate, int channels, int ring_ms);
void s2a_ohos_pcm_free(struct s2a_ohos_pcm_output *);
void s2a_ohos_pcm_reset(struct s2a_ohos_pcm_output *);
uint32_t s2a_ohos_pcm_space(const struct s2a_ohos_pcm_output *);
uint32_t s2a_ohos_pcm_write(struct s2a_ohos_pcm_output *, const void *, uint32_t bytes);
void s2a_ohos_pcm_read(struct s2a_ohos_pcm_output *, void *, uint32_t frames);
