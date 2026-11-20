// 超贴图上限缩建（nvn_rscale.inc 文件头）：游戏要的渲染目标边长超过设备二维贴图上限（Apple GPU 16384）时按 上限 ÷ 长边 缩建、记成已缩，
//   画面完整、只是这张目标分辨率降一档；原先 tex_desc 直接拒绝（「texture size exceeds Metal limits」），整张拿不到、画面全黑。
// 公开 NVN bootstrap → 真实录制、Metal 提交、公开读回（同 t_nvn_rscale 的搭法），内部分辨率设定为 1（S2A_RES_SCALE=1，玩家缺省）。
// 期望全部手算（不跑被测实现）：上限 L = 16384，游戏尺寸 20520x64 → 比例 s = 16384 / 20520，存储 ⌈20520 s⌉ x ⌈64 s⌉ = 16384 x 52；
//   同遍的 1024x64 附件 → ⌈1024 s⌉ x 52 = 818 x 52（818 = ⌈817.6…⌉）。
//   ① 超上限的目标建得出、存储 16384x52、记录「已缩」；清成红、右半（游戏 x ≥ 10260）清成绿，游戏坐标 ReadTexels 读回 = 手算的游戏尺寸图（分界两侧各 2 个游戏像素内放行：
//      读回取最近的存储纹素）；② 同一遍的普通尺寸附件（不可压缩：平时不缩）跟着换到同一比例 818x52、清色读回对；
//   ③ 超上限缩建的存储退不回原尺寸（rs_rescale_to 拒绝，存储与记录不变）；④ 对照：设定为 1 时，单独一遍的普通渲染目标 64x48 照旧原尺寸、记录「没缩」。
// 负对照：main 的 nvn_mtl.m（超上限直接拒绝）①建不出（存储查不到），后面各项不通。
#include "../gfx/nvn/nvn_mtl.m"
#include "../gfx/nvn/nvn_protos.h"

extern void *h_nvnBootstrapLoader(const char *name);

static NVNdevice device; static NVNqueue queue; static NVNmemoryPool pool; static NVNcommandBuffer commands; static void *storage;
static size_t texture_offset = 4 << 20; static unsigned checks, fails; static const char *phase = "初始化";
enum { POOL_SIZE = 64 << 20, COMMAND_SIZE = 1 << 20, GW = 20520, GH = 64, SW = 16384, SH = 52, NW = 1024, NSW = 818 };
#define REQUIRE(x) do { checks++; if (!(x)) { fprintf(stderr, "FAIL [%s] %s:%d: %s\n", phase, __FILE__, __LINE__, #x); fails++; } } while (0)
static void *load(const char *name) { void *e = h_nvnBootstrapLoader(name); if (!e) { fprintf(stderr, "缺入口 %s\n", name); exit(1); } return e; }
#define API(name) ((NVNT_##name)load(#name))

static void setup(void) {
    NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); REQUIRE(API(nvnDeviceInitialize)(&device, &db));
    NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb, &device); REQUIRE(API(nvnQueueInitialize)(&queue, &qb));
    REQUIRE(posix_memalign(&storage, 65536, POOL_SIZE) == 0); memset(storage, 0, POOL_SIZE);
    NVNmemoryPoolBuilder pb; API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb, &device);
    API(nvnMemoryPoolBuilderSetStorage)(&pb, storage, POOL_SIZE); API(nvnMemoryPoolBuilderSetFlags)(&pb, NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
    REQUIRE(API(nvnMemoryPoolInitialize)(&pool, &pb)); REQUIRE(API(nvnCommandBufferInitialize)(&commands, &device));
    static uint8_t control[16384]; API(nvnCommandBufferAddControlMemory)(&commands, control, sizeof control);
}
static void begin(void) { API(nvnCommandBufferAddCommandMemory)(&commands, &pool, 0, COMMAND_SIZE); API(nvnCommandBufferBeginRecording)(&commands); }
static void submit(void) {
    NVNcommandHandle h = API(nvnCommandBufferEndRecording)(&commands); REQUIRE(h != 0);
    API(nvnQueueSubmitCommands)(&queue, 1, &h); API(nvnQueueFinish)(&queue); REQUIRE(mtl_last_commit_error() == 0);
}
static void make_tex(NVNtexture *t, int w, int h, int flags) {
    NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b, &device);
    API(nvnTextureBuilderSetTarget)(&b, NVN_TEXTURE_TARGET_2D); API(nvnTextureBuilderSetSize2D)(&b, w, h); API(nvnTextureBuilderSetLevels)(&b, 1);
    API(nvnTextureBuilderSetFormat)(&b, NVN_FORMAT_RGBA8); API(nvnTextureBuilderSetFlags)(&b, flags);
    size_t al = API(nvnTextureBuilderGetStorageAlignment)(&b), sz = API(nvnTextureBuilderGetStorageSize)(&b);
    texture_offset = (texture_offset + al - 1) / al * al; REQUIRE(texture_offset + sz <= POOL_SIZE);
    API(nvnTextureBuilderSetStorage)(&b, &pool, (ptrdiff_t)texture_offset); texture_offset += sz;
    REQUIRE(API(nvnTextureInitialize)(t, &b));
}
static void storage_is(NVNtexture *t, int want_state, int sw, int sh) {
    int w = 0, h = 0, st = nvn_be_tex_storage_size(t, &w, &h);
    printf("  存储 %dx%d 记录 %d（期望 %dx%d 记录 %d）\n", w, h, st, sw, sh, want_state);
    REQUIRE(st == want_state && w == sw && h == sh);
}
static void fill(float f[4], const uint8_t c[4]) { for (int i = 0; i < 4; i++) f[i] = c[i] / 255.0f; }
static const uint8_t RED[4] = {255, 0, 0, 255}, GREEN[4] = {0, 255, 0, 255}, BLUE[4] = {0, 0, 255, 255};
// 游戏坐标读回整张，逐像素对手算的期望 want(x)；分界 edge 两侧各 tol 个游戏像素内放行（取最近存储纹素，落哪边都算对）
static void read_is(NVNtexture *t, int w, int h, int edge, int tol, const uint8_t *left, const uint8_t *right, const char *what) {
    uint8_t *got = malloc((size_t)w * h * 4); memset(got, 0xA5, (size_t)w * h * 4);
    NVNcopyRegion r = {0, 0, 0, w, h, 1}; API(nvnTextureReadTexels)(t, NULL, &r, got);
    long exact = 0, band = 0; int bad = 0;
    for (int y = 0; y < h && !bad; y++) for (int x = 0; x < w; x++) {
        const uint8_t *g = got + 4 * ((size_t)y * w + x), *e = x < edge ? left : right;
        if (!memcmp(g, e, 4)) { exact++; continue; }
        if (tol && x >= edge - tol && x < edge + tol && (!memcmp(g, left, 4) || !memcmp(g, right, 4))) { band++; continue; }
        fprintf(stderr, "FAIL [%s] %s (%d,%d) 得 %d,%d,%d,%d 期望 %d,%d,%d,%d\n", phase, what, x, y, g[0], g[1], g[2], g[3], e[0], e[1], e[2], e[3]); bad = 1; break;
    }
    checks++; if (bad) fails++;
    printf("  %s：%ld 个逐字节相等，%ld 个在分界带\n", what, exact, band);
    free(got);
}

int main(void) {
    @autoreleasepool {
    setenv("S2A_RES_SCALE", "1", 1);
    setup();
    NVNtexture BIG, SIDE, SMALL;
    make_tex(&BIG, GW, GH, NVN_TEXTURE_FLAGS_COMPRESSIBLE);   // 游戏的超宽交换链（#1493：10K 补丁 20520x4320，这里取 64 行省内存，规则只看边长）
    make_tex(&SIDE, NW, GH, 0);                               // 不可压缩：平时不缩（rs_eligible 否决）
    make_tex(&SMALL, 64, 48, NVN_TEXTURE_FLAGS_COMPRESSIBLE);

    phase = "① 超上限的目标缩建、清色读回";
    // 先单独一遍清 BIG；再开一遍 BIG + SIDE 同挂、只清 SIDE（宽度不同的附件同挂时 Metal 的渲染区取最小附件，与本功能无关，所以 BIG 的内容在单独那遍画）
    { float f[4]; const NVNtexture *t1[1] = {&BIG}, *t2[2] = {&BIG, &SIDE};
      begin(); API(nvnCommandBufferSetRenderTargets)(&commands, 1, t1, NULL, NULL, NULL);
      API(nvnCommandBufferSetScissor)(&commands, 0, 0, GW, GH); fill(f, RED); API(nvnCommandBufferClearColor)(&commands, 0, f, 15);
      API(nvnCommandBufferSetScissor)(&commands, GW / 2, 0, GW - GW / 2, GH); fill(f, GREEN); API(nvnCommandBufferClearColor)(&commands, 0, f, 15);
      API(nvnCommandBufferSetRenderTargets)(&commands, 2, t2, NULL, NULL, NULL);
      API(nvnCommandBufferSetScissor)(&commands, 0, 0, NW, GH); fill(f, BLUE); API(nvnCommandBufferClearColor)(&commands, 1, f, 15);
      submit(); }
    storage_is(&BIG, RS_SCALED, SW, SH);
    if (!fails) read_is(&BIG, GW, GH, GW / 2, 2, RED, GREEN, "BIG 游戏坐标读回 = 左红右绿");
    printf("%s %s\n", fails ? "FAIL" : "PASS", phase); unsigned f1 = fails;

    phase = "② 同一遍的普通尺寸附件跟着换到同一比例";
    storage_is(&SIDE, RS_SCALED, NSW, SH);
    if (fails == f1) read_is(&SIDE, NW, GH, NW, 0, BLUE, BLUE, "SIDE 游戏坐标读回 = 全蓝");
    printf("%s %s\n", fails == f1 ? "PASS" : "FAIL", phase); unsigned f2 = fails;

    phase = "③ 超上限缩建的存储退不回原尺寸";
    { id<MTLTexture> b = tex_mtl((const tex_t *)&BIG);
      REQUIRE(b != nil);
      if (b) { id<MTLTexture> n = rs_rescale_to(b, 1.0, "单测"); REQUIRE(n == nil); }
      storage_is(&BIG, RS_SCALED, SW, SH); }
    printf("%s %s\n", fails == f2 ? "PASS" : "FAIL", phase); unsigned f3 = fails;

    phase = "④ 对照：设定为 1 时普通渲染目标照旧原尺寸";
    { float f[4]; const NVNtexture *ts[1] = {&SMALL};
      begin(); API(nvnCommandBufferSetRenderTargets)(&commands, 1, ts, NULL, NULL, NULL);
      API(nvnCommandBufferSetScissor)(&commands, 0, 0, 64, 48); fill(f, BLUE); API(nvnCommandBufferClearColor)(&commands, 0, f, 15); submit(); }
    storage_is(&SMALL, RS_NONE, 64, 48);
    if (fails == f3) read_is(&SMALL, 64, 48, 64, 0, BLUE, BLUE, "SMALL 游戏坐标读回 = 全蓝");
    printf("%s %s\n", fails == f3 ? "PASS" : "FAIL", phase);

    if (fails) { printf("✗ t_nvn_rs_oversize：%u 项里 %u 项不通（%s）\n", checks, fails, g_m3 ? "Metal3" : "Metal4"); return 1; }
    printf("✓ t_nvn_rs_oversize：4 组 %u 项全过（%s）\n", checks, g_m3 ? "Metal3" : "Metal4");
    }
    return 0;
}
