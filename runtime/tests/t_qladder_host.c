// 档位梯子宿主单测（runtime/src/qladder_host.c）。期望手算：
//   帧率归游戏的款（没有 60 帧补丁 / 60 帧没开）梯子不跑、不压帧；60 帧靠补丁的款每局从 60 帧起（放开 = s2a_fps_hold(0)），
//   旧版留下的 ladder.txt（哪怕记着底档）不读也不写（#1688：一局掉帧之后每局都压在 30 帧）；
//   局内一直慢、有 GPU 读数 → 压回 30 帧（hold 1）并告诉玩家一次（原因 4）；没有 GPU 读数 → 不降；
//   玩家点「再试 60 帧」（s2a_ql_retry60）→ 下一帧放开（hold 0），不再弹「已恢复」；梯子从头到尾不改运行模式（S2A_DOCKED 原样、不调 s2a_console_mode_set）。
#include "native.h"
#include "s2a_qladder.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
static int g_fps, g_hold = -1, g_mode_sets, g_notes, g_gpu_on;   // g_hold：最后一次 s2a_fps_hold（-1 没调）；g_notes：s2a_ios_fps_capped(4) 次数
static double g_gpu;
int s2a_fps_real_source(void) { return g_fps; } int s2a_fps_enabled(void) { return g_fps; } void s2a_fps_hold(int hold) { g_hold = hold; }
int s2a_widen_game(void) { return 0; } void s2a_console_mode_set(int docked) { (void)docked; g_mode_sets++; } int s2a_console_mode(void) { return -1; }
void s2a_ios_fps_capped(int reason) { g_notes += reason == 4 ? 1 : 100; }   // 「已恢复」（0）记 100，一眼看出不该弹的弹了
double s2a_gpu_busy_ms(void) { return g_gpu_on ? g_gpu : -1; }
void s2a_ql_host_frame(uint64_t now, int game, uint64_t dt, int game_itv); void s2a_ql_retry60(void);
static int bad;
// 一种情况一个子进程（梯子状态是进程内静态）：fps = 60 帧靠补丁与否；ladder = 旧版 ladder.txt 内容（NULL 没有）；gpu = 有没有 GPU 读数；
//   slow_s：局内慢帧（10 帧/秒、GPU 忙 90%）喂几秒；retry：之后点「再试 60 帧」再喂一帧。输出「压帧 弹提示 切模式次数 S2A_DOCKED ladder.txt」
static void one(const char *why, int fps, const char *ladder, int gpu, int slow_s, int retry, const char *want) {
    char dir[] = "/tmp/t_qladder_host.XXXXXX"; if (!mkdtemp(dir)) { printf("✗ 建临时目录失败\n"); bad++; return; }
    char p[600]; snprintf(p, sizeof p, "%s/ladder.txt", dir);
    if (ladder) { FILE *f = fopen(p, "w"); fputs(ladder, f); fclose(f); }
    int fd[2]; if (pipe(fd)) { bad++; return; }
    pid_t pid = fork();
    if (!pid) { close(fd[0]); setenv("S2A_DOCS", dir, 1); unsetenv("S2A_AUTOPLAY"); unsetenv("S2A_LADDER"); setenv("S2A_DOCKED", "0", 1);
        g_fps = fps; g_gpu_on = gpu;
        uint64_t now = 1000000000ull; s2a_ql_host_frame(now, 0, 16666667ull, 1);
        for (int i = 0; i < slow_s * 10; i++) { now += 100000000ull; g_gpu += 90; s2a_ql_host_frame(now, 1, 100000000ull, 1); }
        if (retry) { s2a_ql_retry60(); now += 16666667ull; s2a_ql_host_frame(now, 1, 16666667ull, 1); }
        FILE *f = fopen(p, "r"); char lt[32] = "-"; if (f) { if (!fgets(lt, sizeof lt, f)) lt[0] = 0; fclose(f); lt[strcspn(lt, "\n")] = 0; }
        const char *d = getenv("S2A_DOCKED"); char out[96]; snprintf(out, sizeof out, "%d %d %d %s %s", g_hold, g_notes, g_mode_sets, d ? d : "-", lt);
        write(fd[1], out, strlen(out)); _exit(0); }
    close(fd[1]); char got[96] = {0}; read(fd[0], got, sizeof got - 1); close(fd[0]); waitpid(pid, 0, 0);
    unlink(p); rmdir(dir);
    int ok = !strcmp(got, want); bad += !ok;
    printf("%s %s：期望「压帧 弹提示 切模式 S2A_DOCKED ladder.txt」%s → 实 %s\n", ok ? "✓" : "✗", why, want, got);
}
int main(void) {
    one("帧率归游戏的款、局内一直慢：梯子不跑、不压帧", 0, NULL, 1, 180, 0, "-1 0 0 0 -");
    one("60 帧靠补丁、开局：放开 60 帧", 1, NULL, 1, 0, 0, "0 0 0 0 -");
    one("#1688 旧版 ladder.txt 记着底档：不读，照样从 60 帧起、文件原样", 1, "kind=1 tier=2", 1, 0, 0, "0 0 0 0 kind=1 tier=2");
    one("局内一直慢、有 GPU 读数：压回 30 帧、提示一次、不写 ladder.txt、不改运行模式", 1, NULL, 1, 600, 0, "1 1 0 0 -");
    one("局内一直慢、没有 GPU 读数：不降，照 60 帧跑", 1, NULL, 0, 600, 0, "0 0 0 0 -");
    one("压回 30 帧后玩家点再试 60 帧：放开 60 帧、不弹「已恢复」", 1, NULL, 1, 600, 1, "0 1 0 0 -");
    printf("%s t_qladder_host：%d 项不符\n", bad ? "✗" : "✓", bad);
    return bad ? 1 : 0;
}
