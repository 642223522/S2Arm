// iOS 后台通知只能关门，不能在 UIKit 主线程等在途图形调用：
// 一条调用故意占住（直到排空开始后才放），dm_gfx_suspend(1) 仍须在 100 ms 内返回。
// 「排空等旧调用」原先按墙钟判（排空用时 ≥ 100 ms，旧调用 300 ms 定时放）：负载高时主线程晚到排空、旧调用已放，排空不到 100 ms 就假红。
//   现在按事件判：旧调用只在排空开始之后才放；排空真正动手（dm_gfx_test_drain 被调）时旧调用必须已经离开
#include "../host/dm.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>

static _Atomic int entered, release_call, blocked_passed, left, drain_started, left_at_drain = -1;
extern void (*dm_gfx_test_drain)(void);
static void drain_noop(void) { atomic_store(&left_at_drain, atomic_load(&left)); }   // 排空等完在途调用后才调到这里：此刻旧调用应已离开

static uint64_t mono_ns(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec;
}

static void *inflight(void *unused) {
    (void)unused;
    dm_gfx_enter();
    atomic_store(&entered, 1);
    while (!atomic_load(&release_call)) usleep(1000);
    atomic_store(&left, 1);   // 先记「已离开」再真离开：排空若看到在途数归零，left 必已是 1
    dm_gfx_leave();
    return NULL;
}

static void *release_later(void *unused) {
    (void)unused;
    // 等主线程开始排空（兜底 30 秒：关门若错误地等旧调用，它到这里也会放，关门用时 ≥ 100 ms 照样判红），
    //   再给排空 50 ms 走进等待（负对照短窗：负载高时排空晚进等待，只会让「排空不等旧调用」漏检，不会假红），然后放旧调用
    for (int i = 0; i < 30000 && !atomic_load(&drain_started); i++) usleep(1000);
    usleep(50000);
    atomic_store(&release_call, 1);
    return NULL;
}

static void *new_call(void *unused) {
    (void)unused;
    dm_gfx_enter();
    atomic_store(&blocked_passed, 1);
    dm_gfx_leave();
    return NULL;
}

int main(void) {
    pthread_t api, timer, blocked;
    dm_gfx_test_drain = drain_noop;
    if (pthread_create(&api, NULL, inflight, NULL) || pthread_create(&timer, NULL, release_later, NULL)) {
        fprintf(stderr, "✗ t_nvn_suspend：测试线程起不来\n");
        return 1;
    }
    while (!atomic_load(&entered)) usleep(1000);

    uint64_t begin = mono_ns();
    dm_gfx_suspend(1);
    double elapsed_ms = (mono_ns() - begin) / 1e6;

    if (pthread_create(&blocked, NULL, new_call, NULL)) {
        fprintf(stderr, "✗ t_nvn_suspend：关门后的测试线程起不来\n");
        atomic_store(&release_call, 1); dm_gfx_suspend(0); pthread_join(timer, NULL); pthread_join(api, NULL);
        return 1;
    }
    usleep(50000);   // 负对照短窗：关门后新调用 50 ms 内没进来（负载高时新线程晚跑只会漏检，不会假红）
    int passed_before_drain = atomic_load(&blocked_passed);
    uint64_t drain_begin = mono_ns();
    atomic_store(&drain_started, 1);
    dm_gfx_suspend_drain();
    double drain_ms = (mono_ns() - drain_begin) / 1e6;
    int passed_after_drain = atomic_load(&blocked_passed);
    dm_gfx_suspend(0);
    pthread_join(timer, NULL);
    pthread_join(api, NULL);
    pthread_join(blocked, NULL);
    if (elapsed_ms >= 100.0 || passed_before_drain || atomic_load(&left_at_drain) != 1 || passed_after_drain || !atomic_load(&blocked_passed)) {
        fprintf(stderr, "✗ t_nvn_suspend：关门 <100 ms / 新调用被挡 / 排空等旧调用（排空动手时旧调用已离开）/ 排空后仍关 / 恢复后放行，实 %.1f ms / %d / %d（用时 %.1f ms）/ %d / %d\n",
                elapsed_ms, passed_before_drain, atomic_load(&left_at_drain), drain_ms, passed_after_drain, atomic_load(&blocked_passed));
        return 1;
    }
    printf("✓ t_nvn_suspend：5 项全过（后台关门 %.1f ms；排空等旧调用 %.1f ms；新调用到恢复后才放行）\n", elapsed_ms, drain_ms);
    return 0;
}
