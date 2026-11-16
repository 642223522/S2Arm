// 切后台瘦身只标能从客体内存重建的打包贴图（nvn_mtl.m nvn_be_background_purge，11-16 D-CZCW：纯 GPU 贴图被系统清掉后找不回，回前台花屏）。
// 期望按语义手写，不由被测实现推出：驻留集里三张私有贴图——A 打包贴图（NvPkg，CPU 内容）、B 纯 GPU 贴图、C GPU 写过的打包贴图（NvPkg 带 pgpu）
//   ① 进后台：A 变可清除（Volatile），B、C 保持不可清除（NonVolatile）
//   ② 回前台：A 标回不可清除
#include "../gfx/nvn/nvn_mtl.m"
static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "SETUP FAIL %s:%d %s\n", __FILE__, __LINE__, #c); exit(2); } } while (0)
#define CHECK(c, ...) do { checks++; int ok_ = !!(c); failures += !ok_; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
static const char *st(MTLPurgeableState s) { return s == MTLPurgeableStateNonVolatile ? "不可清除" : s == MTLPurgeableStateVolatile ? "可清除" : s == MTLPurgeableStateEmpty ? "已清" : "?"; }
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0); alarm(60); unsetenv("S2A_BG_PURGE");
    mtl_init(); printf("BACKEND %s\n", g_m3 ? "Metal3" : "Metal4");
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:256 height:256 mipmapped:NO];
    d.storageMode = MTLStorageModePrivate; d.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    id<MTLTexture> A = [g_dev newTextureWithDescriptor:d], B = [g_dev newTextureWithDescriptor:d], C = [g_dev newTextureWithDescriptor:d]; REQUIRE(A && B && C);
    res_add(A); res_add(B); res_add(C); res_commit();
    NvPkg *pa = [NvPkg new]; pa->tex = A;
    NvPkg *pc = [NvPkg new]; pc->tex = C; pc->pgpu = calloc(1, sizeof(uint64_t));
    uint64_t ka = 101, kb = 102, kc = 103;
    pthread_mutex_lock(&g_smu); hm_put_id(&g_by_serial, &ka, pa); hm_put_id(&g_by_serial, &kb, B); hm_put_id(&g_by_serial, &kc, pc); pthread_mutex_unlock(&g_smu);
    nvn_be_background_purge(1);
    MTLPurgeableState sa = [A setPurgeableState:MTLPurgeableStateKeepCurrent], sb = [B setPurgeableState:MTLPurgeableStateKeepCurrent], sc = [C setPurgeableState:MTLPurgeableStateKeepCurrent];
    CHECK(sa == MTLPurgeableStateVolatile && sb == MTLPurgeableStateNonVolatile && sc == MTLPurgeableStateNonVolatile,
          "① 进后台：打包贴图 A %s（应可清除）、纯 GPU 贴图 B %s、GPU 写过的打包贴图 C %s（都应不可清除）", st(sa), st(sb), st(sc));
    nvn_be_background_purge(0);
    sa = [A setPurgeableState:MTLPurgeableStateKeepCurrent];
    CHECK(sa == MTLPurgeableStateNonVolatile || sa == MTLPurgeableStateEmpty, "② 回前台：A %s（应标回不可清除；被系统清了则为已清、登记重传）", st(sa));
    printf("%s t_nvn_bg_purge：%u 项，%u 项不符\n", failures ? "✗" : "✓", checks, failures);
    return failures != 0;
} }
