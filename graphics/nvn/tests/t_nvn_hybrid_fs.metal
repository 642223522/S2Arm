// t_nvn_hybrid ⑥ ⑦（随包拉取基础管线、逐对 lzfse）的片元库：mk 编成 hybrid_fs.metallib，单测按它与拉取库 aaaaaaaaaaaaaaaa_bp.metallib 用本机 metal-tt 出 Metal 4 归档。
//   输入接拉取库 main0 的输出（[[user(locn0)]]）；片元函数体互不相同，归档按函数哈希认。⑦ 用 fd / fc：拉取基础管线按（拉取入口, 片元函数对象）认，
//   同名函数 Metal 给同一个对象，⑥ 用过的 fb / fz 已有基础管线，⑦ 要没建过的
#include <metal_stdlib>
using namespace metal;

struct F0 { float4 a [[user(locn0)]]; };
fragment float4 fb(F0 i [[stage_in]]) { return i.a; }
fragment float4 fy(F0 i [[stage_in]]) { return i.a.zyxw; }
fragment float4 fz(F0 i [[stage_in]]) { return i.a * 0.5; }
fragment float4 fd(F0 i [[stage_in]]) { return i.a.yxzw; }
fragment float4 fc(F0 i [[stage_in]]) { return i.a * 0.25; }
