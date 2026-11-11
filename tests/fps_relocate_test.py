#!/usr/bin/env python3
"""tools/fps_relocate.py 单测：合成两版镜像，期望按构造写死（不跑被测实现推导）。
真数据核过（10-29，写在工具文件头）：巫师3 4.04c → 4.04a 判同构（610 处全差 −0x1F0）；怪猎 3.9.0 → 15.0.0 数据段 / bss 不同、拒。"""
import struct
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import fps_relocate as fr

DATA, DSZ, BSS = 0x2000, 0x100, 0x80


def image(ptrs=None, extra=None):
    """镜像：代码 0–0x1000、只读 0x1000–0x2000、数据 0x2000–0x2100；数据里在 ptrs 给的位置放 8 字节指针值"""
    img = bytearray(DATA + DSZ)
    for i in range(DATA, DATA + DSZ, 8): img[i:i + 8] = struct.pack('<Q', 0x1234 + i)   # 普通数据
    for off, v in (ptrs or {}).items(): img[DATA + off:DATA + off + 8] = struct.pack('<Q', v)
    for off, v in (extra or {}).items(): img[DATA + off:DATA + off + 8] = struct.pack('<Q', v)
    return bytes(img)


def mod(img, bss=BSS, dsz=DSZ):
    return img, 'aa' * 16, [(0, 0x1000), (0x1000, 0x1000), (DATA, dsz)], bss


class Isomorphic(unittest.TestCase):
    def test_pointer_shift_only(self):
        # 两个指向代码的指针，新版代码段短 0x10：都差 −0x10 → 同构，2 处不同
        old = mod(image({0x10: 0x500, 0x40: 0x800}))
        new = mod(image({0x10: 0x4f0, 0x40: 0x7f0}))
        ok, why = fr.isomorphic(old, new)
        self.assertTrue(ok, why)
        self.assertIn('2 处不同', why)
        self.assertIn('-0x10', why)

    def test_identical(self):
        ok, why = fr.isomorphic(mod(image()), mod(image()))
        self.assertTrue(ok, why)
        self.assertIn('0 处不同', why)

    def test_two_deltas_rejected(self):
        # 一处差 −0x10、一处差 +0x4：数据本身改了，不同构
        old = mod(image({0x10: 0x500, 0x40: 0x800}))
        new = mod(image({0x10: 0x4f0, 0x40: 0x804}))
        ok, why = fr.isomorphic(old, new)
        self.assertFalse(ok)
        self.assertIn('差值不止一种', why)

    def test_bss_or_data_size_differs(self):
        self.assertFalse(fr.isomorphic(mod(image()), mod(image(), bss=BSS + 8))[0])
        self.assertFalse(fr.isomorphic(mod(image()), mod(image() + bytes(8), dsz=DSZ + 8))[0])


class Relocate(unittest.TestCase):
    TABLE = 'build 1fee6f3f1d2a6a91\npresent display\nw main 0x411dcfc i32 60   # 限帧\nslot 2041 f32 200 100\n'

    def test_build_line_replaced_rows_kept(self):
        body, bad = fr.relocate(self.TABLE, '4bc4a8a814fd46a4831b3aa8e689886b')
        self.assertEqual(bad, [])
        self.assertEqual(body.splitlines(), ['build 4bc4a8a814fd46a4', 'present display', 'w main 0x411dcfc i32 60   # 限帧', 'slot 2041 f32 200 100'])

    def test_code_rows_refused_without_code(self):
        _, bad = fr.relocate(self.TABLE + 'c main 0x100 word 3942f661 52800021\n', 'bb' * 16)
        self.assertEqual(bad, ['c main 0x100 word 3942f661 52800021'])


def code(n, seed):
    """合成代码段：n 条「普通指令」（数据处理类编码、互不相同、不含地址字段），每 8 条插一条 bl、每 16 条插一对 adrp x3 + add x3,x3,#imm"""
    out = []
    for i in range(n):
        if i % 16 == 5: out.append(0x90000003 | ((seed + i) & 0x3) << 29 | ((seed * 7 + i) & 0x7FFFF) << 5)   # adrp x3（页号随版本变）
        elif i % 16 == 6: out.append(0x91000063 | ((seed * 13 + i) & 0xFFF) << 10)                               # add x3, x3, #页内偏移（随版本变）
        elif i % 8 == 3: out.append(0x94000000 | ((seed * 31 + i) & 0x3FFFFFF))                                  # bl（目标随版本变）
        else: out.append(0x8B000000 | (i * 2654435761 & 0x1FFFFF))                                               # add（寄存器）：版本间不变
    return b''.join(struct.pack('<I', w) for w in out)


class RelocateCode(unittest.TestCase):
    OLD = code(4096, 1)
    AT = 0x400 * 4                     # 第 0x400 条：普通指令

    def word(self, img, at): return struct.unpack_from('<I', img, at)[0]

    def test_identity(self):
        na, why = fr.locate(self.OLD, self.OLD, self.AT, self.word(self.OLD, self.AT))
        self.assertEqual(na, self.AT, why)

    def test_shift_and_pc_relative_fields_changed(self):
        # 新版：前面多 64 条（整体后移 0x100 字节），bl / adrp / add 页内偏移全换（seed 不同）→ 期望新地址 = 旧地址 + 0x100
        new = code(64, 9)[:64 * 4] + code(4096, 2)
        # code(…, 2) 的普通指令与 seed 1 相同（只依赖 i），地址字段不同
        na, why = fr.locate(self.OLD, new, self.AT, self.word(self.OLD, self.AT))
        self.assertEqual(na, self.AT + 0x100, why)
        body, bad = fr.relocate(f'build aa\nc main {self.AT:#x} word {self.word(self.OLD, self.AT):08x} 52800021   # 改\n', 'cc' * 16, (self.OLD, new))
        self.assertEqual(bad, [])
        self.assertIn(f'c main {self.AT + 0x100:#x} word', body)

    def test_ambiguous_refused(self):
        # 新版里把旧版前 8192 字节整段复制一份接在后面：窗口出现两次、放大到 64 条也不唯一 → 拒
        new = self.OLD[:8192] + self.OLD[:8192]
        na, why = fr.locate(self.OLD, new, self.AT, self.word(self.OLD, self.AT))
        self.assertIsNone(na); self.assertIn('不唯一', why)

    def test_missing_refused(self):
        # 新版窗口里的普通指令全改：找不到 → 拒；整张表不出
        new = bytes(b ^ 0x5A for b in self.OLD)
        na, why = fr.locate(self.OLD, new, self.AT, self.word(self.OLD, self.AT))
        self.assertIsNone(na); self.assertIn('找不到', why)

    def test_old_word_mismatch_refused(self):
        na, why = fr.locate(self.OLD, self.OLD, self.AT, 0xDEADBEEF)
        self.assertIsNone(na); self.assertIn('不是表里的旧字', why)


if __name__ == '__main__':
    unittest.main()
