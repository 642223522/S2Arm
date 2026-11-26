// 全线程现场单测：起一条命名线程停在已知函数里，现场里要有它的名字、它停住的函数名，另写的 threads.txt 与日志一致；取完别的线程照常往下跑
#include "../src/native.h"
#include <pthread.h>
#include <stdarg.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
int s2a_dump_threads(const char *why);
module_t *module_of(const void *p) { (void)p; return NULL; }   // 桩：单测没有游戏模块，地址全走宿主符号
static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER; static pthread_cond_t cv = PTHREAD_COND_INITIALIZER; static volatile int go, parked, after;
__attribute__((noinline)) void t_tdump_marker_wait(void) {
    pthread_mutex_lock(&mu); parked = 1; while (!go) pthread_cond_wait(&cv, &mu); pthread_mutex_unlock(&mu);
    __asm__ volatile("" ::: "memory");
}
static void *body(void *a) { (void)a; pthread_setname_np("s2a-单测停住"); t_tdump_marker_wait(); after = 1; return NULL; }
static int fails;
static void check(const char *what, int ok) { printf("%s %s\n", ok ? "✓" : "✗", what); fails += !ok; }
int main(void) {
    char dir[] = "/tmp/t_tdumpXXXXXX"; if (!mkdtemp(dir)) return 1; setenv("S2A_DOCS", dir, 1);
    char lp[256]; snprintf(lp, sizeof lp, "%s/host.log", dir); g_s2a_logfd = open(lp, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    pthread_t t; pthread_create(&t, NULL, body, NULL);
    while (!parked) usleep(1000); usleep(20000);
    int n = s2a_dump_threads("单测");
    char p[256]; snprintf(p, sizeof p, "%s/threads.txt", dir); FILE *f = fopen(p, "r"); static char buf[1 << 20]; size_t len = f ? fread(buf, 1, sizeof buf - 1, f) : 0; if (f) fclose(f); buf[len] = 0;
    check("线程数 ≥ 2（主线程 + 停住线程）", n >= 2);
    check("threads.txt 有停住线程的名字「s2a-单测停住」", strstr(buf, "「s2a-单测停住」") != NULL);
    check("threads.txt 回溯里有它停住的函数 t_tdump_marker_wait", strstr(buf, "t_tdump_marker_wait") != NULL);
    check("threads.txt 有本线程（发起现场）一行", strstr(buf, "本线程，发起现场") != NULL);
    // 11-16 #55248c：系统库被抹名，帧括号里带「库名+库内偏移」、末尾列库基址与 UUID。期望用 dwarfdump --uuid 独立读本测试程序的 UUID，不经被测代码
    { char exe[1024]; uint32_t es = sizeof exe; char want[64] = "", cmd[1200], line[512];
      if (!_NSGetExecutablePath(exe, &es)) { snprintf(cmd, sizeof cmd, "dwarfdump --uuid '%s' 2>/dev/null", exe); FILE *q = popen(cmd, "r");
        if (q && fgets(line, sizeof line, q)) { char *u = strstr(line, "UUID: "); if (u) snprintf(want, 37, "%s", u + 6); } if (q) pclose(q); }
      const char *base = strrchr(exe, '/') ? strrchr(exe, '/') + 1 : exe; char needle[256]; snprintf(needle, sizeof needle, "库 %s 基址 0x", base);
      char *row = strstr(buf, needle);
      check("末尾库表有本测试程序一行「库 <名> 基址 0x…」", row != NULL);
      check("库表里本测试程序的 UUID = dwarfdump --uuid 读出的", want[0] && row && strstr(row, want) && strstr(row, want) < strchr(row, '\n'));
      snprintf(needle, sizeof needle, "t_tdump_marker_wait+0x"); char *f = strstr(buf, needle);
      snprintf(needle, sizeof needle, "（%s+0x", base);
      check("停住线程那一帧括号里带「库名+库内偏移」", f && strstr(f, needle) && strstr(f, needle) < strchr(f, '\n')); }
    check("threads.txt 有停住线程的全寄存器行 x0..x28（取证增强）", strstr(buf, "    x0 ") != NULL && strstr(buf, "    x28 ") != NULL);
    { FILE *g = fopen(lp, "r"); int lines = 0, ch; while (g && (ch = fgetc(g)) != EOF) lines += ch == '\n'; if (g) fclose(g);
      int k = 0; for (char *q = buf; *q; q++) k += *q == '\n';
      check("host.log 行数与 threads.txt 行数一致", lines == k && k > 0); }
    pthread_mutex_lock(&mu); go = 1; pthread_cond_signal(&cv); pthread_mutex_unlock(&mu); pthread_join(t, NULL);
    check("取完现场后被挂起的线程照常跑完", after == 1);
    unlink(p); unlink(lp); rmdir(dir);
    printf("%s t_tdump：%d 处不符（共 10 项）\n", fails ? "✗" : "✓", fails); return fails != 0;
}
