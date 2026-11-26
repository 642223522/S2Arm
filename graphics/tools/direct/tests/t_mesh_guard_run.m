// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// t_mesh_guard.py 的 GPU 跑器：t_mesh_guard_run <MSL 文件> <宏 0|1> <外层圈数> <内层圈数> → 打印「总圈数 GPU毫秒」（1 个线程，main0(device uint* b)，b = {外, 内, 结果}）
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
int main(int argc, char **argv) { @autoreleasepool {
    if (argc != 5) return 2;
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice(); if (!dev) return 2;
    NSError *err = nil;
    NSString *src = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:&err]; if (!src) return 2;
    MTLCompileOptions *o = [MTLCompileOptions new];
    if (atoi(argv[2])) o.preprocessorMacros = @{@"S2A_MESH_EMU": @1};
    id<MTLLibrary> lib = [dev newLibraryWithSource:src options:o error:&err];
    id<MTLFunction> fn = [lib newFunctionWithName:@"main0"];
    id<MTLComputePipelineState> ps = fn ? [dev newComputePipelineStateWithFunction:fn error:&err] : nil;
    if (!ps) { fprintf(stderr, "%s\n", err.localizedDescription.UTF8String); return 2; }
    id<MTLBuffer> b = [dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
    uint32_t *w = (uint32_t *)b.contents; w[0] = (uint32_t)strtoul(argv[3], 0, 10); w[1] = (uint32_t)strtoul(argv[4], 0, 10); w[2] = 0;
    id<MTLCommandQueue> q = [dev newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
    [e setComputePipelineState:ps]; [e setBuffer:b offset:0 atIndex:0];
    [e dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)]; [e endEncoding];
    [cb commit]; [cb waitUntilCompleted];
    if (cb.error) { fprintf(stderr, "%s\n", cb.error.localizedDescription.UTF8String); return 3; }
    printf("%u %.3f\n", w[2], (cb.GPUEndTime - cb.GPUStartTime) * 1e3);
    return 0;
}}
