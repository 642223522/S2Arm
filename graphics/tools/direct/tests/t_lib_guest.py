#!/usr/bin/env python3
# 直连库容器客体输入（种类 56）打包单测（C# LibPack.GuestBlocks / PackFiles，经 dsh_batch --libpack pack <输入目录>（含 guest/ 子目录）调；
#   宿主读法 graphics/nvn/lib_pack.inc lp_guest_get，读端在 graphics/nvn/tests/t_lib_pack.m 另测）。不依赖 Metal 工具链。
#   手造 guest/<键>.<阶段>.ctl / .code：阶段 0 二十个键（0x100..0x113，按键排 16 + 4 两块）、阶段 1 三个键（0x050 / 0x200 / 0x300，一块）、阶段 5 一个键（0x001，一块），
#   外加一个普通键文件（0x100 的 _b.json，同键另一种类）。按格式自己解析 lib.idx 与段（Python zlib 解压，不调被测实现），期望全部手算：
#   记录 = 24 条种类 56 + 1 条种类 1，按 (键, 种类) 升序；种类 56 的段 = u32 解压后长度 + u32 0 + zlib 流；4 块、同块的键 (分片, 偏移, 长度) 相同、不同块不同；
#   块头 = 条数（16 / 4 / 3 / 1）、阶段（0 / 0 / 1 / 5）、版本 1；块内键升序、每条控制段 + 代码区逐字节等于输入文件；同一输入再打一次逐字节相同（可复现）。
#   反证：给 Vulkan 侧指纹 → 退出 1（Vulkan 库不带客体输入）；同一键给两个阶段 → 退出 1、报红、输出目录不留 lib.idx
import os, random, shutil, struct, subprocess, sys, tempfile, zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, '../../../../translator')); import dsh_batch
CMD, _ = dsh_batch.get()
fails = []
def check(cond, msg):
    print(('  ✓ ' if cond else '  ✗ ') + msg)
    if not cond: fails.append(msg)
def pack(src, out, *extra): return subprocess.run([*CMD, '--libpack', 'pack', src, out, '0a7dae3c1e7b', *extra], capture_output=True, text=True, encoding='utf-8')

_inc = open(os.path.join(HERE, '../../../nvn/lib_pack_core.inc'), encoding='utf-8').read()
check('LP_K_GUEST = 56' in _inc, '宿主 graphics/nvn/lib_pack_core.inc 的 LP_K_GUEST = 56（下面按同号解析）')

rng = random.Random(56)
STAGE0 = [0x100 + i for i in range(20)]; STAGE1 = [0x050, 0x200, 0x300]; STAGE5 = [0x001]
inputs = {}   # 键 → (阶段, 控制段, 代码区)
for st, ks in ((0, STAGE0), (1, STAGE1), (5, STAGE5)):
    for k in ks: inputs[k] = (st, rng.randbytes(rng.randrange(0x40, 0x900)), rng.randbytes(rng.randrange(8, 3000)))
# 手算的分块：同阶段按键升序每 16 条一块，阶段升序
BLOCKS = [(0, STAGE0[:16]), (0, STAGE0[16:]), (1, sorted(STAGE1)), (5, STAGE5)]

def build(t, keys=inputs):
    d = os.path.join(t, 'src'); g = os.path.join(d, 'guest'); os.makedirs(g)
    for k, (st, c, code) in keys.items():
        open(os.path.join(g, f'{k:016x}.{st}.ctl'), 'wb').write(c); open(os.path.join(g, f'{k:016x}.{st}.code'), 'wb').write(code)
    open(os.path.join(d, f'{0x100:016x}_b.json'), 'w').write('{"stage": "vs"}')
    return d

def parse(d):
    idx = open(os.path.join(d, 'lib.idx'), 'rb').read()
    n, ns = struct.unpack_from('<II', idx, 12)
    recs = [struct.unpack_from('<QBBHIQ', idx, 48 + 16 * ns + 24 * i) for i in range(n)]
    return idx, recs

with tempfile.TemporaryDirectory() as t:
    src = build(t); out = os.path.join(t, 'out')
    r = pack(src, out)
    check(r.returncode == 0 and '客体输入 24 键 4 块' in r.stdout, f'打包退出 0、汇总行报「客体输入 24 键 4 块」（{r.stdout.strip()[-160:]}{r.stderr.strip()[:200]}）')
    idx, recs = parse(out)
    want_order = sorted([(k, 56) for k in inputs] + [(0x100, 1)])
    check([(k, kd) for k, kd, *_ in recs] == want_order, f'记录 25 条（24 条种类 56 + 1 条种类 1），按 (键, 种类) 升序')
    seg_of = {k: (sh, off, ln) for k, kd, sh, _, ln, off in recs if kd == 56}
    shards = {}
    def seg(sh, off, ln):
        if sh not in shards: shards[sh] = open(os.path.join(out, f'lib.{sh:03d}.pak'), 'rb').read()
        return shards[sh][off:off + ln]
    distinct = []
    for bi, (st, ks) in enumerate(BLOCKS):
        locs = {seg_of[k] for k in ks}
        check(len(locs) == 1, f'块 {bi}（阶段 {st}，{len(ks)} 键）：这些键的记录指向同一段')
        loc = next(iter(locs)); distinct.append(loc)
        b = seg(*loc); rawlen, z = struct.unpack_from('<II', b, 0); raw = zlib.decompress(b[8:])
        check(z == 0 and rawlen == len(raw) and loc[1] % 16 == 0, f'块 {bi}：段头解压后长度 {rawlen} = 实际 {len(raw)}、第二个字为 0、段起点 16 字节对齐')
        cnt, bst, ver, z16 = struct.unpack_from('<IBBH', raw, 0)
        check((cnt, bst, ver, z16) == (len(ks), st, 1, 0), f'块 {bi}：块头 条数 {cnt} 阶段 {bst} 版本 {ver}（期望 {len(ks)} / {st} / 1）')
        ents = [struct.unpack_from('<QIIII', raw, 8 + 24 * i) for i in range(cnt)]
        check([e[0] for e in ents] == ks, f'块 {bi}：块内键升序 = 手算分块')
        ok = all(raw[o:o + nc] == inputs[k][1] and raw[o + nc:o + nc + nd] == inputs[k][2] and zz == 0 for k, o, nc, nd, zz in ents)
        check(ok, f'块 {bi}：每条控制段 + 代码区逐字节等于输入文件')
    check(len(set(distinct)) == 4, '4 块落在 4 个不同的段')
    out2 = os.path.join(t, 'out2'); r2 = pack(src, out2)
    same = r2.returncode == 0 and all(open(os.path.join(out, f), 'rb').read() == open(os.path.join(out2, f), 'rb').read() for f in sorted(os.listdir(out)))
    check(same and sorted(os.listdir(out)) == sorted(os.listdir(out2)), '同一输入再打一次：产物逐字节相同')
    r3 = pack(src, os.path.join(t, 'out3'), '0123456789abcdef')
    check(r3.returncode == 1 and 'Vulkan 库不带客体输入' in r3.stderr, f'反证：给 Vulkan 侧指纹 → 退出 1、报红（{r3.stderr.strip()[:120]}）')
with tempfile.TemporaryDirectory() as t:
    dup = dict(inputs); src = build(t, dup)
    st, c, code = inputs[0x100]
    open(os.path.join(src, 'guest', f'{0x100:016x}.1.ctl'), 'wb').write(c); open(os.path.join(src, 'guest', f'{0x100:016x}.1.code'), 'wb').write(code)
    out = os.path.join(t, 'out'); r = pack(src, out)
    check(r.returncode == 1 and '[RED]' in r.stderr and '同一个键' in r.stderr and not os.path.exists(os.path.join(out, 'lib.idx')), f'反证：同一键给两个阶段 → 退出 1、报红、不留 lib.idx（{r.stderr.strip()[:120]}）')
print('PASS' if not fails else f'FAIL：{len(fails)} 处')
sys.exit(1 if fails else 0)
