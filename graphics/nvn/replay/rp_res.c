#include "rp_res.h"
#include "rp_exec.h"
#include "nvn_unimpl.h"
#include "nvn_plat.h"
#include "nvn_hmap.h"
#include "nvn_dirty.h"
#include "nvn_fmt_info.h"
#include "nvn_deswizzle.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// 一份后端贴图存储。可被多个贴图对象（序号）共用。
struct rp_tex {
    nvn_gpu_tex g;
    int users;                 // 指向它的序号个数
    uint8_t cpu;               // 内容来自游戏内存（按脏页重传）
    uint8_t gpu_written;       // 内容以 GPU 为准
    uint8_t uploaded;
    uint8_t in_alias;
    uint64_t stamp;            // 最近一次上传取的脏页代号
    uint64_t up_sub;           // 最近一次上传所在的提交序号
    const uint8_t *mem; uint64_t size;
};
// 同存储共用表的键：内存池 + 偏移 + 描述（去掉只表示用途、不影响存储布局的标志）
typedef struct { uint64_t pool; int64_t off; nvn_texdesc d; } alias_key;
enum { ALIAS_USE_FLAGS = NVN_TEXTURE_FLAGS_IMAGE | NVN_TEXTURE_FLAGS_COMPRESSIBLE | NVN_TEXTURE_FLAGS_ADAPTIVE_ZCULL | NVN_TEXTURE_FLAGS_DEPTH16_PREFER_FAST_CLEAR | NVN_TEXTURE_FLAGS_ZCULL_SUPPORT_STENCIL };
enum { SWZ_IDENTITY = 2 | 3 << 3 | 4 << 6 | 5 << 9 };   // tex_builder_t.swz 打包法下的 R G B A：等于没设
static void alias_key_of(alias_key *k, const tex_t *t) { memset(k, 0, sizeof *k); k->pool = (uint64_t)(uintptr_t)t->pool; k->off = t->off; k->d = t->d; k->d.flags &= ~(int)ALIAS_USE_FLAGS; }

typedef struct { tex_t t; view_t v; uint8_t ok, has_v; nvn_gpu_view view; struct rp_tex *of; uint64_t gen; } treg_t;
typedef struct { samp_par p; uint8_t ok; nvn_gpu_samp s; } sreg_t;

static pthread_mutex_t g_rmu = PTHREAD_MUTEX_INITIALIZER;
static treg_t *g_treg; static int g_ntreg;
static sreg_t *g_sreg; static int g_nsreg;
static int g_tpool_n;
static nvn_hmap g_by_serial = {.klen = 8};                  // 序号 → struct rp_tex *
static nvn_hmap g_alias = {.klen = sizeof(alias_key)};      // 键 → struct rp_tex *
static nvn_hmap g_cpu_ser = {.klen = 8};                    // 游戏用 WriteTexels 写过的序号（可能早于首次使用）
static nvn_hmap g_pool_gpu = {.klen = 8};                   // GPU 写过的内存池
static uint64_t g_ser_gen = 1;                              // 任何「序号 → 存储」映射变了就 +1：各贴图号缓存的视图据此重验
static int g_built; static uint64_t g_uploads;

// ---------- 登记 ----------
static void treg_drop_view(treg_t *r) { if (r->view) { nvn_gpu_view_release(r->view); r->view = NULL; } r->of = NULL; }
void nvn_be_set_tex_pool_n(int n) { pthread_mutex_lock(&g_rmu); g_tpool_n = n; pthread_mutex_unlock(&g_rmu); }
void nvn_be_reg_tex(int id, const tex_t *t, const view_t *v) {
    if (id < 0 || id >= (1 << 20) || !t) return;
    pthread_mutex_lock(&g_rmu);
    if (id >= g_ntreg) { int n = id + 1024; treg_t *nr = realloc(g_treg, (size_t)n * sizeof *nr); if (!nr) { pthread_mutex_unlock(&g_rmu); return; }
        memset(nr + g_ntreg, 0, (size_t)(n - g_ntreg) * sizeof *nr); g_treg = nr; g_ntreg = n; }
    treg_t *r = &g_treg[id];
    int same = r->ok && r->t.serial == t->serial && r->has_v == (v != NULL) && (!v || !memcmp(&r->v, v, sizeof *v));
    if (!same) treg_drop_view(r);
    r->t = *t; r->has_v = v != NULL; if (v) r->v = *v; else memset(&r->v, 0, sizeof r->v); r->ok = 1;   // 只存快照：不建图、不建视图
    pthread_mutex_unlock(&g_rmu);
}
void nvn_be_unreg_tex_range(int base, int n) {
    pthread_mutex_lock(&g_rmu);
    for (int i = base < 0 ? 0 : base; i < base + n && i < g_ntreg; i++) { treg_drop_view(&g_treg[i]); g_treg[i].ok = 0; }
    pthread_mutex_unlock(&g_rmu);
}
void nvn_be_reg_samp(int id, const samp_par *p) {
    if (id < 0 || id >= (1 << 20) || !p) return;
    pthread_mutex_lock(&g_rmu);
    if (id >= g_nsreg) { int n = id + 256; sreg_t *nr = realloc(g_sreg, (size_t)n * sizeof *nr); if (!nr) { pthread_mutex_unlock(&g_rmu); return; }
        memset(nr + g_nsreg, 0, (size_t)(n - g_nsreg) * sizeof *nr); g_sreg = nr; g_nsreg = n; }
    sreg_t *r = &g_sreg[id];
    if (r->s) { nvn_gpu_samp_release(r->s); r->s = NULL; }   // 后端把真正销毁推迟到最后一次使用结束（契约 A3）
    r->p = *p; r->ok = 1;
    pthread_mutex_unlock(&g_rmu);
}

// ---------- 内容归属 ----------
void nvn_be_pool_gpu_written(const void *pool) { uint64_t k = (uint64_t)(uintptr_t)pool; pthread_mutex_lock(&g_rmu); nvn_hm_put(&g_pool_gpu, &k, (void *)1); pthread_mutex_unlock(&g_rmu); }
void nvn_be_tex_cpu_written(const tex_t *t) {
    if (!t || !t->serial) return;
    pthread_mutex_lock(&g_rmu);
    nvn_hm_put(&g_cpu_ser, &t->serial, (void *)1);
    struct rp_tex *x = nvn_hm_get(&g_by_serial, &t->serial);
    if (x) { x->cpu = 1; x->gpu_written = 0; x->uploaded = 0; }   // 游戏刚用 CPU 写了它：下次使用整张重传
    pthread_mutex_unlock(&g_rmu);
}
int nvn_be_tex_gpu_owned(uint64_t serial) {
    pthread_mutex_lock(&g_rmu);
    struct rp_tex *x = nvn_hm_get(&g_by_serial, &serial); int r = x && x->gpu_written;
    pthread_mutex_unlock(&g_rmu);
    return r;
}
// iOS 按页记 GPU 写的时刻（gpw_*，nvn_mtl.m:3560 一带）；这里先按整张贴图判，页级账随读回路径一起接
int nvn_be_tex_gpu_owned_since(uint64_t serial, uint64_t stamp) { (void)stamp; return nvn_be_tex_gpu_owned(serial); }
void rp_tex_mark_gpu_written(const tex_t *t) {
    if (!t || !t->serial) return;
    pthread_mutex_lock(&g_rmu);
    struct rp_tex *x = nvn_hm_get(&g_by_serial, &t->serial);
    if (x) { x->gpu_written = 1; x->cpu = 0; }
    pthread_mutex_unlock(&g_rmu);
}

static int fmt_compressed(int f) { nvn_fmt_info i; return nvn_fmt_info_of((uint32_t)f, &i) && (i.bw > 1 || i.bh > 1); }
static int fmt_depth(int f) { nvn_fmt_info i; return nvn_fmt_info_of((uint32_t)f, &i) && (i.depth || i.stencil); }
static int mem_any(const uint8_t *p, uint64_t n) { for (uint64_t i = 0; i < n; i++) if (p[i]) return 1; return 0; }

// 首次使用时判「存储里是 CPU 写的数据」（nvn_mtl.m tex_cpu_content @3900）。持 g_rmu 调。
static int cpu_content(const tex_t *t) {
    if (!t->mem || !t->pool || t->d.samples > 1 || t->d.target == NVN_TEXTURE_TARGET_BUFFER) return 0;
    if (t->has_layout || nvn_hm_get(&g_cpu_ser, &t->serial)) return 1;   // 随包贴图 / WriteTexels 写过
    uint64_t pk = (uint64_t)(uintptr_t)t->pool;
    int unc = !fmt_compressed(t->d.format) && t->d.target != NVN_TEXTURE_TARGET_3D;
    if (unc && (fmt_depth(t->d.format) || (t->d.flags & (NVN_TEXTURE_FLAGS_DISPLAY | NVN_TEXTURE_FLAGS_VIDEO_DECODE)) || nvn_hm_get(&g_pool_gpu, &pk))) return 0;
    if (t->pool->flags & (NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS | NVN_MEMORY_POOL_FLAGS_VIRTUAL)) return 0;
    if ((t->d.flags & (NVN_TEXTURE_FLAGS_COMPRESSIBLE | NVN_TEXTURE_FLAGS_LINEAR | NVN_TEXTURE_FLAGS_LINEAR_RENDER_TARGET | NVN_TEXTURE_FLAGS_SPARSE))
        || ((t->d.flags & NVN_TEXTURE_FLAGS_IMAGE) && !fmt_compressed(t->d.format))) return 0;
    return mem_any(t->mem, t->L.size);
}

// ---------- 上传：块线性存储 → 逐级逐层线性 → 后端 ----------
static int upload_all(const tex_t *t, struct rp_tex *x, nvn_gpu_cmd c) {
    if (t->d.flags & (NVN_TEXTURE_FLAGS_LINEAR | NVN_TEXTURE_FLAGS_LINEAR_RENDER_TARGET | NVN_TEXTURE_FLAGS_SPARSE)) { nvn_unimpl("tex", "upload_linear_or_sparse", t); return -1; }
    int bw = 1, bh = 1; int bpb = nvn_fmt_bpb(t->d.format, &bw, &bh);
    if (!bpb) { nvn_unimpl("fmt", "upload_unknown_format", t); return -1; }
    nvn_dirty_protect(t->mem, t->L.size); uint64_t st = nvn_dirty_now();   // 先保护、取代号、再读：取代号之后的写下次查得到
    uint32_t levels = t->d.levels ? t->d.levels : 1, layers = t->L.layers ? t->L.layers : 1;
    int is3d = t->d.target == NVN_TEXTURE_TARGET_3D;
    uint8_t *tmp = NULL; size_t cap = 0; int rc = 0;
    for (uint32_t l = 0; l < levels && !rc; l++) {
        uint32_t w = t->d.width >> l, h = t->d.height >> l, dp = is3d ? t->d.depth >> l : 1;
        if (!w) w = 1;
        if (!h) h = 1;
        if (!dp) dp = 1;
        size_t pitch = (size_t)((w + (uint32_t)bw - 1) / (uint32_t)bw) * (size_t)bpb, rows = (h + (uint32_t)bh - 1) / (uint32_t)bh, img = pitch * rows * dp;
        if (img > cap) { uint8_t *n = realloc(tmp, img); if (!n) { rc = -1; break; } tmp = n; cap = img; }
        for (uint32_t y = 0; y < layers; y++) {
            if (nvn_deswizzle(&t->d, l, y, t->mem, tmp, pitch)) { nvn_unimpl("tex", "deswizzle_failed", t); rc = -1; break; }
            NVNcopyRegion r = {0, 0, 0, (int)w, (int)h, (int)dp};
            nvn_gpu_tex_upload(c, x->g, l, y, &r, tmp, pitch, img);
        }
    }
    free(tmp);
    if (!rc) { x->stamp = st; x->uploaded = 1; g_uploads++; }
    return rc;
}

static uint32_t usage_of(const tex_t *t, int cpu) {
    uint32_t caps = nvn_gpu_format_caps((uint32_t)t->d.format), u = NVN_GPU_TEX_SAMPLED | NVN_GPU_TEX_VIEW_FMT;
    // Vulkan 的用途事后补不了，Metal 那边是用到时再升级（tex_upgrade）：能当附件的格式一律带上附件用途
    if ((caps & (NVN_GPU_FMT_RENDER | NVN_GPU_FMT_DEPTH)) && !fmt_compressed(t->d.format)) u |= NVN_GPU_TEX_RENDER;
    if ((t->d.flags & NVN_TEXTURE_FLAGS_IMAGE) && (caps & NVN_GPU_FMT_STORAGE)) u |= NVN_GPU_TEX_STORAGE;
    if (cpu) u |= NVN_GPU_TEX_CPU_UPLOAD;
    return u;
}

static void tex_unref(struct rp_tex *x) {
    if (--x->users > 0 || x->in_alias) return;   // 共用表里的存储由表持有：池销毁时才放（nvn_be_alias_drop_pool）
    nvn_gpu_tex_release(x->g); g_built--; free(x);
}

nvn_gpu_tex rp_tex_resolve(const tex_t *t, nvn_gpu_cmd c) {
    if (!t || !t->serial) return NULL;
    pthread_mutex_lock(&g_rmu);
    struct rp_tex *x = nvn_hm_get(&g_by_serial, &t->serial);
    if (!x) {
        int cpu = cpu_content(t);
        alias_key k; alias_key_of(&k, t);
        if (!cpu && t->pool) x = nvn_hm_get(&g_alias, &k);   // 同存储同描述的另一个对象已经建过：共用
        if (!x) {
            nvn_gpu_tex_desc d = {0}; d.d = t->d; d.usage = usage_of(t, cpu); d.swz = t->set_swz && t->swz != SWZ_IDENTITY ? t->swz : 0; d.stencil_view = t->stencil;
            nvn_gpu_tex g = NULL; nvn_gpu_err err = {0};
            if (!nvn_gpu_ok(nvn_gpu_tex_create(&d, &g, &err))) {
                pthread_mutex_unlock(&g_rmu);
                char name[48]; snprintf(name, sizeof name, "tex_create_fmt_%#x_target_%d", (unsigned)t->d.format, t->d.target); if (nvn_unimpl("gpu", name, t) == 1) nvn_plat_log(NVN_PLAT_LOG_RED, "gpu", err.why);   // 首次：带上后端给的原因
                return NULL;
            }
            x = calloc(1, sizeof *x); x->g = g; x->cpu = (uint8_t)cpu; x->mem = t->mem; x->size = t->L.size; g_built++;
            if (!cpu && t->pool) { nvn_hm_put(&g_alias, &k, x); x->in_alias = 1; }
        }
        x->users++;
        nvn_hm_put(&g_by_serial, &t->serial, x); g_ser_gen++;
    }
    if (x->cpu && !x->gpu_written && c && t->mem && (!x->uploaded || nvn_dirty_since(t->mem, t->L.size, x->stamp))) {
        nvn_gpu_cmd xc = rp_xfer_cmd(&x->up_sub);   // 上传是传输：录进前置段（本次提交里第二次上传才回主段）
        if (xc) upload_all(t, x, xc);
    }
    nvn_gpu_tex g = x->g;
    pthread_mutex_unlock(&g_rmu);
    return g;
}

// ---------- 按（贴图对象，视图记录）取视图：渲染目标、拷贝端点这些不经贴图号的使用点 ----------
enum { VF_N = 64 };
static struct { uint64_t serial; view_t v; uint8_t has_v; nvn_gpu_view view; struct rp_tex *of; } g_vf[VF_N];
static int g_vf_next;
static void vf_drop_serial(uint64_t serial) {   // 持 g_rmu
    for (int i = 0; i < VF_N; i++) if (g_vf[i].view && (!serial || g_vf[i].serial == serial)) { nvn_gpu_view_release(g_vf[i].view); memset(&g_vf[i], 0, sizeof g_vf[i]); }
}
nvn_gpu_view rp_view_for(const tex_t *t, const view_t *v, nvn_gpu_cmd c) {
    nvn_gpu_tex g = rp_tex_resolve(t, c);
    if (!g) return NULL;
    pthread_mutex_lock(&g_rmu);
    struct rp_tex *x = nvn_hm_get(&g_by_serial, &t->serial);
    nvn_gpu_view out = NULL; int slot = -1;
    for (int i = 0; i < VF_N && x; i++) if (g_vf[i].view && g_vf[i].serial == t->serial && g_vf[i].has_v == (v != NULL) && (!v || !memcmp(&g_vf[i].v, v, sizeof *v))) {
        if (g_vf[i].of == x) out = g_vf[i].view; else slot = i;   // 序号换了存储：这一项作废重建
        break; }
    if (!out && x) {
        if (slot < 0) slot = g_vf_next++ % VF_N;
        if (g_vf[slot].view) nvn_gpu_view_release(g_vf[slot].view);
        memset(&g_vf[slot], 0, sizeof g_vf[slot]);
        nvn_gpu_err err = {0};
        if (nvn_gpu_ok(nvn_gpu_view_create(x->g, v, &g_vf[slot].view, &err))) { g_vf[slot].serial = t->serial; g_vf[slot].has_v = v != NULL; if (v) g_vf[slot].v = *v; g_vf[slot].of = x; out = g_vf[slot].view; }
        else { g_vf[slot].view = NULL; if (nvn_unimpl("gpu", "view_create", t) == 1) nvn_plat_log(NVN_PLAT_LOG_RED, "gpu", err.why); }
    }
    pthread_mutex_unlock(&g_rmu);
    return out;
}

// 贴图对象 Finalize（rp_entry.c nvn_be_tex_release 调）：序号不再指向这份存储
void rp_res_tex_gone(uint64_t serial) {
    pthread_mutex_lock(&g_rmu);
    vf_drop_serial(serial);
    struct rp_tex *x = nvn_hm_del(&g_by_serial, &serial);
    nvn_hm_del(&g_cpu_ser, &serial);
    if (x) { tex_unref(x); g_ser_gen++; }
    pthread_mutex_unlock(&g_rmu);
}

// 内存池 Finalize：建在这个池上的共用存储全部出表（nvn_mtl.m nvn_be_alias_drop_pool @2408）
void nvn_be_alias_drop_pool(const void *pool) {
    uint64_t pk = (uint64_t)(uintptr_t)pool;
    pthread_mutex_lock(&g_rmu);
    nvn_hm_del(&g_pool_gpu, &pk);
    for (int again = 1; again;) { again = 0;
        for (uint32_t i = 0; i < g_alias.cap; i++) { if (!g_alias.vals[i]) continue;
            alias_key k; memcpy(&k, g_alias.keys + (size_t)i * sizeof k, sizeof k); if (k.pool != pk) continue;
            struct rp_tex *x = nvn_hm_del(&g_alias, &k); x->in_alias = 0;
            if (x->users <= 0) { nvn_gpu_tex_release(x->g); g_built--; free(x); }
            again = 1; break; } }   // 删除会挪表项：从头再扫
    g_ser_gen++;
    pthread_mutex_unlock(&g_rmu);
}

nvn_gpu_view rp_view_by_id(int id, nvn_gpu_cmd c, const tex_t **t_out) {
    pthread_mutex_lock(&g_rmu);
    if (id < 0 || id >= g_ntreg || !g_treg[id].ok || (g_tpool_n && id >= g_tpool_n)) { pthread_mutex_unlock(&g_rmu); return NULL; }
    tex_t t = g_treg[id].t; view_t v = g_treg[id].v; int has_v = g_treg[id].has_v;
    pthread_mutex_unlock(&g_rmu);
    nvn_gpu_tex g = rp_tex_resolve(&t, c);   // 每次都过一遍：CPU 内容脏了要在这一段里重传
    if (!g) return NULL;
    pthread_mutex_lock(&g_rmu);
    nvn_gpu_view out = NULL;
    if (id < g_ntreg && g_treg[id].ok && g_treg[id].t.serial == t.serial) {
        treg_t *r = &g_treg[id];
        struct rp_tex *x = nvn_hm_get(&g_by_serial, &t.serial);
        if (r->view && (r->gen != g_ser_gen) && r->of != x) treg_drop_view(r);   // 序号换了存储：旧视图作废
        if (!r->view && x) {
            nvn_gpu_err err = {0};
            if (nvn_gpu_ok(nvn_gpu_view_create(x->g, has_v ? &v : NULL, &r->view, &err))) r->of = x;
            else { r->view = NULL; nvn_unimpl("gpu", "view_create", r); }
        }
        r->gen = g_ser_gen; out = r->view;
        if (t_out) *t_out = &r->t;
    }
    pthread_mutex_unlock(&g_rmu);
    return out;
}

// 贴图号 → 登记时的贴图描述快照（着色器编译事实用；不建图）。1 = 有
int rp_tex_snap_by_id(int id, tex_t *t, view_t *v, int *has_v) {
    int ok = 0;
    pthread_mutex_lock(&g_rmu);
    if (id >= 0 && id < g_ntreg && g_treg[id].ok) { if (t) *t = g_treg[id].t; if (v) *v = g_treg[id].v; if (has_v) *has_v = g_treg[id].has_v; ok = 1; }
    pthread_mutex_unlock(&g_rmu);
    return ok;
}

nvn_gpu_samp rp_samp_by_id(int id) {
    pthread_mutex_lock(&g_rmu);
    nvn_gpu_samp s = NULL;
    if (id >= 0 && id < g_nsreg && g_sreg[id].ok) {
        if (!g_sreg[id].s) { nvn_gpu_err err = {0}; if (!nvn_gpu_ok(nvn_gpu_samp_create(&g_sreg[id].p, &g_sreg[id].s, &err))) { g_sreg[id].s = NULL; nvn_unimpl("gpu", "samp_create", &g_sreg[id]); } }
        s = g_sreg[id].s;
    }
    pthread_mutex_unlock(&g_rmu);
    return s;
}

void rp_res_reset(void) {
    pthread_mutex_lock(&g_rmu);
    for (int i = 0; i < g_ntreg; i++) treg_drop_view(&g_treg[i]);
    vf_drop_serial(0);
    for (int i = 0; i < g_nsreg; i++) if (g_sreg[i].s) nvn_gpu_samp_release(g_sreg[i].s);
    free(g_treg); g_treg = NULL; g_ntreg = 0; free(g_sreg); g_sreg = NULL; g_nsreg = 0; g_tpool_n = 0;
    // 一份存储可能同时挂在序号表（多次）和共用表里：先收集去重再放
    struct rp_tex **all = NULL; int n = 0, cap = 0;
    nvn_hmap *tabs[2] = {&g_by_serial, &g_alias};
    for (int k = 0; k < 2; k++) for (uint32_t i = 0; i < tabs[k]->cap; i++) { struct rp_tex *x = tabs[k]->vals[i]; if (!x) continue;
        int dup = 0; for (int j = 0; j < n; j++) if (all[j] == x) { dup = 1; break; }
        if (dup) continue;
        if (n == cap) { cap = cap ? cap * 2 : 64; all = realloc(all, (size_t)cap * sizeof *all); }
        all[n++] = x; }
    for (int j = 0; j < n; j++) { nvn_gpu_tex_release(all[j]->g); free(all[j]); }
    free(all);
    nvn_hmap *clr[4] = {&g_by_serial, &g_alias, &g_cpu_ser, &g_pool_gpu};
    for (int k = 0; k < 4; k++) { uint32_t kl = clr[k]->klen; free(clr[k]->keys); free(clr[k]->vals); nvn_hm_init(clr[k], kl); }
    g_built = 0; g_ser_gen++;
    pthread_mutex_unlock(&g_rmu);
}

int rp_res_tex_built(void) { pthread_mutex_lock(&g_rmu); int n = g_built; pthread_mutex_unlock(&g_rmu); return n; }
int rp_res_tex_serials(void) { pthread_mutex_lock(&g_rmu); int n = (int)g_by_serial.n; pthread_mutex_unlock(&g_rmu); return n; }
uint64_t rp_res_uploads(void) { pthread_mutex_lock(&g_rmu); uint64_t n = g_uploads; pthread_mutex_unlock(&g_rmu); return n; }
