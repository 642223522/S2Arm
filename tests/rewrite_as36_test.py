#!/usr/bin/env python3
"""36 位老 SDK 写死的可随机区 / 栈区（#1503，改写器 sdk_as36_ranges）：合成 SDK 代码形状，期望值按指令编码手算，不跑被测实现推。

老 SDK 的 nnosInitialize 用常数构造两个 nn::os::detail::AddressSpaceAllocator(起点, 终点, 保护区)：
  add x0, x19, #0x18; mov w1, #0x8000000; mov x2, #0x1000000000; mov w3, #0x4000; bl Ctor   → 可随机区
  add x0, x19, #0x40; mov w1, #0x8000000; mov w2, #0x80000000;   mov w3, #0x4000; bl Ctor   → 栈区
（两个 36 位款 SDK 真样本就是这四个 ORR 立即数字：0x320503e1 / 0xb25c03e2 / 0x320103e2 / 0x321203e3。）
期望：装起点 / 终点的四条各换成 brk #(0x8000 + 序号)，fixups 表头 TRAP_SITES 4 与四行 # TRAP <偏移> <种类> <寄存器> <原字>，mov w3 不动；
两段缺一段、两次调的不是同一个函数、bl 前被别的指令改了 x1 —— 一处都不改、没有 TRAP 表头。苹果 / 安卓两个目标同样。
"""
import importlib.util
import os
from pathlib import Path
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'tests/rewrite_corpus'))
spec = importlib.util.spec_from_file_location('corpus', ROOT / 'tests/rewrite_corpus/run.py')
corpus = importlib.util.module_from_spec(spec)
spec.loader.exec_module(corpus)

W1, X2_36, W2_31, W3 = 0x320503e1, 0xb25c03e2, 0x320103e2, 0x321203e3   # 真样本的 ORR 立即数形式
BASE = 0x100   # corpus.nso 把代码放在代码段 +0x100


def source(variant):
    w1, x2, w2, w3 = (f'.inst {W1:#x}', f'.inst {X2_36:#x}', f'.inst {W2_31:#x}', f'.inst {W3:#x}')
    if variant == 'movz':   # 同值的 MOVZ 形式
        w1, x2, w2, w3 = 'movz w1, #0x800, lsl #16', 'movz x2, #0x10, lsl #32', 'movz w2, #0x8000, lsl #16', 'movz w3, #0x4000'
    if variant == 'aslr_only': w2 = 'movz w2, #0x4000, lsl #16'   # 终点 0x40000000：不是栈区
    g1 = ['add x0, x19, #0x18', w1, x2, w3]
    if variant == 'order': g1 = [w3, 'add x0, x19, #0x18', x2, w1]
    if variant == 'clobber': g1 = g1 + ['mov x1, x5']
    second = 'other' if variant == 'two_targets' else 'ctor'
    asm = '\n'.join(g1 + ['bl ctor', 'add x0, x19, #0x40', w1, w2, w3, f'bl {second}', 'add x0, x19, #0x68', 'bl other', 'ret',
                          'ctor: ret', 'other: ret']) + '\n'
    return corpus.assemble('as36-' + variant, asm)


def expect(variant, words):
    """(相对代码起点的偏移, 种类, 寄存器) 按出现顺序；空 = 不该改"""
    if variant in ('aslr_only', 'two_targets', 'clobber'):
        return []
    def at(want):   # 写该寄存器的那条常数在语料里的位置（按编码低 5 位 = Rd 与上面手写的字找，不靠被测代码）
        return [i * 4 for i, w in enumerate(words) if w == want]
    if variant == 'movz':
        lo, hi36, hi31 = 0x52a10001, 0xd2c00202, 0x52b00002   # movz w1,#0x800,lsl16 / movz x2,#0x10,lsl32 / movz w2,#0x8000,lsl16
    else:
        lo, hi36, hi31 = W1, X2_36, W2_31
    los = at(lo)
    assert len(los) == 2 and len(at(hi36)) == 1 and len(at(hi31)) == 1, (variant, [hex(w) for w in words])
    return [(los[0], 'as_aslr_lo', 1), (at(hi36)[0], 'as_aslr_hi', 2), (los[1], 'as_stack_lo', 1), (at(hi31)[0], 'as_stack_hi', 2)]


def main():
    native = Path(os.environ['REW']).resolve()
    n = 0
    tmp = Path(corpus.T)
    try:
        for variant in ('valid', 'movz', 'order', 'aslr_only', 'two_targets', 'clobber'):
            words = source(variant)
            want = expect(variant, words)
            src = tmp / f'{variant}.nso'
            corpus.nso(words, {}, len(words) * 4, str(src))
            for target in ('apple', 'android'):
                out = tmp / f'out-{variant}-{target}'
                r = subprocess.run([str(native), str(src), str(out), 'sdk'], env=dict(os.environ, S2A_TARGET=target),
                                   capture_output=True, text=True, timeout=60)
                assert r.returncode == 0, (variant, target, r.stdout, r.stderr)
                patched = (out / 'sdk.patched.bin').read_bytes()
                fix = (out / 'sdk.fixups.tsv').read_text().splitlines()
                rows = [l.split('\t') for l in fix if l.startswith('# TRAP\t')]
                heads = [l for l in fix if l.startswith('# TRAP_SITES')]
                got = [(int(f[1], 16) - BASE, f[2], int(f[3])) for f in rows]
                assert got == want, (variant, target, got, want)
                assert heads == ([f'# TRAP_SITES\t{len(want)}'] if want else []), (variant, target, heads)
                for i, (off, _, _) in enumerate(want):
                    assert int(rows[i][4], 16) == words[off // 4], (variant, target, rows[i])
                    assert struct.unpack_from('<I', patched, BASE + off)[0] == 0xd4200000 | (0x8000 + i) << 5, (variant, target, off)
                for i, w in enumerate(words):   # 其余常数字（含 mov w3）一律原样
                    if w in (W1, X2_36, W2_31, W3, 0x52a10001, 0xd2c00202, 0x52b00002, 0x52880003) and i * 4 not in [o for o, _, _ in want]:
                        assert struct.unpack_from('<I', patched, BASE + i * 4)[0] == w, (variant, target, hex(i * 4))
                yellow = '36 位老 SDK 地址区间' in r.stdout
                assert yellow == (not want), (variant, target, r.stdout[-400:])
                n += 1
            print('✓', variant, '改' if want else '不改', len(want), '处', flush=True)
        print(f'✓ rewrite_as36_test：{n} 组（6 种形状 × 苹果 / 安卓）全部符合')
    finally:
        import shutil
        shutil.rmtree(corpus.T)


if __name__ == '__main__':
    main()
