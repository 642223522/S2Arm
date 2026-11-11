// 内存池在后端的镜像缓冲，与缓冲类命令。
// iOS 上内存池就是零拷贝的 MTLBuffer（nvn_mtl.m pool_add @556），GPU 直接读游戏内存。Vulkan 没有通用的等价物，这里的做法是：
//   · 游戏内存是唯一真值；每个被当缓冲用到的池在后端有一份等大的镜像，按页同步；
//   · 同步点 = 每次使用点（绘制 / 派发 / 拷贝取这段地址时）：自上次同步后被写过的页，在当前段的 GPU 顺序里重传；
//   · 所以按 GPU 顺序生效的 CPU 数据写（OP_UPDATE_UB / OP_COPY_B2B / OP_CLEAR_BUF）只需要改游戏内存：
//     排在它前面的使用点已经带着旧内容同步过，排在它后面的使用点会看到页脏了再同步新内容。
// GPU 往池里写（贴图拷回缓冲、计算着色器写存储缓冲、变换反馈）要反方向回写游戏内存，随那几条命令一起接。
// 平台有零拷贝后备（安卓 AHB）时镜像与同步都可以省掉，那是平台接口「内存池后备」一组，接它不改这里的对外形状。
#include "rp_exec.h"
#include "rp_res.h"
#include "nvn_unimpl.h"
#include "nvn_hmap.h"
#include "nvn_dirty.h"
#include "nvn_mtl.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

struct shadow { const uint8_t *mem; uint64_t size; nvn_gpu_buf buf; uint64_t *synced, *sub; uint64_t npages; uintptr_t page0; };   // synced[i]：第 i 页上次同步取的脏页代号，0 = 从没同步
static pthread_mutex_t g_bmu = PTHREAD_MUTEX_INITIALIZER;
static nvn_hmap g_shadow = {.klen = 8};   // 池起点 → struct shadow *
static uint64_t g_sync_bytes, g_sync_runs;

int rp_pool_find(uint64_t addr, uint64_t len, const uint8_t **mem, uint64_t *size);   // rp_entry.c

static struct shadow *shadow_get(const uint8_t *mem, uint64_t size) {
    uint64_t k = (uint64_t)(uintptr_t)mem;
    struct shadow *s = nvn_hm_get(&g_shadow, &k);
    if (s) return s;
    nvn_gpu_buf b = NULL; nvn_gpu_err err = {0};
    if (!nvn_gpu_ok(nvn_gpu_buf_create(size, NVN_GPU_MEM_SHARED, NULL, &b, &err))) { nvn_unimpl("gpu", "buf_create_pool_mirror", mem); return NULL; }
    size_t ps = nvn_dirty_page_size();
    s = calloc(1, sizeof *s); s->mem = mem; s->size = size; s->buf = b;
    s->page0 = (uintptr_t)mem & ~(uintptr_t)(ps - 1);
    s->npages = ((uintptr_t)mem + size - s->page0 + ps - 1) / ps;
    s->synced = calloc(s->npages ? s->npages : 1, sizeof *s->synced);
    s->sub = calloc(s->npages ? s->npages : 1, sizeof *s->sub);   // 各页上次同步所在的提交序号
    nvn_hm_put(&g_shadow, &k, s);
    return s;
}

int rp_buf_resolve(nvn_gpu_cmd c, uint64_t addr, uint64_t len, nvn_gpu_buf *buf, uint64_t *off) {
    (void)c;   // 同步录进哪一段由 rp_xfer_cmd 定
    const uint8_t *mem; uint64_t size;
    if (!len || !rp_pool_find(addr, len, &mem, &size)) { nvn_unimpl("buf", "address_outside_pools", (const void *)(uintptr_t)addr); return 0; }
    pthread_mutex_lock(&g_bmu);
    struct shadow *s = shadow_get(mem, size);
    if (!s) { pthread_mutex_unlock(&g_bmu); return 0; }
    size_t ps = nvn_dirty_page_size();
    uint64_t p = ((uintptr_t)addr - s->page0) / ps, q = ((uintptr_t)addr + len - 1 - s->page0) / ps, n = q - p + 1;
    uint64_t stack[256], *gens = n <= 256 ? stack : malloc((size_t)n * sizeof *gens);
    long got = gens ? nvn_dirty_page_gens(nvn_dirty_span((const void *)(uintptr_t)addr, (size_t)len), (const void *)(uintptr_t)addr, (size_t)len, gens, (size_t)n) : -1;
    int tracked = got == (long)n;   // 没被写跟踪的池：每次使用都整段同步
    for (uint64_t i = p; i <= q;) {
        if (s->synced[i] && tracked && gens[i - p] <= s->synced[i]) { i++; continue; }
        uint64_t j = i; while (j + 1 <= q && !(s->synced[j + 1] && tracked && gens[j + 1 - p] <= s->synced[j + 1])) j++;
        uintptr_t a = s->page0 + (uintptr_t)(i * ps), b = s->page0 + (uintptr_t)((j + 1) * ps);   // 这一串脏页，裁到池的范围
        if (a < (uintptr_t)mem) a = (uintptr_t)mem;
        if (b > (uintptr_t)mem + size) b = (uintptr_t)mem + size;
        nvn_dirty_protect((const void *)a, b - a); uint64_t st = nvn_dirty_now(); if (!st) st = 1;   // 先保护、取代号、再读
        // 这一串里只要有一页本次提交已同步过，整串就按「第二次同步」走主段
        uint64_t last = 0; for (uint64_t k = i; k <= j; k++) if (s->sub[k] > last) last = s->sub[k];
        nvn_gpu_cmd xc = rp_xfer_cmd(&last);
        if (xc) nvn_gpu_buf_write(xc, s->buf, a - (uintptr_t)mem, (const void *)a, b - a);
        for (uint64_t k = i; k <= j; k++) { s->synced[k] = st; s->sub[k] = last; }
        g_sync_bytes += b - a; g_sync_runs++;
        i = j + 1;
    }
    if (gens != stack) free(gens);
    if (buf) *buf = s->buf;
    if (off) *off = addr - (uint64_t)(uintptr_t)mem;
    pthread_mutex_unlock(&g_bmu);
    return 1;
}

void rp_buf_pool_gone(const void *mem) {
    uint64_t k = (uint64_t)(uintptr_t)mem;
    pthread_mutex_lock(&g_bmu);
    struct shadow *s = nvn_hm_del(&g_shadow, &k);
    if (s) { nvn_gpu_buf_release(s->buf, NULL, NULL); free(s->synced); free(s->sub); free(s); }
    pthread_mutex_unlock(&g_bmu);
}
void rp_buf_reset(void) {
    pthread_mutex_lock(&g_bmu);
    for (uint32_t i = 0; i < g_shadow.cap; i++) { struct shadow *s = g_shadow.vals[i]; if (s) { nvn_gpu_buf_release(s->buf, NULL, NULL); free(s->synced); free(s->sub); free(s); } }
    free(g_shadow.keys); free(g_shadow.vals); nvn_hm_init(&g_shadow, 8);
    pthread_mutex_unlock(&g_bmu);
}
void rp_buf_stats(uint64_t *bytes, uint64_t *runs) { pthread_mutex_lock(&g_bmu); if (bytes) *bytes = g_sync_bytes; if (runs) *runs = g_sync_runs; pthread_mutex_unlock(&g_bmu); }
int rp_buf_mirrors(void) { pthread_mutex_lock(&g_bmu); int n = (int)g_shadow.n; pthread_mutex_unlock(&g_bmu); return n; }

// ---------- 缓冲类命令：只改游戏内存（见文件头）----------
static int in_pool(uint64_t a, uint64_t n) { return n && rp_pool_find(a, n, NULL, NULL); }
void rp_op_update_ub(const void *a, const void *rec) {
    uint64_t d, n; memcpy(&d, a, 8); memcpy(&n, (const uint8_t *)a + 8, 8);
    if (!n) return;
    if (!in_pool(d, n)) { nvn_unimpl("buf", "update_outside_pools", rec); return; }
    memcpy((void *)(uintptr_t)d, (const uint8_t *)a + 16, (size_t)n);
}
void rp_op_copy_b2b(const void *a, const void *rec) {
    uint64_t s, d, n; memcpy(&s, a, 8); memcpy(&d, (const uint8_t *)a + 8, 8); memcpy(&n, (const uint8_t *)a + 16, 8);
    if (!n) return;
    if (!in_pool(s, n) || !in_pool(d, n)) { nvn_unimpl("buf", "copy_outside_pools", rec); return; }
    memmove((void *)(uintptr_t)d, (const void *)(uintptr_t)s, (size_t)n);
}
void rp_op_clear_buf(const p_clear_buf *cb, const void *rec) {   // 32 位样式填充（不是按字节）
    if (!cb->size) return;
    if (!in_pool(cb->addr, cb->size)) { nvn_unimpl("buf", "clear_outside_pools", rec); return; }
    uint8_t *p = (uint8_t *)(uintptr_t)cb->addr; uint64_t n = cb->size, i = 0;
    for (; i + 4 <= n; i += 4) memcpy(p + i, &cb->value, 4);
    if (i < n) memcpy(p + i, &cb->value, (size_t)(n - i));
}

// OP_COPY_B2T：缓冲里是线性行（行距 / 片距可由游戏设），直接从游戏内存按当前段的 GPU 顺序传进贴图（nvn_mtl.m copy_b2t @13762）
void rp_op_copy_b2t(nvn_gpu_cmd c, const p_copy_b2t *o, const void *rec) {
    const tex_t *t = o->tex; if (!t) return;
    if (t->d.flags & (NVN_TEXTURE_FLAGS_LINEAR | NVN_TEXTURE_FLAGS_LINEAR_RENDER_TARGET)) { nvn_unimpl("tex", "b2t_linear", rec); return; }
    int bw = 1, bh = 1, bpb = nvn_fmt_bpb(t->d.format, &bw, &bh);
    if (!bpb || o->r.width <= 0 || o->r.height <= 0) { nvn_unimpl("tex", "b2t_bad_format_or_region", rec); return; }
    uint32_t level = o->has_view && o->view.set_levels ? o->view.base_level : 0, layer0 = o->has_view && o->view.set_layers ? o->view.min_layer : 0;
    uint64_t row = o->row_stride ? o->row_stride : (uint64_t)(((uint32_t)o->r.width + (uint32_t)bw - 1) / (uint32_t)bw) * (uint64_t)bpb;
    uint64_t rows = ((uint32_t)o->r.height + (uint32_t)bh - 1) / (uint32_t)bh, img = o->image_stride ? o->image_stride : row * rows;
    uint32_t nz = o->r.depth > 0 ? (uint32_t)o->r.depth : 1;
    if (t->d.target == NVN_TEXTURE_TARGET_3D && nz > 1) { nvn_unimpl("tex", "b2t_3d_multi_slice", rec); return; }
    if (!in_pool(o->src, img * nz)) { nvn_unimpl("buf", "b2t_source_outside_pools", rec); return; }
    nvn_gpu_tex g = rp_tex_resolve(t, c);
    if (!g || !c) return;
    for (uint32_t z = 0; z < nz; z++) {
        NVNcopyRegion r = o->r; r.depth = 1;
        uint32_t layer = layer0 + (uint32_t)o->r.zoffset + z;
        if (t->d.target == NVN_TEXTURE_TARGET_3D) layer = 0; else r.zoffset = 0;
        nvn_gpu_tex_upload(c, g, level, layer, &r, (const void *)(uintptr_t)(o->src + z * img), row, img);
    }
    rp_tex_mark_gpu_written(t);   // 这张贴图的内容从此不再从它自己的存储重传
}
