// BC → ASTC 预转包读取（gal_astc.m）单测：平面键黄金值 / 包往返（写包 → 按键查 → 取回负载）/ 损坏的包整包不用且不崩 / 格式 → 族。
// 期望值都不跑被测实现：键的黄金值由 shasum -a 256 对手拼的字节算出（命令见各值旁）；包由本文件按 gal_astc.h 的格式手写。
#include "../gal_astc.h"
#include "../gal_formats.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int g_fail, g_checks;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_fail++; printf("  ✗ " __VA_ARGS__); printf("\n"); } } while (0)

static void hex(const char *s, uint8_t out[32]) { for (int i = 0; i < 32; i++) { unsigned v; sscanf(s + 2 * i, "%2x", &v); out[i] = (uint8_t)v; } }
static void put64(uint8_t *p, uint64_t v) { for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> (8 * i)); }
static void put32(uint8_t *p, uint32_t v) { for (int i = 0; i < 4; i++) p[i] = (uint8_t)(v >> (8 * i)); }

// 键：printf 's2a-bc-astc-v1\x01\x00\x00\x00\x04\x00\x00\x00\x04\x00\x00\x00\x00\x01\x02\x03\x04\x05\x06\x07' | shasum -a 256
//     族 7、8x4、32 字节 i*7&255：同上拼出后 shasum -a 256
static void t_key(void) {
    uint8_t k[32], want[32], bc[32];
    for (int i = 0; i < 8; i++) bc[i] = (uint8_t)i;
    gal_astc_key(GAL_ASTC_FAM_BC1, 4, 4, bc, 8, k);
    hex("cf2afb54f06542892aba31a135661c3ef9c351863bde6e7267e6643cb26d109f", want);
    CHECK(!memcmp(k, want, 32), "BC1 4x4 单块的键与 shasum 算出的不同");
    for (int i = 0; i < 32; i++) bc[i] = (uint8_t)(i * 7);
    gal_astc_key(GAL_ASTC_FAM_BC7, 8, 4, bc, 32, k);
    hex("8542d04487cea4a07310b82d9b430f524fc68d1c16bab9472585dc1927ddb6d5", want);
    CHECK(!memcmp(k, want, 32), "BC7 8x4 的键与 shasum 算出的不同");
}

// 手写一个包：n 项（键已按升序给），负载各自 16 字节对齐放在头后；alias[i] ≥ 0 表示第 i 项复用第 alias[i] 项的负载
typedef struct { uint8_t key[32]; const uint8_t *data; uint64_t len; int alias; } ent;
static size_t build(uint8_t *out, const ent *e, int n) {
    uint64_t off[16], pos = GAL_ASTC_HEAD;
    for (int i = 0; i < n; i++) {
        if (e[i].alias >= 0) { off[i] = off[e[i].alias]; continue; }
        off[i] = pos; memcpy(out + pos, e[i].data, e[i].len); pos += (e[i].len + 15) & ~15ull;
    }
    uint64_t ioff = pos;
    for (int i = 0; i < n; i++) { uint8_t *x = out + ioff + 48 * i; memcpy(x, e[i].key, 32); put64(x + 32, off[i]); put64(x + 40, e[i].len); }
    uint64_t total = ioff + 48ull * n;
    memset(out, 0, GAL_ASTC_HEAD); memcpy(out, "S2ABCAST", 8); put32(out + 8, 1); put32(out + 12, 48);
    put64(out + 16, (uint64_t)n); put64(out + 24, ioff); put64(out + 32, total); out[40] = 4; out[41] = 4;
    return (size_t)total;
}
static char g_dir[] = "/tmp/t_astc.XXXXXX";
static const char *wr(const char *name, const uint8_t *b, size_t n) {
    static char p[256]; snprintf(p, sizeof p, "%s/%s", g_dir, name);
    FILE *f = fopen(p, "wb"); fwrite(b, 1, n, f); fclose(f); return p;
}

static uint8_t g_buf[4096];
static void t_roundtrip(void) {
    uint8_t p1[16], p2[32];
    for (int i = 0; i < 16; i++) p1[i] = (uint8_t)(0xa0 + i);
    for (int i = 0; i < 32; i++) p2[i] = (uint8_t)(0x10 + i);
    ent e[3] = {{{0}, p1, 16, -1}, {{0}, p2, 32, -1}, {{0}, p1, 16, 0}};
    memset(e[0].key, 0x11, 32); memset(e[1].key, 0x22, 32); memset(e[2].key, 0x33, 32);   // 已升序；第 3 项与第 1 项同负载
    size_t n = build(g_buf, e, 3);
    CHECK(n == 64 + 16 + 32 + 3 * 48, "包长 %zu，期望 64 + 16 + 32 + 144 = 256", n);
    char why[128] = {0};
    gal_astc_pack *p = gal_astc_open(wr("ok.pack", g_buf, n), why, sizeof why);
    CHECK(p != NULL, "合法的包打不开：%s", why);
    if (!p) return;
    CHECK(gal_astc_count(p) == 3, "项数 %llu，期望 3", (unsigned long long)gal_astc_count(p));
    uint8_t out[64]; uint64_t sz = 0;
    CHECK(gal_astc_find(p, e[1].key, &sz) && sz == 32, "第 2 项查不到或长度 %llu ≠ 32", (unsigned long long)sz);
    memset(out, 0, sizeof out);
    CHECK(gal_astc_read(p, e[1].key, out, 32) && !memcmp(out, p2, 32), "第 2 项负载读回不对");
    memset(out, 0, sizeof out);
    CHECK(gal_astc_read(p, e[2].key, out, 16) && !memcmp(out, p1, 16), "第 3 项（复用第 1 项负载）读回不对");
    CHECK(!gal_astc_read(p, e[0].key, out, 32), "长度与包里记的不等（要 32、包里 16）却算命中");
    uint8_t miss[32]; memset(miss, 0x2a, 32);
    CHECK(!gal_astc_find(p, miss, NULL) && !gal_astc_read(p, miss, out, 16), "包里没有的键却命中");
    gal_astc_close(p);

    // 0 项的包合法：什么都查不到
    size_t n0 = build(g_buf, e, 0);
    p = gal_astc_open(wr("empty.pack", g_buf, n0), why, sizeof why);
    CHECK(p && gal_astc_count(p) == 0 && !gal_astc_find(p, e[0].key, NULL), "0 项的包应能打开、查不到东西");
    gal_astc_close(p);
}

// 损坏的包：每种都整包不用（open 返回 NULL），不崩
static void t_corrupt(void) {
    uint8_t p1[16] = {1}, p2[16] = {2};
    ent e[2] = {{{0}, p1, 16, -1}, {{0}, p2, 16, -1}};
    memset(e[0].key, 0x11, 32); memset(e[1].key, 0x22, 32);
    size_t n = build(g_buf, e, 2); uint8_t b[4096]; char why[128];
    struct { const char *name; size_t len; int edit; } cases[] = {
        {"截掉最后一字节", n - 1, 0}, {"多一个字节", n + 1, 0}, {"魔数错", n, 1}, {"版本 2", n, 2}, {"块 6x6", n, 3},
        {"索引未排序", n, 4}, {"负载偏移越界", n, 5}, {"负载偏移不对齐", n, 6}, {"索引偏移在头里", n, 7}, {"只有半个头", 40, 0}, {"空文件", 0, 0},
    };
    for (size_t c = 0; c < sizeof cases / sizeof *cases; c++) {
        memcpy(b, g_buf, n); b[n] = 0;
        uint8_t *ix = b + 64 + 32;   // 索引起点：头 64 + 两份 16 字节负载
        switch (cases[c].edit) {
        case 1: b[0] = 'X'; break;
        case 2: put32(b + 8, 2); break;
        case 3: b[40] = 6; b[41] = 6; break;
        case 4: { uint8_t t[48]; memcpy(t, ix, 48); memcpy(ix, ix + 48, 48); memcpy(ix + 48, t, 48); } break;
        case 5: put64(ix + 48 + 32, 4000); break;
        case 6: put64(ix + 32, 72); break;
        case 7: put64(b + 24, 32); break;
        }
        why[0] = 0;
        gal_astc_pack *p = gal_astc_open(wr("bad.pack", b, cases[c].len), why, sizeof why);
        CHECK(p == NULL, "损坏的包（%s）没被拒", cases[c].name);
        if (!p) printf("  · %s → 拒：%s\n", cases[c].name, why);
        gal_astc_close(p);
    }
    CHECK(gal_astc_open("/nonexistent/x.pack", why, sizeof why) == NULL, "不存在的路径没被拒");
    CHECK(gal_astc_open(g_dir, why, sizeof why) == NULL, "目录没被拒");
}

static void t_family(void) {
    struct { int f, fam; } k[] = {
        {F_Bc1RgbaUnorm, 1}, {F_Bc1RgbaSrgb, 1}, {F_Bc2Unorm, 2}, {F_Bc2Srgb, 2}, {F_Bc3Unorm, 3}, {F_Bc3Srgb, 3},
        {F_Bc4Unorm, 0}, {F_Bc4Snorm, 0}, {F_Bc5Unorm, 5}, {F_Bc5Snorm, 0}, {F_Bc7Unorm, 7}, {F_Bc7Srgb, 7},
        {F_Bc6HSfloat, 0}, {F_Bc6HUfloat, 0}, {F_R8G8B8A8Unorm, 0}, {F_Astc4x4Unorm, 0},
    };
    for (size_t i = 0; i < sizeof k / sizeof *k; i++) CHECK(gal_astc_family(k[i].f) == k[i].fam, "格式 %d 的族 %d，期望 %d", k[i].f, gal_astc_family(k[i].f), k[i].fam);
    CHECK(gal_astc_plane_bytes(1, 1) == 16 && gal_astc_plane_bytes(4, 4) == 16 && gal_astc_plane_bytes(5, 3) == 32 && gal_astc_plane_bytes(64, 32) == 16 * 8 * 16, "ASTC 4x4 平面字节数不对");
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    if (!mkdtemp(g_dir)) { printf("建临时目录失败\n"); return 2; }
    t_key(); t_roundtrip(); t_corrupt(); t_family();
    char cmd[300]; snprintf(cmd, sizeof cmd, "rm -rf '%s'", g_dir); (void)!system(cmd);
    printf("%s：%d / %d 项通过\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks);
    return g_fail ? 1 : 0;
}
