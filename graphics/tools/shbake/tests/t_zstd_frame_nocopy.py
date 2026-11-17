#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# zstd_frame 不复制取帧的单测（graphics/tools/shbake/nxsh_extract.py）：约 1 秒，退出 0 = 全过。
# 背景：zstd_frame 原先每遇到一个帧魔数先 bytes(data[i:i + 1 MB]) 复制 1 MB 再判帧长，大文件逐段盲扫一款 657 万个帧光复制就要 245 秒；
#   现在经缓冲区协议直接取 bytes / 只读 mmap / memoryview 的内部地址 + 偏移。
# 构造（期望按构造手算，不跑被测实现）：用 libzstd 压出若干已知内容的帧，夹在随机垃圾之间拼成一份数据，记下每帧的起点、压缩长度与原文：
#   ① 帧头写了原长的小帧：zstd_frame(数据, 起点) = (原文, 压缩长度)
#   ② 帧头没写原长的帧（流式压缩，ZSTD_CONTENTSIZE_UNKNOWN）：同样返回 (原文, 压缩长度)
#   ③ 原文 3 MB 的帧（压缩后超过 1 MB）：同样返回 (原文, 压缩长度)——原先靠第二档 64 MB 窗口取到
#   ④ 截在数据尾、帧不完整：None；⑤ 垃圾里的假魔数（后面不是合法帧头）：None
#   ⑥ 同一份数据按 bytes、只读 mmap、memoryview 三种形态给，结果逐条相同；⑦ 调完 mmap 照常能关（缓冲区已释放）
#   ⑧ scan_zstd_frames 走完整份数据：统计「内嵌 zstd 帧」= 完整帧个数（①②③ 共 4 个）
import sys, os, ctypes, mmap, random, tempfile, collections
D = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
sys.path.insert(0, os.path.abspath(D)); import nxsh_extract as X
z = X._zstd_lib()
z.ZSTD_compress.restype = ctypes.c_size_t; z.ZSTD_compress.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char_p, ctypes.c_size_t, ctypes.c_int]
z.ZSTD_compressBound.restype = ctypes.c_size_t; z.ZSTD_compressBound.argtypes = [ctypes.c_size_t]
fails = 0
def ck(ok, msg):
    global fails
    print(('通 ' if ok else '不通 ') + msg)
    fails += 0 if ok else 1
def comp(src):   # 帧头写原长的普通压缩
    cap = z.ZSTD_compressBound(len(src)); buf = ctypes.create_string_buffer(cap); n = z.ZSTD_compress(buf, cap, src, len(src), 3)
    assert not z.ZSTD_isError(n); return buf.raw[:n]
def comp_unknown(src):   # 帧头不写原长：用流式 API 压、不给 pledgedSrcSize
    class Buf(ctypes.Structure): _fields_ = [('ptr', ctypes.c_void_p), ('size', ctypes.c_size_t), ('pos', ctypes.c_size_t)]
    z.ZSTD_createCCtx.restype = ctypes.c_void_p
    z.ZSTD_compressStream2.restype = ctypes.c_size_t; z.ZSTD_compressStream2.argtypes = [ctypes.c_void_p, ctypes.POINTER(Buf), ctypes.POINTER(Buf), ctypes.c_int]
    z.ZSTD_freeCCtx.argtypes = [ctypes.c_void_p]
    cctx = z.ZSTD_createCCtx(); cap = z.ZSTD_compressBound(len(src)) + 64; out = ctypes.create_string_buffer(cap); inb = ctypes.create_string_buffer(src, len(src))
    ob = Buf(ctypes.cast(out, ctypes.c_void_p), cap, 0); ib = Buf(ctypes.cast(inb, ctypes.c_void_p), len(src), 0)
    while True:   # ZSTD_e_end = 2；没设 pledgedSrcSize → 帧头不写原长
        r = z.ZSTD_compressStream2(cctx, ctypes.byref(ob), ctypes.byref(ib), 2)
        assert not z.ZSTD_isError(r)
        if r == 0: break
    z.ZSTD_freeCCtx(cctx); return out.raw[:ob.pos]
rnd = random.Random(7)
def junk(n): return bytes(rnd.getrandbits(8) for _ in range(n)).replace(b'\x28\xb5\x2f\xfd', b'\x00\xb5\x2f\xfd')
small = b'shader-blob ' * 300
unknown = b'no-content-size ' * 500
big = bytes(rnd.getrandbits(8) for _ in range(3 << 20))   # 随机内容几乎不可压：压缩后 > 1 MB
parts, frames = [junk(100)], []
def put(src, f):
    frames.append((sum(map(len, parts)), len(f), src)); parts.append(f); parts.append(junk(57))
put(small, comp(small)); put(unknown, comp_unknown(unknown)); put(big, comp(big)); put(small[::-1], comp(small[::-1]))
fake = sum(map(len, parts)); parts.append(b'\x28\xb5\x2f\xfd' + b'\xff' * 40)   # ⑤ 假魔数：帧头描述符非法
cut_f = comp(small * 3); cut = sum(map(len, parts)); parts.append(cut_f[:len(cut_f) // 2])   # ④ 截在数据尾
data = b''.join(parts)
ck(len(frames[2][2]) == 3 << 20 and frames[2][1] > 1 << 20, f'③ 大帧压缩后 {frames[2][1]} 字节，超过 1 MB')
for k, (off, cs, src) in enumerate(frames):
    ck(X.zstd_frame(data, off) == (src, cs), f'{"①②③①"[k]} 第 {k + 1} 帧（起点 {off:#x}）→ 原文 {len(src)} 字节、压缩长度 {cs}')
ck(X.zstd_frame(data, cut) is None, '④ 截断的帧 → None')
ck(X.zstd_frame(data, fake) is None, '⑤ 假魔数 → None')
p = tempfile.mktemp(); open(p, 'wb').write(data)
want = [X.zstd_frame(data, o) for o in [f[0] for f in frames] + [cut, fake]]
with open(p, 'rb') as fh:
    mm = mmap.mmap(fh.fileno(), 0, access=mmap.ACCESS_READ)
    got_mm = [X.zstd_frame(mm, o) for o in [f[0] for f in frames] + [cut, fake]]
    got_mv = [X.zstd_frame(memoryview(data), o) for o in [f[0] for f in frames] + [cut, fake]]
    ck(got_mm == want and got_mv == want, '⑥ bytes / 只读 mmap / memoryview 三种形态结果逐条相同')
    try: mm.close(); ck(True, '⑦ 调完照常能关 mmap（缓冲区已释放）')
    except BufferError as e: ck(False, f'⑦ mmap 关不了：{e}')
os.remove(p)
stat = collections.Counter(); X.scan_zstd_frames('t.bin', data, [], {}, stat)
ck(stat['内嵌 zstd 帧'] == 4, f'⑧ scan_zstd_frames 内嵌 zstd 帧 = {stat["内嵌 zstd 帧"]}（期望 4）')
print('✓ t_zstd_frame_nocopy 全过' if not fails else f'✗ t_zstd_frame_nocopy {fails} 项不通'); sys.exit(1 if fails else 0)
