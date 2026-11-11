// 绘制（对齐 nvn_mtl.m draw / draw_emit @12900 一带与 encode_args_ @9640 的职责）：
// 状态类命令早已落在 rp_S 里，这里在绘制时把它们变成后端的管线、动态状态、顶点流和绑定，再发绘制。
// 没改过的不重发：管线看 rp_pso_dirty，各阶段绑定看 rp_args_dirty[阶段]。
// 还没接：间接绘制、间接计数多绘、变换反馈、四边形 / 线环等要展开的图元、图元重启以外的小状态、存储缓冲与图像绑定、空槽假贴图。
#include "rp_exec.h"
#include "rp_state.h"
#include "rp_res.h"
#include "rp_shader.h"
#include "nvn_unimpl.h"
#include "nvn_plat.h"
#include "nvn_refl.h"
#include "nvn_fmt_info.h"
#include <stdio.h>
#include <string.h>

// SupportBuffer 里现在要填的字段（翻译器产物的布局；其余保持 0）
enum { SB_RENDER_SCALE = 192, SB_S2A_FLAGS = 1392, SB_S2A_POINT = 1408, SB_RENDER_SCALE_Y = 1440, SB_RENDER_SCALE_COUNT = 73 };
// 驱动常量段 c0 的合成布局（着色器从它读存储缓冲描述符表、最大点径、base instance）
enum { DRV0_BYTES = 0xA00 };
static const int k_drv0_base[5] = {0x110, 0x510, 0x410, 0x210, 0x310};   // 各图形阶段的存储缓冲表起点

int rp_pool_find(uint64_t addr, uint64_t len, const uint8_t **mem, uint64_t *size);   // rp_entry.c

static const struct rp_prog *g_prog; static nvn_gpu_pipe g_pipe; static nvn_gpu_cmd g_pipe_cmd;
static uint64_t g_draws, g_skips; static uint32_t g_prim = ~0u;

static int alloc_copy(nvn_gpu_cmd c, uint64_t n, const void *src, nvn_gpu_slice *sl) {
    nvn_gpu_caps caps; nvn_gpu_caps_get(&caps);
    nvn_gpu_err err = {0};
    if (!nvn_gpu_ok(nvn_gpu_arena_alloc(c, n, caps.min_ubo_align ? caps.min_ubo_align : 256, sl, &err)) || !sl->cpu) return 0;
    if (src) memcpy(sl->cpu, src, (size_t)n); else memset(sl->cpu, 0, (size_t)n);
    return 1;
}

static int g_log_left;   // 逐笔日志还剩几行（调试开关 nvk_drawlog：上屏每 600 帧给下一帧开一次，见 rp_draw_log_arm）
static int skip(const char *why, const void *rec) {
    nvn_unimpl("draw", why, rec); g_skips++;
    if (g_log_left) { g_log_left--; char b[96]; snprintf(b, sizeof b, "跳过一笔：%s", why); nvn_plat_log(NVN_PLAT_LOG_INFO, "draw", b); }
    return 0;
}
void rp_draw_log_arm(int lines) { g_log_left = lines; }

// 一个阶段的全部绑定。0 = 有取不到的资源（已记账），这笔不画
static int bind_stage(nvn_gpu_cmd c, const struct rp_prog *pg, int st, uint32_t base_instance, const nvn_gpu_view *tv, const nvn_gpu_samp *ts, const void *rec) {
    nvn_gpu_binding b[RP_PROG_ENT_MAX]; uint32_t n = 0;
    nvn_gpu_caps caps; nvn_gpu_caps_get(&caps);
    for (uint32_t i = 0; i < pg->nent[st]; i++) {
        const nvn_gpu_layout_ent *e = &pg->ent[st][i];
        nvn_gpu_binding *o = &b[n]; memset(o, 0, sizeof *o); o->ent = (uint16_t)i; o->cls = e->cls;
        nvn_gpu_slice sl;
        switch (e->src_kind) {
            case NVN_RB_SUPPORT: {
                if (!alloc_copy(c, pg->support_bytes, NULL, &sl)) return skip("arena_alloc_failed", rec);
                uint32_t flags = (rp_depth_zero() ? 0u : 1u) | 2u;   // 位 0：深度 −1..1；位 1：base vertex / instance 取内建（后端基线要求 shaderDrawParameters）
                if (SB_S2A_FLAGS + 4 <= pg->support_bytes) memcpy(sl.cpu + SB_S2A_FLAGS, &flags, 4);
                float one = 1.0f;
                if (SB_S2A_POINT + 4 <= pg->support_bytes) memcpy(sl.cpu + SB_S2A_POINT, &one, 4);
                for (uint32_t k = 0; k < SB_RENDER_SCALE_COUNT; k++) {
                    if (SB_RENDER_SCALE + k * 16 + 4 <= pg->support_bytes) memcpy(sl.cpu + SB_RENDER_SCALE + k * 16, &one, 4);
                    if (SB_RENDER_SCALE_Y + k * 16 + 4 <= pg->support_bytes) memcpy(sl.cpu + SB_RENDER_SCALE_Y + k * 16, &one, 4);
                }
                o->u.b.buf = sl.buf; o->u.b.off = sl.off; o->u.b.len = pg->support_bytes; break; }
            case NVN_RB_DRV0: {
                if (!alloc_copy(c, DRV0_BYTES, NULL, &sl)) return skip("arena_alloc_failed", rec);
                for (int r = 0; r < 16; r++) { const p_bind_buf *sb = &rp_S.ssbo[st][r]; if (!sb->addr) continue;
                    uint64_t a = sb->addr; uint32_t sz = (uint32_t)sb->size; memcpy(sl.cpu + k_drv0_base[st] + 16 * r, &a, 8); memcpy(sl.cpu + k_drv0_base[st] + 16 * r + 8, &sz, 4); }
                float max_point = 2047.0f; memcpy(sl.cpu + 0x610, &max_point, 4); memcpy(sl.cpu + 0x644, &base_instance, 4);
                o->u.b.buf = sl.buf; o->u.b.off = sl.off; o->u.b.len = DRV0_BYTES; break; }
            case NVN_RB_C1: {
                if (!(pg->c1_ok >> st & 1)) return skip("c1_segment_not_captured", rec);
                if (!alloc_copy(c, 0x100, pg->c1[st], &sl)) return skip("arena_alloc_failed", rec);
                o->u.b.buf = sl.buf; o->u.b.off = sl.off; o->u.b.len = 0x100; break; }
            case NVN_RB_CBUF: {
                const p_bind_buf *ub = &rp_S.ubo[st][e->src_reg];
                if (!ub->addr || !ub->size) return skip("uniform_buffer_unbound", rec);
                // 常量缓冲一律拷进本段的暂存区再绑：就是编码这一刻的内容（按序的 OP_UPDATE_UB 之后再用自然是新值），
                // 不经池镜像，也就没有通道内的传输。地址必须在登记过的池里。
                if (!rp_pool_find(ub->addr, ub->size, NULL, NULL)) return skip("uniform_buffer_outside_pools", rec);
                if (!alloc_copy(c, ub->size, (const void *)(uintptr_t)ub->addr, &sl)) return skip("arena_alloc_failed", rec);
                o->u.b.buf = sl.buf; o->u.b.off = sl.off; o->u.b.len = ub->size; break; }
            case NVN_RB_TEX: {
                if (!tv[i]) return skip("texture_slot_unresolved", rec);
                if (!ts[i]) return skip("sampler_slot_unresolved", rec);
                o->u.ts.view = tv[i]; o->u.ts.samp = ts[i]; break; }
            default: return skip("binding_source_unknown", rec);
        }
        n++;
    }
    nvn_gpu_bind(c, st ? NVN_GPU_SH_FS : NVN_GPU_SH_VS, b, n);
    return 1;
}

static void fill_dyn(nvn_gpu_dyn *d, uint32_t tw, uint32_t th) {
    memset(d, 0, sizeof *d);
    d->nvp = 1;
    if (rp_S.has_vp) { memcpy(d->vp[0], rp_S.vp[0], 16); } else { d->vp[0][2] = (float)tw; d->vp[0][3] = (float)th; }
    d->vp[0][4] = rp_S.dr[0]; d->vp[0][5] = rp_S.dr[1];
    memcpy(d->vp_sw, rp_S.vp_sw, sizeof d->vp_sw);
    if (rp_R.has_sc) { d->has_sc = 1; d->sc[0] = rp_R.sc.x; d->sc[1] = rp_R.sc.y; d->sc[2] = rp_R.sc.w; d->sc[3] = rp_R.sc.h; }
    d->origin_ll = (uint8_t)rp_origin_lower_left(); d->depth_clamp = (uint8_t)(rp_S.depth_clamp != 0);
    d->po = rp_S.po;
    memcpy(d->st_vmask, rp_S.st_vmask, sizeof d->st_vmask); memcpy(d->st_wmask, rp_S.st_wmask, sizeof d->st_wmask); memcpy(d->st_ref, rp_S.st_ref, sizeof d->st_ref);
    memcpy(d->blend_color, rp_S.blend_color, sizeof d->blend_color);
    d->ds = rp_S.ds; d->poly = rp_S.poly;
}

// OP_DRAW / OP_DRAW_IDX 共用。di 非空 = 带索引
void rp_draw(nvn_gpu_cmd c, const p_draw *dr, const p_draw_idx *di, const void *rec) {
    if (!c) return;
    uint32_t prim = (uint32_t)(di ? di->prim : dr->prim);
    if ((di && (di->ind || di->mdi_cnt)) || (dr && (dr->ind || dr->mdi_cnt))) { skip("indirect", rec); return; }
    if (dr && dr->tfc) { skip("transform_feedback_count", rec); return; }
    if (rp_S.tf_on) { skip("transform_feedback_active", rec); return; }
    if (!(prim == 0 || prim == 1 || prim == 3 || prim == 4 || prim == 5 || prim == 6)) { char nm[24]; snprintf(nm, sizeof nm, "prim_%u", prim); skip(nm, rec); return; }
    uint32_t count = (uint32_t)(di ? di->count : dr->count);
    if (!count) return;
    const p_set_rt *rt = rp_pass_target();
    if (!rt) { skip("draw_without_target", rec); return; }
    // 程序：管线状态或任一阶段的绑定变过才重新取（贴图槽里换了不同类型的贴图会换变体）
    if (prim != g_prim) { g_prim = prim; rp_pso_dirty = 1; }   // 图元在绘制记录里，不在状态块里：换了图元就是换管线
    int args_dirty = rp_args_dirty[0] || rp_args_dirty[1];
    if (!g_prog || rp_pso_dirty || args_dirty) {
        struct rp_shader_req q; memset(&q, 0, sizeof q); q.prim = prim; q.rt_count = rt->n;
        for (int i = 0; i < rt->n && i < 8; i++) if (rt->color[i]) q.rt_format[i] = (uint32_t)(rt->has_cview[i] && rt->cview[i].set_format ? rt->cview[i].format : rt->color[i]->d.format);
        const struct rp_prog *np = NULL;
        int sr = rp_shader_resolve(&q, &np);
        if (sr) { skip(sr > 0 ? "program_not_ready" : "program_unresolved", rec); g_prog = NULL; return; }
        if (np != g_prog) { g_prog = np; rp_pso_dirty = 1; }
    }
    // 先把这笔要用的资源都取好：池镜像同步、贴图上传是传输，不能出现在通道里，必须在开通道之前做完
    nvn_gpu_buf vb_buf[16]; uint64_t vb_off[16]; uint32_t streams = 0;
    for (int i = 0; i < rp_S.nattr && i < 16; i++) if (g_prog->attr_mask >> i & 1) streams |= 1u << rp_S.attr[i].stream;
    for (int i = 0; i < 16; i++) if (streams >> i & 1) {
        uint64_t va = nvn_ga2ca(rp_S.vbuf[i].address), vn = rp_S.vbuf[i].size;   // 记录里的顶点缓冲地址是 GPU 地址
        if (!va || !vn) { skip("vertex_stream_unbound", rec); return; }
        if (!rp_buf_resolve(c, va, vn, &vb_buf[i], &vb_off[i])) { skip("vertex_buffer_unresolved", rec); return; }
    }
    nvn_gpu_draw_args a; memset(&a, 0, sizeof a);
    if (di) {
        if (di->itype < 0 || di->itype > 2) { skip("index_type_invalid", rec); return; }
        uint32_t isz = di->itype == 0 ? 1 : di->itype == 1 ? 2 : 4;
        if (!rp_buf_resolve(c, di->ibuf, (uint64_t)count * isz, &a.ibuf, &a.ioff)) { skip("index_buffer_unresolved", rec); return; }
        a.itype = (uint32_t)di->itype; a.base_vertex = di->base_vertex;
    } else a.first = (uint32_t)dr->first;
    static nvn_gpu_view tv[RP_PROG_STAGES][RP_PROG_ENT_MAX]; static nvn_gpu_samp ts[RP_PROG_STAGES][RP_PROG_ENT_MAX];
    char tl[160]; size_t tn = 0; tl[0] = 0;   // 逐笔日志用：这笔采样的贴图
    for (int st = 0; st < 2; st++) for (uint32_t i = 0; i < g_prog->nent[st]; i++) {
        const nvn_gpu_layout_ent *e = &g_prog->ent[st][i]; tv[st][i] = NULL; ts[st][i] = NULL;
        if (e->src_kind != NVN_RB_TEX) continue;
        uint64_t h = rp_S.tex[st][e->src_reg];
        const tex_t *tt = NULL;
        tv[st][i] = rp_view_by_id(h ? (int)(h & 0xFFFFF) : rp_S.tex_base, c, &tt);
        if (g_log_left && tn < sizeof tl - 56) {
            int id = h ? (int)(h & 0xFFFFF) : rp_S.tex_base;
            if (tt) tn += (size_t)snprintf(tl + tn, sizeof tl - tn, " t%d.%u=#%d(%#x %dx%d swz %#x)", st, (unsigned)e->src_reg, id, (unsigned)tt->d.format, tt->d.width, tt->d.height, tt->set_swz ? (unsigned)tt->swz : 0u);
            else tn += (size_t)snprintf(tl + tn, sizeof tl - tn, " t%d.%u=#%d(无)", st, (unsigned)e->src_reg, id);
        }
        ts[st][i] = rp_samp_by_id(h ? (int)(h >> 20) : rp_S.samp_base);
    }
    if (!rp_pass_begin(c)) { skip("pass_begin_failed", rec); return; }
    if (rp_S.poly.offset_en) nvn_unimpl("gpu", "polygon_offset_ignored", rec);   // 后端还没接深度偏移：照画，记一笔
    if (rp_pso_dirty || !g_pipe || g_pipe_cmd != c) {
        nvn_gpu_pipe_desc pd; memset(&pd, 0, sizeof pd);
        pd.st[0].sh = g_prog->sh[0]; pd.st[1].sh = g_prog->sh[1];
        for (int i = 0; i < rt->n && i < 8; i++) { pd.cfmt[i] = rt->color[i] ? (uint32_t)(rt->has_cview[i] && rt->cview[i].set_format ? rt->cview[i].format : rt->color[i]->d.format) : 0; pd.lmap[i] = (uint8_t)i; }
        if (rt->depth) { nvn_fmt_info fi; uint32_t f = (uint32_t)rt->depth->d.format; int ok = nvn_fmt_info_of(f, &fi); if (!ok || fi.depth) pd.dfmt = f; if (ok && fi.stencil) pd.sfmt = f; }
        pd.samples = rt->n && rt->color[0] ? (uint32_t)rt->color[0]->d.samples : 0;
        pd.prim = prim; pd.patch_size = (uint32_t)rp_S.patch_size; pd.prim_restart = (uint8_t)(rp_S.restart.on != 0);
        memcpy(pd.blend, rp_S.blend, sizeof pd.blend); pd.color = rp_S.color; pd.chmask = rp_S.chmask; pd.ms = rp_S.ms;
        for (int i = 0; i < rp_S.nattr && i < 16; i++) pd.attr[i] = rp_S.attr[i];
        for (int i = 0; i < rp_S.nstream && i < 16; i++) pd.stream[i] = rp_S.stream[i];
        pd.ds = rp_S.ds; pd.poly = rp_S.poly; pd.rast_discard = (uint8_t)(rp_S.rast_discard != 0);
        nvn_gpu_pipe np = NULL; nvn_gpu_err err = {0};
        nvn_gpu_rc r = nvn_gpu_pipe_get(&pd, NVN_GPU_PIPE_SYNC, &np, &err);
        if (!nvn_gpu_ok(r)) { if (nvn_unimpl("gpu", "pipe_get", rec) == 1) nvn_plat_log(NVN_PLAT_LOG_RED, "gpu", err.why); g_skips++; g_pipe = NULL; return; }
        g_pipe = np; g_pipe_cmd = c;
        nvn_gpu_set_pipe(c, g_pipe);
        rp_args_dirty[0] = rp_args_dirty[1] = 1;   // 换了管线：两个阶段的绑定都重发
    }
    uint32_t tw = 1, th = 1; if (rt->n && rt->color[0]) { uint32_t l = rt->has_cview[0] && rt->cview[0].set_levels ? rt->cview[0].base_level : 0; tw = rt->color[0]->d.width >> l; th = rt->color[0]->d.height >> l; if (!tw) tw = 1; if (!th) th = 1; }
    nvn_gpu_dyn dyn; fill_dyn(&dyn, tw, th); nvn_gpu_set_dyn(c, &dyn);
    for (int i = 0; i < 16; i++) if (streams >> i & 1) nvn_gpu_set_vbuf(c, (uint32_t)i, vb_buf[i], vb_off[i]);
    uint32_t base_instance = (uint32_t)(di ? di->base_instance : dr->base_instance);
    for (int st = 0; st < 2; st++) if (!bind_stage(c, g_prog, st, base_instance, tv[st], ts[st], rec)) return;   // 首版每笔都整组重发（support / c0 每笔在暂存区里新建）；按脏位省重发是后面的事
    a.prim = prim; a.count = count; a.instances = (uint32_t)(di ? di->instances : dr->instances); if (!a.instances) a.instances = 1; a.base_instance = base_instance;
    nvn_gpu_draw(c, &a);
    if (g_log_left) {
        g_log_left--;
        char b[420]; const blend_st *bl = &rp_S.blend[0];
        snprintf(b, sizeof b, "第 %llu 笔：图元 %u 数 %u 实例 %u%s 目标 %ux%u 格式 %#x 程序 %02x%02x/%02x%02x 混合 开%#x 源%u 目%u 掩码 %#x 视口 %.0f,%.0f %.0fx%.0f 裁剪 %d(%d,%d %dx%d) 深度测 %d 模板 %d 剔除 %u 正面 %u%s",
                 (unsigned long long)g_draws, prim, count, a.instances, di ? " 带索引" : "", tw, th, (unsigned)(rt->n && rt->color[0] ? rt->color[0]->d.format : 0),
                 rp_S.skey[0][0], rp_S.skey[0][1], rp_S.skey[1][0], rp_S.skey[1][1], (unsigned)rp_S.color.blend_en, (unsigned)bl->src_rgb, (unsigned)bl->dst_rgb, (unsigned)rp_S.chmask.mask,
                 dyn.vp[0][0], dyn.vp[0][1], dyn.vp[0][2], dyn.vp[0][3], dyn.has_sc, dyn.sc[0], dyn.sc[1], dyn.sc[2], dyn.sc[3], (int)rp_S.ds.dt, (int)rp_S.ds.st, (unsigned)rp_S.poly.cull, (unsigned)rp_S.poly.front, tl);
        nvn_plat_log(NVN_PLAT_LOG_INFO, "draw", b);
    }
    rp_pso_dirty = rp_dss_dirty = 0; memset(rp_args_dirty, 0, sizeof rp_args_dirty);
    g_draws++;
}

void rp_draw_stats(uint64_t *draws, uint64_t *skips) { if (draws) *draws = g_draws; if (skips) *skips = g_skips; }
void rp_draw_reset(void) { g_prog = NULL; g_pipe = NULL; g_pipe_cmd = NULL; g_draws = g_skips = 0; g_prim = ~0u; }
