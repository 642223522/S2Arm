// 回放主循环与提交（对齐 nvn_mtl.m：nvn_be_exec @14491、nvn_be_sub_begin @1171、nvn_be_sub_commit @2210、nvn_xqueue.inc xq_piece @106）。
// 一次游戏提交 = 一段后端命令 = 一个栅栏值；绘制攒在段里，不逐笔提交，CPU 不等完成。
// 「GPU 完成后才可见」的 CPU 副作用（事件值、计数器）挂在本段的完成回调里做。
#include "rp_exec.h"
#include "rp_state.h"
#include "nvn_unimpl.h"
#include "nvn_plat.h"
#include "nvn_backend.h"
#include "nvn_mtl.h"   // 上沿声明（nvn_be_* 与 NVN_EV_WAIT；文件名是历史名，内容与 Metal 无关）
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

void nvn_hle_queue_enter(void *q);   // hle_nvn.c
void nvn_hle_piece_begun(void);
uint64_t s2a_guest_tick(void);       // 运行时：游戏的系统计数器（与游戏自己读到的同一个钟）

#define OPN(x) [x] = #x
static const char *const k_op_name[OP_NVN2_END_] = {
    OPN(OP_END), OPN(OP_JUMP), OPN(OP_BEGIN), OPN(OP_CALL), OPN(OP_SIGNAL_EVENT), OPN(OP_REPORT_COUNTER), OPN(OP_COPY_B2B), OPN(OP_UPDATE_UB),
    OPN(OP_SET_RT), OPN(OP_CLEAR_COLOR), OPN(OP_CLEAR_DS), OPN(OP_VIEWPORTS), OPN(OP_SCISSOR), OPN(OP_DEPTH_RANGE),
    OPN(OP_BIND_PROGRAM), OPN(OP_BIND_STATE), OPN(OP_BIND_VATTR), OPN(OP_BIND_VSTREAM), OPN(OP_BIND_VBUF),
    OPN(OP_BIND_UBO), OPN(OP_BIND_SSBO), OPN(OP_BIND_TEX), OPN(OP_BIND_SAMP),
    OPN(OP_STENCIL), OPN(OP_POLY_OFFSET), OPN(OP_DRAW), OPN(OP_DRAW_IDX), OPN(OP_DISPATCH), OPN(OP_BARRIER),
    OPN(OP_SET_TEX_POOL), OPN(OP_SET_SAMP_POOL), OPN(OP_COPY_B2T), OPN(OP_BLEND_COLOR), OPN(OP_COPY_T2B), OPN(OP_BIND_IMG), OPN(OP_COPY_T2T),
    OPN(OP_RESET_COUNTER), OPN(OP_CLEAR_TEX), OPN(OP_CLEAR_BUF), OPN(OP_DEPTH_CLAMP), OPN(OP_RENDER_COND), OPN(OP_FENCE_SYNC),
    OPN(OP_TF_BIND), OPN(OP_TF_STATE), OPN(OP_RAST_DISCARD), OPN(OP_VP_SWIZZLE), OPN(OP_BIND_TEX1), OPN(OP_PRIM_RESTART), OPN(OP_SET_PATCH_SIZE),
    OPN(OP_DRAW_TEX), OPN(OP_WAIT_SYNC), OPN(OP_ALPHA_REF),
    OPN(OP_PUSH_CONST), OPN(OP_DLSS), OPN(OP_PUSH_CONST_PTR), OPN(OP_MULTI_DRAW),
};
#undef OPN
// 加了新命令这里就红：名字表、接线表（docs/直连_Vulkan回放接线表.tsv）、nvn_be_exec 三处同批补。
_Static_assert(OP_COUNT_ == 52 && OP_NVN2_END_ == 56, "录制命令个数变了：补 k_op_name、接线表和 nvn_be_exec");
const char *rp_op_name(uint32_t op) { return op < OP_NVN2_END_ && k_op_name[op] ? k_op_name[op] : "OP_?"; }

// ---------- 提交 ----------
struct post { volatile uint32_t *val; uint32_t mode, v; uint64_t report; uint32_t type; };   // 完成后写事件值（mode 0 写 / 1 加）；report 非 0 = 计数器报告的写回地址
struct sub { struct post *p; int n, cap; uint64_t t_commit; };
// 分时读数（上屏那边每 5 秒取走一次清零）：一次队列提交里回放花的、交给后端花的、游戏等围栏花的、段从提交到完成隔了多久
static uint64_t now_ns(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec; }
static uint64_t g_pf[RP_PERF_N];
void rp_perf_take(uint64_t out[RP_PERF_N]) { for (int i = 0; i < RP_PERF_N; i++) out[i] = __atomic_exchange_n(&g_pf[i], 0, __ATOMIC_ACQ_REL); }
static void pf_add(int i, uint64_t v) { __atomic_fetch_add(&g_pf[i], v, __ATOMIC_RELAXED); }
static struct sub *g_sub;      // 当前段挂着的完成后副作用
static nvn_gpu_cmd g_cmd;      // 当前段（NULL = 后端没给出段：本次提交只走状态，不编码）
static nvn_gpu_cmd g_pre;      // 前置段：本次提交里资源同步用的传输（池镜像、贴图上传），先于 g_cmd 提交。用到才开
static uint64_t g_sub_serial;  // 第几次提交（资源按它判断「本次提交里已经用过」）
static uint64_t g_fence;       // 最近一次提交的栅栏值
static int g_ret_n;            // OP_CALL 嵌套深度

static void red(const char *fmt, const char *why) { char b[256]; snprintf(b, sizeof b, fmt, why); nvn_plat_log(NVN_PLAT_LOG_RED, "replay", b); }
static void pre_done(void *user, const nvn_gpu_done *d) { (void)user; if (d->status == NVN_GPU_DONE_FAILED) red("前置段失败：%s", d->why ? d->why : "?"); }

// 资源同步该录进哪一段。传输不能出现在渲染通道里，所以同步一律录进前置段，它在 GPU 上先于本次提交的全部通道执行。
// 前提是「同步的内容对本次提交里每个使用点都成立」：回放发生在游戏提交之后，游戏对池内存的写在提交前已经做完，这个前提成立；
// 例外是同一资源在本次提交里已经同步过又变了（命令流里按序的写、别的线程正在写下一帧）：那一次必须排在已录的绘制之后，
// 于是结束当前通道、录进主段（通道在下一笔绘制时重开）。last_sub：该资源上次同步所在的提交序号，由调用方持有。
nvn_gpu_cmd rp_xfer_cmd(uint64_t *last_sub) {
    if (!g_cmd) return NULL;
    if (*last_sub == g_sub_serial) { rp_pass_end(g_cmd); return g_cmd; }
    *last_sub = g_sub_serial;
    if (!g_pre) { nvn_gpu_err err = {0}; nvn_gpu_cmd_desc d = {0, "nvn submit pre"};
        if (!nvn_gpu_ok(nvn_gpu_cmd_begin(&d, &g_pre, &err))) { g_pre = NULL; rp_pass_end(g_cmd); return g_cmd; } }
    return g_pre;
}

static void sub_done(void *user, const nvn_gpu_done *d) {
    struct sub *s = user;
    if (s->t_commit) { pf_add(RP_PERF_DONE_NS, now_ns() - s->t_commit); pf_add(RP_PERF_DONE_N, 1); }
    if (d->status != NVN_GPU_DONE_FAILED)   // 没执行的段不做任何成功回写
        for (int i = 0; i < s->n; i++) {
            if (s->p[i].report) {   // 计数器记录 = {计数值, 时间}（各 8 字节）。时间取本段完成这一刻的游戏时钟；时间戳类的计数值就是时间，
                // 其余管线统计类计数值写 0（同 nvn_mtl.m 提交完成回调里的写法）。同一段里的多条报告现在拿到同一个时间：按报告所在位置给 GPU 时间要后端出段内时间戳，没接。
                uint64_t t = s2a_guest_tick(), rec[2] = {s->p[i].type == NVN_COUNTER_TYPE_TIMESTAMP || s->p[i].type == NVN_COUNTER_TYPE_TIMESTAMP_TOP ? t : 0, t};
                memcpy((void *)(uintptr_t)s->p[i].report, rec, sizeof rec);
                continue;
            }
            if (s->p[i].mode & 1) __atomic_fetch_add((uint32_t *)s->p[i].val, s->p[i].v, __ATOMIC_SEQ_CST);
            else __atomic_store_n((uint32_t *)s->p[i].val, s->p[i].v, __ATOMIC_SEQ_CST);
        }
    else red("提交段失败，本段的事件 / 计数器不回写：%s", d->why ? d->why : "?");
    free(s->p); free(s);
}

void nvn_be_sub_begin(void) {
    g_sub = calloc(1, sizeof *g_sub);
    nvn_gpu_err err = {0}; nvn_gpu_cmd_desc d = {0, "nvn submit"};
    g_cmd = NULL; g_pre = NULL; g_sub_serial++;
    if (!nvn_gpu_ok(nvn_gpu_cmd_begin(&d, &g_cmd, &err))) { g_cmd = NULL; static int said; if (!said++) red("开提交段失败（之后同样的失败不再逐条报）：%s", err.why); }
    rp_dirty_all();   // 新段：已发给后端的状态全部重发；rp_S / rp_R 不动
}

uint64_t nvn_be_sub_commit(void) {
    struct sub *s = g_sub; g_sub = NULL;
    rp_pass_flush(g_cmd);   // 打开的通道与待折清除不跨提交
    if (!g_cmd) {   // 没有段：副作用无处挂，直接按失败丢弃（不写假成功）
        if (s) { free(s->p); free(s); }
        if (g_pre) { nvn_gpu_cmd_abort(g_pre); g_pre = NULL; }
        return g_fence;
    }
    nvn_gpu_err err = {0}; uint64_t f = g_fence + 2;   // 前置段占 +1（没开就空着：时间线的值只要求递增），主段 +2
    if (g_pre) { nvn_gpu_cmd pc = g_pre; g_pre = NULL; if (!nvn_gpu_ok(nvn_gpu_cmd_commit(pc, g_fence + 1, pre_done, NULL, &err))) red("前置段提交失败：%s", err.why); }
    nvn_gpu_cmd c = g_cmd; g_cmd = NULL;
    // 契约：无论成败 done 恰好调一次（失败以 FAILED 调），所以 s 一定由 sub_done 释放
    uint64_t t0 = now_ns(); if (s) s->t_commit = t0;
    if (!nvn_gpu_ok(nvn_gpu_cmd_commit(c, f, sub_done, s, &err))) red("提交失败：%s", err.why);
    pf_add(RP_PERF_COMMIT_NS, now_ns() - t0); pf_add(RP_PERF_SUBS, 1);
    g_fence = f;
    rp_debug_dump_poll(&g_fence);   // 调试开关 nvk_dump：有登记才做事
    return f;
}

uint64_t nvn_be_last_fence(void) { return g_fence; }

int nvn_be_wait(uint64_t fence, uint64_t timeout_ns) {
    if (!fence) return 1;
    uint64_t t0 = now_ns();
    nvn_gpu_rc r = nvn_gpu_fence_wait(fence, timeout_ns, NULL);
    pf_add(RP_PERF_WAIT_NS, now_ns() - t0); pf_add(RP_PERF_WAIT_N, 1);
    // 时间线已失败：再等也不会完成。按「已结束」放行，让游戏线程不死等；失败本身已在 sub_done 报红
    return nvn_gpu_ok(r) || r.code == NVN_GPU_E_FAILED || r.code == NVN_GPU_E_DEVICE;
}

static void post_event(volatile uint32_t *val, uint32_t mode, uint32_t v) {
    struct sub *s = g_sub; if (!s || !val) return;
    if (s->n == s->cap) { int cap = s->cap ? s->cap * 2 : 8; struct post *np = realloc(s->p, (size_t)cap * sizeof *np); if (!np) return; s->p = np; s->cap = cap; }
    s->p[s->n++] = (struct post){val, mode, v, 0, 0};
}
static void post_report(uint64_t addr, uint32_t type) {
    struct sub *s = g_sub; if (!s || !addr) return;
    if (s->n == s->cap) { int cap = s->cap ? s->cap * 2 : 8; struct post *np = realloc(s->p, (size_t)cap * sizeof *np); if (!np) return; s->p = np; s->cap = cap; }
    s->p[s->n++] = (struct post){NULL, 0, 0, addr, type};
}

void nvn_be_sub_index(const uint64_t *h, int n) { (void)h; (void)n; }     // 存储前瞻索引：通道规划接上时再建
void nvn_be_exec_rest(const uint64_t *h, int n) { (void)h; (void)n; }

// ---------- 主循环 ----------
static int rec_bad(op_hdr h) { return h.size < 8 || (h.size & 7) || h.op >= OP_NVN2_END_ || h.op == OP_BEGIN; }

void nvn_be_exec(const uint8_t *p) {
    static int inited; if (!inited) { inited = 1; rp_state_reset(); }
    if (!p) return;
    for (;;) {
        op_hdr h; memcpy(&h, p, sizeof h);
        if (rec_bad(h)) { nvn_unimpl("rec", "bad_record", p); return; }   // 按这条列表的 END 处理
        const void *a = p + 8;
        switch (h.op) {
            case OP_END: return;
            case OP_JUMP: { const uint8_t *t; memcpy(&t, a, 8); p = t; continue; }
            case OP_CALL: { uint64_t t; memcpy(&t, a, 8);
                if (g_ret_n >= 64) { nvn_unimpl("rec", "call_depth_over_64", p); break; }
                g_ret_n++; nvn_be_exec((const uint8_t *)(uintptr_t)t); g_ret_n--;
                break; }
            case OP_SIGNAL_EVENT: { volatile uint32_t *val; uint32_t m, v; memcpy(&val, a, 8); memcpy(&m, (const uint8_t *)a + 8, 4); memcpy(&v, (const uint8_t *)a + 12, 4);
                if (m & NVN_EV_WAIT) nvn_unimpl("op", "OP_SIGNAL_EVENT+WAIT", p);   // GPU 侧等事件：跨队列顺序接上时做
                else post_event(val, m, v);
                break; }
            case OP_REPORT_COUNTER: { uint64_t t, ad; memcpy(&t, a, 8); memcpy(&ad, (const uint8_t *)a + 8, 8);
                if (t == NVN_COUNTER_TYPE_SAMPLES_PASSED) nvn_unimpl("op", "OP_REPORT_COUNTER+SAMPLES_PASSED", p);   // 遮挡计数：后端的遮挡查询没接，不写假结果
                else post_report(ad, (uint32_t)t);
                break; }
            case OP_DRAW: { p_draw t; rp_draw(g_cmd, draw_rec(a, h.size, &t), NULL, p); break; }
            case OP_DRAW_IDX: { p_draw_idx t; rp_draw(g_cmd, NULL, draw_idx_rec(a, h.size, &t), p); break; }
            case OP_SET_RT: { p_set_rt t; rp_pass_set_rt(g_cmd, set_rt_rec(a, h.size, &t)); break; }
            case OP_CLEAR_COLOR: rp_pass_clear_color(g_cmd, a, p); break;
            case OP_CLEAR_DS: rp_pass_clear_ds(g_cmd, a, p); break;
            case OP_BARRIER: { int32_t bits; memcpy(&bits, a, 4); rp_pass_barrier((uint32_t)bits); break; }
            case OP_COPY_B2T: rp_pass_flush(g_cmd); rp_op_copy_b2t(g_cmd, a, p); break;   // 传输在通道外
            case OP_UPDATE_UB: rp_op_update_ub(a, p); break;
            case OP_COPY_B2B: rp_op_copy_b2b(a, p); break;
            case OP_CLEAR_BUF: rp_op_clear_buf(a, p); break;
            case OP_FENCE_SYNC: { sync_t *s; memcpy(&s, a, 8); if (s) sync_publish(s, g_fence + 2); break; }   // 本次提交主段的栅栏值
            default:
                if (!rp_state_op(h.op, a, h.size)) nvn_unimpl("op", rp_op_name(h.op), p);
                break;
        }
        p += h.size;
    }
}

// 一次 NVN 队列提交（hle_nvn.c nvnQueueSubmitCommands）。跨队列停靠（等别的队列还没回放的信号）未接：见 OP_SIGNAL_EVENT+WAIT。
void nvn_be_submit(void *q, const uint64_t *h, int n) {
    nvn_hle_queue_enter(q);
    uint64_t t0 = now_ns();
    nvn_be_sub_begin(); nvn_hle_piece_begun();
    nvn_be_sub_index(h, n);
    for (int i = 0; i < n; i++) { nvn_be_exec_rest(h + i + 1, n - i - 1); nvn_be_exec((const uint8_t *)(uintptr_t)h[i]); }
    nvn_be_exec_rest(NULL, 0);
    nvn_be_sub_commit();
    pf_add(RP_PERF_SUBMIT_NS, now_ns() - t0);
}
