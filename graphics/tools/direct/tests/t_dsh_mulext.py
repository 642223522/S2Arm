#!/usr/bin/env python3
# 标量宽乘法离开 SPIRV-Cross 的 optnone 模板（S2A.Dsh DshCompiler.MulExtended，经 dsh_cmp --fn mul_extended 调；照 nxnative test_dmsh_extended_multiply.py（MIT））。
# 期望不跑被测实现得出：
#   ① 文本：模板原样保留，紧跟其后补 uint / int 两个重载（原文手写），调用处不动；再改一次不变
#   ② 不改：没有模板 / 模板被改过 / 两份模板 / 模板没有 optnone → 原样返回
#   ③ GPU 对拍：改后的核在本机 GPU 上跑 65536 组输入（含边界值），乘以字面量（2 的幂与否）、变量、有符号、向量，高低字与 CPU 64 位乘积逐位相同
#   ④ 编译后的核里标量调用都内联掉了，只剩向量那 1 个调用模板（iOS 与 Mac 两个 SDK 都编得过）
# 负对照：DSH_CMP_DLL 指向改动前的翻译器，①② 红（没有这个函数）。用法：python3 graphics/tools/direct/tests/t_dsh_mulext.py
import os, re, shutil, subprocess, sys, tempfile
from pathlib import Path
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE); import dshfn

HEAD = '''#include <metal_stdlib>
using namespace metal;
struct U { uint lo; uint hi; };
struct S { int lo; int hi; };
struct U2 { uint2 lo; uint2 hi; };

template<typename T, typename U, typename V>
[[clang::optnone]] T spvMulExtended(V l, V r)
{
    return T{U(l * r), U(mulhi(l, r))};
}

'''
# multiplies by 4042322161 (a division constant), 3, 16 (high word only, as Ocarina's address math), 0x80000000, a variable, signed by -7 and a variable, and a vector by a variable
KERNEL = '''kernel void check(device const uint2* input [[buffer(0)]], device uint* output [[buffer(1)]], uint i [[thread_position_in_grid]])
{
    uint2 x = input[i];
    U a = spvMulExtended<U, uint>(uint(x.x), 4042322161u);
    U b = spvMulExtended<U, uint>(as_type<uint>(x.y), 3u);
    uint c = (spvMulExtended<U, uint>(uint(x.x), 16u)).hi;
    U d = spvMulExtended<U, uint>(x.y, 2147483648u);
    U e = spvMulExtended<U, uint>(x.x, x.y);
    S f = spvMulExtended<S, int>(as_type<int>(x.x), -7);
    S g = spvMulExtended<S, int>(as_type<int>(x.x), as_type<int>(x.y));
    U2 h = spvMulExtended<U2, uint2>(x, x.yx);
    device uint* o = output + i * 16;
    o[0] = a.lo; o[1] = a.hi; o[2] = b.lo; o[3] = b.hi; o[4] = c; o[5] = d.lo; o[6] = d.hi; o[7] = e.lo; o[8] = e.hi;
    o[9] = as_type<uint>(f.lo); o[10] = as_type<uint>(f.hi); o[11] = as_type<uint>(g.lo); o[12] = as_type<uint>(g.hi); o[13] = h.lo.x; o[14] = h.hi.x; o[15] = h.hi.y;
}
'''
RUNNER = r'''#import <Metal/Metal.h>
#include <stdint.h>
#include <stdio.h>
int main(int argc, char **argv) {
 @autoreleasepool {
    id<MTLDevice> d = MTLCreateSystemDefaultDevice();
    if (!d) return 2;
    NSError *err = nil;
    id<MTLLibrary> lib = [d newLibraryWithURL:[NSURL fileURLWithPath:@(argv[1])] error:&err];
    id<MTLComputePipelineState> ps = lib ? [d newComputePipelineStateWithFunction:[lib newFunctionWithName:@"check"] error:&err] : nil;
    if (!ps) { fprintf(stderr, "%s\n", err.localizedDescription.UTF8String); return 1; }
    const unsigned n = 65536;
    id<MTLBuffer> in = [d newBufferWithLength:n * 8 options:MTLResourceStorageModeShared];
    id<MTLBuffer> out = [d newBufferWithLength:n * 64 options:MTLResourceStorageModeShared];
    uint32_t edge[] = {0, 1, 2, 3, 0x7fffffff, 0x80000000, 0x80000001, 0xfffffffe, 0xffffffff, 0x00010000, 0x0000ffff, 0xffff0000, 4042322161u, 2290649225u, 954437177u};
    unsigned ne = sizeof(edge) / sizeof(edge[0]);
    uint32_t *a = in.contents, state = 0x12345678;
    for (unsigned i = 0; i < n; i++) {
        for (unsigned j = 0; j < 2; j++) { state ^= state << 13; state ^= state >> 17; state ^= state << 5; a[2*i+j] = state; }
        if (i < ne*ne) { a[2*i] = edge[i/ne]; a[2*i+1] = edge[i%ne]; }
    }
    id<MTLCommandQueue> q = [d newCommandQueue];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLComputeCommandEncoder> en = [cb computeCommandEncoder];
    [en setComputePipelineState:ps]; [en setBuffer:in offset:0 atIndex:0]; [en setBuffer:out offset:0 atIndex:1];
    [en dispatchThreadgroups:MTLSizeMake(n/64,1,1) threadsPerThreadgroup:MTLSizeMake(64,1,1)];
    [en endEncoding]; [cb commit]; [cb waitUntilCompleted];
    if (cb.status == MTLCommandBufferStatusError) { fprintf(stderr, "%s\n", cb.error.localizedDescription.UTF8String); return 1; }
    const uint32_t *b = out.contents;
    for (unsigned i = 0; i < n; i++) {
        uint32_t x = a[2*i], y = a[2*i+1];
        uint64_t pa = (uint64_t)x * 4042322161u, pb = (uint64_t)y * 3u, pc = (uint64_t)x * 16u, pd = (uint64_t)y * 0x80000000u, pe = (uint64_t)x * y;
        uint64_t pf = (uint64_t)((int64_t)(int32_t)x * -7), pg = (uint64_t)((int64_t)(int32_t)x * (int32_t)y), ph = (uint64_t)y * x;
        uint32_t want[16] = {(uint32_t)pa, (uint32_t)(pa >> 32), (uint32_t)pb, (uint32_t)(pb >> 32), (uint32_t)(pc >> 32), (uint32_t)pd, (uint32_t)(pd >> 32),
                             (uint32_t)pe, (uint32_t)(pe >> 32), (uint32_t)pf, (uint32_t)(pf >> 32), (uint32_t)pg, (uint32_t)(pg >> 32), (uint32_t)pe, (uint32_t)(pe >> 32), (uint32_t)(ph >> 32)};
        for (unsigned k = 0; k < 16; k++)
            if (b[16*i+k] != want[k]) { fprintf(stderr, "result %u at %u (%08x, %08x): %08x, want %08x\n", k, i, x, y, b[16*i+k], want[k]); return 1; }
    }
    return 0;
 }
}
'''


SCALAR = ("template<typename T, typename U> static inline __attribute__((always_inline)) T spvMulExtended(uint l, uint r) { ulong p = ulong(l) * ulong(r); return T{U(p), U(p >> 32)}; }\n"
          "template<typename T, typename U> static inline __attribute__((always_inline)) T spvMulExtended(int l, int r) { long p = long(l) * long(r); return T{U(p), U(p >> 32)}; }\n")
checks = fails = 0
def check(name, ok, detail=""):
    global checks, fails
    checks += 1
    if not ok: fails += 1
    print(("✓ " if ok else "✗ ") + name + ("" if ok else "\n" + detail))

out = dshfn.fn("mul_extended", HEAD + KERNEL)
check("① 模板后补两个标量重载、调用处不动", out == HEAD[:-1] + SCALAR + "\n" + KERNEL, out[:1200])
check("① 再改一次不变", dshfn.fn("mul_extended", out) == out)
for name, src in (("没有模板", KERNEL), ("模板被改过", HEAD.replace("U(mulhi(l, r))", "U(mulhi(l, r) + 1)") + KERNEL),
                  ("两份模板", HEAD + HEAD + KERNEL), ("模板没有 optnone", HEAD.replace("[[clang::optnone]] ", "") + KERNEL)):
    check("② 不改：" + name, dshfn.fn("mul_extended", src) == src)

if shutil.which("xcrun") and shutil.which("clang"):
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp); (root / "test.metal").write_text(out); (root / "run.m").write_text(RUNNER)
        for sdk in ("macosx", "iphoneos"):
            subprocess.run(["xcrun", "-sdk", sdk, "metal", "-c", "-O2", "-fpreserve-invariance", str(root / "test.metal"), "-o", str(root / f"{sdk}.air")], check=True, capture_output=True)
        subprocess.run(["xcrun", "-sdk", "macosx", "metallib", str(root / "macosx.air"), "-o", str(root / "test.metallib")], check=True, capture_output=True)
        subprocess.run(["clang", "-fobjc-arc", "-O1", str(root / "run.m"), "-framework", "Metal", "-framework", "Foundation", "-o", str(root / "run")], check=True, capture_output=True)
        r = subprocess.run([str(root / "run"), str(root / "test.metallib")], capture_output=True, text=True)
        check("③ GPU 上 65536 组乘积与 CPU 64 位结果逐位相同", r.returncode == 0, r.stdout + r.stderr)
        subprocess.run(["xcrun", "-sdk", "macosx", "metal", "-S", "-emit-llvm", "-O2", str(root / "test.metal"), "-o", str(root / "test.ll")], check=True, capture_output=True)
        ll = (root / "test.ll").read_text(); body = ll[ll.index("@check("):]; body = body[:body.index("\n}\n")]
        calls = re.findall(r"call [^@]*@(\S*spvMulExtended\S*)\(", body)
        check("④ 编译后只剩向量那 1 个调用模板（%d 个）" % len(calls), len(calls) == 1 and "Dv2_j" in calls[0], str(calls))
else:
    check("③④ 要 Xcode 与 Metal（门禁机是 Mac）", False, "没有 xcrun / clang")

print(("✓ t_dsh_mulext：%d 项全过" % checks) if not fails else ("✗ t_dsh_mulext：%d 项里 %d 项不符" % (checks, fails)))
sys.exit(1 if fails else 0)
