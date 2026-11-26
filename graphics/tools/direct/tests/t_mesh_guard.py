#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""#770 宿主自跑网格的循环护栏（S2A.Dsh MeshStage.GuardLoops，经 dsh_cmp --fn mesh_guard_loops；#1542）：python3 t_mesh_guard.py <dsh_cmp.dll>
期望按规则手算，不跑被测实现推：护栏 = 每个线程所有循环合计最多 4096 圈（MeshStage.EMU_LOOP_GUARD），任一循环用光即退出、外层下一圈也退出。
  ① 两层嵌套循环、圈数从缓冲读（喂垃圾计数 100000 × 100000），带 S2A_MESH_EMU 编、GPU 上 1 个线程跑：总圈数 ≤ 4096 + 1（内层第 4097 次判断时退出，外层接着一次判断退出）
     旧护栏每个循环各 4096 圈、嵌套相乘 → 4096 × 4096 = 16777216（负对照：传改动前的 dsh_cmp.dll 必红）
  ② 同一份不带 S2A_MESH_EMU（出包的库）：宏为空，3 × 4 → 12 圈，行为不变
  ③ 带宏、正常小计数 3 × 4 → 12 圈（预算内不改结果）
  ④ 改写文本：函数体开头一处 DM_LG_DECL()、每个循环体开头一处 DM_LG()；没有循环的源码原样返回"""
import os, subprocess, sys, tempfile
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__))); import dshfn
if len(sys.argv) > 1: os.environ['DSH_CMP_DLL'] = os.path.abspath(sys.argv[1])
H = os.path.dirname(os.path.abspath(__file__))
n = bad = 0
def ck(name, ok):
    global n, bad
    n += 1; bad += 0 if ok else 1; print(('✓ ' if ok else '✗ ') + name)
SRC = """#include <metal_stdlib>
using namespace metal;

kernel void main0(device uint* b [[buffer(0)]])
{
    uint total = 0u;
    for (uint i = 0u; i < b[0]; i++)
    {
        for (uint j = 0u; j < b[1]; j++)
        {
            total++;
        }
    }
    b[2] = total;
}
"""
out = dshfn.fn('mesh_guard_loops', SRC)
ck(f'④ 改写：一处 DM_LG_DECL()、两处 DM_LG()（{out.count("DM_LG_DECL()") - 2 if out else None} / {out.count("    DM_LG()") if out else None}）',
   bool(out) and out.count('    DM_LG_DECL()\n') == 1 and out.count('    DM_LG()\n') == 2 and 'DM_LG(0)' not in out)
plain = "#include <metal_stdlib>\nusing namespace metal;\n\nkernel void main0(device uint* b [[buffer(0)]])\n{\n    b[2] = 1u;\n}\n"
ck('④ 没有循环的源码原样返回', dshfn.fn('mesh_guard_loops', plain) == plain)
with tempfile.TemporaryDirectory() as t:
    exe = os.path.join(t, 'run'); src = os.path.join(t, 'k.metal'); open(src, 'w').write(out or SRC)
    c = subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-O1', '-o', exe, os.path.join(H, 't_mesh_guard_run.m'), '-framework', 'Foundation', '-framework', 'Metal'], capture_output=True, text=True)
    if c.returncode: print(c.stderr[-500:]); sys.exit(1)
    def go(mac, a, b):
        r = subprocess.run([exe, src, str(mac), str(a), str(b)], capture_output=True, text=True, timeout=120)
        if r.returncode: return None, r.stderr.strip()
        x = r.stdout.split(); return int(x[0]), float(x[1])
    got, ms = go(1, 100000, 100000)
    ck(f'① 垃圾计数 100000 × 100000、带宏：总圈数 ≤ 4097（实得 {got}，GPU {ms} ms；旧护栏 16777216）', got is not None and got <= 4097)
    got, _ = go(0, 3, 4); ck(f'② 不带宏（出包的库）3 × 4 → 12（实得 {got}）', got == 12)
    got, _ = go(1, 3, 4); ck(f'③ 带宏、预算内 3 × 4 → 12（实得 {got}）', got == 12)
print(f't_mesh_guard：{n} 项，失败 {bad}')
sys.exit(1 if bad else 0)
