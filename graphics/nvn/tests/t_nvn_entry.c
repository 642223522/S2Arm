// NVN 汇编入口在游戏 sp 不对齐时不崩（11-17，graphics/nvn/gfx/nvn/nvn_entry.S）：只链 nvn_entry.S，槽表 / 实现表 / 回调都在本文件打桩。
// 苹果芯片对「以 sp 为基址的读写」查 16 字节对齐，Horizon 不查：游戏 sp 末位是 8 时，原先这三个入口开头一压栈就 SIGBUS。
// 每项各在子进程里跑两遍（sp 对齐 / 错开 8 字节），期望手写：
//   ① nvn_unimpl_entry（x16 = 槽 1）：nvn_unimpl_c 收到 (槽 1 地址, 11, 22, 33)、返回 0，不崩、调后 sp 原样
//   ② nvn_prof_entry（x16 = 槽 2，实现 = 八参求和且开头压栈）：返回 1+…+8 = 36，计时累加到 nvn_prof_ticks[2]
//   ③ nvn_stackarg_entry（x16 = 槽 3，实现 = 十参求和，第 9、10 个在调用方栈 [sp] / [sp, #8]）：返回 36 + 100 + 200 = 336
//   ④ 前提自证：sp 错开 8 字节直接调开头压栈的实现 → 被信号杀（不是这个就说明本机不查对齐，上面的「不崩」证明不了什么）
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

struct nvn_slot_t { void *fn; void *pad; } nvn_slot[4];
void *nvn_real[4], *nvn_big_real[4], *nvn_sa_real[4];
uint64_t nvn_prof_ticks[4];
int g_nvn_qlog;
static uint64_t got[4];
uint64_t nvn_unimpl_c(void *slot, uint64_t a, uint64_t b, uint64_t c) { got[0] = (uint64_t)slot; got[1] = a; got[2] = b; got[3] = c; return 0; }
void nvn_qlog_c(void) {}
__asm__(".text\n.p2align 2\n.globl _dm_bigstack_enter\n_dm_bigstack_enter:\n    br x16\n");
extern void nvn_unimpl_entry(void), nvn_prof_entry(void), nvn_stackarg_entry(void);

__attribute__((noinline)) static long sum8(long a, long b, long c, long d, long e, long f, long g, long h) {   // 开头必压栈：局部数组落栈
    volatile long buf[8] = {a, b, c, d, e, f, g, h}; long s = 0; for (int i = 0; i < 8; i++) s += buf[i];
    return s + (long)getpid() * 0;
}
__attribute__((noinline)) static long sum10(long a, long b, long c, long d, long e, long f, long g, long h, long i, long j) {
    volatile long buf[2] = {i, j};
    return sum8(a, b, c, d, e, f, g, h) + buf[0] + buf[1];
}
// sp 往下挪 off 字节（16 = 对齐，24 = 错开 8），在新 sp 处放两个栈参 100 / 200，x0..x7 = 1..8、x16 = slot，调 fn；返回 x0，*sp_ok = 调后 sp 原样
static long call_at(void *fn, void *slot, long off, int *sp_ok) {
    long r; uint64_t before, after;
    __asm__ volatile(
        "mov %[bf], sp\n"
        "sub sp, sp, %[off]\n"
        "mov x9, #100\n mov x10, sp\n str x9, [x10]\n mov x9, #200\n str x9, [x10, #8]\n"
        "mov x0, #1\n mov x1, #2\n mov x2, #3\n mov x3, #4\n mov x4, #5\n mov x5, #6\n mov x6, #7\n mov x7, #8\n"
        "mov x16, %[sl]\n"
        "blr %[fn]\n"
        "add sp, sp, %[off]\n"
        "mov %[af], sp\n"
        "mov %[r], x0\n"
        : [r] "=&r"(r), [bf] "=&r"(before), [af] "=&r"(after)
        : [fn] "r"(fn), [sl] "r"(slot), [off] "r"(off)
        : "x0", "x1", "x2", "x3", "x4", "x5", "x6", "x7", "x8", "x9", "x10", "x11", "x12", "x13", "x14", "x15", "x16", "x17", "x30", "memory", "cc");
    *sp_ok = before == after; return r;
}
static int bad;
#define CHECK(c, ...) do { if (!(c)) { bad++; printf("✗ "); printf(__VA_ARGS__); printf("\n"); } } while (0)
// 子进程里跑 body，返回 0 = 期望全对；信号 = -信号号
static int child(int (*body)(long), long off) {
    fflush(stdout); pid_t p = fork();
    if (p == 0) _exit(body(off));
    int st; waitpid(p, &st, 0);
    return WIFSIGNALED(st) ? -WTERMSIG(st) : WEXITSTATUS(st);
}
static int unimpl(long off) {
    int ok; long r = call_at((void *)nvn_unimpl_entry, &nvn_slot[1], off, &ok);
    return !(r == 0 && ok && got[0] == (uint64_t)&nvn_slot[1] && got[1] == 1 && got[2] == 2 && got[3] == 3);
}
static int prof(long off) {
    nvn_real[2] = (void *)sum8;
    int ok; long r = call_at((void *)nvn_prof_entry, &nvn_slot[2], off, &ok);
    return !(r == 36 && ok && nvn_prof_ticks[2] > 0);
}
static int stackarg(long off) {
    nvn_sa_real[3] = (void *)sum10;
    int ok; long r = call_at((void *)nvn_stackarg_entry, &nvn_slot[3], off, &ok);
    return !(r == 336 && ok);
}
static int raw(long off) { int ok; call_at((void *)sum10, &nvn_slot[3], off, &ok); return 0; }

int main(void) {
    static const struct { const char *name; int (*body)(long); } t[] = {{"① nvn_unimpl_entry", unimpl}, {"② nvn_prof_entry", prof}, {"③ nvn_stackarg_entry", stackarg}};
    for (unsigned i = 0; i < 3; i++)
        for (long off = 16; off <= 24; off += 8) {
            int rc = child(t[i].body, off);
            CHECK(rc == 0, "%s sp %s：期望不崩、返回值对、sp 原样 → %s %d", t[i].name, off % 16 ? "错开 8" : "对齐", rc < 0 ? "信号" : "不符", rc < 0 ? -rc : rc);
        }
    int rc = child(raw, 24);
    CHECK(rc < 0, "④ 前提：sp 错开 8 直接调开头压栈的实现应被信号杀 → 退出 %d", rc);
    printf("%s t_nvn_entry：%d 处不符（3 个入口 × 对齐 / 不对齐 + 前提自证）\n", bad ? "✗" : "✓", bad);
    return bad != 0;
}
