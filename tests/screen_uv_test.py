#!/usr/bin/env python3
"""遍内自采样改片上读取的离线两半（10-30 帧率能耗线）：S2A.Dsh DshFetch.ProjUv / Variant 的 proj 标记（graphics/tools/direct/dsh/Fetch.cs）、
DshCompiler.ScrUvLocns（graphics/tools/direct/dsh/Dsh.cs），经 dsh_cmp --fn fetch_variant / scr_uv_locns 调（graphics/tools/direct/tests/dshfn.py）。
夹具是照塞尔达 753d0169ae3ce4f0（片元）/ 0224fecce6565477（顶点）写法手写的小段 MSL，期望值按写法手写，不跑被测实现得来；每条正例配反例。"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "graphics" / "tools" / "direct" / "tests"))
import dshfn  # noqa: E402


def variant(msl, binds):
    return dshfn.fn("fetch_variant", msl, binds, False)


def scr_uv_locns(src):
    return dshfn.fn("scr_uv_locns", src)


def scr_pos_locns(src):
    return dshfn.fn("scr_pos_locns", src)

FS = """#include <metal_stdlib>
using namespace metal;

struct spvDescriptorSetBuffer0
{
    texture2d<float> fp_t_tcb_8 [[id(0)]];
    sampler fp_t_tcb_8Smplr [[id(1)]];
    texture2d<float> fp_t_tcb_A [[id(2)]];
    sampler fp_t_tcb_ASmplr [[id(3)]];
};

struct main0_out
{
    float4 m_10 [[color(0)]];
    float4 m_11 [[color(1)]];
};

struct main0_in
{
    float4 m_54 [[user(locn6)]];
    float4 m_60 [[user(locn0)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]])
{
    main0_out out = {};
    float _98 = in.m_54.w;
    float _104 = in.m_54.x;
    float _108 = in.m_54.y;
    float _159 = 1.0 / _98;
    float _199 = _104 * _159;
    float _201 = _159 * _108;
    float2 _946 = float2(_199, _201);
    float _300 = in.m_60.x;
    float _301 = in.m_60.y;
    float2 _950 = float2(_300, _301);
    float _203 = spvDescriptorSet0.fp_t_tcb_A.sample(spvDescriptorSet0.fp_t_tcb_ASmplr, select(_946, float2(0.0), isnan(_946))).x;
    float _204 = spvDescriptorSet0.fp_t_tcb_8.sample(spvDescriptorSet0.fp_t_tcb_8Smplr, select(_950, float2(0.0), isnan(_950))).x;
    out.m_10 = float4(_203);
    out.m_11 = float4(_204);
    return out;
}
"""
BINDS = [{"kind": "tex", "msl_name": "fp_t_tcb_8", "reg": 0}, {"kind": "tex", "msl_name": "fp_t_tcb_A", "reg": 1}]

VS = """struct main0_out
{
    float4 m_70 [[user(locn6)]];
    float4 m_71 [[user(locn7)]];
    float4 gl_Position [[position]];
};

vertex main0_out main0(main0_in in [[stage_in]], constant float4& s2a_push [[buffer(13)]])
{
    main0_out out = {};
    out.m_70 = float4(0.0, 0.0, 0.0, 1.0);
    out.gl_Position.x = 0.0;
    float _673 = in.m_1.x;
    float _677 = in.m_1.w;
    float _679 = in.m_1.y;
    out.gl_Position.x = _673;
    out.gl_Position.w = _677;
    out.gl_Position.y = _679;
    float _683 = _673 + _677;
    out.m_70.w = _677;
    float _685 = -_679;
    float _687 = _685 + _677;
    if (_673 > 0.0)
    {
        float _691 = _673;
    }
    float _695 = _683 * 0.5;
    float _697 = _687 * 0.5;
    out.m_70.x = _695;
    out.m_70.y = _697;
    out.m_71.x = _673;
    out.m_71.y = _679;
    out.m_71.w = _677;
    { float4 s2a_q = s2a_push; out.gl_Position.x = out.gl_Position.x * (1.0f - s2a_q.z); }
    return out;
}

"""


def vs_with_z(body):
    """main0 原样，再复制一份同体的 main0_z（两个入口都要成立）"""
    z = body.replace("vertex main0_out main0(", "vertex main0_out main0_z(", 1).split("struct main0_out", 1)[1]
    return body + "struct main0_out" + z


class ProjUv(unittest.TestCase):
    def test_projective_and_direct(self):
        fv, meta = variant(FS, BINDS)
        self.assertIsNotNone(fv)
        calls = sorted(meta["calls"], key=lambda c: c["tex_reg"])
        # 槽 1（fp_t_tcb_A）：in.m_54.xy * (1 / in.m_54.w)，乘数前后都认 → proj，插值量 locn6；槽 0：直接插值 locn0，无 proj
        self.assertEqual(calls, [{"fc": 1, "tex_reg": 0, "varying_locn": 0}, {"fc": 0, "tex_reg": 1, "varying_locn": 6, "proj": 1}])
        self.assertEqual(meta["mixed_regs"], [])

    def test_w_from_other_varying_is_not_projective(self):
        bad = FS.replace("float _98 = in.m_54.w;", "float _98 = in.m_60.w;")
        fv, meta = variant(bad, BINDS)
        self.assertEqual([c["tex_reg"] for c in meta["calls"]], [0])   # 槽 1 不再可改

    def test_different_reciprocal_is_not_projective(self):
        bad = FS.replace("float _201 = _159 * _108;", "float _201 = _104 * _108;")
        fv, meta = variant(bad, BINDS)
        self.assertEqual([c["tex_reg"] for c in meta["calls"]], [0])

    def test_inlined_component_reads(self):
        # 11-07 卡顿线：翻译器关 DebugMode 后表达式传播把分量读并进乘法 / 倒数 / float2（旷野之息 0b6d8f4f993ae7ee：「_70 = in.m_40.x * _64; _64 = 1.0 / in.m_40.w;」），
        #   期望同展开写法：槽 1 proj、locn6；槽 0 直接插值 locn0
        inl = FS.replace("""    float _98 = in.m_54.w;
    float _104 = in.m_54.x;
    float _108 = in.m_54.y;
    float _159 = 1.0 / _98;
    float _199 = _104 * _159;
    float _201 = _159 * _108;
""", """    float _159 = 1.0 / in.m_54.w;
    float _199 = in.m_54.x * _159;
    float _201 = _159 * in.m_54.y;
""").replace("""    float _300 = in.m_60.x;
    float _301 = in.m_60.y;
    float2 _950 = float2(_300, _301);""", """    float2 _950 = float2(in.m_60.x, in.m_60.y);""")
        self.assertNotIn("float _98", inl); self.assertIn("float2 _950 = float2(in.m_60.x, in.m_60.y);", inl)   # 夹具确实换成了并入写法
        fv, meta = variant(inl, BINDS)
        self.assertIsNotNone(fv)
        calls = sorted(meta["calls"], key=lambda c: c["tex_reg"])
        self.assertEqual(calls, [{"fc": 1, "tex_reg": 0, "varying_locn": 0}, {"fc": 0, "tex_reg": 1, "varying_locn": 6, "proj": 1}])
        # 反例：并入写法里 w 取自别的插值量 → 槽 1 不是投影坐标；x 与 y 来自不同插值量 → 槽 0 不可改
        bad = inl.replace("float _159 = 1.0 / in.m_54.w;", "float _159 = 1.0 / in.m_60.w;")
        self.assertEqual([c["tex_reg"] for c in variant(bad, BINDS)[1]["calls"]], [0])
        bad2 = inl.replace("float2(in.m_60.x, in.m_60.y)", "float2(in.m_60.x, in.m_54.y)")
        self.assertEqual([c["tex_reg"] for c in variant(bad2, BINDS)[1]["calls"]], [1])

    def test_reassigned_coordinate_is_not_resolved(self):
        # 11-07 卡顿线：坐标分量的临时量在别处又被赋值（循环变量，旷野之息 0e0440f4f042f99d「float _80 = _46;」后循环体里「_80 = _299;」）→ 值随路径变，不能代回成插值量读，
        #   期望槽 0（float2(_300, _301)，_300 被改写）不可改，槽 1 照旧
        bad = FS.replace("    out.m_10 = float4(_203);\n", "    _300 = _201;\n    out.m_10 = float4(_203);\n")
        self.assertNotEqual(bad, FS)
        self.assertEqual([c["tex_reg"] for c in variant(bad, BINDS)[1]["calls"]], [1])

    def test_second_use_marks_mixed(self):
        extra = "    float _205 = spvDescriptorSet0.fp_t_tcb_A.sample(spvDescriptorSet0.fp_t_tcb_ASmplr, float2(0.5, 0.5)).x;\n"
        bad = FS.replace("    out.m_10 = float4(_203);\n", extra + "    out.m_10 = float4(_203 + _205);\n")
        fv, meta = variant(bad, BINDS)
        self.assertEqual(meta["mixed_regs"], [1])   # 槽 1 还有一处非本像素读法 → 混用，宿主不改


class ScrUv(unittest.TestCase):
    def test_screen_uv_locn(self):
        # m_70 = ((P.x + P.w) / 2, (-P.y + P.w) / 2, ·, P.w) → locn6；m_71 = (P.x, P.y, ·, P.w) 不是 → 不记
        self.assertEqual(scr_uv_locns(vs_with_z(VS)), [6])

    def test_main0_only_is_enough_when_no_z_entry(self):
        self.assertEqual(scr_uv_locns(VS), [6])

    def test_assignment_inside_block(self):
        bad = VS.replace("    out.m_70.x = _695;\n", "    if (_673 > 0.0) { out.m_70.x = _695; }\n")
        self.assertEqual(scr_uv_locns(vs_with_z(bad)), [])

    def test_position_changed_inside_block(self):
        bad = VS.replace("        float _691 = _673;\n", "        out.gl_Position.y = _673;\n")
        self.assertEqual(scr_uv_locns(vs_with_z(bad)), [])

    def test_y_not_negated(self):
        self.assertEqual(scr_uv_locns(vs_with_z(VS.replace("float _685 = -_679;", "float _685 = _679;"))), [])

    def test_w_not_position_w(self):
        self.assertEqual(scr_uv_locns(vs_with_z(VS.replace("    out.m_70.w = _677;\n", "    out.m_70.w = _673;\n"))), [])

    def test_z_entry_disagrees(self):
        good, bad = VS, VS.replace("float _695 = _683 * 0.5;", "float _695 = _683 * 0.25;")
        z = bad.replace("vertex main0_out main0(", "vertex main0_out main0_z(", 1).split("struct main0_out", 1)[1]
        self.assertEqual(scr_uv_locns(good + "struct main0_out" + z), [])

    def test_inlined_form(self):
        # 11-07 卡顿线：关 DebugMode 后表达式内联（旷野之息 008308c18fc89a42：out.m_72.x = (_237 + _239) * 0.5; out.m_72.y = ((-_241) + _239) * 0.5;），期望同展开写法 → locn6
        inl = VS.replace("""    float _695 = _683 * 0.5;
    float _697 = _687 * 0.5;
    out.m_70.x = _695;
    out.m_70.y = _697;
""", """    out.m_70.x = (_673 + _677) * 0.5;
    out.m_70.y = ((-_679) + _677) * 0.5;
""")
        self.assertNotEqual(inl, VS)
        self.assertEqual(scr_uv_locns(vs_with_z(inl)), [6])
        self.assertEqual(scr_uv_locns(vs_with_z(inl.replace("((-_679) + _677) * 0.5", "(_679 + _677) * 0.5"))), [])   # y 没取负 → 不是
        self.assertEqual(scr_uv_locns(vs_with_z(inl.replace("(_673 + _677) * 0.5", "(_673 + _677) * 0.25"))), [])

    def test_temp_reassigned_in_block_is_not_resolved(self):
        # 临时量在块里又被赋值（值随路径变）→ 不能代回：m_70.x 的来源 _695 在 if 里改写 → 不成立
        bad = VS.replace("        float _691 = _673;\n", "        _695 = _673;\n").replace("    float _695 = _683 * 0.5;\n", "")
        bad = bad.replace("    float4 gl_Position [[position]];", "    float4 gl_Position [[position]];").replace("    out.m_70.w = _677;\n", "    out.m_70.w = _677;\n    float _695 = _683 * 0.5;\n")
        self.assertEqual(scr_uv_locns(vs_with_z(bad)), [])

    def test_no_main0(self):
        self.assertEqual(scr_uv_locns(VS.replace("main0(", "other(")), [])




# #1152：片元自己把裁剪坐标插值量换成 uv（异度之刃 3 038af36eb178a2bf / a93aa7a906dc4e2d 的写法：_111 = 1.0 / in.m_55.w；
#   _113 = fma(_99 * _111, 0.5, 0.5)；_139 = fma(_101 * _111, -0.5, 0.5)）。期望按写法手写：可改、proj + ndc、插值量 locn；顶点侧要求这个插值量 = gl_Position
FS_NDC = """#include <metal_stdlib>
using namespace metal;

struct spvDescriptorSetBuffer0
{
    texture2d<float> fp_t_tcb_1A [[id(0)]];
    sampler fp_t_tcb_1ASmplr [[id(1)]];
};

struct main0_out
{
    float4 m_10 [[color(0)]];
};

struct main0_in
{
    float4 m_55 [[user(locn7)]];
};

fragment main0_out main0(main0_in in [[stage_in]], constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]])
{
    main0_out out = {};
    float _99 = in.m_55.x;
    float _101 = in.m_55.y;
    float _111 = 1.0 / in.m_55.w;
    float _113 = fma(_99 * _111, 0.5, 0.5);
    float _139 = fma(_101 * _111, -0.5, 0.5);
    float2 _511 = float2(_113, _139);
    float3 _203 = spvDescriptorSet0.fp_t_tcb_1A.sample(spvDescriptorSet0.fp_t_tcb_1ASmplr, s2a_uv(select(_511, float2(0.0), isnan(_511)), spvDescriptorSet0.s2a_uvx[16]), bias(spvDescriptorSet0.s2a_lb[17])).xyz;
    out.m_10 = float4(_203, 1.0);
    return out;
}
"""
BINDS_NDC = [{"kind": "tex", "msl_name": "fp_t_tcb_1A", "reg": 9}]


class NdcUv(unittest.TestCase):
    def test_fragment_ndc_to_uv(self):
        fv, meta = variant(FS_NDC, BINDS_NDC)
        self.assertIsNotNone(fv)
        self.assertEqual(meta["calls"], [{"fc": 0, "tex_reg": 9, "varying_locn": 7, "proj": 1, "ndc": 1}])

    def test_inlined_ndc(self):
        inl = FS_NDC.replace("    float _99 = in.m_55.x;\n    float _101 = in.m_55.y;\n", "").replace("fma(_99 * _111", "fma(in.m_55.x * _111").replace("fma(_101 * _111", "fma(in.m_55.y * _111")
        self.assertNotIn("_99 =", inl)
        self.assertEqual(variant(inl, BINDS_NDC)[1]["calls"], [{"fc": 0, "tex_reg": 9, "varying_locn": 7, "proj": 1, "ndc": 1}])

    def test_y_not_flipped_is_not_this_pixel(self):
        bad = FS_NDC.replace("fma(_101 * _111, -0.5, 0.5)", "fma(_101 * _111, 0.5, 0.5)")
        self.assertIsNone(variant(bad, BINDS_NDC)[0])   # 没有可改的采样：整支不出变体

    def test_x_flipped_is_not_this_pixel(self):
        bad = FS_NDC.replace("fma(_99 * _111, 0.5, 0.5)", "fma(_99 * _111, -0.5, 0.5)")
        self.assertIsNone(variant(bad, BINDS_NDC)[0])   # 没有可改的采样：整支不出变体

    def test_other_scale_is_not_this_pixel(self):
        bad = FS_NDC.replace("fma(_99 * _111, 0.5, 0.5)", "fma(_99 * _111, 0.25, 0.5)")
        self.assertIsNone(variant(bad, BINDS_NDC)[0])   # 没有可改的采样：整支不出变体

    def test_w_from_other_component(self):
        bad = FS_NDC.replace("float _111 = 1.0 / in.m_55.w;", "float _111 = 1.0 / in.m_55.z;")
        self.assertIsNone(variant(bad, BINDS_NDC)[0])   # 没有可改的采样：整支不出变体


class WideGbuffer(unittest.TestCase):
    """#1152：G-buffer 贴花写 5 个颜色输出、带多重采样关时的样本掩码成员（s2a_smask）、return 包在单行块里（异度之刃 3 a93aa7a906dc4e2d 的形状）。
    期望按写法手写：出变体；5 个输出都记；第 5 个输出的搬位置常量落在 128 起（不撞 S2A_AT 100 / S2A_MSOFF 101）；样本掩码成员留在结构里；单行块里的 return 前插了输出赋值"""
    SRC = FS_NDC.replace("""    float4 m_10 [[color(0)]];
""", """    float4 m_10 [[color(0)]];
    float4 m_11 [[color(1)]];
    float4 m_12 [[color(2)]];
    float4 m_13 [[color(3)]];
    float4 m_14 [[color(4)]];
    uint s2a_smask [[sample_mask, function_constant(S2A_MSOFF_ON)]];
""").replace("""    out.m_10 = float4(_203, 1.0);
    return out;
""", """    out.m_10 = float4(_203, 1.0);
    out.m_14 = float4(0.0);
    { if (S2A_MSOFF_ON) out.s2a_smask = 0xffffffffu; return out; }
""").replace("using namespace metal;\n", "using namespace metal;\nconstant int S2A_AT [[function_constant(100)]]; constant bool S2A_MSOFF [[function_constant(101)]]; constant bool S2A_MSOFF_ON = is_function_constant_defined(S2A_MSOFF) ? S2A_MSOFF : false;\n", 1)

    def test_five_outputs_smask_inline_return(self):
        self.assertIn("uint s2a_smask", self.SRC); self.assertIn("{ if (S2A_MSOFF_ON) out.s2a_smask = 0xffffffffu; return out; }", self.SRC)
        fv, meta = variant(self.SRC, BINDS_NDC)
        self.assertIsNotNone(fv, meta)
        self.assertEqual([o["color"] for o in meta["outputs"]], [0, 1, 2, 3, 4])
        self.assertIn("constant bool OM_4_0 [[function_constant(128)]];", fv)
        self.assertIn("constant bool OM_3_7 [[function_constant(95)]];", fv)
        self.assertNotIn("[[function_constant(100)]];\nconstant bool OM", fv)
        for n in range(96, 128):
            self.assertNotIn("OM_", "\n".join(l for l in fv.splitlines() if f"function_constant({n})" in l))
        self.assertIn("uint s2a_smask [[sample_mask, function_constant(S2A_MSOFF_ON)]];", fv)
        self.assertRegex(fv, r"if \(OM_4_0\) out\.m_14_at0 = spv_o_m_14;[^\n]*return out; \}")

    def test_nine_outputs_refused(self):
        many = FS_NDC.replace("    float4 m_10 [[color(0)]];\n", "".join(f"    float4 m_{10 + i} [[color({i})]];\n" for i in range(9)))
        fv, why = variant(many, BINDS_NDC)
        self.assertIsNone(fv); self.assertIn("more than 8", why)


class ScrPos(unittest.TestCase):
    def test_position_copy_locn(self):
        # VS：m_71 = (P.x, P.y, ·, P.w) → locn7；m_70 是 scr_uv 那种（(P.x + P.w) / 2 …）不是位置本身 → 不记
        self.assertEqual(scr_pos_locns(vs_with_z(VS)), [7])
        self.assertEqual(scr_uv_locns(vs_with_z(VS)), [6])

    def test_y_negated_is_not_position(self):
        bad = VS.replace("    out.m_71.y = _679;\n", "    out.m_71.y = -_679;\n")
        self.assertEqual(scr_pos_locns(vs_with_z(bad)), [])

    def test_w_not_position_w(self):
        bad = VS.replace("    out.m_71.w = _677;\n", "    out.m_71.w = _673;\n")
        self.assertEqual(scr_pos_locns(vs_with_z(bad)), [])

    def test_assignment_inside_block(self):
        bad = VS.replace("    out.m_71.x = _673;\n", "    if (_673 > 0.0) { out.m_71.x = _673; }\n")
        self.assertEqual(scr_pos_locns(vs_with_z(bad)), [])


if __name__ == "__main__":
    unittest.main(verbosity=1)
