// SPDX-License-Identifier: MIT
// Calibrated report timestamps: host nanoseconds only, never guest clock ticks.
#pragma once
#include <math.h>
#include <stdint.h>
#include "nvn_vk_ts_math.h"

// Why a conversion was refused (0 = converted): 1 bad args / clock order, 2 window over half a counter cycle,
// 3 out of range, 4 sample before the window, 5 sample after the window (both after widening by the deviation).
static inline int s2a_report_ts_convert_why(uint64_t raw, uint64_t gpu, uint64_t host,
        uint32_t bits, double period, uint64_t begin, uint64_t end, uint64_t deviation, uint64_t *out) {
    if (!out || !bits || bits > 64 || !isfinite(period) || period <= 0 || end < begin || host < begin || host > end) return 1;
    // The signed modular difference is unique only within half a counter cycle.
    long double half = (long double)(UINT64_C(1) << (bits - 1)) * period;
    if ((long double)(end - begin) + deviation >= half) return 2;
    long double ns = (long double)host + (long double)s2a_ts_wrap_diff(raw, gpu, bits) * period;
    // Avoid floating-to-integer overflow (UINT64_MAX may round up on some hosts).
    if (ns < 0 || ns >= 18446744073709551616.0L) return 3;
    // Conservative validity: the entire calibration uncertainty must fit the
    // recording-to-completion window. Never clamp an uncertain sample into it.
    if (ns - deviation < (long double)begin) return 4;
    if (ns + deviation > (long double)end) return 5;
    *out = (uint64_t)ns;
    return 0;
}
static inline int s2a_report_ts_convert(uint64_t raw, uint64_t gpu, uint64_t host,
        uint32_t bits, double period, uint64_t begin, uint64_t end, uint64_t deviation, uint64_t *out) {
    return s2a_report_ts_convert_why(raw, gpu, host, bits, period, begin, end, deviation, out) == 0;
}
