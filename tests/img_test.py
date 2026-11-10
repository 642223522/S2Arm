#!/usr/bin/env python3
"""单一 IMG v1（pack/img.py + services/romfs_index --std）单测：python3 tests/img_test.py。期望值来自夹具本身，不跑被测实现推：
  ① 头：魔数 / 格式号 1 / 游戏号大写 / 资源包号 / 文件长 = 实际长度
  ② 其余文件：按路径 O(1) 查得到、起点页对齐、字节与源文件相同；查不在的路径 → None；路径重复 → 报红
  ③ RomFS 段：按 Switch 标准 RomFS 公开格式独立解析（本文件 std_romfs，不用 LibHac）——文件集合与夹具目录相同、逐文件字节相同
     （要 dotnet 编 services/romfs_index；没有 dotnet 时 ③ 跳过并打印原因，①② 照测）"""
import os, shlex, shutil, struct, subprocess, sys, tempfile
from pathlib import Path

R = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(R / 'pack'))
import img

bad = 0
def ck(ok, msg):
    global bad
    print(('通 ' if ok else '不通 ') + msg); bad += 0 if ok else 1


def std_romfs(path, base):
    """按公开格式读标准 RomFS → {相对路径: 字节}"""
    f = open(path, 'rb')
    def rd(off, n): f.seek(base + off); return f.read(n)
    hs, dho, dhs, dmo, dms, fho, fhs, fmo, fms, data = struct.unpack('<10Q', rd(0, 0x50))
    dmeta, fmeta, out = rd(dmo, dms), rd(fmo, fms), {}
    def walk(off, path):
        _, _, child, first, _, nl = struct.unpack_from('<6I', dmeta, off)
        name = dmeta[off + 24: off + 24 + nl].decode(); p = path + ('/' + name if name else '')
        fo = first
        while fo != 0xFFFFFFFF:
            _, sib, foff, size, _, fnl = struct.unpack_from('<IIQQII', fmeta, fo)
            out[(p + '/' + fmeta[fo + 32: fo + 32 + fnl].decode()).lstrip('/')] = rd(data + foff, size); fo = sib
        c = child
        while c != 0xFFFFFFFF: walk(c, p); c = struct.unpack_from('<6I', dmeta, c)[1]
    walk(0, ''); return out


def romfs_index_cmd(t):
    dotnet = shutil.which('dotnet') or (os.path.join(os.environ['DOTNET_ROOT'], 'dotnet') if os.environ.get('DOTNET_ROOT') else None)
    if not dotnet: return None, '没有 dotnet'
    out = os.path.join(t, 'ri')
    r = subprocess.run([dotnet, 'build', str(R / 'services/romfs_index'), '-c', 'Release', '-o', out], capture_output=True, text=True)
    if r.returncode: return None, '编 services/romfs_index 失败：' + r.stdout[-300:]
    return f'{shlex.quote(dotnet)} {shlex.quote(os.path.join(out, "romfs_index.dll"))}', ''


with tempfile.TemporaryDirectory(prefix='img test ') as t:
    T = Path(t); (T / 'romfs/a/b c').mkdir(parents=True); (T / 'o').mkdir()
    files = {'a/b c/big.bin': os.urandom(100000), 'a/小.txt': b'hi', 'empty': b''}
    for k, v in files.items(): (T / 'romfs' / k).write_bytes(v)
    others = {'exefs/main.npdm': os.urandom(5000), 'ctl/control.nacp': b'NACP'}
    src = []
    for k, v in others.items(): p = T / 'o' / k.replace('/', '_'); p.write_bytes(v); src.append((k, str(p)))
    cmd, why = romfs_index_cmd(t)
    out = str(T / 'g.img')
    img.build(str(T / 'romfs') if cmd else None, src, out, '0100abcd00000000', 'abc123', cmd, say=lambda *_: None)
    h = img.header(out)
    ck((h['format'], h['gid'], h['pack_id'], h['total']) == (1, '0100ABCD00000000', 'abc123', os.path.getsize(out)), f'① 头 {h}')
    for k, v in others.items():
        off, size = img.find(out, k); b = open(out, 'rb'); b.seek(off)
        ck(off % img.PAGE == 0 and b.read(size) == v, f'② {k} 页对齐、字节相同（偏移 {off}）')
    ck(img.find(out, 'nope') is None, '② 查不在的路径 → None')
    try: img.toc_bytes([('x', 0, 1), ('x', 1, 1)]); ck(False, '② 路径重复应报红')
    except img.Red: ck(True, '② 路径重复报红')
    if cmd:
        got = std_romfs(out, h['romfs'][0])
        ck(got == files, f'③ 标准 RomFS 段：独立解析 {len(got)} 个文件，集合与字节同夹具')
    else:
        print(f'跳过 ③：{why}')
print(f'img 单测：{"全通" if not bad else f"{bad} 项不通"}'); sys.exit(1 if bad else 0)
