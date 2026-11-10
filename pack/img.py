#!/usr/bin/env python3
"""单一 IMG v1（v0.3.0）：一款游戏的原始资源交成一个文件——出包产出它、游戏库存它、推送 / 导出传它、iPhone 上放它。
只装游戏原始资源（RomFS、exefs、ctl、系统数据…），字节永远不变；直连着色器库（派生产物）与界面覆盖层不进，放在 IMG 旁边。

布局（小端，PAGE = 16 KB）：
  [0, PAGE)        头：0 "S2AIMG01" | 8 u32 格式号 | 12 u32 0 | 16 16 字节游戏号（ASCII 十六进制）| 32 64 字节资源包号（ASCII，可空）
                       | 96 u64 RomFS 段偏移 | 104 u64 RomFS 段长 | 112 u64 目录表偏移 | 120 u64 目录表长 | 128 u64 整个文件长 | 其余 0
  RomFS 段         Switch 标准 RomFS（services/romfs_index --std，LibHac RomFsBuilder；与 hactool / nxdumptool 的 romfs.bin 同一种），起点页对齐
  其余文件段       每个文件起点页对齐（读时一次 pread / mmap 零拷贝）
  目录表           u32 槽数（2 的幂）| u32 条目数 | 槽数 × {u64 路径 FNV-1a 64（0 = 空槽）, u64 偏移, u64 长度, u32 路径偏移, u32 路径长} | 路径区（UTF-8）
                   开放寻址线性探测，按路径 O(1) 查；路径用 / 分隔、相对资源包根（如 exefs/main.npdm）
                   有 RomFS 段时目录表另有一条 romfs.list：RomFS 里全部文件的相对路径（UTF-8，按字节序，一行一个）——服务层叠界面覆盖层时
                   按它重建虚拟 RomFS（services RomFsIndex.OpenImg），不依赖 LibHac 的目录遍历
格式号只在字节布局真变时加一；新壳必须保留读旧号的代码（坑记录与发版步骤）。

用法：img.py build <RomFS 目录> <其余文件清单 tsv：相对路径\\t源文件> <输出 .img> --gid <游戏号> [--pack-id <资源包号>] [--romfs-index <romfs_index 命令>]
      img.py ls <img>   列目录表（单测 / 诊断）"""
import argparse, os, shlex, struct, subprocess, sys

MAGIC, FORMAT, PAGE = b'S2AIMG01', 1, 16384
HDR = struct.Struct('<8sII16s64s5Q')
SLOT = struct.Struct('<QQQII')


class Red(Exception):
    pass


def fnv(path):
    h = 1469598103934665603
    for b in path.encode('utf-8'):
        h = ((h ^ b) * 1099511628211) & 0xFFFFFFFFFFFFFFFF
    return h or 1


def up(n):
    return (n + PAGE - 1) // PAGE * PAGE


def toc_bytes(entries):
    """entries：[(路径, 偏移, 长度)] → 目录表字节"""
    slots = 1
    while slots < max(1, len(entries)) * 2: slots <<= 1
    table = [None] * slots; paths = bytearray()
    for path, off, size in entries:
        h = fnv(path); k = h & (slots - 1)
        while table[k] is not None:
            if table[k][0] == h and table[k][5] == path: raise Red(f'目录表路径重复：{path}')
            k = (k + 1) & (slots - 1)
        p = path.encode('utf-8'); table[k] = (h, off, size, len(paths), len(p), path); paths += p
    out = bytearray(struct.pack('<II', slots, len(entries)))
    for t in table: out += SLOT.pack(*t[:5]) if t else bytes(SLOT.size)
    return bytes(out + paths)


def build(romfs_dir, others, out, gid, pack_id='', romfs_index=None, say=print):
    """romfs_dir：RomFS 目录（None = 没有 RomFS）；others：[(相对路径, 源文件)]；→ 输出路径"""
    if len(gid) != 16 or any(c not in '0123456789ABCDEFabcdef' for c in gid): raise Red(f'游戏号不对：{gid!r}')
    part = out + '.part'
    try:
        with open(part, 'wb') as f: f.truncate(PAGE)
        romfs_off = romfs_len = 0
        if romfs_dir:
            if not romfs_index: raise Red('写 RomFS 段要 romfs_index 命令（services/romfs_index）')
            romfs_off = PAGE
            r = subprocess.run([*shlex.split(romfs_index), '--std', romfs_dir, '-', part, str(romfs_off)], capture_output=True, text=True)
            if r.returncode: raise Red(f'写标准 RomFS 段失败：{(r.stderr or r.stdout).strip()[-300:]}')
            romfs_len = int(r.stdout.strip().splitlines()[-1])
        pos = up(romfs_off + romfs_len) if romfs_dir else PAGE
        entries = []
        if romfs_dir:   # romfs.list：同 romfs_index 的文件集合（跳过 macOS 垃圾 .DS_Store / ._*，同 RomFsIndex.IsHostJunk），按字节序
            names = sorted((os.path.relpath(os.path.join(d, n), romfs_dir).replace(os.sep, '/') for d, _, ns in os.walk(romfs_dir) for n in ns
                            if n != '.DS_Store' and not n.startswith('._')), key=lambda x: x.encode('utf-8'))
            lst = out + '.romfs.list'; open(lst, 'w', encoding='utf-8', newline='\n').write(''.join(n + '\n' for n in names)); others = [*others, ('romfs.list', lst)]
        with open(part, 'r+b') as f:
            for rel, src in sorted(others):
                size = os.path.getsize(src); f.seek(pos)
                with open(src, 'rb') as s:
                    while b := s.read(1 << 22): f.write(b)
                entries.append((rel, pos, size)); pos = up(pos + size)
            toc = toc_bytes(entries); toc_off = pos; f.seek(toc_off); f.write(toc)
            total = toc_off + len(toc)
            f.seek(0); f.write(HDR.pack(MAGIC, FORMAT, 0, gid.upper().encode('ascii'), pack_id.encode('ascii')[:64], romfs_off, romfs_len, toc_off, len(toc), total))
        os.replace(part, out)
        if romfs_dir: os.unlink(out + '.romfs.list')
    except BaseException:
        try: os.unlink(part)
        except OSError: pass
        raise
    say(f'IMG v1：{out}（{total / 1e9:.2f} GB；RomFS {romfs_len / 1e9:.2f} GB，其余 {len(entries)} 个文件）')
    return out


def header(path):
    with open(path, 'rb') as f: b = f.read(HDR.size)
    m, fmt, _, gid, pid, ro, rl, to, tl, total = HDR.unpack(b)
    if m != MAGIC: raise Red('不是 IMG')
    return dict(format=fmt, gid=gid.decode('ascii'), pack_id=pid.rstrip(b'\0').decode('ascii'), romfs=(ro, rl), toc=(to, tl), total=total)


def entries(path):
    h = header(path)
    with open(path, 'rb') as f:
        f.seek(h['toc'][0]); t = f.read(h['toc'][1])
    slots, n = struct.unpack_from('<II', t, 0); base = 8 + slots * SLOT.size; out = []
    for i in range(slots):
        hh, off, size, po, pl = SLOT.unpack_from(t, 8 + i * SLOT.size)
        if hh: out.append((t[base + po: base + po + pl].decode('utf-8'), off, size))
    return sorted(out)


def find(path, rel):
    """按路径 O(1) 查目录表 → (偏移, 长度) 或 None（与运行时读法同一算法）"""
    h = header(path)
    with open(path, 'rb') as f:
        f.seek(h['toc'][0]); t = f.read(h['toc'][1])
    slots, _ = struct.unpack_from('<II', t, 0); base = 8 + slots * SLOT.size; want = fnv(rel); k = want & (slots - 1)
    while True:
        hh, off, size, po, pl = SLOT.unpack_from(t, 8 + k * SLOT.size)
        if not hh: return None
        if hh == want and t[base + po: base + po + pl].decode('utf-8') == rel: return off, size
        k = (k + 1) & (slots - 1)


def main(argv=None):
    ap = argparse.ArgumentParser(); sp = ap.add_subparsers(dest='cmd', required=True)
    b = sp.add_parser('build'); b.add_argument('romfs'); b.add_argument('others'); b.add_argument('out'); b.add_argument('--gid', required=True)
    b.add_argument('--pack-id', default=''); b.add_argument('--romfs-index')
    l = sp.add_parser('ls'); l.add_argument('img')
    a = ap.parse_args(argv)
    try:
        if a.cmd == 'build':
            others = [tuple(l.rstrip('\n').split('\t', 1)) for l in open(a.others, encoding='utf-8') if '\t' in l]
            build(None if a.romfs == '-' else a.romfs, others, a.out, a.gid, a.pack_id, a.romfs_index)
        else:
            print(header(a.img))
            for e in entries(a.img): print(*e, sep='\t')
    except (Red, OSError) as e:
        print(f'【红】{e}'); return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
