// t_nvn_hybrid ⑥（随包拉取基础管线）的片元库：mk 编成 hybrid_fs.metallib，单测按它与拉取库 aaaaaaaaaaaaaaaa_bp.metallib 用本机 metal-tt 出 Metal 4 归档。
//   输入接拉取库 main0 的输出（[[user(locn0)]]）；三个片元函数体互不相同，归档按函数哈希认
#include <metal_stdlib>
using namespace metal;

struct F0 { float4 a [[user(locn0)]]; };
fragment float4 fb(F0 i [[stage_in]]) { return i.a; }
fragment float4 fy(F0 i [[stage_in]]) { return i.a.zyxw; }
fragment float4 fz(F0 i [[stage_in]]) { return i.a * 0.5; }
