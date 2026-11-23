#!/usr/bin/env python3
"""图形阶段「用到哪几个存储缓冲槽」（s2a_libpack_stage_sbuf_slots）的负对照：正例跑 libpack_vk_test；
改坏 libpack_vk.c 里这个函数的判据各一处，libpack_vk_test 必红在对应断言。

这个函数是引擎判断「非对齐的存储缓冲绑定会不会影响这个程序」的依据（nvk_shader.c gfx_ssbo_align）：
  多报一个槽，只是多走一次现编；少报一个槽，就会把「按对齐翻的」库件交给非对齐的绑定（画面是错的）。
所以这里锁的是「不许少报」那一侧：库里读不准就说不准（不猜）、槽号 / 阶段 / 图元 / dm_ctl / 语法逐项核对、只读不动计数。
"""
import os
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
out = root / 'build/libpack-sbuf-slots'
out.mkdir(parents=True, exist_ok=True)
native = root / 'android/native'
source = (native / 'direct/libpack_vk.c').read_text()
flags = ['-std=c11', '-D_GNU_SOURCE', '-Wall', '-Wextra', '-Werror']
includes = [native, native/'direct', native/'nvn', root/'runtime/include']


def run(name, text=None):
    lib = native / 'direct/libpack_vk.c'
    if text is not None:
        lib = out / (name + '.c')
        lib.write_text(text)
    exe = out / name
    sources = [root/'android/tests/libpack_vk_test.c', lib, native/'direct/json.c', native/'direct/jv.c', native/'nvn/nvn_vk_program_result.c']
    subprocess.run([os.environ.get('CC', 'cc'), *flags, *('-I'+str(p) for p in includes), *(str(p) for p in sources), '-o', str(exe)], check=True)
    env = os.environ.copy()
    env['TMPDIR'] = str(out)
    return subprocess.run([str(exe)], capture_output=True, text=True, env=env)


good = run('good')
if good.returncode != 0 or 'libpack_vk_test: all checks passed' not in good.stdout:
    sys.exit(f'libpack_vk_test failed on the unmodified source rc={good.returncode}\n{good.stdout}\n{good.stderr}')
print('PASS: libpack_vk_test (stage sbuf slots: set / unknown / stage / topology / dm_ctl / syntax / read-only / agrees with the composed program)')

PREFIX = 'FAIL: 存储槽集合：'
mutants = (
    # 种类
    ('unknown-kind-as-nonstorage', '    return -1;\n}\n\nint s2a_libpack_stage_sbuf_slots', '    return 0;\n}\n\nint s2a_libpack_stage_sbuf_slots',
     PREFIX + '不认得的种类 → 说不准（不当成没用存储）'),
    ('other-storage-kinds-skipped', '            if (cls < 0) goto done;', '            if (cls < 0) continue;',
     PREFIX + 'sbuf_ubo → 说不准（别的存储种类）'),
    ('nonstorage-list-short', '{ "tex", "tbuf", "tex_pool", "tex_ubo",', '{ "tbuf", "tex_pool", "tex_ubo",',
     PREFIX + '22 种已知非存储种类 → 读到、集合为空（逐个种类都认得）'),
    # 槽号
    ('reg-range-unchecked', 'if (jf_u32(b, "reg", &reg) || reg >= 16) goto done;', 'if (jf_u32(b, "reg", &reg)) goto done;',
     PREFIX + 'sbuf 槽号 16（越界）→ 说不准'),
    ('missing-reg-as-zero', 'if (jf_u32(b, "reg", &reg) || reg >= 16) goto done;', 'if (jf_u32(b, "reg", &reg)) reg = 0;\n            if (reg >= 16) goto done;',
     PREFIX + 'sbuf 没有 reg → 说不准'),
    ('slot-bit-off-by-one', '            mask |= 1u << reg;', '            mask |= 1u << (reg + 1);',
     PREFIX + 'sbuf reg 0 / 3 / 15（夹着 cbuf / tex）→ 集合 0x8009'),
    ('slot-from-index-not-reg', 'if (jf_u32(b, "reg", &reg) || reg >= 16) goto done;', 'if (jf_u32(b, "index", &reg) || reg >= 16) goto done;',
     PREFIX + 'sbuf reg 0 / 3 / 15（夹着 cbuf / tex）→ 集合 0x8009'),
    ('mask-overwritten-not-merged', '            mask |= 1u << reg;', '            mask = 1u << reg;',
     PREFIX + 'sbuf reg 0 / 3 / 15（夹着 cbuf / tex）→ 集合 0x8009'),
    # 命中判据（与 program_v1 的合成同口径）
    ('dm-ctl-unchecked', 'if (jf_str(top, "dm_ctl", ctl, sizeof ctl) || strcmp(ctl, khex)) goto done;', '(void)ctl;',
     PREFIX + 'dm_ctl 与键不符 → 说不准'),
    ('stage-unchecked', 'if (jf_str(top, "stage", st, sizeof st) || strcmp(st, lib_stage)) goto done;', '(void)st;',
     PREFIX + '同一份 json 当顶点段读 → stage 不符，说不准'),
    ('syntax-unchecked',
     'if (!s2a_jv_is_object(top) || s2a_jv_scan((const char *)jb, (const char *)jb + jn, &jend) || jend != (const char *)jb + jn) goto done;',
     'if (!s2a_jv_is_object(top)) goto done;\n        (void)jend;',
     PREFIX + 'bindings 之后还有语法错误的成员 → 说不准（整份核一遍，不只读用到的字段）'),
    # 几何：图元挑对格子、json 自称的图元要和格子一致、不退到 _b.json
    ('gs-topology-unchecked', 'if (gs && (jf_u32(top, "gs_input_topology", &git) || git != (uint32_t)gt)) goto done;', '(void)git;',
     PREFIX + '_vg3 里 json 自称点输入 → 说不准'),
    ('gs-reads-b-json', 'gs ? LP_K_VGJSON + (unsigned)gt : LP_K_BJSON, &jb, &jn, gw, sizeof gw) != S2A_LIBPACK_HIT) { free(jb); return 1; }\n    struct s2a_jv top',
     'LP_K_BJSON, &jb, &jn, gw, sizeof gw) != S2A_LIBPACK_HIT) { free(jb); return 1; }\n    struct s2a_jv top',
     PREFIX + '几何段、三角输入、_vg3：sbuf reg 1 → 0x2'),
    ('gs-topology-fixed-triangle', 'gs ? LP_K_VGJSON + (unsigned)gt : LP_K_BJSON, &jb, &jn, gw, sizeof gw) != S2A_LIBPACK_HIT) { free(jb); return 1; }\n    struct s2a_jv top',
     'gs ? LP_K_VGJSON + 3u : LP_K_BJSON, &jb, &jn, gw, sizeof gw) != S2A_LIBPACK_HIT) { free(jb); return 1; }\n    struct s2a_jv top',
     PREFIX + '几何段、线输入：_vg1 的 sbuf reg 4 → 0x10（图元挑对格子）'),
    # 说不准时集合清零；只读
    ('slots-not-cleared-on-failure', '    if (slots) *slots = 0;\n    if (!lp || !lp->p.idx || !key || !slots) return 1;', '    if (!lp || !lp->p.idx || !key || !slots) return 1;',
     PREFIX + 'sbuf 槽号 16（越界）→ 说不准'),
    ('counts-a-miss', 'done:\n    free(jb);\n    return out;\n}\n\nint s2a_libpack_program_v1', 'done:\n    free(jb);\n    atomic_fetch_add(&g_misses, 1);\n    return out;\n}\n\nint s2a_libpack_program_v1',
     PREFIX + '只读，不动命中 / 没有 / 拒收计数'),
)
for name, old, new, expected in mutants:
    assert source.count(old) == 1, (name, 'mutation anchor', source.count(old))
    result = run(name, source.replace(old, new))
    if result.returncode == 0 or expected not in result.stdout:
        sys.exit(f'{name}: wrong negative control outcome rc={result.returncode}\n{result.stdout}\n{result.stderr}')
    print(f'{name}: expected assertion failure: {expected}', flush=True)
print(f'PASS: {len(mutants)} stage-sbuf-slots negative controls')
