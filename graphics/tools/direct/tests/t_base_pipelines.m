// 拉取基础管线随包归档探针（t_base_pipelines.sh 调）：按设备 nvn_mtl.m m4_render_desc(d, 拉取顶点, 片元, nil, unspec=1) 同一描述查 Metal 4 归档，命中再按一种画布特化。
//   t_base_pipelines <归档> <顶点库> <顶点函数> <片元库> <片元函数> <u|i> <采样数>
//   库按设备读法整份载入（拉取库 = 容器种类 55 那一段，片元 = 种类 0 批库整段，newLibraryWithData）；函数描述 = 库 + 名字，库里原函数声明了函数常量的套一层特化、常量不给（设备 spec_probe_fn）；
//   不带顶点描述；采样数照给、拓扑类未指定、alpha-to-coverage / alpha-to-one 关；颜色附件：u = 8 个全留空（设备 spec_probe_color unspec）；
//   i = 附件 0 留空、1–7 写 Invalid（改之前设备对没绑的附件的写法，反证用）。
//   命中后按「附件 0 = BGRA8、其余 Invalid、不混合、全写」特化（设备 hybrid_get 的 newRenderPipelineStateBySpecializationWithDescriptor）。
//   标准输出一行：hit=<0|1> spec=<0|1|->；退出 0 = 探针跑通（命中与否由调用方按期望判），2 = 归档 / 库 / 函数载不进
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>

static id<MTLLibrary> load(id<MTLDevice> dev, const char *path) {
    NSData *d = [NSData dataWithContentsOfFile:@(path)]; NSError *e = nil;
    return d ? [dev newLibraryWithData:dispatch_data_create(d.bytes, d.length, nil, DISPATCH_DATA_DESTRUCTOR_DEFAULT) error:&e] : nil;
}
static id fdesc(id<MTLLibrary> lib, NSString *name) API_AVAILABLE(macos(26.0)) {
    MTL4LibraryFunctionDescriptor *l = [MTL4LibraryFunctionDescriptor new]; l.library = lib; l.name = name;
    if (![lib newFunctionWithName:name].functionConstantsDictionary.count) return l;
    MTL4SpecializedFunctionDescriptor *s = [MTL4SpecializedFunctionDescriptor new]; s.functionDescriptor = l; s.constantValues = [MTLFunctionConstantValues new]; return s;
}
int main(int argc, char **argv) { @autoreleasepool {
    if (argc != 8) { fprintf(stderr, "usage: t_base_pipelines <archive> <vertex lib> <vertex fn> <fragment lib> <fragment fn> <u|i> <samples>\n"); return 2; }
    if (@available(macOS 26.0, *)) {
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); NSError *e = nil;
        id<MTL4Archive> ar = [dev newArchiveWithURL:[NSURL fileURLWithPath:@(argv[1])] error:&e];
        if (!ar) { printf("hit=0 spec=-\n"); fprintf(stderr, "archive: %s\n", e.localizedDescription.UTF8String); return 0; }   // 打不开（别的系统大版本 / 架构）也是没命中
        id<MTLLibrary> vl = load(dev, argv[2]), fl = load(dev, argv[4]);
        if (![vl newFunctionWithName:@(argv[3])] || ![fl newFunctionWithName:@(argv[5])]) { fprintf(stderr, "function not in its library\n"); return 2; }
        MTL4RenderPipelineDescriptor *p = [MTL4RenderPipelineDescriptor new];
        p.vertexFunctionDescriptor = fdesc(vl, @(argv[3])); p.fragmentFunctionDescriptor = fdesc(fl, @(argv[5]));
        p.rasterSampleCount = (NSUInteger)atoi(argv[7]); p.inputPrimitiveTopology = MTLPrimitiveTopologyClassUnspecified;
        p.alphaToCoverageState = MTL4AlphaToCoverageStateDisabled; p.alphaToOneState = MTL4AlphaToOneStateDisabled;
        for (int i = 0; i < 8; i++) { MTL4RenderPipelineColorAttachmentDescriptor *c = p.colorAttachments[i];
            if (argv[6][0] == 'i' && i) { c.pixelFormat = MTLPixelFormatInvalid; continue; }
            c.pixelFormat = MTLPixelFormatUnspecialized; c.writeMask = MTLColorWriteMaskUnspecialized; c.blendingState = MTL4BlendStateUnspecialized;
            c.sourceRGBBlendFactor = c.destinationRGBBlendFactor = c.sourceAlphaBlendFactor = c.destinationAlphaBlendFactor = MTLBlendFactorUnspecialized;
            c.rgbBlendOperation = c.alphaBlendOperation = MTLBlendOperationUnspecialized; }
        id<MTLRenderPipelineState> base = [ar newRenderPipelineStateWithDescriptor:p error:&e];
        if (!base) { printf("hit=0 spec=-\n"); return 0; }
        id<MTL4Compiler> comp = [dev newCompilerWithDescriptor:[MTL4CompilerDescriptor new] error:&e];
        MTL4RenderPipelineDescriptor *s = [p copy];
        for (int i = 0; i < 8; i++) { MTL4RenderPipelineColorAttachmentDescriptor *c = s.colorAttachments[i];
            c.pixelFormat = i ? MTLPixelFormatInvalid : MTLPixelFormatBGRA8Unorm; c.writeMask = MTLColorWriteMaskAll; c.blendingState = MTL4BlendStateDisabled;
            c.sourceRGBBlendFactor = c.sourceAlphaBlendFactor = MTLBlendFactorOne; c.destinationRGBBlendFactor = c.destinationAlphaBlendFactor = MTLBlendFactorZero;
            c.rgbBlendOperation = c.alphaBlendOperation = MTLBlendOperationAdd; }
        id<MTLRenderPipelineState> ps = comp ? [comp newRenderPipelineStateBySpecializationWithDescriptor:s pipeline:base error:&e] : nil;
        printf("hit=1 spec=%d\n", ps != nil);
        return 0;
    }
    fprintf(stderr, "Metal 4 needs macOS 26\n"); return 2;
} }
