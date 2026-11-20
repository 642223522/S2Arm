#!/usr/bin/env python3
# 拉取式顶点输入变体 <键>_bp（S2A.Dsh DshPull，graphics/tools/direct/dsh/Pull.cs，照上游参考实现（MIT）dmsh_pull；经 dsh_cmp --fn vs_pull 调（dshfn.py））。
# 期望按契约手写（布局块 dm_vlayout 在顶点缓冲槽 16：16 个流 {base, stride, divisor} + 32 个 NVN 属性状态字 = 格式 8 位 | 偏移 19 位 << 8 | 流号 5 位 << 27）：
#   ① 形状：main0_in 去掉 [[attribute]]、入口去掉 [[stage_in]]、末尾加 constant dm_vlayout& dm_lay [[buffer(16)]] 与缺的 [[vertex_id]] / [[instance_id]] / [[base_instance]]，
#      入口开头逐输入 in.m = as_type<T>(dm_fetch(dm_lay, 属性号u, 顶点号, 实例号, 起始实例))（已有的内建参数沿用原名）；前导紧跟 using namespace metal;；
#      只留 main0 / main0_z（几何抓取、层入口等去掉）；反射 {entry, entry_z（有才有）, slot 16, inputs}；带逗号的模板参数不被切开
#   ② 认不出的形状各返回原因、不出变体：没有 main0_in、槽 16 已占、输入不是 float4 / uint4 / int4 m_N [[attribute(n)]]、属性号 ≥ 32、main0 签名认不出、没有 using namespace metal;
#   ③ 前导里的格式表 dm_ftab 非 0 的格式 = 宿主 nvn_mtl.m vfmt 认得的格式（手数 76 个：0x01–0x30 共 48、10:10:10:2 两种 0x3D / 0x69、R11G11B10F 0x3F、BGRA8 0x9A、整数读成浮点 0x51–0x68 共 24）
#   ④ GPU（t_vs_pull_run.m，宿主 vfmt / vconv_i2f 从 nvn_mtl.m 原样摘出编进去）：每个格式拉取读出的寄存器字 = Metal 顶点描述抓取（整数读成浮点的 = 同布局整数抓取再转浮点）；
#      跨距 0 / 除数 1–3 配起始实例 5 = Metal 的步进且 = 手写元素号；基址未 4 字节对齐（低位并进偏移）= 对齐拷贝的 Metal 抓取；端到端原样 vs 变体着色器写出的输入逐字相同，库里只有 main0 / main0_z
#   ⑤（带 --dsx <libdsx> 才跑，tests/vs_pull_pack_test.sh 先编 libdsx 再调）：合成 NVN2 顶点着色器按出包翻译（PackOut）真出 _bp.json / _bp.metal，反射 = {main0, main0_z, 16, [0]}、按出包 Mac 参数编得过
# 反证：原样 MSL 里有 [[stage_in]]、没有 dm_fetch；把前导里一个格式的表项改成 0 → ④ 该格式不再相同（--self-check 跑，门禁不跑）。用法：t_vs_pull.py
import os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__)); R = os.path.abspath(os.path.join(HERE, '../../../..')); sys.path.insert(0, HERE); import dshfn
HOST = os.path.join(R, 'graphics/nvn/gfx/nvn/nvn_mtl.m')
HEAD = '#include <metal_stdlib>\n#include <simd/simd.h>\n\nusing namespace metal;\n\n'
OUT = 'struct main0_out\n{\n    float4 gl_Position [[position, invariant]];\n    float gl_PointSize [[point_size]];\n};\n\n'
VS = (HEAD + OUT + 'struct main0_in\n{\n    float4 m_0 [[attribute(0)]];\n    uint4 m_3 [[attribute(5)]];\n    int4 m_7_1 [[attribute(31)]];\n};\n\n'
      'static inline float4 helper(float4 x)\n{\n    return x * 2.0;\n}\n\n'
      'vertex main0_out main0(main0_in in [[stage_in]], constant float4& s2a_push [[buffer(13)]], texture2d<float, access::read> t0 [[texture(0)]])\n{\n'
      '    main0_out out = {};\n    out.gl_Position = helper(in.m_0) + float4(in.m_3) + float4(in.m_7_1) + s2a_push;\n    return out;\n}\n\n'
      'vertex main0_out main0_z(main0_in in [[stage_in]], constant float4& s2a_push [[buffer(13)]], texture2d<float, access::read> t0 [[texture(0)]])\n{\n'
      '    main0_out out = {};\n    out.gl_Position = in.m_0;\n    return out;\n}\n\n'
      'vertex void main0_gs(main0_in in [[stage_in]], uint dm_vid [[vertex_id]], device float4* dm_gs [[buffer(13)]])\n{\n    dm_gs[dm_vid] = in.m_0;\n}\n\n')
# 已有内建参数、没有 main0_z
VS2 = (HEAD + OUT + 'struct main0_in\n{\n    float4 m_2 [[attribute(2)]];\n};\n\n'
       'vertex main0_out main0(main0_in in [[stage_in]], uint gl_VertexIndex [[vertex_id]], uint gl_InstanceIndex [[instance_id]], uint gl_BaseInstance [[base_instance]])\n{\n'
       '    main0_out out = {};\n    out.gl_Position = in.m_2 * float(gl_VertexIndex + gl_InstanceIndex + gl_BaseInstance);\n    return out;\n}\n\n')
# 端到端（④）：原样与变体各写出自己读到的输入；main0 带全部内建参数、main0_z 只带顶点号与实例号（变体补起始实例）、几何抓取入口应被去掉
E2E = (HEAD + OUT + 'struct main0_in\n{\n    float4 m_0 [[attribute(0)]];\n    uint4 m_5 [[attribute(5)]];\n    int4 m_20 [[attribute(20)]];\n};\n\n'
       'vertex main0_out main0(main0_in in [[stage_in]], device uint4* dbg [[buffer(1)]], uint gl_VertexIndex [[vertex_id]], uint gl_InstanceIndex [[instance_id]], uint gl_BaseInstance [[base_instance]])\n{\n'
       '    main0_out out = {};\n    uint i = ((gl_InstanceIndex - gl_BaseInstance) * 6u + gl_VertexIndex) * 3u;\n'
       '    dbg[i] = as_type<uint4>(in.m_0);\n    dbg[i + 1u] = in.m_5;\n    dbg[i + 2u] = as_type<uint4>(in.m_20);\n'
       '    out.gl_Position = float4(0.0, 0.0, 0.0, 1.0);\n    out.gl_PointSize = 1.0;\n    return out;\n}\n\n'
       'vertex main0_out main0_z(main0_in in [[stage_in]], device uint4* dbg [[buffer(1)]], uint vid [[vertex_id]], uint iid [[instance_id]])\n{\n'
       '    main0_out out = {};\n    uint i = ((iid - 3u) * 6u + vid) * 3u;\n'
       '    dbg[i] = as_type<uint4>(in.m_0);\n    dbg[i + 1u] = in.m_5;\n    dbg[i + 2u] = as_type<uint4>(in.m_20);\n'
       '    out.gl_Position = float4(0.0, 0.0, 0.5, 1.0);\n    out.gl_PointSize = 1.0;\n    return out;\n}\n\n'
       'vertex void main0_gs(main0_in in [[stage_in]], uint dm_vid [[vertex_id]], device uint4* dm_gs [[buffer(13)]])\n{\n    dm_gs[dm_vid] = in.m_5;\n}\n\n')
BAD = {
    'no stage input': HEAD + OUT + 'vertex main0_out main0()\n{\n    main0_out out = {};\n    return out;\n}\n\n',
    'buffer 16 is taken': VS2.replace('uint gl_VertexIndex [[vertex_id]]', 'constant float4& x [[buffer(16)]], uint gl_VertexIndex [[vertex_id]]'),
    'an input declaration not understood: float3 m_2 [[attribute(2)]];': VS2.replace('float4 m_2 [[attribute(2)]]', 'float3 m_2 [[attribute(2)]]'),
    'an input at attribute 32 or above': VS2.replace('[[attribute(2)]]', '[[attribute(32)]]'),
    'main0 signature not recognized': VS2.replace('vertex main0_out main0(', 'vertex main0_out main1('),
    'no "using namespace metal;"': VS2.replace('using namespace metal;', 'using metal::float4;'),
}
fails = []
def ck(what, cond):
    print(('✓ ' if cond else '✗ ') + what)
    if not cond: fails.append(what)

cases = [VS, VS2, E2E] + list(BAD.values())
r = dshfn.batch([('vs_pull', [s]) for s in cases])
if any('ok' not in x for x in r): print('✗ dsh_cmp --fn vs_pull 报错：', [x.get('err') for x in r]); sys.exit(1)
(a, ai), (b, bi), (e, ei) = (x['ok'] for x in r[:3])

# ① 形状
LAY = 'constant dm_vlayout& dm_lay [[buffer(16)]]'
ck('① 反射：entry main0、entry_z main0_z、slot 16、inputs [0, 5, 31]', ai == {'entry': 'main0', 'entry_z': 'main0_z', 'slot': 16, 'inputs': [0, 5, 31]})
ck('① main0_in 去掉 [[attribute]]', '\nstruct main0_in\n{\n    float4 m_0;\n    uint4 m_3;\n    int4 m_7_1;\n};' in a and '[[attribute(' not in a)
ck('① 入口去掉 [[stage_in]]，带逗号的模板参数原样，末尾加布局块与三个内建参数',
   '\nvertex main0_out main0(constant float4& s2a_push [[buffer(13)]], texture2d<float, access::read> t0 [[texture(0)]], ' + LAY
   + ', uint dm_vid [[vertex_id]], uint dm_iid [[instance_id]], uint dm_bi [[base_instance]])\n{\n' in a and '[[stage_in]]' not in a)
pro = ('    main0_in in;\n    in.m_0 = as_type<float4>(dm_fetch(dm_lay, 0u, dm_vid, dm_iid, dm_bi));\n    in.m_3 = as_type<uint4>(dm_fetch(dm_lay, 5u, dm_vid, dm_iid, dm_bi));\n'
       '    in.m_7_1 = as_type<int4>(dm_fetch(dm_lay, 31u, dm_vid, dm_iid, dm_bi));\n    main0_out out = {};\n')
ck('① main0 / main0_z 开头逐输入读（属性号 0 / 5 / 31），本体接着原样', a.count(pro) == 2 and '    out.gl_Position = helper(in.m_0) + float4(in.m_3) + float4(in.m_7_1) + s2a_push;\n    return out;\n}' in a)
ck('① 几何抓取入口 main0_gs 去掉，辅助函数留着', 'main0_gs' not in a and 'static inline float4 helper(float4 x)' in a)
ck('① 前导紧跟 using namespace metal;（布局块结构与 dm_fetch）',
   a.startswith(HEAD.rstrip('\n') + '\n\n// Vertex pulling') and 'struct dm_vstream { device const uchar *base; uint stride; uint divisor; };\nstruct dm_vlayout { dm_vstream s[16]; uint attr[32]; };' in a
   and 'static inline uint4 dm_fetch(constant dm_vlayout &L, uint a, uint vid, uint iid, uint bi) {' in a and a.index('dm_fetch(constant') < a.index('struct main0_out'))
ck('① 已有内建参数沿用原名、只加布局块；没有 main0_z → 反射不带 entry_z',
   bi == {'entry': 'main0', 'slot': 16, 'inputs': [2]}
   and '\nvertex main0_out main0(uint gl_VertexIndex [[vertex_id]], uint gl_InstanceIndex [[instance_id]], uint gl_BaseInstance [[base_instance]], ' + LAY + ')\n{\n'
       '    main0_in in;\n    in.m_2 = as_type<float4>(dm_fetch(dm_lay, 2u, gl_VertexIndex, gl_InstanceIndex, gl_BaseInstance));\n' in b)
ck('① 端到端那支：main0_z 只补起始实例', '\nvertex main0_out main0_z(device uint4* dbg [[buffer(1)]], uint vid [[vertex_id]], uint iid [[instance_id]], ' + LAY + ', uint dm_bi [[base_instance]])\n{\n' in e
   and ei == {'entry': 'main0', 'entry_z': 'main0_z', 'slot': 16, 'inputs': [0, 5, 20]})
ck('① 再变一次：槽 16 已被布局块占了 → 不出（不会叠两层）', dshfn.fn('vs_pull', a) == [None, 'buffer 16 is taken'])
ck('反证：原样 MSL 有 [[stage_in]]、没有 dm_fetch', '[[stage_in]]' in VS and 'dm_fetch' not in VS)

# ② 认不出的形状
for (why, _), res in zip(BAD.items(), r[3:]):
    v, info = res['ok']
    ck(f'② {why} → 不出变体、原因如期（{info}）', v is None and info == why)

# ③ 格式表 vs 宿主 vfmt
pre = a.split('using namespace metal;\n\n', 1)[1].split('\nstruct main0_out', 1)[0]
tab = re.search(r'constant uchar dm_ftab\[256\] = \{(.*?)\};', pre, re.S)
ftab = [int(x) for x in tab.group(1).replace('\n', ' ').split(',') if x.strip()] if tab else []
ck(f'③ dm_ftab 256 项（{len(ftab)}）', len(ftab) == 256)
want76 = set(range(0x01, 0x31)) | {0x3D, 0x69, 0x3F, 0x9A} | set(range(0x51, 0x69))
ck(f'③ dm_ftab 非 0 的格式 = 手数的 76 个（{len([f for f in range(256) if ftab and ftab[f]])}）', {f for f in range(256) if ftab and ftab[f]} == want76)

src = open(HOST).read()
def fn_text(sig):
    m = re.search(re.escape(sig) + r'.*?\n\}\n', src, re.S)
    return m.group(0) if m else None
i2f, vf = fn_text('static int vconv_i2f(int f, int *bits, int *sgn) {'), fn_text('static MTLVertexFormat vfmt(int f) {')
if not i2f or not vf: print('✗ nvn_mtl.m 里找不到 vconv_i2f / vfmt'); sys.exit(1)

def gpu(prelude, tag):
    with tempfile.TemporaryDirectory(prefix='t_vs_pull_') as t:
        h = os.path.join(t, 'host_vfmt.h'); open(h, 'w').write('#import <Metal/Metal.h>\n' + i2f + vf)
        exe = os.path.join(t, 'run')
        c = subprocess.run(['clang', '-fobjc-arc', '-Wno-unused-function', '-include', h, '-framework', 'Metal', '-framework', 'Foundation', '-o', exe, os.path.join(HERE, 't_vs_pull_run.m')], capture_output=True, text=True)
        if c.returncode: print(f'✗ t_vs_pull_run 编不过（{tag}）：' + c.stderr[-600:]); sys.exit(1)
        fp, fo, fv = (os.path.join(t, n) for n in ('prelude.metal', 'orig.metal', 'var.metal'))
        open(fp, 'w').write(prelude); open(fo, 'w').write(E2E); open(fv, 'w').write(e)
        o = subprocess.run([exe, fp, fo, fv], capture_output=True, text=True)
        return o.returncode, o.stdout, o.stderr

if '--self-check' in sys.argv:   # 反证：表里 RGBA8 unorm（0x25）改成 0 → 拉取读零，该格式不再相同
    broke = pre.replace('\n     54,  70,  90,  58,  74,  19,  35,  51,  67,  87,  23,  39,  55,  71,  91,  59,\n', '\n     54,  70,  90,  58,  74,   0,  35,  51,  67,  87,  23,  39,  55,  71,  91,  59,\n')   # 第 3 行 = 格式 0x20–0x2F，第 6 项 = 0x25
    rc, out, err = gpu(broke, '反证')
    ck('反证：dm_ftab[0x25] 改成 0 → 0x25 的比较不同、退出非 0', broke != pre and rc != 0 and 'format 0x25' in err)
else:
    rc, out, err = gpu(pre, '正式')
    fm = re.search(r'^FMT((?: \d+)*)$', out, re.M); got = {int(x) for x in fm.group(1).split()} if fm else set()
    ck(f'④ 宿主 vfmt 认得的格式 = dm_ftab 非 0 的格式（{len(got)} 个）', got == want76)
    m1 = re.search(r'CHECK formats (\d+), Metal fetch comparisons (\d+), of them integer-as-float (\d+)', out)
    # 比较次数手数：76 个格式各 1 遍；8 位分量的另在 2 字节偏移 1 遍：0x01–0x04、0x0D–0x10、0x19–0x1C、0x25–0x28、0x9A 共 17 个，加整数读成浮点里 8 位的
    #   0x51 / 0x52 / 0x57 / 0x58 / 0x5D / 0x5E / 0x63 / 0x64 共 8 个；1 字节元素（0x01–0x04、0x51 / 0x52 共 6 个）另跨距 1 一遍 → 76 + 25 + 6 = 107；其中整数读成浮点 24 + 8 + 2 = 34
    ck(f'④ 每个格式都比了（{m1.group(0) if m1 else "无输出"}）', bool(m1) and (m1.group(1), m1.group(2), m1.group(3)) == ('76', '107', '34'))
    m2 = re.search(r'CHECK step (\d+)', out); m3 = re.search(r'CHECK unaligned (\d+)', out)
    ck(f'④ 跨距 0 / 除数 1–3 × 7 个实例都比了（{m2.group(1) if m2 else "无"} / 28）', bool(m2) and m2.group(1) == '28')
    ck(f'④ 基址 +1 / +2 / +3 × 5 种格式都比了（{m3.group(1) if m3 else "无"} / 15）', bool(m3) and m3.group(1) == '15')
    ck('④ 变体库里只有 main0 / main0_z（另加测试的片元函数）', 'CHECK variant functions main0,main0_z,t_frag' in out)
    ck('④ 端到端 main0 / main0_z 写出的输入逐字相同', out.count(' differ\n') == 2 and re.search(r'CHECK e2e main0 288 words, 0 differ', out) and re.search(r'CHECK e2e main0_z 288 words, 0 differ', out))
    last = re.search(r't_vs_pull_run: (\d+) checks, (\d+) failed', out)
    ck(f'④ GPU 逐项全过（{last.group(0) if last else "无末行"}；退出 {rc}）', rc == 0 and bool(last) and last.group(2) == '0')
    if rc: print(err[-1500:])
if '--dsx' in sys.argv:   # ⑤ 出包那条路（DshCompiler.Compile 开 PackOut，经 dsh_cmp --fn ampere_compile_pack；要 libdsx，由 tests/vs_pull_pack_test.sh 先编好再带路径来）
    import json; sys.path.insert(0, HERE); import t_vs_int_inputs as V   # 合成 NVN2 顶点着色器：只读属性 0（ALD a[0x80..0x84]），写位置与输出 0
    st, code, ctl = V.SYN
    pr = dshfn.batch([('ampere_compile_pack', [st, code.hex(), ctl.hex()])], dsx=sys.argv[sys.argv.index('--dsx') + 1])[0]
    pb, pv, pj = pr['ok'] if 'ok' in pr and isinstance(pr['ok'], list) and len(pr['ok']) == 3 else (None, None, None)
    ck(f'⑤ 出包翻译真出了 _bp.json：pull = {{entry main0, entry_z main0_z, slot 16, inputs [0]}}（{json.dumps(json.loads(pj)) if pj else pj}）', bool(pj) and json.loads(pj) == {'pull': {'entry': 'main0', 'entry_z': 'main0_z', 'slot': 16, 'inputs': [0]}})
    ck('⑤ _bp.metal：两个入口各带布局块、读属性 0，没有 [[stage_in]] 与几何抓取入口；_b.metal 原样带 [[stage_in]] 与 main0_gs（反证）',
       bool(pv) and pv.count(LAY) == 2 and pv.count('(dm_fetch(dm_lay, 0u, ') == 2 and '[[stage_in]]' not in pv and 'main0_gs' not in pv
       and bool(pb) and '[[stage_in]]' in pb and 'vertex void main0_gs(' in pb)
    with tempfile.TemporaryDirectory(prefix='t_vs_pull_p_') as t:
        f = os.path.join(t, 'bp.metal'); open(f, 'w').write(pv or '')
        c = subprocess.run(['xcrun', '-sdk', 'macosx', 'metal', '-c', '-w', '-O1', '-fwrapv', '-fmetal-math-mode=relaxed', '-fpreserve-invariance', '-mmacosx-version-min=15.0', f, '-o', f + '.air'], capture_output=True, text=True)
        ck(f'⑤ _bp.metal 按出包 Mac 编译参数编得过（退出 {c.returncode}{"：" + c.stderr[-200:] if c.returncode else ""}）', bool(pv) and c.returncode == 0)
print(('✓ t_vs_pull：全过' if not fails else f'✗ t_vs_pull：{len(fails)} 项不符'))
sys.exit(1 if fails else 0)
