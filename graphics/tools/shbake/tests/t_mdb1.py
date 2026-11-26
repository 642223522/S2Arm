#!/usr/bin/env python3
# Media.Vision MVGL（MDB1）归档与 NXFS 着色器容器（translator/mdb1.py、nxsh_extract.py scan_nxfs / mdb1_visit）。期望按格式手写，不跑被测实现：
#   ① 64 位归档：三个数据项——原样存、LZ4 块压缩、没被任何树项指到（名字给 None），逐字节解回原文，名字 = 名项的 name.ext
#   ② 不是 MDB1：ValueError
#   ③ 32 位归档的压缩条目（doboz，未实现）：不拿 LZ4 错解，这一条给空内容；同归档里原样存的条目照常解
#   ④ NXFS 容器：控制段在 +0x40、与机器码之间隔 0x80 字节（相邻扫描够不着），按头取出一支片元；键 = sha256(控制段（第 2 代：
#      [0x790, 0x798) 与 [0x7d0, 0x7e8) 置零）‖ 机器码)[:16] 手算；头对不上（控制段偏移越界）不认、不配假键
#   ⑤ 端到端：MDB1 归档的一个条目是 ④ 的 NXFS 容器，mdb1_visit 出同一个键、来源 <归档>//<条目名>@nxfs0x40
import collections, hashlib, os, struct, sys, unittest
import lz4.block
H = os.path.dirname(os.path.dirname(os.path.abspath(__file__))); sys.path.insert(0, H)
R = os.path.normpath(os.path.join(H, '..', '..', '..')); sys.path.insert(0, os.path.join(R, 'translator'))
import mdb1, nxsh_extract as X


class Buf:   # mdb1.Archive 要的 seek / read
    def __init__(self, b): self.b, self.p = b, 0
    def seek(self, p): self.p = p
    def read(self, n): r = self.b[self.p:self.p + n]; self.p += len(r); return r


def mdb1_64(items, tree):
    """items = [(名字, 扩展名, 原文, 压不压)]；tree = 树项按序的数据号。64 位：头 0x20、树项 16B、名项 128B、数据项 16B"""
    tn, nn, dn = len(tree), len(tree), len(items)
    names = b''.join(ex.encode().ljust(4, b'\0') + nm.encode().ljust(0x7c, b'\0') for nm, ex, _, _ in [items[d] for d in tree])
    trees = b''.join(struct.pack('<4I', 0, d, 0, 0) for d in tree)
    data, recs = b'', b''
    for _, _, raw, z in items:
        st = lz4.block.compress(raw, store_size=False) if z else raw
        recs += struct.pack('<QII', len(data), len(raw), len(st)); data += st
    start = 0x14 + len(trees) + len(names) + len(recs)
    hdr = b'MDB1' + struct.pack('<3I', tn, nn, dn) + struct.pack('<QQ', start, start + len(data))
    return hdr[:0x14] + trees + names + recs + data, hdr


def mdb1_32(items):
    """32 位：头 0x14、树项 8B、名项 0x40B、数据项 12B；items = [(名字, 扩展名, 存的字节, 原长)]"""
    n = len(items)
    trees = b''.join(struct.pack('<4H', 0xffff if d == 0 else 0, d, 0, 0) for d in range(n))   # 树根比较位 0xFFFF（同真件；+0x14 不为 0 才认 32 位）
    names = b''.join(ex.encode().ljust(4, b'\0') + nm.encode().ljust(0x3c, b'\0') for nm, ex, _, _ in items)
    data, recs = b'', b''
    for _, _, st, ln in items: recs += struct.pack('<3I', len(data), ln, len(st)); data += st
    start = 0x14 + len(trees) + len(names) + len(recs)
    return b'MDB1' + struct.pack('<2HI', n, n, n) + struct.pack('<2I', start, start + len(data)) + trees + names + recs + data


def nxfs_shader():
    """一支片元：控制段 0x800（自身长度 +0x20、机器码长 +0x704、两段易变字段非零），机器码 0x80（头 78563412、SPH +0x30 类型 5）"""
    code = bytearray(0x80); code[:4] = bytes.fromhex('78563412'); struct.pack_into('<I', code, 0x30, 5 << 10)
    ctl = bytearray(0x800); ctl[:8] = bytes.fromhex('3412769801000000')
    struct.pack_into('<I', ctl, 0x20, 0x800); struct.pack_into('<I', ctl, 0x700, 0x80); struct.pack_into('<I', ctl, 0x704, 0x80)
    ctl[0x790:0x798] = b'\x11' * 8; ctl[0x7d0:0x7e8] = b'\x22' * 0x18
    co, do = 0x40, 0x40 + 0x800 + 0x80
    blob = bytearray(do + len(code)); blob[:4] = b'NXFS'
    struct.pack_into('<I', blob, 4, len(blob)); struct.pack_into('<I', blob, 0x0c, co); struct.pack_into('<I', blob, 0x14, do); struct.pack_into('<I', blob, 0x18, len(code))
    blob[co:co + 0x800] = ctl; blob[do:] = code
    z = bytearray(ctl); z[0x790:0x798] = bytes(8); z[0x7d0:0x7e8] = bytes(0x18)   # 第 2 代键：两段置零（照规格手写）
    return bytes(blob), hashlib.sha256(bytes(z) + bytes(code)).hexdigest()[:16]


class T(unittest.TestCase):
    def test_1_archive64(self):
        a, b, c = b'raw entry bytes', b'compressible ' * 40, b'orphan'
        arc, _ = mdb1_64([('alpha', 'bin', a, False), ('beta', 'dat', b, True), ('gamma', 'x', c, False)], [0, 1])
        got = list(mdb1.Archive(Buf(arc)).entries())
        self.assertEqual(got, [(0, 'alpha.bin', a), (1, 'beta.dat', b), (2, None, c)])

    def test_2_not_mdb1(self):
        with self.assertRaises(ValueError): mdb1.Archive(Buf(b'MDB0' + bytes(0x40)))

    def test_3_archive32_doboz(self):
        arc = mdb1_32([('plain', 'bin', b'plain data', 10), ('packed', 'bin', b'\x01\x02\x03', 50)])
        self.assertEqual(list(mdb1.Archive(Buf(arc)).entries()), [(0, 'plain.bin', b'plain data'), (1, 'packed.bin', b'')])

    def test_4_nxfs(self):
        blob, key = nxfs_shader()
        rows, blobs, stat = [], {}, collections.Counter()
        self.assertEqual(X.scan_nxfs('p', blob, rows, blobs, stat), {0x40})
        self.assertEqual(rows, [(key, 'ps', 'p@nxfs0x40', 0)])
        bad = bytearray(blob); struct.pack_into('<I', bad, 0x0c, len(bad))   # 控制段偏移越界
        rows2 = []; self.assertEqual(X.scan_nxfs('p', bytes(bad), rows2, {}, collections.Counter()), set()); self.assertEqual(rows2, [])

    def test_5_end_to_end(self):
        blob, key = nxfs_shader()
        arc, _ = mdb1_64([('shader', 'nxfs', blob, True)], [0])
        rows, blobs, stat = [], {}, collections.Counter()
        X.mdb1_visit('app_0.mvgl', mdb1.Archive(Buf(arc)), rows, blobs, stat)
        self.assertIn((key, 'ps', 'app_0.mvgl//shader.nxfs@nxfs0x40', 0), rows)
        self.assertEqual(stat['MDB1 归档'], 1)


if __name__ == '__main__':
    unittest.main()
