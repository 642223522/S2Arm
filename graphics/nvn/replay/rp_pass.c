// 渲染目标与通道（对齐 nvn_mtl.m：OP_SET_RT @14565、OP_CLEAR_COLOR @14578、OP_CLEAR_DS @14599、rp_begin_ex @5100 一带、rp_flush @5232）。
//   · OP_SET_RT 只换目标，不开通道；通道在下一笔绘制时才开。
//   · 整屏、全通道的清除不编码任何东西：记成「待折清除」，开通道时落成该附件的 load = CLEAR。
//     一直没有绘制：换目标或提交时为它开一个只做清除的通道。
//   · 目标绑定跨命令缓冲、跨提交保留（记录内的贴图快照拷一份自己留着）；打开的通道与待折清除不跨提交。
// 还没接：部分清除（带裁剪 / 部分通道 / 部分模板掩码，iOS 用清除三角形）、通道合并与存储前瞻（TBDR 上省带宽的手段，不影响画面）。
#include "rp_exec.h"
#include "rp_state.h"
#include "rp_res.h"
#include "nvn_unimpl.h"
#include "nvn_fmt_info.h"
#include <math.h>
#include <string.h>

static struct {
    p_set_rt rt; tex_t kept[9]; int has_rt;
    uint8_t clear_c[8]; float cc[8][4];
    int clear_d, clear_s; float cd; int cs;
    int open;                 // 后端通道开着
    uint32_t barrier_bits;    // 游戏发过的屏障位：下一个通道前交给后端
} P;

static void level_size(const tex_t *t, const view_t *v, int has_v, uint32_t *w, uint32_t *h) {
    uint32_t l = has_v && v->set_levels ? v->base_level : 0;
    *w = t->d.width >> l; *h = t->d.height >> l;
    if (!*w) *w = 1;
    if (!*h) *h = 1;
}
static int scissor_full(const tex_t *t, const view_t *v, int has_v) {
    if (!rp_R.has_sc) return 1;
    uint32_t w, h; level_size(t, v, has_v, &w, &h);
    return rp_R.sc.x <= 0 && rp_R.sc.y <= 0 && (int64_t)rp_R.sc.x + rp_R.sc.w >= (int64_t)w && (int64_t)rp_R.sc.y + rp_R.sc.h >= (int64_t)h;
}
static int pending(void) { if (P.clear_d || P.clear_s) return 1; for (int i = 0; i < 8; i++) if (P.clear_c[i]) return 1; return 0; }

void rp_pass_end(nvn_gpu_cmd c) { if (P.open && c) nvn_gpu_pass_end(c); P.open = 0; }

// 开通道（已开着直接回 1）。0 = 开不了（已记账）：调用方跳过这笔绘制。
int rp_pass_begin(nvn_gpu_cmd c) {
    if (P.open) return 1;
    if (!c || !P.has_rt) { if (c) nvn_unimpl("pass", "draw_without_target", NULL); return 0; }
    if (P.rt.n <= 0 || P.rt.n > 8) { nvn_unimpl("gpu", "pass_depth_only", NULL); return 0; }   // 后端现在要求至少一个颜色附件
    nvn_gpu_pass_desc d; memset(&d, 0, sizeof d);
    for (int i = 0; i < P.rt.n; i++) {
        const tex_t *t = P.rt.color[i];
        if (!t) { nvn_unimpl("pass", "null_color_slot", NULL); return 0; }
        nvn_gpu_view v = rp_view_for(t, P.rt.has_cview[i] ? &P.rt.cview[i] : NULL, c);
        if (!v) return 0;
        d.color[i].view = v; d.color[i].store = NVN_GPU_STORE_STORE;
        d.color[i].load = P.clear_c[i] ? NVN_GPU_LOAD_CLEAR : NVN_GPU_LOAD_LOAD;
        if (P.clear_c[i]) {   // 整数格式的清除值转换同 iOS 的清除三角形（nvn_mtl.m:14426）
            nvn_fmt_info fi; int kind = nvn_fmt_info_of((uint32_t)(P.rt.has_cview[i] && P.rt.cview[i].set_format ? P.rt.cview[i].format : t->d.format), &fi) ? fi.kind : NVN_FMT_UNORM;
            for (int k = 0; k < 4; k++) { float f = P.cc[i][k];
                if (kind == NVN_FMT_UINT) d.color[i].clear.u[k] = isnan(f) || f <= 0 ? 0u : f >= 4294967295.0f ? 0xffffffffu : (uint32_t)f;
                else if (kind == NVN_FMT_SINT) d.color[i].clear.i[k] = isnan(f) ? 0 : f >= 2147483647.0f ? INT32_MAX : f <= -2147483648.0f ? INT32_MIN : (int32_t)f;
                else d.color[i].clear.f[k] = f; }
        }
        if (!i) level_size(t, &P.rt.cview[0], P.rt.has_cview[0], &d.w, &d.h);
    }
    d.ncolor = (uint32_t)P.rt.n; d.layers = 1;
    if (P.rt.depth) {
        nvn_fmt_info fi; int ok = nvn_fmt_info_of((uint32_t)P.rt.depth->d.format, &fi);
        nvn_gpu_view v = rp_view_for(P.rt.depth, P.rt.has_dview ? &P.rt.dview : NULL, c);
        if (!v) return 0;
        if (!ok || fi.depth) { d.depth.view = v; d.depth.store = NVN_GPU_STORE_STORE; d.depth.load = P.clear_d ? NVN_GPU_LOAD_CLEAR : NVN_GPU_LOAD_LOAD; d.clear_depth = P.cd; }
        if (ok && fi.stencil) { d.stencil.view = v; d.stencil.store = NVN_GPU_STORE_STORE; d.stencil.load = P.clear_s ? NVN_GPU_LOAD_CLEAR : NVN_GPU_LOAD_LOAD; d.clear_stencil = (uint32_t)P.cs & 0xff; }
    }
    if (P.barrier_bits) { nvn_gpu_barrier(c, P.barrier_bits); P.barrier_bits = 0; }
    nvn_gpu_pass_begin(c, &d);
    for (int i = 0; i < P.rt.n; i++) rp_tex_mark_gpu_written(P.rt.color[i]);
    if (P.rt.depth) rp_tex_mark_gpu_written(P.rt.depth);
    memset(P.clear_c, 0, sizeof P.clear_c); P.clear_d = P.clear_s = 0;
    P.open = 1;
    rp_dirty_all();   // 新通道：已发给后端的管线 / 动态状态 / 绑定全部重发
    return 1;
}

// 结束当前通道；有待折清除而没画过的，为它开一个只做清除的通道
void rp_pass_flush(nvn_gpu_cmd c) {
    if (!P.open && pending() && c && P.has_rt) rp_pass_begin(c);
    rp_pass_end(c);
    if (!c) { memset(P.clear_c, 0, sizeof P.clear_c); P.clear_d = P.clear_s = 0; }   // 没有段：清除无处落，丢弃（提交已按失败处理）
}

void rp_pass_set_rt(nvn_gpu_cmd c, const p_set_rt *r) {
    rp_pass_flush(c);
    P.rt = *r; P.has_rt = 1;
    // 记录里的贴图指针指向记录内的快照，记录所在的命令内存这次提交之后可能被复用：自己留一份（nvn_mtl.m rt_keep_state @4453）
    for (int i = 0; i < 8; i++) if (P.rt.color[i]) { P.kept[i] = *P.rt.color[i]; P.rt.color[i] = &P.kept[i]; }
    if (P.rt.depth) { P.kept[8] = *P.rt.depth; P.rt.depth = &P.kept[8]; }
}

void rp_pass_clear_color(nvn_gpu_cmd c, const p_clear_color *cc, const void *rec) {
    if (!P.has_rt || cc->index < 0 || cc->index >= P.rt.n || cc->index >= 8 || !P.rt.color[cc->index]) { nvn_unimpl("pass", "clear_color_no_target", rec); return; }
    if (!(cc->mask & 0xf)) return;
    int i = cc->index;
    if ((cc->mask & 0xf) != 0xf || !scissor_full(P.rt.color[i], &P.rt.cview[i], P.rt.has_cview[i])) { nvn_unimpl("pass", "clear_color_partial", rec); return; }
    if (P.open) rp_pass_end(c);   // 通道中的整屏清除：结束这一通道，清除挂到下一个通道开头（其余附件照常 LOAD）
    P.clear_c[i] = 1; memcpy(P.cc[i], cc->rgba, sizeof P.cc[i]);
}

void rp_pass_clear_ds(nvn_gpu_cmd c, const p_clear_ds *cd, const void *rec) {
    if (!P.has_rt || !P.rt.depth) { nvn_unimpl("pass", "clear_ds_no_target", rec); return; }
    int sm = cd->stencil_mask & 0xff;
    if (!cd->depth_mask && !sm) return;
    if (!scissor_full(P.rt.depth, &P.rt.dview, P.rt.has_dview) || (sm && sm != 0xff)) { nvn_unimpl("pass", "clear_ds_partial", rec); return; }
    if (P.open) rp_pass_end(c);
    if (cd->depth_mask) { P.clear_d = 1; P.cd = isnan(cd->depth) ? 0 : cd->depth < 0 ? 0 : cd->depth > 1 ? 1 : cd->depth; }
    if (sm) { P.clear_s = 1; P.cs = cd->stencil; }
}

// 游戏的屏障：不拆通道，记下位，下一个通道前交给后端（nvn_mtl.m:14646 的缺省路径；通道内着色器写图像后要求片元顺序的拆通道随图像绑定一起接）
void rp_pass_barrier(uint32_t bits) { P.barrier_bits |= bits; }

void rp_pass_reset(void) { memset(&P, 0, sizeof P); }
int rp_pass_is_open(void) { return P.open; }
const p_set_rt *rp_pass_target(void) { return P.has_rt ? &P.rt : NULL; }
