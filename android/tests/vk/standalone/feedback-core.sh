#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
set -euo pipefail
repo=$(cd "$(dirname "$0")/../../../.." && pwd)
out="$repo/build/vk-feedback-core"
mkdir -p "$out/shaders"
: "${S2A_LAVAPIPE_ICD:?lavapipe required}"
: "${S2A_VK_LAYER_DIR:?validation required}"
[ -f "$repo/build/c883-ndk/vulkan/vulkan_core.h" ] || { echo 'NDK 29 headers missing' >&2; exit 2; }
glslc=${GLSLC:-glslc}
for shader in feedback feedback_pool feedback_pool_phantom feedback_combined feedback_depth; do
    "$glslc" --target-env=vulkan1.1 "$repo/android/tests/vk/shaders/$shader.frag" -o "$out/shaders/$shader.frag.spv"
done
"$glslc" --target-env=vulkan1.1 "$repo/android/native/nvn/blit_shaders/fullscreen.vert" -o "$out/shaders/fullscreen.vert.spv"
inc=()
for d in android/tests/vkhost build/c883-ndk graphics/nvn graphics/nvn/replay graphics/nvn/gfx/nvn graphics/nvn/gfx/nvn/include android/native android/native/nvn android/native/direct runtime/include; do inc+=(-I "$repo/$d"); done
src=("$repo/android/tests/vk/t_feedback.c" "$repo/graphics/nvn/replay/nvn_unimpl.c")
for f in android/native/nvn/backend_vulkan.c android/native/nvn/nvn_pipe_flight.c android/native/nvn/nvn_vk_pipe_once.c android/native/direct/vk_device.c android/native/direct/gs_path.c android/native/capprobe/capprobe_host.c android/native/nvn/nvn_vk_format.c graphics/nvn/gfx/nvn/nvn_fmt_expand.c android/native/nvn/nvn_vk_bcdec.c android/native/nvn/nvn_vk_driver_cache.c android/native/direct/sha256.c; do src+=("$repo/$f"); done
wrap=()
for fn in vkCreateImageView vkCreateFramebuffer vkCmdBeginRenderPass vkUpdateDescriptorSets vkCmdBindDescriptorSets vkCmdDraw vkCmdCopyImage vkGetDeviceProcAddr vkDestroyImageView vkWaitForFences; do wrap+=(-Wl,--wrap="$fn"); done
cc -D_POSIX_C_SOURCE=200809L -std=c11 -O1 -g -Wall -Wextra -Werror -Wno-unused-parameter \
    -ffunction-sections -fdata-sections -DS2A_ANDROID_VK_BACKEND_NVN_VK=1 \
    "${inc[@]}" "${src[@]}" "${wrap[@]}" -Wl,--gc-sections -lvulkan -lpthread -lm -o "$out/test"
export VK_ICD_FILENAMES="$S2A_LAVAPIPE_ICD" VK_LAYER_PATH="$S2A_VK_LAYER_DIR" VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation
# run.sh 在调用此独立入口之后才开同步校验，不能依赖父进程或本地包装器。
# 同计算写入负控一样同时打开 shader 访问启发式；仅加载 validation 层不够。
export VK_LAYER_ENABLES=VK_VALIDATION_FEATURE_ENABLE_SYNCHRONIZATION_VALIDATION_EXT
cat > "$out/vk_layer_settings.txt" <<'SETTINGS'
khronos_validation.validate_sync = true
khronos_validation.syncval_shader_accesses_heuristic = true
SETTINGS
export VK_LAYER_SETTINGS_PATH="$out/vk_layer_settings.txt"
printf 'feedback validation: sync=1 shader_accesses_heuristic=1 settings=%s\n' "$VK_LAYER_SETTINGS_PATH"
failed=0
# 旧行为（nvk_pool_fb=1）：整池数组也为写着的附件拷快照。同步校验开着，必须零冒险、零校验报错。
for dq in 0 1; do
    for opt in 0 1; do
        set +e
        timeout 120 "$out/test" "$out/shaders" "$dq" "$opt" 1 1 2>&1 | tee "$out/dq$dq-opt$opt.log"
        rc=${PIPESTATUS[0]}
        set -e
        if [ "$rc" -ne 0 ] || grep -qE 'Validation Error|VUID-' "$out/dq$dq-opt$opt.log" ||
           ! grep -q "feedback cases=$((18 - opt)) failures=0" "$out/dq$dq-opt$opt.log"; then
            echo "【红】feedback DQ=$dq OPT=$opt pool_fb=1 rc=$rc or validation failure" >&2; failed=1
        fi
    done
done
# 缺省（nvk_pool_fb=0）：整池数组与写着的附件重叠，不拷快照、不拆通道（对齐 Ryujinx：数组段不做反馈环追踪）。
#   opt=0：案例 10（真读本通道附件）、15（只登记、不读）故意保留描述符别名，同步校验会（也应当）报冒险，
#          所以这一组只关同步校验、保留核心校验；其余案例（显式绑定、深度、中止）的数字与旧行为一致。
#   opt=1：沿用旧行为，同步校验照开，必须零冒险（案例 15 要求池里的图都是 GENERAL，该模式不跑；故 17 → 16 个案例）。
#   案例 16：池里登记的是「本笔没写」的附件，缺省与旧行为一样照旧拷快照、拆通道。
cat > "$out/vk_layer_settings_nosync.txt" <<'SETTINGS'
khronos_validation.validate_sync = false
SETTINGS
for dq in 0 1; do
    for opt in 0 1; do
        set +e
        if [ "$opt" -eq 0 ]; then
            env -u VK_LAYER_ENABLES VK_LAYER_SETTINGS_PATH="$out/vk_layer_settings_nosync.txt" \
                timeout 120 "$out/test" "$out/shaders" "$dq" "$opt" 1 0 2>&1 | tee "$out/dq$dq-opt$opt-poolskip.log"
        else
            timeout 120 "$out/test" "$out/shaders" "$dq" "$opt" 1 0 2>&1 | tee "$out/dq$dq-opt$opt-poolskip.log"
        fi
        rc=${PIPESTATUS[0]}
        set -e
        if [ "$rc" -ne 0 ] || grep -qE 'Validation Error|VUID-' "$out/dq$dq-opt$opt-poolskip.log" ||
           ! grep -q "feedback cases=$((18 - opt)) failures=0" "$out/dq$dq-opt$opt-poolskip.log"; then
            echo "【红】feedback DQ=$dq OPT=$opt pool_fb=0 rc=$rc or validation failure" >&2; failed=1
        fi
    done
done
# 两种模式的读数必须真的不同（防止开关没接上、两边测的是同一件事）：
# 缺省：15 号案例 2 笔 draw 拷 0 份、整个命令只开 3 次通道；旧行为：拷 2 份、多重开 2 次。
if ! grep -q 'pool_fb=0 case=15 draws=2 live-overlap=2 copies=0 copy-bad=0 begins=3 ' "$out/dq0-opt0-poolskip.log" ||
   ! grep -q 'pool_fb=1 case=15 draws=2 live-overlap=0 copies=2 copy-bad=0 begins=5 ' "$out/dq0-opt0.log"; then
    echo '【红】feedback 案例 15：缺省 / 旧行为的读数没有分开（期望 拷 0 份开 3 次通道 / 拷 2 份开 5 次通道）' >&2; failed=1
fi
# Negative control disables the whole snapshot path (copy + barriers + descriptor
# substitution), with the same binary and real driver / validation configuration.
set +e
timeout 120 "$out/test" "$out/shaders" 1 0 0 1 > "$out/negative.log" 2>&1
negative_rc=$?
set -e
if [ "$negative_rc" -ne 1 ] ||
   ! grep -q 'case=3 draws=2 live-overlap=2 copies=0 copy-bad=1 begins=[0-9]* begins-bad=0 overlap-bad=1 pixel-bad=0' "$out/negative.log" ||
   ! grep -q 'feedback cases=18 failures=' "$out/negative.log" ||
   ! grep -q 'SYNC-HAZARD-READ-AFTER-WRITE' "$out/negative.log"; then
    echo '【红】feedback negative did not reach the expected alias failure' >&2
    tail -n 40 "$out/negative.log";failed=1
else
    echo 'feedback negative: PASS (same binary, copy off, live alias + VVL hazard detected)'
fi
exit "$failed"
