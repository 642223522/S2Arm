#!/usr/bin/env python3
"""列目录按扩展名收文件的几处，遇到 AppleDouble「._<名>」附属文件不收（#1529 同类，全仓审查）。
游戏库 / 数据根 / 引擎副本可以在玩家的外置 exFAT 盘上：macOS 给每个带扩展属性的文件另写一份「._<名>」（4 KB，头 00 05 16 07），
os.listdir / pathlib 的 glob / rglob 照样列出来，交给链接器报 unknown file type、当字体数成 14 份、打进程序包。
不用真 exFAT 盘：临时目录里照样摆「._<名>」文件。期望集合手写。
  ① dsx_win.build 的链接只收本次编出的目标文件（假编译器：每编一个 .o 旁边再写一份 ._<名>.o，链接参数里不许有它）
  ② stages.bfttf：7 份字体 + 7 份 ._ → 7 份
  ③ programs.recipe_files：程序包配方文件不含 ._
  ④ pso_seed.files：种子目录里的 ._x.tsv 不收
用法：appledouble_scan_test.py [仓库根]（缺省本文件所在仓库；负对照：传一份改前的检出）"""
import os
import subprocess
import sys
import tempfile
from pathlib import Path

R = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]).resolve()
AD = b'\x00\x05\x16\x07' + b'\x00' * 60
fails = 0


def ck(what, ok):
    global fails
    print(('ok   ' if ok else '红   ') + what)
    fails += not ok


def junk(p):
    p = Path(p)
    (p.parent / ('._' + p.name)).write_bytes(AD)


with tempfile.TemporaryDirectory(prefix='adscan_') as T:
    T = Path(T)
    # ① 假编译器：-c 源 -o 目标 → 写目标 + ._目标；链接（-shared -o 库 …）→ 记参数、写库
    log = T / 'link_args.txt'
    cc = T / 'fakecc.py'
    cc.write_text('import sys, os\n'
                  'a = sys.argv[1:]\n'
                  'o = a[a.index("-o") + 1]\n'
                  'if "-c" in a:\n'
                  '    open(o, "wb").write(b"obj")\n'
                  '    d, n = os.path.split(o); open(os.path.join(d, "._" + n), "wb").write(b"\\x00\\x05\\x16\\x07")\n'
                  'else:\n'
                  f'    open({str(log)!r}, "w").write("\\n".join(a)); open(o, "wb").write(b"dll")\n')
    wrap = T / 'fakecc'
    wrap.write_text(f'#!/bin/sh\nexec "{sys.executable}" "{cc}" "$@"\n'); wrap.chmod(0o755)
    env = dict(os.environ, S2A_CC=str(wrap), S2A_CXX=str(wrap))
    out = T / 'dsx' / 'dsx.dll'
    r = subprocess.run([sys.executable, str(R / 'graphics/dsx/dsx_win.py'), str(out)], env=env, capture_output=True, text=True)
    args = log.read_text().split('\n') if log.is_file() else []
    objs = [a for a in args if a.endswith('.o')]
    ck(f'① dsx_win 链接成功（rc={r.returncode}）、收了 {len(objs)} 个目标文件', r.returncode == 0 and len(objs) > 0)
    bad = [os.path.basename(a) for a in objs if os.path.basename(a).startswith('._')]
    ck(f'① 链接参数里没有 AppleDouble「._<名>.o」：{bad[:3]}', not bad)

    sys.path[:0] = [str(R), str(R / 'pack/jobs'), str(R / 'graphics/tools/direct')]
    # ② 字体
    fonts = T / 'fonts'; fonts.mkdir()
    for i in range(7):
        f = fonts / f'font{i}.bfttf'; f.write_bytes(b'f'); junk(f)
    try:
        from pack.orch import stages
        got = sorted(p.name for p in stages.bfttf(fonts))
        ck(f'② stages.bfttf：{len(got)} 份（期望 7 份、不含 ._）', got == [f'font{i}.bfttf' for i in range(7)])
    except AttributeError:
        ck('② stages.bfttf 不存在（改前没有这个函数：字体按 glob("*.bfttf") 数，7 份数成 14 份）', False)
    # ③ 程序包配方
    import programs
    kit = T / 'kit'; (kit / 'sub').mkdir(parents=True)
    for rel in ('main', 'main.npdm', 'sub/a.bin'):
        f = kit / rel; f.write_bytes(b'x'); junk(f)
    got = sorted(p.relative_to(kit).as_posix() for p in programs.recipe_files(kit, ['main']))
    ck(f'③ programs.recipe_files：{got}', not any(Path(g).name.startswith('._') for g in got) and 'sub/a.bin' in got)
    # ④ 管线种子
    import pso_seed
    seeds = T / 'seeds'; seeds.mkdir()
    for n in ('a.tsv', 'b.tsv'):
        f = seeds / n; f.write_text('x\n'); junk(f)
    got = sorted(os.path.basename(p) for p in pso_seed.files([str(seeds)]))
    ck(f'④ pso_seed.files：{got}', got == ['a.tsv', 'b.tsv'])

print(f'{"全过" if not fails else f"红 {fails} 项"}（仓库 {R}）')
sys.exit(1 if fails else 0)
