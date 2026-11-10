#!/usr/bin/env python3
"""单文件镜像（pack/romfs_image.py）：手写布局，期望值不跑被测实现：python3 tests/romfs_image_test.py"""
import hashlib, json, os, struct, subprocess, sys, tempfile, unittest
from pathlib import Path

R = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(R / 'pack')); sys.path.insert(0, str(R / 'tools'))
import romfs_image


def sha(b): return hashlib.sha256(b).hexdigest()


def index(total, files):
    paths = b''.join(rel.encode() for _, _, rel in files); out = b'S2ARFS01' + struct.pack('<qi', total, len(files)); p = 0
    for off, n, rel in files:
        out += struct.pack('<qqii', off, n, p, len(rel.encode())); p += len(rel.encode())
    return out + struct.pack('<i', len(paths)) + paths + struct.pack('<i', 0)


class Image(unittest.TestCase):
    def setUp(self):
        self.td = tempfile.TemporaryDirectory(); t = Path(self.td.name)
        self.src, self.out, self.root = t / 'pack.files', t / 'pack', t / 'root'
        self.root.mkdir(); (self.src / 'romfs/ui').mkdir(parents=True); (self.src / 'exefs').mkdir()
        self.files = {'romfs/a.bin': b'AAAA', 'romfs/ui/layout.zs': b'OVER', 'romfs/z.bin': b'ZZ', 'romfs/empty': b'', 'exefs/main.npdm': b'NPDM'}
        for k, v in self.files.items(): (self.src / k).write_bytes(v)
        idx = index(4096, [(100, 4, 'a.bin'), (200, 4, 'ui/layout.zs'), (300, 2, 'z.bin')]); (self.src / 'romfs.s2aidx').write_bytes(idx); self.files['romfs.s2aidx'] = idx
        (self.root / 'ui_overlay.tsv').write_text('ui/layout.zs\n')
        self.write_index()

    def write_index(self, skip=()):
        (self.src / 'index.tsv').write_text(''.join(f'{k}\t{len(v)}\t{sha(v)}\n' for k, v in self.files.items() if k not in skip))

    def tearDown(self): self.td.cleanup()

    def build(self): romfs_image.build(str(self.src), str(self.out), str(self.root))

    def image(self):   # 库里不存镜像（#329）：按索引记的长度 / sha256 现拼，读回字节后删掉
        row = {l.split('\t')[0]: l.split('\t') for l in (self.out / 'index.tsv').read_text().splitlines()}['romfs.img']
        f = Path(romfs_image.materialize(self.out, 'romfs.img', int(row[1]), row[2], say=lambda *_: None))
        b = f.read_bytes(); f.unlink(); return b

    def test_layout(self):
        self.build()
        self.assertFalse((self.out / 'romfs.img').exists())   # #329：库里不存镜像
        for rel in ('a.bin', 'z.bin'):   # 存镜像各文件的硬链接（同一 inode，不另占盘）；覆盖层不在里面
            self.assertEqual((self.out / 'romfs.files' / rel).stat().st_ino, (self.src / 'romfs' / rel).stat().st_ino)
        self.assertFalse((self.out / 'romfs.files/ui/layout.zs').exists())
        self.assertEqual(self.image(), b'AAAAZZ')   # 覆盖层文件不进镜像，首尾相接
        m = (self.out / 'romfs.imgmap').read_bytes()
        self.assertEqual(m, b'S2ARIM01' + struct.pack('<qi', 6, 3) + struct.pack('<3q', 0, -1, 4))
        self.assertEqual((self.out / 'romfs_overlay/ui/layout.zs').read_bytes(), b'OVER')
        self.assertFalse((self.out / 'romfs').exists())
        rows = {l.split('\t')[0]: l.split('\t') for l in (self.out / 'index.tsv').read_text().splitlines()}
        self.assertEqual(rows['romfs.img'][1:], ['6', sha(b'AAAAZZ')])
        self.assertEqual(rows['romfs_overlay/ui/layout.zs'][1:], ['4', sha(b'OVER')])
        self.assertIn('exefs/main.npdm', rows); self.assertNotIn('romfs/a.bin', rows)
        man = json.loads((self.out / 'manifest.json').read_text())
        self.assertEqual((man['index_sha256'], man['files']), (sha((self.out / 'index.tsv').read_bytes()), len(rows)))

    def test_overlay_change_keeps_image(self):
        self.build(); before = self.image()
        self.files['romfs/ui/layout.zs'] = b'OVER2'; (self.src / 'romfs/ui/layout.zs').write_bytes(b'OVER2')
        self.files['romfs.s2aidx'] = index(4096, [(100, 4, 'a.bin'), (200, 5, 'ui/layout.zs'), (300, 2, 'z.bin')]); (self.src / 'romfs.s2aidx').write_bytes(self.files['romfs.s2aidx'])
        self.write_index(); self.build()
        self.assertEqual(self.image(), before)   # 覆盖层变了，镜像字节不变，不用重推
        self.assertEqual((self.out / 'romfs_overlay/ui/layout.zs').read_bytes(), b'OVER2')

    def test_mismatch_is_red_and_leaves_no_output(self):
        self.files['romfs/extra.bin'] = b'X'; (self.src / 'romfs/extra.bin').write_bytes(b'X'); self.write_index()
        with self.assertRaises(romfs_image.Red): self.build()
        self.assertFalse((self.out / 'manifest.json').exists())

    def test_unchanged_is_reused(self):
        self.build(); mt = (self.out / 'index.tsv').stat().st_mtime_ns; self.build()
        self.assertEqual((self.out / 'index.tsv').stat().st_mtime_ns, mt)

    def test_materialize_rejects_changed_file(self):
        # 资源包里的文件被改过（同长不同内容）：现拼核 sha256 对不上 → 报红、不留半份
        self.build(); f = self.out / 'romfs.files/z.bin'; f.unlink(); f.write_bytes(b'YY')
        row = {l.split('\t')[0]: l.split('\t') for l in (self.out / 'index.tsv').read_text().splitlines()}['romfs.img']
        with self.assertRaises(romfs_image.Red): romfs_image.materialize(self.out, 'romfs.img', int(row[1]), row[2], say=lambda *_: None)
        self.assertFalse((self.out / 'romfs.img').exists()); self.assertFalse((self.out / 'romfs.img.part').exists())


if __name__ == '__main__':
    unittest.main()
