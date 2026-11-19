// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#ifndef S2A_SPIRV_SAMPLER_USE_H
#define S2A_SPIRV_SAMPLER_USE_H
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
// 保守证明：单项 combined descriptor 只经 Load -> Image -> 不使用采样器的查询。
// 任意别的使用（含采样、gather、QueryLod、别名/函数参数）均不作此证明。
static inline int s2a_spirv_sampler_unused(const uint32_t *w, size_t bytes, unsigned set, unsigned binding) {
    if (!w || bytes < 20 || bytes % 4 || w[0] != 0x07230203u || !w[3] || w[3] > 65536) return 0;
    size_t words = bytes / 4;
    uint8_t *ids = calloc(w[3], 1);
    if (!ids) return 0;
    int result = 0; uint32_t var = 0, pointer = 0, sampled = 0, image = 0;
    for (size_t i = 5; i < words;) {
        unsigned n = w[i] >> 16, op = w[i] & 65535;
        if (!n || n > words - i) goto done;
        if (op == 71 && n == 4 && w[i + 1] < w[3]) {
            uint8_t *f = &ids[w[i + 1]];
            if (w[i + 2] == 34) *f |= w[i + 3] == set ? 1 : 4;
            if (w[i + 2] == 33) *f |= w[i + 3] == binding ? 2 : 8;
        }
        i += n;
    }
    for (size_t i = 5; i < words; i += w[i] >> 16) {
        unsigned n = w[i] >> 16, op = w[i] & 65535;
        if (op == 59 && n >= 4 && w[i + 2] < w[3] && ids[w[i + 2]] == 3 && w[i + 3] == 0) {
            if (var) goto done;
            var = w[i + 2]; pointer = w[i + 1];
        }
    }
    if (!var) goto done;
    for (size_t i = 5; i < words; i += w[i] >> 16)
        if ((w[i] & 65535) == 32 && (w[i] >> 16) == 4 && w[i + 1] == pointer && w[i + 2] == 0) sampled = w[i + 3];
    for (size_t i = 5; i < words; i += w[i] >> 16)
        if ((w[i] & 65535) == 27 && (w[i] >> 16) == 3 && w[i + 1] == sampled) image = w[i + 2];
    if (!image) goto done;
    for (uint32_t i = 0; i < w[3]; ++i) ids[i] = 0;
    int body = 0, loads = 0, queries = 0;
    for (size_t i = 5; i < words; i += w[i] >> 16) {
        unsigned n = w[i] >> 16, op = w[i] & 65535;
        if (op == 54) body = 1;
        if (body) for (unsigned j = 1; j < n; ++j) if (w[i + j] == var) {
            if (op != 61 || j != 3 || n != 4 || w[i + 1] != sampled || w[i + 2] >= w[3]) goto done;
            ids[w[i + 2]] |= 1; loads++;
        }
        if (op == 56) body = 0;
    }
    if (!loads) goto done;
    body = 0;
    for (size_t i = 5; i < words; i += w[i] >> 16) {
        unsigned n = w[i] >> 16, op = w[i] & 65535;
        if (op == 54) body = 1;
        if (body) for (unsigned j = 1; j < n; ++j) if (w[i + j] < w[3] && (ids[w[i + j]] & 1)) {
            if (op == 61 && j == 2) continue; // 定义位置不是使用。
            if (op != 100 || j != 3 || n != 4 || w[i + 1] != image || w[i + 2] >= w[3]) goto done;
            ids[w[i + 2]] |= 2;
        }
        if (op == 56) body = 0;
    }
    body = 0;
    for (size_t i = 5; i < words; i += w[i] >> 16) {
        unsigned n = w[i] >> 16, op = w[i] & 65535;
        if (op == 54) body = 1;
        if (body) for (unsigned j = 1; j < n; ++j) if (w[i + j] < w[3] && (ids[w[i + j]] & 2)) {
            if (op == 100 && j == 2) continue;
            if (j != 3 || !(op == 101 || op == 102 || op == 103 || op == 104 || op == 106 || op == 107)) goto done;
            queries++;
        }
        if (op == 56) body = 0;
    }
    result = queries > 0;
done:
    free(ids); return result;
}
#endif
