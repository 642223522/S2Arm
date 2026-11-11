// 上屏（对齐 nvn_mtl.m present_now @15500 一带的裁剪与等比贴合；nvn_present_fit.h 两端共用）。
// 现在的做法：游戏调上屏时在调用线程上直接取一张交换链图、把游戏的贴图按比例贴上去、呈现。
// 还没接：独立的上屏线程与显示节拍（按住 N 拍、选帧、虚拟拍）、实际上屏时刻（后端没有这项能力时按交给呈现引擎的时刻记）、后处理与抗锯齿缩放。
#include "rp_exec.h"
#include "rp_res.h"
#include "nvn_unimpl.h"
#include "nvn_plat.h"
#include "nvn_present_fit.h"
#include "nvn_mtl.h"
#include "platform/plat.h"
#include <pthread.h>
#include <stdio.h>
#include <string.h>

enum { PT_RING = 256 };
static pthread_mutex_t g_pmu = PTHREAD_MUTEX_INITIALIZER;
static nvn_gpu_surface g_surf; static int g_hz;
static uint64_t g_ticket;                     // 已发出的票号（从 1 起）
static double g_shown[PT_RING];               // 票号 → 上屏时刻（秒）；0 = 还没结果，-1 = 丢了
static uint64_t g_n_shown, g_n_dropped;

// 平台件在窗口挂上 / 摘下时调。摘下时保证返回后核心不再用旧的面。
void rp_present_set_surface(nvn_gpu_surface s, int display_hz) {
    pthread_mutex_lock(&g_pmu);
    g_surf = s; g_hz = s ? display_hz : 0;
    pthread_mutex_unlock(&g_pmu);
}
int nvn_be_has_window(void) { pthread_mutex_lock(&g_pmu); int r = g_surf != NULL; pthread_mutex_unlock(&g_pmu); return r; }
int nvn_be_display_hz(void) { pthread_mutex_lock(&g_pmu); int r = g_hz; pthread_mutex_unlock(&g_pmu); return r; }

static void on_shown(void *user, const nvn_gpu_shown *s) {   // 持 g_pmu 的 present 里被后端回调，或后端的回调线程：只写自己的槽
    (void)user;
    double at = s->status == NVN_GPU_SHOWN_AT ? s->at : s->status == NVN_GPU_SHOWN_UNKNOWN ? (double)plat_now_ns() / 1e9 : -1;
    __atomic_store(&g_shown[s->ticket % PT_RING], &at, __ATOMIC_RELEASE);
}

uint64_t nvn_be_present(const tex_t *t, double period_s, const int crop[4]) {
    (void)period_s;
    pthread_mutex_lock(&g_pmu);
    uint64_t ticket = ++g_ticket; double zero = 0;
    __atomic_store(&g_shown[ticket % PT_RING], &zero, __ATOMIC_RELEASE);
    nvn_gpu_shown drop = {ticket, NVN_GPU_SHOWN_DROPPED, 0};
    if (!g_surf || !t) { on_shown(NULL, &drop); g_n_dropped++; pthread_mutex_unlock(&g_pmu); if (t) nvn_unimpl("present", "no_window", t); return ticket; }
    nvn_gpu_view v = rp_view_for(t, NULL, NULL);
    if (!v) { on_shown(NULL, &drop); g_n_dropped++; pthread_mutex_unlock(&g_pmu); return ticket; }
    nvn_gpu_err err = {0}; nvn_gpu_drawable dr; nvn_gpu_rc r = {NVN_GPU_OK};
    for (int attempt = 0; attempt < 2; attempt++) {
        r = nvn_gpu_drawable_acquire(g_surf, 100000000ull, NULL, &dr, &err);
        if (r.code != NVN_GPU_E_OUTDATED) break;
        nvn_gpu_rc rb = nvn_gpu_surface_rebuild(g_surf, &err);   // 窗口尺寸 / 旋转变了：换一代交换链再取
        if (!nvn_gpu_ok(rb)) { r = rb; break; }
    }
    if (!nvn_gpu_ok(r)) {
        on_shown(NULL, &drop); g_n_dropped++;
        pthread_mutex_unlock(&g_pmu);
        if (r.code != NVN_GPU_E_TIMEOUT && nvn_unimpl("present", "acquire_failed", t) == 1) nvn_plat_log(NVN_PLAT_LOG_RED, "present", err.why);
        return ticket;
    }
    nvn_gpu_present_desc d; memset(&d, 0, sizeof d);
    d.src = v; d.filter = 1;
    int c[4]; int fit = pf_crop_fit(crop, t->d.width, t->d.height, c);
    if (fit >= 0) memcpy(d.crop, c, sizeof c);   // 非法裁剪：按整张显示
    double cw = d.crop[2] > 0 ? d.crop[2] : t->d.width, ch = d.crop[3] > 0 ? d.crop[3] : t->d.height;
    pf_vp vp = pf_viewport(dr.w, dr.h, cw, ch);
    d.dst[0] = (int32_t)(vp.x + 0.5); d.dst[1] = (int32_t)(vp.y + 0.5); d.dst[2] = (int32_t)(vp.w + 0.5); d.dst[3] = (int32_t)(vp.h + 0.5);
    if (d.dst[0] + d.dst[2] > (int32_t)dr.w) d.dst[2] = (int32_t)dr.w - d.dst[0];
    if (d.dst[1] + d.dst[3] > (int32_t)dr.h) d.dst[3] = (int32_t)dr.h - d.dst[1];
    r = nvn_gpu_present(g_surf, &dr, &d, ticket, on_shown, NULL, &err);
    if (nvn_gpu_ok(r)) g_n_shown++; else g_n_dropped++;
    pthread_mutex_unlock(&g_pmu);
    if (!nvn_gpu_ok(r) && r.code != NVN_GPU_E_OUTDATED && nvn_unimpl("present", "present_failed", t) == 1) nvn_plat_log(NVN_PLAT_LOG_RED, "present", err.why);
    return ticket;
}
void nvn_be_present_wait(uint64_t ticket) { (void)ticket; }   // 上屏在调用线程上同步做完，返回时已交给后端
double nvn_be_presented_time(uint64_t n) {
    pthread_mutex_lock(&g_pmu); uint64_t last = g_ticket; pthread_mutex_unlock(&g_pmu);
    if (!n || n > last || last - n >= PT_RING) return n && n <= last ? -1 : 0;
    double at; __atomic_load(&g_shown[n % PT_RING], &at, __ATOMIC_ACQUIRE);
    return at;
}
void rp_present_stats(uint64_t *shown, uint64_t *dropped) { pthread_mutex_lock(&g_pmu); if (shown) *shown = g_n_shown; if (dropped) *dropped = g_n_dropped; pthread_mutex_unlock(&g_pmu); }
void rp_present_reset(void) { pthread_mutex_lock(&g_pmu); g_surf = NULL; g_hz = 0; g_ticket = 0; g_n_shown = g_n_dropped = 0; memset(g_shown, 0, sizeof g_shown); pthread_mutex_unlock(&g_pmu); }
