# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
cmake_minimum_required(VERSION 3.5)
project(probe C)
add_library(probe SHARED napi_probe.c probe.c)
target_link_libraries(probe PUBLIC libace_napi.z.so libhilog_ndk.z.so libvulkan.so)
