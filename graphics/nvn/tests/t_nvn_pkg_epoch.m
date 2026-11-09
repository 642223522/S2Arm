// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Real virtual-pool mapping, production draw / RT resolution and independent
// GPU readback. Padding writes share a dirty page, but no texture byte changes.
#include "../gfx/nvn/nvn_mtl.m"
#include "../gfx/nvn/nvn_protos.h"
#include <signal.h>
extern void *h_nvnBootstrapLoader(const char *);
int s2a_direct_fault(void *, int, void *);
static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr,"SETUP FAIL %s:%d %s\n",__FILE__,__LINE__,#c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int ok=!!(c); failures+=!ok; printf("%s ",ok?"PASS":"FAIL"); printf(__VA_ARGS__); putchar('\n'); } while (0)
static void *api(const char *name) { void *p=h_nvnBootstrapLoader(name); REQUIRE(p); return p; }
#define API(name) ((NVNT_##name)api(#name))
enum { BLOCK=65536, W=8, H=8, CMD_SIZE=1<<20 };
typedef struct { NVNmemoryPool *phys; int64_t poff, voff; uint64_t size; int32_t storage_class, pad; } map_req;
static NVNdevice device; static NVNqueue queue;
static NVNmemoryPool physical, virtual_pool, commands_pool;
static NVNcommandBuffer commands; static NVNsync sync_object;
static NVNtexture backing_texture;
static uint8_t *physical_bytes, *command_bytes; static prog_t graphics;
static void fault(int s, siginfo_t *si, void *uc) { if(s2a_direct_fault(si->si_addr,1,uc)) return; signal(s,SIG_DFL); }
static void pool_init(NVNmemoryPool *p, void *memory, size_t n, int flags) {
    NVNmemoryPoolBuilder b; API(nvnMemoryPoolBuilderSetDefaults)(&b); API(nvnMemoryPoolBuilderSetDevice)(&b,&device);
    API(nvnMemoryPoolBuilderSetStorage)(&b,memory,n); API(nvnMemoryPoolBuilderSetFlags)(&b,flags); REQUIRE(API(nvnMemoryPoolInitialize)(p,&b));
}
static void finish(void) { uint64_t f=nvn_be_sub_commit(); REQUIRE(nvn_be_wait(f,10000000000ull)); REQUIRE(!mtl_last_commit_error()); }
static NvPkg *packed(tex_t *t) { id p=tex_get(t->serial); REQUIRE([p isKindOfClass:NvPkg.class]); REQUIRE(((NvPkg *)p)->sparse); return p; }
static void draw_red(tex_t *t, int whole) {
    rp_flush(); S.prog=&graphics; memset(&R.rt,0,sizeof R.rt); R.rt.n=1; R.rt.color[0]=t; R.has_rt=1;
    R.has_sc=!whole; R.sc=(p_scissor){.x=W-1,.y=H-1,.w=1,.h=1}; g_pso_dirty=1; args_dirty_all();
    p_draw d={.prim=NVN_DRAW_PRIMITIVE_TRIANGLES,.count=3,.instances=1}; draw(&d,NULL);
}
// Read the current resource without resolving it again (which is under test).
static void pixel(tex_t *t, unsigned x, unsigned y, uint8_t out[4]) {
    id<MTLTexture> image=packed(t)->tex; REQUIRE(image && image.width==W && image.height==H);
    id<MTLBuffer> b=[g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared]; REQUIRE(b);
    id<MTLCommandQueue> q=[g_dev newCommandQueue]; REQUIRE(q); id<MTLCommandBuffer> c=[q commandBuffer];
    id<MTLBlitCommandEncoder> e=[c blitCommandEncoder]; REQUIRE(e);
    [e copyFromTexture:image sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(x,y,0) sourceSize:MTLSizeMake(1,1,1)
        toBuffer:b destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:256];
    [e endEncoding]; [c commit]; [c waitUntilCompleted]; REQUIRE(c.status==MTLCommandBufferStatusCompleted); memcpy(out,b.contents,4);
}
static void expect(tex_t *t, unsigned x, unsigned y, int r, int g, int b, const char *what) {
    uint8_t p[4]; pixel(t,x,y,p); CHECK(p[0]==r && p[1]==g && p[2]==b && p[3]==255,
        "%s expected=(%d,%d,%d,255) actual=(%u,%u,%u,%u)",what,r,g,b,p[0],p[1],p[2],p[3]);
}
static void write_pixel(NVNtexture *t, uint8_t r, uint8_t g, uint8_t b) {
    (void)t;
    // CPU writes the mapped physical backing, not the virtual pool (Map=NULL).
    // Use the public writer with the exact same layout over that physical pool.
    const uint8_t p[4]={r,g,b,255}; NVNcopyRegion one={0,0,0,1,1,1}; API(nvnTextureWriteTexels)(&backing_texture,NULL,&one,p);
    API(nvnMemoryPoolFlushMappedRange)(&physical,0,4); REQUIRE(!memcmp(physical_bytes,p,4));
}
static void replay_wait(void) {
    // Record through the public API, replay its actual WAIT_SYNC operation.
    // The fence was published after the completed setup submission.
    static uint8_t control[4096];
    API(nvnCommandBufferAddControlMemory)(&commands,control,sizeof control);
    API(nvnCommandBufferAddCommandMemory)(&commands,&commands_pool,0,CMD_SIZE);
    API(nvnCommandBufferBeginRecording)(&commands); API(nvnCommandBufferWaitSync)(&commands,&sync_object);
    NVNcommandHandle h=API(nvnCommandBufferEndRecording)(&commands); REQUIRE(h);
    uint64_t before=g_pkg_epoch; nvn_be_exec((const uint8_t *)(uintptr_t)h); REQUIRE(g_pkg_epoch>before);
}
int main(void) { @autoreleasepool {
    setvbuf(stdout,NULL,_IOLBF,0); setenv("S2A_RES_SCALE","1",1); setenv("DM_PSO_ARCHIVE","0",1);
    struct sigaction sa={0}; sa.sa_sigaction=fault; sa.sa_flags=SA_SIGINFO; sigaction(SIGBUS,&sa,NULL); sigaction(SIGSEGV,&sa,NULL);
    NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); REQUIRE(API(nvnDeviceInitialize)(&device,&db));
    NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb,&device); REQUIRE(API(nvnQueueInitialize)(&queue,&qb));
    REQUIRE(!posix_memalign((void **)&physical_bytes,BLOCK,BLOCK));
    for(unsigned i=0;i<BLOCK;i+=4) { physical_bytes[i]=0; physical_bytes[i+1]=0; physical_bytes[i+2]=255; physical_bytes[i+3]=255; }
    pool_init(&physical,physical_bytes,BLOCK,NVN_MEMORY_POOL_FLAGS_PHYSICAL|NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED|NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    pool_init(&virtual_pool,NULL,BLOCK,NVN_MEMORY_POOL_FLAGS_VIRTUAL|NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS|NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    map_req mapping={&physical,0,0,BLOCK,0,0}; REQUIRE(API(nvnMemoryPoolMapVirtual)(&virtual_pool,1,(const NVNmappingRequest *)&mapping));
    REQUIRE(!posix_memalign((void **)&command_bytes,BLOCK,CMD_SIZE)); memset(command_bytes,0,CMD_SIZE);
    pool_init(&commands_pool,command_bytes,CMD_SIZE,NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED|NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    REQUIRE(API(nvnCommandBufferInitialize)(&commands,&device)); REQUIRE(API(nvnSyncInitialize)(&sync_object,&device));
    NVNtexture texture={0}; NVNtextureBuilder tb; API(nvnTextureBuilderSetDefaults)(&tb); API(nvnTextureBuilderSetDevice)(&tb,&device);
    API(nvnTextureBuilderSetTarget)(&tb,NVN_TEXTURE_TARGET_2D); API(nvnTextureBuilderSetSize2D)(&tb,W,H); API(nvnTextureBuilderSetLevels)(&tb,1);
    API(nvnTextureBuilderSetFormat)(&tb,NVN_FORMAT_RGBA8); API(nvnTextureBuilderSetStorage)(&tb,&virtual_pool,0); REQUIRE(API(nvnTextureInitialize)(&texture,&tb));
    tex_t *t=(tex_t *)&texture; size_t padding=t->L.size+16;
    API(nvnTextureBuilderSetStorage)(&tb,&physical,0); REQUIRE(API(nvnTextureInitialize)(&backing_texture,&tb));
    REQUIRE(((tex_t *)&backing_texture)->L.size==t->L.size);
    REQUIRE(nvn_sparse_pool(t->pool) && t->L.size>0 && padding<4096 && padding<(size_t)getpagesize());
    REQUIRE(nvn_sparse_mapped(t->pool,(uint64_t)(uintptr_t)t->mem,BLOCK));
    const op_hdr empty={OP_END,sizeof(op_hdr)}; nvn_be_exec((const uint8_t *)&empty); printf("BACKEND Metal%d sparse bytes=%llu padding=%zu\n",g_m3?3:4,(unsigned long long)t->L.size,padding);
    NSError *error=nil; id<MTLLibrary> lib=[g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nvertex float4 tri(uint i [[vertex_id]]) { const float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[i],0,1); }\nfragment float4 red() { return float4(1,0,0,1); }\n" options:nil error:&error];
    if(!lib) fprintf(stderr,"MSL %s\n",error.localizedDescription.UTF8String); REQUIRE(lib);
    NvProg *np=[NvProg new];
    for(int stage=0;stage<2;stage++) { NvShader *s=[NvShader new]; s->stage=stage; s->fn=[lib newFunctionWithName:stage?@"red":@"tri"]; REQUIRE(s->fn);
        strlcpy(s->key,stage?"eeeeeeeeeeeeeeee_b":"ffffffffffffffff_b",sizeof s->key); s->rf.pos_attr=-1; s->rf.has_user=1; np->sh[stage]=s; }
    np->sh[1]->rf.color_known=1; np->sh[1]->rf.color_mask=1;
    graphics=(prog_t){.magic=MAGIC('P','R','O','G'),.serial=nvn_new_serial()}; serial_put(graphics.serial,np);
    // Before the first submission, epoch zero cannot mean "already checked".
    // Both resolutions happen before sub_begin; submitting only drains uploads.
    REQUIRE(g_pkg_epoch==0); REQUIRE(tex_mtl(t)); write_pixel(&texture,0,255,0); REQUIRE(tex_mtl(t));
    nvn_be_sub_begin(); finish(); expect(t,0,0,0,255,0,"before first submission repeated CPU resolution sees green");
    write_pixel(&texture,0,0,255);
    nvn_be_sub_begin(); REQUIRE(tex_mtl(t)); finish(); uint8_t initial[4]; pixel(t,0,0,initial); REQUIRE(initial[0]==0 && initial[1]==0 && initial[2]==255 && initial[3]==255);
    nvn_be_sub_begin(); state_reset(); draw_red(t,1); finish(); expect(t,0,0,255,0,0,"production GPU writer");
    API(nvnQueueFenceSync)(&queue,&sync_object,NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE,0); API(nvnQueueFinish)(&queue);
    nvn_be_sub_begin(); state_reset(); draw_red(t,1); rp_flush();
    uint64_t epoch=g_pkg_epoch; physical_bytes[padding]^=1;
    API(nvnMemoryPoolFlushMappedRange)(&physical,(ptrdiff_t)padding,1); REQUIRE(g_pkg_epoch==epoch);
    draw_red(t,0); finish(); expect(t,0,0,255,0,0,"same epoch padding write must preserve remote GPU red");
    write_pixel(&texture,0,255,0); nvn_be_sub_begin(); state_reset(); draw_red(t,0); finish(); expect(t,0,0,0,255,0,"next submission sees CPU green");
    nvn_be_sub_begin(); state_reset(); draw_red(t,0); rp_flush(); write_pixel(&texture,255,255,0); replay_wait(); draw_red(t,0); finish();
    expect(t,0,0,255,255,0,"real WaitSync starts new check epoch and sees CPU yellow");
    API(nvnTextureFinalize)(&texture);
    API(nvnTextureFinalize)(&backing_texture);
    printf("%s t_nvn_pkg_epoch: %u checks, %u failures\n",failures?"FAIL":"✓",checks,failures); return failures?1:0;
} }
