// SPDX-License-Identifier: MIT
// CPU-only calibration arithmetic; does not claim Vulkan/VVL execution coverage.
#include <assert.h>
#include <stdio.h>
#include "nvn_vk_report_ts.h"

int main(void) {
    uint64_t a = 99, b = 99;
    assert(s2a_report_ts_convert(100, 300, 1000, 64, 2, 0, 500, &a) && a == 600);
    assert(s2a_report_ts_convert(200, 300, 1000, 64, 2, 0, 500, &b) && b == 800);
    assert(a != b); // CPU-completion substitution and dropped slots must not pass.
    assert(s2a_report_ts_convert(250, 5, 1000, 8, 2, 0, 100, &a) && a == 978);
    assert(s2a_report_ts_convert(5, 250, 1000, 8, 2, 0, 100, &a) && a == 1022);
    assert(s2a_report_ts_convert(0, 10, 10, 64, 1, 0, 10, &a) && a == 0);
    assert(!s2a_report_ts_convert(0, 11, 10, 64, 1, 0, 10, &a));
    assert(!s2a_report_ts_convert(1, 0, UINT64_MAX, 64, 1, 0, 10, &a));
    assert(!s2a_report_ts_convert(0, 0, 0, 0, 1, 0, 0, &a));
    assert(!s2a_report_ts_convert(0, 0, 0, 65, 1, 0, 0, &a));
    assert(!s2a_report_ts_convert(0, 0, 0, 8, 0, 0, 0, &a));
    assert(!s2a_report_ts_convert(0, 0, 0, 8, NAN, 0, 0, &a));
    assert(!s2a_report_ts_convert(0, 0, 0, 8, INFINITY, 0, 0, &a));
    assert(!s2a_report_ts_convert(0, 0, 0, 8, 1, 0, 128, &a));
    assert(!s2a_report_ts_convert(0, 0, 0, 8, 1, 10, 9, &a));
    puts("report_ts_test: PASS");
}
