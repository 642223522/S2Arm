#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 两级回放队列（android/native/nvn/nvn_vk_dq.inc）宿主用例：真队列 + 真录制线程 + 记录桩，外加六种变异的负对照。
#   正控：真实现必须全绿；有 ThreadSanitizer 时再用它编一份，必须零报告（没有就跳过，不算红）；
#   负控：每种变异改一份临时 .inc，必须以「红」收场，并且红在预期的那个阶段（不是别处）：
#     M1 记录还没写完就发布              → 录制线程读到半条记录（C1：序列哈希 / 条数不符、没登记的调用，或崩溃）
#     M2 清空不等录制线程                → 清空返回时欠账（C1 收尾条数不足 / C2 跨线程清空）
#     M3 写满环时不等录制线程腾位置      → 没读的记录被覆盖（C1 / C3：序列错 / 崩溃 / 超时）
#     M4 环尾跳过记录的长度写错          → 录制线程跳到错位的地方（C1 第一次回绕：序列错 / 崩溃 / 超时）
#     M5 先报「已读」再执行这一条        → 清空在最后一条做完之前返回（C2 欠账）
#     M6 先走的清空线程抹掉别人的「在等」标记 → 后到的没人叫醒，等满 1 秒超时（C5；这是修前主线的行为）
set -euo pipefail
ulimit -c 0 2> /dev/null || true   # 变异用例可能崩溃（M1 常见）：不留 core 文件
repo=$(cd "$(dirname "$0")/../.." && pwd)
if [ "$(uname -s)" != Linux ]; then   # 队列用 pthread 自旋锁，苹果系统没有；android/test.sh 只在 Linux 门禁里调本脚本
    echo '【红】两级回放队列宿主用例只在 Linux 上跑（队列用 pthread 自旋锁，苹果系统没有）' >&2; exit 2
fi
mkdir -p "$repo/build/dq-queue-tmp"
out=$(mktemp -d "$repo/build/dq-queue-tmp/run.XXXXXX")
trap 'rm -rf "$out"' EXIT

cflags=(-std=gnu11 -D_GNU_SOURCE -O2 -g -Wall -Wextra -Werror -Wno-unused-parameter)
inc=(-I "$repo/android/tests/vkhost" -I "$repo/graphics/nvn/third_party/vulkan-headers/include" -I "$repo/graphics/nvn/replay")
test_c="$repo/android/tests/dq_queue_test.c"
inc_src="$repo/android/native/nvn/nvn_vk_dq.inc"

build() {   # $1 = 可执行文件，$2 = 额外的 -I（变异 .inc 所在目录；排在前面，包含时先找到它），其余 = 额外编译选项
    local exe=$1 mdir=$2; shift 2
    local extra=(); if [ -n "$mdir" ]; then extra=(-I "$mdir"); fi
    cc "${cflags[@]}" "${extra[@]}" "${inc[@]}" -I "$repo/android/native/nvn" "$@" "$test_c" -o "$exe" -lpthread
}
run() {   # $1 = 可执行文件，$2 = 日志；返回码留在 rc
    set +e
    "$1" >"$2" 2>&1
    rc=$?
    set -e
}

# ---- 正控：真实现
build "$out/real" ""
run "$out/real" "$out/log_real"
cat "$out/log_real"
if [ "$rc" -ne 0 ] || ! grep -q '^dq_queue_test：.*，0 项红' "$out/log_real" || grep -q '【红】' "$out/log_real"; then
    echo "【红】两级回放队列宿主用例（真实现）：rc=$rc" >&2; exit 1
fi

# ---- 正控（TSan）：同一份用例换 ThreadSanitizer 编
tsan_pre=(); tsan_ok=0
if echo 'int main(void){return 0;}' | cc -fsanitize=thread -x c - -o "$out/tsan_probe" 2>/dev/null; then
    # 新内核的随机映射范围超出 TSan 的假设（WSL2 常见），而且是随机地时好时坏：探针这次过了，正式跑那次不一定过。
    # 所以只要有 setarch 就一律用它把这一个进程的地址随机化关掉（不动系统设置）；没有 setarch 才直接跑。
    if command -v setarch >/dev/null && setarch "$(uname -m)" -R "$out/tsan_probe" 2>/dev/null; then
        tsan_ok=1; tsan_pre=(setarch "$(uname -m)" -R)
    elif "$out/tsan_probe" 2>/dev/null; then tsan_ok=1
    fi
fi
if [ "$tsan_ok" -eq 1 ]; then
    build "$out/tsan" "" -fsanitize=thread -O1 -DTEST_TIMEOUT_S=900
    set +e
    TSAN_OPTIONS="halt_on_error=1:exitcode=66" ${tsan_pre[@]+"${tsan_pre[@]}"} "$out/tsan" >"$out/log_tsan" 2>&1
    rc=$?
    set -e
    tail -n 3 "$out/log_tsan"
    if [ "$rc" -ne 0 ] || grep -q 'WARNING: ThreadSanitizer' "$out/log_tsan"; then
        cat "$out/log_tsan" >&2; echo "【红】两级回放队列宿主用例（TSan）：rc=$rc" >&2; exit 1
    fi
    echo "TSan：零报告"
else
    echo "（本机没有 ThreadSanitizer，跳过 TSan 那一份）"
fi

# ---- 负控：六种变异
mutate() {   # $1 = 变异名，$2 = 原文，$3 = 改成
    mkdir -p "$out/m_$1"
    python3 - "$inc_src" "$out/m_$1/nvn_vk_dq.inc" "$2" "$3" <<'PYMUT'
import pathlib, sys
src, dst, a, b = sys.argv[1:]
s = pathlib.Path(src).read_text(encoding="utf-8")
if s.count(a) != 1:
    raise SystemExit('变异锚点变了（应恰好出现 1 次，实为 %d 次）：%s' % (s.count(a), a))
pathlib.Path(dst).write_text(s.replace(a, b), encoding="utf-8")
PYMUT
}
neg() {   # $1 = 变异名，$2 = 日志里必须出现的红（正则），$3 = 第一条红发生时所在阶段（正则），$4 = 1：没有红行但在该阶段崩溃（信号）也算
    build "$out/neg_$1" "$out/m_$1" -DTEST_TIMEOUT_S=40
    run "$out/neg_$1" "$out/log_$1"
    local first_red phase_at ok=0
    first_red=$(grep -m1 '【红】' "$out/log_$1" || true)
    if [ -n "$first_red" ]; then
        phase_at=$(awk '/^阶段开始：/ { ph = $0 } /【红】/ { print ph; exit }' "$out/log_$1")
        if [ "$rc" -ne 0 ] && grep -qE "$2" "$out/log_$1" && printf '%s' "$phase_at" | grep -qE "$3"; then ok=1; fi
    elif [ "${4:-0}" = 1 ] && [ "$rc" -ge 128 ]; then
        phase_at=$(awk '/^阶段开始：/ { ph = $0 } END { print ph }' "$out/log_$1")
        first_red="（崩溃，信号 $((rc - 128))）"
        if printf '%s' "$phase_at" | grep -qE "$3"; then ok=1; fi
    fi
    if [ "$ok" -ne 1 ]; then
        cat "$out/log_$1" >&2
        echo "【红】负控 $1 没有红在预期处：rc=${rc}，第一条红 [${first_red}]，当时阶段 [${phase_at}]，预期红 /${2}/、阶段 /${3}/" >&2; exit 1
    fi
    echo "负控 ${1}：红在预期处（rc=${rc}，${first_red}，${phase_at}）"
}
mutate M1 'h->op = op; h->size = (uint32_t)need; h->cb = cb;' 'h->op = op; h->size = (uint32_t)need; h->cb = cb; atomic_store(&g_dq_pub, g_dq_w + need);   /* M1：没写完就发布 */'
neg M1 '【红】(C1 .*(条数不符|序列哈希不符|没登记)|C[1-4] 超时|超时)' 'C1' 1
mutate M2 '__atomic_fetch_add(&g_dq_drains, 1, __ATOMIC_RELAXED); dq_wake();' '__atomic_fetch_add(&g_dq_drains, 1, __ATOMIC_RELAXED); return;   /* M2：清空不等 */'
neg M2 '【红】(C1 .*条数不符|C2：)' 'C[12]'
mutate M3 'while (g_dq_w + need - atomic_load_explicit(&g_dq_rd, memory_order_acquire) > dq_RING) { dq_wake(); sched_yield(); }' '/* M3：不等环里有地方 */'
neg M3 '【红】(C[13] .*(条数不符|序列哈希不符|没登记)|C[13]：|超时)' 'C[13]' 1
mutate M4 'h->op = OP_WRAP; h->size = (uint32_t)(dq_RING - off);' 'h->op = OP_WRAP; h->size = (uint32_t)(dq_RING - off - 16);   /* M4：跳过的长度写错 */'
neg M4 '【红】(C1 .*(条数不符|序列哈希不符|没登记)|超时)' 'C1' 1
mutate M5 'dq_run(h); r += h->size; atomic_store(&g_dq_rd, r); }' 'const uint32_t sz_ = h->size; r += sz_; atomic_store(&g_dq_rd, r); dq_run(h); }   /* M5：先报已读 */'
neg M5 '【红】(C2：|C[13] .*条数不符)' 'C[123]'
mutate M6 'atomic_fetch_sub(&g_dq_draining, 1);' 'atomic_store(&g_dq_draining, 0);   /* M6：先走的抹掉别人的「在等」标记 */'
neg M6 '【红】C5：后到的清空等了' 'C5'
echo "两级回放队列宿主用例：正控全绿，六种变异都红在预期处"
