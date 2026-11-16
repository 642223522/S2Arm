#!/usr/bin/env python3
"""RomFS 清单「目录不在、旁边有 <目录>.std 就从镜像盘点」单测（graphics/nvn/tools/romfs_list.py；python3 tests/romfs_list_img_test.py）。
期望一律来自夹具目录本身（os.walk / open().read），镜像用 services/romfs_index --std（LibHac RomFsBuilder，出 IMG 那一份）建，不跑被测实现推：
  ① 同一份内容：目录盘点与镜像盘点的条目集合（路径、类型、文件大小）相同；walk 按目录逐层的（子目录集合、文件集合）相同；listdir 根与子目录同集合
  ② heads：每个文件的（大小、前 32 字节）同 open().read(32)；e.open() 读全文同夹具
  ③ 命令行 has-ext 同真假、sizes 同集合；files0 镜像下报红退 1（没有散文件路径）
  ④ 目录在就读目录（旁边有 .std 也不看）；目录、镜像都没有 → 同目录盘点的报错
  ⑤ 清单：镜像盘点照样落盘、同镜像再来从清单取不读；镜像文件修改时间变 → 身份变
（要 dotnet 编 services/romfs_index；没有 dotnet 时整份跳过并打印原因，退出 0；夹具不放空目录 / 软链：镜像里本来没有这两样）"""
import os, shlex, shutil, subprocess, sys, tempfile
from pathlib import Path
from unittest.mock import patch

R = Path(__file__).resolve().parents[1]
TOOL = R / 'graphics/nvn/tools/romfs_list.py'
sys.path.insert(0, str(TOOL.parent))
import romfs_list

bad = 0
def ck(ok, msg):
    global bad
    print(('通 ' if ok else '不通 ') + msg); bad += 0 if ok else 1


def romfs_index_cmd(t):   # 同 tests/romfs_img_test.py
    dotnet = shutil.which('dotnet') or (os.path.join(os.environ['DOTNET_ROOT'], 'dotnet') if os.environ.get('DOTNET_ROOT') else None)
    if not dotnet: return None, '没有 dotnet'
    out = os.path.join(t, 'ri')
    r = subprocess.run([dotnet, 'build', str(R / 'services/romfs_index'), '-c', 'Release', '-o', out], capture_output=True, text=True)
    if r.returncode: return None, '编 services/romfs_index 失败：' + r.stdout[-300:]
    return f'{shlex.quote(dotnet)} {shlex.quote(os.path.join(out, "romfs_index.dll"))}', ''


def cli(*a):
    return subprocess.run([sys.executable, str(TOOL), *a], capture_output=True)


def shape(top):
    """夹具目录的期望（os.walk 独立算）：{相对路径: ('d', 0) | ('f', 大小)}、逐层 {目录相对路径: (子目录集合, 文件集合)}"""
    ents, layers = {}, {}
    for d, ds, fs in os.walk(top):
        rel = os.path.relpath(d, top).replace(os.sep, '/'); rel = '' if rel == '.' else rel
        layers[rel] = (set(ds), set(fs))
        for x in ds: ents[(rel + '/' + x).lstrip('/')] = ('d', 0)
        for x in fs: ents[(rel + '/' + x).lstrip('/')] = ('f', os.path.getsize(os.path.join(d, x)))
    return ents, layers


def got_shape(tree):
    ents = {e.rel: ('d', 0) if e.walkdir else ('f', e.lstat.st_size) for e in tree.entries}
    layers = {}
    for d, ds, fs in tree.walk():
        rel = os.path.relpath(d, tree.top).replace(os.sep, '/'); rel = '' if rel == '.' else rel
        layers[rel] = (set(ds), set(fs))
    return ents, layers


with tempfile.TemporaryDirectory(prefix='romfs list img ') as t:
    T = Path(t)
    cmd, why = romfs_index_cmd(t)
    if not cmd:
        print(f'跳过：{why}'); sys.exit(0)
    os.environ['S2A_ROMFS_WALK'] = str(T / 'walk')
    files = {'a/b c/big.bin': os.urandom(300000), 'a/小.txt': '你好'.encode(), 'empty': b'', 'z/y/x/deep.NRO': bytes(16) + b'NRO0' + bytes(8),
             'Layout/ui.arc': b'SARC' + os.urandom(64), 'a/b c/second': b'2' * 10, 'Data.pak': b'PAK' * 3}
    root = T / 't0100@现行'; rd = root / 'romfs'
    for k, v in files.items():
        (rd / k).parent.mkdir(parents=True, exist_ok=True); (rd / k).write_bytes(v)
    want_ents, want_layers = shape(rd)
    img = root / 'romfs.std'; img.write_bytes(b'')
    r = subprocess.run(shlex.split(cmd) + ['--std', str(rd), '-', str(img), '0'], capture_output=True, text=True)
    ck(r.returncode == 0, f'夹具建成镜像（rc={r.returncode} {r.stderr[-200:]}）')

    # ④ 目录在：照旧读目录，镜像不看
    t_dir = romfs_list.scan(rd)
    ck(t_dir.image is None and romfs_list.image_of(rd) is None, '④ 目录在 → 读目录（旁边的 .std 不看）')
    ck(got_shape(t_dir) == (want_ents, want_layers), '④ 目录盘点 = os.walk')
    dir_heads = {e.rel: (e.size, e.head) for e in romfs_list.heads(rd, listing=None).files()}
    dir_cli = (cli('has-ext', str(rd), '.nro').returncode, cli('has-ext', str(rd), '.utoc').returncode, cli('sizes', str(rd), str(T / 's_dir')).returncode)

    # 拿走目录，只剩镜像
    shutil.move(str(rd), str(T / 'away'))
    ck(romfs_list.image_of(rd) == str(img), '目录不在、旁边有 .std → image_of 给镜像')
    t_img = romfs_list.scan(rd)
    ck(t_img.image is not None, '镜像盘点')
    ck(got_shape(t_img) == (want_ents, want_layers), f'① 镜像盘点的条目（路径 / 类型 / 大小）与逐层 walk = 目录')
    ck(set(romfs_list.listdir(rd)) == want_layers[''][0] | want_layers[''][1] and set(romfs_list.listdir(rd / 'a')) == want_layers['a'][0] | want_layers['a'][1],
       '① listdir（根、子目录）同集合')
    try: romfs_list.listdir(rd / 'nope'); ck(False, '① listdir 不在的子目录应报 FileNotFoundError')
    except FileNotFoundError: ck(True, '① listdir 不在的子目录 → FileNotFoundError')
    ck(list(romfs_list.walk(rd)) == list(t_img.walk()), '① walk() 与 scan().walk() 一致')

    # ② 读头 / 读全文
    hd = {e.rel: (e.size, e.head) for e in romfs_list.heads(rd, listing=None).files()}
    ck(hd == dir_heads == {k: (len(v), v[:32]) for k, v in files.items()}, '② heads（大小、前 32 字节）= 目录 = 夹具')
    ck(all(e.open().read() == files[e.rel] for e in t_img.files()), '② e.open() 读全文 = 夹具')

    # ③ 命令行
    img_cli = (cli('has-ext', str(rd), '.nro').returncode, cli('has-ext', str(rd), '.utoc').returncode, cli('sizes', str(rd), str(T / 's_img')).returncode)
    ck(img_cli == dir_cli == (0, 1, 0), f'③ has-ext 同真假、sizes 成功（目录 {dir_cli} / 镜像 {img_cli}）')
    ck(sorted((T / 's_img').read_text().splitlines()) == sorted((T / 's_dir').read_text().splitlines()), '③ sizes 同集合')
    f0 = cli('files0', str(rd))
    ck(f0.returncode == 1 and not f0.stdout and '镜像' in f0.stderr.decode(), '③ files0 镜像下报红退 1、不出路径')

    # ⑤ 清单
    t1 = romfs_list.heads(rd)
    ck(any((T / 'walk').glob(f'*-{t1.identity}.json')), '⑤ 镜像盘点落清单')
    with patch.object(romfs_list, '_read_heads_image', side_effect=AssertionError('不该读盘')):
        t2 = romfs_list.heads(rd)
    ck({e.rel: (e.size, e.head) for e in t2.files()} == hd, '⑤ 同镜像再来从清单取（不读盘）')
    st = os.stat(img); os.utime(img, ns=(st.st_atime_ns, st.st_mtime_ns + 1_000_000_000))
    ck(romfs_list.scan(rd).identity != t1.identity, '⑤ 镜像修改时间变 → 身份变')

    # ④ 目录、镜像都没有
    img.unlink()
    ck(romfs_list.scan(rd).errors.get('') is not None and romfs_list.image_of(rd) is None, '④ 都没有 → 同目录盘点记「打不开」')
print(f'romfs_list 镜像盘点单测：{"全通" if not bad else f"{bad} 项不通"}'); sys.exit(1 if bad else 0)
