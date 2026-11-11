// 回放核心（graphics/nvn/replay）的宿主单测：纯 C，后端与平台件都是本文件里的替身，不需要 GPU。
// 期望值都由用例自己写下的输入直接得出，不经被测实现计算。
#include "nvn_obj.h"
#include "nvn2_cmd.h"
#include "nvn_backend.h"
#include "nvn_mtl.h"
#include "../replay/rp_state.h"
#include "../replay/rp_exec.h"
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
    if (argc > 1 && t_table(argv[1])) g_fail++;
    printf("t_nvn_replay：%d 项检查，%d 项红\n", g_checks, g_fail);
    return g_fail ? 1 : 0;
}
