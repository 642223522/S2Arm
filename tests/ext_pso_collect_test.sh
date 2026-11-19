#!/bin/bash
# 外部公开管线清单收集（tools/ext_pso_collect.py）+ 社区包署名（tools/patch_pack.py seed_source）单测：假镜像两种格式，期望全部手写
set -u
R=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d "${TMPDIR:-/tmp}/extpso.XXXXXX"); trap 'rm -rf "$T"' EXIT
python3 - "$R" "$T" <<'PY'
import gzip, json, os, re, subprocess, sys
from pathlib import Path
R, T = Path(sys.argv[1]), Path(sys.argv[2]); fails = 0
def ck(ok, what):
    global fails; print(('通 ' if ok else '不通 ') + what); fails += 0 if ok else 1
sk = int(subprocess.run([sys.executable, str(R / 'graphics/tools/direct/pso_layout.py'), 'skey-size'], capture_output=True, text=True).stdout)
r_ok, r_bad = 'R\t' + 'ab' * sk, 'R\t' + 'ab' * (sk + 8)
def repo(name, files):
    d = T / 'm' / name; d.mkdir(parents=True)
    for rel, text in files.items(): (d / rel).parent.mkdir(parents=True, exist_ok=True); (d / rel).write_text(text)
    for c in (['init', '-q'], ['add', '-A'], ['-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-q', '-m', 'x']): subprocess.run(['git', '-C', str(d)] + c, check=True)
    return subprocess.run(['git', '-C', str(d), 'rev-parse', 'HEAD'], capture_output=True, text=True).stdout.strip()[:12]
full = 'e4b5b0967a3cd0b3' + 'f' * 48
c1 = repo('nx', {'dm/games/0100AAAA00000000/pso_manifest.tsv': f'# h\nS\t1111222233334444_b\t0\nS\t1111222233334444_b\t0\nC\t5555666677778888_b\n{r_ok}\n{r_bad}\nM\tx\t1\n',
                 'dm/games/notatitle/pso_manifest.tsv': 'S\t9999999999999999_b\t0\n'})
c2 = repo('mng', {'games/kirby/assets/shader_list.tsv': f'# h\nV\t{"a"*64}\t{{}}\nS\t{full}-b7530f698e76_b\t1\tt\nC\t{full}-b7530f698e76_b\tm\nR\t3536\n',
                  'games/other/assets/shader_list.tsv': f'S\t{full}-1_b\t0\tt\n'})
src = T / 'src.tsv'; src.write_text('来源\tnx\thttps://e.x/nx\tMIT\tnxnative\n来源\tmng\thttps://e.x/mng\tMIT\tmng\n映射\tmng\tkirby\t0100BBBB00000000\n')
seeds = T / 'seeds'; (seeds / '0100CCCC00000000').mkdir(parents=True); own = 'S\t0000000000000001_b\t0\n'; (seeds / '0100CCCC00000000/zc_crowd.tsv').write_text(own)
run = lambda: subprocess.run([sys.executable, str(R / 'tools/ext_pso_collect.py'), str(T / 'm'), str(seeds), '--sources', str(src)], capture_output=True, text=True)
o = run(); ck(o.returncode == 0, f'① 收集退出 0（{o.stdout.strip()[-160:]}{o.stderr.strip()[-200:]}）')
nx = (seeds / '0100AAAA00000000/ext_nx.tsv').read_text()
ck(nx == f'# source: repo=https://e.x/nx commit={c1} license=MIT author=nx path=dm/games/0100AAAA00000000/pso_manifest.tsv\n# 外部公开清单（只有标识与管线描述）：tools/ext_pso_collect.py 生成，勿手改；出包时按本包直连库的键滤\n'
          f'S\t1111222233334444_b\t0\nC\t5555666677778888_b\n{r_ok}\n', '② nxnative：首行来源、S 去重、C 与等长 R 原样、别的长度 R 与 M 行不收')
ck(not (seeds / 'NOTATITLE').exists() and not (seeds / 'notatitle').exists(), '③ 不是程序号的目录不收')
mg = (seeds / '0100BBBB00000000/ext_mng.tsv').read_text().split('\n')[2:]
ck(mg == ['S\te4b5b0967a3cd0b3_b\t1', 'C\te4b5b0967a3cd0b3_b', ''], f'④ mng：完整哈希键取前 16 位、V / 编码不同的 R 不收、没映射的目录不收（{mg}）')
ck((seeds / '0100CCCC00000000/zc_crowd.tsv').read_text() == own, '⑤ 我方种子文件不动')
t0 = (seeds / '0100AAAA00000000/ext_nx.tsv').stat().st_mtime_ns; o = run()
ck((seeds / '0100AAAA00000000/ext_nx.tsv').stat().st_mtime_ns == t0 and '改写 0 份' in o.stdout, '⑥ 再跑内容没变不重写')
sys.path.insert(0, str(R / 'tools')); import patch_pack
items = {r['path']: r for r in patch_pack.seed_rows(str(seeds))}
e = items.get('dm/games/0100AAAA00000000/pso_manifest.tsv', {}); m = items.get('0100CCCC00000000/zc_crowd.tsv', {})
ck((e.get('repo'), e.get('commit'), e.get('license'), e.get('author'), e.get('gids')) == ('https://e.x/nx', c1, 'MIT', 'nx', ['0100AAAA00000000']), '⑦ 社区包条目：外部清单署名取首行来源')
ck((m.get('repo'), m.get('commit'), m.get('author')) == ('S2Arm/pso-seeds', '', 'S2Arm'), '⑧ 我方种子署名不变')
(T / 'm/nx/dm/games/0100AAAA00000000/pso_manifest.tsv').unlink(); subprocess.run(['git', '-C', str(T / 'm/nx'), '-c', 'user.name=t', '-c', 'user.email=t@t', 'commit', '-qam', 'rm'], check=True)
o = run(); ck(not (seeds / '0100AAAA00000000/ext_nx.tsv').exists() and (seeds / '0100CCCC00000000/zc_crowd.tsv').exists() and '撤 1 份' in o.stdout, '⑨ 上游删了的款撤掉本工具写的文件、别的不动')
# ---- R 行转换（期望手算：按 nvn_pso_skey.h 偏移拼一条我方键，再按对方结构摆字节）----
import struct, importlib.util
spec = importlib.util.spec_from_file_location('epc', R / 'tools/ext_pso_collect.py'); epc = importlib.util.module_from_spec(spec); spec.loader.exec_module(epc)
ours = bytearray(432); ours[0:18] = b'1111222233334444_b'; ours[24:42] = b'5555666677778888_b'
struct.pack_into('<I', ours, 104, 70); struct.pack_into('<I', ours, 148, 1); struct.pack_into('<I', ours, 152, 0xf)   # cfmt[0] = 70（非整数格式）、blend_en 位 0、chmask
blend = (0x5 << 3) | (1 << 40) | 0x3                                                         # 因子位 + 高级混合位 40 + target 位
struct.pack_into('<Q', ours, 160, blend); want = bytearray(ours); struct.pack_into('<Q', want, 160, 0x5 << 3); want = bytes(want).hex()
h880 = bytes(ours) + struct.pack('<II', 0, 7)                                                # atest 0、logic 7（丢）
ck(epc.conv_nx(h880.hex()) == (want, None), '⑩ nxnative 880：取前 432 字节、清高级混合位与 target 位、logic 丢')
ck(epc.conv_nx((bytes(ours) + struct.pack('<II', 1, 0)).hex())[0] is None, '⑪ nxnative 880 alpha 测试开 → 不收')
ck(epc.conv_nx((bytes(ours) + bytes(8) + bytes(64) + struct.pack('<II', 1, 0)).hex()) == (want, None), '⑫ nxnative 1024：border 丢、其余同 880')
vs, fs = 'e4b5b0967a3cd0b3' + 'a' * 48 + '-b7530f698e76_b', '0123456789abcdef' + 'b' * 48 + '_b'
m = bytearray(544); m[0:len(vs)] = vs.encode(); m[80:80 + len(fs)] = fs.encode(); m[200:544] = ours[88:432]
w2 = bytearray(bytes.fromhex(want)); w2[0:24] = b'e4b5b0967a3cd0b3_b'.ljust(24, b'\0'); w2[24:48] = b'0123456789abcdef_b'.ljust(24, b'\0')
ck(epc.conv_mng(bytes(m).hex()) == (bytes(w2).hex(), None), '⑬ MacNativeGames 明文 1088：着色器名取 sha256 前 16 位 + _b、pso_key 照搬后规范化')
packed = vs + ':' + fs + ':' + re.sub('(00)+', lambda z: f'z{len(z.group(0)) // 2:x}.', bytes(m[160:544]).hex())
ck(epc.conv_mng(packed) == (bytes(w2).hex(), None), '⑭ MacNativeGames 压缩写法展开后同明文')
m2 = bytearray(m); struct.pack_into('<I', m2, 200 + 68, 0x4)
ck(epc.conv_mng(bytes(m2).hex())[0] is None, '⑮ MacNativeGames a2c MetalFX 位 → 不收')
print(f'ext_pso_collect：{15 - fails}/15 通过'); sys.exit(1 if fails else 0)
PY
