#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "ohaudio_sink.h"
#include "pcm_output.h"
#include <ohaudio/native_audiostreambuilder.h>
#include <ohaudio/native_audiorenderer.h>
#include <errno.h>
#include <poll.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <unistd.h>

_Static_assert(sizeof(struct s2a_ohaudio_stats) == 40, "OHAudioSink.Stats ABI");
_Static_assert(offsetof(struct s2a_ohaudio_stats, reopens) == 36, "OHAudioSink.Stats ABI");
struct s2a_ohaudio {
    struct s2a_ohos_pcm_output pcm;
    OH_AudioRenderer *renderer;       // control thread only
    int format, rate, channels, wake_fd;
    int32_t burst_frames;
    uint32_t reopens;
    _Atomic int wants_running, focus_paused, stop_hint, closing;
    _Atomic int reopen_pending, control_pending, last_error;
    _Atomic int shared_duck, shared_mute;
    _Atomic uint32_t volume_bits;
    _Atomic uint64_t notify_at;
};
static int record_error(struct s2a_ohaudio *a, int error) {
    if (error > 0) error = -error;
    atomic_store(&a->last_error, error);
    return error;
}
static void wake(struct s2a_ohaudio *a) {
    uint64_t one = 1;
    ssize_t n;
    do { n = write(a->wake_fd, &one, sizeof one); } while (n < 0 && errno == EINTR);
    if (n < 0 && errno != EAGAIN) record_error(a, -errno);
}
static void notify_if_due(struct s2a_ohaudio *a) {
    uint64_t at = atomic_load_explicit(&a->notify_at, memory_order_relaxed);
    if (at != UINT64_MAX && atomic_load_explicit(&a->pcm.ring.frames_out, memory_order_relaxed) >= at
        && atomic_compare_exchange_strong(&a->notify_at, &at, UINT64_MAX)) wake(a);
}
static OH_AudioData_Callback_Result on_data(OH_AudioRenderer *renderer, void *user, void *data, int32_t size) {
    (void)renderer;
    struct s2a_ohaudio *a = user;
    if (!data || size <= 0 || (uint32_t)size % a->pcm.ring.frame_bytes) {
        record_error(a, -EINVAL);
        wake(a);
        return AUDIO_DATA_CALLBACK_RESULT_INVALID;
    }
    if (atomic_load(&a->closing) || !atomic_load(&a->wants_running)
        || atomic_load(&a->focus_paused) || atomic_load(&a->reopen_pending)) {
        memset(data, 0, (size_t)size);
        return AUDIO_DATA_CALLBACK_RESULT_VALID;
    }
    uint32_t bits = atomic_load_explicit(&a->volume_bits, memory_order_relaxed);
    float volume;
    memcpy(&volume, &bits, sizeof volume);
    if (atomic_load(&a->shared_mute)) volume = 0;
    else if (atomic_load(&a->shared_duck)) volume *= 0.2f;
    s2a_pcm_ring_set_volume(&a->pcm.ring, volume);
    s2a_ohos_pcm_read(&a->pcm, data, (uint32_t)size / a->pcm.ring.frame_bytes);
    notify_if_due(a);
    return AUDIO_DATA_CALLBACK_RESULT_VALID;
}
// Callback threads only publish state and a nonblocking eventfd notification.
// They never call managed code, release/reopen streams, log, allocate, or wait.
static void on_error(OH_AudioRenderer *renderer, void *user, OH_AudioStream_Result error) {
    (void)renderer;
    struct s2a_ohaudio *a = user;
    record_error(a, error ? -(int)error : -EIO);
    atomic_store(&a->reopen_pending, 1);
    wake(a);
}
static void on_interrupt(OH_AudioRenderer *renderer, void *user,
                         OH_AudioInterrupt_ForceType type, OH_AudioInterrupt_Hint hint) {
    (void)renderer;
    struct s2a_ohaudio *a = user;
    switch (hint) {
    case AUDIOSTREAM_INTERRUPT_HINT_PAUSE: atomic_store(&a->focus_paused, 1); break;
    case AUDIOSTREAM_INTERRUPT_HINT_RESUME: atomic_store(&a->focus_paused, 0); break;
    case AUDIOSTREAM_INTERRUPT_HINT_STOP:
        atomic_store(&a->wants_running, 0);
        atomic_store(&a->stop_hint, 1);
        atomic_store(&a->focus_paused, 1);
        break;
    // Forced volume changes were already applied by the system. Do not duck twice.
    case AUDIOSTREAM_INTERRUPT_HINT_DUCK: atomic_store(&a->shared_duck, type == AUDIOSTREAM_INTERRUPT_SHARE); break;
    case AUDIOSTREAM_INTERRUPT_HINT_UNDUCK: atomic_store(&a->shared_duck, 0); break;
    case AUDIOSTREAM_INTERRUPT_HINT_MUTE: atomic_store(&a->shared_mute, type == AUDIOSTREAM_INTERRUPT_SHARE); break;
    case AUDIOSTREAM_INTERRUPT_HINT_UNMUTE: atomic_store(&a->shared_mute, 0); break;
    default: return;
    }
    s2a_ohos_pcm_reset(&a->pcm);
    atomic_store(&a->control_pending, 1);
    wake(a);
}
static void on_route(OH_AudioRenderer *renderer, void *user, OH_AudioStream_DeviceChangeReason reason) {
    (void)renderer; (void)reason;
    struct s2a_ohaudio *a = user;
    // OHAudio owns routing; refresh state/burst size on the serialized owner.
    s2a_ohos_pcm_reset(&a->pcm);
    atomic_store(&a->control_pending, 1);
    wake(a);
}
static int release_stream(struct s2a_ohaudio *a) {
    if (!a->renderer) return 0;
    int e = OH_AudioRenderer_Release(a->renderer);
    if (e) return record_error(a, -e);
    a->renderer = NULL;
    return 0;
}
static int open_stream(struct s2a_ohaudio *a) {
    OH_AudioStreamBuilder *builder = NULL;
    int e = OH_AudioStreamBuilder_Create(&builder, AUDIOSTREAM_TYPE_RENDERER);
    if (e) return record_error(a, -e);
    OH_AudioStream_SampleFormat expected = a->format == S2A_PCM_I16 ? AUDIOSTREAM_SAMPLE_S16LE : AUDIOSTREAM_SAMPLE_F32LE;
    if (!(e = OH_AudioStreamBuilder_SetSamplingRate(builder, a->rate))
        && !(e = OH_AudioStreamBuilder_SetChannelCount(builder, a->channels))
        && !(e = OH_AudioStreamBuilder_SetSampleFormat(builder, expected))
        && !(e = OH_AudioStreamBuilder_SetEncodingType(builder, AUDIOSTREAM_ENCODING_TYPE_RAW))
        && !(e = OH_AudioStreamBuilder_SetLatencyMode(builder, AUDIOSTREAM_LATENCY_MODE_FAST))
        && !(e = OH_AudioStreamBuilder_SetRendererInfo(builder, AUDIOSTREAM_USAGE_GAME))
        && !(e = OH_AudioStreamBuilder_SetRendererWriteDataCallback(builder, on_data, a))
        && !(e = OH_AudioStreamBuilder_SetRendererInterruptCallback(builder, on_interrupt, a))
        && !(e = OH_AudioStreamBuilder_SetRendererErrorCallback(builder, on_error, a))
        && !(e = OH_AudioStreamBuilder_SetRendererOutputDeviceChangeCallback(builder, on_route, a)))
        e = OH_AudioStreamBuilder_GenerateRenderer(builder, &a->renderer);
    int destroy_error = OH_AudioStreamBuilder_Destroy(builder);
    if (!e) e = destroy_error;
    if (e) { if (a->renderer) (void)release_stream(a); return record_error(a, -e); }
    int32_t actual_rate = 0, actual_channels = 0;
    OH_AudioStream_SampleFormat actual_format;
    if (!(e = OH_AudioRenderer_GetSamplingRate(a->renderer, &actual_rate))
        && !(e = OH_AudioRenderer_GetChannelCount(a->renderer, &actual_channels))
        && !(e = OH_AudioRenderer_GetSampleFormat(a->renderer, &actual_format)))
        e = OH_AudioRenderer_GetFrameSizeInCallback(a->renderer, &a->burst_frames);
    if (!e && (actual_rate != a->rate || actual_channels != a->channels || actual_format != expected || a->burst_frames <= 0)) e = ENOTSUP;
    if (e) { (void)release_stream(a); return record_error(a, -e); }
    s2a_ohos_pcm_reset(&a->pcm);
    return 0;
}
static int apply_control(struct s2a_ohaudio *a) {
    if (!a->renderer) return record_error(a, -ENODEV);
    OH_AudioStream_State state;
    int e = OH_AudioRenderer_GetCurrentState(a->renderer, &state);
    if (e) return record_error(a, -e);
    int run = atomic_load(&a->wants_running) && !atomic_load(&a->focus_paused);
    if (run && state != AUDIOSTREAM_STATE_RUNNING) e = OH_AudioRenderer_Start(a->renderer);
    else if (!run && state == AUDIOSTREAM_STATE_RUNNING)
        e = atomic_load(&a->stop_hint) ? OH_AudioRenderer_Stop(a->renderer) : OH_AudioRenderer_Pause(a->renderer);
    else if (state == AUDIOSTREAM_STATE_INVALID || state == AUDIOSTREAM_STATE_RELEASED) e = EIO;
    if (e) return record_error(a, -e);
    return 0;
}
int s2a_ohaudio_open(int format, int rate, int channels, int ring_ms, s2a_ohaudio **out) {
    if (!out) return -EINVAL;
    *out = NULL;
    struct s2a_ohaudio *a = calloc(1, sizeof *a);
    if (!a) return -ENOMEM;
    a->format = format; a->rate = rate; a->channels = channels; a->wake_fd = -1;
    atomic_store(&a->notify_at, UINT64_MAX);
    s2a_ohaudio_set_volume(a, 1.0f);
    int e = s2a_ohos_pcm_init(&a->pcm, format, rate, channels, ring_ms);
    if (e) { free(a); return -e; }
    a->wake_fd = eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK);
    if (a->wake_fd < 0) { e = errno; s2a_ohos_pcm_free(&a->pcm); free(a); return -e; }
    e = open_stream(a);
    if (e) {
        if (a->renderer) { atomic_store(&a->closing, 1); fprintf(stderr, "[OHAudio] failed release; retain callback owner until process exit (%d)\n", e); }
        else { s2a_ohos_pcm_free(&a->pcm); close(a->wake_fd); free(a); }
        return e;
    }
    *out = a;
    return 0;
}
int s2a_ohaudio_start(s2a_ohaudio *a) {
    if (!a || atomic_load(&a->closing)) return -EINVAL;
    atomic_store(&a->wants_running, 1);
    // An explicit user start is allowed to request focus again after STOP.
    atomic_store(&a->focus_paused, 0); atomic_store(&a->stop_hint, 0);
    s2a_ohos_pcm_reset(&a->pcm);
    if (atomic_load(&a->reopen_pending)) return record_error(a, -EAGAIN);
    int e = apply_control(a);
    if (e) atomic_store(&a->wants_running, 0);
    else atomic_store(&a->last_error, 0);
    return e;
}
int s2a_ohaudio_pause(s2a_ohaudio *a) {
    if (!a || atomic_load(&a->closing)) return -EINVAL;
    atomic_store(&a->wants_running, 0);
    s2a_ohos_pcm_reset(&a->pcm);
    return apply_control(a);
}
void s2a_ohaudio_service(s2a_ohaudio *a) {
    if (!a || atomic_load(&a->closing)) return;
    int control = atomic_exchange(&a->control_pending, 0);
    if (atomic_load(&a->reopen_pending)) {
        int previous = atomic_load(&a->last_error);
        if (release_stream(a)) return;
        // Clear before creating: an error callback from the new renderer must
        // remain visible instead of being erased by successful construction.
        atomic_store(&a->reopen_pending, 0);
        if (open_stream(a)) { atomic_store(&a->reopen_pending, 1); return; }
        a->reopens++;
        if (atomic_load(&a->reopen_pending)) return;
        fprintf(stderr, "[OHAudio] stream reopened after error %d (#%u)\n", previous, a->reopens);
        control = 1;
    }
    if (control) {
        int e = apply_control(a);
        if (!e) {
            e = OH_AudioRenderer_GetFrameSizeInCallback(a->renderer, &a->burst_frames);
            if (e) record_error(a, -e);
            else atomic_store(&a->last_error, 0);
        }
    }
}
int s2a_ohaudio_last_error(s2a_ohaudio *a) { return a ? atomic_load(&a->last_error) : -EINVAL; }
void s2a_ohaudio_notify_at(s2a_ohaudio *a, uint64_t frames) {
    atomic_store(&a->notify_at, frames);
    // Close the arm-after-consume race: the callback may already have passed it.
    notify_if_due(a);
}
void s2a_ohaudio_wake(s2a_ohaudio *a) { if (a) wake(a); }
int s2a_ohaudio_wait(s2a_ohaudio *a, int timeout_ms) {
    if (!a || timeout_ms < -1) return -EINVAL;
    struct pollfd p = {.fd = a->wake_fd, .events = POLLIN};
    int n = poll(&p, 1, timeout_ms);
    if (n < 0) return errno == EINTR ? 0 : record_error(a, -errno);
    if (!n) return 0;
    if (!(p.revents & POLLIN)) return record_error(a, -EIO);
    uint64_t value;
    ssize_t got;
    do { got = read(a->wake_fd, &value, sizeof value); } while (got < 0 && errno == EINTR);
    if (got < 0 && errno != EAGAIN) return record_error(a, -errno);
    return 1;
}
uint32_t s2a_ohaudio_space(s2a_ohaudio *a) { return s2a_ohos_pcm_space(&a->pcm); }
uint32_t s2a_ohaudio_write(s2a_ohaudio *a, const void *data, uint32_t bytes) { return s2a_ohos_pcm_write(&a->pcm, data, bytes); }
void s2a_ohaudio_set_volume(s2a_ohaudio *a, float volume) {
    if (!(volume >= 0)) volume = 0;
    if (volume > 1) volume = 1;
    uint32_t bits; memcpy(&bits, &volume, sizeof bits);
    atomic_store_explicit(&a->volume_bits, bits, memory_order_relaxed);
}
void s2a_ohaudio_stats(s2a_ohaudio *a, struct s2a_ohaudio_stats *out) {
    if (!out) return;
    memset(out, 0, sizeof *out); out->sharing = -1;
    if (!a) return;
    out->frames_out = atomic_load(&a->pcm.ring.frames_out);
    out->frames_padded = atomic_load(&a->pcm.ring.frames_padded);
    out->sample_rate = a->rate; out->burst_frames = a->burst_frames; out->reopens = a->reopens;
    if (a->renderer) {
        int e = OH_AudioRenderer_GetUnderflowCount(a->renderer, &out->xruns);
        if (e) record_error(a, -e);
    }
}
void s2a_ohaudio_close(s2a_ohaudio *a) {
    if (!a) return;
    atomic_store(&a->closing, 1); atomic_store(&a->wants_running, 0);
    // Successful Release owns callback quiescence. If it fails, retain memory
    // and fd until process exit instead of freeing a possibly live callback.
    if (release_stream(a)) {
        fprintf(stderr, "[OHAudio] release failed; callback owner retained (%d)\n", atomic_load(&a->last_error));
        return;
    }
    s2a_ohos_pcm_free(&a->pcm); close(a->wake_fd); free(a);
}
