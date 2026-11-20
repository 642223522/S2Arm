// 计算管线随包归档探针（t_cs_pipelines.sh 调）：按设备侧 pso_archive.h par_compute_ 同一描述查归档。
//   t_cs_pipelines <归档> <库段 metallib> <函数名> <加数>
//   库段按设备 lib_from_pack 的读法（整段字节 newLibraryWithData）载入；描述只设 computeFunction，binaryArchives = 这一个归档，MTLPipelineOptionFailOnBinaryArchiveMiss。
//   命中时再派发一次：64 个 float 从 i 起，核函数各加 <加数>，读回逐个核（证明拿到的是能跑的那条管线，不只是对象非空）。
//   标准输出一行：hit=<0|1> run=<0|1|->；退出 0 = 探针本身跑通（命中与否由调用方按期望判），2 = 归档 / 库 / 函数载不进
#import <Metal/Metal.h>
#import <Foundation/Foundation.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) { @autoreleasepool {
    if (argc != 5) { fprintf(stderr, "usage: t_cs_pipelines <archive> <metallib> <function> <addend>\n"); return 2; }
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); NSError *e = nil;
    MTLBinaryArchiveDescriptor *ad = [MTLBinaryArchiveDescriptor new]; ad.url = [NSURL fileURLWithPath:@(argv[1])];
    id<MTLBinaryArchive> ar = [dev newBinaryArchiveWithDescriptor:ad error:&e];
    if (!ar) { fprintf(stderr, "archive: %s\n", e.localizedDescription.UTF8String); return 2; }
    NSData *seg = [NSData dataWithContentsOfFile:@(argv[2])];
    id<MTLLibrary> lib = seg ? [dev newLibraryWithData:dispatch_data_create(seg.bytes, seg.length, nil, DISPATCH_DATA_DESTRUCTOR_DEFAULT) error:&e] : nil;
    id<MTLFunction> fn = [lib newFunctionWithName:@(argv[3])];
    if (!fn) { fprintf(stderr, "function %s not in %s\n", argv[3], argv[2]); return 2; }
    MTLComputePipelineDescriptor *d = [MTLComputePipelineDescriptor new]; d.computeFunction = fn; d.binaryArchives = @[ar];
    id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithDescriptor:d options:MTLPipelineOptionFailOnBinaryArchiveMiss reflection:nil error:&e];
    if (!ps) { printf("hit=0 run=-\n"); return 0; }
    enum { N = 64 }; float add = (float)atof(argv[4]);
    id<MTLBuffer> b = [dev newBufferWithLength:N * sizeof(float) options:MTLResourceStorageModeShared];
    float *p = b.contents; for (int i = 0; i < N; i++) p[i] = (float)i;
    id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer]; id<MTLComputeCommandEncoder> en = [cb computeCommandEncoder];
    [en setComputePipelineState:ps]; [en setBuffer:b offset:0 atIndex:0];
    [en dispatchThreads:MTLSizeMake(N, 1, 1) threadsPerThreadgroup:MTLSizeMake(32, 1, 1)]; [en endEncoding]; [cb commit]; [cb waitUntilCompleted];
    int ok = cb.status == MTLCommandBufferStatusCompleted;
    for (int i = 0; ok && i < N; i++) ok = p[i] == (float)i + add;
    printf("hit=1 run=%d\n", ok);
    return 0;
} }
