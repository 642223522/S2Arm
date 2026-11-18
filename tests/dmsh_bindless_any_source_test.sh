#!/bin/bash
# 门禁覆盖：compat/tree/src/Ryujinx.Graphics.Shader/Translation/Optimizations/BindlessElimination.cs translator/dmsh_xlate/* translator/dmsh_xlate_bin/* tests/dmsh_bindless_any_source_test.sh
# 间接贴图：句柄来源追不到常量缓冲时不再删掉取样（约 3 秒）：bash tests/dmsh_bindless_any_source_test.sh [dmsh_xlate.dll]
# 共用翻译器 BindlessElimination 原先只给「常量缓冲 / 输入 / 存储缓冲读出的句柄」走整池数组，其余来源（句柄经过算术、共享内存、全局内存……）删掉取样、
#   结果填 0、记「Failed to find handle source for bindless access」——用到它的物体全黑。改后：宿主支持分离采样器时任何来源都走整池数组（贴图池 2^20、采样器池 2^12 两个数组，
#   下标 = 句柄低 20 位 / 高 12 位），置 0 分支只剩宿主不支持分离采样器。
# 合成片元着色器（Maxwell 编码按 compat/tree Decoders/InstTable.cs、InstDecoders.cs 手拼，不跑被测实现推期望）：
#   ① 句柄 = c[3][0] + 0x10（MOV R5, c[3][0]；IADD32I R4, R5, 0x10），TEX.B R0, R6, R4（2D，写 RGBA）→ 期望：备注里没有「Failed to find handle source」；
#      反射 textures 恰两项：贴图池数组 2^20、采样器池数组 2^12（采样器类型 None = 0；同 tests/dmsh_pool_arrays_test.sh 的池形状）；SPIR-V 里有取样指令（OpImageSampleExplicitLod 88 / ImplicitLod 87）
#   ② 对照：句柄直接是 c[3][0]（MOV R4, c[3][0]；TEX.B）→ 改前改后都走常量缓冲绑定：贴图 cbuf_slot 3、handle 0、数组 1，没有该备注
# 旧代码反证：传改动前的 dmsh_xlate.dll，① 必红（备注有「Failed to find handle source」、没有贴图、SPIR-V 没有取样），② 照常通。
set -u; H=$(cd "$(dirname "$0")/.." && pwd); PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}
[ -x "$PY" ] || PY=$(command -v python3) || { echo "dmsh_bindless_any_source_test：缺 Python，环境未就绪（退出 75）"; exit 75; }
DN=${DOTNET:-$HOME/.dotnet/dotnet}; [ -x "$DN" ] || DN=$(command -v dotnet) || { echo "dmsh_bindless_any_source_test：缺 dotnet，环境未就绪（退出 75）"; exit 75; }
DLL=${1:-$H/translator/dmsh_xlate_bin/dmsh_xlate.dll}
T=$(mktemp -d "${TMPDIR:-/tmp}/t_bindless_any.XXXXXX"); trap 'rm -rf "$T"' EXIT
"$PY" - "$T" "$DN" "$DLL" <<'PYEOF'
import json, os, struct, subprocess, sys
T, DN, DLL = sys.argv[1:4]
PT = 7
SCHED = 0x001F8000FC0007E0
EXIT = 0xE30000000007000F
def movc(rd, slot, word): return (0b0100110010011 << 51) | (0xF << 39) | (slot << 34) | (word << 20) | (PT << 16) | rd
def iadd32i(rd, ra, imm): return (0b0001110 << 57) | ((imm & 0xFFFFFFFF) << 20) | (PT << 16) | (ra << 8) | rd
def mov32i(rd, imm): return (0b000000010000 << 52) | ((imm & 0xFFFFFFFF) << 20) | (PT << 16) | (0xF << 12) | rd
def texb(rd, ra, rb): return (0b1101111010 << 54) | (PT << 51) | (0xF << 31) | (2 << 28) | (rb << 20) | (PT << 16) | (ra << 8) | rd   # 2D、WMask RGBA、Lodb 0
def frag(ops):
    sph = bytearray(0x50)
    struct.pack_into('<I', sph, 0, 2 | (3 << 5) | (5 << 10))   # SPH v3、片元
    struct.pack_into('<I', sph, 72, 0xF)                        # 目标 0 写 RGBA（R0..R3）
    ops = list(ops) + [EXIT]
    code = []
    while ops:
        grp, ops = ops[:3], ops[3:]
        code += [SCHED] + grp + [EXIT] * (3 - len(grp))
    return bytes(sph) + b''.join(struct.pack('<Q', w) for w in code)
cases = {
    'arith': frag([movc(5, 3, 0), iadd32i(4, 5, 0x10), mov32i(6, 0), mov32i(7, 0), texb(0, 6, 4)]),
    'cbuf':  frag([movc(4, 3, 0), mov32i(6, 0), mov32i(7, 0), texb(0, 6, 4)]),
}
jobs = []
for k, b in cases.items():
    p = os.path.join(T, k + '.bin'); open(p, 'wb').write(b)
    jobs.append({'key': k, 'stage': 'fs', 'code': p, 'tex': {}, 'img': {}, 'attr': {}, 'fout': {}, 'c1': '', 'debug': False})
json.dump(jobs, open(os.path.join(T, 'jobs.json'), 'w'))
r = subprocess.run([DN, DLL, os.path.join(T, 'jobs.json'), os.path.join(T, 'o')], capture_output=True, text=True)
bad = n = 0
def ck(ok, what):
    global bad, n
    n += 1; bad += 0 if ok else 1; print(('✓ ' if ok else '不通 ') + what)
ck(r.returncode == 0, f'两例都翻译成功（rc={r.returncode}，{(r.stdout + r.stderr).strip()[-200:]}）')
def res(k):
    try: return json.load(open(os.path.join(T, 'o', k + '.res.json')))
    except OSError: return None
def samples(k):
    try: s = open(os.path.join(T, 'o', k + '.spv'), 'rb').read()
    except OSError: return -1
    i, c = 20, 0
    while i + 4 <= len(s):
        w = struct.unpack_from('<I', s, i)[0]
        if (w & 0xFFFF) in (87, 88): c += 1
        i += max(1, w >> 16) * 4
    return c
FAIL = 'Failed to find handle source'
a = res('arith')
if a:
    lost = [x for x in a['notes'] if FAIL in x]
    ck(not lost, f'① 句柄经算术：没有「{FAIL}」备注（实得 {lost}）')
    tex = a['textures']
    got = sorted((t['array'], t['type'] == 0) for t in tex)
    ck(got == [(1 << 12, True), (1 << 20, False)], f'① textures 恰为贴图池 2^20 + 采样器池 2^12（实得 {[(t["cbuf_slot"], t["handle"], t["array"], t["type"]) for t in tex]}）')
    ck(samples('arith') >= 1, f'① SPIR-V 有取样指令（实得 {samples("arith")} 条）')
else: ck(False, '① 没有反射输出')
c = res('cbuf')
if c:
    ck(not [x for x in c['notes'] if FAIL in x], '② 对照（句柄就是 c[3][0]）：没有该备注')
    ck([(t['cbuf_slot'], t['handle'], t['array']) for t in c['textures']] == [(3, 0, 1)], f'② 对照走常量缓冲绑定 (3, 0, 1)（实得 {[(t["cbuf_slot"], t["handle"], t["array"]) for t in c["textures"]]}）')
else: ck(False, '② 没有反射输出')
print(f'dmsh_bindless_any_source_test：{n - bad}/{n} 通')
sys.exit(1 if bad else 0)
PYEOF
