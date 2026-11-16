#!/usr/bin/env python3
"""标准 RomFS 镜像读取（Switch 公开格式，LibHac RomFsBuilder / services/romfs_index --std 写的那种；IMG 里的 RomFS 段也是它）。

出包要把「解开成几十万个零散文件的 romfs/ 目录」换成一整段镜像（11-16 维护者「直接做三」，cmdr 方案 RomFS镜像不落散文件）：
读取方从这里按路径取，不再要目录。只读元数据建表，文件数据按需 seek 读，不整份读进内存。

  img = RomfsImage(路径, base=0)          独立镜像 base=0；IMG 里的段用 RomfsImage.in_img(game.img)
  img.entries()                          [(相对路径, 绝对偏移, 长度)]，按路径的 UTF-8 字节序（同 romfs_list 排序清单的口径）
  img.size(rel) / img.read(rel) / img.read_range(rel, off, n) / img.head(rel, n=32) / img.open(rel)（流式读的文件对象）
  img.dirs()                             镜像里记着的目录（根是 ""）；我们出镜像只加文件，空目录不在里面

  romfs_img.py ls <镜像> [--img]          列「相对路径<TAB>长度」
  romfs_img.py cat <镜像> <相对路径> [--img]

只用标准库；路径一律 / 分隔，与 romfs_list.py 相同。"""
import io
import os
import struct
import sys

_HDR = struct.Struct('<10Q')   # 头长、目录哈希表偏移 / 长、目录元数据偏移 / 长、文件哈希表偏移 / 长、文件元数据偏移 / 长、数据区偏移
_DIR = struct.Struct('<6I')    # 父、兄弟、首个子目录、首个文件、哈希链下一个、名字长
_FILE = struct.Struct('<IIQQII')   # 父、兄弟、数据偏移、长度、哈希链下一个、名字长
_END = 0xFFFFFFFF


class RomfsError(Exception):
    pass


class RomfsImage:
    def __init__(self, path, base=0):
        self.path, self.base = os.fspath(path), base
        with open(self.path, 'rb') as f:
            f.seek(base); h = f.read(_HDR.size)
            if len(h) != _HDR.size:
                raise RomfsError(f'不是标准 RomFS（头不全）：{self.path}@{base}')
            hs, _, _, dmo, dms, _, _, fmo, fms, data = _HDR.unpack(h)
            if hs != 0x50:
                raise RomfsError(f'不是标准 RomFS（头长 {hs:#x}，应为 0x50）：{self.path}@{base}')
            f.seek(base + dmo); dmeta = f.read(dms)
            f.seek(base + fmo); fmeta = f.read(fms)
        if len(dmeta) != dms or len(fmeta) != fms:
            raise RomfsError(f'标准 RomFS 元数据不全：{self.path}@{base}')
        files, dirs, todo = {}, [], [(0, '')]
        while todo:
            off, parent = todo.pop()
            _, _, child, first, _, nl = _DIR.unpack_from(dmeta, off)
            name = dmeta[off + 24: off + 24 + nl].decode('utf-8')
            here = (parent + '/' + name).lstrip('/') if name else parent
            dirs.append(here)
            fo = first
            while fo != _END:
                _, sib, foff, size, _, fnl = _FILE.unpack_from(fmeta, fo)
                rel = (here + '/' + fmeta[fo + 32: fo + 32 + fnl].decode('utf-8')).lstrip('/')
                files[rel] = (base + data + foff, size)
                fo = sib
            c = child
            while c != _END:
                todo.append((c, here)); c = _DIR.unpack_from(dmeta, c)[1]
        self._files = files
        self._dirs = sorted(set(dirs), key=lambda p: p.encode('utf-8', 'surrogateescape'))

    @classmethod
    def in_img(cls, img_path):
        """S2Arm 单一 IMG（pack/img.py）里的 RomFS 段；没有 RomFS 段 → RomfsError"""
        with open(img_path, 'rb') as f:
            h = f.read(136)
        if h[:8] != b'S2AIMG01':
            raise RomfsError(f'不是 S2Arm IMG：{img_path}')
        ro, rl = struct.unpack_from('<QQ', h, 96)
        if not rl:
            raise RomfsError(f'IMG 里没有 RomFS 段：{img_path}')
        return cls(img_path, ro)

    def entries(self):
        return [(rel, off, size) for rel, (off, size) in sorted(self._files.items(), key=lambda kv: kv[0].encode('utf-8', 'surrogateescape'))]

    def files(self):
        """{相对路径: (绝对偏移, 长度)}（同 pack/img.py std_files 的返回）"""
        return dict(self._files)

    def dirs(self):
        return list(self._dirs)

    def __contains__(self, rel):
        return rel in self._files

    def _span(self, rel):
        try:
            return self._files[rel]
        except KeyError:
            raise FileNotFoundError(f'RomFS 里没有 {rel}：{self.path}') from None

    def size(self, rel):
        return self._span(rel)[1]

    def read_range(self, rel, offset, n):
        """rel 里从 offset 起至多 n 字节（越过文件尾就截短）"""
        start, size = self._span(rel)
        if offset < 0 or n < 0:
            raise ValueError('偏移 / 长度不能为负')
        n = max(0, min(n, size - offset))
        with open(self.path, 'rb') as f:
            f.seek(start + offset)
            return f.read(n)

    def read(self, rel):
        return self.read_range(rel, 0, self.size(rel))

    def head(self, rel, n=32):
        return self.read_range(rel, 0, n)

    def open(self, rel):
        """只读的流式文件对象（seek / read / tell，越界读到空），给要一块块读大文件的读取方"""
        start, size = self._span(rel)
        return _Slice(open(self.path, 'rb'), start, size)


class _Slice(io.RawIOBase):
    def __init__(self, f, start, size):
        self._f, self._start, self._size, self._pos = f, start, size, 0

    def readable(self): return True
    def seekable(self): return True
    def tell(self): return self._pos

    def seek(self, off, whence=io.SEEK_SET):
        self._pos = max(0, {io.SEEK_SET: off, io.SEEK_CUR: self._pos + off, io.SEEK_END: self._size + off}[whence])
        return self._pos

    def readinto(self, b):
        n = max(0, min(len(b), self._size - self._pos))
        if not n:
            return 0
        self._f.seek(self._start + self._pos)
        got = self._f.readinto(memoryview(b)[:n])
        self._pos += got
        return got

    def close(self):
        self._f.close(); super().close()


def main(argv=None):
    a = sys.argv[1:] if argv is None else argv
    use_img = '--img' in a; a = [x for x in a if x != '--img']
    if len(a) < 2 or a[0] not in ('ls', 'cat'):
        sys.exit('用法：romfs_img.py ls <镜像> [--img] | romfs_img.py cat <镜像> <相对路径> [--img]')
    img = RomfsImage.in_img(a[1]) if use_img else RomfsImage(a[1])
    if a[0] == 'ls':
        for rel, _, size in img.entries():
            sys.stdout.write(f'{rel}\t{size}\n')
    else:
        sys.stdout.buffer.write(img.read(a[2]))


if __name__ == '__main__':
    main()
