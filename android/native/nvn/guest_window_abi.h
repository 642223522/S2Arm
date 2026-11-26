// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#pragma once
#include <stddef.h>
#include <stdint.h>
// ANativeWindow 的公开 LP64 ABI 前缀；这里只描述字段，不包含 SDK 私有 Surface 布局。
// https://android.googlesource.com/platform/system/core/+/a744b05/include/system/window.h
struct s2a_guest_window_prefix {
    uint32_t magic, version;
    uintptr_t reserved[4], inc_ref, dec_ref;
    uint32_t flags;
    int32_t min_interval, max_interval;
    float xdpi, ydpi;
    uintptr_t oem[4];
    uintptr_t set_interval, dequeue_old, lock_old, queue_old, query, perform;
};
_Static_assert(offsetof(struct s2a_guest_window_prefix, perform) == 152, "ANativeWindow LP64 perform offset");
