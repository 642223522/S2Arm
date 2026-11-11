// 前端调用的其余入口（上沿 nvn_be_*，声明在 nvn_mtl.h / nvn_obj.h）。
// 有真实语义而新层还没接的入口，一律经 nvn_unimpl("be", 名字) 记账后返回「没有 / 没做」，不返回假成功；
// 只是 Metal 侧诊断读数的入口返回 0。接上一个就把对应的 nvn_unimpl 换成实现，并在单测里加用例。
#include "rp_exec.h"
#include "rp_state.h"
#include "nvn_unimpl.h"
#include "nvn_plat.h"
#include "nvn_backend.h"
#include "nvn_mtl.h"
#include "nvn_hmap.h"

void rp_res_tex_gone(uint64_t serial);   // rp_res.c
void rp_res_reset(void);
void rp_buf_pool_gone(const void *mem);   // rp_buf.c
void rp_buf_reset(void);
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>

#define UN(name) nvn_unimpl("be", name, __builtin_return_address(0))

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;

void mtl_init(void) {}

// ---------- 内存池登记：按地址判断「这段在不在某个池里」----------
enum { RP_NPOOL = 4096 };
static struct { const uint8_t *mem; uint64_t size; } g_pool[RP_NPOOL];
static int g_npool;
void nvn_be_pool_add(const void *mem, uint64_t size) {
    if (!mem || !size) return;
    pthread_mutex_lock(&g_mu);
    if (g_npool < RP_NPOOL) g_pool[g_npool++] = (__typeof__(g_pool[0])){mem, size};
    else { pthread_mutex_unlock(&g_mu); nvn_unimpl("limit", "pool_table_full_4096", mem); return; }
    pthread_mutex_unlock(&g_mu);
}
void nvn_be_pool_del(const void *mem) {
    pthread_mutex_lock(&g_mu);
    for (int i = 0; i < g_npool; i++) if (g_pool[i].mem == mem) { g_pool[i] = g_pool[--g_npool]; break; }
    pthread_mutex_unlock(&g_mu);
    rp_buf_pool_gone(mem);
}
int nvn_be_addr(uint64_t addr, uint64_t len, void **buf, uint64_t *off) {
    int hit = 0;
    pthread_mutex_lock(&g_mu);
    for (int i = 0; i < g_npool; i++) { uint64_t b = (uint64_t)(uintptr_t)g_pool[i].mem;
        if (addr >= b && addr - b <= g_pool[i].size && len <= g_pool[i].size - (addr - b)) { if (buf) *buf = (void *)g_pool[i].mem; if (off) *off = addr - b; hit = 1; break; } }
    pthread_mutex_unlock(&g_mu);
    return hit;
}
int rp_pool_find(uint64_t addr, uint64_t len, const uint8_t **mem, uint64_t *size) {
    int hit = 0;
    pthread_mutex_lock(&g_mu);
    for (int i = 0; i < g_npool; i++) { uint64_t b = (uint64_t)(uintptr_t)g_pool[i].mem;
        if (addr >= b && addr - b <= g_pool[i].size && len <= g_pool[i].size - (addr - b)) { if (mem) *mem = g_pool[i].mem; if (size) *size = g_pool[i].size; hit = 1; break; } }
    pthread_mutex_unlock(&g_mu);
    return hit;
}
int rp_pool_count(void) { pthread_mutex_lock(&g_mu); int n = g_npool; pthread_mutex_unlock(&g_mu); return n; }
void nvn_be_pool_addressed(const void *mem, uint64_t size) { (void)mem; (void)size; }   // 原始全局内存表：翻译器的裸地址访问接上时用

// ---------- 贴图：初始化只登记序号，建图在首次使用（nvn_mtl.m:2597 / :4113）----------
static nvn_hmap g_tex_live; static int g_tex_live_inited;
static _Atomic uint64_t g_tex_init_n, g_tex_rel_n;
void nvn_be_tex_init(const tex_t *t) {
    if (!t->serial) return;
    atomic_fetch_add(&g_tex_init_n, 1);
    pthread_mutex_lock(&g_mu);
    if (!g_tex_live_inited) { nvn_hm_init(&g_tex_live, 8); g_tex_live_inited = 1; }
    nvn_hm_put(&g_tex_live, &t->serial, (void *)1);
    pthread_mutex_unlock(&g_mu);
}
void nvn_be_tex_release(tex_t *t) {
    if (!t || !t->serial) return;
    atomic_fetch_add(&g_tex_rel_n, 1);
    pthread_mutex_lock(&g_mu);
    if (g_tex_live_inited) nvn_hm_del(&g_tex_live, &t->serial);
    pthread_mutex_unlock(&g_mu);
    rp_res_tex_gone(t->serial);
}
int rp_tex_live_n(void) { pthread_mutex_lock(&g_mu); int n = g_tex_live_inited ? (int)g_tex_live.n : 0; pthread_mutex_unlock(&g_mu); return n; }
void nvn_be_tex_counters(uint64_t *init, uint64_t *rel) { if (init) *init = atomic_load(&g_tex_init_n); if (rel) *rel = atomic_load(&g_tex_rel_n); }
void nvn_be_tex_tick(uint64_t frame) { (void)frame; }
int nvn_be_tex_from_gl(void *t, uint32_t gl_name) { (void)t; (void)gl_name; UN("tex_from_gl"); return 0; }
void nvn_be_xv_window_tex(uint64_t serial) { (void)serial; }   // 跨提交有效性账本随通道规划接
void nvn_be_read_texels(const tex_t *t, unsigned level, unsigned layer0, const NVNcopyRegion *r, uint8_t *dst, size_t row, size_t img) {
    (void)t; (void)level; (void)layer0; (void)r; (void)dst; (void)row; (void)img; UN("read_texels"); }

// ---------- 程序（描述符池登记、贴图内容归属在 rp_res.c）----------
void nvn_be_prog_release(prog_t *p) { (void)p; }               // 还没有按程序的管线缓存：没有东西要释放
void nvn_be_shader_prefetch(const uint8_t key[8]) { (void)key; }   // 预取是提速手段，不影响正确性；着色器链接上后再接
int nvn_be_multi_draw_range(void) { return 0; }                // 0 = 前端逐条录间接计数多绘；OP_MULTI_DRAW 接上后改 1
int nvn_be_buf_extent_consumer(void) { return 1; }             // Vulkan 上 size = 0 的存储绑定要按地址求活缓冲长度：让前端登记

// ---------- 全局状态 ----------
static int g_depth_zero, g_origin_ll = 1; static uint64_t g_frame;
void nvn_be_set_depth_zero(int on) { g_depth_zero = on; }
void nvn_be_set_origin_lower_left(int on) { g_origin_ll = on; }
void nvn_be_set_frame(uint64_t f) { g_frame = f; }
int rp_depth_zero(void) { return g_depth_zero; }
int rp_origin_lower_left(void) { return g_origin_ll; }
uint64_t rp_frame(void) { return g_frame; }

// ---------- 事件 / 跨队列：GPU 侧等事件未接（OP_SIGNAL_EVENT+WAIT），所以没有停住的队列 ----------
void nvn_be_event_written(volatile uint32_t *val) { (void)val; }
void nvn_be_event_gpu_recorded(volatile uint32_t *val) { (void)val; }
void nvn_be_xq_flush(void *q, const char *why) { (void)q; (void)why; }
int nvn_be_xq_fence(void *q, void *s) { (void)q; (void)s; return 0; }
int nvn_be_xq_owed(const void *s, void **q) { (void)s; (void)q; return 0; }
int nvn_be_xq_owed_wait(const void *s, uint64_t ns) { (void)s; (void)ns; return 1; }
void nvn_be_xq_wait_queue(void *q, void *owner) { (void)q; (void)owner; }

// ---------- 等完成 ----------
void nvn_be_finish(void) { uint64_t f = nvn_be_last_fence(); if (f) nvn_be_wait(f, 5000000000ull); }
void nvn_be_drain(void) { nvn_be_finish(); }

// ---------- 上屏与节拍：未接 ----------
static _Atomic uint64_t g_present_n;
uint64_t nvn_be_present(const tex_t *t, double period_s, const int crop[4]) { (void)t; (void)period_s; (void)crop; UN("present"); return atomic_fetch_add(&g_present_n, 1) + 1; }
void nvn_be_present_wait(uint64_t ticket) { (void)ticket; }
double nvn_be_presented_time(uint64_t n) { (void)n; return -1; }   // 没上屏：按「丢弃」报，不拿别的时刻冒充
int nvn_be_has_window(void) { return 0; }
int nvn_be_display_hz(void) { return 0; }
int nvn_be_link_active(void) { return 0; }
int nvn_be_link_wait_tick(int vsyncs, uint64_t timeout_ns) { (void)vsyncs; (void)timeout_ns; return 0; }
void nvn_be_ub_present(double iv_ms) { (void)iv_ms; }

// ---------- 会话 ----------
void nvn_be_begin_session(void) {}
int nvn_be_request_stop(void) { return 0; }
int nvn_be_drain_session(void) { nvn_be_finish(); return 0; }
int nvn_be_shutdown_session(void) { rp_res_reset(); rp_buf_reset(); rp_state_reset(); return 0; }

// ---------- Metal 侧诊断读数：新层没有对应账本，报 0 ----------
double nvn_be_gpu_ms(uint64_t f) { (void)f; return 0; }
int nvn_be_gpu_span(uint64_t f, uint64_t *t0, uint64_t *t1) { (void)f; if (t0) *t0 = 0; if (t1) *t1 = 0; return 0; }
void nvn_be_stats(uint64_t *passes, uint64_t *draws) { if (passes) *passes = 0; if (draws) *draws = 0; }
void nvn_be_args_stats(uint64_t *enc, uint64_t *reuse) { if (enc) *enc = 0; if (reuse) *reuse = 0; }
void nvn_be_use_stats(uint64_t *call, uint64_t *skip) { if (call) *call = 0; if (skip) *skip = 0; }
uint64_t nvn_be_ds_omit(void) { return 0; }
uint64_t nvn_be_drawable_ns_take(void) { return 0; }
void nvn_be_bw(uint64_t *load, uint64_t *store, uint64_t *full) { if (load) *load = 0; if (store) *store = 0; if (full) *full = 0; }
uint64_t nvn_be_udc_saved_bytes(void) { return 0; }
void nvn_be_pkg_stats(uint64_t *uploads, uint64_t *reuploads) { if (uploads) *uploads = 0; if (reuploads) *reuploads = 0; }
uint64_t nvn_be_upload_ns_take(void) { return 0; }
uint64_t nvn_be_upload_gpu_ns_take(void) { return 0; }
void nvn_be_create_stats(uint64_t *lib, uint64_t *pso) { if (lib) *lib = 0; if (pso) *pso = 0; }
void nvn_be_vbuf_stats(uint64_t *resolve, uint64_t *reuse, uint64_t *set, uint64_t *skip) { if (resolve) *resolve = 0; if (reuse) *reuse = 0; if (set) *set = 0; if (skip) *skip = 0; }
void mtl_res_counts(uint32_t tick, const char *why) { (void)tick; (void)why; }
void mtl_res_snapshot(mtl_res_count *out) { if (out) memset(out, 0, sizeof *out); }
void bf_want_note(const char *key) { (void)key; }
uint64_t nvn_be_upload_bytes(void) { return 0; }
void nvn_be_create_ns(uint64_t *lib_ns, uint64_t *pso_ns) { if (lib_ns) *lib_ns = 0; if (pso_ns) *pso_ns = 0; }

// ---------- 帧率目标、帧录放 ----------
int dm_fps_setting(void) __attribute__((weak));   // 宿主：玩家的帧率设置；宿主没给这个入口时按 60
int nvn_be_fps_target(void) { return dm_fps_setting && dm_fps_setting() == 30 ? 30 : 60; }
// 帧录放（把一帧的命令流存盘再回放）只在 Metal 后端有（nvn_frame_rec.inc）：这里恒关
int nvn_frec_on(void) { return 0; }
void nvn_frec_submit(const uint64_t *h, int n) { (void)h; (void)n; }
void nvn_frec_present(const tex_t *t, double period, const int crop[4]) { (void)t; (void)period; (void)crop; }
