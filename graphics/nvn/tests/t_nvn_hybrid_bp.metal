// t_nvn_hybrid 的拉取式顶点库 <key>_bp（mk 编成 aaaaaaaaaaaaaaaa_bp.metallib）：前导 pull_prelude.metal 是 mk 从 graphics/tools/direct/dsh/Pull.cs 的 Prelude 原样摘出的
//   （dm_vlayout / dm_fetch 就是出包那份），入口照 Pull.cs Variant 写出的形状：去掉 [[stage_in]]、加 constant dm_vlayout& dm_lay [[buffer(16)]] 与三个内建参数、
//   开头 in.m_N = as_type<T>(dm_fetch(dm_lay, 属性号u, ...))。精确版（stage_in）在 t_nvn_hybrid.m 里现编
#include <metal_stdlib>
using namespace metal;

#include "pull_prelude.metal"

struct VO { float4 p [[position]]; float4 a [[user(locn0)]]; };
struct VI { float4 m_0; };

vertex VO main0(constant dm_vlayout& dm_lay [[buffer(16)]], uint dm_vid [[vertex_id]], uint dm_iid [[instance_id]], uint dm_bi [[base_instance]])
{
    VI in;
    in.m_0 = as_type<float4>(dm_fetch(dm_lay, 0u, dm_vid, dm_iid, dm_bi));
    VO o; o.p = float4(in.m_0.xy, 0, 1); o.a = in.m_0; return o;
}
