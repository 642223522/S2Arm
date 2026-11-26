// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 驻留集改动排队、提交换锁（马车世界缺口 ④，nvn_mtl.m res_add / res_remove / res_commit，照上游参考实现（MIT）0c078130）。期望按语义手写：
//   ① 有人正在 commit（本测的持锁线程持 g_res_commit_mu，直到本测放行）时 res_add：不等它——持锁期间就返回
//   ② 这时另一线程 res_commit：等那次 commit 做完才返回——返回时持锁线程已放锁
//   （原先持锁 300 ms、按墙钟判 res_add < 50 ms、res_commit ≥ 200 ms，负载高时线程晚被调度就假红；现在按「持锁期间 / 放锁之后」这两个事件判）
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
// 持锁线程：拿到 g_res_commit_mu 后置 held，一直持着直到测试置 release（不按 300 ms 定时放）；放锁前先置 unlocked
static _Atomic int held, release_hold, add_done, commit_started, commit_after_unlock = -1, unlocked;
static id<MTLBuffer> add_buf;
static void *holder(void *a) { (void)a; pthread_mutex_lock(&g_res_commit_mu); atomic_store(&held, 1);
    while (!atomic_load(&release_hold)) usleep(1000);
    atomic_store(&unlocked, 1); pthread_mutex_unlock(&g_res_commit_mu); return NULL; }
static void *adder1(void *a) { (void)a; res_add(add_buf); atomic_store(&add_done, 1); return NULL; }
// 返回时记下持锁线程是否已放锁：放锁之前就返回 = 没等那次 commit
static void *committer(void *a) { (void)a; atomic_store(&commit_started, 1); res_commit(); atomic_store(&commit_after_unlock, atomic_load(&unlocked)); return NULL; }
// 等条件成立，兜底 30 秒；返回条件是否成立
#define WAIT30(c) ({ int ok_ = 0; for (int w_ = 0; w_ < 3000 && !(ok_ = !!(c)); w_++) usleep(10000); ok_; })
static id<MTLBuffer> bufs[2][100];
static void *adder(void *a) { int k = (int)(intptr_t)a; @autoreleasepool { for (int i = 0; i < 100; i++) { bufs[k][i] = [g_dev newBufferWithLength:4096 options:MTLResourceStorageModeShared]; res_add(bufs[k][i]); } res_commit(); } return NULL; }

int main(void) { @autoreleasepool {
    setvbuf(stdout,NULL,_IOLBF,0); alarm(60); unsetenv("NXGAL_BE");
    mtl_init(); res_commit();
    {   // ① ②
        id<MTLBuffer> b = [g_dev newBufferWithLength:4096 options:MTLResourceStorageModeShared]; add_buf = b;
        // 原先睡 50 ms 当「持锁线程已拿到锁」：负载高时还没拿到就往下走。现在等 held 置位（兜底 30 秒）
        pthread_t h, c, ad; pthread_create(&h, NULL, holder, NULL); REQUIRE(WAIT30(atomic_load(&held)));
        // ①：res_add 在另一线程跑，锁一直持着；30 秒内返回 = 不等那次 commit（等的话要到放锁才回）
        pthread_create(&ad, NULL, adder1, NULL); int add_while_held = WAIT30(atomic_load(&add_done)) && !atomic_load(&unlocked);
        // ②：res_commit 起跑后给它 20 ms 走到锁上（负对照短窗：负载高时它晚到锁，只会让「没等就返回」的错漏检，不会假红），再放锁
        pthread_create(&c, NULL, committer, NULL); REQUIRE(WAIT30(atomic_load(&commit_started))); usleep(20000);
        atomic_store(&release_hold, 1);
        pthread_join(h, NULL); pthread_join(c, NULL); pthread_join(ad, NULL);
        CHECK(add_while_held, "① 别人 commit 中 res_add：持锁期间就返回 %d（期望 1，不等）", add_while_held);
        CHECK(atomic_load(&commit_after_unlock) == 1, "② 别人 commit 中 res_commit：返回时那次 commit 已做完（持锁线程已放锁）%d（期望 1）", atomic_load(&commit_after_unlock));
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
