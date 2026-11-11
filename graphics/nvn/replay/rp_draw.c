// 绘制（对齐 nvn_mtl.m draw / draw_emit @12900 一带与 encode_args_ @9640 的职责）：
// 状态类命令早已落在 rp_S 里，这里在绘制时把它们变成后端的管线、动态状态、顶点流和绑定，再发绘制。
// 没改过的不重发：管线看 rp_pso_dirty，各阶段绑定看 rp_args_dirty[阶段]。
// 四边形图元（NVN 7）没有原生对应：在这里展开成三角形列表的 32 位索引（每个四边形 0,1,2 / 0,2,3，同 nvn_mtl.m fanquad_expand），按带索引的三角形画。
// 还没接：间接绘制、间接计数多绘、变换反馈、线环 / 四边形带、图元重启以外的小状态、存储缓冲与图像绑定、空槽假贴图。
#include "rp_exec.h"
#include "rp_state.h"
#include "rp_res.h"
#include "rp_shader.h"
#include "nvn_unimpl.h"
#include "nvn_plat.h"
#include "nvn_refl.h"
#include "nvn_fmt_info.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// SupportBuffer 里现在要填的字段（翻译器产物的布局；其余保持 0）
enum { SB_RENDER_SCALE = 192, SB_S2A_FLAGS = 1392, SB_S2A_POINT = 1408, SB_RENDER_SCALE_Y = 1440, SB_RENDER_SCALE_COUNT = 73 };
// 驱动常量段 c0 的合成布局（着色器从它读存储缓冲描述符表、最大点径、base instance）
enum { DRV0_BYTES = 0xA00 };
static const int k_drv0_base[5] = {0x110, 0x510, 0x410, 0x210, 0x310};   // 各图形阶段的存储缓冲表起点

int rp_pool_find(uint64_t addr, uint64_t len, const uint8_t **mem, uint64_t *size);   // rp_entry.c
extern int s2a_nvn_rast_flip;   // hle_nvn.c：当前提交队列的正面光栅翻转位（建队列时按窗口原点定）

static const struct rp_prog *g_prog; static nvn_gpu_pipe g_pipe; static nvn_gpu_cmd g_pipe_cmd;
static uint64_t g_draws, g_skips; static uint32_t g_prim = ~0u; static int g_quads = -1, g_face = -1;

// 四边形 → 三角形索引。src NULL = 不带索引（顶点自己，0 起；first 由调用方放进 base vertex）；否则是 isz 字节一个的索引。
// rv >= 0：图元重启值，每遇到一个就另起一串四边形，前一串不足一个四边形的零头丢掉。返回写出的索引个数（d 至少要 count / 4 * 6 个）
static uint32_t quad_expand(const uint8_t *src, uint32_t isz, uint32_t count, int64_t rv, uint32_t *d) {
#define IX(i) (!src ? (uint32_t)(i) : isz == 1 ? src[i] : isz == 2 ? (uint32_t)(src[(size_t)(i) * 2] | src[(size_t)(i) * 2 + 1] << 8) : \
               ((uint32_t)src[(size_t)(i) * 4] | (uint32_t)src[(size_t)(i) * 4 + 1] << 8 | (uint32_t)src[(size_t)(i) * 4 + 2] << 16 | (uint32_t)src[(size_t)(i) * 4 + 3] << 24))
    uint32_t o = 0;
    for (uint32_t s = 0; s < count;) {
        uint32_t e = s; if (src && rv >= 0) { while (e < count && IX(e) != (uint32_t)rv) e++; } else e = count;
        for (uint32_t q = s; q + 4 <= e; q += 4) {
            d[o++] = IX(q); d[o++] = IX(q + 1); d[o++] = IX(q + 2);
            d[o++] = IX(q); d[o++] = IX(q + 2); d[o++] = IX(q + 3);
        }
        s = e + 1;
    }
#undef IX
    return o;
}

// 贴图数组（着色器按运行时下标取句柄）的各项：每个阶段至多一个数组，至多 RP_TEXARR_MAX 项。
// 数组第 k 项 = 驱动句柄表的第 k 个 8 字节项；贴图槽 s 的句柄在第 4 + s 项，前 4 项与没绑的槽读作池里的第 0 项（同单个贴图槽没绑时的口径）
enum { RP_TEXARR_MAX = 64, RP_HANDLE_TABLE_FIRST_SLOT = 4 };
static nvn_gpu_view g_av[RP_PROG_STAGES][RP_TEXARR_MAX]; static nvn_gpu_samp g_as[RP_PROG_STAGES][RP_TEXARR_MAX];

static int alloc_copy(nvn_gpu_cmd c, uint64_t n, const void *src, nvn_gpu_slice *sl) {
    nvn_gpu_caps caps; nvn_gpu_caps_get(&caps);
    nvn_gpu_err err = {0};
    if (!nvn_gpu_ok(nvn_gpu_arena_alloc(c, n, caps.min_ubo_align ? caps.min_ubo_align : 256, sl, &err)) || !sl->cpu) return 0;
    if (src) memcpy(sl->cpu, src, (size_t)n); else memset(sl->cpu, 0, (size_t)n);
    return 1;
}

// 调试读回用的绘制历史（见文件后部 dump_chain）
enum { HIST_N = 4096, HIST_TEX = 6, DUMP_MAX = 28 };
static struct { uint64_t target, tex[HIST_TEX]; } g_hist[HIST_N]; static uint32_t g_hist_n;
static void hist_note(uint64_t target, const uint64_t *tex, int ntex) {
    uint32_t i = g_hist_n++ % HIST_N; g_hist[i].target = target; memset(g_hist[i].tex, 0, sizeof g_hist[i].tex);
    for (int k = 0; k < ntex && k < HIST_TEX; k++) g_hist[i].tex[k] = tex[k];
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
            case NVN_RB_DRV2: {   // 驱动的贴图句柄表：贴图槽 s 的句柄（贴图号 | 采样器号 << 20）在第 4 + s 个 8 字节项
                enum { DRV2_BYTES = (RP_HANDLE_TABLE_FIRST_SLOT + 32) * 8 };
                if (!alloc_copy(c, DRV2_BYTES, NULL, &sl)) return skip("arena_alloc_failed", rec);
                for (int s = 0; s < 32; s++) { uint64_t h = rp_S.tex[st][s]; memcpy(sl.cpu + (RP_HANDLE_TABLE_FIRST_SLOT + s) * 8, &h, 8); }
                o->u.b.buf = sl.buf; o->u.b.off = sl.off; o->u.b.len = DRV2_BYTES; break; }
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
                if (e->count > 1) {   // 贴图数组：逐项绑（视图与采样器已在开通道前取好，放在 g_av / g_as）
                    if (n + e->count > RP_PROG_ENT_MAX) return skip("too_many_bindings", rec);
                    for (uint32_t k = 0; k < e->count; k++) {
                        if (!g_av[st][k]) return skip("texture_slot_unresolved", rec);
                        if (!g_as[st][k]) return skip("sampler_slot_unresolved", rec);
                        nvn_gpu_binding *ok = &b[n + k]; memset(ok, 0, sizeof *ok); ok->ent = (uint16_t)i; ok->cls = e->cls; ok->elem = k;
                        ok->u.ts.view = g_av[st][k]; ok->u.ts.samp = g_as[st][k];
                    }
                    n += e->count - 1;   // 循环末尾再加 1
                    break;
                }
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

// 绘制时的动态状态（对照 nvn_mtl.m @12740–12776）。返回 0 = 裁剪矩形与目标没有交集：这笔什么都画不出，不发（iOS 同样跳过，不算未接）
static int fill_dyn(nvn_gpu_dyn *d, uint32_t tw, uint32_t th, const void *rec) {
    memset(d, 0, sizeof *d);
    d->nvp = 1;
    if (rp_S.has_vp) { memcpy(d->vp[0], rp_S.vp[0], 16); } else { d->vp[0][2] = (float)tw; d->vp[0][3] = (float)th; }
    d->vp[0][4] = rp_S.dr[0]; d->vp[0][5] = rp_S.dr[1];
    // 视口重排：只认「y 取反」（等于视口上下翻，正面判定在它之后做，绕序状态不用动）；其余重排照没重排画，记一笔
    { uint32_t sw; memcpy(&sw, rp_S.vp_sw[0], 4);
      if (sw == 0x100) { d->vp[0][1] += d->vp[0][3]; d->vp[0][3] = -d->vp[0][3]; }
      else if (sw) nvn_unimpl("gpu", "viewport_swizzle", rec); }
    // 裁剪矩形夹到目标范围内（原生接口不收负的起点；宽高是游戏给的任意数）
    if (rp_R.has_sc) {
        int64_t x0 = rp_R.sc.x < 0 ? 0 : rp_R.sc.x, y0 = rp_R.sc.y < 0 ? 0 : rp_R.sc.y, x1 = (int64_t)rp_R.sc.x + rp_R.sc.w, y1 = (int64_t)rp_R.sc.y + rp_R.sc.h;
        if (x1 > (int64_t)tw) x1 = tw;
        if (y1 > (int64_t)th) y1 = th;
        if (x1 <= x0 || y1 <= y0) return 0;
        d->has_sc = 1; d->sc[0] = (int32_t)x0; d->sc[1] = (int32_t)y0; d->sc[2] = (int32_t)(x1 - x0); d->sc[3] = (int32_t)(y1 - y0);
    }
    d->origin_ll = (uint8_t)rp_origin_lower_left(); d->depth_clamp = (uint8_t)(rp_S.depth_clamp != 0);
    d->po = rp_S.po;
    memcpy(d->st_vmask, rp_S.st_vmask, sizeof d->st_vmask); memcpy(d->st_wmask, rp_S.st_wmask, sizeof d->st_wmask); memcpy(d->st_ref, rp_S.st_ref, sizeof d->st_ref);
    memcpy(d->blend_color, rp_S.blend_color, sizeof d->blend_color);
    d->ds = rp_S.ds; d->poly = rp_S.poly;
    return 1;
}

// OP_DRAW / OP_DRAW_IDX 共用。di 非空 = 带索引
void rp_draw(nvn_gpu_cmd c, const p_draw *dr, const p_draw_idx *di, const void *rec) {
    if (!c) return;
    uint32_t prim = (uint32_t)(di ? di->prim : dr->prim);
    if ((di && (di->ind || di->mdi_cnt)) || (dr && (dr->ind || dr->mdi_cnt))) { skip("indirect", rec); return; }
    if (dr && dr->tfc) { skip("transform_feedback_count", rec); return; }
    if (rp_S.tf_on) { skip("transform_feedback_active", rec); return; }
    if (!(prim == 0 || prim == 1 || prim == 3 || prim == 4 || prim == 5 || prim == 6 || prim == 7)) { char nm[24]; snprintf(nm, sizeof nm, "prim_%u", prim); skip(nm, rec); return; }
    int quads = prim == 7; if (quads) prim = 4;   // 四边形：下面一律按三角形列表走，索引在取资源那一步展开
    uint32_t count = (uint32_t)(di ? di->count : dr->count);
    if (!count) return;
    const p_set_rt *rt = rp_pass_target();
    if (!rt) { skip("draw_without_target", rec); return; }
    // 程序：管线状态或任一阶段的绑定变过才重新取（贴图槽里换了不同类型的贴图会换变体）
    if (prim != g_prim || quads != g_quads) { g_prim = prim; g_quads = quads; rp_pso_dirty = 1; }
    { int face = (rp_origin_lower_left() != 0) | (s2a_nvn_rast_flip != 0) << 1;   // 窗口原点与光栅翻转位不在状态块里，但进管线描述（正面绕序）：变了就是换管线
      if (face != g_face) { g_face = face; rp_pso_dirty = 1; } }   // 图元在绘制记录里，不在状态块里：换了图元就是换管线
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
    if (di && (di->itype < 0 || di->itype > 2)) { skip("index_type_invalid", rec); return; }
    if (quads) {
        uint32_t isz = di ? (di->itype == 0 ? 1 : di->itype == 1 ? 2 : 4) : 0;
        if (count / 4 == 0) return;   // 不足一个四边形：什么都不画
        // 带索引：游戏的索引在登记过的池里，编码这一刻读出来展开（同常量缓冲：就是此刻的内容）
        if (di && !rp_pool_find(di->ibuf, (uint64_t)count * isz, NULL, NULL)) { skip("index_buffer_unresolved", rec); return; }
        nvn_gpu_slice sl; nvn_gpu_err err = {0};
        if (!nvn_gpu_ok(nvn_gpu_arena_alloc(c, (uint64_t)(count / 4) * 6 * 4, 4, &sl, &err)) || !sl.cpu) { skip("arena_alloc_failed", rec); return; }
        uint32_t n = quad_expand(di ? (const uint8_t *)(uintptr_t)di->ibuf : NULL, isz, count, di && rp_S.restart.on ? (int64_t)rp_S.restart.index : -1, (uint32_t *)(void *)sl.cpu);
        if (!n) return;
        a.ibuf = sl.buf; a.ioff = sl.off; a.itype = 2; a.base_vertex = di ? di->base_vertex : dr->first; count = n;
    } else if (di) {
        uint32_t isz = di->itype == 0 ? 1 : di->itype == 1 ? 2 : 4;
        if (!rp_buf_resolve(c, di->ibuf, (uint64_t)count * isz, &a.ibuf, &a.ioff)) { skip("index_buffer_unresolved", rec); return; }
        a.itype = (uint32_t)di->itype; a.base_vertex = di->base_vertex;
    } else a.first = (uint32_t)dr->first;
    static nvn_gpu_view tv[RP_PROG_STAGES][RP_PROG_ENT_MAX]; static nvn_gpu_samp ts[RP_PROG_STAGES][RP_PROG_ENT_MAX];
    char tl[160]; size_t tn = 0; tl[0] = 0;   // 逐笔日志用：这笔采样的贴图
    int narr[RP_PROG_STAGES] = {0, 0};
    for (int st = 0; st < 2; st++) for (uint32_t i = 0; i < g_prog->nent[st]; i++) {
        const nvn_gpu_layout_ent *e = &g_prog->ent[st][i]; tv[st][i] = NULL; ts[st][i] = NULL;
        if (e->src_kind != NVN_RB_TEX) continue;
        if (e->count > 1) {
            if (e->count > RP_TEXARR_MAX || narr[st]++) { skip("texture_array_unsupported_shape", rec); return; }
            for (uint32_t k = 0; k < e->count; k++) {
                int slot = (int)(e->src_reg + k) - RP_HANDLE_TABLE_FIRST_SLOT;
                uint64_t hk = slot >= 0 && slot < 32 ? rp_S.tex[st][slot] : 0;
                g_av[st][k] = rp_view_by_id(hk ? (int)(hk & 0xFFFFF) : rp_S.tex_base, c, NULL);
                g_as[st][k] = rp_samp_by_id(hk ? (int)(hk >> 20) : rp_S.samp_base);
            }
            // 取不到的项（没绑的槽、池里第 0 项不是贴图）拿数组里第一个取到的顶上：描述符数组每一项都必须是有效的，
            // 而着色器只会按游戏绑过的槽去取，顶上的这些项不会被采样。一项都取不到才算这笔取不到贴图（绑定时报）。
            { nvn_gpu_view fv = NULL; nvn_gpu_samp fs = NULL;
              for (uint32_t k = 0; k < e->count && !(fv && fs); k++) { if (!fv) fv = g_av[st][k]; if (!fs) fs = g_as[st][k]; }
              for (uint32_t k = 0; k < e->count; k++) { if (!g_av[st][k]) g_av[st][k] = fv; if (!g_as[st][k]) g_as[st][k] = fs; } }
            continue;
        }
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
    if (rp_S.poly.mode != NVN_POLYGON_MODE_FILL) nvn_unimpl("gpu", "polygon_mode_not_fill", rec);   // 点 / 线填充模式（连同它们的深度偏移位）：后端只建填充模式的管线，照画，记一笔
    if (rp_pso_dirty || !g_pipe || g_pipe_cmd != c) {
        nvn_gpu_pipe_desc pd; memset(&pd, 0, sizeof pd);
        pd.st[0].sh = g_prog->sh[0]; pd.st[1].sh = g_prog->sh[1];
        for (int i = 0; i < rt->n && i < 8; i++) { pd.cfmt[i] = rt->color[i] && rp_pass_slot_attached(i) ? (uint32_t)(rt->has_cview[i] && rt->cview[i].set_format ? rt->cview[i].format : rt->color[i]->d.format) : 0; pd.lmap[i] = (uint8_t)i; }
        if (rt->depth) { nvn_fmt_info fi; uint32_t f = (uint32_t)rt->depth->d.format; int ok = nvn_fmt_info_of(f, &fi); if (!ok || fi.depth) pd.dfmt = f; if (ok && fi.stencil) pd.sfmt = f; }
        const tex_t *c0 = NULL; for (int i = 0; i < rt->n && i < 8 && !c0; i++) c0 = rt->color[i];   // 第一个有图的颜色槽
        pd.samples = c0 ? (uint32_t)c0->d.samples : rt->depth ? (uint32_t)rt->depth->d.samples : 0;
        pd.prim = prim; pd.patch_size = (uint32_t)rp_S.patch_size; pd.prim_restart = (uint8_t)(rp_S.restart.on != 0 && !quads);   // 四边形的重启在展开时已经处理掉
        memcpy(pd.blend, rp_S.blend, sizeof pd.blend); pd.color = rp_S.color; pd.chmask = rp_S.chmask; pd.ms = rp_S.ms;
        // 归一化（对照 nvn_mtl.m pso_key_norm / pso_desc，docs/对照_iOS回放层语义.md 第 1 段）：
        //   · 片元着色器没写的输出分量不落帧缓冲：写掩码与着色器的输出映射相与（硬件只写着色器输出表里的；宿主上没写的输出是未定义值）；
        //   · 一个分量都不写的目标、没有图的槽：不混合；高级混合位只为查询保真，不进管线。
        pd.chmask.mask &= g_prog->color_out_mask;
        for (int i = 0; i < 8; i++) {
            if (!pd.cfmt[i] || !(pd.chmask.mask >> (4 * i) & 0xf)) { pd.chmask.mask &= ~(0xfu << (4 * i)); pd.color.blend_en &= (uint8_t)~(1u << i); memset(&pd.blend[i], 0, sizeof pd.blend[i]); continue; }
            pd.blend[i].adv_mode = 0; pd.blend[i].adv_overlap = 0; pd.blend[i].adv_premul = 0; pd.blend[i].adv_normdst = 0;
        }
        { static int fm = -1; if (fm < 0) fm = nvn_plat_flag("nvk_fullmask", 0); if (fm) pd.chmask.mask = 0xffffffffu; }   // 临时实验：颜色写掩码一律全开
        for (int i = 0; i < rp_S.nattr && i < 16; i++) pd.attr[i] = rp_S.attr[i];
        for (int i = 0; i < rp_S.nstream && i < 16; i++) pd.stream[i] = rp_S.stream[i];
        pd.ds = rp_S.ds; pd.poly = rp_S.poly; pd.rast_discard = (uint8_t)(rp_S.rast_discard != 0);
        // 正面绕序（对照 nvn_mtl.m @12766）：游戏自带驱动只在建队列时按当时的窗口原点写一次「光栅翻转」位（原点不是左上 = 开），
        // 之后改原点不再动它。y 朝上的规范化设备坐标里：翻转开着时正面是接口值的反面，关着时就是接口值。
        // 后端再按它翻不翻视口换成自己的帧缓冲绕序，所以窗口原点一并给它。
        pd.poly.front = ((rp_S.poly.front == NVN_FRONT_FACE_CCW) != (s2a_nvn_rast_flip != 0)) ? NVN_FRONT_FACE_CCW : NVN_FRONT_FACE_CW;
        pd.origin_ll = (uint8_t)(rp_origin_lower_left() != 0);
        pd.depth_clamp = (uint8_t)(rp_S.depth_clamp != 0);
        nvn_gpu_pipe np = NULL; nvn_gpu_err err = {0};
        nvn_gpu_rc r = nvn_gpu_pipe_get(&pd, NVN_GPU_PIPE_SYNC, &np, &err);
        if (!nvn_gpu_ok(r)) { if (nvn_unimpl("gpu", "pipe_get", rec) == 1) nvn_plat_log(NVN_PLAT_LOG_RED, "gpu", err.why); g_skips++; g_pipe = NULL; return; }
        g_pipe = np; g_pipe_cmd = c;
        nvn_gpu_set_pipe(c, g_pipe);
        rp_args_dirty[0] = rp_args_dirty[1] = 1;   // 换了管线：两个阶段的绑定都重发
    }
    uint32_t tw = 1, th = 1;
    { int fi = -1; for (int i = 0; i < rt->n && i < 8 && fi < 0; i++) if (rt->color[i]) fi = i;   // 缺省视口的尺寸：第一个有图的颜色槽，没有就取深度目标
      if (fi >= 0) { uint32_t l = rt->has_cview[fi] && rt->cview[fi].set_levels ? rt->cview[fi].base_level : 0; tw = rt->color[fi]->d.width >> l; th = rt->color[fi]->d.height >> l; }
      else if (rt->depth) { uint32_t l = rt->has_dview && rt->dview.set_levels ? rt->dview.base_level : 0; tw = rt->depth->d.width >> l; th = rt->depth->d.height >> l; }
      if (!tw) tw = 1;
      if (!th) th = 1; }
    nvn_gpu_dyn dyn; if (!fill_dyn(&dyn, tw, th, rec)) return;
    nvn_gpu_set_dyn(c, &dyn);
    for (int i = 0; i < 16; i++) if (streams >> i & 1) nvn_gpu_set_vbuf(c, (uint32_t)i, vb_buf[i], vb_off[i]);
    uint32_t base_instance = (uint32_t)(di ? di->base_instance : dr->base_instance);
    for (int st = 0; st < 2; st++) if (!bind_stage(c, g_prog, st, base_instance, tv[st], ts[st], rec)) return;   // 首版每笔都整组重发（support / c0 每笔在暂存区里新建）；按脏位省重发是后面的事
    a.prim = prim; a.count = count; a.instances = (uint32_t)(di ? di->instances : dr->instances); if (!a.instances) a.instances = 1; a.base_instance = base_instance;
    nvn_gpu_draw(c, &a);
    if (g_log_left) {
        g_log_left--;
        char b[480]; const blend_st *bl = &rp_S.blend[0];
        snprintf(b, sizeof b, "第 %llu 笔：图元 %u 数 %u 实例 %u%s 目标 #%llu %ux%u 格式 %#x 视图格式 %#x 颜色槽 %d 程序 %02x%02x/%02x%02x 混合 开%#x 源%u 目%u 掩码 %#x 视口 %.0f,%.0f %.0fx%.0f 裁剪 %d(%d,%d %dx%d) 深度测 %d 模板 %d 剔除 %u 正面 %u%s",
                 (unsigned long long)g_draws, prim, count, a.instances, di ? " 带索引" : "", (unsigned long long)(rt->n && rt->color[0] ? rt->color[0]->serial : rt->depth ? rt->depth->serial : 0), tw, th, (unsigned)(rt->n && rt->color[0] ? rt->color[0]->d.format : 0), (unsigned)(rt->n && rt->color[0] && rt->has_cview[0] && rt->cview[0].set_format ? rt->cview[0].format : 0), rt->n,
                 rp_S.skey[0][0], rp_S.skey[0][1], rp_S.skey[1][0], rp_S.skey[1][1], (unsigned)rp_S.color.blend_en, (unsigned)bl->src_rgb, (unsigned)bl->dst_rgb, (unsigned)rp_S.chmask.mask,
                 dyn.vp[0][0], dyn.vp[0][1], dyn.vp[0][2], dyn.vp[0][3], dyn.has_sc, dyn.sc[0], dyn.sc[1], dyn.sc[2], dyn.sc[3], (int)rp_S.ds.dt, (int)rp_S.ds.st, (unsigned)rp_S.poly.cull, (unsigned)rp_S.poly.front, tl);
        nvn_plat_log(NVN_PLAT_LOG_INFO, "draw", b);
        // 片元阶段各常量缓冲的地址、长度与第 9 / 10 / 15 个四元组（调试取证：对照着色器里读的位置看内容对不对）
        for (int r = 0; r < 4; r++) { const p_bind_buf *ub = &rp_S.ubo[1][r]; if (!ub->addr || ub->size < 256 || !rp_pool_find(ub->addr, ub->size, NULL, NULL)) continue;
            const float *f = (const float *)(uintptr_t)ub->addr;
            snprintf(b, sizeof b, "  片元常量缓冲 %d：地址 %#llx 长 %llu [9]=%.3g,%.3g,%.3g,%.3g [10]=%.3g,%.3g,%.3g,%.3g [15]=%.3g,%.3g,%.3g,%.3g", r, (unsigned long long)ub->addr, (unsigned long long)ub->size,
                     (double)f[36], (double)f[37], (double)f[38], (double)f[39], (double)f[40], (double)f[41], (double)f[42], (double)f[43], (double)f[60], (double)f[61], (double)f[62], (double)f[63]);
            nvn_plat_log(NVN_PLAT_LOG_INFO, "draw", b); }
    }
    { uint64_t ts4[HIST_TEX]; int nt = 0;
      for (int st = 0; st < 2; st++) for (uint32_t i = 0; i < g_prog->nent[st] && nt < HIST_TEX; i++) { const nvn_gpu_layout_ent *e = &g_prog->ent[st][i];
          if (e->src_kind != NVN_RB_TEX || e->count > 1) continue;
          uint64_t h = rp_S.tex[st][e->src_reg]; tex_t snap; view_t sv; int hv;
          if (rp_tex_snap_by_id(h ? (int)(h & 0xFFFFF) : rp_S.tex_base, &snap, &sv, &hv)) ts4[nt++] = snap.serial; }
      hist_note(rt->n && rt->color[0] ? rt->color[0]->serial : rt->depth ? rt->depth->serial : 0, ts4, nt); }
    rp_pso_dirty = rp_dss_dirty = 0; memset(rp_args_dirty, 0, sizeof rp_args_dirty);
    g_draws++;
}

// ---------- 调试：把「上屏那张图」和它上游几层的贴图读回落盘（开关 nvk_dump；rp_present 每 600 帧调一次） ----------
// 每笔绘制记下目标序号和它采样的头几张贴图序号；从上屏的那张图往回走：画到它的那些笔采样了谁，再往上，至多 3 层、12 张。
// 每张读第 0 级第 0 层的原始字节，写到缓存目录（没有就写诊断目录）的 nvkdump_<帧>_<层>_<序号>_<宽>x<高>_<格式>.raw。
struct dump_job { nvn_gpu_buf buf; uint64_t bytes; char path[300]; };
static void dump_done(void *user, const nvn_gpu_done *d) {
    struct dump_job *j = user;
    if (d->status != NVN_GPU_DONE_FAILED) { FILE *f = fopen(j->path, "wb"); if (f) { fwrite(nvn_gpu_buf_cpu(j->buf), 1, (size_t)j->bytes, f); fclose(f); nvn_plat_log(NVN_PLAT_LOG_INFO, "dump", j->path); } }
    nvn_gpu_buf_release(j->buf, NULL, NULL); free(j);
}
// 上屏线程只登记「要读回」；真正的读回在提交线程上、一次提交收尾时做（时间线的值只有提交线程能发）
static uint64_t g_dump_serial, g_dump_frame;
void rp_debug_dump_request(uint64_t present_serial, uint64_t frame) { __atomic_store_n(&g_dump_frame, frame, __ATOMIC_RELEASE); __atomic_store_n(&g_dump_serial, present_serial, __ATOMIC_RELEASE); }
static void dump_chain(uint64_t present_serial, uint64_t frame, uint64_t *fence);
void rp_debug_dump_poll(uint64_t *fence) {
    uint64_t s = __atomic_exchange_n(&g_dump_serial, 0, __ATOMIC_ACQ_REL);
    if (s) dump_chain(s, __atomic_load_n(&g_dump_frame, __ATOMIC_ACQUIRE), fence);
}
static void dump_chain(uint64_t present_serial, uint64_t frame, uint64_t *fence) {
    // 先用缓存目录：安卓上它在应用私有区，调试包可以用 run-as 取出来；诊断目录在外部存储的应用目录里，新系统上 adb 读不到
    const char *dir = nvn_plat_dir(NVN_PLAT_DIR_CACHE); if (!dir) dir = nvn_plat_dir(NVN_PLAT_DIR_DIAG);
    if (!dir) { nvn_plat_log(NVN_PLAT_LOG_WARN, "dump", "没有可写目录，不落盘"); return; }
    uint64_t list[DUMP_MAX]; int depth[DUMP_MAX], n = 0; list[n] = present_serial; depth[n++] = 0;
    uint32_t have = g_hist_n < HIST_N ? g_hist_n : HIST_N;
    for (int i = 0; i < n && n < DUMP_MAX; i++) {
        if (depth[i] >= 6) continue;
        for (uint32_t h = 0; h < have && n < DUMP_MAX; h++) { if (g_hist[h].target != list[i]) continue;
            for (int k = 0; k < HIST_TEX && n < DUMP_MAX; k++) { uint64_t s = g_hist[h].tex[k]; if (!s) continue;
                int seen = 0; for (int q = 0; q < n; q++) if (list[q] == s) seen = 1;
                if (!seen) { list[n] = s; depth[n++] = depth[i] + 1; } } }
    }
    for (int i = 0; i < n; i++) {
        nvn_gpu_tex g = rp_tex_backend_by_serial(list[i]); if (!g) continue;
        nvn_gpu_tex_info ti; nvn_gpu_tex_info_get(g, &ti);
        int bw = 1, bh = 1, bpb = nvn_fmt_bpb((int)ti.nvn_format, &bw, &bh);
        if (!bpb || bw != 1 || bh != 1 || !ti.w || !ti.h || ti.samples > 1 || ti.depth > 1) continue;   // 只读回不压缩的二维贴图：读回失败的段会让时间线进失败终态
        uint64_t row = (uint64_t)((ti.w + (uint32_t)bw - 1) / (uint32_t)bw) * (uint64_t)bpb, bytes = row * ((ti.h + (uint32_t)bh - 1) / (uint32_t)bh);
        struct dump_job *j = calloc(1, sizeof *j); nvn_gpu_err err = {0}; nvn_gpu_cmd c = NULL; nvn_gpu_cmd_desc cd = {0, "nvk dump"};
        if (!j || !nvn_gpu_ok(nvn_gpu_buf_create(bytes, NVN_GPU_MEM_SHARED, NULL, &j->buf, &err)) || !nvn_gpu_ok(nvn_gpu_cmd_begin(&cd, &c, &err))) { if (j && j->buf) nvn_gpu_buf_release(j->buf, NULL, NULL); free(j); continue; }
        j->bytes = bytes; snprintf(j->path, sizeof j->path, "%s/nvkdump_%llu_%d_%llu_%ux%u_%#x.raw", dir, (unsigned long long)frame, depth[i], (unsigned long long)list[i], ti.w, ti.h, ti.nvn_format);
        nvn_gpu_copy_tex_buf(c, g, 0, 0, NULL, j->buf, 0, row, bytes);
        *fence += 1;
        nvn_gpu_rc cr = nvn_gpu_cmd_commit(c, *fence, dump_done, j, &err);
        if (!nvn_gpu_ok(cr)) { char m[260]; snprintf(m, sizeof m, "读回 #%llu（%ux%u 格式 %#x）提交失败 %d：%s", (unsigned long long)list[i], ti.w, ti.h, ti.nvn_format, cr.code, err.why); nvn_plat_log(NVN_PLAT_LOG_RED, "dump", m); }
    }
}

void rp_draw_stats(uint64_t *draws, uint64_t *skips) { if (draws) *draws = g_draws; if (skips) *skips = g_skips; }
void rp_draw_reset(void) { g_prog = NULL; g_pipe = NULL; g_pipe_cmd = NULL; g_draws = g_skips = 0; g_prim = ~0u; g_quads = -1; g_face = -1; }
