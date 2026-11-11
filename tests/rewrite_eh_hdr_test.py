#!/usr/bin/env python3
"""函数边界不靠 .eh_frame_hdr 的二分表也能取（11-11：模块没有 .eh_frame_hdr 时，改写器读 MOD0 起点后面的字节当 FDE 个数，
REQUIRE「n >= 0 && n <= g->len / 8」中止，出包停在八个轻阶段）：REW=<C 改写器> python3 tests/rewrite_eh_hdr_test.py
合成同一个模块（两个函数共 4 条指令碰 x18、各一条 FDE），只换 .eh_frame_hdr 的形态；期望按输入手写、不跑被测实现：
  ① 有二分表（常规）：退出 0、需改写 4 处、0 缺口
  ② 有 .eh_frame_hdr 但个数 / 表编码 = DW_EH_PE_omit（0xff，规范允许没有二分表）：从 eh_frame_ptr 顺着 .eh_frame 读到同两条 FDE → 产物与 ① 只差输入里那两个编码字节，统计 eh_frame_walk = 1
  ③ 没有 .eh_frame_hdr（MOD0 起点 = 终点，指着后面的 .eh_frame）：退出 0、需改写 4 处、0 缺口，统计 eh_frame_none = 1
负对照（11-11 手工跑过，写进坑记录）：③ 在改前的改写器上退出非 0、报 n >= 0 && (uint64_t)n <= g->len / 8——与玩家报错同一条"""
import os, re, struct, subprocess, sys, tempfile

REW = os.environ['REW']
bad = 0


def chk(name, want, got):
    global bad
    ok = want == got; bad += not ok; print(f'{"通" if ok else "不通"} {name}：期望 {want!r} → 真结果 {got!r}')


def nso(path, code, funcs, form):   # 同 tests/rewrite_below_sp_test.py 的模块，form = table / notable / none
    tsz = (0x100 + 4 * len(code) + 0xfff) & ~0xfff
    text = bytearray(tsz); struct.pack_into('<II', text, 0, 0x14000040, tsz); struct.pack_into('<%dI' % len(code), text, 0x100, *code)
    nf = len(funcs); EH = 0x100; TB = EH + 12; EF = (TB + 8 * nf + 15) & ~15
    rosz = (EF + 0x18 + 0x10 * nf + 0x10 + 0xfff) & ~0xfff
    ro = bytearray(rosz)
    hs, he = (EH, EH + 0x20) if form != 'none' else (EF, EF)   # MOD0 里 .eh_frame_hdr 的起点 / 终点（相对 MOD0）
    struct.pack_into('<4sIIIii', ro, 0, b'MOD0', 0, 0, 0, hs, he)
    struct.pack_into('<BBBBiI', ro, EH, 1, 0x1B, 0x03, 0x3B, (tsz + EF) - (tsz + EH + 4), nf)
    if form == 'notable':
        ro[EH + 2] = ro[EH + 3] = 0xff
    ro[EF:EF + 0x18] = struct.pack('<II', 0x14, 0) + bytes([1]) + b'zR\0' + bytes([4, 0x78, 30, 1, 0x1B]) + bytes(7)
    for k, (fa, fl) in enumerate(funcs):
        f = tsz + EF + 0x18 + 0x10 * k
        struct.pack_into('<IIii', ro, EF + 0x18 + 0x10 * k, 0x0c, (f + 4) - (tsz + EF), fa - (f + 8), fl)
        struct.pack_into('<ii', ro, TB + 8 * k, fa - (tsz + EH), f - (tsz + EH))
    segs = ((0, bytes(text)), (tsz, bytes(ro)), (tsz + rosz, bytes(0x1000)))
    h = bytearray(0x100); h[:4] = b'NSO0'
    for k, (mo, seg) in enumerate(segs):
        struct.pack_into('<III', h, 0x10 + 0x10 * k, 0x100 + sum(len(s[1]) for s in segs[:k]), mo, len(seg)); struct.pack_into('<I', h, 0x60 + 4 * k, len(seg))
    h[0x40:0x50] = bytes(range(16))
    open(path, 'wb').write(bytes(h) + b''.join(s[1] for s in segs))


F1 = [0xb9401c32,   # ldr w18, [x1, #0x1c]  ← x18
      0x2a1203e0,   # mov w0, w18
      0xd65f03c0]   # ret
F2 = [0xaa0003f2,   # mov x18, x0           ← x18
      0x91000640,   # add x0, x18, #1
      0xd65f03c0]   # ret
CODE = F1 + F2
FUNCS = [(0x100, 4 * len(F1)), (0x100 + 4 * len(F1), 4 * len(F2))]


def run(form):
    with tempfile.TemporaryDirectory() as t:
        src = os.path.join(t, 'main'); nso(src, CODE, FUNCS, form)
        r = subprocess.run([REW, src, os.path.join(t, 'o'), 'main'], capture_output=True, text=True, timeout=120, env=dict(os.environ, S2A_TARGET='ios'))
        m = re.search(r'PFRW mod=main need=(\d+) gaps=(\d+)', r.stdout)
        st = {k: int(v) for k, v in re.findall(r"'(eh_frame_walk|eh_frame_none)': (\d+)", r.stdout)}
        img = open(os.path.join(t, 'o', 'main.patched.bin'), 'rb').read() if r.returncode == 0 else b''
        return r.returncode, (int(m[1]), int(m[2])) if m else None, st, img, (r.stdout + r.stderr)[-300:]


rc1, s1, st1, img1, _ = run('table')
chk('① 有二分表：退出 0、需改写 4 处、0 缺口', (0, (4, 0)), (rc1, s1))
chk('① 常规模块统计里没有 eh_frame_walk / eh_frame_none', {}, st1)
rc2, s2, st2, img2, _ = run('notable')
chk('② 没有二分表：退出 0、需改写 4 处、0 缺口', (0, (4, 0)), (rc2, s2))
chk('② 统计 eh_frame_walk = 1', {'eh_frame_walk': 1}, st2)
# 产物带只读段：② 的输入本身只在 .eh_frame_hdr 两个编码字节上与 ① 不同（只读段 0x1000 + hdr 0x100 + 2 / 3），其余应逐字节相同
diff = [hex(i) for i in range(min(len(img1), len(img2))) if img1[i] != img2[i]] if img1 and img2 and len(img1) == len(img2) else None
chk('② 产物与 ① 只差输入里那两个表头字节（顺着 .eh_frame 读到同一批 FDE）', ['0x1102', '0x1103'], diff)
rc3, s3, st3, img3, tail3 = run('none')
chk('③ 没有 .eh_frame_hdr：退出 0、需改写 4 处、0 缺口', (0, (4, 0)), (rc3, s3))
chk('③ 统计 eh_frame_none = 1', {'eh_frame_none': 1}, st3)
if rc3:
    print(f'   ③ 输出末尾：{tail3}')

print(f'{"✓" if not bad else "✗"} rewrite_eh_hdr_test：{bad} 处不符')
sys.exit(1 if bad else 0)
