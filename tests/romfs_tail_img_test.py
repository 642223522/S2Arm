#!/usr/bin/env python3
"""出包尾段直接用 RomFS 镜像（RomFS 不落散文件第 3 段）：python3 tests/romfs_tail_img_test.py
同一份夹具产物根走两遍尾段（资源包 pack/pack.py → 核对 pack/verify.py → 单文件镜像 pack/romfs_image.py → 写 IMG pack/img.py convert）：
目录形态（romfs/ 在）与镜像形态（romfs/ 拿走、只有 services/romfs_index --std 从同一目录建的 romfs.std）。期望：
  ① 两种形态的 pack.files 与 pack 的 index.tsv / manifest.json、romfs.imgmap、最终 game.img / game.imgmap / index.tsv / manifest.json 逐字节相同；
     index.tsv 的 romfs 行 = 夹具文件的长度与 SHA-256（测试里按夹具字节独立算）；界面覆盖层（ui_overlay/romfs）那个文件取覆盖后的字节
  ② 镜像形态的 pack.files 里是 romfs.std（不拆散文件），romfs/ 下只有覆盖层那个真文件；上一版是目录形态时留下的散文件删掉；pack 里是 romfs.std、没有 romfs.files/
  ③ 核对：镜像形态绿；包里那份镜像改一个字节（落在某个文件里）→ 红、点名那个文件；重打 0 个要重算、核对增量全跳过
  ④ 推送现拼（materialize）从 romfs.std 读：拼出的 romfs.img 长度 / SHA-256 = index.tsv 记的
  ⑤ 写 IMG 边写边腾（consume）：镜像独占（1 个链接）→ 写完镜像没了、game.img 不变；镜像另有硬链接 → 那份完好、这个名字删掉、game.img 不变
  ⑥ 镜像形态 + 就地改 RomFS 的界面覆盖（没有 ui_overlay/）→ 报红
（要 dotnet 编 services/romfs_index；没有 dotnet 时整份跳过并打印原因，退出 0）"""
import hashlib, os, shlex, shutil, struct, subprocess, sys, tempfile
from pathlib import Path

R = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(R / 'pack'))
import img, pkg_srcs, romfs_image   # noqa: E402
from romfs_img import RomfsImage   # noqa: E402

bad = 0
def ck(ok, msg):
    global bad
    print(('通 ' if ok else '不通 ') + msg); bad += 0 if ok else 1


def sha(b): return hashlib.sha256(b).hexdigest()


def romfs_index_cmd(t):   # 同 tests/img_test.py
    dotnet = shutil.which('dotnet') or (os.path.join(os.environ['DOTNET_ROOT'], 'dotnet') if os.environ.get('DOTNET_ROOT') else None)
    if not dotnet: return None, '没有 dotnet'
    out = os.path.join(t, 'ri')
    r = subprocess.run([dotnet, 'build', str(R / 'services/romfs_index'), '-c', 'Release', '-o', out], capture_output=True, text=True)
    if r.returncode: return None, '编 services/romfs_index 失败：' + r.stdout[-300:]
    return f'{shlex.quote(dotnet)} {shlex.quote(os.path.join(out, "romfs_index.dll"))}', ''


def s2aidx(files):   # RomFS 预建索引（格式同 tests/romfs_image_test.py index）：romfs_image / write_map 只用文件表的顺序与长度
    paths = b''.join(rel.encode() for _, rel in files); out = b'S2ARFS01' + struct.pack('<qi', 1 << 20, len(files)); p = 0
    for n, rel in files:
        out += struct.pack('<qqii', 0, n, p, len(rel.encode())); p += len(rel.encode())
    return out + struct.pack('<i', len(paths)) + paths + struct.pack('<i', 0)


def run(*a):
    return subprocess.run([sys.executable, *map(str, a)], capture_output=True, text=True, cwd=R)


def read(p): return Path(p).read_bytes()


ROMFS = {'a/b c/big.bin': os.urandom(300000), 'a/小.txt': b'hi', 'empty': b'', 'Pack/Boot.pack': b'ORIGINAL', 'd/e/f.bin': os.urandom(7000), 'z.bin': b'ZZ'}
OVER = {'Pack/Boot.pack': b'OVERLAID!'}

with tempfile.TemporaryDirectory(prefix='romfs tail ') as t:
    T = Path(t)
    cmd, why = romfs_index_cmd(t)
    if not cmd:
        print(f'跳过：{why}'); sys.exit(0)

    def root(name, image):
        w = T / name; (w / 'exefs').mkdir(parents=True); (w / 'ctl').mkdir(); (w / 'ui_overlay/romfs/Pack').mkdir(parents=True)
        (w / 'exefs/main.npdm').write_bytes(b'NPDM' * 10); (w / 'ctl/control.nacp').write_bytes(b'NACP')
        (w / 'unpack.tsv').write_text('title_id\t0100000000abc000\n')
        for k, v in OVER.items(): (w / 'ui_overlay/romfs' / k).write_bytes(v)
        (w / 'ui_overlay.tsv').write_text(''.join(k + '\n' for k in OVER))
        (w / 'romfs.s2aidx').write_bytes(s2aidx([(len(v), k) for k, v in sorted({**ROMFS, **OVER}.items()) if v]))   # 预建索引按覆盖后的视图
        for k, v in ROMFS.items(): (w / 'romfs' / k).parent.mkdir(parents=True, exist_ok=True); (w / 'romfs' / k).write_bytes(v)
        if image:
            std = w / 'romfs.std'; std.write_bytes(b'')
            r = subprocess.run(shlex.split(cmd) + ['--std', str(w / 'romfs'), '-', str(std), '0'], capture_output=True, text=True)
            if r.returncode: sys.exit(f'建镜像失败：{r.stderr[-300:]}')
            shutil.rmtree(w / 'romfs')
        return w

    def tail(w, pk, stop_after_image=False):
        srcs = pk / 'srcs.txt'; pk.mkdir(exist_ok=True)
        srcs.write_text(''.join(f'{x}={y}\n' for x, y in pkg_srcs.srcs(str(w))))
        out = {}
        for step, a in (('pack', [R / 'pack/pack.py', pk / 'pack.files', '@' + str(srcs)]), ('verify', [R / 'pack/verify.py', pk / 'pack.files', '@' + str(srcs)]),
                        ('image', [R / 'pack/romfs_image.py', pk / 'pack.files', pk / 'pack', '--root', w])):
            r = run(*a); out[step] = r.stdout + r.stderr
            if r.returncode: print(out[step]); sys.exit(f'{step} 失败')
        return out

    D, I = root('dir', False), root('img', True)
    pd, pi = T / 'pkg_dir', T / 'pkg_img'
    od = tail(D, pd)
    # ② 先在镜像形态的输出位置打一遍目录形态（上一版是目录形态），再换镜像形态打：散文件要删掉
    D2 = root('img_prev_dir', False); tail(D2, pi); shutil.rmtree(D2)
    oi = tail(I, pi)

    # ① 资源包 / 单文件镜像两层的清单逐字节相同
    for rel in ('pack.files/index.tsv', 'pack.files/manifest.json', 'pack/index.tsv', 'pack/manifest.json', 'pack/romfs.imgmap'):
        ck(read(pd / rel) == read(pi / rel), f'① {rel}：目录形态与镜像形态逐字节相同')
    ix = {l.split('\t')[0]: l.split('\t')[1:] for l in (pi / 'pack.files/index.tsv').read_text().splitlines()}
    want = {**ROMFS, **OVER}
    ck(all(ix.get('romfs/' + k) == [str(len(v)), sha(v)] for k, v in want.items()) and len([k for k in ix if k.startswith('romfs/')]) == len(want),
       f'① 镜像形态 index.tsv 的 romfs 行 = 夹具 {len(want)} 个文件的长度 / SHA-256（覆盖层那个取覆盖后字节）')

    # ② 包里是镜像、不拆散文件
    left = sorted(str(p.relative_to(pi / 'pack.files/romfs')) for p in (pi / 'pack.files/romfs').rglob('*') if p.is_file())
    ck((pi / 'pack.files/romfs.std').is_file() and read(pi / 'pack.files/romfs.std') == read(I / 'romfs.std'), '② pack.files 里有 romfs.std，字节同产物根那份')
    ck(left == sorted(OVER), f'② pack.files/romfs/ 下只剩覆盖层那个真文件（上一版目录形态留下的散文件删了；实得 {left}）')
    ck((pi / 'pack/romfs.std').is_file() and not (pi / 'pack/romfs.files').exists(), '② pack 里是 romfs.std 硬链接、没有 romfs.files/')
    ck((pd / 'pack/romfs.files').is_dir() and not (pd / 'pack/romfs.std').exists(), '② 目录形态照旧 romfs.files/、没有 romfs.std')

    # ④ 推送现拼从 romfs.std 读
    row = {l.split('\t')[0]: l.split('\t') for l in (pi / 'pack/index.tsv').read_text().splitlines()}['romfs.img']
    try:
        f = Path(romfs_image.materialize(pi / 'pack', 'romfs.img', int(row[1]), row[2], say=lambda *_: None))
        body = b''.join(ROMFS[k] for k, v in sorted(ROMFS.items()) if v and k not in OVER)
        ck(f.read_bytes() == body, '④ materialize 从 romfs.std 拼出的 romfs.img = 夹具非覆盖文件按索引顺序首尾相接'); f.unlink()
    except romfs_image.Red as e:
        ck(False, f'④ materialize 报红：{e}')

    # ① 写 IMG：两种形态 game.img 等逐字节相同
    def convert(w, pk, **kw):
        q = T / (pk.name + '_' + kw.pop('tag', 'c')); shutil.copytree(pk / 'pack', q, copy_function=os.link)   # 每次转在自己的一份上（硬链接，不另占）
        img.convert(str(w), str(q), romfs_index=cmd, gid='0100000000ABC000', **kw); return q
    cd, ci = convert(D, pd), convert(I, pi)
    for rel in ('game.img', 'game.imgmap', 'index.tsv', 'manifest.json'):
        ck(read(cd / rel) == read(ci / rel), f'① 写 IMG 后 {rel}：目录形态与镜像形态逐字节相同')
    seg = RomfsImage.in_img(ci / 'game.img')
    ck({k: seg.read(k) for k, _, _ in seg.entries()} == ROMFS, '① game.img 的 RomFS 段 = 产物根原版 RomFS（覆盖层那个仍是原版字节）')
    ck(not (ci / 'romfs.std').exists() and (I / 'romfs.std').is_file(), '① 转完资源包里的 romfs.std 删掉、产物根那份不动（没 consume）')

    # ⑤ consume
    def consumed(link):   # 产物根放进自己的出包工作目录 <工作目录>/roots/<版本>（free_clones 按产物根上两级认这款的各份，不能和别的夹具同级）
        work = T / f'consume_{link}'; w = work / 'roots' / 'v1'; shutil.copytree(I, w)
        other = T / f'other_{link}.std'
        if link: os.link(w / 'romfs.std', other)
        q = convert(w, pi, tag=f'k{link}', consume=True, work=str(work))
        return w, q, other
    w, q, _ = consumed(False)
    ck(not (w / 'romfs.std').exists() and read(q / 'game.img') == read(cd / 'game.img'), '⑤ 镜像独占 → 边写边截、写完镜像删掉，game.img 与目录形态逐字节相同')
    w, q, other = consumed(True)
    ck(not (w / 'romfs.std').exists() and read(other) == read(I / 'romfs.std') and read(q / 'game.img') == read(cd / 'game.img'),
       '⑤ 镜像另有硬链接 → 那份完好（不截短）、这个名字删掉，game.img 不变')

    # ⑥ 就地改的界面覆盖 + 只有镜像 → 红
    w = T / 'inplace'; shutil.copytree(I, w); shutil.rmtree(w / 'ui_overlay'); (w / 'seed.txt').write_text(f'src={D}\n')
    try:
        convert(w, pi, tag='inplace'); ck(False, '⑥ 就地覆盖 + 只有镜像 → 应报红')
    except img.Red as e:
        ck('就地改 RomFS' in str(e), '⑥ 就地覆盖 + 只有镜像 → 报红（分不出原版）')

    # ③ 核对 / 增量（放最后：改的是 pack.files 里那份镜像，pack 里硬链着同一份）
    srcs = pi / 'srcs.txt'
    ck('🟢' in oi['verify'], '③ 镜像形态核对绿')
    r = run(R / 'pack/pack.py', pi / 'pack.files', '@' + str(srcs)); ck('克隆 / 重算 0 个' in r.stdout, f'③ 镜像没变重打 → 0 个要重算（实得 {r.stdout.strip()[-60:]}）')
    r = run(R / 'pack/verify.py', pi / 'pack.files', '@' + str(srcs)); ck(f'核 3 个，{len(want)} 个与上次核对时源 / 包都没变' in r.stdout,
       f'③ 核对增量：源 / 包镜像都没变 → romfs {len(want)} 个都不重比，只比按全内容进包键的 npdm / nacp / s2aidx 3 个（实得 {r.stdout.strip()[:90]}）')
    off = RomfsImage(pi / 'pack.files/romfs.std').files()['d/e/f.bin'][0] + 5
    with open(pi / 'pack.files/romfs.std', 'r+b') as f: f.seek(off); b = f.read(1); f.seek(off); f.write(bytes([b[0] ^ 0xFF]))
    r = run(R / 'pack/verify.py', pi / 'pack.files', '@' + str(srcs))
    ck(r.returncode == 1 and 'romfs/d/e/f.bin（SHA 与 index 不符）' in r.stdout, '③ 包里那份镜像改一个字节 → 核对红、点名 romfs/d/e/f.bin')
    ck(read(I / 'romfs.std') != read(pi / 'pack.files/romfs.std'), '③ 改的是包里那份（克隆独立），源镜像没被带着改')
    r = run(R / 'pack/pack.py', pi / 'pack.files', '@' + str(srcs)); r2 = run(R / 'pack/verify.py', pi / 'pack.files', '@' + str(srcs))
    ck(r2.returncode == 0, '③ 不删状态表直接重打 → 核对恢复绿')

print('romfs_tail_img 单测' + ('全过' if not bad else f'有 {bad} 处不通'))
sys.exit(1 if bad else 0)
