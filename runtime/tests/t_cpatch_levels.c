// 帧率补丁按档（runtime/src/cpatch.c fps_pick / s2a_cpatch_fps_pick / s2a_cpatch_fps_levels，11-13 维护者「60 / 120 都带进去，玩家自己切」）：
//   手工模块，表里两份帧率补丁改同一处数据 0x40（原值 00）：fps:L 位 6 → 55、目标 60；fps:H 位 7 → 77、目标 120。装载时两份都只登记（同处，先写一份另一份原值校验不过）。
// 期望（手算）：可选档 [60, 120]；跟随开、没选档（单测里屏幕刷新率取不到按 60）→ 只开 L：掩码 0x40、0x40 = 55；包里有高于 60 的档 → 出图链 / 节拍归补丁管、选 60 档即 1 / 60；
//   选 120 → 只开 H：掩码 0x80、0x40 = 77、DM_PRESENT_LINK = 2、DM_PRESENT_HZ = 120；选回 60 → 0x40、55、链 1、节拍 60；跟随关 → 0、00；
//   S2A_FPS_PICK=120 起局（玩家设置）→ 开就是 H
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>
#include "../src/native.h"
void s2a_cpatch_load(module_t *m, const char *dir);
void s2a_cpatch_fps_follow(int on); void s2a_cpatch_fps_pick(int target); int s2a_cpatch_fps_levels(int *out, int n, int *cur); int s2a_cpatch_stall_rescue(void); int s2a_cpatch_fps_unit(const char *id);
static int fails;
static int g_scr;   // ⑤ 屏幕最高刷新率（覆盖 cpatch.c 的弱定义 front_screen_max_fps；0 = 还不知道）
int front_screen_max_fps(void) { return g_scr; }
void s2a_cpatch_screen_changed(void);
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("✗ "); printf(__VA_ARGS__); printf("\n"); } } while (0)
static const char *E(const char *k) { const char *v = getenv(k); return v ? v : "-"; }
static int g_fi;   // ④ 补帧开着（DM_PRESENT_FI=1）
static void run(const char *dir, int pick_env, char *out, size_t n) {
    int pp[2]; pipe(pp); pid_t c = fork();
    if (c == 0) {
        close(pp[0]); unsetenv("DM_PRESENT_LINK"); unsetenv("DM_PRESENT_HZ"); unsetenv("S2A_CPATCH_ON");
        if (pick_env) setenv("S2A_FPS_PICK", "120", 1); else unsetenv("S2A_FPS_PICK");
        if (g_fi) setenv("DM_PRESENT_FI", "1", 1); else unsetenv("DM_PRESENT_FI");
        module_t m; memset(&m, 0, sizeof m); snprintf(m.name, sizeof m.name, "%s", "main");
        m.size = 0x8000; m.base = mmap(NULL, m.size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0); m.key_page_off = 0x4000; m.key_page_size = 0x4000;
        s2a_cpatch_load(&m, dir);
        uint64_t *slot = (uint64_t *)(m.base + m.key_page_off) + 2046; char b[512]; int k = 0, lv[8], cur = 0, nl = s2a_cpatch_fps_levels(lv, 8, &cur);
        k += snprintf(b + k, sizeof b - (size_t)k, "档 %d:", nl); for (int i = 0; i < nl; i++) k += snprintf(b + k, sizeof b - (size_t)k, "%s%d", i ? "/" : "", lv[i]);
        s2a_cpatch_fps_follow(1); k += snprintf(b + k, sizeof b - (size_t)k, " 开 %llx %02x %s %s", (unsigned long long)(*slot & 0xC0), m.base[0x40], E("DM_PRESENT_LINK"), E("DM_PRESENT_HZ"));
        if (!pick_env) {
            s2a_cpatch_fps_pick(120); k += snprintf(b + k, sizeof b - (size_t)k, " 选120 %llx %02x %s %s", (unsigned long long)(*slot & 0xC0), m.base[0x40], E("DM_PRESENT_LINK"), E("DM_PRESENT_HZ"));
            s2a_cpatch_fps_pick(60); k += snprintf(b + k, sizeof b - (size_t)k, " 选60 %llx %02x %s %s", (unsigned long long)(*slot & 0xC0), m.base[0x40], E("DM_PRESENT_LINK"), E("DM_PRESENT_HZ"));
        }
        if (pick_env) k += snprintf(b + k, sizeof b - (size_t)k, " 份 %d %d", s2a_cpatch_fps_unit("fps:L"), s2a_cpatch_fps_unit("fps:H"));   // ⑦ 选 120：只有 120 那份选中
        s2a_cpatch_fps_follow(0); k += snprintf(b + k, sizeof b - (size_t)k, " 关 %llx %02x", (unsigned long long)(*slot & 0xC0), m.base[0x40]);
        if (pick_env) k += snprintf(b + k, sizeof b - (size_t)k, " 份 %d %d", s2a_cpatch_fps_unit("fps:L"), s2a_cpatch_fps_unit("fps:H"));   // 关帧率：都没选中
        write(pp[1], b, (size_t)k); _exit(0);
    }
    close(pp[1]); ssize_t r = read(pp[0], out, n - 1); out[r > 0 ? r : 0] = 0; close(pp[0]); waitpid(c, NULL, 0);
}
// ⑤ 屏幕刷新率起局后才知道（Mac 建窗晚于选档）：期望（手算）——屏幕不知道按 60 开 L（40 55 链 1）；屏幕报 120 → 自动档重挑开 H（80 77 链 2）；
//   再报 120 不重复动；玩家选过 60 档（s2a_cpatch_fps_pick）后屏幕变 120 不动（仍 40 55）
static void run_screen(const char *dir, char *out, size_t n) {
    int pp[2]; pipe(pp); pid_t c = fork();
    if (c == 0) {
        close(pp[0]); unsetenv("DM_PRESENT_LINK"); unsetenv("DM_PRESENT_HZ"); unsetenv("S2A_CPATCH_ON"); unsetenv("S2A_FPS_PICK"); unsetenv("DM_PRESENT_FI");
        module_t m; memset(&m, 0, sizeof m); snprintf(m.name, sizeof m.name, "%s", "main");
        m.size = 0x8000; m.base = mmap(NULL, m.size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0); m.key_page_off = 0x4000; m.key_page_size = 0x4000;
        s2a_cpatch_load(&m, dir);
        uint64_t *slot = (uint64_t *)(m.base + m.key_page_off) + 2046; char b[512]; int k = 0;
        g_scr = 0; s2a_cpatch_fps_follow(1); k += snprintf(b + k, sizeof b - (size_t)k, "起 %llx %02x %s", (unsigned long long)(*slot & 0xC0), m.base[0x40], E("DM_PRESENT_LINK"));
        g_scr = 120; s2a_cpatch_screen_changed(); k += snprintf(b + k, sizeof b - (size_t)k, " 屏120 %llx %02x %s", (unsigned long long)(*slot & 0xC0), m.base[0x40], E("DM_PRESENT_LINK"));
        s2a_cpatch_screen_changed(); k += snprintf(b + k, sizeof b - (size_t)k, " 再报 %llx %02x", (unsigned long long)(*slot & 0xC0), m.base[0x40]);
        g_scr = 60; s2a_cpatch_fps_pick(60); g_scr = 120; s2a_cpatch_screen_changed(); k += snprintf(b + k, sizeof b - (size_t)k, " 选60后屏120 %llx %02x", (unsigned long long)(*slot & 0xC0), m.base[0x40]);
        write(pp[1], b, (size_t)k); _exit(0);
    }
    close(pp[1]); ssize_t r = read(pp[0], out, n - 1); out[r > 0 ? r : 0] = 0; close(pp[0]); waitpid(c, NULL, 0);
}
// ③ 停帧救场（11-14，cpatch.c s2a_cpatch_stall_rescue）：期望（手算）——帧率补丁没开时救场不动（0）；开着 120 档时救场 → 返回 1、两份都关（掩码 0、
//   0x40 写回 00）、出图链 1 / 节拍 60、S2A_DOCS 下留 cpatch_stall_off（内容 fps）；同一局再救一次返回 0
static void run_rescue(const char *dir, char *out, size_t n) {
    int pp[2]; pipe(pp); pid_t c = fork();
    if (c == 0) {
        close(pp[0]); unsetenv("DM_PRESENT_LINK"); unsetenv("DM_PRESENT_HZ"); unsetenv("S2A_CPATCH_ON"); setenv("S2A_FPS_PICK", "120", 1); setenv("S2A_DOCS", dir, 1);
        module_t m; memset(&m, 0, sizeof m); snprintf(m.name, sizeof m.name, "%s", "main");
        m.size = 0x8000; m.base = mmap(NULL, m.size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0); m.key_page_off = 0x4000; m.key_page_size = 0x4000;
        s2a_cpatch_load(&m, dir);
        uint64_t *slot = (uint64_t *)(m.base + m.key_page_off) + 2046; char b[512], mk[64] = "-"; int k = 0;
        k += snprintf(b + k, sizeof b - (size_t)k, "未开救 %d", s2a_cpatch_stall_rescue());
        s2a_cpatch_fps_follow(1); k += snprintf(b + k, sizeof b - (size_t)k, " 开 %llx %02x %s %s", (unsigned long long)(*slot & 0xC0), m.base[0x40], E("DM_PRESENT_LINK"), E("DM_PRESENT_HZ"));
        int r1 = s2a_cpatch_stall_rescue();
        char p[300]; snprintf(p, sizeof p, "%s/cpatch_stall_off", dir); FILE *f = fopen(p, "r"); if (f) { if (!fgets(mk, sizeof mk, f)) mk[0] = 0; fclose(f); mk[strcspn(mk, "\n")] = 0; unlink(p); }
        k += snprintf(b + k, sizeof b - (size_t)k, " 救 %d %llx %02x %s %s 标记 %s 再救 %d", r1, (unsigned long long)(*slot & 0xC0), m.base[0x40], E("DM_PRESENT_LINK"), E("DM_PRESENT_HZ"), mk, s2a_cpatch_stall_rescue());
        write(pp[1], b, (size_t)k); _exit(0);
    }
    close(pp[1]); ssize_t r = read(pp[0], out, n - 1); out[r > 0 ? r : 0] = 0; close(pp[0]); waitpid(c, NULL, 0);
}
// ⑥ 同档几个上游补丁只开一组（11-15）：表里两份 60 档，组 g1 两行（位 1 写 0x48 = 11、位 2 写 0x4c = 22，同一上游补丁的 main / sdk）、组 g2 一行（位 3 写 0x50 = 33）。
//   期望（手算）：都没验过 → 开表里第一组 g1：掩码 0x06、0x48 11、0x4c 22、0x50 00；g2 缺省开（我方验过）→ 开 g2：掩码 0x08、00 00 33。
//   ⑦ 按份问选中档（s2a_cpatch_fps_unit，FpsLocker.cs 只写选中那份，审计 P1-184）：g1 选中 → A / B 返回 60、C 返回 0；g2 选中 → 0 0 60
static void run_group(int g2_def, char *out, size_t n) {
    char dir[] = "/tmp/t_cpatch_grp.XXXXXX"; if (!mkdtemp(dir)) { out[0] = 0; return; }
    char p[256]; snprintf(p, sizeof p, "%s/cpatch.tsv", dir); FILE *f = fopen(p, "w");
    fprintf(f, "编号\t模块\t位\t类别\t段名\t许可\t来源\t数据写入\t缺省开\t目标帧率\t画幅\t模式\t组\n");
    fprintf(f, "fps:A\tmain\t1\tfps\t60 a\t\ta\t48:00:11\t0\t60\t\t\tg1\n");
    fprintf(f, "fps:B\tmain\t2\tfps\t60 b\t\tb\t4c:00:22\t0\t60\t\t\tg1\n");
    fprintf(f, "fps:C\tmain\t3\tfps\t60 c\t\tc\t50:00:33\t%d\t60\t\t\tg2\n", g2_def);
    fclose(f);
    int pp[2]; pipe(pp); pid_t c = fork();
    if (c == 0) {
        close(pp[0]); unsetenv("DM_PRESENT_LINK"); unsetenv("DM_PRESENT_HZ"); unsetenv("S2A_CPATCH_ON"); unsetenv("S2A_FPS_PICK"); unsetenv("DM_PRESENT_FI");
        module_t m; memset(&m, 0, sizeof m); snprintf(m.name, sizeof m.name, "%s", "main");
        m.size = 0x8000; m.base = mmap(NULL, m.size, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0); m.key_page_off = 0x4000; m.key_page_size = 0x4000;
        s2a_cpatch_load(&m, dir); s2a_cpatch_fps_follow(1);
        uint64_t *slot = (uint64_t *)(m.base + m.key_page_off) + 2046; char b[128];
        int k = snprintf(b, sizeof b, "%llx %02x %02x %02x 份 %d %d %d", (unsigned long long)(*slot & 0x0e), m.base[0x48], m.base[0x4c], m.base[0x50],
                         s2a_cpatch_fps_unit("fps:A"), s2a_cpatch_fps_unit("fps:B"), s2a_cpatch_fps_unit("fps:C"));
        write(pp[1], b, (size_t)k); _exit(0);
    }
    close(pp[1]); ssize_t r = read(pp[0], out, n - 1); out[r > 0 ? r : 0] = 0; close(pp[0]); waitpid(c, NULL, 0); unlink(p); rmdir(dir);
}
int main(void) {
    char dir[] = "/tmp/t_cpatch_levels.XXXXXX"; if (!mkdtemp(dir)) return 1;
    char p[256]; snprintf(p, sizeof p, "%s/cpatch.tsv", dir); FILE *f = fopen(p, "w");
    fprintf(f, "编号\t模块\t位\t类别\t段名\t许可\t来源\t数据写入\t缺省开\t目标帧率\t画幅\t模式\n");
    fprintf(f, "fps:L\tmain\t6\t60fps\t60 帧\t\tl.pchtxt\t40:00:55\t1\t60\t\t\n");
    fprintf(f, "fps:H\tmain\t7\t60fps\t120 帧\t\th.pchtxt\t40:00:77\t1\t120\t\t\n");
    fclose(f);
    char got[512];
    run(dir, 0, got, sizeof got);
    const char *want = "档 2:60/120 开 40 55 1 60 选120 80 77 2 120 选60 40 55 1 60 关 0 00";
    CHECK(!strcmp(got, want), "① 缺省选档 / 切 120 / 切回 60 / 关：期望 %s，实得 %s", want, got);
    run(dir, 1, got, sizeof got);
    const char *want2 = "档 2:60/120 开 80 77 2 120 份 0 120 关 0 00 份 0 0";   // ⑦ 按份问：选 120 只有 fps:H 选中（120），60 那份 0；关帧率两份都 0
    CHECK(!strcmp(got, want2), "②⑦ 玩家设置 S2A_FPS_PICK=120 起局、按份问选中档：期望 %s，实得 %s", want2, got);
    // ④ 补帧开着（iOS 设置页缺省写 DM_PRESENT_FI=1）：选 120 照样要 120 Hz 显示链（2，nvn_mtl.m mtl_init 见到 2 不再清成 0）；
    //   不在高刷档时回 60 Hz 显示链（1），和补帧关着一样——这一帧真补不补、要不要关成 0 归图形层判（present_link_from_env 看 Metal 3、
    //   fi_link_follow 每帧看补帧开没开 / 有没有补丁占来源）。审计 P1-188：原先这里见补帧环境就写 0（旧实现得 0，红）。期望手写
    g_fi = 1; run(dir, 0, got, sizeof got); g_fi = 0;
    const char *want4 = "档 2:60/120 开 40 55 1 60 选120 80 77 2 120 选60 40 55 1 60 关 0 00";
    CHECK(!strcmp(got, want4), "④ 补帧开着：期望 %s，实得 %s", want4, got);
    run_group(0, got, sizeof got);
    CHECK(!strcmp(got, "6 11 22 00 份 60 60 0"), "⑥⑦ 同档两组、都没验过 → 只开第一组、按份问只有它选中：期望 6 11 22 00 份 60 60 0，实得 %s", got);
    run_group(1, got, sizeof got);
    CHECK(!strcmp(got, "8 00 00 33 份 0 0 60"), "⑥⑦ 第二组我方验过 → 只开它、按份问只有它选中：期望 8 00 00 33 份 0 0 60，实得 %s", got);
    run_screen(dir, got, sizeof got);
    const char *want5 = "起 40 55 1 屏120 80 77 2 再报 80 77 选60后屏120 40 55";
    CHECK(!strcmp(got, want5), "⑤ 起局后才知道屏幕 120 Hz：期望 %s，实得 %s", want5, got);
    run_rescue(dir, got, sizeof got);
    const char *want3 = "未开救 0 开 80 77 2 120 救 1 0 00 1 60 标记 fps 再救 0";
    CHECK(!strcmp(got, want3), "③ 停帧救场：期望 %s，实得 %s", want3, got);
    unlink(p); rmdir(dir);
    if (fails) { printf("✗ t_cpatch_levels：%d 项红\n", fails); return 1; }
    printf("✓ t_cpatch_levels：3 项（缺省按屏幕取档、局中切档、玩家设置起局、停帧救场）\n"); return 0;
}
