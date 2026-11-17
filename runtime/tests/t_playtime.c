// 游玩时间单测（runtime/include/s2a_playtime.h）：期望秒数都按口径手算（相邻上屏间隔 ≤1 秒且有焦点才计、首帧前不计、落盘取整秒余数留着），
// 不跑被测实现推期望。一局 = fork 一个子进程（模块状态是进程级的）；闪退 = 子进程不落盘直接 _exit。每例一个空的 S2A_DOCS 临时目录。
#include "../src/native.h"
#include "s2a_playtime.h"
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

#define S 1000000000ull
#define MS 1000000ull
static int fails;
static char g_dir[64];
#define WANT(cond) do { if (!(cond)) { printf("    不符：%s（行 %d）\n", #cond, __LINE__); _exit(1); } } while (0)
#define CASE(name, body) do { snprintf(g_dir, sizeof g_dir, "/tmp/t_playtime.XXXXXX"); if (!mkdtemp(g_dir)) { perror("mkdtemp"); return 1; } \
    setenv("S2A_DOCS", g_dir, 1); unsetenv("S2A_PLAYTIME"); \
    pid_t p = fork(); if (!p) { body; _exit(0); } int st; waitpid(p, &st, 0); \
    if (!WIFEXITED(st) || WEXITSTATUS(st)) { fails++; printf("✗ %s\n", name); } else printf("  ✓ %s\n", name); } while (0)
#define LAUNCH(body) do { pid_t q = fork(); if (!q) { body; _exit(0); } int qs; waitpid(q, &qs, 0); WANT(WIFEXITED(qs) && !WEXITSTATUS(qs)); } while (0)

// 从 t0 起每 step 纳秒上屏一帧，共 n 帧
static void frames(uint64_t t0, uint64_t step, int n, int focused) { for (int i = 0; i < n; i++) s2a_playtime_frame(t0 + (uint64_t)i * step, focused); }
static uint64_t secs(int64_t *last) { char p[128]; snprintf(p, sizeof p, "%s/playtime.json", g_dir); uint64_t s; int64_t l; s2a_playtime_read(p, &s, &l); if (last) *last = l; return s; }

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);   // fork 不复制缓冲；子进程 _exit 前的「不符」行要看得到
    CASE("首帧前不计、落盘取整秒、余数留到下次", {
        frames(100 * S, 500 * MS, 10, 1);              // 10 帧 = 9 段 × 0.5 秒 = 4.5 秒
        WANT(!s2a_playtime_flush_at(1000)); WANT(secs(NULL) == 4);
        s2a_playtime_frame(100 * S + 5 * S, 1);       // 再一段 0.5 秒：余 0.5 + 0.5 = 1 秒
        WANT(!s2a_playtime_flush_at(1001)); WANT(secs(NULL) == 5); });
    CASE("切后台：上屏中断 30 秒那段不计；失焦期间的帧不计", {
        frames(0, 100 * MS, 51, 1);                   // 0–5 秒：5 秒
        frames(35 * S, 100 * MS, 31, 1);              // 隔 30 秒（后台不上屏）回来：首段间隔 30 秒不计，之后 3 秒
        frames(38 * S + 100 * MS, 100 * MS, 20, 0);   // Mac 失焦还在出帧 2 秒：不计
        WANT(!s2a_playtime_flush_at(2000)); WANT(secs(NULL) == 8); });
    CASE("间隔边界：正好 1 秒计，1 秒零 1 纳秒不计", {
        s2a_playtime_frame(10 * S, 1); s2a_playtime_frame(11 * S, 1); s2a_playtime_frame(12 * S + 1, 1);
        WANT(!s2a_playtime_flush_at(1)); WANT(secs(NULL) == 1); });
    CASE("闪退：最后一次落盘之后的不计、之前的都在；下一局接着加", {
        LAUNCH({ frames(0, 100 * MS, 101, 1); s2a_playtime_flush_at(500);      // 10 秒，心跳落盘
                 frames(10 * S + 100 * MS, 100 * MS, 100, 1); s2a_playtime_flush_at(510);   // 再 10 秒，落盘
                 frames(20 * S + 100 * MS, 100 * MS, 50, 1); _exit(0); });     // 又玩 5 秒后闪退（没落盘）
        WANT(secs(NULL) == 20);
        LAUNCH({ frames(0, 100 * MS, 31, 1); s2a_playtime_flush_at(900); });   // 下一局 3 秒
        int64_t last; WANT(secs(&last) == 23); WANT(last == 900); });
    CASE("跨天：秒数累加，最近一次时刻取最后一次落盘；没攒满 1 秒不写、不动最近时刻", {
        int64_t day1 = 1763251200;            // 2025-11-16 00:00 UTC
        int64_t day2 = day1 + 86400 + 3600;   // 次日 01:00（宏参数里不能有逗号，分两行）
        LAUNCH({ frames(0, 1 * S, 61, 1); s2a_playtime_flush_at(day1); });       // 60 秒
        LAUNCH({ frames(0, 1 * S, 121, 1); s2a_playtime_flush_at(day2); s2a_playtime_frame(500 * S, 1); s2a_playtime_flush_at(day2 + 999); });
        int64_t last; WANT(secs(&last) == 180); WANT(last == day2); });
    CASE("S2A_PLAYTIME 指定文件（Mac 局写游戏库里这款的文件夹）；坏文件按 0 接着记", {
        char p[128]; snprintf(p, sizeof p, "%s/game-folder-playtime.json", g_dir); setenv("S2A_PLAYTIME", p, 1);
        FILE *f = fopen(p, "w"); fputs("not json", f); fclose(f);
        frames(0, 1 * S, 3, 1); WANT(!s2a_playtime_flush_at(42));
        uint64_t s; int64_t l; WANT(!s2a_playtime_read(p, &s, &l)); WANT(s == 2); WANT(l == 42); WANT(secs(NULL) == 0); });
    if (fails) printf("✗ t_playtime：%d 项不通\n", fails); else printf("✓ t_playtime：全过\n");
    return fails != 0;
}
