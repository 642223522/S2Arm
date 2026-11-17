// 着色器补料（graphics/nvn/host/dsh_salvage.inc）：玩家局里库里没有 / 现编失败的着色器存进 shader_miss/，随诊断包带走。
//   ① 没指定目录、兜底目录也不是 …/shaders → 不存；② 存一支：<键>.ctl / .code 字节对、index.tsv 一行；③ 同局再遇同键：次数不加、情况位并上、原文补上；
//   ④ 下一局（重读 index.tsv）再遇：次数 +1；⑤ 先只记索引（拿不到字节），后来拿到字节就补存；⑥ 满额：淘汰出现次数最少、其中最早的，本局见过的不动，
//   全是本局的就不存、计「满额没存」；⑦ 兜底目录 …/wire/<号>/shaders → 同级 shader_miss；⑧ 收局汇总一行
#include <dlfcn.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
static char last_log[1024];
static void tlog(const char *fmt, ...) { va_list ap; va_start(ap, fmt); vsnprintf(last_log, sizeof last_log, fmt, ap); va_end(ap); }
#define LOG(...) tlog(__VA_ARGS__)
const char *s2a_main_build_id(void) { return "11c33c7c2dbd3c5491841f67495c7ee8"; }
#include "../host/dsh_salvage.inc"

static int bad;
#define CHECK(c, ...) do { if (!(c)) { printf("✗ "); printf(__VA_ARGS__); printf("\n"); bad++; } } while (0)
static char dir[256];
static void new_run(void) { free(g_dsv.e); g_dsv.e = NULL; g_dsv.n = g_dsv.nalloc = 0; g_dsv.bytes = 0; g_dsv.init = 0; g_dsv.off = 0; g_dsv.new_run = g_dsv.dropped = 0; memset(g_dsv.kinds_run, 0, sizeof g_dsv.kinds_run); }
static long fsize(const char *k, const char *ext) { char p[600]; struct stat st; snprintf(p, sizeof p, "%s/%s.%s", dir, k, ext); return stat(p, &st) ? -1 : (long)st.st_size; }
static int index_line(const char *k, char *out, size_t n) {   // 这个键的那一行；没有返回 0
    char p[600], ln[512]; snprintf(p, sizeof p, "%s/index.tsv", dir); FILE *f = fopen(p, "r"); if (!f) return 0; int got = 0;
    while (fgets(ln, sizeof ln, f)) if (!strncmp(ln, k, 16)) { snprintf(out, n, "%s", ln); out[strcspn(out, "\n")] = 0; got = 1; }
    fclose(f); return got;
}
static unsigned col_u(const char *ln, int c) { const char *s = ln; for (int i = 0; i < c && s; i++) { s = strchr(s, '\t'); if (s) s++; } return s ? (unsigned)strtoul(s, NULL, 10) : 0; }

int main(void) {
    static uint8_t ctl[0x880], code[0x40000]; for (size_t i = 0; i < sizeof ctl; i++) ctl[i] = (uint8_t)i; for (size_t i = 0; i < sizeof code; i++) code[i] = (uint8_t)(i * 13);
    char root[] = "/tmp/t_dsh_salvage.XXXXXX"; if (!mkdtemp(root)) return 1;
    char ln[512];

    // ① 兜底目录不是 …/shaders、也没指定 → 不存
    unsetenv("S2A_SHADER_SALVAGE"); setenv("DM_MSL_FALLBACK", "/dev/null", 1);
    dsh_salvage_put("aaaaaaaaaaaaaaaa", DSV_NOMAP, 2, ctl, 0x880, code, 64, NULL);
    CHECK(g_dsv.off && g_dsv.n == 0, "① 没有补料目录时不该存（off=%d n=%zu）", g_dsv.off, g_dsv.n);

    // ⑦ 兜底目录 …/wire/<号>/shaders → 同级 shader_miss
    new_run(); char fb[300]; snprintf(fb, sizeof fb, "%s/wire/01008DD013200000/shaders", root); setenv("DM_MSL_FALLBACK", fb, 1);
    dsh_salvage_put("aaaaaaaaaaaaaaaa", DSV_NOMAP, 2, ctl, 0x880, code, 64, NULL);
    snprintf(dir, sizeof dir, "%s/wire/01008DD013200000/shader_miss", root);
    // mkdir 只建最后一级：wire/<号> 由宿主起局时建好（host_adapt.m），这里模拟
    { char w[300]; snprintf(w, sizeof w, "%s/wire", root); mkdir(w, 0755); snprintf(w, sizeof w, "%s/wire/01008DD013200000", root); mkdir(w, 0755); }
    new_run(); dsh_salvage_put("aaaaaaaaaaaaaaaa", DSV_NOMAP, 2, ctl, 0x880, code, 64, NULL);
    CHECK(fsize("aaaaaaaaaaaaaaaa", "ctl") == 0x880 && fsize("aaaaaaaaaaaaaaaa", "code") == 64, "⑦ 兜底目录同级 shader_miss 里没有 aaaa 的 .ctl / .code（%ld / %ld）", fsize("aaaaaaaaaaaaaaaa", "ctl"), fsize("aaaaaaaaaaaaaaaa", "code"));

    // ② 指定目录，存一支：字节对、索引一行（阶段 2、情况 1、次数 1、构建号前 16 位）
    snprintf(dir, sizeof dir, "%s/sv", root); setenv("S2A_SHADER_SALVAGE", dir, 1); setenv("S2A_SHADER_SALVAGE_MB", "1", 1); new_run();
    dsh_salvage_put("1111111111111111", DSV_NOMAP, 2, ctl, 0x880, code, 64, NULL);
    { char p[600]; snprintf(p, sizeof p, "%s/1111111111111111.code", dir); FILE *f = fopen(p, "rb"); uint8_t b[64] = {0}; size_t r = f ? fread(b, 1, 64, f) : 0; if (f) fclose(f);
      CHECK(r == 64 && !memcmp(b, code, 64), "② .code 字节与代码区不同（读到 %zu 字节）", r); }
    CHECK(index_line("1111111111111111", ln, sizeof ln) && col_u(ln, 1) == 2 && col_u(ln, 2) == 1 && col_u(ln, 3) == 1 && strstr(ln, "11c33c7c2dbd3c54"), "② 索引行不对：%s", ln);

    // ③ 同局再遇：次数不加，情况位并上 2，原文补上
    dsh_salvage_put("1111111111111111", DSV_COMPFAIL, 2, ctl, 0x880, code, 64, "translator rc=3 (compute)");
    CHECK(index_line("1111111111111111", ln, sizeof ln) && col_u(ln, 2) == 3 && col_u(ln, 3) == 1 && strstr(ln, "translator rc=3"), "③ 同局再遇应 情况 3、次数 1、带原文：%s", ln);

    // ④ 下一局再遇：次数 2；新键 2222 只记索引（拿不到字节）
    new_run(); dsh_salvage_put("1111111111111111", DSV_NOMAP, 2, ctl, 0x880, code, 64, NULL);
    CHECK(index_line("1111111111111111", ln, sizeof ln) && col_u(ln, 3) == 2 && col_u(ln, 2) == 3 && strstr(ln, "translator rc=3"), "④ 下一局再遇应次数 2、保留情况与原文：%s", ln);
    dsh_salvage_put("2222222222222222", DSV_NOMAP, -1, NULL, 0, NULL, 0, NULL);
    CHECK(index_line("2222222222222222", ln, sizeof ln) && col_u(ln, 5) == 0 && fsize("2222222222222222", "code") < 0, "④ 只记索引的键不该有字节文件：%s", ln);
    // ⑤ 同局后来拿到字节：补存
    dsh_salvage_put("2222222222222222", DSV_NOMAP, 0, ctl, 0x880, code, 128, NULL);
    CHECK(fsize("2222222222222222", "code") == 128 && index_line("2222222222222222", ln, sizeof ln) && col_u(ln, 5) == 128 && col_u(ln, 1) == 0, "⑤ 拿到字节后应补存（.code %ld）：%s", fsize("2222222222222222", "code"), ln);

    // ⑥ 满额（1 MB，每支另加 2 KB 控制段）：下一局存 3333 / 4444（300 KB）、5555（200 KB），各次数 1；再下一局 1111 计次数 3；
    //   新来 6666（300 KB）：总量 811 KB → 1113 KB 超了，按次数最少、其中最早的淘汰：先 2222（2 KB，不够）再 3333
    new_run(); dsh_salvage_put("3333333333333333", DSV_NOMAP, 2, ctl, 0x880, code, 300 << 10, NULL);
    dsh_salvage_put("4444444444444444", DSV_NOMAP, 2, ctl, 0x880, code, 300 << 10, NULL);
    dsh_salvage_put("5555555555555555", DSV_NOMAP, 2, ctl, 0x880, code, 200 << 10, NULL);
    new_run(); dsh_salvage_put("1111111111111111", DSV_NOMAP, 2, ctl, 0x880, code, 64, NULL);
    dsh_salvage_put("6666666666666666", DSV_NOMAP, 2, ctl, 0x880, code, 300 << 10, NULL);
    CHECK(!index_line("2222222222222222", ln, sizeof ln) && !index_line("3333333333333333", ln, sizeof ln) && fsize("3333333333333333", "code") < 0 && fsize("2222222222222222", "ctl") < 0, "⑥ 满额应依次淘汰次数最少里最早的 2222、3333（还在）");
    CHECK(index_line("1111111111111111", ln, sizeof ln) && col_u(ln, 3) == 3 && index_line("4444444444444444", ln, sizeof ln) && index_line("6666666666666666", ln, sizeof ln) && fsize("6666666666666666", "code") == 300 << 10,
          "⑥ 1111（次数 3）、4444 应留下，6666 应存进来");
    // 再来 7777 / 8888 / 9999（各 300 KB）：7777 淘汰 4444，8888 淘汰 5555；9999 时余下的全是本局见过的 → 不存、计满额没存
    dsh_salvage_put("7777777777777777", DSV_NOMAP, 2, ctl, 0x880, code, 300 << 10, NULL);
    dsh_salvage_put("8888888888888888", DSV_NOMAP, 2, ctl, 0x880, code, 300 << 10, NULL);
    dsh_salvage_put("9999999999999999", DSV_NOMAP, 2, ctl, 0x880, code, 300 << 10, NULL);
    CHECK(!index_line("4444444444444444", ln, sizeof ln) && !index_line("5555555555555555", ln, sizeof ln) && index_line("7777777777777777", ln, sizeof ln) && index_line("8888888888888888", ln, sizeof ln)
          && !index_line("9999999999999999", ln, sizeof ln) && g_dsv.dropped == 1 && index_line("1111111111111111", ln, sizeof ln) && index_line("6666666666666666", ln, sizeof ln),
          "⑥ 本局见过的不淘汰：4444 / 5555 让位给 7777 / 8888，9999 没地方不存（满额没存 %llu）", (unsigned long long)g_dsv.dropped);
    CHECK(g_dsv.bytes <= 1u << 20, "⑥ 总量超上限：%zu", g_dsv.bytes);

    // ⑧ 收局汇总一行
    last_log[0] = 0; dsh_salvage_summary();
    CHECK(strstr(last_log, "着色器补料：本局新存 3 支") && strstr(last_log, "满额没存 1 支"), "⑧ 汇总行不对：%s", last_log);

    char cmd[400]; snprintf(cmd, sizeof cmd, "rm -rf '%s'", root); system(cmd);
    printf("%s t_dsh_salvage：着色器补料按键去重、跨局计次数、满额淘汰次数最少的 → %s\n", bad ? "✗" : "✓", bad ? "有不符合项" : "通过");
    return bad != 0;
}
