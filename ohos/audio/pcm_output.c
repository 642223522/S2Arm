#include "pcm_output.h"
#include <errno.h>
#include <string.h>

_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2 && ATOMIC_INT_LOCK_FREE == 2,
               "real-time PCM counters must be lock free");
int s2a_ohos_pcm_init(struct s2a_ohos_pcm_output *out, int format, int rate, int channels, int ring_ms) {
    if (!out || rate <= 0 || channels <= 0 || channels > 2 || ring_ms <= 0 || ring_ms > 10000) return EINVAL;
    uint64_t frames = (uint64_t)rate * (uint32_t)ring_ms / 1000;
    if (!frames || frames > (1u << 24)) return EINVAL;
    memset(out, 0, sizeof *out);
    int e = s2a_pcm_ring_init(&out->ring, format, (uint32_t)channels, (uint32_t)frames);
    if (e) return e;
    out->logical_bytes = (uint32_t)frames * out->ring.frame_bytes;
    // Recover 20 ms after starvation; a short final packet is allowed through
    // after at most 40 ms of callback time so a game waiting for it cannot deadlock.
    out->cushion_frames = (uint32_t)rate / 50;
    if (!out->cushion_frames) out->cushion_frames = 1;
    if (out->cushion_frames > frames) out->cushion_frames = (uint32_t)frames;
    out->max_hold_frames = (uint32_t)rate / 25;
    if (!out->max_hold_frames) out->max_hold_frames = 1;
    out->buffering = 1;
    return 0;
}
void s2a_ohos_pcm_free(struct s2a_ohos_pcm_output *out) { s2a_pcm_ring_free(&out->ring); }
void s2a_ohos_pcm_reset(struct s2a_ohos_pcm_output *out) { atomic_store(&out->reset, 1); }
uint32_t s2a_ohos_pcm_space(const struct s2a_ohos_pcm_output *out) {
    uint64_t used = atomic_load_explicit(&out->ring.written, memory_order_relaxed)
        - atomic_load_explicit(&out->ring.read, memory_order_acquire);
    if (used >= out->logical_bytes) return 0;
    uint32_t available = out->logical_bytes - (uint32_t)used;
    return available / out->ring.frame_bytes * out->ring.frame_bytes;
}
uint32_t s2a_ohos_pcm_write(struct s2a_ohos_pcm_output *out, const void *data, uint32_t bytes) {
    if (!data || !bytes) return 0;
    uint32_t available = s2a_ohos_pcm_space(out);
    if (bytes > available) bytes = available;
    return s2a_pcm_ring_write(&out->ring, data, bytes);
}
void s2a_ohos_pcm_read(struct s2a_ohos_pcm_output *out, void *data, uint32_t frames) {
    if (atomic_exchange_explicit(&out->reset, 0, memory_order_acq_rel)) {
        out->buffering = 1;
        out->held_frames = 0;
    }
    uint64_t available = (atomic_load_explicit(&out->ring.written, memory_order_acquire)
        - atomic_load_explicit(&out->ring.read, memory_order_relaxed)) / out->ring.frame_bytes;
    if (out->buffering && available < out->cushion_frames && (uint64_t)out->held_frames + frames <= out->max_hold_frames) {
        memset(data, 0, (size_t)frames * out->ring.frame_bytes);
        atomic_fetch_add_explicit(&out->ring.frames_padded, frames, memory_order_relaxed);
        uint32_t remaining = out->max_hold_frames - out->held_frames;
        out->held_frames += frames < remaining ? frames : remaining;
        return;
    }
    out->buffering = 0;
    out->held_frames = 0;
    s2a_pcm_ring_read(&out->ring, data, frames);
    if (available < frames) out->buffering = 1;
}
