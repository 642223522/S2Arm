#!/usr/bin/env python3
# 片元输出类型由函数常量选（#427；S2A.Dsh DshCompiler.FsFout，graphics/tools/direct/dsh/Dsh.cs，经 dsh_cmp --fn fs_fout 调）。期望按契约手写：
#   ① 改写：常量声明接在 FC_DECL（S2A_AT 那一行）末尾、同一行；每个浮点颜色输出 color(n) 改由 S2A_Fn 开关，旁加 <名>_s2u / <名>_s2i（S2A_Un / S2A_In），
#      输出 1 旁加 <名>_s2d [[color(0), index(1)]]（S2A_DUAL）、不写输出 1 的加恒 0 的 s2a_src1；每个 return out; 前按位取；再改一次不变；没有 FC_DECL 的 / 顶点原样
#   ② 成批合编（Unity.Src）：两支改过的片元拼一批，S2A_AT + 输出类型声明那一行只出现一次
#   ③ GPU（t_fout_fc_run）：单支与批里每个 main0 入口，按常量特化后建管线、画、读回 (1,1)。顶点给 (1.5, 2, 3, 0.25)，片元输出 0 = 它、输出 1 = 它的 wzyx。
#      期望（手算）：浮点 / 无符号 / 有符号画布读回的字都是同一组位 3fc00000 40000000 40400000 3e800000（输出 1：3e800000 40400000 40000000 3fc00000）；
#      双源（RGBA16Float，结果 = 源 0 × 源 1）= (0.375, 6, 6, 0.375) → 3600 4600 4600 3600，不写输出 1 的源 1 = 0 → 全 0；
#      无符号 + 透明测试 NEVER（S2A_AT=1）= 丢弃 → 清屏 0；ALWAYS + 多重采样关照写。
# 反证：不给常量的 main0 建不出无符号画布的管线（none_on_uint FAIL，即 #427 原先要现编变体的情形）。用法：t_fout_fc.py
import os, re, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__)); R = os.path.abspath(os.path.join(HERE, '../../../..')); sys.path.insert(0, HERE); import dshfn
sys.path.insert(0, os.path.join(R, 'translator')); import dsh_batch
HEAD = '#include <metal_stdlib>\n#include <simd/simd.h>\n\nusing namespace metal;\n\n'
FS = (HEAD + 'struct main0_out\n{\n    float4 m_0 [[color(0)]];\n    float4 m_1 [[color(1)]];\n};\n\nstruct main0_in\n{\n    float4 m_0 [[user(locn0)]];\n};\n\n'
      'fragment main0_out main0(main0_in in [[stage_in]])\n{\n    main0_out out = {};\n    if (in.m_0.x > 2.0)\n    {\n        out.m_0 = in.m_0 * 0.0;\n        return out;\n    }\n'
      '    out.m_0 = in.m_0;\n    out.m_1 = in.m_0.wzyx;\n    return out;\n}\n\n')
FS1 = FS.replace('    float4 m_1 [[color(1)]];\n', '').replace('    out.m_1 = in.m_0.wzyx;\n', '')
VS = HEAD + 'struct main0_out\n{\n    float4 gl_Position [[position]];\n};\n\nvertex main0_out main0()\n{\n    main0_out out = {};\n    return out;\n}\n\n'
fails = []
def ck(what, cond):
    print(('✓ ' if cond else '✗ ') + what)
    if not cond: fails.append(what)

r = dshfn.batch([('fs_alpha_ms', [FS]), ('fs_alpha_ms', [FS1])])
if any('ok' not in x for x in r): print('✗ fs_alpha_ms 报错：', [x.get('err') for x in r]); sys.exit(1)
fa, f1a = (x['ok'] for x in r)
r = dshfn.batch([('fs_fout', [fa]), ('fs_fout', [f1a]), ('fs_fout', [FS]), ('fs_fout', [VS])])
if any('ok' not in x for x in r): print('✗ dsh_cmp --fn fs_fout 报错：', [x.get('err') for x in r]); sys.exit(1)
a, b, raw, v = (x['ok'] for x in r)
line = next((l for l in a.split('\n') if l.startswith('constant int S2A_AT [[function_constant(100)]];')), '')
ck('① 声明接在 S2A_AT 那一行末尾（同一行）', 'constant uint S2A_FU [[function_constant(102)]];' in line and 'constant uint S2A_FS [[function_constant(103)]];' in line and a.count('S2A_FU [[') == 1)
ck('① 输出 0 / 1 由 S2A_F0 / S2A_F1 开关', '    float4 m_0 [[color(0), function_constant(S2A_F0)]];\n' in a and '    float4 m_1 [[color(1), function_constant(S2A_F1)]];\n' in a)
ck('① 旁加整数成员与双源第二源', all(s in a for s in ('    uint4 m_0_s2u [[color(0), function_constant(S2A_U0)]];', '    int4 m_0_s2i [[color(0), function_constant(S2A_I0)]];',
    '    uint4 m_1_s2u [[color(1), function_constant(S2A_U1)]];', '    int4 m_1_s2i [[color(1), function_constant(S2A_I1)]];', '    float4 m_1_s2d [[color(0), index(1), function_constant(S2A_DUAL)]];')))
ck('① s2a_smask 照留', 'uint s2a_smask [[sample_mask, function_constant(S2A_MSOFF_ON)]];' in a)
conv = 'if (S2A_U0) out.m_0_s2u = as_type<uint4>(out.m_0); if (S2A_I0) out.m_0_s2i = as_type<int4>(out.m_0); '
ck('① 两个 return out; 前都按位取（在透明测试之后）', a.count(conv) == 2 and a.count('discard_fragment(); ' + conv) == 2 and a.count('return out;') == 2)
ck('① 不写输出 1：加恒 0 的 s2a_src1', '    float4 s2a_src1 [[color(0), index(1), function_constant(S2A_DUAL)]];' in b and 'if (S2A_DUAL) out.s2a_src1 = float4(0); ' in b and 'm_1' not in b)
ck('① 再改一次不变（幂等）', dshfn.fn('fs_fout', a) == a)
ck('① 没有 FC_DECL 的原样（FsAlphaMs 没接的）', raw == FS)
ck('① 顶点原样', v == VS)

def unity_src(items):
    with tempfile.TemporaryDirectory(prefix='t_fout_fc_u_') as td:
        args = []
        for i, (k, txt) in enumerate(items):
            p = os.path.join(td, f'{i}.metal'); open(p, 'w').write(txt); args += [k, p]
        o = os.path.join(td, 'u.metal'); r = subprocess.run([*dsh_batch.get()[0], '--unity', 'src', o, *args], capture_output=True, text=True)
        if r.returncode: print('✗ dsh_batch --unity src 报错：' + (r.stdout + r.stderr).strip()[-300:]); sys.exit(1)
        return open(o).read()
u = unity_src([('aaaaaaaaaaaaaaaa', a), ('bbbbbbbbbbbbbbbb', b)])
ck('② 成批合编：声明行只一次', u.count(line) == 1 and u.count('S2A_FU [[') == 1)

W0 = '3fc00000 40000000 40400000 3e800000'; W1 = '3e800000 40400000 40000000 3fc00000'; Z = '00000000 00000000 00000000 00000000'
want2 = {'none': f'{W0} | {W1}', 'u1': f'{W0} | {W1}', 's2': f'{W0} | {W1}', 'u1s2': f'{W0} | {W1}', 'dual': '3600 4600 4600 3600',
         'u1_never': f'{Z} | {Z}', 'u1_always_msoff': f'{W0} | {W1}', 'none_on_uint': 'FAIL'}
want1 = dict(want2, dual='0000 0000 0000 0000', **{k: want2[k].split(' | ')[0] + f' | {Z}' for k in ('none', 'u1', 's2', 'u1s2', 'u1_always_msoff')})
with tempfile.TemporaryDirectory(prefix='t_fout_fc_') as t:
    exe = os.path.join(t, 'run'); c = subprocess.run(['clang', '-fobjc-arc', '-framework', 'Metal', '-framework', 'Foundation', '-o', exe, os.path.join(HERE, 't_fout_fc_run.m')], capture_output=True, text=True)
    if c.returncode: print('✗ t_fout_fc_run 编不过：' + c.stderr[-400:]); sys.exit(1)
    files = []
    for nm, txt in (('a.metal', a), ('b.metal', b), ('u.metal', u)):
        p = os.path.join(t, nm); open(p, 'w').write(txt); files.append(p)
    slot = re.search(r's2a_aref \[\[buffer\((\d+)\)\]\]', a).group(1)
    out = subprocess.run([exe, slot, *files], capture_output=True, text=True).stdout
    got = {}
    for m in re.finditer(r'^CASE (\d) (\S+) (\S+) (OK (.*)|FAIL.*)$', out, re.M): got[(int(m.group(1)), m.group(2), m.group(3))] = m.group(5).strip() if m.group(5) is not None else 'FAIL'
    if 'LIB FAIL' in out or not got: print(out[-800:])
    entries = sorted({(f, e) for f, e, _ in got})
    ck(f'③ 入口：单支 2 + 批 2 = 4 个（{entries}）', len(entries) == 4)
    for (f, e) in entries:
        w = want2 if (f == 2 or (f == 4 and 'aaaa' in e)) else want1   # argv[1] 是槽号，文件从 2 起：2 = a（两路输出）、3 = b、4 = 批
        bad = {k: got.get((f, e, k)) for k in w if got.get((f, e, k)) != w[k]}
        ck(f'③ 文件 {f} {e}：{len(w)} 例对手写期望' + (f'，不符 {bad}' if bad else ''), not bad)
print(('✓ t_fout_fc：全过' if not fails else f'✗ t_fout_fc：{len(fails)} 项不符'))
sys.exit(1 if fails else 0)
