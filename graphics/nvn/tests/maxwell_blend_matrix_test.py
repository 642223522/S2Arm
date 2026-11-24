#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Maxwell 浮点混合矩阵（#674 / #2183 通用根修）：全部系数 × 方程 × {有限, 0, NaN, ±Inf}，期望值由参考模型 maxwell_blend_ref.py 算，不读被测实现。

被测实现（provider）按 cell(state, s, s1, d, c) → RGBA 接进来：
  fixed  —— Metal / D3D 的固定混合（IEEE：0 × NaN = NaN），即修前直连层的做法。它必须红：矩阵查得出 #674 这类差异（负对照），
            并且 #674 原状态那一格必须在不等之列。
  （可编程混合实现落地后在这里加它的 provider，要求全等。）
用法：maxwell_blend_matrix_test.py [--full]   缺省只跑门禁用的子集（每种系数 / 方程组合都在，取值组合缩小），--full 跑满。
"""
import itertools
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import maxwell_blend_ref as M   # noqa: E402

NAN, INF = math.nan, math.inf


def cases(full):
    """(state, s, s1, d, c)：RGB 的 (方程, 源系数, 目标系数) 走遍 5 × 19 × 19 种（A 取三种代表），再单扫 A 的 5 × 19 × 19 种（RGB 固定 ONE / ZERO）；
    full 时取值组合放满"""
    vals = (0.0, 0.5, 1.0, -2.0, NAN, INF, -INF) if full else (0.0, 0.5, NAN, INF)
    alpha_states = [(M.ADD, M.ONE, M.ZERO), (M.ADD, M.ZERO, M.ONE_MINUS_SRC_ALPHA), (M.ADD, M.SRC_ALPHA, M.DST_ALPHA)]
    states = [rgb + a for rgb in itertools.product(M.EQS, M.FUNCS, M.FUNCS) for a in alpha_states] + \
             [(M.ADD, M.ONE, M.ZERO) + a for a in itertools.product(M.EQS, M.FUNCS, M.FUNCS)]
    for state in states:
            for sr, sa, dr, da in itertools.product(vals, repeat=4):
                for k in ((0.0, 1.0) if not full else (0.0, 0.25, 1.0)):
                    yield state, (sr, sr, -sr, sa), (k, k, k, k), (dr, -dr, dr, da), (k, 1.0 - k, k, k)


def fixed(state, s, s1, d, c):
    return M.blend(state, s, s1, d, c, ztaiz=False)


PROVIDERS = {"fixed": fixed}
MUST_DIFFER = {"fixed"}   # 负对照：这些实现必须和模型不等


def run(name, impl, full):
    total = bad = 0; first = None
    for state, s, s1, d, c in cases(full):
        total += 1
        want, got = M.blend(state, s, s1, d, c), impl(state, s, s1, d, c)
        if not all(M.same(g, w) for g, w in zip(got, want)):
            bad += 1; first = first or (state, s, d, want, got)
    # #674 原状态那一格（SRC_ALPHA / ONE_MINUS_SRC_ALPHA，A 为 ZERO / ONE_MINUS_SRC_ALPHA；源 (NaN,NaN,NaN,0) 混进 (0,0,0,1)）
    st674 = (M.ADD, M.SRC_ALPHA, M.ONE_MINUS_SRC_ALPHA, M.ADD, M.ZERO, M.ONE_MINUS_SRC_ALPHA)
    cell674 = all(M.same(g, w) for g, w in zip(impl(st674, (NAN, NAN, NAN, 0.0), (0.0,) * 4, (0.0, 0.0, 0.0, 1.0), (0.0,) * 4),
                                                   M.blend(st674, (NAN, NAN, NAN, 0.0), (0.0,) * 4, (0.0, 0.0, 0.0, 1.0), (0.0,) * 4)))
    return total, bad, first, cell674


def main():
    full = "--full" in sys.argv
    fails = 0
    for name, impl in PROVIDERS.items():
        total, bad, first, cell674 = run(name, impl, full)
        if name in MUST_DIFFER:
            ok = bad > 0 and not cell674
            print(f"{'通' if ok else '不通'} 负对照 {name}：{total} 格里和模型不等 {bad} 格（要 > 0），#674 那一格{'不等' if not cell674 else '相等'}（要不等）")
        else:
            ok = bad == 0 and cell674
            print(f"{'通' if ok else '不通'} {name}：{total} 格，和模型不等 {bad} 格（要 0）" + ("" if ok else f"；第一格 {first}"))
        fails += not ok
    print(f"{'✓' if not fails else '✗'} maxwell_blend_matrix：{len(PROVIDERS)} 个实现，不通 {fails}（{'满矩阵' if full else '门禁子集'}）")
    return 1 if fails else 0


if __name__ == "__main__":
    raise SystemExit(main())
