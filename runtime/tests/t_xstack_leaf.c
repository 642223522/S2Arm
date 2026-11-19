// 叶子桩（xstack.c sw_xstack_wrap 对 k_leaf 名单 + entry.S xs_leaf_entry）单测，11-17 D-DVZZ：
//   客体 sp 不是 16 字节对齐时（Horizon 不查，苹果芯片以 sp 为基址的访存要求对齐），宿主叶子函数开头一压栈就 SIGBUS。
// 期望（手写）：① 名单里的名字（memcpy / memmove / memset / strlen）拿到的是桩、不是裸函数；② 经桩、sp 故意错开 8 字节调一个开头压栈的函数：
//   不崩、返回值对、调完 sp 原样恢复；③ sp 对齐时同样对；④ 反证：sp 错开 8 字节直接调裸函数 → 子进程 SIGBUS（证明这个夹具真能触发对齐异常）
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
void *sw_xstack_wrap(const char *name, void *fn);
void *sw_xstack_leaf(const char *name, void *fn);
#include <time.h>
__attribute__((noinline)) long add1(long x, long y) { return x + y; }
const char *s2a_xs_leaf_name(unsigned i);
extern const uint32_t xs_leaf_stubs[];
// entry.S 别的入口（门、线程起点、惰性取核钩子）引用的运行时符号：本测不走那些入口，给占位定义让它链得上
int g_lazy_core;
void gate_dispatch(void) {} void s2a_guest_return(void) {} void s2a_touch_body(void) {} void sw_thread_returned(void) {}
__attribute__((noinline)) static long pushes(long a, long b) {   // 开头必压栈：调一个外部函数、局部数组落栈
    volatile char buf[64]; for (int i = 0; i < 64; i++) buf[i] = (char)(a + i);
    return a + b + buf[3] + (long)getpid() * 0;
}
// 把 sp 往下挪 off 字节（off = 8 → 不对齐），调 fn(a, b)，恢复 sp；返回值、调后 sp 是否原样
static long call_at(void *fn, long a, long b, long off, int *sp_ok) {
    long r; uint64_t before, after;
    __asm__ volatile(
        "mov %[bf], sp\n"
        "sub sp, sp, %[off]\n"
        "mov x0, %[a]\n mov x1, %[b]\n"
        "blr %[fn]\n"
        "add sp, sp, %[off]\n"
        "mov %[af], sp\n"
        "mov %[r], x0\n"
        : [r] "=&r"(r), [bf] "=&r"(before), [af] "=&r"(after)
        : [fn] "r"(fn), [a] "r"(a), [b] "r"(b), [off] "r"(off)
        : "x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7", "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15", "x16", "x17", "x30", "memory", "cc");
    *sp_ok = before == after; return r;
}
static int bad;
#define CHECK(c, ...) do { if (!(c)) { bad++; printf("✗ "); printf(__VA_ARGS__); printf("\n"); } } while (0)
int main(void) {
    void *raw = (void *)pushes;
    // ① 整份叶子名单逐个：拿到的是叶子桩（落在 xs_leaf_stubs 里），不是裸函数、也不是切栈桩
    unsigned n = 0;
    for (const char *nm; (nm = s2a_xs_leaf_name(n)); n++) {
        uintptr_t s = (uintptr_t)sw_xstack_wrap(nm, raw), lo = (uintptr_t)xs_leaf_stubs;
        CHECK(s != (uintptr_t)raw && s >= lo && s < lo + 8192 * 8, "① %s 应拿到叶子桩", nm);
    }
    CHECK(n >= 50, "① 叶子名单应有 50 个以上名字（实 %u）", n);
    void *stub = sw_xstack_wrap("memmove", raw);
    for (long off = 16; off <= 24; off += 8) {   // 16 = 对齐，24 = 错开 8 字节
        pid_t p = fork();
        if (p == 0) { int ok; long r = call_at(stub, 5, 7, off, &ok); _exit(r == 5 + 7 + 8 && ok ? 0 : 3); }
        int st; waitpid(p, &st, 0);
        CHECK(WIFEXITED(st) && WEXITSTATUS(st) == 0, "%s sp 经桩调：应不崩、返回 20、sp 原样（实 %s %d）", off % 16 ? "② 不对齐" : "③ 对齐",
              WIFSIGNALED(st) ? "信号" : "退出", WIFSIGNALED(st) ? WTERMSIG(st) : WEXITSTATUS(st));
    }
    pid_t p = fork();
    if (p == 0) { int ok; call_at(raw, 5, 7, 24, &ok); _exit(0); }
    int st; waitpid(p, &st, 0);
    CHECK(WIFSIGNALED(st) && (WTERMSIG(st) == SIGBUS || WTERMSIG(st) == SIGSEGV), "④ 反证：不对齐 sp 直接调裸函数应崩（实 %s %d）", WIFSIGNALED(st) ? "信号" : "退出", WIFSIGNALED(st) ? WTERMSIG(st) : WEXITSTATUS(st));
    // ⑤ 微基准（11-17 维护者：每帧上万次，量 sp 对齐时经桩每次多几纳秒，写进提交说明；不设阈值以外的判据，只防数量级出错）
    {
        __attribute__((noinline)) long add1(long x, long y);
        void *astub = sw_xstack_leaf("bench_add", (void *)add1);
        long (*direct)(long, long) = add1, (*viastub)(long, long) = (long (*)(long, long))astub;
        enum { N = 20000000 }; volatile long acc = 0; struct timespec t0, t1, t2;
        clock_gettime(CLOCK_MONOTONIC, &t0); for (long i = 0; i < N; i++) acc += direct(i, 1);
        clock_gettime(CLOCK_MONOTONIC, &t1); for (long i = 0; i < N; i++) acc += viastub(i, 1);
        clock_gettime(CLOCK_MONOTONIC, &t2);
        double d0 = ((t1.tv_sec - t0.tv_sec) * 1e9 + (t1.tv_nsec - t0.tv_nsec)) / N, d1 = ((t2.tv_sec - t1.tv_sec) * 1e9 + (t2.tv_nsec - t1.tv_nsec)) / N;
        printf("⑤ 微基准：直接调 %.2f ns/次、经叶子桩（sp 对齐）%.2f ns/次，多 %.2f ns/次（%d 次，acc %ld）\n", d0, d1, d1 - d0, N, (long)acc);
        CHECK(d1 - d0 < 20, "⑤ 经叶子桩每次多出的时间应远小于 20 ns（实 %.2f）", d1 - d0);
    }
    printf("%s t_xstack_leaf：%d 项不通\n", bad ? "✗" : "✓", bad);
    return bad != 0;
}
