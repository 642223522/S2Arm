#!/usr/bin/env python3
# 外壳着色器出哪些域的曲面核（S2A.Dsh DshCompiler.Ctx.TessDomains，经 dsh_cmp --fn tess_domains 调）。诊断 18 款「hull shader … has no isolines-domain kernel
#   (variants: triangles)」：出包时本款扫到的域只有三角，游戏运行时才把这支外壳配上 isolines 域着色器，那组曲面绘制整笔跳过。
# 期望不跑被测实现得出（模式字低 2 位是域：0 isolines / 1 triangles / 2 quads，其余位是分区 / 绕序 / 点模式）：
#   ① 外壳、本款扫到 {1: 0x2a1}（三角）、自身模式 0x2a1 → [[1, 0x2a1, 扫到], [0, 0x2a0, 补], [2, 0x2a2, 补]]：扫到的在前（第一种进 <键>_b，同原先），补齐 isolines / quads，补的域 = 自身模式换掉低 2 位
#   ② 外壳、本款扫到 {0: 0x80, 2: 0x182}、自身模式 0x80 → [[0, 0x80, 扫到], [2, 0x182, 扫到], [1, 0x81, 补]]：扫到的域照扫到的模式字
#   ③ 外壳、本款一个都没扫到、自身模式 1 → [[1, 1, 扫到], [0, 0, 补], [2, 2, 补]]：第一种仍是自身模式的域（同原先只出那一种）
#   ④ 域着色器、模式 0x2e2 → [[2, 0x2e2, 扫到]]：域着色器只出自己那一个域
# 负对照：DSH_CMP_DLL 指向改动前的翻译器 → 没有 tess_domains 这个函数，全红。用法：python3 graphics/tools/direct/tests/t_dsh_tess_doms.py
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE); import dshfn

cases = [
    ('① 外壳扫到三角 → 补 isolines / quads', ('hs', 0x2a1, {'1': 0x2a1}), [[1, 0x2a1, True], [0, 0x2a0, False], [2, 0x2a2, False]]),
    ('② 外壳扫到 isolines / quads → 照扫到的、补三角', ('hs', 0x80, {'0': 0x80, '2': 0x182}), [[0, 0x80, True], [2, 0x182, True], [1, 0x81, False]]),
    ('③ 外壳一个都没扫到 → 自身域在前、补另两种', ('hs', 1, {}), [[1, 1, True], [0, 0, False], [2, 2, False]]),
    ('④ 域着色器只出自己的域', ('ds', 0x2e2, {}), [[2, 0x2e2, True]]),
]
res = dshfn.batch([('tess_domains', a) for _, a, _ in cases])
bad = 0
for (name, _, want), r in zip(cases, res):
    got = r.get('ok')
    ok = got == want
    bad += not ok
    print(f"{'✓' if ok else '✗'} {name}：期望 {want} → 真结果 {got if 'ok' in r else r.get('err')}")
print(f"{'✗' if bad else '✓'} t_dsh_tess_doms：{len(cases)} 例，{bad} 例不符")
sys.exit(1 if bad else 0)
