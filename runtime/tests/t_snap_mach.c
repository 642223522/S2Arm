// 即时存档：停在游戏代码里（忙等、不进门）的线程按 Mach 现场挪到另一条线程接着跑（thread.c 冻结时 Mach 挂住取现场、s2a_snap_unfreeze 写回）。
//   这里单测这套机制本身：工作线程跑 LDXR/STXR 原子自增的死循环（忙等、随时可能停在独占对中间）；主线程把它挂住、取全现场（通用寄存器 / sp / pc / 标志 /
//   q0–q31 / fpsr / fpcr），另起一条线程挂住、中止它的等待、整份写入现场、放行。期望值直接推出、不用被测代码算：
//   ① 原工作线程一直挂着，计数只可能由新线程涨；② 新线程从原指令接着跑，计数继续增长；③ 停在独占对中间时 STXR 失败重试，是正常语义，不影响 ②。
#include <mach/mach.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
static volatile uint64_t g_cnt;
static int bad, cnt;
#define EQ(name, ok) do { cnt++; if (!(ok)) { bad++; printf("✗ %s\n", name); } } while (0)
static void *spin(void *a) {   // 忙等：LDXR/STXR 自增，永不进系统调用
    (void)a;
    __asm__ volatile(
        "1: ldxr x9, [%0]\n"
        "   add x9, x9, #1\n"
        "   stxr w10, x9, [%0]\n"
        "   cbnz w10, 1b\n"
        "   b 1b\n" :: "r"(&g_cnt) : "x9", "x10", "memory");
    return NULL;
}
static void *park(void *a) { (void)a; for (;;) pause(); return NULL; }
int main(void) {
    pthread_t w, v; pthread_create(&w, NULL, spin, NULL);
    for (int i = 0; i < 30000 && !g_cnt; i++) usleep(1000);   // 等忙等线程真跑起来（原先睡 200 ms 当它在跑：负载高时还没上 CPU）
    mach_port_t wp = pthread_mach_thread_np(w);
    EQ("挂住工作线程", thread_suspend(wp) == KERN_SUCCESS);
    arm_thread_state64_t st; mach_msg_type_number_t c1 = ARM_THREAD_STATE64_COUNT; arm_neon_state64_t ns; mach_msg_type_number_t c2 = ARM_NEON_STATE64_COUNT;
    EQ("取通用寄存器现场", thread_get_state(wp, ARM_THREAD_STATE64, (thread_state_t)&st, &c1) == KERN_SUCCESS);
    EQ("取向量寄存器现场", thread_get_state(wp, ARM_NEON_STATE64, (thread_state_t)&ns, &c2) == KERN_SUCCESS);
    uint64_t pc = __darwin_arm_thread_state64_get_pc(st), c0 = g_cnt;
    usleep(100000);
    EQ("挂住期间计数不动", g_cnt == c0);
    // 新线程：先让它进内核等着，再挂住、中止等待、整份写现场、放行
    pthread_create(&v, NULL, park, NULL); usleep(50000);
    mach_port_t vp = pthread_mach_thread_np(v);
    EQ("挂住新线程", thread_suspend(vp) == KERN_SUCCESS);
    thread_abort(vp);
    EQ("写入通用寄存器现场", thread_set_state(vp, ARM_THREAD_STATE64, (thread_state_t)&st, ARM_THREAD_STATE64_COUNT) == KERN_SUCCESS);
    EQ("写入向量寄存器现场", thread_set_state(vp, ARM_NEON_STATE64, (thread_state_t)&ns, ARM_NEON_STATE64_COUNT) == KERN_SUCCESS);
    EQ("放行新线程", thread_resume(vp) == KERN_SUCCESS);
    for (int i = 0; i < 30000 && g_cnt <= c0; i++) usleep(1000);   // 等计数真涨（原先睡 200 ms 再比：负载高时新线程还没被调度到 → 假红）
    uint64_t c1v = g_cnt;
    EQ("新线程从原指令接着跑：计数继续增长", c1v > c0);
    { arm_thread_state64_t s2; mach_msg_type_number_t n2 = ARM_THREAD_STATE64_COUNT; thread_suspend(vp); thread_get_state(vp, ARM_THREAD_STATE64, (thread_state_t)&s2, &n2);
      uint64_t p2 = __darwin_arm_thread_state64_get_pc(s2); EQ("新线程的 PC 落在原忙等循环里（距原 PC 不超过 5 条指令）", p2 >= pc - 20 && p2 <= pc + 20); thread_resume(vp); }
    printf("%s t_snap_mach：%d / %d 项通过（挂住时计数 %llu、放行后 %llu）\n", bad ? "✗" : "✓", cnt - bad, cnt, (unsigned long long)c0, (unsigned long long)c1v);
    fflush(stdout); _exit(bad != 0);
}
