#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct s2a_ohaudio s2a_ohaudio;
// ABI matches OHAudioSink.Stats. buffer_frames is unknown (0): OH does not expose
// AAudio's device buffer metric. sharing is -1 because that enum is not portable.
struct s2a_ohaudio_stats {
    uint64_t frames_out, frames_padded;
    uint32_t xruns;
    int32_t burst_frames, buffer_frames, sample_rate, sharing;
    uint32_t reopens;
};
// API 20+. All control/write calls are serialized by the managed session lock.
// wait/wake may overlap; close requires the waiter and producer to have stopped.
// Return 0 only for a successful requested state, otherwise negative errno or
// negative OH_AudioStream_Result. Async service errors remain readable below.
int s2a_ohaudio_open(int format, int sample_rate, int channels, int ring_ms, s2a_ohaudio **out);
int s2a_ohaudio_start(s2a_ohaudio *);
int s2a_ohaudio_pause(s2a_ohaudio *);
void s2a_ohaudio_service(s2a_ohaudio *);
int s2a_ohaudio_last_error(s2a_ohaudio *);
void s2a_ohaudio_notify_at(s2a_ohaudio *, uint64_t frames);
int s2a_ohaudio_wait(s2a_ohaudio *, int timeout_ms);
void s2a_ohaudio_wake(s2a_ohaudio *);
uint32_t s2a_ohaudio_space(s2a_ohaudio *);
uint32_t s2a_ohaudio_write(s2a_ohaudio *, const void *, uint32_t bytes);
void s2a_ohaudio_set_volume(s2a_ohaudio *, float volume);
void s2a_ohaudio_stats(s2a_ohaudio *, struct s2a_ohaudio_stats *);
void s2a_ohaudio_close(s2a_ohaudio *);
#ifdef __cplusplus
}
#endif
