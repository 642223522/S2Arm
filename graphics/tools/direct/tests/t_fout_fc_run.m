// t_fout_fc.py 的 GPU 一侧：每个 .metal 编库，名字以 main0 结尾的片元入口按一组函数常量特化、建管线、画满 4×4、读回 (1,1) 像素按字打印，由 t_fout_fc.py 对手写期望。
// 顶点固定输出 user(locn0) = (1.5, 2, 3, 0.25)。每行：CASE <文件序号> <入口> <例名> OK <附件 0 的字…> | <附件 1 的字…>，建不出打 CASE … FAIL <原因>
// 用法：t_fout_fc_run <.metal>…
#import <Metal/Metal.h>
#include <stdio.h>
typedef struct { const char *nm; uint32_t fu, fs; int at; bool ms, setfu, setfs; MTLPixelFormat f0, f1; int dual; } cs_t;
int main(int argc, char **argv) { @autoreleasepool {
    id<MTLDevice> d = MTLCreateSystemDefaultDevice(); MTLCompileOptions *o = [MTLCompileOptions new]; o.languageVersion = MTLLanguageVersion3_1; NSError *e = nil;
    id<MTLLibrary> VL = [d newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nstruct VO { float4 p [[position]]; float4 a [[user(locn0)]]; };\n"
        "vertex VO vmain(uint i [[vertex_id]]) { VO o; float2 uv = float2((i << 1) & 2, i & 2); o.p = float4(uv * 2 - 1, 0, 1); o.a = float4(1.5, 2.0, 3.0, 0.25); return o; }\n" options:o error:&e];
    if (!VL) { printf("VS FAIL %s\n", e.localizedDescription.UTF8String); return 1; }
    const MTLPixelFormat F = MTLPixelFormatRGBA32Float, U = MTLPixelFormatRGBA32Uint, S = MTLPixelFormatRGBA32Sint, H = MTLPixelFormatRGBA16Float, N = MTLPixelFormatInvalid;
    cs_t cs[] = {
        {"none", 0, 0, 0, 0, 0, 0, F, F, 0}, {"u1", 1, 0, 0, 0, 1, 0, U, F, 0}, {"s2", 0, 2, 0, 0, 0, 1, F, S, 0}, {"u1s2", 1, 2, 0, 0, 1, 1, U, S, 0},
        {"dual", 0, 0x100, 0, 0, 0, 1, H, N, 1}, {"u1_never", 1, 0, 1, 0, 1, 0, U, F, 0}, {"u1_always_msoff", 1, 0, 8, 1, 1, 0, U, F, 0}, {"none_on_uint", 0, 0, 0, 0, 0, 0, U, F, 0} };
    for (int a = 1; a < argc; a++) {
        id<MTLLibrary> L = [d newLibraryWithSource:[NSString stringWithContentsOfFile:@(argv[a]) encoding:NSUTF8StringEncoding error:nil] options:o error:&e];
        if (!L) { printf("LIB FAIL %d: %s\n", a, e.localizedDescription.UTF8String); continue; }
        for (NSString *fn in [L.functionNames sortedArrayUsingSelector:@selector(compare:)]) { if (![fn hasSuffix:@"main0"]) continue;
            for (unsigned c = 0; c < sizeof cs / sizeof cs[0]; c++) { cs_t k = cs[c];
                MTLFunctionConstantValues *cv = [MTLFunctionConstantValues new];
                if (k.setfu) [cv setConstantValue:&k.fu type:MTLDataTypeUInt withName:@"S2A_FU"];
                if (k.setfs) [cv setConstantValue:&k.fs type:MTLDataTypeUInt withName:@"S2A_FS"];
                if (k.at) [cv setConstantValue:&k.at type:MTLDataTypeInt withName:@"S2A_AT"];
                if (k.ms) [cv setConstantValue:&k.ms type:MTLDataTypeBool withName:@"S2A_MSOFF"];
                NSError *e2 = nil; id<MTLFunction> f = [L newFunctionWithName:fn constantValues:cv error:&e2];
                if (!f) { printf("CASE %d %s %s FAIL spec: %s\n", a, fn.UTF8String, k.nm, e2.localizedDescription.UTF8String); continue; }
                MTLRenderPipelineDescriptor *p = [MTLRenderPipelineDescriptor new]; p.vertexFunction = [VL newFunctionWithName:@"vmain"]; p.fragmentFunction = f;
                p.colorAttachments[0].pixelFormat = k.f0; p.colorAttachments[1].pixelFormat = k.f1;
                if (k.dual) { MTLRenderPipelineColorAttachmentDescriptor *c0 = p.colorAttachments[0]; c0.blendingEnabled = YES;
                    c0.sourceRGBBlendFactor = MTLBlendFactorSource1Color; c0.sourceAlphaBlendFactor = MTLBlendFactorSource1Alpha; c0.destinationRGBBlendFactor = c0.destinationAlphaBlendFactor = MTLBlendFactorZero; }
                id<MTLRenderPipelineState> ps = [d newRenderPipelineStateWithDescriptor:p error:&e2];
                if (!ps) { printf("CASE %d %s %s FAIL pso\n", a, fn.UTF8String, k.nm); continue; }
                MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new]; id<MTLTexture> t[2] = {nil, nil};
                for (int i = 0; i < 2; i++) { MTLPixelFormat pf = i ? k.f1 : k.f0; if (!pf) continue;
                    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:4 height:4 mipmapped:NO]; td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModeShared;
                    t[i] = [d newTextureWithDescriptor:td]; rp.colorAttachments[i].texture = t[i]; rp.colorAttachments[i].loadAction = MTLLoadActionClear; rp.colorAttachments[i].storeAction = MTLStoreActionStore;
                    rp.colorAttachments[i].clearColor = MTLClearColorMake(0, 0, 0, 0); }
                id<MTLCommandBuffer> cb = [[d newCommandQueue] commandBuffer]; id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
                float aref = 0.5f; [en setFragmentBytes:&aref length:sizeof aref atIndex:30];
                [en setRenderPipelineState:ps]; [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [en endEncoding]; [cb commit]; [cb waitUntilCompleted];
                printf("CASE %d %s %s OK", a, fn.UTF8String, k.nm);
                for (int i = 0; i < 2; i++) { if (!t[i]) continue; if (i) printf(" |");
                    if (t[i].pixelFormat == H) { uint16_t w[4]; [t[i] getBytes:w bytesPerRow:32 fromRegion:MTLRegionMake2D(1, 1, 1, 1) mipmapLevel:0]; for (int j = 0; j < 4; j++) printf(" %04x", w[j]); }
                    else { uint32_t w[4]; [t[i] getBytes:w bytesPerRow:64 fromRegion:MTLRegionMake2D(1, 1, 1, 1) mipmapLevel:0]; for (int j = 0; j < 4; j++) printf(" %08x", w[j]); } }
                printf("\n"); } } }
    return 0;
}}
