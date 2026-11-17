#!/usr/bin/env python3
"""标准 RomFS 镜像读取（pack/romfs_img.py）单测：python3 tests/romfs_img_test.py。期望值来自夹具目录本身，不跑被测实现推：
  ① 用 services/romfs_index --std（LibHac RomFsBuilder，出 IMG 那一份）把夹具目录建成镜像；列表 = 夹具里的文件（路径、长度），按路径 UTF-8 字节序
  ② 每个文件 read 的字节与夹具逐字节相同；read_range / head / open（流式 seek + read）取到的与夹具同一段相同；越界截短、读空
  ③ dirs = 含有文件的各级目录（根是 ""；出镜像只加文件，空目录不进镜像）；查不在的路径 → FileNotFoundError；不是 RomFS → RomfsError
  ④ IMG 里的段（pack/img.py build）：RomfsImage.in_img 读到的与独立镜像同样；img.std_files 的返回与 files() 相同（解析只留一份）
  ⑤ 命令行 ls / cat 的输出与夹具一致
（要 dotnet 编 services/romfs_index；没有 dotnet 时整份跳过并打印原因，退出 0）"""
import os, shlex, shutil, subprocess, sys, tempfile
from pathlib import Path

R = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(R / 'pack'))
import img
import romfs_img
from romfs_img import RomfsImage, RomfsError

bad = 0
def ck(ok, msg):
    global bad
    print(('通 ' if ok else '不通 ') + msg); bad += 0 if ok else 1


def romfs_index_cmd(t):   # 同 tests/img_test.py
    dotnet = shutil.which('dotnet') or (os.path.join(os.environ['DOTNET_ROOT'], 'dotnet') if os.environ.get('DOTNET_ROOT') else None)
    if not dotnet: return None, '没有 dotnet'
    out = os.path.join(t, 'ri')
    r = subprocess.run([dotnet, 'build', str(R / 'services/romfs_index'), '-c', 'Release', '-o', out], capture_output=True, text=True)
    if r.returncode: return None, '编 services/romfs_index 失败：' + r.stdout[-300:]
    return f'{shlex.quote(dotnet)} {shlex.quote(os.path.join(out, "romfs_index.dll"))}', ''


with tempfile.TemporaryDirectory(prefix='romfs img test ') as t:
    T = Path(t)
    cmd, why = romfs_index_cmd(t)
    if not cmd:
        print(f'跳过：{why}'); sys.exit(0)
    files = {'a/b c/big.bin': os.urandom(300000), 'a/小.txt': '你好'.encode(), 'empty': b'', 'z/y/x/deep.dat': os.urandom(4097),
             'Layout/ui.arc': b'SARC' + os.urandom(64), 'a/b c/second': b'2' * 10}
    rd = T / 'romfs'
    for k, v in files.items():
        (rd / k).parent.mkdir(parents=True, exist_ok=True); (rd / k).write_bytes(v)
    (rd / 'empty_dir/inner').mkdir(parents=True)
    std = T / 'romfs.std'
    std.write_bytes(b'')   # 写入方按已有文件打开（同 img.build 先建好输出文件）
    r = subprocess.run(shlex.split(cmd) + ['--std', str(rd), '-', str(std), '0'], capture_output=True, text=True)   # 用法同 services/romfs_index.sh：--std <目录> <清单或 -> <输出> <偏移>
    ck(r.returncode == 0 and std.is_file(), f'① 夹具目录建成标准 RomFS（rc={r.returncode} {r.stderr[-200:]}）')
    im = RomfsImage(std)
    want = sorted(((k, len(v)) for k, v in files.items()), key=lambda kv: kv[0].encode())
    got = [(rel, size) for rel, _, size in im.entries()]
    ck(got == want, f'① 列表（路径、长度、字节序）= 夹具（{len(got)} / {len(want)} 个）')
    ck(all(im.read(k) == v for k, v in files.items()), '② read 每个文件逐字节同夹具')
    big = files['a/b c/big.bin']
    ck(im.read_range('a/b c/big.bin', 12345, 5000) == big[12345:17345] and im.head('a/b c/big.bin') == big[:32], '② read_range / head 取到同一段')
    ck(im.read_range('a/小.txt', 4, 100) == files['a/小.txt'][4:] and im.read_range('a/小.txt', 99, 5) == b'', '② 越过文件尾截短 / 读空')
    with im.open('a/b c/big.bin') as f:
        parts = []
        while True:
            c = f.read(65536)
            if not c: break
            parts.append(c)
        f.seek(-10, os.SEEK_END); tail = f.read()
    ck(b''.join(parts) == big and tail == big[-10:], '② open 流式读全文与 seek 到尾 10 字节都同夹具')
    # 出镜像那一步（RomFsIndex WriteStandard）只加文件：空目录不进镜像，dirs = 含有文件的各级目录
    want_dirs = {''} | {'/'.join(k.split('/')[:i]) for k in files for i in range(1, k.count('/') + 1)}
    ck(set(im.dirs()) == want_dirs, f'③ dirs = 含有文件的各级目录（空目录不进镜像）：{sorted(set(im.dirs()) ^ want_dirs)}')
    try: im.read('nope'); ck(False, '③ 查不在的路径应报 FileNotFoundError')
    except FileNotFoundError: ck(True, '③ 查不在的路径 → FileNotFoundError')
    junk = T / 'junk'; junk.write_bytes(b'\0' * 200)
    try: RomfsImage(junk); ck(False, '③ 不是 RomFS 应报 RomfsError')
    except RomfsError: ck(True, '③ 不是 RomFS → RomfsError')
    # ④ IMG 里的段
    out = T / 'g.img'
    img.build(str(rd), [], str(out), '0100abcd00000000', 'pk', cmd, say=lambda *_: None)
    ii = RomfsImage.in_img(out)
    ck([(r_, s_) for r_, _, s_ in ii.entries()] == want and all(ii.read(k) == v for k, v in files.items()), '④ IMG 里的段：列表与内容同夹具')
    ck(img.std_files(str(out), img.header(str(out))['romfs'][0]) == ii.files(), '④ img.std_files 与 RomfsImage.files 相同')
    # ⑤ 命令行
    ls = subprocess.run([sys.executable, str(R / 'pack/romfs_img.py'), 'ls', str(std)], capture_output=True, text=True).stdout
    ck(ls == ''.join(f'{k}\t{n}\n' for k, n in want), '⑤ ls 输出 = 夹具清单')
    cat = subprocess.run([sys.executable, str(R / 'pack/romfs_img.py'), 'cat', str(out), 'z/y/x/deep.dat', '--img'], capture_output=True).stdout
    ck(cat == files['z/y/x/deep.dat'], '⑤ cat --img 输出 = 夹具文件')

print(f'romfs_img 单测：{"全通" if not bad else f"{bad} 项不通"}'); sys.exit(1 if bad else 0)
