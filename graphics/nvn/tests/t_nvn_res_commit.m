// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 驻留集改动排队、提交换锁（马车世界缺口 ④，nvn_mtl.m res_add / res_remove / res_commit，照上游参考实现（MIT）0c078130）。期望按语义手写：
//   ① 有人正在 commit（本测持 g_res_commit_mu 300 ms）时 res_add：不等它，< 50 ms 返回
//   ② 这时另一线程 res_commit：等那次 commit 做完才返回（≥ 200 ms）
//   ③ res_add + res_commit 后对象在驻留集里；res_remove + res_commit 后不在
//   ④ res_remove 之后、commit 之前，自己的引用放掉：对象还活着（队列持有它；Metal 驻留集自己也把移出的对象留到 commit，反证见下）；commit 之后才放
//   ⑤ 两个线程各加 100 个缓冲、各自 res_commit：200 个全在集里
//   反证：res_add 先取 g_res_commit_mu（加改动要等进行中的 commit，即原先的行为）→ ① 红。另测过 res_remove 改回直接 removeAllocation：④ 照样绿，
//   Metal 驻留集自己把移出的对象留到 commit，④ 只钉住「commit 前活着、之后放掉」这条语义，不单独证明队列
#include "../gfx/nvn/nvn_mtl.m"
#include <pthread.h>

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr,"SETUP FAIL %s:%d %s\n",__FILE__,__LINE__,#c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int ok=!!(c); failures+=!ok; printf("%s ",ok?"✓":"✗"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
static double now_ms(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6; }
static void *holder(void *a) { (void)a; pthread_mutex_lock(&g_res_commit_mu); usleep(300000); pthread_mutex_unlock(&g_res_commit_mu); return NULL; }
static double commit_ms;
static void *committer(void *a) { (void)a; double t = now_ms(); res_commit(); commit_ms = now_ms() - t; return NULL; }
static id<MTLBuffer> bufs[2][100];
static void *adder(void *a) { int k = (int)(intptr_t)a; @autoreleasepool { for (int i = 0; i < 100; i++) { bufs[k][i] = [g_dev newBufferWithLength:4096 options:MTLResourceStorageModeShared]; res_add(bufs[k][i]); } res_commit(); } return NULL; }

int main(void) { @autoreleasepool {
    setvbuf(stdout,NULL,_IOLBF,0); alarm(60); unsetenv("NXGAL_BE");
    mtl_init(); res_commit();
    {   // ① ②
        id<MTLBuffer> b = [g_dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
        pthread_t h, c; pthread_create(&h, NULL, holder, NULL); usleep(50000);
        double t = now_ms(); res_add(b); double add_ms = now_ms() - t;
        pthread_create(&c, NULL, committer, NULL); usleep(10000);
        pthread_join(h, NULL); pthread_join(c, NULL);
        CHECK(add_ms < 50, "① 别人 commit 中 res_add：%.2f ms（期望 < 50，不等）", add_ms);
        CHECK(commit_ms >= 200, "② 别人 commit 中 res_commit：%.0f ms（期望 ≥ 200，等那次做完）", commit_ms);
        CHECK([g_res containsAllocation:b], "③ res_add + res_commit 后在驻留集里");
        res_remove(b); res_commit();
        CHECK(![g_res containsAllocation:b], "③ res_remove + res_commit 后不在驻留集里");
    }
    {   // ④
        __weak id<MTLBuffer> w = nil;
        @autoreleasepool { id<MTLBuffer> b = [g_dev newBufferWithLength:4096 options:MTLResourceStorageModeShared]; w = b; res_add(b); res_commit(); res_remove(b); b = nil; }
        int alive_before = w != nil; res_commit(); int alive_after = w != nil;
        CHECK(alive_before && !alive_after, "④ res_remove 后、commit 前对象还活着 %d（期望 1），commit 后放掉 %d（期望 1）", alive_before, !alive_after);
    }
    {   // ⑤
        pthread_t t1, t2; pthread_create(&t1, NULL, adder, (void *)0); pthread_create(&t2, NULL, adder, (void *)1); pthread_join(t1, NULL); pthread_join(t2, NULL);
        int in = 0; for (int k = 0; k < 2; k++) for (int i = 0; i < 100; i++) in += [g_res containsAllocation:bufs[k][i]];
        CHECK(in == 200, "⑤ 两线程各加 100 个、各自 commit：在集里 %d（期望 200）", in);
    }
    printf("%s t_nvn_res_commit：%u 项，%u 项不符\n", failures ? "✗" : "✓", checks, failures);
    return failures != 0;
} }
