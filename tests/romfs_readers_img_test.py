#!/usr/bin/env python3
"""RomFS 读内容的读取方「目录形态 vs 镜像形态」对拍单测（python3 tests/romfs_readers_img_test.py；tests/romfs_img_test.sh 调）。
同一份夹具：目录形态 = <根>/romfs/ 散文件；镜像形态 = 同内容用 services/romfs_index --std（LibHac RomFsBuilder，出 IMG 那一份）建 <根>/romfs.std、romfs/ 拿走。
每个读取方两种形态跑同一个入口，结果逐字节相同；期望另按夹具手写（不跑被测实现推）：
  ① romfs_list 盘点镜像里的子目录（ui_lyt 走 Layout/ 这种）= 目录形态；按路径读：open_file / read_file（全文、seek 后读、读尾）/ file_size / is_file / is_dir / exists / map_file（不对齐 → 匿名映射拷贝、
     对齐到映射粒度 → 直接映射镜像那一段）= 夹具字节；不在的路径同 open / os.path.* 报错或 False；目录在时不看镜像
  ② host_decoder.need：pak 11 Oodle / utoc Oodle / Trinity（.trpfs + .trpfd）/ PKZ Oodle / HGPAK Oodle 块 / IDCL Oodle 着色器 各 1 条 = 6 条，没有 .trpfd 的 .trpfs 不算
  ③ nro_to_nso：a/x.nro、b/X.NRO（同内容）、z.nro + .nrr 登记藏在 data/big.arc 里的原样 NRO → nro_modules.tsv 三行（nro2 来源 data/big.arc@<偏移>）、各 NSO 逐字节相同
  ④ nro_exports：导出表 = 夹具的导出名；glslc_offline.romfs_nros = 夹具三个 NRO 全文；gfx_api.romfs_nros 同两形态、romfs_glsl 有 #version 的 1、没有的 0
  ⑤ resource_input_key：键 = 按规则手算（exefs/main 整份、romfs 文件 ≤ 128 KiB 整份 / 更大取首尾各 64 KiB）；镜像形态签名取镜像文件、重算命中缓存不再读
  ⑥ stages.rewrite_inputs（改写键）= 手算（exefs 文件 + RomFS 里 .nro / .nrr 全文摘要）
  ⑦ spirv_msl.spirv_files 同路径集合、按路径读出的字节 = 夹具；ui_lyt 两形态日志与覆盖层逐字节相同；格式库 unreal_pak / re_pak 认头同真假
负对照：romfs_list 去掉按路径读（open_file 换回 open）→ ①–⑦ 镜像形态报错（见提交说明）。
要 dotnet 编 services/romfs_index；没有 dotnet 时整份跳过并打印原因，退出 0"""
import hashlib, io, mmap, os, shlex, shutil, struct, subprocess, sys, tempfile
from pathlib import Path

R = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(R))
os.environ['S2A_ROMFS_WALK'] = 'off'
from pack.orch import host_decoder, stages   # noqa: E402  先于把 pack/ 放进路径（pack/pack.py 会盖住命名空间包 pack）
for d in ('graphics/nvn/tools', 'pack', 'tools', 'translator', 'graphics/tools', 'graphics/tools/shbake', 'runtime/rewriter'):
    sys.path.insert(0, str(R / d))
import romfs_list   # noqa: E402

bad = 0
def ck(ok, msg):
    global bad
    print(('通 ' if ok else '不通 ') + msg); bad += 0 if ok else 1


def rb(p):   # 读输出文件；没写出来（被测工具失败）→ None，比较照样不通、不中断后面各项
    try: return Path(p).read_bytes()
    except OSError: return None


def attempt(fn):   # 被测入口抛异常 → 记成异常（比较不通），不中断后面各项
    try: return fn()
    except Exception as e: return f'异常 {type(e).__name__}: {e}'


def romfs_index_cmd(t):   # 同 tests/romfs_list_img_test.py
    dotnet = shutil.which('dotnet') or (os.path.join(os.environ['DOTNET_ROOT'], 'dotnet') if os.environ.get('DOTNET_ROOT') else None)
    if not dotnet: return None, '没有 dotnet'
    pre = os.environ.get('S2A_ROMFS_INDEX_DLL')   # tests/romfs_img_test.sh 编好一次交给 4 份脚本共用；没设（单独跑本脚本）照旧自己编
    if pre and os.path.isfile(pre): return f'{shlex.quote(dotnet)} {shlex.quote(pre)}', ''
    out = os.path.join(t, 'ri')
    r = subprocess.run([dotnet, 'build', str(R / 'services/romfs_index'), '-c', 'Release', '-o', out], capture_output=True, text=True)
    if r.returncode: return None, '编 services/romfs_index 失败：' + r.stdout[-300:]
    return f'{shlex.quote(dotnet)} {shlex.quote(os.path.join(out, "romfs_index.dll"))}', ''


# ---- 夹具（各格式按公开布局手写最小文件头，同 tests/host_decoder_test.py / tests/nro_to_nso_test.sh） ----
MAGIC = 0x5A6F12E1
def pak_v11(methods):
    names = b''.join(m.encode().ljust(32, b'\0') for m in methods + [''] * (5 - len(methods)))
    return b'\0' * 64 + b'\0' + struct.pack('<IIQQ', MAGIC, 11, 0, 0) + b'\0' * 20 + names
def utoc(methods):
    h = bytearray(144); h[:16] = b'-==--==--==--==-'; h[16] = 3
    struct.pack_into('<9I', h, 20, 144, 0, 0, 12, len(methods), 32, 65536, 0, 1)
    return bytes(h) + b''.join(m.encode().ljust(32, b'\0') for m in methods)
def pkz_file(methods):
    names = b''; off = {}
    for s in ['a', *methods]:
        if s not in off: off[s] = len(names); names += s.encode() + b'\0'
    n = len(methods); table = 32; data_at = table + 32 * n + len(names)
    rows = b''.join(struct.pack('<IIQQQ', off['a'], off[m], 4, data_at, 4) for m in methods)
    body = rows + names + b'DATA'
    return b'pkzl' + b'\0' * 4 + struct.pack('<Q', 32 + len(body)) + struct.pack('<III', n, table, len(names)) + b'\0' * 4 + body
CH = 0x20000
def hgpak_file(csz):
    n, c = 1, len(csz); D = (0x30 + 32 * n + 8 * c + 15) & ~15
    h = b'HGPAK\0\0\0' + struct.pack('<5Q', 2, n, c, 1, D) + struct.pack('<16sQQ', b'h' * 16, D, CH + 0x80) + struct.pack(f'<{c}Q', *csz)
    return h.ljust(D, b'\0') + b''.join(b'z' * ((s + 15) & ~15) for s in csz)
def idcl_file(kind, how):
    strs = kind.encode() + b'\0x\0'
    h = bytearray(0x80); h[:8] = b'IDCL' + struct.pack('<I', 12)
    struct.pack_into('<4I', h, 0x20, 1, 0, 0, 2); struct.pack_into('<7Q', h, 0x38, len(strs), 0x80, 0, 0xC0, 0, 0xB0, 0x150)
    st = struct.pack('<QQQ', 2, 0, len(kind) + 1) + strs
    e = bytearray(0x90); struct.pack_into('<3Q', e, 0x38, 0x150, 4, 8); e[0x70] = how
    return bytes(h) + st.ljust(0x30, b'\0') + struct.pack('<QQ', 0, 1) + bytes(e) + b'DATA'
EXPORTS = ['s2a_fixture_export', 'nvnBootstrapLoader_like']
def nro(tag):
    """text / ro / data 各 0x1000（同 tests/nro_to_nso_test.sh）；ro 里放 MOD0 + 动态段（DT_SYMTAB / DT_STRTAB）+ 两个导出符号（给 nro_exports）"""
    text = bytearray(0x1000)
    struct.pack_into('<II', text, 0, 0, 0x1000)
    text[0x10:0x14] = b'NRO0'; struct.pack_into('<III', text, 0x14, 0, 0x3000, 0)
    struct.pack_into('<6I', text, 0x20, 0, 0x1000, 0x1000, 0x1000, 0x2000, 0x1000)
    struct.pack_into('<I', text, 0x38, 0x1000); text[0x48] = tag
    ro = bytearray(0x1000)
    struct.pack_into('<4si', ro, 0, b'MOD0', 0x400)                    # 动态段在 ro+0x400（文件 0x1400）
    struct.pack_into('<4Q', ro, 0x400, 5, 0x1600, 6, 0x1500)           # DT_STRTAB = 0x1600、DT_SYMTAB = 0x1500（文件偏移），随后 0 结尾
    strtab = b'\0' + b'\0'.join(n.encode() for n in EXPORTS) + b'\0'
    ro[0x600:0x600 + len(strtab)] = strtab
    at = 1
    for i, n in enumerate(EXPORTS):                                    # 符号 24 字节：名偏移 u32、info（GLOBAL FUNC = 0x12）、other、shndx 1、值、大小
        struct.pack_into('<IBBHQQ', ro, 0x500 + 24 * (i + 1), at, 0x12, 0, 1, 0x100, 4); at += len(n) + 1
    return bytes(text) + bytes(ro) + bytes(0x1000)
def nrr(hashes):
    d = bytearray(0x350 + 32 * len(hashes)); d[:4] = b'NRR0'
    struct.pack_into('<I', d, 0x338, len(d)); struct.pack_into('<II', d, 0x340, 0x350, len(hashes))
    for i, h in enumerate(hashes): d[0x350 + 32 * i:0x370 + 32 * i] = h
    return bytes(d)


A, Z, HID = nro(1), nro(2), nro(3)
HID_AT = 0x1234
BIG = os.urandom(HID_AT) + HID + os.urandom(0x777)
LAYOUT_SARC = b'SARC' + bytes(0x40)
FILES = {
    # host_decoder（②）：各 1 条
    'Game/Paks/a.pak': pak_v11(['Oodle']), 'Game/Paks/g.utoc': utoc(['Zlib', 'Oodle']),
    'arc/data.trpfs': b'ONEPACK\0' + b'\0' * 24, 'arc/data.trpfd': b'\0' * 32, 'lone/x.trpfs': b'ONEPACK\0' + b'\0' * 24,
    'root_000.pkz': pkz_file(['OodleKraken', 'None']), 'GAMEDATA/NMSARC.Shaders.pak': hgpak_file([CH, 0x40]),
    'base/gameresources.resources': idcl_file('renderProgResource', 2),
    # NRO（③ ④）
    'a/x.nro': A, 'b/X.NRO': A, 'z.nro': Z, '.nrr/r.nrr': nrr([hashlib.sha256(HID).digest()]), 'data/big.arc': BIG,
    # GLSL（④）、SPIR-V（⑦）、大文件（⑤ 首尾抽样）、布局（⑦）、RE 引擎 pak 头（⑦）
    'shaders/a.glsl': b'// x\n#version 450\nvoid main(){}\n', 'shaders/v.spv': struct.pack('<5I', 0x07230203, 0x10000, 0, 1, 0),
    'big/blob.bin': os.urandom(300 * 1024), 'Layout/Title.Nin_NX_NVN.szs': LAYOUT_SARC, 're/re_chunk_000.pak': b'KPKA' + bytes(12),
    'empty.bin': b'',
}

with tempfile.TemporaryDirectory(prefix='romfs readers img ') as t:
    T = Path(t)
    cmd, why = romfs_index_cmd(t)
    if not cmd:
        print(f'跳过：{why}'); sys.exit(0)
    D, I = T / 'd' / 't0100@cur', T / 'i' / 't0100@cur'
    for root in (D, I):
        (root / 'exefs').mkdir(parents=True); (root / 'exefs/main').write_bytes(b'NSO0' + b'M' * 300)
    for k, v in FILES.items():
        p = D / 'romfs' / k; p.parent.mkdir(parents=True, exist_ok=True); p.write_bytes(v)
    def build(src, dst):
        dst.write_bytes(b'')
        r = subprocess.run(shlex.split(cmd) + ['--std', str(src), '-', str(dst), '0'], capture_output=True, text=True)
        return r.returncode == 0
    ck(build(D / 'romfs', I / 'romfs.std'), '夹具建成镜像')
    rd, ri = D / 'romfs', I / 'romfs'
    ck(romfs_list.image_of(ri) is not None and romfs_list.image_of(rd) is None, '镜像形态只有 romfs.std、目录形态只有 romfs/')

    # ① 按路径读
    ok_read = ok_seek = ok_map = True
    for k, v in FILES.items():
        p = ri / k
        ok_read &= romfs_list.read_file(p) == v and romfs_list.file_size(p) == len(v) and romfs_list.is_file(p) and romfs_list.exists(p) and not romfs_list.is_dir(p)
        with romfs_list.open_file(p) as f:
            f.seek(len(v) // 2); mid = f.read(7); f.seek(-3, io.SEEK_END); tail = f.read(); pos = f.tell()
        ok_seek &= mid == v[len(v) // 2:len(v) // 2 + 7] and tail == v[-3:] and pos == len(v)
        if v:
            with romfs_list.map_file(p) as m:
                ok_map &= len(m) == len(v) and m[:] == v and m.rfind(v[-4:]) == len(v) - 4
    ck(ok_read, f'① read_file / file_size / is_file / exists = 夹具（{len(FILES)} 个文件）')
    ck(ok_seek, '① open_file：seek 中间读、SEEK_END 读尾、tell = 夹具')
    ck(ok_map, '① map_file（不对齐 → 文件映射视图，3.12 以下拷贝）：长度 / 全文 / rfind = 夹具')
    sub = lambda r: sorted((e.rel, e.file, e.lstat.st_size if e.file else 0) for e in romfs_list.scan(r / 'Game').entries)
    ck(sub(rd) == sub(ri) == [('Paks', False, 0), ('Paks/a.pak', True, len(FILES['Game/Paks/a.pak'])), ('Paks/g.utoc', True, len(FILES['Game/Paks/g.utoc']))]
       and romfs_list.scan(ri / 'nope').errors.get('') is not None, '① scan 镜像里的子目录（Game/）= 目录形态；镜像里没有的子目录同目录盘点记「打不开」')
    ck(romfs_list.is_dir(ri) and romfs_list.is_dir(ri / 'Game/Paks') and not romfs_list.is_dir(ri / 'nope') and not romfs_list.is_file(ri / 'Game'), '① is_dir：镜像根、子目录真，不在的假，目录不是文件')
    errs = []
    for fn in (romfs_list.open_file, romfs_list.read_file, romfs_list.file_size, romfs_list.map_file):
        try: fn(ri / 'nope.bin'); errs.append(None)
        except FileNotFoundError: errs.append('FNF')
    ck(errs == ['FNF'] * 4 and not romfs_list.exists(ri / 'nope.bin'), '① 不在的路径：open_file / read_file / file_size / map_file 抛 FileNotFoundError、exists 假')
    with romfs_list.map_file(rd / 'big/blob.bin') as m: dir_map = type(m).__name__
    ck(dir_map == 'mmap' and romfs_list.read_file(rd / 'z.nro') == Z, '① 目录形态同 open / mmap')
    try: romfs_list.map_file(ri / 'empty.bin'); ck(False, '① 空文件 map_file 应抛 ValueError（同 mmap）')
    except ValueError: ck(True, '① 空文件 map_file 抛 ValueError（同 mmap）')
    # 对齐分支：调 a.bin 的长度让 b.bin 的数据起点落在映射粒度上（LibHac 文件数据按 0x10 排、按路径序）
    G = mmap.ALLOCATIONGRANULARITY; al = T / 'al'; (al / 'r').mkdir(parents=True)
    (al / 'r/a.bin').write_bytes(b'a' * 16); body = os.urandom(G + 5); (al / 'r/b.bin').write_bytes(body)
    build(al / 'r', al / 'probe.std')
    import romfs_img
    start = romfs_img.RomfsImage(al / 'probe.std').span('b.bin')[0]
    (al / 'r/a.bin').write_bytes(b'a' * (16 + (-start) % G))
    (al / 'x').mkdir(); ok = build(al / 'r', al / 'x/romfs.std')
    got_start = romfs_img.RomfsImage(al / 'x/romfs.std').span('b.bin')[0]
    with romfs_list.map_file(al / 'x/romfs/b.bin') as m:
        aligned = (got_start % G == 0, len(m) == len(body), m[:] == body, m.rfind(body[-4:]))
    ck(ok and aligned == (True, True, True, len(body) - 4), f'① map_file 对齐分支（数据起点 {got_start:#x} 按 {G:#x} 对齐 → 直接映射镜像那一段）：长度 / 全文 / rfind = 夹具')
    # 不对齐分支（#1439）：不拷进匿名映射，按下方对齐处映射镜像、平移下标（文件映射、零拷贝）。期望全按夹具 body 手算
    import re as _re, struct as _st
    (al / 'r/a.bin').write_bytes(b'a' * (16 + (-start) % G + 16))
    (al / 'u').mkdir(); oku = build(al / 'r', al / 'u/romfs.std')
    us = romfs_img.RomfsImage(al / 'u/romfs.std').span('b.bin')[0]
    nb = len(body); pat = body[100:108]; at = body.find(pat); last = body.rfind(body[-4:])
    with romfs_list.map_file(al / 'u/romfs/b.bin') as m:
        kind = type(m).__name__
        got = (len(m), m[:] == body, m[0] == body[0], m[-1] == body[-1], m[5:9] == body[5:9], m[::7] == body[::7], m[nb + 10:] == b'',
               m.find(pat) == at, m.find(pat, at + 1) == body.find(pat, at + 1), m.find(body[:4], 1, 50) == body.find(body[:4], 1, 50),
               m.rfind(body[-4:]) == last, _st.unpack_from('<Q', m, 3) == _st.unpack_from('<Q', body, 3),
               (_re.search(_re.escape(pat), m).start() if _re.search(_re.escape(pat), m) else None) == _re.search(_re.escape(pat), body).start(),
               bytes(memoryview(m)) == body, m.size() == nb)
    ck(oku and us % G != 0 and kind == ('_ImageSpan' if sys.version_info >= (3, 12) else 'mmap') and all(got[1:]) and got[0] == nb and m.closed,
       f'① map_file 不对齐分支（数据起点 {us:#x} 不按 {G:#x} 对齐）：文件映射视图、不拷贝；长度 / 下标 / 切片 / find / rfind / struct / 正则 / memoryview = 夹具，with 后关闭（{kind}，{got}）')

    # ② host_decoder
    hd_d, hd_i = attempt(lambda: host_decoder.need([str(rd)])), attempt(lambda: host_decoder.need([str(ri)]))
    # 条目顺序：目录形态是 scandir 顺序（随文件系统），镜像形态按路径字节序——比集合
    ck(isinstance(hd_i, list) and sorted(hd_d) == sorted(hd_i) and len(hd_i) == 6 and not any(x.startswith('lone/') for x in hd_i), f'② host_decoder.need 两形态同一组原因、6 条、孤立 .trpfs 不算（镜像 {len(hd_i)} 条）')

    # ③ nro_to_nso
    def run(args):
        return subprocess.run([sys.executable, *map(str, args)], capture_output=True)
    def tree(p):
        return {str(q.relative_to(p)): q.read_bytes() for q in sorted(Path(p).rglob('*')) if q.is_file()}
    rn = [run([R / 'runtime/rewriter/nro_to_nso.py', r, T / f'nso_{n}']) for n, r in (('d', rd), ('i', ri))]
    sha = lambda b: hashlib.sha256(b).hexdigest()
    want = (f'nro0\t{sha(A)}\t0x3000\t0x1000\ta/x.nro|b/X.NRO\nnro1\t{sha(Z)}\t0x3000\t0x1000\tz.nro\n'
            f'nro2\t{sha(HID)}\t0x3000\t0x1000\tdata/big.arc@{HID_AT:#x}\n')
    got = ''.join(l for l in (rb(T / 'nso_i/nro_modules.tsv') or b'').decode().splitlines(True) if not l.startswith('#'))
    ck([r.returncode for r in rn] == [0, 0] and tree(T / 'nso_d') == tree(T / 'nso_i') and got == want,
       f'③ nro_to_nso 两形态输出逐字节相同、nro_modules.tsv = 手算（藏在 data/big.arc@{HID_AT:#x}）')

    # ④ nro_exports / glslc_offline / gfx_api
    rx = [run([R / 'tools/nro_exports.py', r, T / f'exp_{n}.tsv']) for n, r in (('d', rd), ('i', ri))]
    rows = sorted(l.split('\t') for l in (rb(T / 'exp_i.tsv') or b'').decode().splitlines() if not l.startswith('#'))
    ck([r.returncode for r in rx] == [0, 0] and rb(T / 'exp_d.tsv') == rb(T / 'exp_i.tsv')
       and rows == sorted([n, f] for n in EXPORTS for f in ('a/x.nro', 'b/X.NRO', 'z.nro')), '④ nro_exports 两形态相同、导出 = 夹具名')
    import glslc_offline, gfx_api
    want_nros = sorted([('/' + k.replace('/', os.sep), v) for k, v in FILES.items() if v[0x10:0x14] == b'NRO0'])
    ck(attempt(lambda: glslc_offline.romfs_nros(str(D))) == attempt(lambda: glslc_offline.romfs_nros(str(I))) == want_nros, '④ glslc_offline.romfs_nros 两形态 = 夹具里头 +0x10 是 NRO0 的文件全文')
    gn_d, gn_i = attempt(lambda: list(gfx_api.romfs_nros(str(rd)))), attempt(lambda: list(gfx_api.romfs_nros(str(ri))))
    ck(isinstance(gn_i, list) and gn_d == gn_i and sorted(p for p, _ in gn_i) == sorted([os.path.join('a', 'x.nro'), os.path.join('b', 'X.NRO'), 'z.nro']), '④ gfx_api.romfs_nros 两形态相同、三个 NRO')
    ck((attempt(lambda: gfx_api.romfs_glsl(str(rd))), attempt(lambda: gfx_api.romfs_glsl(str(ri)))) == (1, 1), '④ gfx_api.romfs_glsl 有 #version → 两形态都 1')
    (T / 'ng').mkdir(); (T / 'ng/romfs').mkdir(); (T / 'ng/romfs/x.bin').write_bytes(b'#versio n' * 9); build(T / 'ng/romfs', T / 'ng/r2.std')
    ck((gfx_api.romfs_glsl(str(T / 'ng/romfs')), gfx_api.romfs_glsl(str(T / 'ng/r2'))) == (0, 0), '④ gfx_api.romfs_glsl 没有 #version → 两形态都 0')

    # ⑤ resource_input_key
    import resource_input_key as rik
    B = rik.BLOCK
    def dig(b): return hashlib.sha256(b if len(b) <= 2 * B else b[:B] + b[-B:]).hexdigest()
    h = hashlib.sha256(b's2arm-resource-inputs-v1\0'); h.update(hashlib.sha256((D / 'exefs/main').read_bytes()).digest())
    for k in sorted(FILES, key=lambda k: os.fsencode('romfs/' + k)):
        rel = os.fsencode('romfs/' + k); h.update(len(rel).to_bytes(8, 'little') + rel + len(FILES[k]).to_bytes(8, 'little') + bytes.fromhex(dig(FILES[k])))
    kd, ki = attempt(lambda: rik.resource_key(D)), attempt(lambda: rik.resource_key(I))
    reads = []; real = rik.read_digest
    rik.read_digest = lambda *a: reads.append(a) or real(*a)
    try: ki2 = attempt(lambda: rik.resource_key(I))
    finally: rik.read_digest = real
    ck(kd == ki == h.hexdigest()[:16], f'⑤ resource_key 两形态 = 手算（{ki}）')
    ck(ki2 == ki == h.hexdigest()[:16] and not reads, '⑤ 镜像形态重算：签名对得上、命中缓存，不再读内容')

    # ⑥ 改写键
    h = hashlib.sha256(b'rewrite-inputs-v1\0')
    for rel, b in sorted([('exefs/main', (D / 'exefs/main').read_bytes())] + [('romfs/' + k, v) for k, v in FILES.items() if k.lower().endswith(('.nro', '.nrr'))],
                         key=lambda x: os.fsencode(x[0])):
        r_ = os.fsencode(rel); h.update(len(r_).to_bytes(8, 'little') + r_ + hashlib.sha256(b).digest())
    ck(attempt(lambda: stages.rewrite_inputs(D)) == attempt(lambda: stages.rewrite_inputs(I)) == h.hexdigest(), '⑥ 改写键两形态 = 手算（exefs + RomFS .nro / .nrr）')

    # ⑦ spirv_msl / ui_lyt / 格式库
    import spirv_msl
    sd, si = list(spirv_msl.spirv_files(str(rd))), list(spirv_msl.spirv_files(str(ri)))
    ck([os.path.relpath(p, rd) for p in sd] == [os.path.relpath(p, ri) for p in si] == ['shaders' + os.sep + 'v.spv']
       and romfs_list.read_file(si[0]) == FILES['shaders/v.spv'], '⑦ spirv_msl.spirv_files 两形态同一份、按路径读 = 夹具')
    ul = [run([R / 'graphics/widen/scan/ui_lyt.py', r, T / f'ui_{n}', 2346, 'Layout']) for n, r in (('d', rd), ('i', ri))]
    ck(ul[0].returncode == ul[1].returncode and ul[0].stdout == ul[1].stdout and b'\xe5\x8c\x85 1 \xe4\xb8\xaa' in ul[1].stdout and tree(T / 'ui_d') == tree(T / 'ui_i'),
       f'⑦ ui_lyt 两形态日志 / 覆盖层逐字节相同、认到 1 个包（rc {ul[0].returncode} / {ul[1].returncode}）')
    import unreal_pak, re_pak
    ck([attempt(lambda: unreal_pak.is_pak(str(r / 'Game/Paks/a.pak'))) for r in (rd, ri)] == [True, True] and [attempt(lambda: re_pak.is_pak(str(r / 're/re_chunk_000.pak'))) for r in (rd, ri)] == [True, True]
       and [unreal_pak.is_pak(str(r / 'z.nro')) for r in (rd, ri)] == [False, False], '⑦ unreal_pak / re_pak 按路径认头两形态同真假')
print(f'RomFS 读取方镜像对拍单测：{"全通" if not bad else f"{bad} 项不通"}'); sys.exit(1 if bad else 0)
