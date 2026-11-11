// 回放核心（graphics/nvn/replay）的宿主单测：纯 C，后端与平台件都是本文件里的替身，不需要 GPU。
// 期望值都由用例自己写下的输入直接得出，不经被测实现计算。
#include "nvn_obj.h"
#include "nvn2_cmd.h"
#include "nvn_backend.h"
#include "nvn_mtl.h"
#include "../replay/rp_state.h"
#include "../replay/rp_exec.h"
#include "../replay/rp_res.h"
#include "nvn_dirty.h"
#include "nvn_deswizzle.h"
#include "../replay/nvn_unimpl.h"
#include "../replay/nvn_plat.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int g_fail, g_checks;
#define CHECK(c) do { g_checks++; if (!(c)) { g_fail++; printf("【红】 %s:%d  %s\n", __FILE__, __LINE__, #c); } } while (0)

// ---------- 平台替身 ----------
static int g_red_lines; static char g_last_red[200];
void nvn_plat_log(int level, const char *cls, const char *text) { (void)cls; if (level == NVN_PLAT_LOG_RED) { g_red_lines++; snprintf(g_last_red, sizeof g_last_red, "%s", text); } }
int nvn_plat_flag(const char *name, int dflt) { (void)name; return dflt; }
const char *nvn_plat_dir(int which) { (void)which; return NULL; }

// ---------- 前端替身 ----------
static int g_q_enter, g_piece;
void nvn_hle_queue_enter(void *q) { (void)q; g_q_enter++; }
void nvn_hle_piece_begun(void) { g_piece++; }
int nvn_dpool_base(const void *pool, int tex) { return (int)(uintptr_t)pool + (tex ? 0 : 1000); }
const prog_t *nvn_prog_snap_get(uint64_t serial, uint8_t keys[6][8], uint8_t *ok, uint8_t stage[6]) { (void)serial; (void)keys; (void)ok; (void)stage; return NULL; }   // 宿主表里没有快照
int dm_fps_setting(void) { return 30; }
uint64_t nvn_ga2ca(uint64_t a) { return a + 0x1000; }   // 与恒等不同：证明延后绑定确实做了地址换算

// ---------- 后端替身：段只记账；完成由用例手动触发 ----------
struct nvn_gpu_cmd_s { int live; };
static struct nvn_gpu_cmd_s g_fake_cmd;
static int g_begins, g_commits;
static struct { nvn_gpu_done_fn fn; void *user; uint64_t signal; } g_pend[8]; static int g_npend;
static uint64_t g_fdone;
nvn_gpu_rc nvn_gpu_cmd_begin(const nvn_gpu_cmd_desc *d, nvn_gpu_cmd *out, nvn_gpu_err *err) { (void)d; (void)err; g_begins++; g_fake_cmd.live = 1; *out = &g_fake_cmd; return (nvn_gpu_rc){NVN_GPU_OK}; }
nvn_gpu_rc nvn_gpu_cmd_commit(nvn_gpu_cmd c, uint64_t signal, nvn_gpu_done_fn done, void *user, nvn_gpu_err *err) {
    (void)err; c->live = 0; g_commits++; g_pend[g_npend].fn = done; g_pend[g_npend].user = user; g_pend[g_npend].signal = signal; g_npend++; return (nvn_gpu_rc){NVN_GPU_OK}; }
nvn_gpu_rc nvn_gpu_fence_wait(uint64_t v, uint64_t timeout_ns, nvn_gpu_err *err) { (void)timeout_ns; (void)err; return (nvn_gpu_rc){v <= g_fdone ? NVN_GPU_OK : NVN_GPU_E_TIMEOUT}; }
// 贴图 / 视图 / 采样器 / 上传：只记账
struct nvn_gpu_tex_s { nvn_gpu_tex_desc d; }; struct nvn_gpu_view_s { nvn_gpu_tex of; int has_v; }; struct nvn_gpu_samp_s { int x; };
static int g_tex_creates, g_tex_releases, g_view_creates, g_view_releases, g_samp_creates, g_samp_releases, g_tex_create_fail;
static uint32_t g_last_usage; static uint16_t g_last_swz;
static struct { uint32_t level, layer; uint64_t pitch, img; int w, h; uint8_t first[64]; } g_up[16]; static int g_nup;
nvn_gpu_rc nvn_gpu_tex_create(const nvn_gpu_tex_desc *d, nvn_gpu_tex *out, nvn_gpu_err *err) {
    if (g_tex_create_fail) { snprintf(err->why, sizeof err->why, "替身：不支持"); *out = NULL; return (nvn_gpu_rc){NVN_GPU_E_UNSUPPORTED}; }
    g_tex_creates++; g_last_usage = d->usage; g_last_swz = d->swz; *out = calloc(1, sizeof **out); (*out)->d = *d; return (nvn_gpu_rc){NVN_GPU_OK}; }
void nvn_gpu_tex_release(nvn_gpu_tex t) { g_tex_releases++; free(t); }
nvn_gpu_rc nvn_gpu_view_create(nvn_gpu_tex t, const view_t *v, nvn_gpu_view *out, nvn_gpu_err *err) { (void)err; g_view_creates++; *out = calloc(1, sizeof **out); (*out)->of = t; (*out)->has_v = v != NULL; return (nvn_gpu_rc){NVN_GPU_OK}; }
void nvn_gpu_view_release(nvn_gpu_view v) { g_view_releases++; free(v); }
nvn_gpu_rc nvn_gpu_samp_create(const samp_par *p, nvn_gpu_samp *out, nvn_gpu_err *err) { (void)p; (void)err; g_samp_creates++; *out = calloc(1, sizeof **out); return (nvn_gpu_rc){NVN_GPU_OK}; }
void nvn_gpu_samp_release(nvn_gpu_samp s) { g_samp_releases++; free(s); }
uint32_t nvn_gpu_format_caps(uint32_t f) { return f == NVN_FORMAT_RGBA8 ? NVN_GPU_FMT_SAMPLE | NVN_GPU_FMT_RENDER | NVN_GPU_FMT_STORAGE : NVN_GPU_FMT_SAMPLE; }
void nvn_gpu_tex_upload(nvn_gpu_cmd c, nvn_gpu_tex t, uint32_t level, uint32_t layer, const NVNcopyRegion *r, const void *src, uint64_t row_bytes, uint64_t image_bytes) {
    (void)c; (void)t; if (g_nup == 16) return;
    g_up[g_nup].level = level; g_up[g_nup].layer = layer; g_up[g_nup].pitch = row_bytes; g_up[g_nup].img = image_bytes; g_up[g_nup].w = r->width; g_up[g_nup].h = r->height;
    memcpy(g_up[g_nup].first, src, image_bytes < 64 ? image_bytes : 64); g_nup++; }
// 脏页替身：代号由用例推进
static uint64_t g_dirty_now = 100, g_dirty_written; static int g_protects;
void nvn_dirty_protect(const void *addr, size_t len) { (void)addr; (void)len; g_protects++; }
uint64_t nvn_dirty_now(void) { return g_dirty_now; }
int nvn_dirty_since(const void *addr, size_t len, uint64_t stamp) { (void)addr; (void)len; return g_dirty_written > stamp; }

// 缓冲替身：记每次按 GPU 顺序的写（偏移、长度、首 8 字节）
struct nvn_gpu_buf_s { uint64_t bytes; };
static int g_buf_creates, g_buf_releases; static uint64_t g_buf_bytes;
static struct { uint64_t off, len; uint8_t head[8]; } g_bw[32]; static int g_nbw;
nvn_gpu_rc nvn_gpu_buf_create(uint64_t bytes, int mem, const void *init, nvn_gpu_buf *out, nvn_gpu_err *err) { (void)mem; (void)init; (void)err; g_buf_creates++; g_buf_bytes = bytes; *out = calloc(1, sizeof **out); (*out)->bytes = bytes; return (nvn_gpu_rc){NVN_GPU_OK}; }
void nvn_gpu_buf_release(nvn_gpu_buf b, nvn_gpu_retired_fn retired, void *user) { (void)retired; (void)user; g_buf_releases++; free(b); }
void nvn_gpu_buf_write(nvn_gpu_cmd c, nvn_gpu_buf dst, uint64_t off, const void *src, uint64_t bytes) { (void)c; (void)dst; if (g_nbw == 32) return;
    g_bw[g_nbw].off = off; g_bw[g_nbw].len = bytes; memcpy(g_bw[g_nbw].head, src, bytes < 8 ? bytes : 8); g_nbw++; }
// 页级脏账替身：4096 字节一页，g_pmem 这个池每页的写代号由用例设
enum { PG = 4096, NPG = 8 };
static _Alignas(4096) uint8_t g_pmem[PG * NPG]; static uint64_t g_pg_gen[NPG]; static int g_pg_tracked = 1;
size_t nvn_dirty_page_size(void) { return PG; }
const void *nvn_dirty_span(const void *addr, size_t len) { (void)len; return (const uint8_t *)addr >= g_pmem && (const uint8_t *)addr < g_pmem + sizeof g_pmem ? g_pmem : NULL; }
long nvn_dirty_page_gens(const void *span, const void *addr, size_t len, uint64_t *gens, size_t n) {
    if (!span || !g_pg_tracked) return -1;
    size_t p = (size_t)((const uint8_t *)addr - g_pmem) / PG, q = (size_t)((const uint8_t *)addr + len - 1 - g_pmem) / PG;
    if (q - p + 1 > n) return -1;
    for (size_t i = p; i <= q; i++) gens[i - p] = g_pg_gen[i];
    return (long)(q - p + 1);
}

static void fake_complete(uint32_t status) {
    for (int i = 0; i < g_npend; i++) { nvn_gpu_done d = {0}; d.signal = g_pend[i].signal; d.status = status; d.why = "替身失败"; g_pend[i].fn(g_pend[i].user, &d); if (status != NVN_GPU_DONE_FAILED) g_fdone = g_pend[i].signal; }
    g_npend = 0;
}

// ---------- 录制替身：按 nvn_obj.h 的记录格式写 ----------
typedef struct { uint8_t b[4096]; size_t n; } stream;
static void *put(stream *s, uint32_t op, size_t payload) {
    uint32_t sz = (uint32_t)((8 + payload + 7) & ~(size_t)7); op_hdr h = {op, sz};
    memcpy(s->b + s->n, &h, 8); void *a = s->b + s->n + 8; memset(a, 0, sz - 8); s->n += sz; return a;
}
static void end(stream *s) { put(s, OP_END, 0); }
static void submit1(stream *s) { uint64_t h = (uint64_t)(uintptr_t)s->b; nvn_be_submit(NULL, &h, 1); }

static void t_state_persists(void) {   // 结论 B：状态跨命令缓冲、跨提交继承
    stream a = {0}, b = {0};
    p_blend_color *bc = put(&a, OP_BLEND_COLOR, sizeof *bc); bc->rgba[0] = 1; bc->rgba[1] = 2; bc->rgba[2] = 3; bc->rgba[3] = 4;
    p_viewports *vp = put(&a, OP_VIEWPORTS, sizeof *vp); vp->first = 1; vp->n = 1; vp->v[0][0] = 10; vp->v[0][1] = 20; vp->v[0][2] = 640; vp->v[0][3] = 360;
    p_scissor *sc = put(&a, OP_SCISSOR, sizeof *sc); sc->x = 5; sc->y = 6; sc->w = 7; sc->h = 8;
    end(&a); end(&b);
    submit1(&a); fake_complete(NVN_GPU_DONE_OK);
    submit1(&b); fake_complete(NVN_GPU_DONE_OK);
    CHECK(rp_S.blend_color[0] == 1 && rp_S.blend_color[3] == 4);
    CHECK(rp_S.has_vp == 1 && rp_S.vp[1][0] == 10 && rp_S.vp[1][2] == 640 && rp_S.vp[0][2] == 0);
    CHECK(rp_R.has_sc == 1 && rp_R.sc.x == 5 && rp_R.sc.h == 8);
    CHECK(rp_S.dr[1] == 1 && rp_S.patch_size == 3 && rp_S.ms.enable == 1);   // NVN 默认值没被提交清掉
}

static void t_unimpl_names(void) {   // 没接的命令按命令名报出并计数，回放继续走完
    nvn_unimpl_reset(); int red0 = g_red_lines;
    stream a = {0};
    put(&a, OP_DRAW, sizeof(p_draw)); put(&a, OP_SET_RT, 8); put(&a, OP_SET_RT, 8); put(&a, OP_COPY_T2T, sizeof(p_copy_t2t));
    p_alpha_ref *ar = put(&a, OP_ALPHA_REF, sizeof *ar); ar->ref = 0.25f;   // 排在未接命令之后：证明没有因首个未接而停
    end(&a);
    submit1(&a); fake_complete(NVN_GPU_DONE_OK);
    CHECK(nvn_unimpl_count("op", "OP_DRAW") == 1);
    CHECK(nvn_unimpl_count("op", "OP_SET_RT") == 2);
    CHECK(nvn_unimpl_count("op", "OP_COPY_T2T") == 1);
    CHECK(nvn_unimpl_count("op", "OP_ALPHA_REF") == 0);
    CHECK(nvn_unimpl_kinds() == 3);
    CHECK(g_red_lines - red0 == 3);   // 每种只在首次出现打一行
    char buf[256]; nvn_unimpl_dump(buf, sizeof buf);
    CHECK(!strcmp(buf, "op\tOP_DRAW\t1\nop\tOP_SET_RT\t2\nop\tOP_COPY_T2T\t1\n"));
    CHECK(rp_S.alpha_ref == 0.25f);
}

static void t_one_commit_per_submit(void) {   // 结论 C：绘制攒着，一次提交一段
    int b0 = g_begins, c0 = g_commits, q0 = g_q_enter, p0 = g_piece;
    stream a = {0}; for (int i = 0; i < 5; i++) put(&a, OP_DRAW_IDX, sizeof(p_draw_idx)); end(&a);
    submit1(&a);
    CHECK(g_begins - b0 == 1 && g_commits - c0 == 1);
    CHECK(g_q_enter - q0 == 1 && g_piece - p0 == 1);
    fake_complete(NVN_GPU_DONE_OK);
}

static void t_event_after_done(void) {   // 事件值只在段完成后可见；失败段不回写
    volatile uint32_t ev = 0; stream a = {0};
    uint8_t *r = put(&a, OP_SIGNAL_EVENT, 16); volatile uint32_t *pv = &ev; uint32_t m = 0, v = 7; memcpy(r, &pv, 8); memcpy(r + 8, &m, 4); memcpy(r + 12, &v, 4);
    r = put(&a, OP_SIGNAL_EVENT, 16); m = 1; v = 3; memcpy(r, &pv, 8); memcpy(r + 8, &m, 4); memcpy(r + 12, &v, 4);
    end(&a);
    uint64_t f0 = nvn_be_last_fence();
    submit1(&a);
    CHECK(nvn_be_last_fence() == f0 + 1);
    CHECK(ev == 0);                                   // 已提交、未完成
    CHECK(nvn_be_wait(f0 + 1, 0) == 0);
    fake_complete(NVN_GPU_DONE_OK);
    CHECK(ev == 10);                                  // 写 7 再加 3
    CHECK(nvn_be_wait(f0 + 1, 0) == 1);
    submit1(&a); int red0 = g_red_lines; fake_complete(NVN_GPU_DONE_FAILED);
    CHECK(ev == 10);                                  // 失败段：不回写
    CHECK(g_red_lines - red0 == 1);
}

static void t_fence_sync(void) {
    sync_t s; memset(&s, 0, sizeof s); stream a = {0};
    uint8_t *r = put(&a, OP_FENCE_SYNC, 8); sync_t *ps = &s; memcpy(r, &ps, 8); end(&a);
    uint64_t f0 = nvn_be_last_fence();
    submit1(&a); fake_complete(NVN_GPU_DONE_OK);
    uint64_t got = 0; CHECK(sync_published(&s, &got) == 1 && got == f0 + 1);
}

static void t_jump_call(void) {
    stream a = {0}, b = {0}, sub = {0};
    p_alpha_ref *ar = put(&sub, OP_ALPHA_REF, sizeof *ar); ar->ref = 0.5f; end(&sub);
    p_depth_range *dr = put(&b, OP_DEPTH_RANGE, sizeof *dr); dr->n = 0.125f; dr->f = 0.75f; end(&b);
    uint8_t *r = put(&a, OP_CALL, 8); uint64_t h = (uint64_t)(uintptr_t)sub.b; memcpy(r, &h, 8);
    p_set_patch_size *ps = put(&a, OP_SET_PATCH_SIZE, sizeof *ps); ps->size = 4;   // CALL 返回后继续
    r = put(&a, OP_JUMP, 8); const uint8_t *t = b.b; memcpy(r, &t, 8);
    p_set_patch_size *dead = put(&a, OP_SET_PATCH_SIZE, sizeof *dead); dead->size = 9;   // JUMP 之后的不该执行
    end(&a);
    submit1(&a); fake_complete(NVN_GPU_DONE_OK);
    CHECK(rp_S.alpha_ref == 0.5f && rp_S.patch_size == 4 && rp_S.dr[0] == 0.125f && rp_S.dr[1] == 0.75f);
}

static void t_bad_record(void) {
    nvn_unimpl_reset(); stream a = {0};
    p_set_patch_size *ps = put(&a, OP_SET_PATCH_SIZE, sizeof *ps); ps->size = 5;
    op_hdr bad = {OP_DRAW, 12}; memcpy(a.b + a.n, &bad, 8); a.n += 16;   // 长度不是 8 的倍数
    ps = put(&a, OP_SET_PATCH_SIZE, sizeof *ps); ps->size = 6; end(&a);
    submit1(&a); fake_complete(NVN_GPU_DONE_OK);
    CHECK(nvn_unimpl_count("rec", "bad_record") == 1);
    CHECK(rp_S.patch_size == 5);   // 坏记录之后不再执行
}

static void t_dirty_bits(void) {
    stream a = {0};
    p_bind_state *bs = put(&a, OP_BIND_STATE, sizeof *bs); bs->kind = 4; poly_st po = {NVN_FACE_BACK, NVN_FRONT_FACE_CW, NVN_POLYGON_MODE_FILL, 0}; memcpy(bs->bytes, &po, sizeof po);
    end(&a);
    nvn_be_exec(a.b); rp_pso_dirty = 0; rp_dss_dirty = 0;
    nvn_be_exec(a.b);                         // 同一状态再绑一次：不标脏
    CHECK(rp_pso_dirty == 0 && rp_S.poly.cull == NVN_FACE_BACK);
    stream b = {0}; bs = put(&b, OP_BIND_STATE, sizeof *bs); bs->kind = 4; po.cull = NVN_FACE_FRONT; memcpy(bs->bytes, &po, sizeof po);
    p_stencil *st = put(&b, OP_STENCIL, sizeof *st); st->face = 3; st->which = 2; st->ref = 9;   // 参考值是动态状态：不标深度模板脏
    end(&b);
    nvn_be_exec(b.b);
    CHECK(rp_pso_dirty == 1 && rp_dss_dirty == 0 && rp_S.st_ref[0] == 9 && rp_S.st_ref[1] == 9);
}

static void t_deferred_bind(void) {   // 延后绑定：回放到这条时才读游戏内存，且做 GPU 地址换算
    NVNbufferRange range = {0x4000, 64}; stream a = {0};
    p_bind_buf *b = put(&a, OP_BIND_UBO, sizeof *b); b->stage = 1 | BIND_BUF_DEFER; b->index = 3; b->addr = (uint64_t)(uintptr_t)&range;
    end(&a);
    range.address = 0x8000; range.size = 128;   // 录制之后、回放之前游戏改了
    nvn_be_exec(a.b);
    CHECK(rp_S.ubo[1][3].addr == 0x9000 && rp_S.ubo[1][3].size == 128 && rp_S.ubo[1][3].stage == 1);
}

static void t_program_stages(void) {
    prog_t pa, pb; memset(&pa, 0, sizeof pa); memset(&pb, 0, sizeof pb);
    pa.magic = pb.magic = MAGIC('P', 'R', 'O', 'G'); pa.serial = 11; pb.serial = 22;
    stream a = {0};
    p_bind_program_id *id = put(&a, OP_BIND_PROGRAM, sizeof *id); id->prog = &pa; id->serial = 11; id->stages = 0x3;
    id = put(&a, OP_BIND_PROGRAM, sizeof *id); id->prog = &pb; id->serial = 22; id->stages = 0x20;   // 计算阶段单独一份，不顶掉图形阶段
    end(&a);
    nvn_be_exec(a.b);
    CHECK(rp_S.bser[0] == 11 && rp_S.bser[1] == 11 && rp_S.bser[2] == 0 && rp_S.bst[0] == &pa);
    CHECK(rp_S.cser == 22 && rp_S.cprog == &pb);
    pa.serial = 99;   // 游戏复用了程序对象
    stream c = {0}; id = put(&c, OP_BIND_PROGRAM, sizeof *id); id->prog = &pb; id->serial = 22; id->stages = 0x20; end(&c);
    nvn_be_exec(c.b);
    CHECK(rp_S.bser[0] == 11 && rp_S.bst[0] == NULL);   // 仍按绑定当时的序号，不再读那个对象
}

static void t_pools(void) {
    static uint8_t mem[0x1000]; uint64_t b = (uint64_t)(uintptr_t)mem; void *buf = NULL; uint64_t off = 0;
    int n0 = rp_pool_count();
    nvn_be_pool_add(mem, sizeof mem);
    CHECK(rp_pool_count() == n0 + 1);
    CHECK(nvn_be_addr(b + 0x800, 0x100, &buf, &off) == 1 && buf == (void *)mem && off == 0x800);
    CHECK(nvn_be_addr(b + 0xf80, 0x100, &buf, &off) == 0);    // 越过池尾
    CHECK(nvn_be_addr(b + 0xf00, 0x100, &buf, &off) == 1);    // 恰好到池尾
    nvn_be_pool_del(mem);
    CHECK(nvn_be_addr(b + 0x800, 0x100, &buf, &off) == 0 && rp_pool_count() == n0);
}

static pool_t g_tp; static uint8_t g_tmem[1 << 16];
static tex_t mk_tex(uint64_t serial, int64_t off, int fmt, uint32_t w, uint32_t h, uint32_t levels, int flags) {
    tex_t t; memset(&t, 0, sizeof t); t.magic = MAGIC('T', 'E', 'X', 'T'); t.serial = serial; t.pool = &g_tp; t.off = off; t.mem = g_tmem + off;
    t.d.target = NVN_TEXTURE_TARGET_2D; t.d.format = fmt; t.d.width = w; t.d.height = h; t.d.depth = 1; t.d.levels = levels; t.d.flags = flags;
    nvn_tex_layout(&t.d, &t.L); return t;
}
static void res_fresh(void) { rp_res_reset(); memset(g_tmem, 0, sizeof g_tmem); memset(&g_tp, 0, sizeof g_tp); g_tp.mem = g_tmem; g_tp.size = sizeof g_tmem; g_tp.flags = NVN_MEMORY_POOL_FLAGS_CPU_CACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED;
    g_nup = 0; g_dirty_written = 0; }

// 结论 A：贴图初始化和登记都不建图；只有被用到的那一个建。
static void t_tex_init_registers_only(void) {
    res_fresh();
    enum { N = 11400 }; static tex_t t[N]; int n0 = rp_tex_live_n(), c0 = g_tex_creates;
    for (int i = 0; i < N; i++) { t[i] = mk_tex(1000 + (uint64_t)i, 0, NVN_FORMAT_RGBA8, 64u, 64u, 1, 0); nvn_be_tex_init(&t[i]); nvn_be_reg_tex(i, &t[i], NULL); }
    CHECK(rp_tex_live_n() == n0 + N);
    CHECK(g_tex_creates == c0 && rp_res_tex_built() == 0);          // 11400 个对象：0 张图
    CHECK(rp_view_by_id(7, &g_fake_cmd, NULL) != NULL);
    CHECK(g_tex_creates == c0 + 1 && rp_res_tex_built() == 1);      // 用到 1 个：1 张图
    for (int i = 0; i < 400; i++) nvn_be_tex_release(&t[i]);
    CHECK(rp_tex_live_n() == n0 + N - 400);
    tex_t z; memset(&z, 0, sizeof z); nvn_be_tex_init(&z);   // 序号 0：不登记
    CHECK(rp_tex_live_n() == n0 + N - 400);
    for (int i = 400; i < N; i++) nvn_be_tex_release(&t[i]);
}

static void t_alias(void) {   // 同池同偏移同描述的对象共用一份存储；只差用途标志也算同一份；偏移不同是两份
    res_fresh(); int c0 = g_tex_creates, r0 = g_tex_releases;
    tex_t a = mk_tex(1, 0, NVN_FORMAT_RGBA8, 32, 32, 1, 0), b = mk_tex(2, 0, NVN_FORMAT_RGBA8, 32, 32, 1, NVN_TEXTURE_FLAGS_IMAGE), c = mk_tex(3, 0x4000, NVN_FORMAT_RGBA8, 32, 32, 1, 0);
    nvn_gpu_tex ga = rp_tex_resolve(&a, &g_fake_cmd), gb = rp_tex_resolve(&b, &g_fake_cmd), gc = rp_tex_resolve(&c, &g_fake_cmd);
    CHECK(ga && ga == gb && gc && gc != ga);
    CHECK(g_tex_creates - c0 == 2 && rp_res_tex_built() == 2 && rp_res_tex_serials() == 3);
    CHECK(g_nup == 0);                                              // 存储全 0：不是 CPU 内容，不上传
    CHECK(g_last_usage & NVN_GPU_TEX_RENDER);                       // 能当附件的格式建图时就带附件用途
    tex_t sw = mk_tex(4, 0x8000, NVN_FORMAT_RGBA8, 32, 32, 1, 0); sw.set_swz = 1; sw.swz = 2 | 3 << 3 | 4 << 6 | 5 << 9;
    CHECK(rp_tex_resolve(&sw, &g_fake_cmd) != NULL && g_last_swz == 0);   // 游戏设了恒等通道映射：按「没设」交给后端
    sw.serial = 6; sw.off = 0xC000; sw.mem = g_tmem + 0xC000; sw.swz = 5 | 4 << 3 | 3 << 6 | 2 << 9;
    CHECK(rp_tex_resolve(&sw, &g_fake_cmd) != NULL && g_last_swz == (5 | 4 << 3 | 3 << 6 | 2 << 9));   // 非恒等：原样交
    nvn_be_tex_release(&sw); sw.serial = 4; nvn_be_tex_release(&sw);   // 两个对象都 Finalize；存储仍由共用表持有
    c0 += 2;
    nvn_be_tex_release(&a); nvn_be_tex_release(&b);
    CHECK(g_tex_releases == r0);                                    // 共用表持有：对象 Finalize 不放存储
    tex_t a2 = mk_tex(9, 0, NVN_FORMAT_RGBA8, 32, 32, 1, 0);
    CHECK(rp_tex_resolve(&a2, &g_fake_cmd) == ga && g_tex_creates - c0 == 2);   // 每帧在新对象上重建同一张：还是那份
    nvn_be_tex_release(&a2); nvn_be_tex_release(&c);
    nvn_be_alias_drop_pool(&g_tp);
    CHECK(g_tex_releases - r0 == 4 && rp_res_tex_built() == 0);     // 池销毁：出表并放掉（a/b 共用的一份、c、两张通道映射的）
}

static void t_cpu_upload(void) {   // 存储里是 CPU 写的数据：首次使用上传，之后只在脏了时重传；内容交 GPU 后不再传
    res_fresh();
    tex_t t = mk_tex(5, 0, NVN_FORMAT_RGBA8, 8, 8, 2, 0);
    uint8_t lin0[8 * 8 * 4], lin1[4 * 4 * 4]; for (unsigned i = 0; i < sizeof lin0; i++) lin0[i] = (uint8_t)(i * 7 + 1); for (unsigned i = 0; i < sizeof lin1; i++) lin1[i] = (uint8_t)(200 - i);
    CHECK(nvn_swizzle(&t.d, 0, 0, lin0, 32, t.mem) == 0 && nvn_swizzle(&t.d, 1, 0, lin1, 16, t.mem) == 0);
    int c0 = g_tex_creates, r0 = g_tex_releases, p0 = g_protects; uint64_t u0 = rp_res_uploads();
    CHECK(rp_tex_resolve(&t, &g_fake_cmd) != NULL);
    CHECK(g_tex_creates - c0 == 1 && (g_last_usage & NVN_GPU_TEX_CPU_UPLOAD));
    CHECK(rp_res_uploads() - u0 == 1 && g_nup == 2 && g_protects - p0 == 1);
    CHECK(g_up[0].level == 0 && g_up[0].pitch == 32 && g_up[0].img == 256 && g_up[0].w == 8 && g_up[0].h == 8 && !memcmp(g_up[0].first, lin0, 64));
    CHECK(g_up[1].level == 1 && g_up[1].pitch == 16 && g_up[1].img == 64 && g_up[1].w == 4 && !memcmp(g_up[1].first, lin1, 64));
    CHECK(rp_tex_resolve(&t, &g_fake_cmd) != NULL && rp_res_uploads() - u0 == 1);   // 没脏：不重传
    g_dirty_written = g_dirty_now + 1; g_dirty_now += 2;
    CHECK(rp_tex_resolve(&t, &g_fake_cmd) != NULL && rp_res_uploads() - u0 == 2);   // 游戏写过：重传
    CHECK(nvn_be_tex_gpu_owned(5) == 0);
    rp_tex_mark_gpu_written(&t); g_dirty_written = g_dirty_now + 1; g_dirty_now += 2;
    CHECK(rp_tex_resolve(&t, &g_fake_cmd) != NULL && rp_res_uploads() - u0 == 2);   // 内容已归 GPU：不再从游戏内存传
    CHECK(nvn_be_tex_gpu_owned(5) == 1);
    nvn_be_tex_cpu_written(&t);                                                     // 游戏又 WriteTexels 了
    CHECK(rp_tex_resolve(&t, &g_fake_cmd) != NULL && rp_res_uploads() - u0 == 3 && nvn_be_tex_gpu_owned(5) == 0);
    nvn_be_tex_release(&t);
    CHECK(g_tex_releases - r0 == 1 && rp_res_tex_built() == 0);                     // CPU 内容贴图不进共用表：对象 Finalize 即放
}

static void t_cpu_rules(void) {   // 首用判定的三条分支
    res_fresh();
    tex_t a = mk_tex(21, 0, NVN_FORMAT_RGBA8, 8, 8, 1, 0); memset(a.mem, 0x55, a.L.size);
    nvn_be_pool_gpu_written(&g_tp);                                 // GPU 写过的池里的未压缩贴图：当渲染目标，不取存储
    CHECK(rp_tex_resolve(&a, &g_fake_cmd) != NULL && g_nup == 0);
    tex_t b = mk_tex(22, 0x2000, NVN_FORMAT_RGBA8, 8, 8, 1, 0); memset(b.mem, 0x66, b.L.size);
    nvn_be_tex_cpu_written(&b);                                     // 但游戏明确 WriteTexels 写过的：取存储
    CHECK(rp_tex_resolve(&b, &g_fake_cmd) != NULL && g_nup == 1);
    nvn_be_tex_release(&a); nvn_be_tex_release(&b); nvn_be_alias_drop_pool(&g_tp);
    res_fresh();
    tex_t d = mk_tex(23, 0, NVN_FORMAT_RGBA8, 8, 8, 1, NVN_TEXTURE_FLAGS_COMPRESSIBLE); memset(d.mem, 0x77, d.L.size);
    CHECK(rp_tex_resolve(&d, &g_fake_cmd) != NULL && g_nup == 0);   // COMPRESSIBLE（渲染目标的标志）：不取存储
    nvn_be_tex_release(&d); nvn_be_alias_drop_pool(&g_tp);
}

static void t_registry(void) {
    res_fresh(); nvn_unimpl_reset(); int v0 = g_view_creates, vr0 = g_view_releases, s0 = g_samp_creates, sr0 = g_samp_releases;
    tex_t a = mk_tex(31, 0, NVN_FORMAT_RGBA8, 16, 16, 1, 0), b = mk_tex(32, 0x4000, NVN_FORMAT_RGBA8, 16, 16, 1, 0);
    view_t vw; memset(&vw, 0, sizeof vw); vw.set_levels = 1; vw.nlevels = 1;
    CHECK(rp_view_by_id(3, &g_fake_cmd, NULL) == NULL);             // 没登记
    nvn_be_reg_tex(3, &a, NULL); nvn_be_set_tex_pool_n(8);
    const tex_t *tt = NULL; nvn_gpu_view v1 = rp_view_by_id(3, &g_fake_cmd, &tt);
    CHECK(v1 && tt && tt->serial == 31 && v1->has_v == 0);
    CHECK(rp_view_by_id(3, &g_fake_cmd, NULL) == v1 && g_view_creates - v0 == 1);   // 第二次取：同一个视图
    nvn_be_reg_tex(3, &a, NULL);
    CHECK(rp_view_by_id(3, &g_fake_cmd, NULL) == v1 && g_view_creates - v0 == 1);   // 同内容重登记：视图还在
    nvn_be_reg_tex(3, &b, &vw);
    nvn_gpu_view v2 = rp_view_by_id(3, &g_fake_cmd, &tt);
    CHECK(v2 && tt->serial == 32 && v2->has_v == 1 && g_view_creates - v0 == 2 && g_view_releases - vr0 == 1);   // 换了内容：旧视图放掉
    nvn_be_reg_tex(9, &a, NULL);
    CHECK(rp_view_by_id(9, &g_fake_cmd, NULL) == NULL);             // 池容量 8：号 9 在池外，当空槽
    nvn_be_unreg_tex_range(0, 8);
    CHECK(rp_view_by_id(3, &g_fake_cmd, NULL) == NULL && g_view_releases - vr0 == 2);
    samp_par sp; memset(&sp, 0, sizeof sp);
    CHECK(rp_samp_by_id(4) == NULL);
    nvn_be_reg_samp(4, &sp); CHECK(g_samp_creates == s0);            // 登记不建
    nvn_gpu_samp q = rp_samp_by_id(4);
    CHECK(q && rp_samp_by_id(4) == q && g_samp_creates - s0 == 1);
    nvn_be_reg_samp(4, &sp);
    CHECK(g_samp_releases - sr0 == 1 && rp_samp_by_id(4) != NULL && g_samp_creates - s0 == 2);
    g_tex_create_fail = 1; tex_t f = mk_tex(40, 0x8000, 0x38, 16, 16, 1, 0); nvn_be_set_tex_pool_n(0); nvn_be_reg_tex(5, &f, NULL);
    CHECK(rp_view_by_id(5, &g_fake_cmd, NULL) == NULL && nvn_unimpl_count("gpu", "tex_create_fmt_0x38_target_1") == 1);   // 后端不支持：按格式号记账，不给假图
    g_tex_create_fail = 0;
    res_fresh();
}

static void t_buf_mirror(void) {   // 池镜像：首次使用建一份、按页同步；没写过的页不重传；按使用点的先后保证 GPU 顺序
    nvn_be_shutdown_session(); nvn_unimpl_reset(); memset(g_pg_gen, 0, sizeof g_pg_gen); g_pg_tracked = 1; g_nbw = 0; g_dirty_now = 100;
    for (unsigned i = 0; i < sizeof g_pmem; i++) g_pmem[i] = (uint8_t)(i / PG + 1);   // 第 k 页全是 k+1
    uint64_t base = (uint64_t)(uintptr_t)g_pmem; int c0 = g_buf_creates, r0 = g_buf_releases;
    nvn_be_pool_add(g_pmem, sizeof g_pmem);
    CHECK(g_buf_creates == c0);                                     // 登记池不建镜像
    nvn_gpu_buf b1 = NULL, b2 = NULL; uint64_t o1 = 0, o2 = 0;
    CHECK(rp_buf_resolve(&g_fake_cmd, base + PG + 100, 200, &b1, &o1) == 1);
    CHECK(g_buf_creates - c0 == 1 && g_buf_bytes == sizeof g_pmem && o1 == PG + 100);
    CHECK(g_nbw == 1 && g_bw[0].off == PG && g_bw[0].len == PG && g_bw[0].head[0] == 2);   // 只同步用到的那一页（整页）
    CHECK(rp_buf_resolve(&g_fake_cmd, base + PG + 300, 50, &b2, &o2) == 1 && b2 == b1 && g_nbw == 1);   // 同页、没写过：不重传
    CHECK(rp_buf_resolve(&g_fake_cmd, base + PG - 8, 2 * PG, NULL, NULL) == 1);             // 跨第 0–2 页：第 1 页已同步，补第 0 页和第 2 页
    CHECK(g_nbw == 3 && g_bw[1].off == 0 && g_bw[1].len == PG && g_bw[2].off == 2 * PG && g_bw[2].len == PG);
    g_pg_gen[1] = 101; g_dirty_now = 102;                           // 游戏写了第 1 页
    CHECK(rp_buf_resolve(&g_fake_cmd, base, 3 * PG, NULL, NULL) == 1 && g_nbw == 4 && g_bw[3].off == PG && g_bw[3].len == PG);
    CHECK(rp_buf_resolve(&g_fake_cmd, base, 3 * PG, NULL, NULL) == 1 && g_nbw == 4);       // 再用：干净
    CHECK(rp_buf_resolve(&g_fake_cmd, base + sizeof g_pmem - 4, 8, NULL, NULL) == 0 && nvn_unimpl_count("buf", "address_outside_pools") == 1);   // 越过池尾
    g_pg_tracked = 0;                                               // 没被写跟踪：每次使用都同步
    CHECK(rp_buf_resolve(&g_fake_cmd, base, 100, NULL, NULL) == 1 && rp_buf_resolve(&g_fake_cmd, base, 100, NULL, NULL) == 1 && g_nbw == 6);
    g_pg_tracked = 1;
    CHECK(rp_buf_mirrors() == 1);
    nvn_be_pool_del(g_pmem);
    CHECK(g_buf_releases - r0 == 1 && rp_buf_mirrors() == 0);       // 池销毁：镜像放掉
}

static void t_buf_ops(void) {   // 缓冲类命令只改游戏内存；GPU 顺序由使用点同步保证：先用的看到旧内容，后用的看到新内容
    nvn_be_shutdown_session(); nvn_unimpl_reset(); memset(g_pg_gen, 0, sizeof g_pg_gen); g_nbw = 0; g_dirty_now = 100; memset(g_pmem, 0, sizeof g_pmem);
    uint64_t base = (uint64_t)(uintptr_t)g_pmem; nvn_be_pool_add(g_pmem, sizeof g_pmem);
    memset(g_pmem, 0xA1, 16);
    stream a = {0};
    uint8_t *r = put(&a, OP_UPDATE_UB, 16 + 8); uint64_t d = base, n = 8; memcpy(r, &d, 8); memcpy(r + 8, &n, 8); memset(r + 16, 0xB2, 8);
    r = put(&a, OP_COPY_B2B, 24); uint64_t sv = base, dv = base + PG; n = 8; memcpy(r, &sv, 8); memcpy(r + 8, &dv, 8); memcpy(r + 16, &n, 8);
    p_clear_buf *cb = put(&a, OP_CLEAR_BUF, sizeof *cb); cb->addr = base + 2 * PG; cb->size = 10; cb->value = 0x11223344;
    r = put(&a, OP_UPDATE_UB, 16 + 8); d = base + sizeof g_pmem - 4; n = 8; memcpy(r, &d, 8); memcpy(r + 8, &n, 8);   // 越过池尾：拒绝
    end(&a);
    CHECK(rp_buf_resolve(&g_fake_cmd, base, 8, NULL, NULL) == 1 && g_nbw == 1 && g_bw[0].head[0] == 0xA1);   // 命令之前的使用点：旧内容
    nvn_be_sub_begin(); nvn_be_exec(a.b);
    CHECK(g_pmem[0] == 0xB2 && g_pmem[7] == 0xB2 && g_pmem[8] == 0xA1);        // UPDATE_UB
    CHECK(g_pmem[PG] == 0xB2 && g_pmem[PG + 7] == 0xB2 && g_pmem[PG + 8] == 0);  // COPY_B2B 拷的是更新后的内容
    uint8_t want[10] = {0x44, 0x33, 0x22, 0x11, 0x44, 0x33, 0x22, 0x11, 0x44, 0x33};
    CHECK(!memcmp(g_pmem + 2 * PG, want, 10) && g_pmem[2 * PG + 10] == 0);     // CLEAR_BUF：32 位样式，不是按字节
    CHECK(nvn_unimpl_count("buf", "update_outside_pools") == 1);
    CHECK(nvn_unimpl_count("op", "OP_UPDATE_UB") == 0 && nvn_unimpl_count("op", "OP_COPY_B2B") == 0 && nvn_unimpl_count("op", "OP_CLEAR_BUF") == 0);
    g_pg_gen[0] = 101; g_dirty_now = 102;                                       // 写跟踪看到了第 0 页被写
    CHECK(rp_buf_resolve(&g_fake_cmd, base, 8, NULL, NULL) == 1 && g_nbw == 2 && g_bw[1].head[0] == 0xB2);   // 命令之后的使用点：新内容
    nvn_be_sub_commit(); fake_complete(NVN_GPU_DONE_OK);
    nvn_be_pool_del(g_pmem);
}

static void t_copy_b2t(void) {   // 缓冲 → 贴图：线性行直接传；级 / 层取自视图；行距可由游戏设；之后内容归 GPU
    nvn_be_shutdown_session(); res_fresh(); nvn_unimpl_reset(); memset(g_pmem, 0, sizeof g_pmem);
    for (int i = 0; i < 64; i++) g_pmem[i] = (uint8_t)(i + 1);
    nvn_be_pool_add(g_pmem, sizeof g_pmem);
    tex_t t = mk_tex(51, 0, NVN_FORMAT_RGBA8, 16, 16, 3, 0);
    stream a = {0};
    p_copy_b2t *o = put(&a, OP_COPY_B2T, sizeof *o + sizeof t); tex_t *snap = (tex_t *)(o + 1); *snap = t;
    o->src = (uint64_t)(uintptr_t)g_pmem; o->tex = snap; o->has_view = 1; o->view.set_levels = 1; o->view.base_level = 2;
    o->r = (NVNcopyRegion){1, 0, 0, 2, 2, 1};
    o = put(&a, OP_COPY_B2T, sizeof *o + sizeof t); snap = (tex_t *)(o + 1); *snap = t;
    o->src = (uint64_t)(uintptr_t)g_pmem + 16; o->tex = snap; o->r = (NVNcopyRegion){0, 0, 0, 4, 2, 1}; o->row_stride = 32;
    end(&a);
    nvn_be_sub_begin(); nvn_be_exec(a.b);
    CHECK(g_nup == 2 && nvn_unimpl_count("op", "OP_COPY_B2T") == 0);
    CHECK(g_up[0].level == 2 && g_up[0].layer == 0 && g_up[0].w == 2 && g_up[0].h == 2 && g_up[0].pitch == 8 && g_up[0].img == 16 && g_up[0].first[0] == 1);
    CHECK(g_up[1].level == 0 && g_up[1].pitch == 32 && g_up[1].img == 64 && g_up[1].first[0] == 17);
    CHECK(nvn_be_tex_gpu_owned(51) == 1);
    nvn_be_sub_commit(); fake_complete(NVN_GPU_DONE_OK);
    nvn_be_tex_release(&t); nvn_be_alias_drop_pool(&g_tp); nvn_be_pool_del(g_pmem);
}

static void t_entry_unimpl(void) {   // 有语义而没接的入口：记账，不报假成功
    nvn_unimpl_reset();
    CHECK(nvn_be_present(NULL, 0, NULL) == 1 && nvn_be_present(NULL, 0, NULL) == 2);
    CHECK(nvn_unimpl_count("be", "present") == 2);
    CHECK(nvn_be_presented_time(1) == -1);
    CHECK(nvn_be_has_window() == 0 && nvn_be_display_hz() == 0);
    CHECK(nvn_be_fps_target() == 30);   // 替身宿主设的是 30
}

static int t_table(const char *tsv) {   // 接线表与名字表一致：值、命令名逐行对
    FILE *f = fopen(tsv, "r"); if (!f) { printf("【红】 打不开接线表 %s\n", tsv); return 1; }
    char line[512]; int rows = 0; if (!fgets(line, sizeof line, f)) { fclose(f); return 1; }
    while (fgets(line, sizeof line, f)) { unsigned v; char name[64]; if (sscanf(line, "%u\t%63s", &v, name) != 2) continue;
        CHECK(v == (unsigned)rows); CHECK(!strcmp(rp_op_name(v), name)); rows++; }
    fclose(f);
    CHECK(rows == OP_NVN2_END_);
    CHECK(!strcmp(rp_op_name(OP_NVN2_END_), "OP_?"));
    return 0;
}

int main(int argc, char **argv) {
    t_state_persists(); t_unimpl_names(); t_one_commit_per_submit(); t_event_after_done(); t_fence_sync();
    t_jump_call(); t_bad_record(); t_dirty_bits(); t_deferred_bind(); t_program_stages();
    t_pools(); t_tex_init_registers_only(); t_alias(); t_cpu_upload(); t_cpu_rules(); t_registry(); t_buf_mirror(); t_buf_ops(); t_copy_b2t(); t_entry_unimpl();
    if (argc > 1 && t_table(argv[1])) g_fail++;
    printf("t_nvn_replay：%d 项检查，%d 项红\n", g_checks, g_fail);
    return g_fail ? 1 : 0;
}
