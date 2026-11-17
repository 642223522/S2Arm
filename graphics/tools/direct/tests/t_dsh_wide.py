#!/usr/bin/env python3
# 存储缓冲逐字读合并（S2A.Dsh DshCompiler.WideLoads，经 dsh_cmp --fn wide_loads 调；照 nxnative dmsh_wide.py（MIT）改成适配加固后的写法）。
# 片段照时之笛（Switch 2）着色器的真实写法手写（SPIRV-Cross 输出 + gal_spvx.c 加固：每个字 min(下标, 末项)）。期望按规则手推（不跑被测实现）：
#   ① 同一只读缓冲、同一根值、字节偏移 0/4/8/12 → 一次 packed_uint4，基址 b = min(i0, max(L, 3u) - 3u)，第 k 个字取第 min(i_k, L) - b 个分量（越界时仍同逐字钳位）
#   ② 偏移 220/224（根值的 16 字节格里第 3、4 个字跨格）→ 不合并（一串要从 16 字节边界起）；偏移 0/4/8 → packed_uint3
#   ③ 两个字之间有存储 / 给已有变量赋值 / 花括号 → 不合并
#   ④ 末项表达式不同 → 不合并；不是只读缓冲（device 不带 const）→ 不合并；低位的字不是先读的 → 不合并
#   ⑤ 两个函数体里同名的变量各管各的（函数体按第 0 列的 '{' '}' 分段）
#   ⑥ GPU 对拍（越界语义，11-14）：改后的核在本机 GPU 上跑，缓冲有效长度 L = 10 / 2，每线程从下标 gid 起读 4 个字；期望按逐字钳位手算 buf[min(gid + k, L - 1)]
# 负对照：DSH_CMP_DLL 指向改动前的翻译器，所有例都红（没有这个函数）；指向 11-14 前的版本，⑥ 越界的线程红。用法：python3 graphics/tools/direct/tests/t_dsh_wide.py
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE); import dshfn

HEAD = """#include <metal_stdlib>
using namespace metal;
struct _27
{
    uint _m0[1];
};
struct spvDescriptorSetBuffer0
{
    %s _27* vp_s2 [[id(5)]];
};
vertex main0_out main0(constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]])
{
    uint _1580 = max(_1578, 1u) - 1u;
"""
def f(body, ro=True, tail="}\n"): return HEAD % ("const device" if ro else "device") + body + tail
def load(i, last="_1580"): return f"(*spvDescriptorSet0.vp_s2)._m0[min({i}, {last})]"
FOUR = "".join(f"    uint _i{k} = uint(int(uint(_149{f' + {4*k}' if k else ''}) >> uint(2)));\n    float _f{k} = as_type<float>({load(f'_i{k}')});\n" for k in range(4))
checks = fails = 0
def case(name, src, want):
    global checks, fails
    got = dshfn.fn("wide_loads", src); checks += 1
    if got != want: fails += 1; print(f"✗ {name}\n--- 期望\n{want}\n--- 真结果\n{got}")
    else: print(f"✓ {name}")
# ① 四个字
want = f("    uint _i0 = uint(int(uint(_149) >> uint(2)));\n"
         "    uint _dmw0b = min(_i0, max(_1580, 3u) - 3u); packed_uint4 _dmw0 = *(const device packed_uint4*)&(*spvDescriptorSet0.vp_s2)._m0[_dmw0b];\n"
         "    float _f0 = as_type<float>(_dmw0[min(_i0, _1580) - _dmw0b]);\n"
         + "".join(f"    uint _i{k} = uint(int(uint(_149 + {4*k}) >> uint(2)));\n    float _f{k} = as_type<float>(_dmw0[min(_i{k}, _1580) - _dmw0b]);\n" for k in range(1, 4)))
case("① 同基址连续 4 个字 → 一次 packed_uint4", f(FOUR), want)
# ② 根值经 int 加法链：_155 = _149 + 16，读 _155 起的 3 个字；另有跨 16 字节格的 220/224 两个字不合并
src = ("    int _155 = _149 + 16;\n" + "".join(f"    uint _j{k} = uint(int(uint(_155{f' + {4*k}' if k else ''}) >> uint(2)));\n    float _g{k} = as_type<float>({load(f'_j{k}')});\n" for k in range(3))
       + f"    uint _a = uint(int(uint(_149 + 220) >> uint(2)));\n    float _ga = as_type<float>({load('_a')});\n"
       + f"    uint _b = uint(int(uint(_149 + 224) >> uint(2)));\n    float _gb = as_type<float>({load('_b')});\n")
want = ("    int _155 = _149 + 16;\n    uint _j0 = uint(int(uint(_155) >> uint(2)));\n"
        "    uint _dmw0b = min(_j0, max(_1580, 2u) - 2u); packed_uint3 _dmw0 = *(const device packed_uint3*)&(*spvDescriptorSet0.vp_s2)._m0[_dmw0b];\n"
        "    float _g0 = as_type<float>(_dmw0[min(_j0, _1580) - _dmw0b]);\n"
        + "".join(f"    uint _j{k} = uint(int(uint(_155 + {4*k}) >> uint(2)));\n    float _g{k} = as_type<float>(_dmw0[min(_j{k}, _1580) - _dmw0b]);\n" for k in range(1, 3))
        + f"    uint _a = uint(int(uint(_149 + 220) >> uint(2)));\n    float _ga = as_type<float>({load('_a')});\n"
        + f"    uint _b = uint(int(uint(_149 + 224) >> uint(2)));\n    float _gb = as_type<float>({load('_b')});\n")
case("② 经加法链的 3 个字 → packed_uint3；跨 16 字节格的两个字不动", f(src), f(want))
# ③ 中间有存储 / 赋值 / 花括号
two = lambda mid: (f"    uint _i0 = uint(int(uint(_149) >> uint(2)));\n    float _f0 = as_type<float>({load('_i0')});\n" + mid
                   + f"    uint _i1 = uint(int(uint(_149 + 4) >> uint(2)));\n    float _f1 = as_type<float>({load('_i1')});\n")
for nm, mid in (("存储", "    (*spvDescriptorSet0.vp_s3)._m0[0] = 1u;\n"), ("给已有变量赋值", "    _149 = _149 + 1;\n"), ("花括号", "    if (_x)\n    {\n    }\n")):
    s = f(two(mid)); case(f"③ 两字之间有{nm} → 不合并", s, s)
# ④ 末项不同 / 非只读 / 低位后读
s = f(f"    uint _i0 = uint(int(uint(_149) >> uint(2)));\n    float _f0 = as_type<float>({load('_i0', '_1581')});\n"
      f"    uint _i1 = uint(int(uint(_149 + 4) >> uint(2)));\n    float _f1 = as_type<float>({load('_i1')});\n"); case("④ 末项表达式不同 → 不合并", s, s)
s = f(FOUR, ro=False); case("④ 可写缓冲（device）→ 不合并", s, s)
s = f(f"    uint _i1 = uint(int(uint(_149 + 4) >> uint(2)));\n    float _f1 = as_type<float>({load('_i1')});\n"
      f"    uint _i0 = uint(int(uint(_149) >> uint(2)));\n    float _f0 = as_type<float>({load('_i0')});\n"); case("④ 低位的字后读 → 不合并", s, s)
# ⑤ 两个函数体各自分段：第二个函数里 _149 是另一个值，只在各自体内合并
second = "\nvertex main0_out main0_z(constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]])\n{\n" + two("") + "}\n"
got = dshfn.fn("wide_loads", f(two(""), tail="}\n" + second)); checks += 1
ok = got.count("packed_uint2 _dmw") == 2 and "_dmw0" in got and "_dmw1" in got
print(("✓" if ok else "✗") + " ⑤ 两个函数体各合并一次（_dmw0、_dmw1）"); fails += not ok
# ⑥ GPU 对拍：越界时各字仍同逐字钳位（11-14：原先越界直接取第 k 个分量，读到末尾往回的另一个字）
import shutil, subprocess, tempfile
from pathlib import Path
KSRC = """#include <metal_stdlib>
using namespace metal;
struct _27
{
    uint _m0[1];
};
struct spvDescriptorSetBuffer0
{
    const device _27* vp_s2 [[id(5)]];
};
kernel void check(constant spvDescriptorSetBuffer0& spvDescriptorSet0 [[buffer(0)]], constant uint& L [[buffer(1)]], device uint* out [[buffer(2)]], uint gid [[thread_position_in_grid]])
{
    uint _1580 = max(L, 1u) - 1u;
    int _149 = int(gid) * 4;
""" + "".join(f"    uint _i{k} = uint(int(uint(_149{f' + {4*k}' if k else ''}) >> uint(2)));\n    uint _f{k} = {load(f'_i{k}')};\n" for k in range(4)) + \
"""    out[gid * 4u + 0u] = _f0;
    out[gid * 4u + 1u] = _f1;
    out[gid * 4u + 2u] = _f2;
    out[gid * 4u + 3u] = _f3;
}
"""
GRUN = r"""#import <Metal/Metal.h>
#include <stdio.h>
#include <stdlib.h>
int main(int argc, char **argv) { @autoreleasepool {
    id<MTLDevice> d = MTLCreateSystemDefaultDevice(); if (!d) return 2; NSError *e = nil;
    id<MTLLibrary> lib = [d newLibraryWithURL:[NSURL fileURLWithPath:@(argv[1])] error:&e];
    id<MTLComputePipelineState> ps = lib ? [d newComputePipelineStateWithFunction:[lib newFunctionWithName:@"check"] error:&e] : nil;
    if (!ps) { fprintf(stderr, "%s\n", e.localizedDescription.UTF8String); return 1; }
    const unsigned T = 16, W = 64; int bad = 0;
    id<MTLBuffer> data = [d newBufferWithLength:W * 4 options:MTLResourceStorageModeShared];
    uint32_t *a = data.contents; for (unsigned j = 0; j < W; j++) a[j] = 0xA000u + j;
    uint64_t addr = data.gpuAddress;
    id<MTLCommandQueue> q = [d newCommandQueue];
    for (int t = 0; t < 2; t++) {
        uint32_t L = t ? 2 : 10;
        id<MTLBuffer> out = [d newBufferWithLength:T * 16 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLComputeCommandEncoder> en = [cb computeCommandEncoder];
        [en setComputePipelineState:ps]; [en setBytes:&addr length:8 atIndex:0]; [en setBytes:&L length:4 atIndex:1]; [en setBuffer:out offset:0 atIndex:2];
        [en useResource:data usage:MTLResourceUsageRead];
        [en dispatchThreads:MTLSizeMake(T, 1, 1) threadsPerThreadgroup:MTLSizeMake(T, 1, 1)]; [en endEncoding]; [cb commit]; [cb waitUntilCompleted];
        if (cb.status == MTLCommandBufferStatusError) { fprintf(stderr, "%s\n", cb.error.localizedDescription.UTF8String); return 1; }
        const uint32_t *b = out.contents;
        for (unsigned g = 0; g < T; g++) for (unsigned k = 0; k < 4; k++) {
            unsigned i = g + k, last = L - 1, w = i < last ? i : last; uint32_t want = 0xA000u + w;
            if (b[g * 4 + k] != want) { if (bad++ < 6) fprintf(stderr, "L=%u gid %u word %u: %#x, want %#x\n", L, g, k, b[g * 4 + k], want); }
        }
    }
    return bad != 0;
} }
"""
if shutil.which("xcrun") and shutil.which("clang"):
    kout = dshfn.fn("wide_loads", KSRC); checks += 1
    merged = "_dmw0b" in kout and "packed_uint4" in kout
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp); (root / "k.metal").write_text(kout); (root / "run.m").write_text(GRUN)
        cm = subprocess.run(["xcrun", "-sdk", "macosx", "metal", "-O2", str(root / "k.metal"), "-o", str(root / "k.metallib")], capture_output=True, text=True)
        cr = subprocess.run(["clang", "-fobjc-arc", "-O1", str(root / "run.m"), "-framework", "Metal", "-framework", "Foundation", "-o", str(root / "run")], capture_output=True, text=True)
        r = subprocess.run([str(root / "run"), str(root / "k.metallib")], capture_output=True, text=True) if cm.returncode == 0 and cr.returncode == 0 else None
        ok = merged and r is not None and r.returncode == 0
        if not ok: fails += 1
        print(("✓" if ok else "✗") + " ⑥ GPU 对拍：合并成 packed_uint4、L = 10 / 2 共 128 个字（含越界）都等于逐字钳位 buf[min(gid + k, L - 1)]"
              + ("" if ok else f"\n合并={merged} 编译={cm.stderr[-400:]}{cr.stderr[-200:]} 运行={(r.stderr if r else '')[-600:]}"))
else:
    print("⑥ 跳过 GPU 对拍：本机没有 xcrun / clang（判不了，不算过）"); checks += 1; fails += 1
print(f"{'✗' if fails else '✓'} t_dsh_wide：{checks} 项，{fails} 项不符"); sys.exit(1 if fails else 0)
