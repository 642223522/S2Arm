// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// NVN texture storage is the same memory that CopyBufferToBuffer reads.
#include "nvn_protos.h"
#import <Foundation/Foundation.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern void *h_nvnBootstrapLoader(const char *name);
extern int mtl_last_commit_error(void);
extern int nvn_gob_switch2;
static NVNdevice device;
static NVNqueue queue;
static NVNmemoryPool pool;
static NVNcommandBuffer commands;
static void *storage;
static size_t texture_offset = 2 << 20;
static unsigned cases, checks, fails;
static const char *phase = "初始化";
enum { POOL_SIZE = 16 << 20, COMMAND_SIZE = 1 << 20, READ_OFFSET = 1 << 20, SIDE = 8 };
#define REQUIRE(x) do { checks++; if (!(x)) { fprintf(stderr,"FAIL [%s] %s:%d: %s\n",phase,__FILE__,__LINE__,#x); exit(1); } } while (0)
static void *load(const char *name) { void *entry = h_nvnBootstrapLoader(name); REQUIRE(entry != NULL); return entry; }
#define API(name) ((NVNT_##name)load(#name))
static void setup(void) {
    NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); REQUIRE(API(nvnDeviceInitialize)(&device,&db));
    NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb,&device);
    REQUIRE(API(nvnQueueInitialize)(&queue,&qb)); REQUIRE(posix_memalign(&storage,65536,POOL_SIZE)==0); memset(storage,0,POOL_SIZE);
    NVNmemoryPoolBuilder pb; API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb,&device);
    API(nvnMemoryPoolBuilderSetStorage)(&pb,storage,POOL_SIZE);
    API(nvnMemoryPoolBuilderSetFlags)(&pb,NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED|NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    REQUIRE(API(nvnMemoryPoolInitialize)(&pool,&pb)); REQUIRE(API(nvnCommandBufferInitialize)(&commands,&device));
    static uint8_t control[16384]; API(nvnCommandBufferAddControlMemory)(&commands,control,sizeof control);
}
static void begin(void) { API(nvnCommandBufferAddCommandMemory)(&commands,&pool,0,COMMAND_SIZE); API(nvnCommandBufferBeginRecording)(&commands); }
static void submit(void) {
    NVNcommandHandle handle=API(nvnCommandBufferEndRecording)(&commands); REQUIRE(handle!=0);
    API(nvnQueueSubmitCommands)(&queue,1,&handle); API(nvnQueueFinish)(&queue); REQUIRE(mtl_last_commit_error()==0);
}
// 下一块贴图存储的位置与大小（不建贴图）：调用方可以先往这块存储写内容，再建贴图
static void builder(NVNtextureBuilder *b, size_t *off, size_t *bytes) {
    API(nvnTextureBuilderSetDefaults)(b); API(nvnTextureBuilderSetDevice)(b,&device); API(nvnTextureBuilderSetTarget)(b,NVN_TEXTURE_TARGET_2D);
    API(nvnTextureBuilderSetSize2D)(b,SIDE,SIDE); API(nvnTextureBuilderSetLevels)(b,1); API(nvnTextureBuilderSetFormat)(b,NVN_FORMAT_RGBA8);
    size_t al=API(nvnTextureBuilderGetStorageAlignment)(b); *bytes=API(nvnTextureBuilderGetStorageSize)(b); REQUIRE(al && *bytes);
    // 每张贴图独占 64 KB：建贴图会给它的页加写保护（tex_flush_upload 缺省开，hle_nvn.c ft_add），本进程没有宿主的写保护信号处理，下一张的 CPU 写不能落在同一页
    al=al>65536?al:65536; texture_offset=(texture_offset+al-1)/al*al; *off=texture_offset; REQUIRE(*off+*bytes<=POOL_SIZE);
}
static void make(NVNtexture *t, NVNtextureBuilder *b, size_t off, size_t bytes, int advance) {
    API(nvnTextureBuilderSetStorage)(b,&pool,(ptrdiff_t)off); REQUIRE(API(nvnTextureInitialize)(t,b)); if (advance) texture_offset=off+bytes;
}
static void copy_case(int together, int gpu_source, int partial) {
    cases++; phase = together ? "同一提交内搬移" : "分次提交搬移";
    NVNtexture a={0},b={0}; NVNtextureBuilder ba,bb; size_t ao,an,bo,bn;
    builder(&ba,&ao,&an); make(&a,&ba,ao,an,1);
    builder(&bb,&bo,&bn); make(&b,&bb,bo,bn,1); REQUIRE(an==bn);
    const uint8_t want[4]={0x11,0x22,0x33,0x44}, patch[4]={0x99,0xaa,0xbb,0xcc};
    const size_t linear=READ_OFFSET+cases*65536, patch_at=linear+4096;
    for(unsigned i=0;i<SIDE*SIDE;i++) memcpy((uint8_t*)storage+linear+4*i,gpu_source?(uint8_t[4]){0,0,0,0}:want,4);
    for(unsigned i=0;i<36;i++) memcpy((uint8_t*)storage+patch_at+4*i,patch,4);
    memset((uint8_t*)storage+READ_OFFSET,0xa5,SIDE*SIDE*4);
    NVNbufferAddress base=API(nvnMemoryPoolGetBufferAddress)(&pool);
    NVNcopyRegion r={0,0,0,SIDE,SIDE,1}, pr={1,1,0,6,6,1};
    begin();
    if(gpu_source) API(nvnCommandBufferClearBuffer)(&commands,base+linear,SIDE*SIDE*4,0x44332211);
    API(nvnCommandBufferCopyBufferToTexture)(&commands,base+linear,&a,NULL,&r,0);
    if(partial) API(nvnCommandBufferCopyBufferToTexture)(&commands,base+patch_at,&a,NULL,&pr,0);
    if(!together){submit();begin();}
    API(nvnCommandBufferCopyBufferToBuffer)(&commands,base+ao,base+bo,an,0);
    if(!together){submit();begin();}
    API(nvnCommandBufferCopyTextureToBuffer)(&commands,&b,NULL,&r,base+READ_OFFSET,0);submit();
    unsigned bad=0; const uint8_t *out=(const uint8_t*)storage+READ_OFFSET;
    for(unsigned y=0;y<SIDE;y++) for(unsigned x=0;x<SIDE;x++) {
        const uint8_t *expected=partial&&x>=1&&x<7&&y>=1&&y<7?patch:want;
        bad+=memcmp(out+4*(y*SIDE+x),expected,4)!=0;
    }
    checks++; fails+=bad!=0;
    printf("%s %s CPU/GPU 源=%d 局部=%d：%u/%u 纹素不符\n",bad?"FAIL":"PASS",phase,gpu_source,partial,bad,SIDE*SIDE);
    API(nvnTextureFinalize)(&a); API(nvnTextureFinalize)(&b);
}
// 带 SPARSE 标志、放在普通（物理）池里的贴图（某款开局 8x8 四级、池标志 0xe2）：同样按池字节存放，上传也要写回池存储，
//   之后按字节搬到另一张贴图再读回仍是上传的内容
static void sparse_case(void) {
    cases++; phase="物理池里的 SPARSE 贴图";
    NVNtexture a={0},b={0}; NVNtextureBuilder ba,bb; size_t ao,an,bo,bn;
    builder(&ba,&ao,&an); API(nvnTextureBuilderSetFlags)(&ba,NVN_TEXTURE_FLAGS_SPARSE); an=API(nvnTextureBuilderGetStorageSize)(&ba); make(&a,&ba,ao,an,1);
    builder(&bb,&bo,&bn); API(nvnTextureBuilderSetFlags)(&bb,NVN_TEXTURE_FLAGS_SPARSE); bn=API(nvnTextureBuilderGetStorageSize)(&bb); make(&b,&bb,bo,bn,1); REQUIRE(an==bn);
    const uint8_t want[4]={0x5a,0x6b,0x7c,0x8d}; const size_t linear=READ_OFFSET+cases*65536;
    for(unsigned i=0;i<SIDE*SIDE;i++) memcpy((uint8_t*)storage+linear+4*i,want,4);
    memset((uint8_t*)storage+READ_OFFSET,0xa5,SIDE*SIDE*4);
    NVNbufferAddress base=API(nvnMemoryPoolGetBufferAddress)(&pool); NVNcopyRegion r={0,0,0,SIDE,SIDE,1};
    begin();
    API(nvnCommandBufferCopyBufferToTexture)(&commands,base+linear,&a,NULL,&r,0);
    API(nvnCommandBufferCopyBufferToBuffer)(&commands,base+ao,base+bo,an,0);
    API(nvnCommandBufferCopyTextureToBuffer)(&commands,&b,NULL,&r,base+READ_OFFSET,0); submit();
    unsigned bad=0; for(unsigned i=0;i<SIDE*SIDE;i++) bad+=memcmp((uint8_t*)storage+READ_OFFSET+4*i,want,4)!=0;
    checks++; fails+=bad!=0;
    printf("%s %s：%u/%u 纹素不符\n",bad?"FAIL":"PASS",phase,bad,SIDE*SIDE);
    API(nvnTextureFinalize)(&a); API(nvnTextureFinalize)(&b);
}
// 不用被测的 swizzle / deswizzle 算期望：手算一个 GOB 内 16 字节段的地址。
static void gob_case(int gob2, int alias) {
    phase=alias?"线性源与贴图存储重叠":"GOB 原始字节";
    nvn_gob_switch2=gob2;
    NVNtexture a={0},b={0}; NVNtextureBuilder ba,bb; size_t ao,an,bo,bn;
    builder(&ba,&ao,&an); make(&a,&ba,ao,an,1);
    builder(&bb,&bo,&bn); make(&b,&bb,bo,bn,1);
    size_t input=READ_OFFSET+65536;
    uint8_t pattern[SIDE*SIDE*4];
    for(unsigned i=0;i<sizeof pattern;i++) pattern[i]=(uint8_t)(17+37*i);
    memcpy((uint8_t*)storage+input,pattern,sizeof pattern);
    NVNbufferAddress base=API(nvnMemoryPoolGetBufferAddress)(&pool);
    NVNcopyRegion r={0,0,0,SIDE,SIDE,1};
    begin();
    // 写保护页通过 GPU 填好，源仍是普通线性行，目标是同一段内存的块线性布局。
    if(alias) API(nvnCommandBufferCopyBufferToBuffer)(&commands,base+input,base+ao,sizeof pattern,0);
    API(nvnCommandBufferCopyBufferToTexture)(&commands,base+(alias?ao:input),&a,NULL,&r,0);
    API(nvnCommandBufferCopyBufferToBuffer)(&commands,base+ao,base+bo,an,0);
    API(nvnCommandBufferCopyTextureToBuffer)(&commands,&b,NULL,&r,base+READ_OFFSET,0);submit();
    unsigned bad=0;
    for(unsigned y=0;y<SIDE;y++) for(unsigned x=0;x<SIDE*4;x++) {
        unsigned at=gob2?(x/32)*256+(y/4)*128+(x%32/16)*64+(y%4/2)*32+(y%2)*16+x%16
                       :(x/32)*256+(y/2)*64+(x%32/16)*32+(y%2)*16+x%16;
        bad+=((uint8_t*)storage)[ao+at]!=pattern[y*SIDE*4+x];
    }
    checks++; fails+=bad!=0;
    printf("%s %s Switch%d：原始字节 %u/256 不符\n",bad?"FAIL":"PASS",phase,gob2+1,bad);
    bad=memcmp((uint8_t*)storage+READ_OFFSET,pattern,sizeof pattern)!=0;
    checks++; fails+=bad;
    printf("%s %s Switch%d：搬移后线性读回\n",bad?"FAIL":"PASS",phase,gob2+1);
    API(nvnTextureFinalize)(&a); API(nvnTextureFinalize)(&b); nvn_gob_switch2=0;
}
static void shaped_builder(NVNtextureBuilder *b, size_t *off, size_t *bytes, NVNformat format,
                            NVNtextureTarget target, int w, int h, int depth, int levels) {
    API(nvnTextureBuilderSetDefaults)(b); API(nvnTextureBuilderSetDevice)(b,&device);
    API(nvnTextureBuilderSetTarget)(b,target); API(nvnTextureBuilderSetSize3D)(b,w,h,depth);
    API(nvnTextureBuilderSetLevels)(b,levels); API(nvnTextureBuilderSetFormat)(b,format);
    size_t align=API(nvnTextureBuilderGetStorageAlignment)(b); *bytes=API(nvnTextureBuilderGetStorageSize)(b);
    REQUIRE(align && *bytes); align=align>65536?align:65536;
    texture_offset=(texture_offset+align-1)/align*align; *off=texture_offset; REQUIRE(*off+*bytes<=POOL_SIZE);
}
static uint8_t pattern_byte(unsigned lv, unsigned z, unsigned y, unsigned x) { return (uint8_t)(19+lv*41+z*73+y*29+x*13); }
// 以原创字节填每个压缩块 / 像素；比较原始字节，不依赖 BC 解码器给期望。
static void shaped_case(NVNformat format, NVNtextureTarget target, unsigned w, unsigned h, unsigned depth, unsigned levels) {
    phase="压缩 / 多层 / 三维存储搬移";
    NVNtexture a={0},b={0}; NVNtextureBuilder ba,bb; size_t ao,an,bo,bn;
    shaped_builder(&ba,&ao,&an,format,target,w,h,depth,levels); make(&a,&ba,ao,an,1);
    shaped_builder(&bb,&bo,&bn,format,target,w,h,depth,levels);
    // 目的地原有非零旧字节：同一提交里的 GPU 搬移不能误走 CPU 快照上传。
    memset((uint8_t*)storage+bo,0xa5,bn); make(&b,&bb,bo,bn,1); REQUIRE(an==bn);
    unsigned bw=format==NVN_FORMAT_RGBA8?1:4, bpb=format==NVN_FORMAT_RGBA8?4:format==NVN_FORMAT_RGBA_DXT1?8:16;
    size_t input=READ_OFFSET+65536, at=input;
    NVNbufferAddress base=API(nvnMemoryPoolGetBufferAddress)(&pool);
    begin();
    for(unsigned lv=0;lv<levels;lv++) {
        unsigned lw=w>>lv?w>>lv:1, lh=h>>lv?h>>lv:1;
        unsigned dz=target==NVN_TEXTURE_TARGET_3D?(depth>>lv?depth>>lv:1):depth;
        size_t bytes=((lw+bw-1)/bw)*bpb, rows=(lh+bw-1)/bw, row=bytes+16, image=row*rows+32;
        REQUIRE(at+image*dz<2<<20);
        for(unsigned z=0;z<dz;z++) for(unsigned y=0;y<rows;y++) for(unsigned x=0;x<bytes;x++)
            ((uint8_t*)storage)[at+z*image+y*row+x]=pattern_byte(lv,z,y,x);
        NVNtextureView v; API(nvnTextureViewSetDefaults)(&v); API(nvnTextureViewSetLevels)(&v,lv,1);
        NVNcopyRegion r={0,0,0,(int)lw,(int)lh,(int)dz};
        API(nvnCommandBufferSetCopyRowStride)(&commands,row); API(nvnCommandBufferSetCopyImageStride)(&commands,image);
        API(nvnCommandBufferCopyBufferToTexture)(&commands,base+at,&a,&v,&r,0);
        at=(at+image*dz+255)&~(size_t)255;
    }
    API(nvnCommandBufferCopyBufferToBuffer)(&commands,base+ao,base+bo,an,0);
    // 首层读回也放在搬移的同一提交里，后续层另提交读取。
    for(unsigned lv=0;lv<levels;lv++) {
        unsigned lw=w>>lv?w>>lv:1, lh=h>>lv?h>>lv:1;
        unsigned dz=target==NVN_TEXTURE_TARGET_3D?(depth>>lv?depth>>lv:1):depth;
        size_t bytes=((lw+bw-1)/bw)*bpb, rows=(lh+bw-1)/bw;
        NVNtextureView v; API(nvnTextureViewSetDefaults)(&v); API(nvnTextureViewSetLevels)(&v,lv,1);
        NVNcopyRegion r={0,0,0,(int)lw,(int)lh,(int)dz};
        API(nvnCommandBufferSetCopyRowStride)(&commands,0); API(nvnCommandBufferSetCopyImageStride)(&commands,0);
        API(nvnCommandBufferCopyTextureToBuffer)(&commands,&b,&v,&r,base+READ_OFFSET,0); submit();
        unsigned bad=0;
        for(unsigned z=0;z<dz;z++) for(unsigned y=0;y<rows;y++) for(unsigned x=0;x<bytes;x++)
            bad+=((uint8_t*)storage)[READ_OFFSET+(z*rows+y)*bytes+x]!=pattern_byte(lv,z,y,x);
        checks++; fails+=bad!=0;
        printf("%s format=%#x target=%d mip=%u：%u/%zu 字节不符\n",bad?"FAIL":"PASS",format,target,lv,bad,bytes*rows*dz);
        if(lv+1<levels) begin();
    }
    API(nvnTextureFinalize)(&a); API(nvnTextureFinalize)(&b);
}
int main(void) { @autoreleasepool {
    setup();
    for(int together=0;together<2;together++) for(int gpu=0;gpu<2;gpu++) for(int partial=0;partial<2;partial++) copy_case(together,gpu,partial);
    for(int gob=0;gob<2;gob++) for(int alias=0;alias<2;alias++) gob_case(gob,alias);
    sparse_case();
    shaped_case(NVN_FORMAT_RGBA_DXT1,NVN_TEXTURE_TARGET_2D,64,64,1,7);
    shaped_case(NVN_FORMAT_RGBA_DXT5,NVN_TEXTURE_TARGET_2D_ARRAY,32,16,3,5);
    shaped_case(NVN_FORMAT_RGBA8,NVN_TEXTURE_TARGET_3D,17,9,5,3);
    printf("%s t_nvn_storage_copy：%u checks, %u failures\n",fails?"✗":"✓",checks,fails);return fails?1:0;
} }
