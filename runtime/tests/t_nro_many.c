// nn::ro 装很多 NRO（11-03 大乱斗 SPECIAL：nro_modules.tsv 764 行；原模块表定长 MAX_MOD 256，读表截断、装第 256 个起报「模块表满」）。
// 夹具 runtime/tests/nro_many/prepare.py：自有模块改写成 main + nro0…nro<N-1>（N = 300，超过原上限），nro_modules.tsv N 行。
// 生产 load_modules 装 main，再按表逐个 s2a_nro_map。期望（按语义手算，不读实现）：
//   ① N 个都返回 0、基址两两不同、module_of(基址) 落在名字 nro<k> 的模块上；② 模块数 = 1 + N = 301；
//   ③ 已装的再装返回 3；不在表里的哈希返回 1；④ 卸最后一个再装：返回 0、映回原基址。
//   ⑤ 模块跨度 = (1 + N) × 2 MB（夹具每个模块映像 64 KB，各按 2 MB 对齐）：随行表在逐模块文件或合并表 nro_tables.tsv 里都一样。
//   ⑥ 合并表档（目录里有 nro_tables.tsv，夹具 --merged）：nro1 的门（返回点 +0x10010、原址 +0x100）登记上了。
// 旧实现：nro_table 读到 256 行就停（nro256… 返回 1），且模块数到 256 后返回 4 → ① 红。
#include "../src/native.h"
#include <string.h>
#include <unistd.h>

int s2a_nro_map(const uint8_t sha[32], uint64_t size, uint64_t bss, uint64_t *base);
int s2a_gate_identity(uint64_t ret, uint64_t *orig, int *kind);
int s2a_nro_unmap(uint64_t base);
static int bad;
#define CHECK(c, ...) do { if (!(c)) { bad++; printf("✗ "); printf(__VA_ARGS__); putchar('\n'); } } while (0)
static void sha_of(int k, uint8_t s[32]) { memset(s, 0x5a, 32); s[0] = (uint8_t)(k & 0xff); s[1] = (uint8_t)(k >> 8); }

int main(int argc, char **argv) {
    if (argc != 3) return 2;
    int n = atoi(argv[2]); if (n <= 0) return 2;
    unsetenv("S2A_FPS60"); unsetenv("S2A_CPATCH_ON");
    const char *names[] = {"main"}; load_modules(argv[1], names, 1);
    CHECK(g_nmod == 1, "装 main 后模块数 %d，期望 1", g_nmod);
    uint64_t *bases = calloc((size_t)n, sizeof *bases); if (!bases) return 2;
    int ok = 0, first_bad = -1, first_rc = 0;
    for (int k = 0; k < n; k++) {
        uint8_t s[32]; sha_of(k, s); uint64_t b = 0; int rc = s2a_nro_map(s, 0x10000, 0, &b);
        if (rc) { if (first_bad < 0) { first_bad = k; first_rc = rc; } continue; }
        char want[16]; snprintf(want, sizeof want, "nro%d", k); module_t *m = module_of((void *)b);
        if (!m || strcmp(m->name, want) || (uint64_t)m->base != b) { if (first_bad < 0) { first_bad = k; first_rc = -1; } continue; }
        bases[k] = b; ok++;
    }
    CHECK(ok == n, "① %d 个 NRO 装上 %d 个（第一个失败 nro%d rc=%d）", n, ok, first_bad, first_rc);
    int dup = 0; for (int i = 0; i < n; i++) for (int j = i + 1; j < n; j++) if (bases[i] && bases[i] == bases[j]) dup++;
    CHECK(!dup, "① 基址重复 %d 对", dup);
    CHECK(g_nmod == 1 + n, "② 模块数 %d，期望 %d", g_nmod, 1 + n);
    uint64_t span = s2a_module_span(argv[1]), want = (uint64_t)(1 + n) << 21;
    CHECK(span == want, "⑤ 模块跨度 %#llx，期望 %#llx", (unsigned long long)span, (unsigned long long)want);
    char tp[1100]; snprintf(tp, sizeof tp, "%s/nro_tables.tsv", argv[1]);
    if (!access(tp, F_OK) && n > 1 && bases[1]) {
        uint64_t orig = 0; int kind = -1;
        CHECK(!s2a_gate_identity(bases[1] + 0x10010, &orig, &kind) && orig == bases[1] + 0x100, "⑥ nro1 的门没从合并表登记上（原址 %#llx）", (unsigned long long)orig);
    }
    uint8_t s[32]; uint64_t b = 0; sha_of(0, s);
    CHECK(s2a_nro_map(s, 0x10000, 0, &b) == 3, "③ 已装的 nro0 再装期望 3");
    memset(s, 0xee, 32); CHECK(s2a_nro_map(s, 0x10000, 0, &b) == 1, "③ 不在表里的哈希期望 1");
    if (bases[n - 1]) {
        CHECK(s2a_nro_unmap(bases[n - 1]) == 0, "④ 卸 nro%d 期望 0", n - 1);
        sha_of(n - 1, s); b = 0;
        CHECK(s2a_nro_map(s, 0x10000, 0, &b) == 0 && b == bases[n - 1], "④ 重装 nro%d 期望 0、映回原基址 %#llx（实得 %#llx）", n - 1,
              (unsigned long long)bases[n - 1], (unsigned long long)b);
        CHECK(g_nmod == 1 + n, "④ 重装不增模块数（%d）", g_nmod);
    }
    if (bad) { printf("✗ t_nro_many：%d 处不符\n", bad); return 1; }
    printf("✓ t_nro_many：main + %d 个 NRO 全部装上、基址互异、模块数 %d；重复装 / 未登记 / 卸后重装语义不变\n", n, g_nmod);
    return 0;
}
