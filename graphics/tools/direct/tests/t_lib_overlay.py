#!/usr/bin/env python3
# 直连库覆盖层生成单测（C# LibPack.Overlay，经 dsh_batch --libpack overlay 调；宿主读法 graphics/nvn/lib_pack.inc lp_pick，<库目录>/bf/）。
#   用途：S 级升级给老包补可读瓦片版（_bf）——old = 玩家现有的主容器，fresh = 当前翻译器整份重出的容器，覆盖层只收 old 没有、fresh 有 _bf 的键。
#   手造两份按键文件目录，用同一工具 --libpack pack 打成容器，期望全按写进去的字节手写：
#     K1：old 反射无 fetch、无 _bf；fresh 反射 = old + fetch、有 _bf → 收：覆盖层里 K1 的种类 1（json）= fresh 那份字节、种类 2（_bf）= fresh 那份字节
#     K2：fresh 反射除了 fetch 还改了 fn_prefix（配不上主容器的旧库）→ 跳过
#     K3：old 已有 _bf → 不收
#     K4（顶点）：重出只多了 raster.scr_pos、无 _bf → 只收它的 json（同像素证明要它，#1152 实测漏了它 ⑤ 全拒）
#     K5（顶点）：反射一字不差 → 不收；K6（顶点）：只多了空的 scr_pos → 不收（证明不了什么，不推）
#     K7：重出批库名 fn_lib 变了（批库分组重排，函数没变）+ fetch + _bf → 收；覆盖层的反射 = 旧反射（旧 fn_lib，指向旧容器里真有的批库）+ 新 fetch
#     覆盖层的反射都按 JSON 内容比（旧反射为底换进 fetch / scr_pos，字段顺序与空白不保证同重出那份）
#     覆盖层只有 K1、K7 的两条与 K4 的 json；两份容器链版本不同 → 退出 1；没有要补的 → 退出 0、不建覆盖层目录
import json, os, struct, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '../../../../translator')); import dsh_batch
CMD, _ = dsh_batch.get()
fails = []
def check(cond, msg):
    print(('  ✓ ' if cond else '  ✗ ') + msg)
    if not cond: fails.append(msg)
def run(*a): return subprocess.run([*CMD, '--libpack', *a], capture_output=True, text=True)

K1, K2, K3, K4, K5, K6, K7, CHAIN = '0000000000000a01', '0000000000000a02', '0000000000000a03', '0000000000000a04', '0000000000000a05', '0000000000000a06', '0000000000000a07', '0a7dae3c1e7b'
LIB = b'MTLB-not-a-real-library-'   # 覆盖层只搬字节、不建库：内容任意（PackFiles 不核 metallib 内容）

def write(d, files):
    os.makedirs(d)
    for n, b in files.items(): open(os.path.join(d, n), 'wb').write(b if isinstance(b, bytes) else b.encode())

def read_idx(d):
    b = open(os.path.join(d, 'lib.idx'), 'rb').read()
    n, ns = struct.unpack_from('<II', b, 12); chain = b[24:36].rstrip(b'\0').decode()
    recs = [struct.unpack_from('<QBBHIQ', b, 48 + 16 * ns + 24 * i) for i in range(n)]
    return chain, recs

def seg(d, rec):
    key, kind, shard, _z, ln, off = rec
    with open(os.path.join(d, 'lib.%03d.pak' % shard), 'rb') as f: f.seek(off); return f.read(ln)

with tempfile.TemporaryDirectory() as t:
    j = lambda k, **x: json.dumps({"key": f"{k}_b", "stage": "ps", "fn_prefix": "s0_", **x}, sort_keys=True)
    jv = lambda k, **r: json.dumps({"key": f"{k}_b", "stage": "vs", "raster": {"pos_attr": 0, "scr_uv": [], **r}}, sort_keys=True)
    old = {f'{K1}_b.metallib': LIB + b'1', f'{K1}_b.json': j(K1),
           f'{K4}_b.metallib': LIB + b'4', f'{K4}_b.json': jv(K4), f'{K5}_b.metallib': LIB + b'5', f'{K5}_b.json': jv(K5, scr_pos=[3]), f'{K6}_b.metallib': LIB + b'6', f'{K6}_b.json': jv(K6),
           f'{K2}_b.metallib': LIB + b'2', f'{K2}_b.json': j(K2),
           f'{K3}_b.metallib': LIB + b'3', f'{K3}_b.json': j(K3, fetch={"calls": []}), f'{K3}_bf.metallib': LIB + b'3bf',
           'u_old.metallib': LIB + b'u_old', f'{K7}_b.json': j(K7, fn_lib='u_old')}
    fetch = {"calls": [{"fc": 0, "tex_reg": 9, "varying_locn": 7, "proj": 1, "ndc": 1}], "mixed_regs": [], "outputs": [{"color": 0, "type": "float4"}]}
    fresh = {f'{K1}_b.metallib': LIB + b'1', f'{K1}_b.json': j(K1, fetch=fetch), f'{K1}_bf.metallib': LIB + b'1bf',
             f'{K4}_b.metallib': LIB + b'4', f'{K4}_b.json': jv(K4, scr_pos=[7]), f'{K5}_b.metallib': LIB + b'5', f'{K5}_b.json': jv(K5, scr_pos=[3]), f'{K6}_b.metallib': LIB + b'6', f'{K6}_b.json': jv(K6, scr_pos=[]),
             f'{K2}_b.metallib': LIB + b'2', f'{K2}_b.json': json.dumps({"key": f"{K2}_b", "stage": "ps", "fn_prefix": "s9_", "fetch": fetch}, sort_keys=True), f'{K2}_bf.metallib': LIB + b'2bf',
             f'{K3}_b.metallib': LIB + b'3', f'{K3}_b.json': j(K3, fetch={"calls": []}), f'{K3}_bf.metallib': LIB + b'3bf-new',
             'u_new.metallib': LIB + b'u_new', f'{K7}_b.json': j(K7, fn_lib='u_new', fetch=fetch), f'{K7}_bf.metallib': LIB + b'7bf'}
    for name, files in (('old', old), ('fresh', fresh)):
        write(os.path.join(t, name + '_src'), files)
        r = run('pack', os.path.join(t, name + '_src'), os.path.join(t, name), CHAIN)
        check(r.returncode == 0, f'{name} 容器打成（{r.stderr.strip()[:120]}）')
    ov = os.path.join(t, 'bf')
    r = run('overlay', os.path.join(t, 'old'), os.path.join(t, 'fresh'), ov)
    check(r.returncode == 0 and '补 2 个键' in r.stdout and '跳过 1 个' in r.stdout, f'覆盖层：补 2 键、跳过 1 键，退出 0（{r.stdout.strip()[:160]}｜{r.stderr.strip()[:120]}）')
    chain, recs = read_idx(ov)
    check(chain == CHAIN, f'覆盖层链版本 = {CHAIN}（得 {chain}）')
    got = sorted((r_[0], r_[1]) for r_ in recs)
    check(got == [(int(K1, 16), 1), (int(K1, 16), 2), (int(K4, 16), 1), (int(K7, 16), 1), (int(K7, 16), 2)], f'覆盖层只有 K1、K7 的 json（种类 1）与 _bf（种类 2）、K4 的 json（得 {got}）')
    by = {(r_[0], r_[1]): r_ for r_ in recs}
    if (int(K1, 16), 1) in by: check(json.loads(seg(ov, by[(int(K1, 16), 1)])) == json.loads(fresh[f'{K1}_b.json']), 'K1 的 json = 旧反射 + fetch（内容同重出那份）')
    if (int(K1, 16), 2) in by: check(seg(ov, by[(int(K1, 16), 2)]) == fresh[f'{K1}_bf.metallib'], 'K1 的 _bf = 重出那份逐字节')
    if (int(K4, 16), 1) in by: check(json.loads(seg(ov, by[(int(K4, 16), 1)])) == json.loads(fresh[f'{K4}_b.json']), 'K4 的 json = 旧反射 + scr_pos（内容同重出那份）')
    want7 = {"key": f"{K7}_b", "stage": "ps", "fn_prefix": "s0_", "fn_lib": "u_old", "fetch": fetch}
    if (int(K7, 16), 1) in by: check(json.loads(seg(ov, by[(int(K7, 16), 1)])) == want7, 'K7 的 json = 旧反射（fn_lib 仍是 u_old）+ 新 fetch')
    if (int(K7, 16), 2) in by: check(seg(ov, by[(int(K7, 16), 2)]) == fresh[f'{K7}_bf.metallib'], 'K7 的 _bf = 重出那份逐字节')
    # 反证：链版本不同 → 红、退出 1
    write(os.path.join(t, 'other_src'), fresh)
    run('pack', os.path.join(t, 'other_src'), os.path.join(t, 'other'), '0000000000aa')
    r = run('overlay', os.path.join(t, 'old'), os.path.join(t, 'other'), os.path.join(t, 'bf2'))
    check(r.returncode == 1 and '链版本不同' in r.stderr and not os.path.exists(os.path.join(t, 'bf2', 'lib.idx')), f'链版本不同：退出 1、不出覆盖层（{r.stderr.strip()[:120]}）')
    # 没有要补的（fresh = old）→ 退出 0、不建覆盖层目录
    r = run('overlay', os.path.join(t, 'old'), os.path.join(t, 'old'), os.path.join(t, 'bf3'))
    check(r.returncode == 0 and '没有要补的' in r.stdout and not os.path.exists(os.path.join(t, 'bf3')), f'没有要补的：退出 0、不建目录（{r.stdout.strip()[:120]}）')

print(('✗ t_lib_overlay：%d 项不符' % len(fails)) if fails else '✓ t_lib_overlay：全过')
sys.exit(1 if fails else 0)
