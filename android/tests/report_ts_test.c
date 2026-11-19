// SPDX-License-Identifier: MIT
// CPU-only calibration arithmetic; does not claim Vulkan/VVL execution coverage.
#include <assert.h>
#include <stdio.h>
#include "nvn_vk_report_ts.h"

int main(void) {
    uint64_t a = 99, b = 99;
    assert(s2a_report_ts_convert(100, 300, 1000, 64, 2, 0, 1100, 0, &a) && a == 600);
    assert(s2a_report_ts_convert(200, 300, 1000, 64, 2, 0, 1100, 0, &b) && b == 800);
    assert(a != b); // CPU-completion substitution and dropped slots must not pass.
    assert(s2a_report_ts_convert(250, 5, 1000, 8, 2, 950, 1050, 0, &a) && a == 978);
    assert(s2a_report_ts_convert(5, 250, 1000, 8, 2, 950, 1050, 0, &a) && a == 1022);
    assert(s2a_report_ts_convert(0, 10, 10, 64, 1, 0, 10, 0, &a) && a == 0);
    assert(!s2a_report_ts_convert(0, 11, 10, 64, 1, 0, 10, 0, &a));
    assert(!s2a_report_ts_convert(1, 0, UINT64_MAX, 64, 1, 0, 10, 0, &a));
    assert(!s2a_report_ts_convert(0, 0, 0, 0, 1, 0, 0, 0, &a));
    assert(!s2a_report_ts_convert(0, 0, 0, 65, 1, 0, 0, 0, &a));
    assert(!s2a_report_ts_convert(0, 0, 0, 8, 0, 0, 0, 0, &a));
    assert(!s2a_report_ts_convert(0, 0, 0, 8, NAN, 0, 0, 0, &a));
    assert(!s2a_report_ts_convert(0, 0, 0, 8, INFINITY, 0, 0, 0, &a));
    assert(!s2a_report_ts_convert(0, 0, 0, 8, 1, 0, 128, 0, &a));
    assert(!s2a_report_ts_convert(0, 0, 0, 8, 1, 10, 9, 0, &a));
    a = 99;
    assert(!s2a_report_ts_convert(100, 300, 1000, 64, 2, 700, 1100, 0, &a)); // before recording
    assert(!s2a_report_ts_convert(400, 300, 1000, 64, 2, 0, 1100, 0, &a)); // after completion
    assert(a == 99); // invalid does not overwrite the caller's value
    assert(s2a_report_ts_convert(100, 300, 1000, 64, 2, 590, 1100, 10, &a) && a == 600);
    assert(!s2a_report_ts_convert(100, 300, 1000, 64, 2, 590, 1100, 11, &a)); // uncertain lower boundary
    assert(!s2a_report_ts_convert(300, 300, 1000, 64, 2, 0, 1009, 10, &a)); // uncertain upper boundary
    assert(!s2a_report_ts_convert(100, 100, 100, 8, 1, 0, 120, 8, &a)); // uncertainty reaches half cycle
    assert(!s2a_report_ts_convert(100, 100, 100, 64, 1, 0, 120, UINT64_MAX, &a));
    // Self-calibration (hand-computed, period 1): driver DEVICE value 5400 ticks ahead of the query counter.
    int64_t corr = 7; uint64_t extra = 7;
    assert(s2a_report_ts_self_offset(500, 500, 9000, 64, 1, 8990, 9010, 0, &corr, &extra) && corr == 0 && extra == 0); // driver right
    assert(s2a_report_ts_self_offset(100, 5500, 9400, 64, 1, 8990, 9010, 0, &corr, &extra) && corr == 5000 && extra == 10);
    // Negative control: the raw driver pair puts the sample at 4000, before a [8000, 9500] recording window.
    assert(!s2a_report_ts_convert(100, 5500, 9400, 64, 1, 8000, 9500, 10, &a));
    // Correction applied on the GPU side (gpu - corr ticks), host unchanged: the sample lands at 9000.
    assert(s2a_report_ts_convert(100, 5500 - 5000, 9400, 64, 1, 8000, 9500, 10, &a) && a == 9000);
    // Same on a 48-bit counter: the corrected GPU value wraps below zero and is masked back.
    {
        uint64_t m = s2a_ts_valid_mask(48), g = ((uint64_t)1000 - 6500) & m;   // 1000 - 6500 < 0: wraps, masked to 48 bits
        assert(s2a_report_ts_self_offset(100, 1000, 9400, 48, 1, 14990, 15010, 0, &corr, &extra) && corr == 6500);
        assert(!s2a_report_ts_convert(100, 1000, 9400, 48, 1, 9000, 15500, 10, &a));   // uncorrected: 8500, before the window
        assert(s2a_report_ts_convert(100, g, 9400, 48, 1, 9000, 15500, 10, &a) && a == 15000);
    }
    // Inside the combined uncertainty (half window 10 + deviation 5): trust the driver.
    assert(s2a_report_ts_self_offset(100, 100, 9015, 64, 1, 8990, 9010, 5, &corr, &extra) && corr == 0 && extra == 0);
    assert(s2a_report_ts_self_offset(100, 100, 9016, 64, 1, 8990, 9010, 5, &corr, &extra) && corr == -16 && extra == 10);
    corr = 7; extra = 7;
    assert(!s2a_report_ts_self_offset(0, 0, 0, 0, 1, 0, 1, 0, &corr, &extra));
    assert(!s2a_report_ts_self_offset(0, 0, 0, 64, NAN, 0, 1, 0, &corr, &extra));
    assert(!s2a_report_ts_self_offset(0, 0, 0, 64, 1, 2, 1, 0, &corr, &extra));
    assert(!s2a_report_ts_self_offset(0, 0, 0, 64, 1, 0, 1, 0, NULL, &extra));
    assert(corr == 7 && extra == 7); // rejected inputs leave outputs untouched
    puts("report_ts_test: PASS");
}
