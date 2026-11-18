// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// NVN 的清除覆盖绑定视图的全部层（不带层范围的视图 = 整张贴图），不只是不分层的遍挂上的那一层（layer_clears，移植自 nxnative ffdf67de）。
//   01002FC00412C000：点光源的六面阴影立方体（D32F_S8）在捕获一遍式几何着色器顶点的那一遍里清除，那一遍不分层：只清到第 0 面，
//   1-5 面留着 0 深度，那里的片元全部过不了深度测试，比较采样读成全阴影，灯光只从一面照出来。
// 期望按构造写死：每层先填旧值（深度 0.75 / RGBA8 0x11223344），命令流 [清除][结束] 交 nvn_be_exec 回放，读回每一层：
//   视图范围内的层是新值（深度 0.25 / RGBA8 0.5 = 0x80808080），范围外的层还是旧值。
//   ① 立方体深度清除、不带视图：六面全清      ② 立方体深度清除、只看第 2 面的视图：只清第 2 面
//   ③ 2D 数组颜色清除、不带视图：四层全清     ④ 视图从第 1 层起（层数 0 = 到底）：清 1-3
//   ⑤ 视图第 1 层起两层：清 1-2              ⑥ 对照：普通 2D 目标，一层（修前修后都对，证明框架本身没问题）
// 反证：DM_NVN_LAYER_CLEAR=0（关掉 layer_clears）→ ① ③ ④ ⑤ 红（只清到挂上的那一层）
#include "../gfx/nvn/nvn_mtl.m"

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr,"SETUP FAIL %s:%d %s\n",__FILE__,__LINE__,#c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int ok=!!(c); failures+=!ok; printf("%s ",ok?"✓":"✗"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

enum { W = 4, OLD_D = 0x3f400000, NEW_D = 0x3e800000, OLD_C = 0x11223344, NEW_C = 0x80808080 };   // 深度 0.75 → 0.25；RGBA8 → 每通道 0.5

static uint8_t g_ops[256]; static size_t g_on;
static void put(uint32_t op, const void *pay, uint32_t n) {
    uint32_t sz=(uint32_t)((8+n+7)&~7u); REQUIRE(g_on+sz<=sizeof g_ops);
    op_hdr h={op,sz}; memcpy(g_ops+g_on,&h,8); memset(g_ops+g_on+8,0,sz-8); if (n) memcpy(g_ops+g_on+8,pay,n); g_on+=sz;
}
static NSUInteger slices_of(id<MTLTexture> t) {
    return t.textureType == MTLTextureType3D ? t.depth : t.arrayLength * (t.textureType == MTLTextureTypeCube || t.textureType == MTLTextureTypeCubeArray ? 6 : 1);
}

int main(void) { @autoreleasepool {
    setvbuf(stdout,NULL,_IOLBF,0);
    char map[]="/tmp/t_lyclr_map_XXXXXX",user[]="/tmp/t_lyclr_user_XXXXXX";
    int fd=mkstemp(map); REQUIRE(fd>=0); close(fd); fd=mkstemp(user); REQUIRE(fd>=0); close(fd);
    setenv("DM_NVN_SHMAP",map,1); setenv("DM_PSO_USER",user,1); setenv("DM_PSO_ARCHIVE","0",1);
    unsetenv("DM_NVN_TBDR"); mtl_init();
    printf("BACKEND Metal%d，层清除 %s\n",g_m3?3:4,lyc_on()?"开":"关（DM_NVN_LAYER_CLEAR=0，反证）");
    const op_hdr empty={OP_END,sizeof(op_hdr)}; nvn_be_exec((const uint8_t *)&empty);
    id<MTLCommandQueue> queue=[g_dev newCommandQueue];
    uint8_t *memory=NULL; REQUIRE(!posix_memalign((void **)&memory,65536,1<<20)); memset(memory,0,1<<20);
    pool_t *pool=calloc(1,sizeof *pool); REQUIRE(pool); *pool=(pool_t){.magic=MAGIC('P','O','O','L'),
        .flags=NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS|NVN_MEMORY_POOL_FLAGS_GPU_CACHED,.mem=memory,.size=1<<20}; nvn_be_pool_add(memory,1<<20);

    // depth：1 = 立方体深度，0 = 颜色；view：0 不带视图，1 带 min_layer / nlayers（0 = 到底）
    struct { int depth, target, layers, view, min_layer, nlayers; const char *label; } cases[] = {
        {1, NVN_TEXTURE_TARGET_CUBEMAP,  6, 0, 0, 0, "① 立方体深度清除、不带视图：六面全清"},
        {1, NVN_TEXTURE_TARGET_CUBEMAP,  6, 1, 2, 1, "② 立方体深度清除、只看第 2 面：只清第 2 面"},
        {0, NVN_TEXTURE_TARGET_2D_ARRAY, 4, 0, 0, 0, "③ 2D 数组颜色清除、不带视图：四层全清"},
        {0, NVN_TEXTURE_TARGET_2D_ARRAY, 4, 1, 1, 0, "④ 视图从第 1 层到底：清 1-3"},
        {0, NVN_TEXTURE_TARGET_2D_ARRAY, 4, 1, 1, 2, "⑤ 视图第 1 层起两层：清 1-2"},
        {0, NVN_TEXTURE_TARGET_2D,       1, 0, 0, 0, "⑥ 对照：普通 2D 目标一层"},
    };
    for (unsigned i = 0; i < sizeof cases / sizeof *cases; i++) {
        tex_t t; memset(&t,0,sizeof t); t.magic=MAGIC('T','E','X',0); t.serial=nvn_new_serial();
        t.d=(nvn_texdesc){.target=cases[i].target,.format=cases[i].depth?NVN_FORMAT_DEPTH32F_STENCIL8:NVN_FORMAT_RGBA8,.width=W,.height=W,
                          .depth=cases[i].target==NVN_TEXTURE_TARGET_2D?1:cases[i].layers,.levels=1};
        t.pool=pool; t.off=(int64_t)i*65536; t.mem=pool->mem+t.off;
        // 客体内存也填旧值：颜色每个纹素都是同样 4 字节（与块线性排布无关），宿主从客体内存补同步没写过的层时读到的也是旧值，单测只量清除本身
        if (!cases[i].depth) for (int k=0;k<65536/4;k++) ((uint32_t *)t.mem)[k]=OLD_C;
        nvn_tex_layout(&t.d,&t.L); nvn_be_tex_init(&t);
        id<MTLTexture> base=tex_mtl(&t); REQUIRE(base);
        NSUInteger ns=slices_of(base);
        CHECK(ns==(NSUInteger)cases[i].layers,"case %u 合成目标 %lu 层（期望 %d）",i,(unsigned long)ns,cases[i].layers);
        if (ns!=(NSUInteger)cases[i].layers) continue;
        id<MTLCommandBuffer> cb=[queue commandBuffer];
        for (NSUInteger s=0;s<ns;s++) {   // 每层先填旧值
            MTLRenderPassDescriptor *init=[MTLRenderPassDescriptor renderPassDescriptor];
            if (cases[i].depth) { init.depthAttachment.texture=base; init.depthAttachment.slice=s; init.depthAttachment.loadAction=MTLLoadActionClear;
                init.depthAttachment.storeAction=MTLStoreActionStore; init.depthAttachment.clearDepth=.75; }
            else { init.colorAttachments[0].texture=base; init.colorAttachments[0].slice=s; init.colorAttachments[0].loadAction=MTLLoadActionClear;
                init.colorAttachments[0].storeAction=MTLStoreActionStore; init.colorAttachments[0].clearColor=MTLClearColorMake(0x44/255.,0x33/255.,0x22/255.,0x11/255.); }
            [[cb renderCommandEncoderWithDescriptor:init] endEncoding];
        }
        [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status==MTLCommandBufferStatusCompleted);

        nvn_be_sub_begin(); state_reset(); rp_flush();
        memset(&R.rt,0,sizeof R.rt); R.has_rt=1; R.has_sc=0;
        view_t v; memset(&v,0,sizeof v); if (cases[i].view) { v.set_layers=1; v.min_layer=(uint16_t)cases[i].min_layer; v.nlayers=(uint16_t)cases[i].nlayers; }
        if (cases[i].depth) { R.rt.depth=&t; R.rt.dview=v; R.rt.has_dview=(uint8_t)cases[i].view; }
        else { R.rt.n=1; R.rt.color[0]=&t; R.rt.cview[0]=v; R.rt.has_cview[0]=(uint8_t)cases[i].view; }
        g_on=0;
        if (cases[i].depth) { const p_clear_ds c={.depth=.25f,.depth_mask=1}; put(OP_CLEAR_DS,&c,sizeof c); }
        else { const p_clear_color c={.index=0,.mask=0xf,.rgba={.5f,.5f,.5f,.5f}}; put(OP_CLEAR_COLOR,&c,sizeof c); }
        put(OP_END,NULL,0);
        uint64_t n0=g_lyc_n;
        nvn_be_exec(g_ops); rp_flush();
        uint64_t fe=nvn_be_sub_commit(); REQUIRE(nvn_be_wait(fe,10000000000ull)); REQUIRE(!mtl_last_commit_error());

        id<MTLBuffer> result=[g_dev newBufferWithLength:W*W*4*ns options:MTLResourceStorageModeShared];
        cb=[queue commandBuffer]; id<MTLBlitCommandEncoder> b=[cb blitCommandEncoder];
        for (NSUInteger s=0;s<ns;s++)
            [b copyFromTexture:base sourceSlice:s sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(W,W,1) toBuffer:result destinationOffset:W*W*4*s
                destinationBytesPerRow:W*4 destinationBytesPerImage:W*W*4 options:cases[i].depth?MTLBlitOptionDepthFromDepthStencil:MTLBlitOptionNone];
        [b endEncoding]; [cb commit]; [cb waitUntilCompleted]; REQUIRE(cb.status==MTLCommandBufferStatusCompleted);
        const uint32_t *px=result.contents;
        int lo=cases[i].view?cases[i].min_layer:0, hi=cases[i].view&&cases[i].nlayers?lo+cases[i].nlayers:cases[i].layers;
        char got[64]; size_t o=0; int all_ok=1;
        for (NSUInteger s=0;s<ns;s++) {
            uint32_t want=(int)s>=lo&&(int)s<hi?(cases[i].depth?NEW_D:NEW_C):(cases[i].depth?OLD_D:OLD_C);
            int layer_ok=1; for (unsigned k=0;k<(unsigned)(W*W);k++) if (px[s*W*W+k]!=want) { layer_ok=0; break; }
            all_ok&=layer_ok; o+=snprintf(got+o,sizeof got-o,"%s",layer_ok?(want==NEW_D||want==NEW_C?"新":"旧"):"✗");
            if (!layer_ok) fprintf(stderr,"  case %u 第 %lu 层首个值 %#x，期望 %#x\n",i,(unsigned long)s,px[s*W*W],want);
        }
        CHECK(all_ok,"%s：逐层 %s（层清除遍 %llu 次）",cases[i].label,got,(unsigned long long)(g_lyc_n-n0));
    }
    unlink(map); unlink(user);
} printf("%s t_nvn_layer_clear：%u 项，失败 %u\n",failures?"✗":"✓",checks,failures); return failures?1:0; }
