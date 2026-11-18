// BC 经 ASTC 预转包（gal_tex.m「BC → ASTC」）单测：Mac 都支持 BC，用 gal_bce_test_nobc 把本机当成 Apple TV（不支持 BC、支持 ASTC）。
// 覆盖：能力表照报 BC / 整张上传全命中 → ASTC 4x4、读回字节 = 包里的块 / 单级上传命中 / 视图跟父贴图走 ASTC / 之后没命中 → 换解压格式（已有内容在 GPU 上解成像素）、
//   视图跟着换 / 首次就没命中 → 解压格式、照旧上传解压数据 / 待定被别的用法碰到 → 解压格式 / 包存不了的族直接解压格式 / 互拷两边对齐 /
//   非 BC 贴图不经这条路 / 包损坏与没设环境变量 → 整条路不开、BC 照原生建。
// 期望值都不跑被测实现：ASTC 负载用手拼的「空区块」（void-extent：整块一个常量色，规范 C.2.23），红 / 绿 / 蓝解出来就是 (255,0,0,255) 等；
//   键用 gal_astc_key（它的黄金值在 t_astc 单测里由 shasum 核过），这里只当造包的工具。
#import "../gal_internal.h"
#include "../gal_astc.h"
#include "../gal_formats.h"
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <execinfo.h>
#include <signal.h>
GAL_MTL4_ZONE_BEGIN
static void on_sig(int s) { void *b[32]; int n = backtrace(b, 32); backtrace_symbols_fd(b, n, 2); _exit(128 + s); }
static int g_fail, g_checks;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_fail++; printf("  ✗ " __VA_ARGS__); printf("\n"); } } while (0)

// ASTC 空区块：前 8 字节 FC FD FF FF FF FF FF FF（块模式 0x1FC、LDR、保留位 11、四个范围坐标全 1 = 无范围），后 8 字节 RGBA 各 16 位
static void void_block(uint8_t *b, uint16_t r, uint16_t g, uint16_t bl, uint16_t a) {
    static const uint8_t h[8] = {0xFC, 0xFD, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF}; memcpy(b, h, 8);
    uint16_t c[4] = {r, g, bl, a}; for (int i = 0; i < 4; i++) { b[8 + 2 * i] = (uint8_t)c[i]; b[9 + 2 * i] = (uint8_t)(c[i] >> 8); }
}
static void put64(uint8_t *p, uint64_t v) { for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> (8 * i)); }
static void put32(uint8_t *p, uint32_t v) { for (int i = 0; i < 4; i++) p[i] = (uint8_t)(v >> (8 * i)); }
typedef struct { uint8_t key[32]; uint8_t data[256]; uint64_t len; } ent;
static int ent_cmp(const void *a, const void *b) { return memcmp(((const ent *)a)->key, ((const ent *)b)->key, 32); }
static void write_pack(const char *path, ent *e, int n) {
    qsort(e, (size_t)n, sizeof *e, ent_cmp);
    static uint8_t out[8192]; uint64_t off[16], pos = GAL_ASTC_HEAD;
    for (int i = 0; i < n; i++) { off[i] = pos; memcpy(out + pos, e[i].data, e[i].len); pos += (e[i].len + 15) & ~15ull; }
    for (int i = 0; i < n; i++) { uint8_t *x = out + pos + 48 * i; memcpy(x, e[i].key, 32); put64(x + 32, off[i]); put64(x + 40, e[i].len); }
    uint64_t total = pos + 48ull * n;
    memset(out, 0, GAL_ASTC_HEAD); memcpy(out, "S2ABCAST", 8); put32(out + 8, 1); put32(out + 12, 48);
    put64(out + 16, (uint64_t)n); put64(out + 24, pos); put64(out + 32, total); out[40] = 4; out[41] = 4;
    FILE *f = fopen(path, "wb"); fwrite(out, 1, total, f); fclose(f);
}
static nxgal_tex_info tinfo(int w, int h, int levels, int fmt, int target, int bw, int bpp) {
    nxgal_tex_info i = {w, h, 1, levels, 1, bw, bw, bpp, fmt, 0, target, {2, 3, 4, 5}};
    return i;
}
static nxgal_tex_info bc1(int w, int h, int levels) { return tinfo(w, h, levels, F_Bc1RgbaUnorm, 1, 4, 8); }
static uint64_t caps_bc(void) { uint64_t c[4]; nxgal_device_caps(c); return c[0] & NXGAL_CAP_BC; }
static MTLPixelFormat root_pf(uint32_t t) { gal_tex *x = gal_tex_get(t); return x && x->root ? x->root.pixelFormat : MTLPixelFormatInvalid; }
static MTLPixelFormat tex_pf(uint32_t t) { gal_tex *x = gal_tex_get(t); return x && x->tex ? x->tex.pixelFormat : MTLPixelFormatInvalid; }
static int all_px(const uint8_t *p, int n, uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
    for (int i = 0; i < n; i++) if (p[4 * i] != r || p[4 * i + 1] != g || p[4 * i + 2] != b || p[4 * i + 3] != a) return 0;
    return 1;
}

static char g_dir[] = "/tmp/t_bce.XXXXXX";
static uint8_t g_bc[40], g_bc_other[8], g_red[64], g_green[16];   // 8x8 两级 BC1：级 0 2×2 块 32 字节，级 1 1 块 8 字节
static char g_pack[300], g_bad[300];

static void setup(void) {
    for (int i = 0; i < 40; i++) g_bc[i] = (uint8_t)(i * 13 + 5);
    for (int i = 0; i < 8; i++) g_bc_other[i] = (uint8_t)(0xE0 + i);
    for (int k = 0; k < 4; k++) void_block(g_red + 16 * k, 0xFFFF, 0, 0, 0xFFFF);
    void_block(g_green, 0, 0xFFFF, 0, 0xFFFF);
    ent e[2];
    gal_astc_key(GAL_ASTC_FAM_BC1, 8, 8, g_bc, 32, e[0].key); memcpy(e[0].data, g_red, 64); e[0].len = 64;
    gal_astc_key(GAL_ASTC_FAM_BC1, 4, 4, g_bc + 32, 8, e[1].key); memcpy(e[1].data, g_green, 16); e[1].len = 16;
    snprintf(g_pack, sizeof g_pack, "%s/ok.pack", g_dir); write_pack(g_pack, e, 2);
    snprintf(g_bad, sizeof g_bad, "%s/bad.pack", g_dir);
    FILE *f = fopen(g_pack, "rb"), *o = fopen(g_bad, "wb"); uint8_t b[8192]; size_t n = fread(b, 1, sizeof b, f); fwrite(b, 1, n - 5, o); fclose(f); fclose(o);   // 截掉尾巴
}
static void use_pack(const char *p) { if (p) setenv("NXGAL_ASTC_PACK", p, 1); else unsetenv("NXGAL_ASTC_PACK"); gal_bce_reset(); }

static void t_hit_view_miss(void) {
    printf("· 整张命中 → ASTC；单级命中；视图；之后没命中 → 换解压格式\n");
    CHECK(nxgal_bce_active() == 1 && caps_bc(), "包可用、设备当成不支持 BC：应开这条路且能力表报 BC");
    nxgal_tex_info ti = bc1(8, 8, 2); uint32_t t = nxgal_tex_create(&ti);
    CHECK(t != 0, "建 BC1 贴图失败");
    CHECK(nxgal_tex_set_bc(t, -1, -1, NULL, g_bc, 40) == 1, "整张两级都在包里，应命中");
    CHECK(root_pf(t) == MTLPixelFormatASTC_4x4_LDR, "命中后底层格式 %lu，期望 ASTC_4x4_LDR", (unsigned long)root_pf(t));
    uint8_t rd[2048]; uint64_t n = nxgal_tex_get_data(t, -1, -1, rd, sizeof rd);
    CHECK(n == 80 && !memcmp(rd, g_red, 64) && !memcmp(rd + 64, g_green, 16), "读回 %llu 字节，期望 80 字节 = 包里红 4 块 + 绿 1 块", (unsigned long long)n);
    CHECK(nxgal_tex_set_bc(t, 0, 1, NULL, g_bc + 32, 8) == 1, "单传级 1（包里有）应命中");
    nxgal_tex_info vi = tinfo(8, 8, 2, F_Bc1RgbaSrgb, 1, 4, 8); uint32_t v = nxgal_tex_view(t, &vi, 0, 0);
    CHECK(v && tex_pf(v) == MTLPixelFormatASTC_4x4_sRGB, "BC1 sRGB 视图格式 %lu，期望 ASTC_4x4_sRGB", (unsigned long)tex_pf(v));
    // 级 1 换成包里没有的数据：整张换成解压格式（级 0 已有的红在 GPU 上解成像素），本次调用方解压后再传
    CHECK(nxgal_tex_set_bc(t, 0, 1, NULL, g_bc_other, 8) == 0, "级 1 的新数据不在包里，应没命中");
    CHECK(root_pf(t) == MTLPixelFormatRGBA8Unorm && gal_tex_get(t)->info.format == F_R8G8B8A8Unorm, "没命中后底层应是 RGBA8Unorm（%lu）", (unsigned long)root_pf(t));
    CHECK(tex_pf(v) == MTLPixelFormatRGBA8Unorm_sRGB && gal_tex_get(v)->bce == GAL_BCE_DEC, "视图应跟着换成 RGBA8Unorm_sRGB（%lu）", (unsigned long)tex_pf(v));
    n = nxgal_tex_get_data(t, 0, 0, rd, sizeof rd);
    CHECK(n == 256 && all_px(rd, 64, 255, 0, 0, 255), "级 0 应是原 ASTC 红块解出的 64 个 (255,0,0,255)（%llu 字节，首像素 %u %u %u %u）", (unsigned long long)n, rd[0], rd[1], rd[2], rd[3]);
    uint8_t px[64]; for (int i = 0; i < 64; i++) px[i] = (uint8_t)(i * 3);
    nxgal_tex_set_data(t, 0, 1, NULL, px, 64);   // 调用方（C#）解压后的 4x4 RGBA8
    n = nxgal_tex_get_data(t, 0, 1, rd, sizeof rd);
    CHECK(n == 64 && !memcmp(rd, px, 64), "级 1 解压数据写入后读回不对");
    CHECK(nxgal_tex_set_bc(t, -1, -1, NULL, g_bc, 40) == 0, "已是解压格式：不再查包，应返回 0");
    nxgal_tex_release(v); nxgal_tex_release(t);
}

static void t_first_miss(void) {
    printf("· 首次就没命中 / 待定被别的用法碰到 / 包存不了的族 / 非 BC\n");
    nxgal_tex_info ti = bc1(8, 8, 2); uint32_t t = nxgal_tex_create(&ti);
    uint8_t bc[40]; memcpy(bc, g_bc, 40); bc[0] ^= 1;   // 级 0 差一个字节：不在包里
    CHECK(nxgal_tex_set_bc(t, -1, -1, NULL, bc, 40) == 0, "级 0 不在包里，应没命中");
    CHECK(root_pf(t) == MTLPixelFormatRGBA8Unorm, "首次没命中应建解压格式 RGBA8Unorm（%lu）", (unsigned long)root_pf(t));
    uint8_t px[320], rd[320]; for (int i = 0; i < 320; i++) px[i] = (uint8_t)(i * 7 + 1);
    nxgal_tex_set_data(t, -1, -1, NULL, px, 320);   // 8x8 + 4x4 RGBA8
    CHECK(nxgal_tex_get_data(t, -1, -1, rd, sizeof rd) == 320 && !memcmp(rd, px, 320), "解压格式的整张写入读回不对");
    nxgal_tex_release(t);

    t = nxgal_tex_create(&ti);
    nxgal_tex_info vi = bc1(8, 8, 1); uint32_t v = nxgal_tex_view(t, &vi, 0, 0);   // 还没数据就建视图：定成解压格式
    CHECK(v && root_pf(t) == MTLPixelFormatRGBA8Unorm && tex_pf(v) == MTLPixelFormatRGBA8Unorm, "待定时建视图应先定成解压格式（父 %lu 视图 %lu）", (unsigned long)root_pf(t), (unsigned long)tex_pf(v));
    CHECK(nxgal_tex_set_bc(t, -1, -1, NULL, g_bc, 40) == 0, "已定成解压格式就不再查包");
    nxgal_tex_release(v); nxgal_tex_release(t);

    t = nxgal_tex_create(&ti); nxgal_tex_release(t);   // 待定直接放：不建存储、不崩
    CHECK(1, "");

    nxgal_tex_info si = tinfo(8, 8, 1, F_Bc4Snorm, 1, 4, 8); uint32_t s = nxgal_tex_create(&si);
    CHECK(s && root_pf(s) == MTLPixelFormatR8Snorm, "带符号 BC4 包存不了，应直接建解压格式 R8Snorm（%lu）", (unsigned long)root_pf(s));
    CHECK(nxgal_tex_set_bc(s, -1, -1, NULL, g_bc, 32) == 0, "带符号 BC4 应返回 0（调用方解压）");
    nxgal_tex_release(s);
    nxgal_tex_info ri = tinfo(4, 4, 1, F_R8G8B8A8Unorm, 1, 1, 4); uint32_t r = nxgal_tex_create(&ri);
    CHECK(nxgal_tex_set_bc(r, -1, -1, NULL, px, 64) == -1, "非 BC 贴图应返回 -1（照常上传）");
    nxgal_tex_release(r);
}

static void t_copy(void) {
    printf("· 互拷：ASTC → 待定（跟着 ASTC）；ASTC → 解压格式（ASTC 那边换解压格式）\n");
    nxgal_tex_info ti = bc1(8, 8, 2);
    uint32_t a = nxgal_tex_create(&ti), b = nxgal_tex_create(&ti), c = nxgal_tex_create(&ti);
    CHECK(nxgal_tex_set_bc(a, -1, -1, NULL, g_bc, 40) == 1, "a 应命中");
    nxgal_tex_copy(a, b, 0, 0);
    CHECK(root_pf(b) == MTLPixelFormatASTC_4x4_LDR, "待定的 b 被 ASTC 的 a 拷入，应定成 ASTC（%lu）", (unsigned long)root_pf(b));
    uint8_t rd[2048];
    CHECK(nxgal_tex_get_data(b, -1, -1, rd, sizeof rd) == 80 && !memcmp(rd, g_red, 64) && !memcmp(rd + 64, g_green, 16), "b 拷完应与 a 的 ASTC 块相同");
    uint8_t bc[40]; memcpy(bc, g_bc, 40); bc[3] ^= 0x40;
    CHECK(nxgal_tex_set_bc(c, -1, -1, NULL, bc, 40) == 0, "c 应没命中（解压格式）");
    nxgal_tex_copy_slice(a, c, 0, 0, 0, 0);
    CHECK(root_pf(a) == MTLPixelFormatRGBA8Unorm, "a（ASTC）拷进解压格式的 c 前应换成解压格式（%lu）", (unsigned long)root_pf(a));
    CHECK(nxgal_tex_get_data(c, 0, 0, rd, sizeof rd) == 256 && all_px(rd, 64, 255, 0, 0, 255), "c 级 0 应是 a 的红（首像素 %u %u %u %u）", rd[0], rd[1], rd[2], rd[3]);
    nxgal_tex_release(a); nxgal_tex_release(b); nxgal_tex_release(c);
}

static void t_off(void) {
    printf("· 包损坏 / 没设环境变量：整条路不开，BC 照原生建\n");
    use_pack(g_bad);
    CHECK(nxgal_bce_active() == 0 && !caps_bc(), "损坏的包应整包不用：不开这条路、能力表不报 BC（设备当成不支持）");
    nxgal_tex_info ti = bc1(8, 8, 2); uint32_t t = nxgal_tex_create(&ti);
    CHECK(t && gal_tex_get(t)->bce == GAL_BCE_NONE && root_pf(t) == MTLPixelFormatBC1_RGBA, "包不开时 BC1 应照原样建（%lu）", (unsigned long)root_pf(t));
    CHECK(nxgal_tex_set_bc(t, -1, -1, NULL, g_bc, 40) == -1, "包不开时应返回 -1");
    nxgal_tex_release(t);
    use_pack(NULL);
    CHECK(nxgal_bce_active() == 0, "没设 NXGAL_ASTC_PACK 不应开");
    gal_bce_test_nobc = 0; use_pack(g_pack);
    CHECK(nxgal_bce_active() == 0 && caps_bc(), "设备原生支持 BC 时不用包、能力表照报 BC");
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0); signal(SIGSEGV, on_sig); signal(SIGBUS, on_sig); signal(SIGABRT, on_sig);
    if (!mkdtemp(g_dir)) { printf("建临时目录失败\n"); return 2; }
    if (nxgal_init(0)) { printf("初始化失败\n"); return 2; }
    @autoreleasepool {
        if (![g_gdev supportsFamily:MTLGPUFamilyApple2]) { printf("本机不支持 ASTC，跳过\n"); return 0; }
        setup(); gal_bce_test_nobc = 1; use_pack(g_pack);
        t_hit_view_miss(); t_first_miss(); t_copy(); t_off();
    }
    nxgal_shutdown();
    char cmd[300]; snprintf(cmd, sizeof cmd, "rm -rf '%s'", g_dir); (void)!system(cmd);
    printf("%s：%d / %d 项通过\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks);
    return g_fail ? 1 : 0;
}
GAL_MTL4_ZONE_END
