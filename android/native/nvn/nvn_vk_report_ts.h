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

// Self-calibration against the driver's calibrated pair. Some drivers (Adreno 830, driver 0x80320049) return a
// DEVICE-domain value from vkGetCalibratedTimestamps whose zero differs from vkCmdWriteTimestamp's by a constant
// (measured 73.18 M ticks = 3.81 s), so every converted sample lands outside its recording window. A probe submit
// that only writes one timestamp gives a host window [begin, end] that must contain the sample: the correction is
// the window centre minus the driver-based conversion. Within the combined uncertainty the driver is trusted
// (correction 0, extra uncertainty 0); otherwise the correction is kept with half the probe window as extra
// uncertainty. Returns 0 when the inputs cannot be converted at all.
static inline int s2a_report_ts_self_offset(uint64_t raw, uint64_t gpu, uint64_t host, uint32_t bits, double period,
        uint64_t begin, uint64_t end, uint64_t deviation, int64_t *corr, uint64_t *extra) {
    if (!corr || !extra || !bits || bits > 64 || !isfinite(period) || period <= 0 || end < begin) return 0;
    long double ns = (long double)host + (long double)s2a_ts_wrap_diff(raw, gpu, bits) * period;
    long double mid = ((long double)begin + (long double)end) / 2;
    long double half = ((long double)end - (long double)begin) / 2;
    long double d = mid - ns;
    if (!(d > -9.0e18L && d < 9.0e18L)) return 0;   // also rejects NaN
    if ((d < 0 ? -d : d) <= half + (long double)deviation) { *corr = 0; *extra = 0; return 1; }
    *corr = (int64_t)d;
    *extra = (uint64_t)(half + 0.5L);
    return 1;
}
