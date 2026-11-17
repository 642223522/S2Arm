#!/usr/bin/env python3
"""pack/orch/stages.py romfsidx_key（RomFS 索引阶段键）提速前后键逐字节相同（python3 tests/romfsidx_key_test.py；tests/orch_stages_test.sh 调）。
提速：原先按 walk 逐个文件 stat 取大小（4.2 万个文件 3.4–4 秒），改成一次盘点（romfs_list.scan，每个条目 lstat 一次）的大小。
期望 = 改前的算法原样抄在本文件（REF，不跑被测实现推）：同 walk 顺序（目录名排序、文件名排序）、每行「相对路径\\t大小\\n」、取前 16 位、拼索引写法对象号再摘要；
夹具：随机目录树 300+ 个文件（多层、空目录、空文件、名字带空格 / 中文 / 大小写混排），目录形态与镜像形态（romfs.std，services/romfs_index --std 建）各算一次，
外加界面布局覆盖层（ui_overlay/romfs，替换两个文件、大小不同）一次。没有 dotnet 时镜像那项跳过"""
import hashlib, os, random, shlex, shutil, subprocess, sys, tempfile
from pathlib import Path

R = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(R))
os.environ['S2A_ROMFS_WALK'] = 'off'
from pack.orch import stages   # noqa: E402
sys.path.insert(0, str(R / 'graphics/nvn/tools'))
import romfs_list   # noqa: E402

bad = 0
def ck(ok, msg):
    global bad
    print(('通 ' if ok else '不通 ') + msg); bad += 0 if ok else 1


def REF(current):
    """改前的 romfsidx_key（逐个文件取大小），原样"""
    oids = stages.romfs_writer_oids()
    kt = stages.digest('\n'.join(oids) + '\n')
    h = hashlib.sha256()
    base = Path(current) / 'romfs'
    for directory, dirs, files in romfs_list.walk(base):
        dirs.sort()
        for name in sorted(files):
            p = Path(directory) / name
            h.update(f'{p.relative_to(base).as_posix()}\t{romfs_list.file_size(p)}\n'.encode())
    over = stages.overlay_sizes(current)
    if over:
        h.update(''.join(f'ui_overlay\t{n}\t{over[n]}\n' for n in sorted(over)).encode())
    return stages.digest(f'{h.hexdigest()[:16]} {kt}')


rng = random.Random(1116)
NAMES = ['a', 'B', 'c d', '资源', 'Zz', 'x.bin', 'Layout', 'ui', 'e_f', '0']
with tempfile.TemporaryDirectory(prefix='romfsidx key ') as t:
    T = Path(t)
    D = T / 'd'; rf = D / 'romfs'
    n = 0
    while n < 320:
        depth = rng.randint(0, 4)
        rel = Path(*[rng.choice(NAMES) + str(rng.randint(0, 3)) for _ in range(depth)], f'f{n}_{rng.choice(NAMES)}.dat')
        p = rf / rel
        if p.parent.is_file() or p.exists():
            continue
        try:
            p.parent.mkdir(parents=True, exist_ok=True)
        except (FileExistsError, NotADirectoryError):
            continue
        p.write_bytes(os.urandom(rng.choice([0, 1, 17, 4096, rng.randint(0, 70000)])))
        n += 1
    (rf / 'empty_dir' / 'deeper').mkdir(parents=True)
    ck(stages.romfsidx_key(D) == REF(D), f'目录形态 {n} 个文件：改后键 = 改前键（{REF(D)}）')
    # 覆盖层：替换两个已有文件、大小不同
    picks = sorted(p for p in rf.rglob('*') if p.is_file())[:2]
    for p in picks:
        q = D / 'ui_overlay' / 'romfs' / p.relative_to(rf); q.parent.mkdir(parents=True, exist_ok=True); q.write_bytes(b'O' * (p.stat().st_size + 5))
    ck(stages.romfsidx_key(D) == REF(D), '目录形态 + 界面布局覆盖层：改后键 = 改前键')
    shutil.rmtree(D / 'ui_overlay')
    # 镜像形态
    dotnet = shutil.which('dotnet') or (os.path.join(os.environ['DOTNET_ROOT'], 'dotnet') if os.environ.get('DOTNET_ROOT') else None)
    if not dotnet:
        print('跳过 镜像形态：没有 dotnet')
    else:
        out = T / 'ri'
        b = subprocess.run([dotnet, 'build', str(R / 'services/romfs_index'), '-c', 'Release', '-o', str(out)], capture_output=True, text=True)
        I = T / 'i'; I.mkdir(); (I / 'romfs.std').write_bytes(b'')
        r = subprocess.run([dotnet, str(out / 'romfs_index.dll'), '--std', str(rf), '-', str(I / 'romfs.std'), '0'], capture_output=True, text=True) if not b.returncode else b
        ck(r.returncode == 0 and romfs_list.image_of(I / 'romfs') is not None, '夹具建成镜像')
        if r.returncode == 0:
            ck(stages.romfsidx_key(I) == REF(I), '镜像形态：改后键 = 改前键')
            # 两形态的键也相同（键只看相对路径 + 大小；空目录不进键）
            ck(stages.romfsidx_key(I) == stages.romfsidx_key(D), '镜像形态与目录形态键相同')

print('romfsidx_key 单测全过' if not bad else f'有 {bad} 项不通')
sys.exit(1 if bad else 0)
