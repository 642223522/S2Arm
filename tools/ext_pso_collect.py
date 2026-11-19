#!/usr/bin/env python3
"""外部公开着色器 / 管线清单 → 我方管线种子目录（tools/patch_pack.py 第三参，进社区统一包 g/<程序号>，玩家出包时管线种子阶段当来源）。
用法：ext_pso_collect.py <镜像根> <种子目录> [--sources tools/ext_pso_sources.tsv]
  镜像根下每个来源一个本地检出（目录名 = 来源名字，调用方先 git pull）；来源与许可见 tools/ext_pso_sources.tsv，NOTICE「着色器清单数据」同步署名。
为什么：别的项目公开了按款录的预建清单（同一种键：sha256(控制段 + 代码)，graphics/tools/direct/pso_seed.py 同口径），我方没跑过的场景也能在首局加载时后台预建。
收什么：S（着色器键）/ C（计算着色器键）原样（mng 的完整哈希键取前 16 位，同一种键）；R（渲染管线，pso_skey 十六进制）只收长度等于我方当前 pso_skey 两倍的（graphics/tools/direct/pso_layout.py skey-size），
  别的长度是对方别的结构版本，转不了就不收、按长度计数；其余行类（如 V）不收、按类计数。别的游戏版本的键不在这里滤：出包时 pso_seed.py 按本包直连库的键滤。
输出：<种子目录>/<程序号>/ext_<名字>.tsv，首行「# source: repo= commit= license= author= path=」（patch_pack.seed_source 读，致谢与追溯），行序同上游、去重；
  内容没变不重写（社区包同输入同字节）；这个来源里已没有的款，删掉它的 ext_<名字>.tsv（只删本工具写的这一种文件名）。最后一行一句读数，按来源分。"""
import argparse, collections, os, re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
KEY = re.compile(r'[0-9a-f]{16}(_b)?$')
TID = re.compile(r'0[0-9A-F]{15}$')
FULL = re.compile(r'[0-9a-f]{64}-[0-9a-f]+_b$')   # mng 的 S / C 键：完整 sha256(控制段 + 代码) + 「-<翻译链号>_b」


def sources(path):
    src, maps = [], collections.defaultdict(dict)
    for line in open(path, encoding='utf-8'):
        f = line.rstrip('\n').split('\t')
        if f[0] == '来源' and len(f) == 5: src.append(dict(name=f[1], repo=f[2], license=f[3], fmt=f[4]))
        elif f[0] == '映射' and len(f) == 4: maps[f[1]][f[2]] = f[3].upper()
    return src, maps


def files(mirror, s, maps):
    """→ [(程序号, 上游相对路径, 文件)]"""
    out = []
    if s['fmt'] == 'nxnative':
        for p in sorted((mirror / 'dm/games').glob('*/pso_manifest.tsv')):
            if TID.match(p.parent.name.upper()): out.append((p.parent.name.upper(), str(p.relative_to(mirror)), p))
    elif s['fmt'] == 'mng':
        for d, tid in sorted(maps[s['name']].items()):
            p = mirror / 'games' / d / 'assets/shader_list.tsv'
            if p.is_file(): out.append((tid, str(p.relative_to(mirror)), p))
    else:
        raise SystemExit(f'【红】来源 {s["name"]} 格式 {s["fmt"]} 认不得')
    return out


def rows(p, rlen, why):
    seen, keep = set(), []
    for line in open(p, encoding='utf-8', errors='replace'):
        if not line.strip() or line.startswith('#'): continue
        f = line.rstrip('\n').split('\t'); k = f[0]
        if k in ('S', 'C') and len(f) >= 2 and FULL.match(f[1]): f[1] = f[1][:16] + '_b'   # mng：完整 sha256 + 翻译链号 → 我方键 = 同一 sha256 前 16 位（旷野之息实测 16/26 落在同版本键表里）
        ok = (k in ('S', 'C') and len(f) >= 2 and KEY.match(f[1])) or (k == 'R' and len(f) >= 2 and len(f[1]) == rlen and re.fullmatch(r'[0-9a-f]+', f[1]))
        if not ok:
            why['R 行（结构长度与我方 pso_skey 不同）' if k == 'R' else f'{k} 行'] += 1; continue
        r = '\t'.join(f[:3] if k == 'S' else f[:2])
        if r not in seen: seen.add(r); keep.append(r)
    return keep


def main():
    ap = argparse.ArgumentParser(); ap.add_argument('mirror_root', type=Path); ap.add_argument('seeds', type=Path)
    ap.add_argument('--sources', type=Path, default=ROOT / 'tools/ext_pso_sources.tsv')
    a = ap.parse_args()
    sk = subprocess.run([sys.executable, str(ROOT / 'graphics/tools/direct/pso_layout.py'), 'skey-size'], capture_output=True, text=True)
    if sk.returncode or not sk.stdout.strip().isdigit(): raise SystemExit(f'【红】量不出管线键字节数（pso_layout.py skey-size）：{sk.stderr.strip()[-200:]}')
    rlen = 2 * int(sk.stdout.strip())
    src, maps = sources(a.sources); notes = []
    for s in src:
        mirror = a.mirror_root / s['name']
        head = subprocess.run(['git', '-C', str(mirror), 'rev-parse', 'HEAD'], capture_output=True, text=True)
        if head.returncode: notes.append(f'{s["name"]}：没有本地检出（{mirror}），跳过'); continue
        commit = head.stdout.strip()[:12]; why = collections.Counter(); n = changed = 0; got = set()
        for tid, rel, p in files(mirror, s, maps):
            keep = rows(p, rlen, why)
            if not keep: continue
            got.add(tid); n += len(keep)
            text = f'# source: repo={s["repo"]} commit={commit} license={s["license"]} author={s["name"]} path={rel}\n' \
                   f'# 外部公开清单（只有标识与管线描述）：tools/ext_pso_collect.py 生成，勿手改；出包时按本包直连库的键滤\n' + '\n'.join(keep) + '\n'
            out = a.seeds / tid / f'ext_{s["name"]}.tsv'
            if out.is_file() and out.read_text(encoding='utf-8') == text: continue
            out.parent.mkdir(parents=True, exist_ok=True); tmp = out.with_name(out.name + f'.{os.getpid()}.tmp')
            tmp.write_text(text, encoding='utf-8'); os.replace(tmp, out); changed += 1
        gone = [d for d in (a.seeds.iterdir() if a.seeds.is_dir() else []) if (d / f'ext_{s["name"]}.tsv').is_file() and d.name.upper() not in got]
        for d in gone: (d / f'ext_{s["name"]}.tsv').unlink()
        notes.append(f'{s["name"]}@{commit}：{len(got)} 款 {n} 行（改写 {changed} 份、撤 {len(gone)} 份）' + (f'；不收 {dict(why)}' if why else ''))
    print('外部管线清单：' + '；'.join(notes))


if __name__ == '__main__':
    main()
