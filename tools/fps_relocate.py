#!/usr/bin/env python3
"""帧率表跨版本带用（情报 10-28：帧率表按构建号硬绑，换个版本 60 帧就静默失效）。

用法：python3 tools/fps_relocate.py <有表那版的 exefs/main> <新版的 exefs/main> <runtime/fps/<旧构建号>.tsv> [--write]
  判两版主程序的数据段 / bss 布局是否同构：数据段起点、大小与 bss 大小一样，且数据段里每一处不同都是「指针值差同一个常数」
  （代码段 / 只读段整体平移，指向它们的指针跟着变；10-29 巫师3 4.04c → 4.04a：70 万个 8 字节块里 610 处不同、全部差 −0x1F0）。
  同构 → 表里只碰数据段 / bss 的行（w、slot、speed、present30、present）原样成立，打出新构建号的表（--write 写 runtime/fps/<新构建号前 16 位>.tsv）；
  改指令的 c 行（11-11 起）：以那条指令为中心取前后 16 / 32 / 64 条做特征，屏蔽随地址变的字段（b / bl / b.cond / cbz / tbz / adr / adrp /
  字面量 ldr 的偏移，以及基址来自窗口内 adrp 的 add / ldr / str 的页内偏移），在新版代码段里找；只认唯一匹配，且那条指令本身按同样屏蔽与表里的旧字一致。
  任何一行定位不了（0 处或不止 1 处）→ 报红、退出 1，整张表不出（宁缺毋滥）。只改数据的行仍要求数据段 / bss 同构；只有 c 行的表不看同构。
  出的表只是候选：登记 60 帧仍要 tools/ab_pair.sh <款> fps60 关 / 开对照局、tools/fps_speed_judge.py 判 ρ≈1。
退出码：0 出表 / 1 不能带用 / 2 参数或读文件错。单测：tests/fps_relocate_test.py"""
import struct, sys
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'graphics/nvn/games'))


def load(path):
    """(镜像, 构建号 32 位十六进制, [(段内存偏移, 段大小)] × 3, bss 大小)"""
    import profile_guess
    img, bid, _, bss = profile_guess.nso(path)
    d = Path(path).read_bytes()
    return img, bid, [struct.unpack_from('<III', d, 0x10 + i * 0x10)[1:] for i in range(3)], bss


def isomorphic(old, new):
    """old / new = load() 的结果。返回 (同构与否, 理由)"""
    oi, _, os_, ob = old; ni, _, ns, nb = new
    (od, odz), (nd, ndz) = os_[2], ns[2]
    if (od, odz, ob) != (nd, ndz, nb):
        return False, f'数据段 / bss 布局不同：旧 数据 {od:#x}+{odz:#x} bss {ob:#x}，新 数据 {nd:#x}+{ndz:#x} bss {nb:#x}'
    deltas = Counter()
    for i in range(od, od + odz - 7, 8):
        a, b = oi[i:i + 8], ni[i:i + 8]
        if a != b: deltas[struct.unpack('<q', b)[0] - struct.unpack('<q', a)[0]] += 1
    if len(deltas) > 1:
        return False, f'数据段有 {sum(deltas.values())} 处不同、差值不止一种（{", ".join(f"{k:#x}×{v}" for k, v in deltas.most_common(3))}）：数据本身改了'
    n = sum(deltas.values())
    return True, f'数据段与 bss 同起点同大小，{(odz) // 8} 个 8 字节块里 {n} 处不同' + (f'、全部差 {next(iter(deltas)):#x}（指向代码 / 只读段的指针跟着平移）' if n else '')


def relocate(table_text, new_bid, code=None):
    """表文本 → (新表文本, 不能带用的行)。build 行换成新构建号；c 行（改指令）按 code=(旧代码段, 新代码段) 重新定位，不给 code 就不能带用"""
    out, bad = [], []
    for line in table_text.splitlines():
        f = line.split('#')[0].split()
        if f[:1] == ['build']:
            out.append(f'build {new_bid[:16]}'); continue
        if f[:1] == ['c']:
            if code is None or len(f) < 5 or f[1] != 'main':
                bad.append(line.strip()); out.append(line); continue
            na, why = locate(code[0], code[1], int(f[2], 16), int(f[4], 16))
            if na is None:
                bad.append(f'{line.strip()}（{why}）'); out.append(line); continue
            out.append(line.replace(f[2], f'{na:#x}', 1)); continue
        out.append(line)
    return '\n'.join(out) + '\n', bad


# ---------- 改指令的行：按指令上下文在新版代码段里重新定位 ----------
def _mask(w):
    """一条指令里随地址变的字段屏蔽掉之后的掩码（1 = 比较）；返回 (掩码, 是否 adrp 及其目的寄存器)"""
    if (w & 0x7C000000) == 0x14000000: return 0xFC000000, None          # b / bl
    if (w & 0xFF000010) == 0x54000000: return 0xFF00001F, None          # b.cond
    if (w & 0x7E000000) == 0x34000000: return 0xFF00001F, None          # cbz / cbnz
    if (w & 0x7E000000) == 0x36000000: return 0xFFF8001F, None          # tbz / tbnz
    if (w & 0x1F000000) == 0x10000000: return 0x9F00001F, (w & 0x1F) if w & 0x80000000 else None   # adr / adrp
    if (w & 0x3B000000) == 0x18000000: return 0xFF00001F, None          # ldr（字面量）
    return 0xFFFFFFFF, None


def _pattern(code, at, n):
    """以 at（字节偏移）为中心前后各 n 条指令的 (掩码值, 掩码) 列表；基址来自窗口内 adrp 的 add / ldr / str 屏蔽页内偏移"""
    lo = max(0, at - 4 * n); hi = min(len(code) - 4, at + 4 * n)
    pat, page_regs = [], set()
    for a in range(lo, hi + 1, 4):
        w = struct.unpack_from('<I', code, a)[0]; m, adrp = _mask(w)
        rn = (w >> 5) & 0x1F
        if m == 0xFFFFFFFF and rn in page_regs and ((w & 0x7F800000) == 0x11000000 or (w & 0x3B000000) == 0x39000000):
            m = 0xFFC003FF   # add 立即数 / ldr·str 无符号偏移：屏蔽 imm12（页内偏移）
        if adrp is not None: page_regs.add(adrp)
        pat.append((w & m, m))
    return lo, pat


def locate(old_code, new_code, at, old_word):
    """旧代码段 at 处（表里旧字 old_word）在新代码段的位置：(新偏移, 说明)；定位不了 → (None, 原因)"""
    if at + 4 > len(old_code) or struct.unpack_from('<I', old_code, at)[0] != old_word:
        return None, f'旧主程序 {at:#x} 处不是表里的旧字 {old_word:08x}'
    for n in (16, 32, 64):
        lo, pat = _pattern(old_code, at, n)
        # 锚点：窗口里不含地址字段、在旧代码段出现次数最少的一条（用字节搜索快速找候选）
        full = [(i, v) for i, (v, m) in enumerate(pat) if m == 0xFFFFFFFF]
        if not full: continue
        def freq(v):
            b = struct.pack('<I', v); c, p = 0, old_code.find(b)
            while p >= 0 and c < 50: c += p % 4 == 0; p = old_code.find(b, p + 1)
            return c
        ai, av = min(full, key=lambda iv: freq(iv[1])); ab = struct.pack('<I', av)
        hits = []; p = new_code.find(ab)
        while p >= 0:
            if p % 4 == 0:
                base = p - 4 * ai
                if base >= 0 and base + 4 * len(pat) <= len(new_code) and all(
                        (struct.unpack_from('<I', new_code, base + 4 * k)[0] & m) == v for k, (v, m) in enumerate(pat)):
                    hits.append(base + (at - lo))
                    if len(hits) > 1: break
            p = new_code.find(ab, p + 1)
        if len(hits) == 1: return hits[0], f'窗口前后各 {n} 条唯一匹配'
        if len(hits) > 1: continue   # 不唯一：放大窗口再试
        return None, f'新版代码段里找不到前后各 {n} 条的匹配'
    return None, '放大到前后各 64 条仍不唯一'


def main(a):
    if len(a) not in (3, 4) or (len(a) == 4 and a[3] != '--write'):
        print(__doc__.strip().splitlines()[2]); return 2
    try:
        old, new, text = load(a[0]), load(a[1]), Path(a[2]).read_text(encoding='utf-8')
    except (OSError, ValueError, struct.error) as e:
        print(f'🔴 读不了：{e}'); return 2
    ob = next((l.split()[1] for l in text.splitlines() if l.split()[:1] == ['build']), '')
    if not old[1].startswith(ob):
        print(f'🔴 表是构建号 {ob} 的，给的旧主程序是 {old[1]}'); return 2
    has_data = any(l.split('#')[0].split()[:1] in (['w'], ['slot'], ['speed'], ['present30']) for l in text.splitlines())
    ok, why = isomorphic(old, new)
    if has_data and not ok:
        print(f'🔴 {old[1][:16]} → {new[1][:16]} 不能带用：{why}'); return 1
    if not has_data: why = '只有改指令的行（不看数据段同构）'
    body, bad = relocate(text, new[1], (old[0][:old[2][0][1]], new[0][:new[2][0][1]]))
    if bad:
        print(f'🔴 {old[1][:16]} → {new[1][:16]}：{len(bad)} 行改指令定位不了（整张表不出）：'); [print('   ', b[:200]) for b in bad]; return 1
    nc = sum(1 for l in text.splitlines() if l.split('#')[0].split()[:1] == ['c'])
    if nc: why += f'；{nc} 行改指令按上下文唯一定位'
    head = (f'# 由 tools/fps_relocate.py 从 {Path(a[2]).name}（主程序 {old[1]}）带到主程序 {new[1]}：{why}\n'
            f'# 候选：登记前跑 tools/ab_pair.sh <款> fps60 关 / 开对照局，tools/fps_speed_judge.py 判 ρ≈1\n')
    if len(a) == 4:
        dst = HERE.parent / 'runtime/fps' / f'{new[1][:16]}.tsv'
        if dst.exists():
            print(f'🔴 {dst} 已经有了，不覆盖'); return 1
        dst.write_text(head + body, encoding='utf-8')
        print(f'🟢 写入 {dst.relative_to(HERE.parent)}：{why}')
    else:
        print(head + body, end='')
        print(f'🟢 可以带用：{why}', file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
