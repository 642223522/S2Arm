#!/bin/bash
# 安卓设备能力预检（tools/android_devcaps.py）单测：规则从 vk_device.c 读出、手工规则锚点仍在源码里、合成设备档判定正确（不出真机，约 1 秒）
# 门禁输入：tools/android_devcaps.py android/native/direct/vk_device.c android/native/direct/provider_vk.c android/native/nvn/nvn_vk_swapchain.c android/native/nvn/nvn_vk_draw.c android/native/nvn/backend_vulkan.c
set -u; H=$(cd "$(dirname "$0")/.." && pwd)
exec "${S2A_PY:-python3}" "$H/tests/android_devcaps_test.py"
