"""BC → ASTC 预转包出包工具（pack/astc_pack.py + graphics/tools/astc/bc2astc.c）单测。
合成 BC1 / BC3 / BC7（外加该忽略的 RGBA8、BC4、Switch 2 BNTX、布局对不上的贴图），按 Tegra 块线性规则自己摆进一个最小 BNTX，
套上 SARC / Yaz0 / zstd，跑 build → 用本文件自己的包解析器读回：键集合、每项 ASTC 字节数与块数、排序与对齐都按期望核。
期望值都不经被测实现：平面是本文件先生成的线性字节，键由 hashlib 按 gal_astc.h 的口径现算，块线性摆放与各级起点由本文件按 GOB 规则另写一份；
纯红 BC1 块编出的 ASTC 应是常量色「空区块」（规范 C.2.23：FC FD FF×6 + RGBA16），由此核 BC 解压 → 编码的通道次序。
"""
import hashlib
import importlib.util
import os
import random
import shutil
import struct
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('astc_pack', ROOT / 'pack/astc_pack.py')
ap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ap)
TOOL_DIR = os.environ.get('S2A_ASTC_TOOL_DIR')   # 缺省 build/astc_tool；门禁外手跑可指到外置盘

GOB_W, GOB_H = 64, 8


def key(fam, w, h, plane):
    return hashlib.sha256(b's2a-bc-astc-v1' + struct.pack('<III', fam, w, h) + plane).digest()


def gob_y_at(hb, gy):
    while gy > 1 and hb <= (gy // 2) * GOB_H: gy //= 2
    return gy


def level_bytes(bpp, w, h, gy0, level):
    """(本级字节, 本级 GOB 高)：宽按 GOB（64 字节）取整、高按「gy 个 GOB」取整"""
    wb, hb = -(-max(1, w >> level) // 4), -(-max(1, h >> level) // 4)
    gy = gob_y_at(hb, gy0)
    return -(-wb * bpp // GOB_W) * GOB_W * (-(-hb // (GOB_H * gy)) * GOB_H * gy), gy


def swizzle_plane(lin, bpp, wb, hb, gy, out, base):
    """线性 BC 块 → Tegra 块线性：GOB = 64 字节 × 8 行，GOB 内 512 字节按 (x/32, y/2, x/16, y%2, x%16) 交错；gy 个 GOB 竖着成一组，组在行内从左到右"""
    gobs_w = -(-wb * bpp // GOB_W)
    for y in range(hb):
        for x in range(wb):
            xb = x * bpp
            gob_x, gob_y = xb // GOB_W, y // GOB_H
            group = (gob_y // gy) * gobs_w + gob_x
            inner = ((xb % 64) // 32) * 256 + ((y % 8) // 2) * 64 + ((xb % 32) // 16) * 32 + (y % 2) * 16 + (xb % 16)
            o = base + group * gy * 512 + (gob_y % gy) * 512 + inner
            out[o:o + bpp] = lin[(y * wb + x) * bpp:(y * wb + x + 1) * bpp]


def make_tex(fmt, fam, bpp, w, h, mips, layers, gob_log2, dim, gen, break_offsets=False):
    """一张贴图：各平面的线性字节（gen(level, layer, n) 生成）、块线性数据、各级起点"""
    gy0 = 1 << gob_log2
    sizes = [level_bytes(bpp, w, h, gy0, l) for l in range(mips)]
    offs, o = [], 0
    for sz, _ in sizes: offs.append(o); o += sz
    layer = o
    if layers > 1:
        g = gob_y_at(-(-h // 4), gy0) * 512
        layer = -(-o // g) * g
    data = bytearray(layer * layers)
    planes = {}
    for L in range(layers):
        for l in range(mips):
            lw, lh = max(1, w >> l), max(1, h >> l); wb, hb = -(-lw // 4), -(-lh // 4)
            lin = gen(l, L, wb * hb * bpp)
            planes[(l, L)] = (lw, lh, lin)
            swizzle_plane(lin, bpp, wb, hb, sizes[l][1], data, L * layer + offs[l])
    if break_offsets and mips > 1: offs[1] += 512
    return {'fmt': fmt, 'fam': fam, 'w': w, 'h': h, 'mips': mips, 'layers': layers, 'gob': gob_log2, 'dim': dim, 'data': bytes(data), 'offs': offs, 'planes': planes}


def bntx(textures, platform=b'NX  '):
    """最小 BNTX：头 0x40 | 贴图指针表 | 各 BRTI（0x90）| 各级起点表 | 数据（512 对齐）"""
    n = len(textures); p_table = 0x40; p_brti = p_table + 8 * n; p_mips = p_brti + 0x90 * n
    mip_tab = [p_mips + sum(8 * t['mips'] for t in textures[:i]) for i in range(n)]
    pos = -(-(p_mips + sum(8 * t['mips'] for t in textures)) // 512) * 512
    starts = []
    for t in textures: starts.append(pos); pos += -(-len(t['data']) // 512) * 512
    d = bytearray(pos)
    d[0:8] = b'BNTX\0\0\0\0'; struct.pack_into('<H', d, 0xc, 0xfeff); struct.pack_into('<I', d, 0x1c, pos); d[0x20:0x24] = platform
    struct.pack_into('<IQ', d, 0x24, n, p_table)
    for i, t in enumerate(textures):
        b = p_brti + 0x90 * i
        struct.pack_into('<Q', d, p_table + 8 * i, b)
        d[b:b + 4] = b'BRTI'
        struct.pack_into('<BBHHH9I', d, b + 0x10, 0, 2, 0, 0, t['mips'], 1, t['fmt'], 0, t['w'], t['h'], 1, t['layers'], t['gob'], 0)
        struct.pack_into('<IIII', d, b + 0x50, len(t['data']), 512, 0, t['dim'])
        struct.pack_into('<Q', d, b + 0x70, mip_tab[i])
        for l, o in enumerate(t['offs']): struct.pack_into('<Q', d, mip_tab[i] + 8 * l, starts[i] + o)
        d[starts[i]:starts[i] + len(t['data'])] = t['data']
    return bytes(d)


def sarc(members):
    names = b''.join(nm.encode() + b'\0' * (4 - len(nm) % 4) for nm, _ in members)
    hl, n = 0x14, len(members)
    sfat = b'SFAT' + struct.pack('<HHI', 0xc, n, 0x65)
    nofs, dofs, entries, blob = 0, 0, b'', b''
    for nm, data in members:
        entries += struct.pack('<IIII', 0, 0x01000000 | (nofs // 4), dofs, dofs + len(data))
        nofs += len(nm) + 4 - len(nm) % 4
        blob += data + b'\0' * ((-len(data)) % 16); dofs = len(blob)
    sfnt = b'SFNT' + struct.pack('<HH', 8, 0)
    head_len = hl + len(sfat) + len(entries) + len(sfnt) + len(names)
    doff = -(-head_len // 16) * 16
    head = b'SARC' + struct.pack('<HHIIHH', hl, 0xfeff, doff + len(blob), doff, 0x100, 0)
    out = head + sfat + entries + sfnt + names
    return out + b'\0' * (doff - len(out)) + blob


def yaz0_literal(d):
    """全字面量的 Yaz0（每组标志 0xFF + 8 字节原样）"""
    out = bytearray(b'Yaz0' + struct.pack('>I', len(d)) + b'\0' * 8)
    for i in range(0, len(d), 8): out += b'\xff' + d[i:i + 8]
    return bytes(out)


def parse_pack(path):
    b = Path(path).read_bytes()
    assert b[:8] == b'S2ABCAST', '魔数'
    ver, ent, count, ioff, total, bw, bh = struct.unpack_from('<IIQQQBB', b, 8)
    assert (ver, ent, bw, bh) == (1, 48, 4, 4) and total == len(b) and ioff + 48 * count == total, '头'
    rows = {}
    last = b''
    for i in range(count):
        k = b[ioff + 48 * i:ioff + 48 * i + 32]; off, n = struct.unpack_from('<QQ', b, ioff + 48 * i + 32)
        assert k > last and off >= 64 and off % 16 == 0 and n % 16 == 0 and off + n <= ioff, f'索引第 {i} 项'
        last = k; rows[k] = b[off:off + n]
    return rows


RED_BC1 = struct.pack('<HHI', 0xF800, 0xF800, 0)   # 两端点都是 565 纯红、索引全 0 → 16 个 (255,0,0,255)


class AstcPackTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix='astc_pack_test.'))
        rnd = random.Random(1115)
        rand = lambda l, L, n: bytes(rnd.getrandbits(8) for _ in range(n))
        def bc7(l, L, n):   # BC7 模式 6（首字节低 7 位 1000000）随机端点：合法块
            out = bytearray()
            for _ in range(n // 16): blk = bytearray(rnd.getrandbits(8) for _ in range(16)); blk[0] = 0x40; out += blk
            return bytes(out)
        cls.bc1 = make_tex(0x1a01, 1, 8, 64, 32, 3, 1, 2, 1, rand)              # 3 级、非方形、GOB 高 4
        cls.bc3 = make_tex(0x1c06, 3, 16, 24, 20, 2, 2, 1, 5, rand)             # 2 层数组、非 4 整倍尺寸、sRGB
        cls.bc7 = make_tex(0x2001, 7, 16, 8, 8, 1, 1, 0, 1, bc7)
        cls.red = make_tex(0x1a06, 1, 8, 8, 4, 1, 1, 0, 1, lambda l, L, n: RED_BC1 * (n // 8))
        cls.rgba = make_tex(0x0b01, 0, 4, 16, 16, 1, 1, 0, 1, rand)             # RGBA8：不收
        cls.bc4 = make_tex(0x1d01, 4, 8, 16, 16, 1, 1, 0, 1, rand)              # BC4：不收（不省内存）
        cls.bad = make_tex(0x1a01, 1, 8, 64, 64, 2, 1, 1, 1, rand, break_offsets=True)   # 级起点对不上：整张不收
        cls.sw2 = make_tex(0x1a01, 1, 8, 32, 32, 1, 1, 0, 1, rand)              # 放进 Switch 2 BNTX：不收
        romfs = cls.tmp / 'romfs'; (romfs / 'a').mkdir(parents=True)
        (romfs / 'a' / 'one.bntx').write_bytes(bntx([cls.bc1, cls.rgba, cls.bad]))
        inner = sarc([('x/two.bntx', bntx([cls.bc3, cls.bc4])), ('readme.txt', b'not a texture')])
        (romfs / 'a' / 'pack.szs').write_bytes(yaz0_literal(inner))
        model = b'FRES' + b'\0' * 60 + bntx([cls.bc7, cls.red])                  # 嵌在 BFRES 里的 BNTX
        try:
            from compression import zstd
            (romfs / 'model.bfres.zs').write_bytes(zstd.compress(model)); cls.zstd = True
        except ImportError:
            (romfs / 'model.bfres').write_bytes(model); cls.zstd = False
        (romfs / 'sw2.bntx').write_bytes(bntx([cls.sw2], platform=b'Ounc'))
        (romfs / 'big.dat').write_bytes(b'\0' * 4096)
        cls.romfs = romfs
        cls.out = cls.tmp / 'out.pack'
        cls.rep = ap.build(str(romfs), str(cls.out), ap.QUALITY['fast'], 4, TOOL_DIR, say=lambda s: None)
        cls.rows = parse_pack(cls.out)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def expected(self):
        want = {}
        for t in (self.bc1, self.bc3, self.bc7, self.red):
            for (l, L), (w, h, lin) in t['planes'].items(): want[key(t['fam'], w, h, lin)] = (w, h)
        return want

    def test_key_golden(self):
        # 与 graphics/metal/tests/t_astc.c 同一个黄金值（printf … | shasum -a 256）：出包与运行时口径一致
        self.assertEqual(ap.plane_key(1, 4, 4, bytes(range(8))).hex(), 'cf2afb54f06542892aba31a135661c3ef9c351863bde6e7267e6643cb26d109f')

    def test_keys_and_sizes(self):
        want = self.expected()
        self.assertEqual(set(self.rows), set(want), '包里的键应正好是 BC1(3 级) + BC3(2 级 × 2 层) + BC7 + 纯红 BC1 的各平面')
        self.assertEqual(len(want), 3 + 4 + 1 + 1)
        for k, (w, h) in want.items():
            blocks = -(-w // 4) * -(-h // 4)
            self.assertEqual(len(self.rows[k]), blocks * 16, f'{w}x{h} 平面的 ASTC 应是 {blocks} 块 × 16 字节')

    def test_skips_counted(self):
        r = self.rep
        self.assertEqual(r.get('layout_differs'), 1, r)
        self.assertEqual(r.get('skip_switch2'), 1, r)
        self.assertEqual(r.get('converted'), 4, r)
        self.assertEqual(r.get('yaz0'), 1, r); self.assertEqual(r.get('sarc'), 1, r)
        if self.zstd: self.assertEqual(r.get('zstd'), 1, r)
        self.assertEqual(r['entries'], len(self.rows))

    def test_red_is_constant_block(self):
        (w, h, lin), = self.red['planes'].values()
        a = self.rows[key(1, w, h, lin)]
        self.assertEqual(len(a), 32)
        for i in range(0, 32, 16):
            self.assertEqual(a[i:i + 2], b'\xfc\xfd', '纯色块应编成空区块（块模式 0x1FC、LDR）')
            r, g, b_, al = struct.unpack_from('<4H', a, i + 8)
            self.assertEqual((r, g, b_, al), (0xFFFF, 0, 0, 0xFFFF), '颜色应是红 (1,0,0,1)')

    def test_deterministic(self):
        again = self.tmp / 'again.pack'
        ap.build(str(self.romfs), str(again), ap.QUALITY['fast'], 2, TOOL_DIR, say=lambda s: None)
        self.assertEqual(again.read_bytes(), self.out.read_bytes(), '同样的输入（换并行度）应出同样的字节')

    def test_reader_agrees(self):
        head, rows = ap.read_index(str(self.out))
        self.assertEqual(head['count'], len(self.rows))
        self.assertEqual({k for k, _, _ in rows}, set(self.rows))


class UnzstdCliTest(unittest.TestCase):
    """没有 compression.zstd 时（Windows 随包 Python 3.12）退到 zstd 命令行：带字典的帧也要解得开"""

    def test_dict_frame_via_cli(self):
        try:
            from compression import zstd
        except ImportError:
            self.skipTest('这台机器的 Python 没有 compression.zstd，造不了带字典的样本')
        if not shutil.which('zstd'):
            self.skipTest('没有 zstd 命令行')
        plain = b'texture-' * 512 + bytes(range(256)) * 8
        zd = zstd.train_dict([plain[i:i + 300] + bytes([i % 251]) * 40 for i in range(0, 4000, 37)], 2048)
        frame = zstd.compress(plain, zstd_dict=zd)
        did = zd.dict_id
        self.assertNotEqual(did, 0, '训练出的字典应带编号')
        real = ap._zstd
        ap._zstd = lambda: None   # 装作没有 compression.zstd
        try:
            self.assertEqual(ap.unzstd(frame, {did: zd.dict_content}), plain)
            self.assertEqual(ap.unzstd(zstd.compress(plain), {}), plain)
        finally:
            ap._zstd = real


if __name__ == '__main__':
    unittest.main(verbosity=2)
