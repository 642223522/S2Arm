// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#include "pcm_output.h"
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    struct s2a_ohos_pcm_output out;
    assert(s2a_ohos_pcm_init(&out, S2A_PCM_I16, 48000, 3, 20) == EINVAL);
    assert(s2a_ohos_pcm_init(&out, S2A_PCM_I16, 48000, 2, 1) == 0);
    // 48 frames * 2 channels * 2 bytes: rounding the storage must not add latency.
    assert(s2a_ohos_pcm_space(&out) == 192);
    int16_t input[2048], output[2048];
    for (unsigned i = 0; i < 2048; ++i) input[i] = 1234;
    assert(s2a_ohos_pcm_write(&out, input, sizeof input) == 192);
    s2a_ohos_pcm_read(&out, output, 48);
    for (unsigned i = 0; i < 96; ++i) assert(output[i] == 1234);
    assert(s2a_ohos_pcm_space(&out) == 192);
    // Repeated wrapping preserves sample order and the exact logical capacity.
    for (unsigned round = 0; round < 20; ++round) {
        input[0] = (int16_t)round;
        assert(s2a_ohos_pcm_write(&out, input, 192) == 192);
        s2a_ohos_pcm_read(&out, output, 48);
        assert(output[0] == (int16_t)round);
    }
    s2a_ohos_pcm_free(&out);
    assert(s2a_ohos_pcm_init(&out, S2A_PCM_I16, 48000, 2, 100) == 0);
    input[0] = 1234;
    assert(s2a_ohos_pcm_write(&out, input, 40) == 40); // ten final frames
    // A short final packet cannot wait forever for a 20 ms cushion.
    for (unsigned callback = 0; callback < 4; ++callback) {
        memset(output, 0x55, sizeof output);
        s2a_ohos_pcm_read(&out, output, 480); // ten milliseconds
        for (unsigned i = 0; i < 960; ++i) assert(output[i] == 0);
        assert(atomic_load(&out.ring.frames_out) == 0);
    }
    s2a_ohos_pcm_read(&out, output, 480);
    for (unsigned i = 0; i < 20; ++i) assert(output[i] == 1234);
    for (unsigned i = 20; i < 960; ++i) assert(output[i] == 0);
    assert(atomic_load(&out.ring.frames_out) == 10);
    assert(atomic_load(&out.ring.frames_padded) == 2390);
    s2a_ohos_pcm_reset(&out);
    assert(s2a_ohos_pcm_write(&out, input, 3840) == 3840); // full 20 ms cushion
    s2a_ohos_pcm_read(&out, output, 480);
    for (unsigned i = 0; i < 960; ++i) assert(output[i] == 1234);
    assert(atomic_load(&out.ring.frames_out) == 490);
    s2a_ohos_pcm_free(&out);
    puts("PCM output: capacity, wrap, final-packet deadline, padding and reset passed");
    return 0;
}
