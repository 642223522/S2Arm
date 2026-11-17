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
    puts("report_ts_test: PASS");
}
