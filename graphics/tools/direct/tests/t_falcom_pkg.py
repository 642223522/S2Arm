#!/usr/bin/env python3
# Falcom 资源包（.pkg）里的着色器（11-19 英雄传说 创之轨迹 010053D014C44000：148,359 支着色器全在 shaders/*.pkg 的 LZ4 条目里，直连抽取只当普通文件扫，
#   离线直连库 4 支，其余全部到设备上首遇现编）：translator/shader_split.py falcom_pkg / scan_file。约 0.1 秒，退出 0 = 全过。
# 包格式（期望按格式手写，不跑被测实现推）：u32 0、u32 条目数 n、n × 0x50 字节条目 {64 字节名字（零补齐）、u32 长度、u32 存储长度、u32 偏移（从文件头算）、u32 标志}，
#   数据紧跟条目表（第一条的偏移 = 8 + 0x50 n）。标志 0 = 原样存；位 0 = LZ4 块；标志 9、存储长度 0 = 数据不在包里。
#   键 = sha256(控制段[0:0x880] ‖ 代码区) 前 16 位十六进制（直连口径）。
#   ① 两条 LZ4 条目 + 一条原样存的条目各放一个 BNSH（各 1 支 vs），再加一条不含着色器的 LZ4 条目：读出 3 支，键、来源标签逐个对
#   ② 标志 9、存储长度 0 的条目：不读、不报错（同 ① 的包里带一条）
#   ③ 标志带位 0 但数据不是 LZ4 块：这个文件报 [RED]（scan_counted 只跳过它、记 FILE_RED），不静默当没有
#   ④ 开头也是 u32 0、但条目表对不上的普通文件（第一条偏移不在表尾）：照旧按普通文件扫，里面直接放的 BNSH 读得到
#   ⑤ 认不出的标志（这里 4）且有数据的条目：这一条不读、打一行 [WARN]，同包其余条目照读
#   ⑥ 开头 u32 0、条目数很大（10 万）但第一条偏移不在表尾的普通文件：读条目表之前就判成不是包（falcom_pkg 里 struct.unpack_from 只调 2 次：文件头、第一条的偏移）
#   ⑦ 标志 1 的条目自报长度超过 LZ4 上限（存储 1 字节、自报 0x40000000；LZ4 最多 255 倍）：解压之前报 [RED]（解码器会先按自报长度申请内存），lz4.block.decompress 调 0 次
import contextlib, hashlib, io, os, struct, sys, tempfile
from pathlib import Path
import lz4.block
H = Path(__file__).resolve().parents[4]
CTL = bytes.fromhex('34127698'); GFX = bytes.fromhex('78563412')
bad = 0
def chk(name, want, got):
    global bad
    ok = want == got; bad += not ok
    print(f'{"通" if ok else "不通"} {name}：期望 {want!r} → 真结果 {got!r}')

def bnsh(fill):
    """一个 BNSH：1 个变体、1 个程序、1 支顶点着色器（控制段 0x880 字节在 0x400、代码区 0x40 字节在 0x1000，代码区第 4 字节起填 fill）；同 t_bnsh_bounds.py container"""
    d = bytearray(0x2000)
    d[0:8] = b'BNSH\0\0\0\0'; struct.pack_into('<I', d, 0x1c, len(d)); d[0x60:0x64] = b'grsc'
    struct.pack_into('<IQ', d, 0x7c, 1, 0x100); struct.pack_into('<Q', d, 0x100 + 0x10, 0x200); struct.pack_into('<Q', d, 0x200 + 8, 0x300)
    struct.pack_into('<QQII', d, 0x300 + 8, 0x400, 0x1000, 0x40, 0x880)
    d[0x400:0x404] = CTL; struct.pack_into('<I', d, 0x400 + 0x20, 0x880); struct.pack_into('<I', d, 0x400 + 0x704, 0x40)
    d[0x1000:0x1004] = GFX; d[0x1004:0x1040] = bytes([fill]) * 0x3c
    return bytes(d)
def key(b): return hashlib.sha256(b[0x400:0x400 + 0x880] + b[0x1000:0x1040]).hexdigest()[:16]

def pkg(entries, first=None):
    """entries：[(名字, 原始数据, 标志, 存进包的字节或 None = 按标志现压)]"""
    n = len(entries); table = bytearray(); data = bytearray(); at = 8 + 0x50 * n if first is None else first
    for name, raw, flags, stored in entries:
        s = stored if stored is not None else lz4.block.compress(raw, store_size=False) if flags & 1 else raw
        table += name.encode().ljust(0x40, b'\0') + struct.pack('<IIII', len(raw), len(s), at + len(data), flags); data += s
    return struct.pack('<II', 0, n) + bytes(table) + bytes(first - 8 - 0x50 * n if first is not None else 0) + bytes(data)

with tempfile.TemporaryDirectory(prefix='falcompkg-') as t:
    (Path(t) / 'game.tsv').write_text('shader_groups\tsynthetic=synthetic\nshader_note\tsynthetic\n')
    os.environ['DM_GAME'] = t
    sys.path.insert(0, str(H / 'translator'))
    import shader_split as S
    def scan(name, blob):
        p = Path(t) / name; p.write_bytes(blob)
        out = io.StringIO()
        with contextlib.redirect_stdout(out): r = S.scan_counted((str(p), name))
        return r, out.getvalue()
    a, b, c = bnsh(0x11), bnsh(0x22), bnsh(0x33)
    # ① ②
    r, _ = scan('a.pkg', pkg([('aaaa', a, 1, None), ('tex.dds.phyre', bytes(0x1000), 9, b''), ('bbbb', b, 1, None), ('plain.xml', b'<?xml version="1.0"?>' * 40, 1, None), ('cccc', c, 0, None)]))
    chk('① ② 3 支着色器的键', sorted([key(a), key(b), key(c)]), sorted(r[1]))
    chk('① 来源标签', sorted(f'/a.pkg/{n}#BNSH@0x0#var0' for n in ('aaaa', 'bbbb', 'cccc')), sorted(v[0] for v in r[1].values()))
    chk('① ② 没有跳过记录', [], r[4])
    # ③
    r, _ = scan('bad.pkg', pkg([('aaaa', a, 1, None), ('junk', bytes(0x400), 1, b'\xff' * 0x40)]))
    chk('③ 解不开的 LZ4 条目：整个文件记 FILE_RED', (True, {}), (len(r[4]) == 1 and r[4][0][0] == getattr(S, 'FILE_RED', None) and r[4][0][1].startswith('bad.pkg: '), r[1]))
    # ④
    r, _ = scan('plain.bin', pkg([('aaaa', a, 0, None)], first=8 + 0x50 + 0x10))
    chk('④ 条目表对不上：按普通文件扫', ([key(a)], [f'/plain.bin#BNSH@{8 + 0x50 + 0x10:#x}#var0']), (sorted(r[1]), sorted(v[0] for v in r[1].values())))
    # ⑤
    r, log = scan('mix.pkg', pkg([('aaaa', a, 1, None), ('zzzz', b, 4, lz4.block.compress(b, store_size=False))]))
    chk('⑤ 认不出的标志：这一条不读，其余照读', ([key(a)], []), (sorted(r[1]), r[4]))
    chk('⑤ 打一行 [WARN]', 1, sum(l.startswith('[WARN] /mix.pkg') for l in log.splitlines()))
    # ⑥
    blob = bytearray(8 + 0x50 * 100000 + 0x100); struct.pack_into('<II', blob, 0, 0, 100000); struct.pack_into('<I', blob, 8 + 0x48, 0x1234)
    calls = [0]; real = struct.unpack_from
    def counted(*a): calls[0] += 1; return real(*a)
    S.struct.unpack_from = counted
    try: got = getattr(S, 'falcom_pkg', lambda d: 'no reader')(bytes(blob))
    finally: S.struct.unpack_from = real
    chk('⑥ 第一条偏移不在表尾：不读条目表', (None, 2), (got, calls[0]))
    # ⑦
    n = [0]; dec = lz4.block.decompress
    def spy(*a, **k): n[0] += 1; return dec(*a, **k)
    lz4.block.decompress = spy
    try: r, _ = scan('bomb.pkg', pkg([('aaaa', a, 1, None)])[:8 + 0x40] + struct.pack('<IIII', 0x40000000, 1, 8 + 0x50, 1) + b'\0')
    finally: lz4.block.decompress = dec
    chk('⑦ 自报长度超过 LZ4 上限：解压前报红', (True, 0), (len(r[4]) == 1 and r[4][0][0] == getattr(S, 'FILE_RED', None) and '255 to 1' in r[4][0][1], n[0]))
print(f'{"✓" if not bad else "✗"} t_falcom_pkg：{bad} 处不符')
sys.exit(1 if bad else 0)
