# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Focus loss keeps consuming the PCM ring, as Android does (aaudio_sink.c on_data).

Builds the actual ohaudio_sink.c + pcm_output.c + pcm_ring.c against a test-only OHAudio,
eventfd and poll boundary, then drives the real callbacks and service(). CC is a host C
compiler. --source swaps in another ohaudio_sink.c (negative control: the old one must fail).
"""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]

HEADERS = {
    'ohaudio/native_audiostreambuilder.h': '#pragma once\n#include "native_audiorenderer.h"\n',
    'ohaudio/native_audiorenderer.h': r'''
#pragma once
#include <stdint.h>
typedef struct OH_AudioRenderer OH_AudioRenderer;
typedef struct OH_AudioStreamBuilder OH_AudioStreamBuilder;
typedef enum { AUDIOSTREAM_SUCCESS = 0, AUDIOSTREAM_ERROR_ILLEGAL_STATE = 2 } OH_AudioStream_Result;
typedef enum { AUDIOSTREAM_TYPE_RENDERER = 1 } OH_AudioStream_Type;
typedef enum { AUDIOSTREAM_SAMPLE_S16LE = 1, AUDIOSTREAM_SAMPLE_F32LE = 4 } OH_AudioStream_SampleFormat;
typedef enum { AUDIOSTREAM_ENCODING_TYPE_RAW = 0 } OH_AudioStream_EncodingType;
typedef enum { AUDIOSTREAM_USAGE_GAME = 11 } OH_AudioStream_Usage;
typedef enum { AUDIOSTREAM_LATENCY_MODE_NORMAL = 0, AUDIOSTREAM_LATENCY_MODE_FAST = 1 } OH_AudioStream_LatencyMode;
typedef enum { AUDIOSTREAM_STATE_INVALID = -1, AUDIOSTREAM_STATE_NEW = 0, AUDIOSTREAM_STATE_PREPARED = 1,
    AUDIOSTREAM_STATE_RUNNING = 2, AUDIOSTREAM_STATE_STOPPED = 3, AUDIOSTREAM_STATE_RELEASED = 4,
    AUDIOSTREAM_STATE_PAUSED = 5 } OH_AudioStream_State;
typedef enum { AUDIOSTREAM_INTERRUPT_FORCE = 0, AUDIOSTREAM_INTERRUPT_SHARE = 1 } OH_AudioInterrupt_ForceType;
typedef enum { AUDIOSTREAM_INTERRUPT_HINT_NONE = 0, AUDIOSTREAM_INTERRUPT_HINT_RESUME = 1,
    AUDIOSTREAM_INTERRUPT_HINT_PAUSE = 2, AUDIOSTREAM_INTERRUPT_HINT_STOP = 3, AUDIOSTREAM_INTERRUPT_HINT_DUCK = 4,
    AUDIOSTREAM_INTERRUPT_HINT_UNDUCK = 5, AUDIOSTREAM_INTERRUPT_HINT_MUTE = 6,
    AUDIOSTREAM_INTERRUPT_HINT_UNMUTE = 7 } OH_AudioInterrupt_Hint;
typedef enum { REASON_UNKNOWN = 0 } OH_AudioStream_DeviceChangeReason;
typedef enum { AUDIO_DATA_CALLBACK_RESULT_INVALID = -1, AUDIO_DATA_CALLBACK_RESULT_VALID = 0 } OH_AudioData_Callback_Result;
typedef OH_AudioData_Callback_Result (*OH_AudioRenderer_OnWriteDataCallback)(OH_AudioRenderer *, void *, void *, int32_t);
typedef void (*OH_AudioRenderer_OnInterruptCallback)(OH_AudioRenderer *, void *, OH_AudioInterrupt_ForceType, OH_AudioInterrupt_Hint);
typedef void (*OH_AudioRenderer_OnErrorCallback)(OH_AudioRenderer *, void *, OH_AudioStream_Result);
typedef void (*OH_AudioRenderer_OutputDeviceChangeCallback)(OH_AudioRenderer *, void *, OH_AudioStream_DeviceChangeReason);
int OH_AudioStreamBuilder_Create(OH_AudioStreamBuilder **, OH_AudioStream_Type);
int OH_AudioStreamBuilder_Destroy(OH_AudioStreamBuilder *);
int OH_AudioStreamBuilder_SetSamplingRate(OH_AudioStreamBuilder *, int32_t);
int OH_AudioStreamBuilder_SetChannelCount(OH_AudioStreamBuilder *, int32_t);
int OH_AudioStreamBuilder_SetSampleFormat(OH_AudioStreamBuilder *, OH_AudioStream_SampleFormat);
int OH_AudioStreamBuilder_SetEncodingType(OH_AudioStreamBuilder *, OH_AudioStream_EncodingType);
int OH_AudioStreamBuilder_SetLatencyMode(OH_AudioStreamBuilder *, OH_AudioStream_LatencyMode);
int OH_AudioStreamBuilder_SetRendererInfo(OH_AudioStreamBuilder *, OH_AudioStream_Usage);
int OH_AudioStreamBuilder_SetRendererWriteDataCallback(OH_AudioStreamBuilder *, OH_AudioRenderer_OnWriteDataCallback, void *);
int OH_AudioStreamBuilder_SetRendererInterruptCallback(OH_AudioStreamBuilder *, OH_AudioRenderer_OnInterruptCallback, void *);
int OH_AudioStreamBuilder_SetRendererErrorCallback(OH_AudioStreamBuilder *, OH_AudioRenderer_OnErrorCallback, void *);
int OH_AudioStreamBuilder_SetRendererOutputDeviceChangeCallback(OH_AudioStreamBuilder *, OH_AudioRenderer_OutputDeviceChangeCallback, void *);
int OH_AudioStreamBuilder_GenerateRenderer(OH_AudioStreamBuilder *, OH_AudioRenderer **);
int OH_AudioRenderer_Release(OH_AudioRenderer *);
int OH_AudioRenderer_Start(OH_AudioRenderer *);
int OH_AudioRenderer_Pause(OH_AudioRenderer *);
int OH_AudioRenderer_Stop(OH_AudioRenderer *);
int OH_AudioRenderer_GetCurrentState(OH_AudioRenderer *, OH_AudioStream_State *);
int OH_AudioRenderer_GetSamplingRate(OH_AudioRenderer *, int32_t *);
int OH_AudioRenderer_GetChannelCount(OH_AudioRenderer *, int32_t *);
int OH_AudioRenderer_GetSampleFormat(OH_AudioRenderer *, OH_AudioStream_SampleFormat *);
int OH_AudioRenderer_GetFrameSizeInCallback(OH_AudioRenderer *, int32_t *);
int OH_AudioRenderer_GetUnderflowCount(OH_AudioRenderer *, uint32_t *);
''',
    'sys/eventfd.h': '#pragma once\n#define EFD_CLOEXEC 1\n#define EFD_NONBLOCK 2\nint eventfd(unsigned, int);\n',
    'poll.h': '#pragma once\nstruct pollfd { int fd; short events, revents; };\n#define POLLIN 1\n'
              'int poll(struct pollfd *, unsigned long, int);\n',
    'unistd.h': '#pragma once\n#include <stddef.h>\n#include <sys/types.h>\n#define read fake_read\n#define write fake_write\n'
                '#define close fake_close\nssize_t fake_read(int, void *, size_t);\nssize_t fake_write(int, const void *, size_t);\n'
                'int fake_close(int);\n',
}

DRIVER = r'''
#define _POSIX_C_SOURCE 200809L
#include <time.h>
static void sleep_ms(int ms) { struct timespec t = {0, ms * 1000000L}; nanosleep(&t, NULL); }
#include "ohaudio_sink.h"
#include "ohaudio/native_audiostreambuilder.h"
#include <poll.h>
#include <sys/eventfd.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

// ---- test-only OHAudio boundary: one renderer, the system's forced state changes are set by the test ----
struct OH_AudioRenderer {
    OH_AudioStream_State state;
    OH_AudioRenderer_OnWriteDataCallback data; OH_AudioRenderer_OnInterruptCallback interrupt; void *user;
};
struct OH_AudioStreamBuilder { struct OH_AudioRenderer pending; };
static struct OH_AudioRenderer *R;
static int starts, pauses, stops;
static uint64_t wakes;
static int last_poll_timeout;
int OH_AudioStreamBuilder_Create(OH_AudioStreamBuilder **b, OH_AudioStream_Type t) { (void)t; *b = calloc(1, sizeof **b); return 0; }
int OH_AudioStreamBuilder_Destroy(OH_AudioStreamBuilder *b) { free(b); return 0; }
int OH_AudioStreamBuilder_SetSamplingRate(OH_AudioStreamBuilder *b, int32_t v) { (void)b; (void)v; return 0; }
int OH_AudioStreamBuilder_SetChannelCount(OH_AudioStreamBuilder *b, int32_t v) { (void)b; (void)v; return 0; }
int OH_AudioStreamBuilder_SetSampleFormat(OH_AudioStreamBuilder *b, OH_AudioStream_SampleFormat v) { (void)b; (void)v; return 0; }
int OH_AudioStreamBuilder_SetEncodingType(OH_AudioStreamBuilder *b, OH_AudioStream_EncodingType v) { (void)b; (void)v; return 0; }
int OH_AudioStreamBuilder_SetLatencyMode(OH_AudioStreamBuilder *b, OH_AudioStream_LatencyMode v) { (void)b; (void)v; return 0; }
int OH_AudioStreamBuilder_SetRendererInfo(OH_AudioStreamBuilder *b, OH_AudioStream_Usage v) { (void)b; (void)v; return 0; }
int OH_AudioStreamBuilder_SetRendererWriteDataCallback(OH_AudioStreamBuilder *b, OH_AudioRenderer_OnWriteDataCallback f, void *u) { b->pending.data = f; b->pending.user = u; return 0; }
int OH_AudioStreamBuilder_SetRendererInterruptCallback(OH_AudioStreamBuilder *b, OH_AudioRenderer_OnInterruptCallback f, void *u) { b->pending.interrupt = f; (void)u; return 0; }
int OH_AudioStreamBuilder_SetRendererErrorCallback(OH_AudioStreamBuilder *b, OH_AudioRenderer_OnErrorCallback f, void *u) { (void)b; (void)f; (void)u; return 0; }
int OH_AudioStreamBuilder_SetRendererOutputDeviceChangeCallback(OH_AudioStreamBuilder *b, OH_AudioRenderer_OutputDeviceChangeCallback f, void *u) { (void)b; (void)f; (void)u; return 0; }
int OH_AudioStreamBuilder_GenerateRenderer(OH_AudioStreamBuilder *b, OH_AudioRenderer **r) {
    R = malloc(sizeof *R); *R = b->pending; R->state = AUDIOSTREAM_STATE_PREPARED; *r = R; return 0;
}
int OH_AudioRenderer_Release(OH_AudioRenderer *r) { free(r); R = NULL; return 0; }
int OH_AudioRenderer_Start(OH_AudioRenderer *r) { starts++; r->state = AUDIOSTREAM_STATE_RUNNING; return 0; }
int OH_AudioRenderer_Pause(OH_AudioRenderer *r) { pauses++; r->state = AUDIOSTREAM_STATE_PAUSED; return 0; }
int OH_AudioRenderer_Stop(OH_AudioRenderer *r) { stops++; r->state = AUDIOSTREAM_STATE_STOPPED; return 0; }
int OH_AudioRenderer_GetCurrentState(OH_AudioRenderer *r, OH_AudioStream_State *s) { *s = r->state; return 0; }
int OH_AudioRenderer_GetSamplingRate(OH_AudioRenderer *r, int32_t *v) { (void)r; *v = 48000; return 0; }
int OH_AudioRenderer_GetChannelCount(OH_AudioRenderer *r, int32_t *v) { (void)r; *v = 2; return 0; }
int OH_AudioRenderer_GetSampleFormat(OH_AudioRenderer *r, OH_AudioStream_SampleFormat *v) { (void)r; *v = AUDIOSTREAM_SAMPLE_S16LE; return 0; }
int OH_AudioRenderer_GetFrameSizeInCallback(OH_AudioRenderer *r, int32_t *v) { (void)r; *v = 480; return 0; }
int OH_AudioRenderer_GetUnderflowCount(OH_AudioRenderer *r, uint32_t *v) { (void)r; *v = 0; return 0; }
int eventfd(unsigned v, int f) { (void)v; (void)f; return 77; }
ssize_t fake_write(int fd, const void *p, size_t n) { (void)fd; (void)p; wakes++; return (ssize_t)n; }
ssize_t fake_read(int fd, void *p, size_t n) { (void)fd; memcpy(p, &wakes, sizeof wakes); wakes = 0; return (ssize_t)n; }
int fake_close(int fd) { (void)fd; return 0; }
int poll(struct pollfd *p, unsigned long n, int timeout) {   // never blocks; records the timeout asked for
    (void)n; last_poll_timeout = timeout; p->revents = wakes ? POLLIN : 0; return wakes ? 1 : 0;
}

// ---- helpers ----
static int16_t pcm[2 * 48000], out[2 * 4800];
static uint64_t frames_out(s2a_ohaudio *a) { struct s2a_ohaudio_stats s; s2a_ohaudio_stats(a, &s); return s.frames_out; }
static void queue(s2a_ohaudio *a, uint32_t frames) { if (s2a_ohaudio_write(a, pcm, frames * 4) != frames * 4) abort(); }
static void callback(uint32_t frames) { memset(out, 0x55, sizeof out); R->data(R, R->user, out, (int32_t)(frames * 4)); }
static int silent(uint32_t frames) { for (uint32_t i = 0; i < frames * 2; i++) if (out[i]) return 0; return 1; }
static int level(uint32_t frames, int v) { for (uint32_t i = 0; i < frames * 2; i++) if (out[i] != v) return 0; return 1; }
static void hint(OH_AudioInterrupt_ForceType t, OH_AudioInterrupt_Hint h) { R->interrupt(R, R->user, t, h); }
static s2a_ohaudio *open_started(void) {
    s2a_ohaudio *a = NULL;
    starts = pauses = stops = 0; wakes = 0;
    if (s2a_ohaudio_open(1, 48000, 2, 1000, &a) || s2a_ohaudio_start(a) || R->state != AUDIOSTREAM_STATE_RUNNING) abort();
    return a;
}
#define CHECK(c) do { if (!(c)) { printf("FAIL %s: %s (line %d)\n", name, #c, __LINE__); s2a_ohaudio_close(a); return 1; } } while (0)

// Shared PAUSE: renderer keeps running, callback consumes and outputs silence, owner is woken.
static int shared_pause(void) {
    const char *name = "shared-pause"; s2a_ohaudio *a = open_started();
    queue(a, 1920);
    hint(AUDIOSTREAM_INTERRUPT_SHARE, AUDIOSTREAM_INTERRUPT_HINT_PAUSE);
    s2a_ohaudio_service(a);
    CHECK(pauses == 0 && stops == 0 && R->state == AUDIOSTREAM_STATE_RUNNING);
    uint64_t before = frames_out(a); wakes = 0;
    s2a_ohaudio_notify_at(a, before + 480);
    callback(480);
    CHECK(silent(480));
    CHECK(frames_out(a) == before + 480);
    CHECK(wakes > 0);
    hint(AUDIOSTREAM_INTERRUPT_SHARE, AUDIOSTREAM_INTERRUPT_HINT_RESUME);
    s2a_ohaudio_service(a);
    CHECK(starts == 1);
    callback(480);
    CHECK(level(480, 1000));
    s2a_ohaudio_close(a); printf("PASS %s\n", name); return 0;
}
// Forced PAUSE/STOP: the system already suspended the renderer; service() drains at the stream rate.
static int forced(OH_AudioInterrupt_Hint h, OH_AudioStream_State system_state, const char *name) {
    s2a_ohaudio *a = open_started();
    queue(a, 4800);                                     // 100 ms
    R->state = system_state;
    hint(AUDIOSTREAM_INTERRUPT_FORCE, h);
    s2a_ohaudio_service(a);
    CHECK(starts == 1);                                 // never fights the system's pause
    uint64_t before = frames_out(a);
    struct timespec t0, t1; clock_gettime(CLOCK_MONOTONIC, &t0);
    int capped = 1;
    for (int i = 0; i < 200 && frames_out(a) < before + 4800; i++) {
        sleep_ms(5);
        s2a_ohaudio_wait(a, 1000);
        capped &= last_poll_timeout <= 10;
        s2a_ohaudio_service(a);
    }
    clock_gettime(CLOCK_MONOTONIC, &t1);
    double ms = (t1.tv_sec - t0.tv_sec) * 1e3 + (t1.tv_nsec - t0.tv_nsec) / 1e6;
    CHECK(frames_out(a) == before + 4800);              // every queued frame returned
    CHECK(ms >= 80);                                    // paced like playback, not dropped at once
    CHECK(capped);                                      // owner wakes at least every 10 ms meanwhile
    CHECK(starts == 1 && R->state == system_state);
    if (h == AUDIOSTREAM_INTERRUPT_HINT_PAUSE) hint(AUDIOSTREAM_INTERRUPT_SHARE, AUDIOSTREAM_INTERRUPT_HINT_RESUME);
    else CHECK(s2a_ohaudio_start(a) == 0);               // STOP: only an explicit start asks again
    s2a_ohaudio_service(a);
    CHECK(starts == 2 && R->state == AUDIOSTREAM_STATE_RUNNING);
    s2a_ohaudio_wait(a, 1000);
    CHECK(last_poll_timeout == 1000);                   // drain ended
    s2a_ohaudio_close(a); printf("PASS %s\n", name); return 0;
}
// Explicit pause by the game: nothing consumes (Android: stream paused when not running).
static int explicit_pause(void) {
    const char *name = "explicit-pause"; s2a_ohaudio *a = open_started();
    hint(AUDIOSTREAM_INTERRUPT_SHARE, AUDIOSTREAM_INTERRUPT_HINT_PAUSE);
    CHECK(s2a_ohaudio_pause(a) == 0 && pauses == 1);
    queue(a, 960);
    uint64_t before = frames_out(a);
    for (int i = 0; i < 6; i++) { sleep_ms(5); s2a_ohaudio_service(a); }
    callback(480);
    CHECK(frames_out(a) == before && silent(480));
    s2a_ohaudio_close(a); printf("PASS %s\n", name); return 0;
}
// Shared MUTE / DUCK keep consuming as well.
static int mute_duck(void) {
    const char *name = "mute-duck"; s2a_ohaudio *a = open_started();
    queue(a, 2880);
    hint(AUDIOSTREAM_INTERRUPT_SHARE, AUDIOSTREAM_INTERRUPT_HINT_MUTE);
    uint64_t before = frames_out(a);
    callback(960);
    CHECK(silent(960) && frames_out(a) == before + 960);
    hint(AUDIOSTREAM_INTERRUPT_SHARE, AUDIOSTREAM_INTERRUPT_HINT_UNMUTE);
    hint(AUDIOSTREAM_INTERRUPT_SHARE, AUDIOSTREAM_INTERRUPT_HINT_DUCK);
    callback(960);
    CHECK(level(960, 200) && frames_out(a) == before + 1920);
    CHECK(pauses == 0 && stops == 0);
    s2a_ohaudio_close(a); printf("PASS %s\n", name); return 0;
}
int main(void) {
    for (unsigned i = 0; i < sizeof pcm / sizeof *pcm; i++) pcm[i] = 1000;
    int failed = shared_pause();
    failed += forced(AUDIOSTREAM_INTERRUPT_HINT_PAUSE, AUDIOSTREAM_STATE_PAUSED, "forced-pause");
    failed += forced(AUDIOSTREAM_INTERRUPT_HINT_STOP, AUDIOSTREAM_STATE_STOPPED, "forced-stop");
    failed += explicit_pause();
    failed += mute_duck();
    printf("%d failed\n", failed);
    return failed ? 1 : 0;
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=HERE / 'ohaudio_sink.c', help='ohaudio_sink.c to test')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory() as tmp:
        tmp = Path(tmp)
        for name, text in HEADERS.items():
            (tmp / 'include' / name).parent.mkdir(parents=True, exist_ok=True)
            (tmp / 'include' / name).write_text(text, encoding='utf8')
        driver, exe = tmp / 'focus.c', tmp / ('focus.exe' if os.name == 'nt' else 'focus')
        driver.write_text(DRIVER, encoding='utf8')
        sink = tmp / 'ohaudio_sink.c'   # copied so "ohaudio_sink.h"/"pcm_output.h" resolve via -I
        sink.write_text(args.source.read_text(encoding='utf8'), encoding='utf8')
        subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', '-Wall', '-Wextra', '-I', str(tmp / 'include'), '-I', str(HERE),
                        str(driver), str(sink), str(HERE / 'pcm_output.c'), str(REPO / 'android/native/pcm_ring.c'),
                        '-pthread', '-o', str(exe)], check=True)
        return subprocess.run([str(exe)], timeout=60).returncode


if __name__ == '__main__':
    raise SystemExit(main())
