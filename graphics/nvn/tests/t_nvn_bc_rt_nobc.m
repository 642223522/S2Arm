// 无 BC 的 GPU 上 BC 贴图当块写（nvn_mtl.m bcdec_attach / bcdec_flush，宿主图形未实现清单 G-11）：游戏在 GPU 上编码 BC，按「一个纹素 = 一个块」的整数视图
//   （BC1 → RGBA16UI 0x2C）把 BC 贴图当渲染目标写；无 BC 时底贴图存的是解压后的像素，原先按底格式画、块写进了像素。
// 跑法：DM_TEST_NO_BC=1 强制走无 BC 路径（本机 Mac 有 BC 也照样走）；公开 NVN bootstrap → 真实录制 → Metal 提交（同 t_nvn_partial_clear 的搭法），
//   直接包含生产 nvn_mtl.m，只为读解压后的底贴图（tex_mtl，GPU 读回）。
// 期望手算：8x8 的 RGBA_DXT1（2x2 个块）经 RGBA16UI 视图整张清成 {0xF800, 0, 0, 0} = 一个 BC1 块：color0 = RGB565 0xF800（纯红）、color1 = 0、
//   color0 > color1 走四色、索引全 0 → 16 个纹素都是 color0 = (255, 0, 0, 255)。读回解压后的底贴图 64 个像素全是红。
//   负对照：换回 main 的 nvn_mtl.m（没有块影子）→ 底贴图不是这 64 个红像素
#ifndef NVN_BCRT_SOURCE
#define NVN_BCRT_SOURCE "../gfx/nvn/nvn_mtl.m"
#endif
#include NVN_BCRT_SOURCE
#include "../gfx/nvn/nvn_protos.h"

extern void *h_nvnBootstrapLoader(const char *name);
static NVNdevice device; static NVNqueue queue; static NVNmemoryPool pool; static NVNcommandBuffer commands; static void *storage;
static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "SETUP FAIL %s:%d %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int good_ = !!(c); failures += !good_; printf("%s ", good_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
static void *load(const char *name) { void *e = h_nvnBootstrapLoader(name); REQUIRE(e != NULL); return e; }
#define API(name) ((NVNT_##name)load(#name))
enum { POOL_SIZE = 8 << 20, COMMAND_SIZE = 1 << 20, W = 8 };

int main(void) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IOLBF, 0); alarm(60);
        setenv("DM_TEST_NO_BC", "1", 1);
        NVNdeviceBuilder db; API(nvnDeviceBuilderSetDefaults)(&db); REQUIRE(API(nvnDeviceInitialize)(&device, &db));
        NVNqueueBuilder qb; API(nvnQueueBuilderSetDefaults)(&qb); API(nvnQueueBuilderSetDevice)(&qb, &device); REQUIRE(API(nvnQueueInitialize)(&queue, &qb));
        REQUIRE(posix_memalign(&storage, 65536, POOL_SIZE) == 0); memset(storage, 0, POOL_SIZE);
        NVNmemoryPoolBuilder pb; API(nvnMemoryPoolBuilderSetDefaults)(&pb); API(nvnMemoryPoolBuilderSetDevice)(&pb, &device);
        API(nvnMemoryPoolBuilderSetStorage)(&pb, storage, POOL_SIZE); API(nvnMemoryPoolBuilderSetFlags)(&pb, NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED);
        REQUIRE(API(nvnMemoryPoolInitialize)(&pool, &pb)); REQUIRE(API(nvnCommandBufferInitialize)(&commands, &device));
        static uint8_t control[16384]; API(nvnCommandBufferAddControlMemory)(&commands, control, sizeof control);
        printf("DEVICE %s backend=Metal%d no_bc=%d\n", g_dev.name.UTF8String, g_m3 ? 3 : 4, no_bc());
        REQUIRE(no_bc());
        NVNtexture T; NVNtextureBuilder b; API(nvnTextureBuilderSetDefaults)(&b); API(nvnTextureBuilderSetDevice)(&b, &device);
        API(nvnTextureBuilderSetTarget)(&b, NVN_TEXTURE_TARGET_2D); API(nvnTextureBuilderSetSize2D)(&b, W, W);
        API(nvnTextureBuilderSetFormat)(&b, NVN_FORMAT_RGBA_DXT1); API(nvnTextureBuilderSetFlags)(&b, 0);
        size_t al = API(nvnTextureBuilderGetStorageAlignment)(&b); size_t off = (COMMAND_SIZE + al - 1) / al * al;
        API(nvnTextureBuilderSetStorage)(&b, &pool, (ptrdiff_t)off); REQUIRE(API(nvnTextureInitialize)(&T, &b));
        NVNtextureView v; API(nvnTextureViewSetDefaults)(&v); API(nvnTextureViewSetFormat)(&v, NVN_FORMAT_RGBA16UI);
        API(nvnCommandBufferAddCommandMemory)(&commands, &pool, 0, COMMAND_SIZE); API(nvnCommandBufferBeginRecording)(&commands);
        const NVNtexture *ts[1] = {&T}; const NVNtextureView *vs[1] = {&v};
        API(nvnCommandBufferSetRenderTargets)(&commands, 1, ts, vs, NULL, NULL);
        API(nvnCommandBufferSetScissor)(&commands, 0, 0, W / 4, W / 4);
        uint32_t blk[4] = {0xF800, 0, 0, 0}; API(nvnCommandBufferClearColorui)(&commands, 0, blk, 15);
        NVNcommandHandle h = API(nvnCommandBufferEndRecording)(&commands); REQUIRE(h);
        API(nvnQueueSubmitCommands)(&queue, 1, &h); API(nvnQueueFinish)(&queue); REQUIRE(!mtl_last_commit_error());
        id<MTLTexture> base = tex_mtl((const tex_t *)&T); REQUIRE(base);
        printf("底贴图 Metal 格式 %lu %lux%lu\n", (unsigned long)base.pixelFormat, (unsigned long)base.width, (unsigned long)base.height);
        id<MTLBuffer> rb = [g_dev newBufferWithLength:W * W * 4 options:MTLResourceStorageModeShared]; id<MTLCommandQueue> q = [g_dev newCommandQueue];
        id<MTLCommandBuffer> cb = [q commandBuffer]; id<MTLBlitCommandEncoder> be = [cb blitCommandEncoder];
        [be copyFromTexture:base sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, W, 1) toBuffer:rb destinationOffset:0 destinationBytesPerRow:W * 4 destinationBytesPerImage:W * W * 4];
        [be endEncoding]; [cb commit]; [cb waitUntilCompleted];
        const uint8_t *px = rb.contents; int red = 0;
        for (int i = 0; i < W * W; i++) red += px[4 * i] == 255 && px[4 * i + 1] == 0 && px[4 * i + 2] == 0 && px[4 * i + 3] == 255;
        CHECK(base.pixelFormat == MTLPixelFormatRGBA8Unorm && red == W * W, "8x8 BC1 经 RGBA16UI 块视图清成纯红块：解压后的底贴图（格式 %lu，期望 RGBA8Unorm %lu）红像素 %d / %d（第 0 个像素 %d,%d,%d,%d）",
              (unsigned long)base.pixelFormat, (unsigned long)MTLPixelFormatRGBA8Unorm, red, W * W, px[0], px[1], px[2], px[3]);
        printf("%s t_nvn_bc_rt_nobc: %u checks %u failures; backend Metal%d\n", failures ? "✗" : "✓", checks, failures, g_m3 ? 3 : 4);
        return failures != 0;
    }
}
