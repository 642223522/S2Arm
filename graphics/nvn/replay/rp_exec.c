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

void nvn_hle_queue_enter(void *q);   // hle_nvn.c
void nvn_hle_piece_begun(void);

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
struct post { volatile uint32_t *val; uint32_t mode, v; };   // 完成后写事件值：mode 0 写 / 1 加
struct sub { struct post *p; int n, cap; };
static struct sub *g_sub;      // 当前段挂着的完成后副作用
static nvn_gpu_cmd g_cmd;      // 当前段（NULL = 后端没给出段：本次提交只走状态，不编码）
static uint64_t g_fence;       // 最近一次提交的栅栏值
static int g_ret_n;            // OP_CALL 嵌套深度

static void red(const char *fmt, const char *why) { char b[256]; snprintf(b, sizeof b, fmt, why); nvn_plat_log(NVN_PLAT_LOG_RED, "replay", b); }

static void sub_done(void *user, const nvn_gpu_done *d) {
    struct sub *s = user;
    if (d->status != NVN_GPU_DONE_FAILED)   // 没执行的段不做任何成功回写
        for (int i = 0; i < s->n; i++) {
            if (s->p[i].mode & 1) __atomic_fetch_add((uint32_t *)s->p[i].val, s->p[i].v, __ATOMIC_SEQ_CST);
            else __atomic_store_n((uint32_t *)s->p[i].val, s->p[i].v, __ATOMIC_SEQ_CST);
        }
    else red("提交段失败，本段的事件 / 计数器不回写：%s", d->why ? d->why : "?");
    free(s->p); free(s);
}

void nvn_be_sub_begin(void) {
    g_sub = calloc(1, sizeof *g_sub);
    nvn_gpu_err err = {0}; nvn_gpu_cmd_desc d = {0, "nvn submit"};
    g_cmd = NULL;
    if (!nvn_gpu_ok(nvn_gpu_cmd_begin(&d, &g_cmd, &err))) { g_cmd = NULL; red("开提交段失败：%s", err.why); }
    rp_dirty_all();   // 新段：已发给后端的状态全部重发；rp_S / rp_R 不动
}

uint64_t nvn_be_sub_commit(void) {
    struct sub *s = g_sub; g_sub = NULL;
    rp_pass_flush(g_cmd);   // 打开的通道与待折清除不跨提交
    if (!g_cmd) {   // 没有段：副作用无处挂，直接按失败丢弃（不写假成功）
        if (s) { free(s->p); free(s); }
        return g_fence;
    }
    nvn_gpu_err err = {0}; uint64_t f = g_fence + 1;
    nvn_gpu_cmd c = g_cmd; g_cmd = NULL;
    // 契约：无论成败 done 恰好调一次（失败以 FAILED 调），所以 s 一定由 sub_done 释放
    if (!nvn_gpu_ok(nvn_gpu_cmd_commit(c, f, sub_done, s, &err))) red("提交失败：%s", err.why);
    g_fence = f;
    return f;
}

uint64_t nvn_be_last_fence(void) { return g_fence; }

int nvn_be_wait(uint64_t fence, uint64_t timeout_ns) {
    if (!fence) return 1;
    nvn_gpu_rc r = nvn_gpu_fence_wait(fence, timeout_ns, NULL);
    // 时间线已失败：再等也不会完成。按「已结束」放行，让游戏线程不死等；失败本身已在 sub_done 报红
    return nvn_gpu_ok(r) || r.code == NVN_GPU_E_FAILED || r.code == NVN_GPU_E_DEVICE;
}

static void post_event(volatile uint32_t *val, uint32_t mode, uint32_t v) {
    struct sub *s = g_sub; if (!s || !val) return;
    if (s->n == s->cap) { int cap = s->cap ? s->cap * 2 : 8; struct post *np = realloc(s->p, (size_t)cap * sizeof *np); if (!np) return; s->p = np; s->cap = cap; }
    s->p[s->n++] = (struct post){val, mode, v};
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
            case OP_SET_RT: { p_set_rt t; rp_pass_set_rt(g_cmd, set_rt_rec(a, h.size, &t)); break; }
            case OP_CLEAR_COLOR: rp_pass_clear_color(g_cmd, a, p); break;
            case OP_CLEAR_DS: rp_pass_clear_ds(g_cmd, a, p); break;
            case OP_BARRIER: { int32_t bits; memcpy(&bits, a, 4); rp_pass_barrier((uint32_t)bits); break; }
            case OP_COPY_B2T: rp_pass_flush(g_cmd); rp_op_copy_b2t(g_cmd, a, p); break;   // 传输在通道外
            case OP_UPDATE_UB: rp_op_update_ub(a, p); break;
            case OP_COPY_B2B: rp_op_copy_b2b(a, p); break;
            case OP_CLEAR_BUF: rp_op_clear_buf(a, p); break;
            case OP_FENCE_SYNC: { sync_t *s; memcpy(&s, a, 8); if (s) sync_publish(s, g_fence + 1); break; }
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
    nvn_be_sub_begin(); nvn_hle_piece_begun();
    nvn_be_sub_index(h, n);
    for (int i = 0; i < n; i++) { nvn_be_exec_rest(h + i + 1, n - i - 1); nvn_be_exec((const uint8_t *)(uintptr_t)h[i]); }
    nvn_be_exec_rest(NULL, 0);
    nvn_be_sub_commit();
}
