// 放置式稀疏贴图的块管理（11-16，一款 Switch 2 赛车游戏 0400C3F00006E000 的常驻内存）。移植自 kartnative（seedds，MIT，dm/gfx/tex/nvn_sparse_tex.m，
//   docs/reference/nvn-objects.md「Sparse tiles with one physical memory share a heap page」「GPU-written sparse textures backed by placement-sparse textures」），
//   改动：类型与函数全部 static、全局加 stx_ 前缀（本文件被 nvn_mtl.m 与单测各自 #include）；块形状取 nvn_tex_sparse_layout；去混排整级尾用 nvn_deswizzle 的整存储取址；
//   映射操作里有解除映射时先调宿主的 drain（延后编码：先交出已录的命令，免得早于它们解除映射）。
// 做什么：NVN 稀疏贴图（虚拟池里、flags SPARSE）背后是 Metal 4 放置式稀疏贴图，64 KB 块只在游戏映射了内存的地方映射，从共享的放置堆按页取；
//   同一块物理内存背后的块共用一个堆页（游戏把同一物理页映射到很多虚拟位置：这款 3.47 GB 虚拟页落在 0.98 GB 物理页上，原先每个虚拟块一页，第三场比赛堆 4.1 GB）。
//   键 = 这 64 KB 的客体物理地址（一整段连续物理内存时）+ 像素格式：只有块压缩格式共享（Metal 可能把非压缩私有贴图无损压缩，一页经两张贴图写读会错），
//   GPU 写的贴图（稀疏渲染目标）不论格式都共享（建时 allowGPUOptimizedContents = NO），它们的块从不上传，新页清零。
//   同步是增量的：只映射 / 解除映射变了的块，只上传映射了且页变过的块（每次至多 budget 字节，余下挂起到下次用到）。
#include <pthread.h>
#include "../tex/nvn_deswizzle.h"
#include "nvn_hmap.h"

enum { STX_TILE = 0x10000, STX_HEAP_PAGES = 2048, STX_MAXLV = 16 };   // 64 KB 块；堆 128 MB 一个

// 客体侧（调用方的）：贴图存储地址、它的池的页表
typedef struct {
    void *ctx;
    uint64_t base;                                                 // 贴图存储的客体地址
    int (*mapped)(void *ctx, uint64_t a, uint64_t n);              // [a, a + n) 每页都有内存
    int (*changed)(void *ctx, uint64_t a, uint64_t n);             // [a, a + n) 自上次同步以来被写过或映射变过（拿不准给 1）
    void (*copy)(void *ctx, void *dst, uint64_t a, uint64_t n);    // 收 [a, a + n)，没映射的页读 0；GPU 写的贴图给 NULL
    uint64_t (*backing)(void *ctx, uint64_t a);                    // a 起 64 KB 背后的物理内存（一整段时它的地址），否则 0；可为 NULL（不共享）
} nvn_stex_guest;
// 宿主侧：上传的暂存与编码器、新堆的驻留、解除映射前的排空
typedef struct {
    void *ctx;
    id<MTLBuffer> (*stage)(void *ctx, size_t n, size_t *off);      // n 字节共享内存，活到编码器所在命令缓冲跑完
    id (*encoder)(void *ctx);                                      // 上传批的计算编码器（Metal 4，stage 之后取：stage 可能开了新批）
    void (*resident)(void *ctx, id<MTLAllocation> a);              // 新放置堆：进驻留集
    void (*drain)(void *ctx);                                      // 可为 NULL：解除映射前让已录（未交）的命令先交到队列
} nvn_stex_host;

// heap：持有的 id<MTLHeap>；free：空页栈；ref：映射到各页的块数；key：共享页装的客体内存（0：某一块自己的）
typedef struct { void *heap; uint32_t nfree; uint16_t free[STX_HEAP_PAGES]; uint32_t ref[STX_HEAP_PAGES]; uint64_t key[STX_HEAP_PAGES]; } stx_heap;
static stx_heap **g_stx_heaps; static unsigned g_stx_nheaps;
static pthread_mutex_t g_stx_mu = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_stx_pages, g_stx_tiles;   // 用着的堆页 / 映射到它们的块，g_stx_mu 下
static nvn_hmap g_stx_shared = {.klen = 8};  // 共享键 → 堆页 + 1，g_stx_mu 下
static uint64_t stx_share_key(uint64_t phys, MTLPixelFormat pf, int gpu) { return phys ? phys | (uint64_t)pf << 52 | (uint64_t)gpu << 62 : 0; }
// 诊断（GPU 写的贴图）：页已还回堆、客体仍留着那块物理内存的共享键。GPU 上那块内存的内容还在，宿主这边没了：之后再映射到它的块从零开始（记「丢失」），映射到从没块用过的内存记「新」
enum { STX_FREED_MAX = 1 << 20 };
#define STX_KEY_GPU (1ull << 62)
static nvn_hmap g_stx_freed = {.klen = 8};
static uint64_t g_stx_lost_tiles, g_stx_fresh_tiles;

typedef struct { int32_t page; uint8_t dirty; uint64_t key; } stx_ent;   // page：堆号 << 16 | 页号（一块），0（尾项，已映射），-1 = 没映射；key：所在页的共享键（0 不共享）
typedef struct nvn_stex {
    void *tex;                       // id<MTLTexture>，拥有时持有
    void *dev;                       // id<MTLDevice>（不持有，设备随进程常驻）：同步时用它，不向贴图发 device——nvn_mtl.m 这个编译单元发出的选择子都要有延后编码替身（t_nvn_rec_cover）
    MTLPixelFormat pf;
    int share, gpu, owned;           // share：块可共用堆页（块压缩格式，和所有 GPU 写的）；gpu：GPU 写（块不上传、新页清零）；owned：tex 持有引用（nvn_stex_take 之前）
    nvn_texdesc d, tile;             // 贴图；一块 64 KB 当一张块线性小贴图（去混排用）
    nvn_texlayout L;
    unsigned slices, levels, tiled, mtail, tail_pages, bw, bh, bpb;   // tiled：客体按块铺的级数；mtail：Metal 尾从哪级起（没有尾 = levels）
    uint32_t tw, th;                 // 一块的像素宽高
    uint32_t tx[STX_MAXLV], ty[STX_MAXLV];   // Metal 按块铺的每级每行 / 每列块数
    uint64_t lvoff[STX_MAXLV + 1];   // 一层里的级起点；lvoff[tiled] = 客体的尾
    unsigned per_slice, tail_tiles;  // 每层项数：客体按块铺的各级每块一项，再加尾一项；客体尾背后的 Metal 块数
    stx_ent *e;
    int32_t *tailpg;                 // 各层映射的尾所用的页（slices × tail_tiles）
    int pending;
    uint64_t lost, fresh;
} nvn_stex;

static uint32_t stx_mipd(uint32_t s, unsigned l) { s >>= l; return s ? s : 1; }

API_AVAILABLE(macos(26.0), ios(26.0))
static int nvn_stex_wanted(id<MTLDevice> dev, const nvn_texdesc *d, MTLPixelFormat pf, uint64_t min_bytes) {
    if (!dev || !d || (d->target != 1 && d->target != 4) || !(d->flags & 0x20) || (d->flags & 0x52) || d->samples > 1) return 0;   // 2D / 2D 数组、SPARSE、不是 LINEAR / VIDEO_DECODE
    nvn_texlayout L; nvn_tex_layout(d, &L);
    if (L.size < min_bytes || L.align != STX_TILE) return 0;
    uint32_t tl[4]; nvn_tex_sparse_layout(d, tl);
    if (!tl[0] || tl[0] > STX_MAXLV || tl[3] != 1 || (d->levels ? d->levels : 1) > STX_MAXLV) return 0;
    MTLSize ts = [dev sparseTileSizeWithTextureType:d->target == 4 ? MTLTextureType2DArray : MTLTextureType2D pixelFormat:pf sampleCount:1 sparsePageSize:MTLSparsePageSize64];
    return ts.width == tl[1] && ts.height == tl[2] && ts.depth == 1;
}

API_AVAILABLE(macos(26.0), ios(26.0))
static nvn_stex *nvn_stex_new(id<MTLDevice> dev, MTLTextureDescriptor *desc, const nvn_texdesc *d, int gpu) {
    if (!nvn_stex_wanted(dev, d, desc.pixelFormat, 0)) return NULL;
    MTLTextureDescriptor *td = [desc copy];
    td.storageMode = MTLStorageModePrivate; td.placementSparsePageSize = MTLSparsePageSize64;
    if (gpu) td.allowGPUOptimizedContents = NO;   // GPU 写的块按物理内存共享页，不能无损压缩（压缩元数据跟不上经另一张贴图写的页）
    id<MTLTexture> t = [dev newTextureWithDescriptor:td];
    if (!t) return NULL;
    nvn_stex *s = calloc(1, sizeof *s);
    if (!s) return NULL;
    s->d = *d; nvn_tex_layout(d, &s->L); s->levels = d->levels ? d->levels : 1;
    int bw, bh; s->bpb = (unsigned)nvn_fmt_bpb(d->format, &bw, &bh); s->bw = (unsigned)bw; s->bh = (unsigned)bh; s->share = bw > 1 || gpu; s->gpu = gpu; s->owned = 1;
    uint32_t tl[4]; nvn_tex_sparse_layout(d, tl); s->tiled = tl[0]; s->tw = tl[1]; s->th = tl[2];
    s->mtail = (unsigned)MIN(t.firstMipmapInTail, (NSUInteger)s->levels);
    s->slices = d->target == 4 ? (d->depth ? d->depth : 1) : 1;
    // 一块当一张贴图：tw × th 像素，行是一个块高 = 块高 GOB 的块（本级块高），64 KB
    unsigned rows = s->th / s->bh, h = 0; while ((8u << h) < rows) h++;
    s->tile = (nvn_texdesc){1, d->format, 0, 0, s->tw, s->th, 1, 1, 0, (int)h + 1};
    nvn_texlayout tlay; nvn_tex_layout(&s->tile, &tlay);
    uint32_t tile_gobs = s->bpb ? s->tw / s->bw * s->bpb / 64 : 0;
    int ok = tlay.size == STX_TILE && (8u << h) == rows && t.tailSizeInBytes % STX_TILE == 0 && tile_gobs && s->mtail >= s->tiled;
    for (unsigned l = 0; ok && l < s->mtail; l++) {
        s->tx[l] = (stx_mipd(d->width, l) + s->tw - 1) / s->tw; s->ty[l] = (stx_mipd(d->height, l) + s->th - 1) / s->th;
        if (l >= s->tiled) { s->tail_tiles += s->tx[l] * s->ty[l]; continue; }
        s->lvoff[l] = nvn_tex_level_offset(d, l);
        ok = nvn_tex_level_gobs(d, l) == s->tx[l] * tile_gobs;   // 客体把这级补齐到整块
        s->per_slice += s->tx[l] * s->ty[l];
    }
    if (!ok) { free(s); return NULL; }
    s->lvoff[s->tiled] = s->tiled < s->levels ? nvn_tex_level_offset(d, s->tiled) : s->L.layer_size;
    s->tail_pages = s->mtail < s->levels ? (unsigned)(t.tailSizeInBytes / STX_TILE) : 0;
    s->tail_tiles += s->tail_pages;
    if (s->tiled < s->levels) s->per_slice++;   // 客体的尾
    s->e = malloc(sizeof *s->e * s->per_slice * s->slices);
    s->tailpg = malloc(sizeof *s->tailpg * (s->tail_tiles ? s->tail_tiles : 1) * s->slices);
    if (!s->e || !s->tailpg) { free(s->e); free(s->tailpg); free(s); return NULL; }
    for (size_t i = 0; i < (size_t)s->per_slice * s->slices; i++) s->e[i] = (stx_ent){-1, 0, 0};
    s->pf = td.pixelFormat;
    s->tex = (__bridge_retained void *)t; s->dev = (__bridge void *)dev;
    return s;
}

static id<MTLTexture> nvn_stex_texture(const nvn_stex *s) { return s ? (__bridge id<MTLTexture>)s->tex : nil; }
static __attribute__((unused)) int nvn_stex_pending(const nvn_stex *s) { return s && s->pending; }
static uint64_t nvn_stex_mapped_bytes(void) { pthread_mutex_lock(&g_stx_mu); uint64_t b = g_stx_pages * STX_TILE; pthread_mutex_unlock(&g_stx_mu); return b; }
static uint64_t nvn_stex_tile_bytes(void) { pthread_mutex_lock(&g_stx_mu); uint64_t b = g_stx_tiles * STX_TILE; pthread_mutex_unlock(&g_stx_mu); return b; }
static __attribute__((unused)) uint64_t nvn_stex_heap_bytes(void) { pthread_mutex_lock(&g_stx_mu); uint64_t b = (uint64_t)g_stx_nheaps * STX_HEAP_PAGES * STX_TILE; pthread_mutex_unlock(&g_stx_mu); return b; }
static void nvn_stex_lost(const nvn_stex *s, uint64_t *lost, uint64_t *fresh) {
    pthread_mutex_lock(&g_stx_mu); *lost = s ? s->lost : g_stx_lost_tiles; *fresh = s ? s->fresh : g_stx_fresh_tiles; pthread_mutex_unlock(&g_stx_mu);
}

// 一块要的堆页（→ 堆号 << 16 | 页号，拿不到 -1）：已经装着 key 那块内存的页（key 0：自己一页）；*alone：这页对这块是新的（内容未定）；*lost：GPU 写的键，它的页曾还回堆
API_AVAILABLE(macos(26.0), ios(26.0))
static int stx_page_alloc(id<MTLDevice> dev, const nvn_stex_host *h, uint64_t key, int *alone, int *lost) {
    *lost = 0;
    pthread_mutex_lock(&g_stx_mu);
    void *sh = key ? nvn_hm_get(&g_stx_shared, &key) : NULL;
    if (sh) { int p = (int)((intptr_t)sh - 1); g_stx_heaps[p >> 16]->ref[p & 0xffff]++; g_stx_tiles++; pthread_mutex_unlock(&g_stx_mu); *alone = 0; return p; }
    int p = -1; id<MTLHeap> fresh = nil;
    for (unsigned i = 0; i < g_stx_nheaps && p < 0; i++) if (g_stx_heaps[i]->nfree) p = (int)(i << 16 | g_stx_heaps[i]->free[--g_stx_heaps[i]->nfree]);
    if (p < 0) {
        MTLHeapDescriptor *hd = [MTLHeapDescriptor new];
        hd.type = MTLHeapTypePlacement; hd.storageMode = MTLStorageModePrivate; hd.size = (NSUInteger)STX_HEAP_PAGES * STX_TILE; hd.maxCompatiblePlacementSparsePageSize = MTLSparsePageSize64;
        fresh = g_stx_nheaps < 0x8000 ? [dev newHeapWithDescriptor:hd] : nil;
        if (!fresh) { pthread_mutex_unlock(&g_stx_mu); return -1; }
        stx_heap *hp = calloc(1, sizeof *hp), **grown = hp ? realloc(g_stx_heaps, sizeof *g_stx_heaps * (g_stx_nheaps + 1)) : NULL;
        if (!grown) { free(hp); pthread_mutex_unlock(&g_stx_mu); return -1; }
        g_stx_heaps = grown; hp->heap = (__bridge_retained void *)fresh;
        for (unsigned k = 0; k < STX_HEAP_PAGES; k++) hp->free[k] = (uint16_t)(STX_HEAP_PAGES - 1 - k);   // 依次弹出 0, 1, 2, …
        hp->nfree = STX_HEAP_PAGES - 1;                                                                     // 第 0 页给这次
        g_stx_heaps[g_stx_nheaps] = hp;
        p = (int)(g_stx_nheaps++ << 16);
    }
    stx_heap *hp = g_stx_heaps[p >> 16]; hp->ref[p & 0xffff] = 1; hp->key[p & 0xffff] = key;
    if (key & STX_KEY_GPU) { *lost = nvn_hm_del(&g_stx_freed, &key) != NULL; if (*lost) g_stx_lost_tiles++; else g_stx_fresh_tiles++; }
    if (key) nvn_hm_put(&g_stx_shared, &key, (void *)(intptr_t)(p + 1));
    g_stx_pages++; g_stx_tiles++;
    pthread_mutex_unlock(&g_stx_mu);
    if (fresh && h && h->resident) h->resident(h->ctx, (id<MTLAllocation>)fresh);
    *alone = 1; return p;
}
static void stx_page_free(int p) {   // 页上少一块；最后一块走时页还回堆
    pthread_mutex_lock(&g_stx_mu); stx_heap *hp = g_stx_heaps[p >> 16]; unsigned i = (unsigned)(p & 0xffff);
    if (!--hp->ref[i]) {
        if (hp->key[i] & STX_KEY_GPU) { if (g_stx_freed.n >= STX_FREED_MAX) nvn_hm_clear(&g_stx_freed, NULL); nvn_hm_put(&g_stx_freed, &hp->key[i], (void *)1); }
        if (hp->key[i]) nvn_hm_del(&g_stx_shared, &hp->key[i]);
        hp->key[i] = 0; hp->free[hp->nfree++] = (uint16_t)i; g_stx_pages--; }
    g_stx_tiles--; pthread_mutex_unlock(&g_stx_mu);
}

typedef struct { MTLSparseTextureMappingMode mode; MTLRegion r; NSUInteger lv, z, off; int heap; } stx_op;   // heap -1：解除映射
typedef struct { stx_op *v; size_t n, cap; int unmaps; } stx_oplist;
static void stx_op_add(stx_oplist *o, int map, MTLRegion r, unsigned lv, unsigned z, int page) {
    if (o->n == o->cap) { stx_op *v = realloc(o->v, sizeof *o->v * (o->cap = o->cap ? o->cap * 2 : 256)); if (!v) abort(); o->v = v; }
    o->v[o->n++] = (stx_op){map ? MTLSparseTextureMappingModeMap : MTLSparseTextureMappingModeUnmap, r, lv, z, map ? (NSUInteger)(page & 0xffff) : 0, map ? page >> 16 : -1};
    o->unmaps |= !map;
}
static int stx_op_cmp(const void *a, const void *b) { int x = ((const stx_op *)a)->heap, y = ((const stx_op *)b)->heap; return (x > y) - (x < y); }
API_AVAILABLE(macos(26.0), ios(26.0))
static void stx_ops_apply(id q, id<MTLTexture> t, stx_oplist *o, const nvn_stex_host *h) {   // 每个堆一次调用（解除映射不带堆）
    if (!o->n) return;
    if (o->unmaps && h && h->drain) h->drain(h->ctx);
    qsort(o->v, o->n, sizeof *o->v, stx_op_cmp);   // 按堆分组；解除映射（堆 -1）排最前，一块换页时先解除、再映射到新页
    MTL4UpdateSparseTextureMappingOperation *buf = malloc(sizeof *buf * o->n);
    if (!buf) abort();
    for (size_t i = 0; i < o->n;) {
        size_t j = i; while (j < o->n && o->v[j].heap == o->v[i].heap) { const stx_op *x = &o->v[j]; buf[j - i] = (MTL4UpdateSparseTextureMappingOperation){x->mode, x->r, x->lv, x->z, x->off}; j++; }
        id<MTLHeap> heap = nil;
        if (o->v[i].heap >= 0) { pthread_mutex_lock(&g_stx_mu); heap = (__bridge id<MTLHeap>)g_stx_heaps[o->v[i].heap]->heap; pthread_mutex_unlock(&g_stx_mu); }
        [q updateTextureMappings:t heap:heap operations:buf count:j - i];
        i = j;
    }
    free(buf); o->n = 0; o->unmaps = 0;
}

// 第 z 层第 k 项：客体按块铺的一块（它的 64 KB 与位置），或客体的尾（它的范围，lv = tiled）
static void stx_ent_geom(const nvn_stex *s, unsigned z, unsigned k, uint64_t *a, uint64_t *n, unsigned *lv, uint32_t *x, uint32_t *y) {
    uint64_t layer = (uint64_t)z * s->L.layer_size;
    for (unsigned l = 0; l < s->tiled; l++) {
        unsigned c = s->tx[l] * s->ty[l];
        if (k < c) { *lv = l; *x = k % s->tx[l]; *y = k / s->tx[l]; *a = layer + s->lvoff[l] + (uint64_t)k * STX_TILE; *n = STX_TILE; return; }
        k -= c;
    }
    *lv = s->tiled; *x = *y = 0; *a = layer + s->lvoff[s->tiled]; *n = s->L.layer_size - s->lvoff[s->tiled];
}
// 客体尾背后的第 j 个 Metal 块：Metal 还按块铺的那几级（tiled .. mtail - 1）的块，再是它自己尾的页
static void stx_tail_tile(const nvn_stex *s, unsigned j, unsigned *lv, MTLRegion *r) {
    for (unsigned l = s->tiled; l < s->mtail; l++) {
        unsigned c = s->tx[l] * s->ty[l];
        if (j < c) { *lv = l; *r = MTLRegionMake3D(j % s->tx[l], j / s->tx[l], 0, 1, 1, 1); return; }
        j -= c;
    }
    *lv = s->mtail; *r = MTLRegionMake3D(j, 0, 0, 1, 1, 1);
}
// 映射（map = 1）或解除一项的 Metal 块：→ 1 带来自己的一页（内容未定），0 共用已装着它内存的页（或解除），-1 拿不到堆页（这项什么都不留映射）
API_AVAILABLE(macos(26.0), ios(26.0))
static int stx_ent_map(nvn_stex *s, stx_oplist *o, id<MTLDevice> dev, const nvn_stex_host *h, unsigned z, unsigned k, int map, uint64_t key) {
    stx_ent *e = &s->e[(size_t)z * s->per_slice + k];
    uint64_t a, n; unsigned lv; uint32_t x, y; stx_ent_geom(s, z, k, &a, &n, &lv, &x, &y);
    if (lv < s->tiled) {
        if (!map) { stx_op_add(o, 0, MTLRegionMake3D(x, y, 0, 1, 1, 1), lv, z, 0); stx_page_free(e->page); e->page = -1; e->key = 0; return 0; }
        int alone, lost, p = stx_page_alloc(dev, h, key, &alone, &lost); if (p < 0) return -1;
        if (key & STX_KEY_GPU) { if (lost) s->lost++; else if (alone) s->fresh++; }
        stx_op_add(o, 1, MTLRegionMake3D(x, y, 0, 1, 1, 1), lv, z, p); e->page = p; e->key = key; return alone;
    }
    int32_t *pg = s->tailpg + (size_t)z * s->tail_tiles;
    for (unsigned j = 0; j < s->tail_tiles; j++) {
        unsigned tl; MTLRegion r; stx_tail_tile(s, j, &tl, &r);
        if (!map) { stx_op_add(o, 0, r, tl, z, 0); stx_page_free(pg[j]); continue; }
        int alone, lost, p = stx_page_alloc(dev, h, 0, &alone, &lost); (void)alone; (void)lost;   // 尾的页是它自己的
        if (p < 0) { while (j--) { stx_tail_tile(s, j, &tl, &r); stx_op_add(o, 0, r, tl, z, 0); stx_page_free(pg[j]); } return -1; }
        stx_op_add(o, 1, r, tl, z, p); pg[j] = p;
    }
    e->page = map ? 0 : -1;
    return map;
}

// 一项的一次上传：它填第 l 级的哪块、去混排成多少线性字节（整块，或尾的整级）
static void stx_up_geom(const nvn_stex *s, unsigned lv, uint32_t x, uint32_t y, unsigned l, MTLOrigin *o, MTLSize *sz, size_t *pitch, size_t *bytes) {
    uint32_t w = stx_mipd(s->d.width, l), hh = stx_mipd(s->d.height, l), x0 = 0, y0 = 0, cw = w, ch = hh;
    if (lv < s->tiled) { x0 = x * s->tw; y0 = y * s->th; w = MIN(s->tw, w - x0); hh = MIN(s->th, hh - y0); cw = s->tw; ch = s->th; }
    *o = MTLOriginMake(x0, y0, 0); *sz = MTLSizeMake(w, hh, 1);
    *pitch = (size_t)((cw + s->bw - 1) / s->bw) * s->bpb; *bytes = *pitch * ((ch + s->bh - 1) / s->bh);
}
static size_t stx_up_bytes(const nvn_stex *s, unsigned lv) {   // 一项的暂存，每次拷贝 256 字节对齐
    size_t n = 0, pitch, b; MTLOrigin o; MTLSize sz;
    for (unsigned l = lv; l < (lv < s->tiled ? lv + 1 : s->levels); l++) { stx_up_geom(s, lv, 0, 0, l, &o, &sz, &pitch, &b); n += (b + 255) & ~(size_t)255; }
    return n;
}

// 让块与客体一致：映射有内存的、解除失去内存的（映射更新排在 q 上，早于之后交到 q 的上传批），再编码映射了且页变过的块的上传，至多 budget 字节（0 = 不限）。
// → 上传字节数，-1 失败（没堆页 / 没暂存）。剩下的挂起（nvn_stex_pending）
API_AVAILABLE(macos(26.0), ios(26.0))
static int64_t nvn_stex_sync(nvn_stex *s, id q, const nvn_stex_guest *g, const nvn_stex_host *h, uint64_t budget) {
    if (!s || !q || !g || !h) return -1;
    id<MTLTexture> t = (__bridge id<MTLTexture>)s->tex; id<MTLDevice> dev = (__bridge id<MTLDevice>)s->dev;
    const unsigned per = s->per_slice;
    if (!per) return 0;
    size_t ne = (size_t)per * s->slices; stx_oplist o = {0}; int fail = 0;
    for (unsigned z = 0; z < s->slices; z++) for (unsigned k = 0; k < s->per_slice; k++) {
        stx_ent *e = &s->e[(size_t)z * s->per_slice + k];
        uint64_t a, n; unsigned lv; uint32_t x, y; stx_ent_geom(s, z, k, &a, &n, &lv, &x, &y);
        // 一块有没有内存；好几页的尾只要有一页有就算有（没映射的页读 0，同 GPU）
        int m = 0; for (uint64_t p = 0; p < n && !m; p += STX_TILE) m = g->mapped(g->ctx, g->base + a + p, MIN((uint64_t)STX_TILE, n - p));
        if (!m) { if (e->page >= 0) stx_ent_map(s, &o, dev, h, z, k, 0, 0); e->dirty = 0; continue; }
        // 共享键只在新映射或页变过时问（范围里有新映射就算变过）：内存搬走的块离开它共用的页。新映射的块总上传，页里就是现在的内存；GPU 写的块不传（它的内存就是页），自己一页清零
        #define STX_KEY() (s->share && lv < s->tiled && g->backing ? stx_share_key(g->backing(g->ctx, g->base + a), s->pf, s->gpu) : 0)
        if (e->page < 0) { int r = stx_ent_map(s, &o, dev, h, z, k, 1, STX_KEY()); if (r < 0) fail = 1; else e->dirty = s->gpu ? (uint8_t)r : 1; }
        else if (g->changed(g->ctx, g->base + a, n)) {
            uint64_t key = STX_KEY(); if (!s->gpu) e->dirty = 1;
            if (key != e->key) { stx_ent_map(s, &o, dev, h, z, k, 0, 0); int r = stx_ent_map(s, &o, dev, h, z, k, 1, key); if (r < 0) { fail = 1; e->dirty = 0; } else e->dirty = s->gpu ? (uint8_t)r : 1; }
        }
        #undef STX_KEY
    }
    stx_ops_apply(q, t, &o, h); free(o.v);
    // 这次上传的项（到预算为止），暂存一次拿齐，去混排进去，再编码拷贝
    size_t total = 0, last = 0; uint64_t bytes = 0;
    for (; last < ne; last++) {
        if (!s->e[last].dirty) continue;
        if (budget && bytes >= budget) break;
        uint64_t a, n; unsigned lv; uint32_t x, y; stx_ent_geom(s, (unsigned)(last / per), (unsigned)(last % per), &a, &n, &lv, &x, &y);
        total += stx_up_bytes(s, lv); bytes += n;
    }
    s->pending = 0; for (size_t i = last; i < ne && !s->pending; i++) s->pending = s->e[i].dirty;
    if (!total) return fail ? -1 : 0;
    size_t base; id<MTLBuffer> stg = h->stage(h->ctx, total, &base);
    if (!stg) { s->pending = 1; return -1; }
    typedef struct { size_t off, pitch, bytes; MTLOrigin o; MTLSize sz; unsigned z, l; } cp;
    cp *cps = malloc(sizeof *cps * (total / 256 + 1)); size_t ncp = 0, at = base; uint8_t *tmp = NULL; uint64_t tmp_n = 0;
    if (!cps) { s->pending = 1; return -1; }
    for (size_t i = 0; i < last; i++) {
        stx_ent *e = &s->e[i]; if (!e->dirty) continue;
        unsigned z = (unsigned)(i / per); uint64_t a, n; unsigned lv; uint32_t x, y; stx_ent_geom(s, z, (unsigned)(i % per), &a, &n, &lv, &x, &y);
        if (!s->gpu) { if (n > tmp_n) { free(tmp); tmp = malloc(n); tmp_n = tmp ? n : 0; } if (!tmp) { fail = 1; continue; } g->copy(g->ctx, tmp, g->base + a, n); }
        for (unsigned l = lv; l < (lv < s->tiled ? lv + 1 : s->levels); l++) {   // 一块，或尾的每一级
            cp c = {at, 0, 0, {0}, {0}, z, l}; stx_up_geom(s, lv, x, y, l, &c.o, &c.sz, &c.pitch, &c.bytes);
            uint8_t *dst = (uint8_t *)stg.contents + at;
            // 尾：nvn_deswizzle 按整存储取址，把 [a, a + n) 的局部副本当作「存储起点偏移 a 处」交进去（尾整段在副本里）
            if (s->gpu) memset(dst, 0, c.bytes);
            else if (lv < s->tiled ? nvn_deswizzle(&s->tile, 0, 0, tmp, dst, c.pitch) : nvn_deswizzle(&s->d, l, z, tmp - a, dst, c.pitch)) { fail = 1; continue; }
            cps[ncp++] = c; at += (c.bytes + 255) & ~(size_t)255;
        }
        e->dirty = 0;
    }
    free(tmp);
    id enc = h->encoder(h->ctx);   // 暂存之后取：拿暂存可能开了新上传批
    if (enc && ncp) [enc barrierAfterQueueStages:MTLStageResourceState beforeStages:MTLStageBlit visibilityOptions:MTL4VisibilityOptionDevice];   // 在映射更新之后
    for (size_t i = 0; enc && i < ncp; i++)
        [enc copyFromBuffer:stg sourceOffset:cps[i].off sourceBytesPerRow:cps[i].pitch sourceBytesPerImage:cps[i].bytes sourceSize:cps[i].sz
                  toTexture:t destinationSlice:cps[i].z destinationLevel:cps[i].l destinationOrigin:cps[i].o];
    free(cps);
    if (!enc) return -1;
    return fail && !bytes ? -1 : (int64_t)bytes;
}

// 把贴图的引用交给调用方：之后贴图随调用方活，nvn_stex_free（q 给 nil）只还页
static id<MTLTexture> nvn_stex_take(nvn_stex *s) {
    if (!s || !s->owned) return nil;
    s->owned = 0; return (__bridge_transfer id<MTLTexture>)s->tex;   // s->tex 留作不持有的指针供同步用
}
// 解除它的块（页还回堆）并释放；在 GPU 不再用这张贴图时调
API_AVAILABLE(macos(26.0), ios(26.0))
static void nvn_stex_free(nvn_stex *s, id q, const nvn_stex_host *h) {
    if (!s) return;
    stx_oplist o = {0};
    id qq = s->owned ? q : nil;   // 贴图在走（nvn_stex_take 过）：映射随它走，页只还回堆
    id<MTLTexture> t = s->owned ? (__bridge_transfer id<MTLTexture>)s->tex : nil;
    for (unsigned z = 0; z < s->slices; z++) for (unsigned k = 0; k < s->per_slice; k++)
        if (s->e[(size_t)z * s->per_slice + k].page >= 0) stx_ent_map(s, &o, nil, NULL, z, k, 0, 0);
    if (qq) stx_ops_apply(qq, t, &o, h);
    free(o.v); free(s->e); free(s->tailpg); free(s);
}
