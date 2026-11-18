#!/usr/bin/env python3
"""直连抽取（translator/shader_split.py）与 GL 着色器源（translator/gl_shaders.py + mvgl.py）读 RomFS「目录形态 vs 镜像形态」对拍（python3 tests/romfs_split_gl_img_test.py；tests/romfs_img_test.sh 调）。
起因（11-16 RomFS 不落散文件端到端）：开关开时 shader_split 逐个文件 open(path) 读不到镜像里的文件，scan_counted 当「读不了的文件」整份跳过（一款 3.5 GB 的款跳过 19012 个），
直连库键数靠 S2Arm 抽取补齐、看不出来，但 shader_pairs / shader_facts / shader_map 只剩 main 里的那点（pairs 307616 → 1684 字节）；gl_shaders 见 romfs/ 不在直接报「输入路径不存在」。
夹具同 tests/romfs_readers_img_test.py：目录形态 = romfs/ 散文件；镜像形态 = 同内容 services/romfs_index --std 建 romfs.std、romfs/ 不在。期望按夹具手写：
  ① shader_split.scan_counted：没有着色器的普通文件 → (相对路径, {}, 空, {}, [])；Yaz0 包、zstd 字典判断（.data 旁有 .dict 跳过）两形态同；FILE_RED 0 条。
     负对照：路径不在（盘上、镜像里都没有）→ 记 FILE_RED 一条（证明「读不到」确实会被记成跳过、本测能看出来）
  ② shader_split.map_big：镜像里的文件映射出的字节 = 夹具；`in` 按子串判（Mapped 语义）
  ③ gl_shaders.sources：RomFS 里 shaders/a.vert、shaders/b.frag 两支 → (源码文本, 阶段, /相对路径) = 夹具手写；两形态逐项相同
  ④ mvgl.Archive：手写最小 MDB1 档（1 个条目 x_vp.shad，不压缩）→ files 与 read 两形态同 = 夹具
要 dotnet 编 services/romfs_index；没有 dotnet 时整份跳过并打印原因，退出 0"""
import os, shlex, shutil, struct, subprocess, sys, tempfile
from pathlib import Path

R = Path(__file__).resolve().parents[1]
os.environ['S2A_ROMFS_WALK'] = 'off'
os.environ.setdefault('DM_GAME', '010015100B514000')   # shader_split 导入时按配置档选读法；夹具只有普通文件，选哪款都一样
for d in ('graphics/nvn/tools', 'translator'):
    sys.path.insert(0, str(R / d))
import romfs_list   # noqa: E402

bad = 0
def ck(ok, msg):
    global bad
    print(('通 ' if ok else '不通 ') + msg); bad += 0 if ok else 1


def romfs_index_cmd(t):   # 同 tests/romfs_readers_img_test.py
    dotnet = shutil.which('dotnet') or (os.path.join(os.environ['DOTNET_ROOT'], 'dotnet') if os.environ.get('DOTNET_ROOT') else None)
    if not dotnet: return None, '没有 dotnet'
    out = os.path.join(t, 'ri')
    r = subprocess.run([dotnet, 'build', str(R / 'services/romfs_index'), '-c', 'Release', '-o', out], capture_output=True, text=True)
    if r.returncode: return None, '编 services/romfs_index 失败：' + r.stdout[-300:]
    return f'{shlex.quote(dotnet)} {shlex.quote(os.path.join(out, "romfs_index.dll"))}', ''


def mvgl_archive(name, data):
    """最小 MDB1 档（translator/mvgl.py 读法）：头 'MDB1' u16 树项数 u16 名字数 u32 数据项数 u32 数据起点 u32 数据总长；
    树项 8 字节 × 1、名字 0x40 字节 × 1（4 字节扩展名 + 60 字节名）、数据项 12 字节 × 1（u32 偏移 u32 长度 u32 存储长度），数据在后"""
    stem, ext = name.rsplit('.', 1)
    head_len = 0x14 + 8 + 0x40 + 12
    nm = ext.encode().ljust(4, b' ') + stem.encode().ljust(60, b'\0')
    return (b'MDB1' + struct.pack('<HHIII', 1, 1, 1, head_len, len(data)) + struct.pack('<HHHH', 0, 0, 0, 0) + nm
            + struct.pack('<III', 0, len(data), len(data)) + data)


VERT = b'#version 330\nvoid main() { gl_Position = vec4(0.0); }\n'
FRAG = b'#version 330\nout vec4 c; void main() { c = vec4(1.0); }\n'
FILES = {
    'shaders/a.vert': VERT,
    'shaders/b.frag': FRAG,
    'Model/plain.bin': b'no shader here ' * 40,
    'Pack/x.szs': b'Yaz0' + struct.pack('>I', 4) + b'\0' * 8 + b'\xf0ABCD',   # Yaz0：4 字节全字面量
    'Data/s.data': b'DATA' * 8, 'Data/s.dict': b'DICT' * 8,   # .data 旁有 .dict：交给 nlg 读，自己跳过
    'big/huge.bin': b'H' * 4096 + b'NEEDLE' + b'H' * 4096,
}

with tempfile.TemporaryDirectory(prefix='romfs split gl img ') as t:
    T = Path(t)
    cmd, why = romfs_index_cmd(t)
    if not cmd:
        print(f'跳过：{why}'); sys.exit(0)
    D, I = T / 'd', T / 'i'
    for k, v in FILES.items():
        p = D / 'romfs' / k; p.parent.mkdir(parents=True, exist_ok=True); p.write_bytes(v)
    (D / 'romfs' / 'mv').mkdir(); (D / 'romfs' / 'mv/a.mvgl').write_bytes(mvgl_archive('x_vp.shad', VERT))
    I.mkdir(); (I / 'romfs.std').write_bytes(b'')
    r = subprocess.run(shlex.split(cmd) + ['--std', str(D / 'romfs'), '-', str(I / 'romfs.std'), '0'], capture_output=True, text=True)
    ck(r.returncode == 0 and romfs_list.image_of(I / 'romfs') is not None, '夹具建成镜像（romfs/ 不在、只有 romfs.std）')
    rd, ri = D / 'romfs', I / 'romfs'

    import shader_split as S
    # ① scan_counted
    def scan(root, rel):
        return S.scan_counted((os.path.join(root, rel), rel))
    for rel in ('Model/plain.bin', 'Pack/x.szs', 'Data/s.data', 'shaders/a.vert', 'big/huge.bin'):
        a, b = scan(rd, rel), scan(ri, rel)
        want = (rel, {}, set(), {}, [])
        ck(a == want and b == want, f'① scan_counted {rel}：目录 {a[1:] if a != want else "空"}，镜像 {b[1:] if b != want else "空"}（期望没有着色器、没有跳过）')
    neg = scan(ri, 'Model/missing.bin')
    ck(len(neg[4]) == 1 and neg[4][0][0] == S.FILE_RED, f'① 负对照：不在的文件记成跳过（FILE_RED）：{neg[4]}')

    # ② map_big
    m = S.map_big(os.path.join(ri, 'big/huge.bin'))
    ck(bytes(m[:]) == FILES['big/huge.bin'] and b'NEEDLE' in m and b'NOPE' not in m, f'② map_big 镜像里的文件 = 夹具、子串判对（{len(m)} 字节）')

    # ③ gl_shaders.sources（只取 shaders/ 与 mv/ 两处有源码的）
    import gl_shaders as G
    want = [(VERT.decode(), 'vert', '/shaders/a.vert'), (FRAG.decode(), 'frag', '/shaders/b.frag')]
    def srcs(root):
        try: return sorted((s if isinstance(s, str) else s.decode(), st, w) for s, st, w in G.sources([str(root)]) if not w.startswith('/mv/'))
        except Exception as e: return f'异常 {type(e).__name__}: {e}'
    a, b = srcs(rd), srcs(ri)
    ck(a == sorted(want) and b == a, f'③ gl_shaders.sources 两形态 = 夹具两支：目录 {a if a != sorted(want) else "对"}，镜像 {b if b != a else "同目录"}')

    # ④ mvgl
    import mvgl
    def arc(root):
        try: x = mvgl.Archive(os.path.join(root, 'mv/a.mvgl')); return sorted(x.files), x.read('x_vp.shad')
        except Exception as e: return f'异常 {type(e).__name__}: {e}'
    a, b = arc(rd), arc(ri)
    ck(a == (['x_vp.shad'], VERT) and b == a, f'④ mvgl.Archive 两形态 = 夹具：目录 {a if a != (["x_vp.shad"], VERT) else "对"}，镜像 {b if b != a else "同目录"}')

print('RomFS 镜像形态：直连抽取 / GL 源读取单测全过' if not bad else f'有 {bad} 项不通')
sys.exit(1 if bad else 0)
