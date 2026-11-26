"""Switch 1 着色器键第 2 代（translator/nvn_key.py；宿主同口径 graphics/nvn/gfx/nvn/nvn_key.h）在各离线算键处的口径。合成字节，不用游戏数据。
期望值按规则用 hashlib 逐字节手算（下面 HAND 表是另写的一次性脚本算出后抄进来的，不经被测实现）：
  v1 = sha256(ctl[:n] ‖ code)[:16]；v2 = 同上，但 ctl 的 [0x790,0x798)、[0x7d0,0x7e8) 落在 n 内的字节先置 0；n = +0x20 自报长度 ∈ [0x760,0x880) 时取它，否则 0x880
  夹具：ctl[i] = (i*7+3) & 0xff（0x880 字节），+0x20 = own，+0x704 = 0x40；code[i] = (i*13+5) & 0xff（0x40 字节），前 4 字节 78 56 34 12
① nvn_key.skey 第 2 / 1 代 = HAND；A 与 B（只差两段）v2 同、v1 不同；C（差在 +0x100）v2 不同；D（own 0x7e0：第二段只置零到 0x7e0）、E（只差 nctl 内两段）、F（差在 nctl 外）同 v2
② 出包各处同口径：shader_split.skey、merge_extract.nx_key、nxsh_extract.key_of、android/tools/direct_prepare.extraction_key 对 A / D 都 = HAND 的 v2
③ nxsh_extract.key_of 对整段控制段（含自报 0x88c、长于 0x880 的）：sha256(整段、两段置零 ‖ code)（S2Arm 抽取口径，整段）
④ Switch 2 控制段（魔数 98761234、版本 c9）键不变：= d84a694ffca1c9c9（ns2_shaders 规则，与第 2 代无关）
⑤ rt_dump_merge：按第 1 代键命名的 Switch 1 顶点转储照收，按第 2 代键进库；同内容第 1、2 代各一份只进一次
⑥ merge_extract.py --alias 出包内键别名表：两段非零的着色器进表（第 1 代 → 第 2 代），两段全零的不进表
反证：nvn_key.key_bytes 不置零 → ①② A/D 红、⑤ 键不符跳过、⑥ 表为空；rt_dump_merge 不认第 1 代文件名 → ⑤ 跳过 1 支"""
import hashlib, os, shutil, struct, subprocess, sys, tempfile
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
for d in ('translator', 'graphics/tools/direct', 'graphics/tools/shbake', 'android/tools'): sys.path.insert(0, str(ROOT / d))
bad = 0
def ck(name, want, got):
    global bad
    ok = want == got; bad += not ok
    print(f"{'✓' if ok else '✗'} {name}：期望 {want}，实 {got}")

def ctl_of(own):
    c = bytearray((i * 7 + 3) & 0xff for i in range(0x880))
    struct.pack_into('<I', c, 0x20, own); struct.pack_into('<I', c, 0x704, 0x40); return c
code = bytearray((i * 13 + 5) & 0xff for i in range(0x40)); code[0:4] = bytes.fromhex('78563412'); code = bytes(code)
A = ctl_of(0x880); B = bytearray(A); C = bytearray(A); C[0x100] ^= 1
for i in range(0x790, 0x798): B[i] ^= 0x5a
for i in range(0x7d0, 0x7e8): B[i] ^= 0xa5
D = ctl_of(0x7e0); E = bytearray(D); E[0x7d8] ^= 0xff; E[0x792] ^= 0xff; F = bytearray(D); F[0x7e4] ^= 0xff
HAND = {'A': ('404d87c7549fd09c', 'e0d0ef6990987e99'), 'B': ('1dee7e8e37634f1d', 'e0d0ef6990987e99'), 'C': ('18e4a9d2f3ced205', '4aa6cc1d9c43e270'),
        'D': ('54daf52547a5a9b4', '2729eeba92fce15e'), 'E': ('057da50789e2819a', '2729eeba92fce15e'), 'F': ('54daf52547a5a9b4', '2729eeba92fce15e')}

import nvn_key
for n, c in (('A', A), ('B', B), ('C', C), ('D', D), ('E', E), ('F', F)):
    ck(f"① {n} 第 1 / 2 代", HAND[n], (nvn_key.skey(bytes(c), code, gen=1), nvn_key.skey(bytes(c), code)))

with tempfile.TemporaryDirectory(prefix='s2a-keyv2-') as d:
    prof = Path(d) / 'profile'; prof.mkdir()
    shutil.copyfile(ROOT / 'tests/fixtures/shader_split_reuse/shader_split_reuse_profile.tsv', prof / 'game.tsv')
    os.environ['DM_GAME'] = str(prof)
    import shader_split, merge_extract, nxsh_extract, direct_prepare
    for n, c in (('A', A), ('D', D)):
        want = HAND[n][1]
        ck(f"② shader_split.skey {n}", want, shader_split.skey(bytes(c), code))
        ck(f"② merge_extract.nx_key {n}", want, merge_extract.nx_key(bytes(c), code))
        ck(f"② direct_prepare.extraction_key {n}", want, direct_prepare.extraction_key(code, bytes(c)))
    # nxsh_extract.key_of 只认带控制段魔数 34127698、+0x20 = 整段长的控制段：夹具换上魔数，期望照规则另算
    for n, own in (('0x880', 0x880), ('0x7e0', 0x7e0), ('0x88c（长于 0x880，整段进键）', 0x88c)):
        L = bytearray((i * 7 + 3) & 0xff for i in range(own)); L[:4] = bytes.fromhex('34127698'); struct.pack_into('<I', L, 0x20, own); struct.pack_into('<I', L, 0x704, 0x40)
        h = bytearray(L); h[0x790:0x798] = bytes(8); h[0x7d0:min(0x7e8, own)] = bytes(min(0x7e8, own) - 0x7d0)
        ck(f"②③ nxsh_extract.key_of 整段 {n}", hashlib.sha256(bytes(h) + code).hexdigest()[:16], nxsh_extract.key_of(bytes(L), code))
    n2 = bytearray((i * 5 + 1) & 0xff for i in range(0xe0)); struct.pack_into('<II', n2, 0, 0x98761234, 0xc9); struct.pack_into('<I', n2, 0x44, 0x40)
    ck("④ Switch 2 键不变", 'd84a694ffca1c9c9', nvn_key.skey(bytes(n2), code))
    ck("④ Switch 2 键不变（shader_split）", 'd84a694ffca1c9c9', shader_split.skey(bytes(n2), code))

    # ⑤ 顶点着色器转储（SPH 字 0x0461 = 顶点），控制段两段非零；键手算
    vc = bytearray(0x100); vc[:4] = bytes.fromhex('78563412'); struct.pack_into('<I', vc, 0x30, 0x0461)
    for i in range(0x80, 0x100): vc[i] = (i * 5 + 1) & 0xff
    vc = bytes(vc)
    vt = bytearray(0x880); vt[:4] = bytes.fromhex('34127698'); struct.pack_into('<I', vt, 0x20, 0x880); struct.pack_into('<I', vt, 0x704, len(vc))
    vt[0x790:0x798] = b'\x11' * 8; vt[0x7d0:0x7e8] = b'\x22' * 24; vt = bytes(vt)
    k1 = hashlib.sha256(vt + vc).hexdigest()[:16]
    z = bytearray(vt); z[0x790:0x798] = bytes(8); z[0x7d0:0x7e8] = bytes(24); k2 = hashlib.sha256(bytes(z) + vc).hexdigest()[:16]
    for case, names in (('第 1 代命名', (k1,)), ('第 1、2 代各一份', (k1, k2))):
        w = Path(d) / ('m%d' % len(names)); (w / 'dump').mkdir(parents=True); (w / 'pkg').mkdir()
        for k in names: (w / 'dump' / f'{k}.ctl').write_bytes(vt); (w / 'dump' / f'{k}.code').write_bytes(vc)
        (w / 'map.tsv').write_text('package\tindex\tstage\tdm_ctl_sha16\tsource\n'); (w / 'facts.tsv').write_text('# 答案表\n')
        r = subprocess.run([sys.executable, str(ROOT / 'translator/rt_dump_merge.py'), str(w / 'dump'), str(w / 'pkg'), str(w / 'map.tsv'), str(w / 'facts.tsv')], capture_output=True, text=True)
        rows = [l.split('\t')[3] for l in (w / 'map.tsv').read_text().splitlines()[1:]]
        ck(f"⑤ rt_dump_merge {case}：退出码、表里的键", (0, [k2]), (r.returncode, rows))

    # ⑥ 包内键别名表（merge_extract.py --alias）：顶点转储同一份控制段 vt（两段非零）→ 一行 k1 → k2（上面手算）；两段全零的另一支（vz）两代同键，不进表
    w = Path(d) / 'alias'; (w / 'pkg').mkdir(parents=True)
    vz = bytearray(vt); vz[0x790:0x798] = bytes(8); vz[0x7d0:0x7e8] = bytes(24); vz[0x100] = 0x5a; vz = bytes(vz)
    kz = hashlib.sha256(vz + vc).hexdigest()[:16]
    def rec(code, ctl):
        r = bytearray(b'BTCDBTCD' + bytes(0x30)); struct.pack_into('<2I', r, 0x28, len(ctl), len(code)); return bytes(r) + code + ctl
    (w / 'pkg' / 'vs_t.bin').write_bytes(rec(vc, vt) + rec(vc, vz))
    (w / 'map.tsv').write_text(f'package\tindex\tstage\tdm_ctl_sha16\tsource\nvs_t.bin\t0\tvertex\t{k2}\tx\nvs_t.bin\t1\tvertex\t{kz}\tx\n')
    r = subprocess.run([sys.executable, str(ROOT / 'graphics/tools/direct/merge_extract.py'), '--alias', str(w / 'pkg'), str(w / 'map.tsv'), str(w / 'key_alias.tsv')], capture_output=True, text=True)
    rows = [l.split('\t') for l in (w / 'key_alias.tsv').read_text().splitlines() if l and not l.startswith('#')] if r.returncode == 0 else r.stderr[-300:]
    ck("⑥ 键别名表：两段非零的进表 k1 → k2，全零的不进表", [[k1, k2]], rows)

# ⑦ 抽取的「同键两份是否同一着色器」按第 2 代口径比（shader_split.same_shader / uniq_keys）：只差两段易变字段的两份是同一着色器，
#   原先按原始控制段比，判成「同键不同内容」、red 退出，整份数据文件被跳过（一款 Unity 游戏 52,692 支掉到 138 支）
ck("⑦ same_shader：只差两段易变字段 = 同一着色器", True, shader_split.same_shader((bytes(A), code), (bytes(B), code)))
ck("⑦ same_shader：短控制段（自身长度 0x7e0）里只差易变字段 = 同一着色器", True, shader_split.same_shader((bytes(D), code), (bytes(E), code)))
G = bytearray(B); G[0x100] ^= 1   # 两段易变字段不同、别处也不同
ck("⑦ 两段易变字段不同、别处也不同：第 2 代键不同（别处的差别照样分得开）", True, nvn_key.skey(bytes(A), code) != nvn_key.skey(bytes(G), code))
ck("⑦ same_shader：差在易变字段以外 = 不是同一着色器", False, shader_split.same_shader((bytes(A), code), (bytes(C), code)))
try:
    got = sorted(shader_split.uniq_keys([('a', 'vs', bytes(A), code), ('b', 'vs', bytes(B), code)]))
except SystemExit as e:
    got = 'red：' + str(e)[:60]
ck("⑦ uniq_keys：只差易变字段的两份合成一个第 2 代键、不判红", [HAND['A'][1]], got)

print('shader_key_v2 单测全过' if not bad else f'shader_key_v2 单测有 {bad} 项不通')
sys.exit(1 if bad else 0)
