// 渲染目标与通道（对齐 nvn_mtl.m：OP_SET_RT @14565、OP_CLEAR_COLOR @14578、OP_CLEAR_DS @14599、rp_begin_ex @5100 一带、rp_flush @5232）。
//   · OP_SET_RT 只换目标，不开通道；通道在下一笔绘制时才开。
//   · 整屏、全通道的清除不编码任何东西：记成「待折清除」，开通道时落成该附件的 load = CLEAR。
//     一直没有绘制：换目标或提交时为它开一个只做清除的通道。
//   · 目标绑定跨命令缓冲、跨提交保留（记录内的贴图快照拷一份自己留着）；打开的通道与待折清除不跨提交。
//   · 带裁剪或带写掩码的清除（裁剪矩形盖不满目标 / 只写部分颜色通道 / 只写部分模板位）：像绘制一样开通道（待折清除先落），
//     在通道里按矩形清（后端 nvn_gpu_clear_rect，写掩码一并交给它）。清完后端的管线与动态状态不保证，下一笔绘制前全部重发。
// 还没接：通道合并与存储前瞻（TBDR 上省带宽的手段，不影响画面）。
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
// 裁剪矩形与目标（该级）求交。0 = 交集为空（这次清除什么都不动）
static int scissor_rect(const tex_t *t, const view_t *v, int has_v, nvn_gpu_clear *o) {
    uint32_t w, h; level_size(t, v, has_v, &w, &h);
    int64_t x0 = 0, y0 = 0, x1 = w, y1 = h;
    if (rp_R.has_sc) {
        if (rp_R.sc.x > x0) x0 = rp_R.sc.x;
        if (rp_R.sc.y > y0) y0 = rp_R.sc.y;
        if ((int64_t)rp_R.sc.x + rp_R.sc.w < x1) x1 = (int64_t)rp_R.sc.x + rp_R.sc.w;
        if ((int64_t)rp_R.sc.y + rp_R.sc.h < y1) y1 = (int64_t)rp_R.sc.y + rp_R.sc.h;
    }
    if (x1 <= x0 || y1 <= y0) return 0;
    o->x = (int32_t)x0; o->y = (int32_t)y0; o->w = (uint32_t)(x1 - x0); o->h = (uint32_t)(y1 - y0);
    return 1;
}
// 清除值按附件格式的数值类别换算（整数格式的转换同 iOS 的清除三角形，nvn_mtl.m:14426）。out 是 16 字节的 f / u / i 联合
static void color_value(int i, const float rgba[4], void *out) {
    const tex_t *t = P.rt.color[i];
    nvn_fmt_info fi; int kind = nvn_fmt_info_of((uint32_t)(P.rt.has_cview[i] && P.rt.cview[i].set_format ? P.rt.cview[i].format : t->d.format), &fi) ? fi.kind : NVN_FMT_UNORM;
    union { float f[4]; uint32_t u[4]; int32_t i[4]; } v;
    for (int k = 0; k < 4; k++) { float f = rgba[k];
        if (kind == NVN_FMT_UINT) v.u[k] = isnan(f) || f <= 0 ? 0u : f >= 4294967295.0f ? 0xffffffffu : (uint32_t)f;
        else if (kind == NVN_FMT_SINT) v.i[k] = isnan(f) ? 0 : f >= 2147483647.0f ? INT32_MAX : f <= -2147483648.0f ? INT32_MIN : (int32_t)f;
        else v.f[k] = f; }
    memcpy(out, &v, sizeof v);
}
static float depth_value(float d) { return isnan(d) ? 0 : d < 0 ? 0 : d > 1 ? 1 : d; }
// 颜色槽 i 挂的图（同一级、同一层）在更靠前的槽里已经挂过。记录里是贴图对象的快照，按序号比
static int dup_slot(int i) {
    const tex_t *t = P.rt.color[i]; if (!t) return 0;
    uint32_t lv = P.rt.has_cview[i] && P.rt.cview[i].set_levels ? P.rt.cview[i].base_level : 0, ly = P.rt.has_cview[i] && P.rt.cview[i].set_layers ? P.rt.cview[i].min_layer : 0;
    for (int j = 0; j < i; j++) { const tex_t *u = P.rt.color[j]; if (!u || u->serial != t->serial) continue;
        uint32_t lj = P.rt.has_cview[j] && P.rt.cview[j].set_levels ? P.rt.cview[j].base_level : 0, yj = P.rt.has_cview[j] && P.rt.cview[j].set_layers ? P.rt.cview[j].min_layer : 0;
        if (lj == lv && yj == ly) return 1; }
    return 0;
}
int rp_pass_slot_attached(int i) { return P.has_rt && i >= 0 && i < P.rt.n && i < 8 && P.rt.color[i] && !dup_slot(i); }
static int pending(void) { if (P.clear_d || P.clear_s) return 1; for (int i = 0; i < 8; i++) if (P.clear_c[i]) return 1; return 0; }

void rp_pass_end(nvn_gpu_cmd c) { if (P.open && c) nvn_gpu_pass_end(c); P.open = 0; }

// 开通道（已开着直接回 1）。0 = 开不了（已记账）：调用方跳过这笔绘制。
int rp_pass_begin(nvn_gpu_cmd c) {
    if (P.open) return 1;
    if (!c || !P.has_rt) { if (c) nvn_unimpl("pass", "draw_without_target", NULL); return 0; }
    int any_color = 0; for (int i = 0; i < P.rt.n && i < 8; i++) if (P.rt.color[i]) any_color = 1;
    if (P.rt.n < 0 || P.rt.n > 8 || (!any_color && !P.rt.depth)) { nvn_unimpl("pass", "no_attachment", NULL); return 0; }
    nvn_gpu_pass_desc d; memset(&d, 0, sizeof d);
    for (int i = 0; i < P.rt.n; i++) {
        const tex_t *t = P.rt.color[i];
        if (!t) continue;   // 颜色槽里的空位：描述里留空（view = NULL），后端按「不用的槽」处理
        if (dup_slot(i)) continue;   // 同一张图的同一级同一层挂了两个槽：只挂前一个（nvn_mtl.m rt_dup_slot @4797）
        nvn_gpu_view v = rp_view_for(t, P.rt.has_cview[i] ? &P.rt.cview[i] : NULL, c);
        if (!v) return 0;
        d.color[i].view = v; d.color[i].store = NVN_GPU_STORE_STORE;
        d.color[i].load = P.clear_c[i] ? NVN_GPU_LOAD_CLEAR : NVN_GPU_LOAD_LOAD;
        if (P.clear_c[i]) color_value(i, P.cc[i], &d.color[i].clear);
        if (!d.w) level_size(t, &P.rt.cview[i], P.rt.has_cview[i], &d.w, &d.h);   // 尺寸取第一个有图的槽
    }
    d.ncolor = (uint32_t)P.rt.n; d.layers = 1;
    if (!d.w && P.rt.depth) level_size(P.rt.depth, &P.rt.dview, P.rt.has_dview, &d.w, &d.h);   // 只有深度的通道（阴影图、深度预通道）：尺寸取深度目标的
    if (P.rt.depth) {
        nvn_fmt_info fi; int ok = nvn_fmt_info_of((uint32_t)P.rt.depth->d.format, &fi);
        nvn_gpu_view v = rp_view_for(P.rt.depth, P.rt.has_dview ? &P.rt.dview : NULL, c);
        if (!v) return 0;
        if (!ok || fi.depth) { d.depth.view = v; d.depth.store = NVN_GPU_STORE_STORE; d.depth.load = P.clear_d ? NVN_GPU_LOAD_CLEAR : NVN_GPU_LOAD_LOAD; d.clear_depth = P.cd; }
        if (ok && fi.stencil) { d.stencil.view = v; d.stencil.store = NVN_GPU_STORE_STORE; d.stencil.load = P.clear_s ? NVN_GPU_LOAD_CLEAR : NVN_GPU_LOAD_LOAD; d.clear_stencil = (uint32_t)P.cs & 0xff; }
    }
    if (P.barrier_bits) { nvn_gpu_barrier(c, P.barrier_bits); P.barrier_bits = 0; }
    nvn_gpu_pass_begin(c, &d);
    for (int i = 0; i < P.rt.n; i++) if (P.rt.color[i]) rp_tex_mark_gpu_written(P.rt.color[i]);
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
    if ((cc->mask & 0xf) != 0xf || !scissor_full(P.rt.color[i], &P.rt.cview[i], P.rt.has_cview[i])) {
        nvn_gpu_clear cl; memset(&cl, 0, sizeof cl); cl.color = i; cl.color_mask = (uint8_t)(cc->mask & 0xf); cl.stencil_mask = 0xff;
        if (!scissor_rect(P.rt.color[i], &P.rt.cview[i], P.rt.has_cview[i], &cl)) return;
        if (!c || !rp_pass_begin(c)) { if (c) nvn_unimpl("pass", "clear_rect_pass_begin_failed", rec); return; }
        color_value(i, cc->rgba, &cl.value);
        nvn_gpu_clear_rect(c, &cl);
        rp_dirty_all();
        return;
    }
    if (P.open) rp_pass_end(c);   // 通道中的整屏清除：结束这一通道，清除挂到下一个通道开头（其余附件照常 LOAD）
    P.clear_c[i] = 1; memcpy(P.cc[i], cc->rgba, sizeof P.cc[i]);
}

void rp_pass_clear_ds(nvn_gpu_cmd c, const p_clear_ds *cd, const void *rec) {
    if (!P.has_rt || !P.rt.depth) { nvn_unimpl("pass", "clear_ds_no_target", rec); return; }
    int sm = cd->stencil_mask & 0xff;
    if (!cd->depth_mask && !sm) return;
    // 目标实际有哪些面：没有的面这次清除对它无事可做（同 rp_pass_begin 的附件判定）
    nvn_fmt_info fi; int ok = nvn_fmt_info_of((uint32_t)P.rt.depth->d.format, &fi);
    int do_d = cd->depth_mask && (!ok || fi.depth), do_s = sm && ok && fi.stencil;
    if (!do_d && !do_s) return;
    if (!scissor_full(P.rt.depth, &P.rt.dview, P.rt.has_dview) || (do_s && sm != 0xff)) {
        nvn_gpu_clear cl; memset(&cl, 0, sizeof cl); cl.color = -1; cl.color_mask = 0xf; cl.stencil_mask = (uint8_t)(do_s ? sm : 0xff);
        if (!scissor_rect(P.rt.depth, &P.rt.dview, P.rt.has_dview, &cl)) return;
        if (!c || !rp_pass_begin(c)) { if (c) nvn_unimpl("pass", "clear_rect_pass_begin_failed", rec); return; }
        cl.depth = (uint8_t)do_d; cl.stencil = (uint8_t)do_s; cl.depth_value = depth_value(cd->depth); cl.stencil_value = (uint32_t)cd->stencil & 0xff;
        nvn_gpu_clear_rect(c, &cl);
        rp_dirty_all();
        return;
    }
    if (P.open) rp_pass_end(c);
    if (do_d) { P.clear_d = 1; P.cd = depth_value(cd->depth); }
    if (do_s) { P.clear_s = 1; P.cs = cd->stencil; }
}

// 游戏的屏障：不拆通道，记下位，下一个通道前交给后端（nvn_mtl.m:14646 的缺省路径；通道内着色器写图像后要求片元顺序的拆通道随图像绑定一起接）
void rp_pass_barrier(uint32_t bits) { P.barrier_bits |= bits; }

void rp_pass_reset(void) { memset(&P, 0, sizeof P); }
int rp_pass_is_open(void) { return P.open; }
const p_set_rt *rp_pass_target(void) { return P.has_rt ? &P.rt : NULL; }
