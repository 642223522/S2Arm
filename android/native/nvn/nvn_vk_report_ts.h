// SPDX-License-Identifier: MIT
// Calibrated report timestamps: host nanoseconds only, never guest clock ticks.
#pragma once
#include <math.h>
#include <stdint.h>
#include "nvn_vk_ts_math.h"

static inline int s2a_report_ts_convert(uint64_t raw, uint64_t gpu, uint64_t host,
        uint32_t bits, double period, uint64_t begin, uint64_t end, uint64_t *out) {
    if (!bits || bits > 64 || !isfinite(period) || period <= 0 || end < begin) return 0;
    // The signed modular difference is unique only within half a counter cycle.
    long double half = (long double)(UINT64_C(1) << (bits - 1)) * period;
    if ((long double)(end - begin) >= half) return 0;
    long double ns = (long double)host + (long double)s2a_ts_wrap_diff(raw, gpu, bits) * period;
    // Avoid floating-to-integer overflow (UINT64_MAX may round up on some hosts).
    if (ns < 0 || ns >= 18446744073709551616.0L) return 0;
    *out = (uint64_t)ns;
    return 1;
}
