#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""#1648：只读首尾的映射不能先把整个成员复制进每个进程。

两个全新解释器同时持有同一份 64 MiB 合成 RomFS 成员，各读首尾 16 字节；
每个进程从导入完读取器到映射后的峰值 RSS 增量必须小于成员长度的 1/4。
对齐和不对齐各测一次。16 MiB 容差远大于按需读入的几页，但能拦住整份复制。
不遍历全文、不把多进程 RSS 相加当作物理内存；不需要游戏文件或 .NET。
"""
import json
import mmap
import os
from pathlib import Path
import selectors
import struct
import subprocess
import sys
import tempfile
import time
import unittest

R = Path(__file__).resolve().parents[1]
SIZE = 64 << 20
WORKERS = 2
HEAD, TAIL = b'S2ARM-MAP-HEAD!!', b'S2ARM-MAP-TAIL!!'


def fixture(path, data_offset):
    """标准 RomFS 的最小根目录与单文件表；期望偏移/内容直接给定，不经读取器生成。"""
    end = 0xffffffff
    name = b'payload.bin'
    directory = struct.pack('<6I', 0, end, end, 0, end, 0)
    entry = struct.pack('<IIQQII', 0, end, 0, SIZE, end, len(name)) + name
    entry += b'\0' * (-len(entry) % 4)
    # 0x50 头；单桶目录哈希；根目录；单桶文件哈希；文件记录；16 字节对齐的数据区。
    dmo = 0x54
    fho = dmo + len(directory)
    fmo = fho + 4
    header = struct.pack('<10Q', 0x50, 0x50, 4, dmo, len(directory), fho, 4, fmo, len(entry), data_offset)
    path.parent.mkdir()
    block = os.urandom(1 << 20)
    with path.open('wb') as stream:
        stream.write(header + struct.pack('<I', 0) + directory + struct.pack('<I', 0) + entry)
        stream.seek(data_offset)
        for _ in range(SIZE // len(block)):
            stream.write(block)
        stream.seek(data_offset)
        stream.write(HEAD)
        stream.seek(data_offset + SIZE - len(TAIL))
        stream.write(TAIL)


def worker(path):
    import resource

    sys.path.insert(0, str(R / 'graphics/nvn/tools'))
    import romfs_list

    def rss():
        value = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
        return value if sys.platform == 'darwin' else value * 1024

    before = rss()
    with romfs_list.map_file(path) as mapped:
        assert len(mapped) == SIZE
        assert mapped[:len(HEAD)] == HEAD and mapped[-len(TAIL):] == TAIL
        # 同时走 buffer 协议；不只检验包装对象的切片。
        assert struct.unpack_from('<16s', mapped)[0] == HEAD
        after = rss()
        print(json.dumps({'before_bytes': before, 'after_bytes': after, 'growth_bytes': after - before}), flush=True)
        # 父进程收齐读数才放行，确保两份映射确实同时存活。
        if sys.stdin.readline() != '\n':
            raise RuntimeError('父进程未确认读数')


@unittest.skipUnless(sys.platform in ('darwin', 'linux') and sys.version_info >= (3, 12),
                     'RSS 口径只覆盖 macOS / Linux，零拷贝 buffer 协议需要 Python 3.12+')
class MapMemory(unittest.TestCase):
    def measure(self, path):
        processes = []
        readings = []
        try:
            with selectors.DefaultSelector() as selector:
                for _ in range(WORKERS):
                    process = subprocess.Popen(
                        [sys.executable, str(Path(__file__).resolve()), '--worker', str(path)],
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                        text=True, env={**os.environ, 'S2A_ROMFS_WALK': 'off'},
                    )
                    processes.append(process)
                    selector.register(process.stdout, selectors.EVENT_READ, process)
                deadline = time.monotonic() + 30
                while len(readings) < WORKERS:
                    ready = selector.select(max(0, deadline - time.monotonic()))
                    self.assertTrue(ready, '映射子进程 30 秒内没有返回读数')
                    for key, _ in ready:
                        line = key.fileobj.readline()
                        if not line:
                            _, error = key.data.communicate(timeout=5)
                            self.fail(f'映射子进程未返回读数就退出：{error}')
                        readings.append(json.loads(line))
                        selector.unregister(key.fileobj)
            for process in processes:
                process.stdin.write('\n')
                process.stdin.flush()
            for process in processes:
                _, error = process.communicate(timeout=5)
                self.assertEqual(process.returncode, 0, error)
            return readings
        finally:
            for process in processes:
                if process.poll() is None:
                    process.kill()
                process.communicate()

    def test_mapping_is_lazy_in_each_process(self):
        with tempfile.TemporaryDirectory(prefix='romfs map memory ') as temporary:
            for name, offset in (('aligned', mmap.ALLOCATIONGRANULARITY),
                                 ('unaligned', mmap.ALLOCATIONGRANULARITY + 16)):
                with self.subTest(layout=name):
                    image = Path(temporary) / name / 'romfs.std'
                    fixture(image, offset)
                    readings = self.measure(image.with_suffix('') / 'payload.bin')
                    print(f'{name}: member_bytes={SIZE}, workers={WORKERS}, maxrss={json.dumps(readings)}', flush=True)
                    self.assertEqual(len(readings), WORKERS)
                    for number, reading in enumerate(readings):
                        with self.subTest(worker=number):
                            self.assertLess(reading['growth_bytes'], SIZE // 4,
                                            f'{name} worker {number}: 映射并读首尾就增加了至少 16 MiB，疑似整份复制')


if __name__ == '__main__':
    if sys.argv[1:2] == ['--worker']:
        worker(sys.argv[2])
    else:
        unittest.main()
