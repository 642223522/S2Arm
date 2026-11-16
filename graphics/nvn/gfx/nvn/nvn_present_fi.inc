// 出图补帧（11-14 维护者手测后定，取代我方 60 帧；DM_PRESENT_FI=1 备好功能，iOS 设置页缺省写 1，开不开按这款的「补帧」开关当场定，s2a_fi_set_live）。给原本 30 帧的游戏在屏上补到 60 帧：游戏一帧不少画、节拍不动。
// 流程：游戏每交一帧，出图线程只把它缩拷成一张输入图（BGRA8，按游戏画面比例、高 ≤ DM_PRESENT_FI_MAXH，缺省 1080）就返回（不等 GPU）；这次拷贝做完的回调
//   把这一帧交给补帧队列（串行），那里用 MetalFX 帧插值（MTLFXFrameInterpolator，iOS / macOS 26）由上一帧与这一帧补出正中的一帧：
//   整画面插值，深度填常数 1、运动矢量填 0（同 devinhurry/nxnative fix/ios-framegen-reference 的 nvn_fg.inc，MIT；一台 iPhone 上一款 30 帧开放世界游戏实测 28.56 → 59.98 帧、GPU 15.36 ms）；
//   先上补出来的帧，再隔半个游戏周期把游戏的原图直接画上屏（原分辨率），原图上屏的命令做完才把这一帧的票记完成。
//   比 11-13 的 VideoToolbox 版少了 RGB ↔ YUV 两次转换（那一版只走流程就 +1.3 W）；MetalFX 在单独一条 Metal 命令队列上编码，输入图写完（Metal 4 回调）才编、做完才上屏。
// 超时：补帧在 DM_PRESENT_FI_BUDGET_MS（缺省 12）毫秒内没做完就跳过这一次，直接上真帧，不等它。
// 只走 Metal 4 + 有窗口的出图线程（开着时从启动就不建显示链接）；系统不支持、任何一步建不出来就整段回退到原来的出图，报红一次。
// 线程：present_blit_m4 用到出图的共用状态（遍描述、管线缓存、驻留集提交），出图线程与补帧队列在 g_fi_enc_mu 下串行编码。
// MetalFX 头由 nvn_mtl.m 先包含的 nvn_present_fx.inc 带进来（本文件只在它之后被包含；不在共用文件里再直接包含苹果头，分层规则 R-02）
#include "nvn_fi_rule.h"   // 逐帧判定：只补 30 帧档或更低档、跑满的帧（dm_fi_should_interp）

API_AVAILABLE(macos(26.0), ios(26.0))
@interface NvPresentFI : NSObject {
@public
    int w, h; NSUInteger hw, hh; MTLPixelFormat hpf; uint64_t n;
    id<MTLTexture> in_tex[3], mid_tex, depth, motion;   // 输入图三张轮换（这一帧 / 上一帧 / 出图线程正在写的下一帧，读写不撞同一张）、补出的帧、常数深度、零运动
    id<MTLFXFrameInterpolator> mfx; id<MTLCommandQueue> mq;   // MetalFX 帧插值在自己的 Metal 命令队列上编码
    id<MTLRenderPipelineState> psoCopy;
    id<MTLComputePipelineState> mvDown, mvMatch, mvSpread; id<MTLTexture> lumaCur, lumaPrev; id<MTLBuffer> mvBlocks; int qw, qh, bw, bh;   // 自算运动矢量（DM_PRESENT_FI_MV）
    id<MTLBuffer> uv[4]; id tab[4];   // 命令槽 0 写输入（出图线程）、1 上补出的帧、2 上真帧（补帧队列）
    id alloc[3], cb[3];   // Metal 4 分配器 / 命令缓冲（MTL4 棘轮：用 id，经 nvn_mtl.m 的 m4_* 包装）
    dispatch_semaphore_t slot_free[3];
    int in_busy[3];   // 每张输入图上还在 GPU 上算的 MetalFX 读者数（g_pq_mu 下）：出图线程写这张前等它归零（fi_in_wait）
    dispatch_queue_t q; uint64_t last_seq, jobs;
    uint64_t made, skipped, shown_mid, declined, last_in_ns; double ms_sum, ms_max, gpu_sum;
    double bd_enc, bd_queue, bd_cb, bd_n; uint64_t made_win0;   // made_win0：本窗口开头的补成数（MetalFX GPU 平均按本窗口补成次数除）   // 拆账（常开，每 300 帧一行）：作业开始→提交 / 提交→GPU 开始（排在游戏 GPU 工作后面等）/ GPU 结束→完成回调，毫秒累计   // declined：按规则不补的帧（60 帧档 / 跑不满），原图直接上屏
}
@end
@implementation NvPresentFI @end

__attribute__((weak)) int s2a_fps_source(void) { return 1; }   // runtime/src/caps.c 给强定义（2 = 社区帧率补丁开着）；图形单测不链宿主时按「补帧」
static int g_fi_state = -1;   // -1 没读开关；0 关 / 已回退；1 开
static id g_fi;               // NvPresentFI
static double g_fi_budget_ms = 12;
// 和显示链互斥（11-15 #ee56e7 / #1155：补帧开着时出图切到显示链模式，补帧任务在自己队列里照样 nextDrawable，Core Animation 抛
//   CAMetalLayerInvalidOperation 整个 App 退出；切换前后新旧两路同时交帧 = 频闪）。经典出图线程取画布时 g_classic_busy、显示链挂图层前先占 g_link_owns_layer 再等它归零
//   （nvn_mtl.m link_main）；补帧任务不在这套里。现在：派任务时在途数 +1、两张画布交完 -1，显示链等「经典出图空闲且没有在途补帧」才挂；
//   任务取画布前看一眼图层归不归显示链，归了就不取、只记票完成（这一帧丢掉，不两路交帧）。以下都在 g_pq_mu 下
static int g_link_owns_layer, g_classic_busy;   // 暂定定义：同 nvn_mtl.m 出图段那一行是同一对象
static int g_fi_inflight;                       // 已派出、两张画布还没交完的补帧任务数
static int link_layer_busy(void) { return g_classic_busy || g_fi_inflight; }   // 显示链还不能挂图层
static int fi_may_take_drawable(void) { return !g_link_owns_layer; }           // 补帧任务这时能不能 nextDrawable
static void fi_inflight_add(int d) { pthread_mutex_lock(&g_pq_mu); g_fi_inflight += d; if (d < 0) pthread_cond_broadcast(&g_pq_cv); pthread_mutex_unlock(&g_pq_mu); }
// 局中当场开 / 关补帧（iOS 齿轮菜单「补帧」调 s2a_fi_set_live，起局按这款的设置设）。关 = 这一帧起走原出图路径（同社区帧率补丁暂停那支），开 = 接着补
static _Atomic int g_fi_live = 1;
__attribute__((visibility("default"))) void s2a_fi_set_live(int on) { atomic_store(&g_fi_live, on ? 1 : 0); }

// 显示链跟着「这一帧补不补」走（审计 P1-188）：补 → 0（补帧任务自己取画布）；玩家局中关补帧 / 社区帧率补丁接手 → 回到不补帧时的出图方式（g_link_base），
//   原出图路径照旧有显示链。补丁要的 120 Hz 链（2）归补丁管（runtime/src/cpatch.c fps_link），这里不动。切换由 link_sync 每帧对齐，
//   显示链挂图层前等经典出图与在途补帧都交完（g_link_owns_layer，#ee56e7）
static void fi_link_follow(int fi) {
    if (g_dm_present_link == 2) return;
    int want = fi ? 0 : g_link_base;
    if (g_dm_present_link != want) { MLOG("present frame interpolation: display link %s", want ? "back on (not interpolating)" : "off (interpolating)"); g_dm_present_link = want; }
}
static int fi_wanted_now(void);
static int fi_wanted(void) { int on = fi_wanted_now(); if (g_fi_state == 1) fi_link_follow(on); return on; }
static int fi_wanted_now(void) {
    if (g_fi_state < 0) { const char *e = getenv("DM_PRESENT_FI"), *b = getenv("DM_PRESENT_FI_BUDGET_MS");
        g_fi_state = e && !strcmp(e, "1") && !g_m3; if (b && atof(b) > 0) g_fi_budget_ms = atof(b);
        if (g_fi_state) { MLOG("present frame interpolation: on (DM_PRESENT_FI=1), budget %.1f ms, display link off", g_fi_budget_ms); } }
    if (g_fi_state != 1) return 0;
    // 帧率来源（runtime/include/caps.h s2a_fps_source：补丁 > 补帧 > 原帧率）：有开着的社区帧率补丁这一帧就不补、走原出图路径（显示链照常，补丁的 60–120 Hz 才生效）；
    //   每帧按当下来源判，60 帧开关局中切换、补丁跟着开关变也随即跟上
    { int live = atomic_load(&g_fi_live); static int lw = 1; if (live != lw) { MLOG("present frame interpolation: %s by the player (in-game switch)", live ? "on" : "off"); lw = live; } if (!live) return 0; }
    int patch = s2a_fps_source() == 2; static int was = -1;
    if (patch != was) { if (patch || was == 1) MLOG("present frame interpolation: %s", patch ? "paused, a community frame-rate patch is active (patch > interpolation)" : "resumed, no active frame-rate patch"); was = patch; }
    return !patch;
}
static void fi_off(const char *why) { g_fi_state = 0; g_fi = nil; MLOG("【红】 present frame interpolation turned off: %s; presenting as before", why); fi_link_follow(0); }   // 整段回退：显示链设回（审计 P1-188）

API_AVAILABLE(macos(26.0), ios(26.0))
static id<MTLTexture> fi_tex(MTLPixelFormat pf, int w, int h, MTLTextureUsage u) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:(NSUInteger)w height:(NSUInteger)h mipmapped:NO];
    td.usage = u; td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:td];
    if (t) res_add(t);
    return t;
}
// 输入缩拷与补出帧上屏共用的一遍：采源图（按裁剪）写目标
API_AVAILABLE(macos(26.0), ios(26.0))
// 自算运动矢量（DM_PRESENT_FI_MV，缺省 1；-1 取反对照方向，0 = 零矢量）：零矢量时 MetalFX 只能混合前后两帧，镜头快转时重影（11-14 iPhone 实机 一款 30 帧开放世界游戏：主角半透明叠在岩壁上）。
//   在 1/4 分辨率亮度图上做块匹配：块 8×8（原图 32×32 像素），每块一个线程组、1024 线程各算一个位移（-16..15，原图约 ±64 像素），块与搜索窗先读进组内共享内存；
//   块位移按块中心双线性铺成整张运动矢量图（输入图像素，当前帧 → 前一帧）；-1 = 取反（MetalFX 方向约定没把握时对照用）。
//   11-14 第一版每块一个线程（全画面约 920 线程、每线程串行 7 万次比较）在iPhone 实机 上多花约 5 ms、九成多帧超预算跳过，改成每块一组
static int fi_mv_mode(void) { static int v = -2; if (v == -2) { const char *e = getenv("DM_PRESENT_FI_MV"); v = e ? atoi(e) : 1; if (v) MLOG("present frame interpolation: computed motion vectors (DM_PRESENT_FI_MV=%d), 8x8 blocks on a quarter-size luma, search +-16", v); } return v; }
API_AVAILABLE(macos(26.0), ios(26.0))
static int fi_mv_setup(NvPresentFI *f) {
    static const char *msl =
        "#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void down(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]], uint2 g [[thread_position_in_grid]]) {\n"
        "  if (g.x >= dst.get_width() || g.y >= dst.get_height()) return; float s = 0;\n"
        "  for (uint y = 0; y < 4; y++) for (uint x = 0; x < 4; x++) { float3 c = src.read(uint2(g.x * 4 + x, g.y * 4 + y)).rgb; s += dot(c, float3(0.299, 0.587, 0.114)); }\n"
        "  dst.write(float4(s / 16, 0, 0, 0), g); }\n"
        "kernel void match(texture2d<float, access::read> cur [[texture(0)]], texture2d<float, access::read> prev [[texture(1)]], device float2* out [[buffer(0)]], constant uint2& nb [[buffer(1)]],\n"
        "                  uint2 b [[threadgroup_position_in_grid]], uint2 t [[thread_position_in_threadgroup]], uint li [[thread_index_in_threadgroup]], uint sl [[thread_index_in_simdgroup]], uint sg [[simdgroup_index_in_threadgroup]]) {\n"
        "  threadgroup float blk[64]; threadgroup float win[40 * 40]; threadgroup uint part[32]; threadgroup float zsad;\n"
        "  int W = cur.get_width(), H = cur.get_height(); int2 o = int2(b) * 8;\n"
        "  if (li < 64) { int2 p = clamp(o + int2(li % 8, li / 8), int2(0), int2(W - 1, H - 1)); blk[li] = cur.read(uint2(p)).r; }\n"
        "  for (uint k = li; k < 1600; k += 1024) { int2 q = clamp(o + int2(int(k % 40) - 16, int(k / 40) - 16), int2(0), int2(W - 1, H - 1)); win[k] = prev.read(uint2(q)).r; }\n"
        "  threadgroup_barrier(mem_flags::mem_threadgroup);\n"
        "  float sad = 0; for (int y = 0; y < 8; y++) for (int x = 0; x < 8; x++) sad += abs(blk[y * 8 + x] - win[(int(t.y) + y) * 40 + int(t.x) + x]);\n"
        "  if (t.x == 16 && t.y == 16) zsad = sad;\n"
        "  uint key = (as_type<uint>(sad) & ~0x3FFu) | li;   // 正浮点按位序即数值序：低 10 位换成线程号，取最小同时带出位移\n"
        "  key = simd_min(key); if (sl == 0) part[sg] = key;\n"
        "  threadgroup_barrier(mem_flags::mem_threadgroup);\n"
        "  if (sg == 0) { uint k2 = simd_min(sl < 32 ? part[sl] : 0xFFFFFFFFu);\n"
        "    if (sl == 0) { uint bi = k2 & 0x3FFu; float best = as_type<float>(k2 & ~0x3FFu); int2 bd = int2(int(bi % 32) - 16, int(bi / 32) - 16);\n"
        "      if (zsad <= best * 1.02 + 0.05) bd = int2(0);   // 不动或平坦处偏向零位移，免得乱跳\n"
        "      out[b.y * nb.x + b.x] = float2(bd) * 4; } } }\n"
        "kernel void spread(device const float2* blk [[buffer(0)]], constant uint2& nb [[buffer(1)]], constant float& sign [[buffer(2)]], constant uint& sc [[buffer(3)]], texture2d<float, access::write> mv [[texture(0)]],\n"
        "                   texture2d<float, access::read> cur [[texture(1)]], texture2d<float, access::read> prev [[texture(2)]], uint2 g [[thread_position_in_grid]]) {\n"
        "  if (g.x >= mv.get_width() || g.y >= mv.get_height()) return;\n"
        "  uint2 gp = g * sc + sc / 2; float2 u = (float2(g) + 0.5) * float(sc) / 32.0 - 0.5; int2 i0 = int2(floor(u)); float2 t = u - float2(i0);\n"
        "  int2 a = clamp(i0, int2(0), int2(nb) - 1), c = clamp(i0 + 1, int2(0), int2(nb) - 1);\n"
        "  float2 v = mix(mix(blk[a.y * nb.x + a.x], blk[a.y * nb.x + c.x], t.x), mix(blk[c.y * nb.x + a.x], blk[c.y * nb.x + c.x], t.x), t.y);\n"
        "  if (all(abs(cur.read(gp).rgb - prev.read(gp).rgb) < 0.004)) v = float2(0);   // 前后两帧这个像素一样（界面、静止物体）：不动，免得跟着背景被搬走\n"
        "  mv.write(float4(v * sign, 0, 0), g); }\n";
    NSError *e = nil; id<MTLLibrary> lib = [g_dev newLibraryWithSource:@(msl) options:nil error:&e];
    if (!lib) { MLOG("【红】 frame interpolation motion shader: %s", e.localizedDescription.UTF8String); return 0; }
    f->mvDown = [g_dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"down"] error:&e];
    f->mvMatch = [g_dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"match"] error:&e];
    f->mvSpread = [g_dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"spread"] error:&e];
    f->qw = f->w / 4; f->qh = f->h / 4; f->bw = (f->qw + 7) / 8; f->bh = (f->qh + 7) / 8;
    f->lumaCur = fi_tex(MTLPixelFormatR16Float, f->qw, f->qh, MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite);
    f->lumaPrev = fi_tex(MTLPixelFormatR16Float, f->qw, f->qh, MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite);
    f->mvBlocks = [g_dev newBufferWithLength:(NSUInteger)(f->bw * f->bh) * 8 options:MTLResourceStorageModePrivate];
    if (!f->mvDown || !f->mvMatch || !f->mvSpread || !f->lumaCur || !f->lumaPrev || !f->mvBlocks) { MLOG("【红】 frame interpolation motion setup: %s", e.localizedDescription.UTF8String ?: "resources"); return 0; }
    return 1;
}
// 在 MetalFX 之前编进同一条命令缓冲：前后两帧缩成 1/4 亮度 → 逐块匹配 → 铺成运动矢量图（写 f->motion）
API_AVAILABLE(macos(26.0), ios(26.0))
static void fi_mv_encode(NvPresentFI *f, id<MTLCommandBuffer> c, id<MTLTexture> cur, id<MTLTexture> prev, float sign) {
    id<MTLComputeCommandEncoder> en = [c computeCommandEncoder];
    MTLSize tg = MTLSizeMake(8, 8, 1);
    [en setComputePipelineState:f->mvDown];
    [en setTexture:cur atIndex:0]; [en setTexture:f->lumaCur atIndex:1]; [en dispatchThreads:MTLSizeMake(f->qw, f->qh, 1) threadsPerThreadgroup:tg];
    [en setTexture:prev atIndex:0]; [en setTexture:f->lumaPrev atIndex:1]; [en dispatchThreads:MTLSizeMake(f->qw, f->qh, 1) threadsPerThreadgroup:tg];
    [en memoryBarrierWithScope:MTLBarrierScopeTextures];
    uint32_t nb[2] = {(uint32_t)f->bw, (uint32_t)f->bh};
    [en setComputePipelineState:f->mvMatch]; [en setTexture:f->lumaCur atIndex:0]; [en setTexture:f->lumaPrev atIndex:1];
    [en setBuffer:f->mvBlocks offset:0 atIndex:0]; [en setBytes:nb length:sizeof nb atIndex:1];
    [en dispatchThreadgroups:MTLSizeMake(f->bw, f->bh, 1) threadsPerThreadgroup:MTLSizeMake(32, 32, 1)];   // 每块一组，组内 1024 线程各算一个位移（±16 → 32×32）
    [en memoryBarrierWithScope:MTLBarrierScopeBuffers];
    [en setComputePipelineState:f->mvSpread]; [en setBuffer:f->mvBlocks offset:0 atIndex:0]; [en setBytes:nb length:sizeof nb atIndex:1]; [en setBytes:&sign length:4 atIndex:2]; uint32_t sc = (uint32_t)(f->w / f->motion.width); [en setBytes:&sc length:4 atIndex:3];
    [en setTexture:f->motion atIndex:0]; [en setTexture:cur atIndex:1]; [en setTexture:prev atIndex:2]; [en dispatchThreads:MTLSizeMake(f->motion.width, f->motion.height, 1) threadsPerThreadgroup:tg];
    [en endEncoding];
}
API_AVAILABLE(macos(26.0), ios(26.0))
static int fi_copy_setup(NvPresentFI *f) {
    static const char *msl =
        "#include <metal_stdlib>\nusing namespace metal;\n"
        "struct V { float4 p [[position]]; float2 uv; };\n"
        "vertex V vs(uint id [[vertex_id]]) { float2 uv = float2((id << 1) & 2, id & 2); V o; o.p = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1); o.uv = uv; return o; }\n"
        "struct Crop { float4 rect; float4 edge; };\n"
        "fragment float4 fsCopy(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant Crop& c [[buffer(0)]]) { return float4(t.sample(s, clamp(in.uv * c.rect.zw + c.rect.xy, c.edge.xy, c.edge.zw)).rgb, 1); }\n";
    NSError *e = nil; id<MTLLibrary> lib = [g_dev newLibraryWithSource:@(msl) options:nil error:&e];
    if (!lib) { MLOG("【红】 frame interpolation shader: %s", e.localizedDescription.UTF8String); return 0; }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"vs"]; pd.fragmentFunction = [lib newFunctionWithName:@"fsCopy"]; pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    f->psoCopy = [g_dev newRenderPipelineStateWithDescriptor:pd error:&e];
    if (!f->psoCopy) { MLOG("【红】 frame interpolation pipeline: %s", e.localizedDescription.UTF8String); return 0; }
    return 1;
}
// 建 / 重建（画布尺寸与格式跟着 layer；画面比例变了整个重建）。返回 nil = 回退
API_AVAILABLE(macos(26.0), ios(26.0))
static NvPresentFI *fi_get(CAMetalLayer *layer, NSUInteger cw, NSUInteger ch) {
    NvPresentFI *f = g_fi;
    NSUInteger hw = (NSUInteger)layer.drawableSize.width, hh = (NSUInteger)layer.drawableSize.height;
    static int maxh = -1; if (maxh < 0) { const char *e = getenv("DM_PRESENT_FI_MAXH"); maxh = e && atoi(e) > 0 ? atoi(e) : 1080; }
    double s = ch > (NSUInteger)maxh ? (double)maxh / ch : 1;
    int iw = (int)(cw * s) & ~1, ih = (int)(ch * s) & ~1;
    if (f && f->hw == hw && f->hh == hh && f->hpf == layer.pixelFormat && f->w == iw && f->h == ih) return f;
    if (f && (f->w != iw || f->h != ih)) {   // 画面比例变了（11-13 iPhone 实机：开局竖屏、几秒后转横屏）：插值器的输入尺寸是建时定死的，等在途的活做完、整个重建
        dispatch_sync(f->q, ^{});
        MLOG("present frame interpolation: the game picture changed to %lux%lu (input %dx%d → %dx%d), rebuilding", (unsigned long)cw, (unsigned long)ch, f->w, f->h, iw, ih);
        g_fi = nil; f = nil;
    }
    // 不链 MetalFX 框架（同 nvn_present_fx.inc）：类按名字从运行时取，首次用时 dlopen 系统框架
    static Class dc; static int looked; if (!looked) { looked = 1; dlopen("/System/Library/Frameworks/MetalFX.framework/MetalFX", RTLD_LAZY); dc = NSClassFromString(@"MTLFXFrameInterpolatorDescriptor"); }
    if (!dc || ![dc supportsDevice:g_dev]) { fi_off("MetalFX frame interpolation is not supported on this device"); return nil; }
    if (!f) {
        f = [NvPresentFI new]; f->w = iw; f->h = ih;
        MTLFXFrameInterpolatorDescriptor *d = [dc new];
        // 运动矢量 / 深度缺省按 1/4 尺寸交给 MetalFX（DM_PRESENT_FI_MVQ=0 回全尺寸）。11-14 iPhone 实机同包同局对照：超时跳过 10.5% → 1.8%、作业中位 9.64 → 8.95 ms（颜色与输出仍是游戏画面尺寸；我们的块匹配本来就在 1/4 亮度图上做，原先再铺回全尺寸）
        static int mvq = -1; if (mvq < 0) { const char *e = getenv("DM_PRESENT_FI_MVQ"); mvq = !(e && !strcmp(e, "0")); if (mvq) MLOG("present frame interpolation: motion / depth at quarter size (DM_PRESENT_FI_MVQ=0 for full size)"); }
        int mw = mvq && fi_mv_mode() ? iw / 4 : iw, mh = mvq && fi_mv_mode() ? ih / 4 : ih;
        d.outputWidth = (NSUInteger)iw; d.outputHeight = (NSUInteger)ih; d.inputWidth = (NSUInteger)mw; d.inputHeight = (NSUInteger)mh;
        d.colorTextureFormat = d.outputTextureFormat = MTLPixelFormatBGRA8Unorm; d.depthTextureFormat = MTLPixelFormatR32Float; d.motionTextureFormat = MTLPixelFormatRG16Float;
        f->mfx = [d newFrameInterpolatorWithDevice:g_dev]; f->mq = [g_dev newCommandQueue];
        if (!f->mfx || !f->mq) { fi_off("MetalFX makes no frame interpolator for this size"); return nil; }
        for (int i = 0; i < 3; i++) f->in_tex[i] = fi_tex(MTLPixelFormatBGRA8Unorm, iw, ih, f->mfx.colorTextureUsage | MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead);
        f->mid_tex = fi_tex(MTLPixelFormatBGRA8Unorm, iw, ih, f->mfx.outputTextureUsage | MTLTextureUsageShaderRead);
        f->depth = fi_tex(MTLPixelFormatR32Float, mw, mh, f->mfx.depthTextureUsage | MTLTextureUsageRenderTarget);
        f->motion = fi_tex(MTLPixelFormatRG16Float, mw, mh, f->mfx.motionTextureUsage | MTLTextureUsageRenderTarget | MTLTextureUsageShaderWrite);
        if (!f->in_tex[0] || !f->in_tex[1] || !f->in_tex[2] || !f->mid_tex || !f->depth || !f->motion) { fi_off("cannot create the interpolation textures"); return nil; }
        {   // 常数深度 1、零运动：清一次
            id<MTLCommandBuffer> c = [f->mq commandBuffer]; MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new];
            rp.colorAttachments[0].texture = f->depth; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore; rp.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 0, 0);
            rp.colorAttachments[1].texture = f->motion; rp.colorAttachments[1].loadAction = MTLLoadActionClear; rp.colorAttachments[1].storeAction = MTLStoreActionStore; rp.colorAttachments[1].clearColor = MTLClearColorMake(0, 0, 0, 0);
            [[c renderCommandEncoderWithDescriptor:rp] endEncoding]; [c commit]; [c waitUntilCompleted];
        }
        NSError *te = nil;
        for (int i = 0; i < 4; i++) { f->uv[i] = [g_dev newBufferWithLength:8 * sizeof(float) options:MTLResourceStorageModeShared]; res_add(f->uv[i]); f->tab[i] = tab_new(1, 1, 1, &te); if (!f->uv[i] || !f->tab[i]) { fi_off("cannot create the blit tables"); return nil; } }
        for (int i = 0; i < 3; i++) { f->alloc[i] = [g_dev newCommandAllocator]; f->cb[i] = [g_dev newCommandBuffer]; f->slot_free[i] = dispatch_semaphore_create(1); if (!f->alloc[i] || !f->cb[i]) { fi_off("cannot create the command buffers"); return nil; } }
        f->q = dispatch_queue_create("dm.nvn.present-fi", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0)); f->last_seq = UINT64_MAX;
        if (!fi_copy_setup(f)) { fi_off("cannot create the copy pipeline"); return nil; }
        if (fi_mv_mode() && !fi_mv_setup(f)) { fi_off("cannot create the motion-vector pipelines"); return nil; }
        res_commit();
        MLOG("present frame interpolation: MetalFX, input %dx%d (game picture %lux%lu), constant depth, zero motion", f->w, f->h, (unsigned long)cw, (unsigned long)ch);
    }
    f->hw = hw; f->hh = hh; f->hpf = layer.pixelFormat;
    g_fi = f; return f;
}
static pthread_mutex_t g_fi_enc_mu = PTHREAD_MUTEX_INITIALIZER;
static _Atomic uint64_t g_fi_on_mid, g_fi_on_real;   // 系统回报真的上了屏的次数（presentedTime > 0）：补出的帧 / 真帧
__attribute__((weak)) void s2a_hud_mid_frame(void) {}   // runtime/src/hud.c 强定义：浮层把补出的帧算进屏上帧率
static void fi_count_on(id<CAMetalDrawable> d, _Atomic uint64_t *c) {
#if !TARGET_OS_SIMULATOR
    int mid = c == &g_fi_on_mid;
    [d addPresentedHandler:^(id<MTLDrawable> x) { if (x.presentedTime > 0) { atomic_fetch_add(c, 1); if (mid) s2a_hud_mid_frame(); } }];
#else
    (void)d; (void)c;
#endif
}
// 拆账用 DM_PRESENT_FI_DUP=1：不写 YUV 平面、不调模型，每个游戏帧把原图上屏两次（只剩「每秒上屏 60 次 + 屏幕 60 Hz」本身的开销）
static int fi_dup(void) { static int v = -1; if (v < 0) v = getenv("DM_PRESENT_FI_DUP") != NULL; return v; }
typedef struct { int has, c[4]; } fi_crop;
// 一遍全屏三角：t0（与可选的 t1）经 pso 画进 dst。裁剪 / 翻转同 present_blit_m4；vw x vh 是内容的宽高（定视口：画布上保持比例居中，平面贴图上铺满）
API_AVAILABLE(macos(26.0), ios(26.0))
static int fi_pass(id cb, id<MTLRenderPipelineState> pso, id table, id<MTLBuffer> uvb, id<MTLTexture> t0, id<MTLTexture> t1, id<MTLTexture> dst, const int *crop, BOOL flip, NSUInteger vw, NSUInteger vh) {
    NSUInteger cx = 0, cy = 0, cw = t0.width, ch = t0.height;
    if (crop && (crop[2] || crop[3])) { if (crop[0] < 0 || crop[1] < 0 || crop[2] <= 0 || crop[3] <= 0 || (uint64_t)crop[0] + crop[2] > t0.width || (uint64_t)crop[1] + crop[3] > t0.height) return 0;
        cx = (NSUInteger)crop[0]; cy = (NSUInteger)crop[1]; cw = (NSUInteger)crop[2]; ch = (NSUInteger)crop[3]; }
    double dw = dst.width, dh = dst.height; pf_vp pv = pf_viewport(dw, dh, vw ? vw : cw, vh ? vh : ch); MTLViewport vp = {pv.x, pv.y, pv.w, pv.h, 0, 1};
    int full = vp.originX == 0 && vp.originY == 0 && vp.width == dw && vp.height == dh;
    id rp = pass_desc(); MTLRenderPassColorAttachmentDescriptor *ca = [rp colorAttachments][0];
    ca.texture = dst; ca.loadAction = full ? MTLLoadActionDontCare : MTLLoadActionClear; ca.storeAction = MTLStoreActionStore; ca.clearColor = MTLClearColorMake(0, 0, 0, 1);
    id en = m4_render_on(cb, rp); if (!en) return 0;
    enc_full_barrier_begin(en);
    enc_r_table(en, table, MTLRenderStageFragment);
    tab_tex(table, present_raw_src(t0), 0); if (t1) tab_tex(table, t1, 1);
    tab_samp(table, g_blit_samp, 0);
    float *uv = uvb.contents;
    uv[0] = (float)cx / t0.width; uv[1] = (float)cy / t0.height; uv[2] = (float)cw / t0.width; uv[3] = (float)ch / t0.height;
    uv[4] = (cx + 0.5f) / t0.width; uv[5] = (cy + 0.5f) / t0.height; uv[6] = (cx + cw - 0.5f) / t0.width; uv[7] = (cy + ch - 0.5f) / t0.height;
    if (flip) { uv[1] += uv[3]; uv[3] = -uv[3]; }
    tab_buf(table, uvb, 0, 0);
    [en setViewport:vp]; [en setRenderPipelineState:pso];
    [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    enc_end_on(en, YES);
    return 1;
}
// 在命令槽 s 上编码并提交（dr 非空 = 这次画进画布）。after 在 GPU 做完的回调里调。槽的分配器要等它上一次提交做完才能重用
API_AVAILABLE(macos(26.0), ios(26.0))
static int fi_commit(NvPresentFI *f, int s, id<CAMetalDrawable> dr, int (^enc)(id cb), void (^after)(int ok)) {
    dispatch_semaphore_wait(f->slot_free[s], DISPATCH_TIME_FOREVER);
    pthread_mutex_lock(&g_fi_enc_mu);
    present_pipeline(MTLPixelFormatBGRA8Unorm);   // 取样器（g_blit_samp）在这里建
    if (dr) [g_q4 waitForDrawable:dr];
    id cb = f->cb[s]; m4_begin_on(cb, f->alloc[s]);
    int ok = enc(cb);
    [cb endCommandBuffer];
    if (!ok) { if (dr) [g_q4 signalDrawable:dr]; pthread_mutex_unlock(&g_fi_enc_mu); dispatch_semaphore_signal(f->slot_free[s]); return 0; }
    dispatch_semaphore_t fr = f->slot_free[s];
    id o = fb_new(); fb_add(o, ^(id fbk) { NSError *fe = [fbk error]; int good = !fe; if (!good) MLOG("【红】 frame interpolation command buffer error (slot %d): %s", s, fe.description.UTF8String);
                                dispatch_semaphore_signal(fr); if (after) after(good); });
    res_commit(); m4_commit_one(cb, o);
    if (dr) [g_q4 signalDrawable:dr];
    pthread_mutex_unlock(&g_fi_enc_mu);
    return 1;
}
static void fi_ticket_done(uint64_t ticket) { pthread_mutex_lock(&g_pq_mu); if (ticket > g_pq_done) g_pq_done = ticket; pthread_cond_broadcast(&g_pq_cv); pthread_mutex_unlock(&g_pq_mu); }
// 补帧队列：这一帧的输入图已经在 GPU 上写好（in_tex[k]；上一帧在 in_tex[(k + 2) % 3]）
API_AVAILABLE(macos(26.0), ios(26.0))
static void fi_job(NvPresentFI *f, CAMetalLayer *layer, id<MTLTexture> src, fi_crop cr, BOOL flip, int k, uint64_t seq, double period, uint64_t ticket, int good, int allow) { @autoreleasepool {
    const int *crop = cr.has ? cr.c : NULL; int have_mid = 0; uint64_t t0 = now_ns(); id<MTLTexture> mid = f->mid_tex;
    static int novt = -1; if (novt < 0) novt = getenv("DM_PRESENT_FI_NOVT") != NULL;   // 拆账用：不调 MetalFX，中间那一帧直接用上一帧
    int dup = fi_dup();
    if (good && dup && allow) have_mid = 1;
    else if (good && !allow) f->last_seq = seq;   // 这一帧按规则不补：只当下一帧的前一帧
    else if (good) {
        int pair = seq > 0 && f->last_seq == seq - 1;
        if (pair && novt) { have_mid = 1; mid = f->in_tex[(k + 2) % 3]; }
        else if (pair) {
            id<MTLFXFrameInterpolator> fx = f->mfx; static uint64_t last_pair_seq = UINT64_MAX;
            fx.colorTexture = f->in_tex[k]; fx.prevColorTexture = f->in_tex[(k + 2) % 3]; fx.outputTexture = f->mid_tex;
            fx.depthTexture = f->depth; fx.motionTexture = f->motion; fx.motionVectorScaleX = fx.motionVectorScaleY = (float)f->motion.width / (float)f->w;   // 矢量按全尺寸像素算；按 1/4 尺寸交时换成输入像素
            fx.deltaTime = period > 0 ? (float)period : 1.f / 30; fx.nearPlane = .1f; fx.farPlane = 1000; fx.fieldOfView = 60; fx.aspectRatio = (float)f->w / f->h;
            fx.jitterOffsetX = fx.jitterOffsetY = 0; fx.depthReversed = NO; fx.shouldResetHistory = last_pair_seq == UINT64_MAX || seq - 1 != last_pair_seq;   // 断开过（不补的帧 / 跳过）就重置历史
            id<MTLCommandBuffer> c = [f->mq commandBuffer]; c.label = @"present frame interpolation (MetalFX)";
            if (fi_mv_mode()) fi_mv_encode(f, c, f->in_tex[k], f->in_tex[(k + 2) % 3], fi_mv_mode() < 0 ? -1.f : 1.f);
            [fx encodeToCommandBuffer:c]; fx.outputTexture = fx.prevColorTexture = fx.colorTexture = nil;
            dispatch_semaphore_t done = dispatch_semaphore_create(0); __block int ok = 0; __block double gms = 0, gstart = 0, gend = 0, cbt = 0;
            double tcommit = CACurrentMediaTime(), tenc = (now_ns() - t0) / 1e6;
            int kp = (k + 2) % 3; pthread_mutex_lock(&g_pq_mu); f->in_busy[k]++; f->in_busy[kp]++; pthread_mutex_unlock(&g_pq_mu);   // 这两张输入图被这次插值读着
            [c addCompletedHandler:^(id<MTLCommandBuffer> x) { pthread_mutex_lock(&g_pq_mu); f->in_busy[k]--; f->in_busy[kp]--; pthread_cond_broadcast(&g_pq_cv); pthread_mutex_unlock(&g_pq_mu);
                                                               cbt = CACurrentMediaTime(); gstart = x.GPUStartTime; gend = x.GPUEndTime; ok = x.error == nil; gms = (x.GPUEndTime - x.GPUStartTime) * 1000; if (x.error) MLOG("【红】 MetalFX frame interpolation failed: %s", x.error.description.UTF8String); dispatch_semaphore_signal(done); }];
            [c commit];
            // 预算内做完才上补出的帧；超时就不再等（审计 P1-189：原先超时后再等最多 1 秒才上真帧、才记票，30 帧款的上屏节拍被拖长）——直接往下上真帧、记票。
            //   迟到的那次接着在 GPU 上跑完：它读的两张输入图由 in_busy 护着（出图线程见到被占就这一帧不写不补，fi_input_free），写的 mid_tex 下一次插值在同一命令队列上排在它后面
            int in_time = !dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(g_fi_budget_ms * 1e6)));
            if (in_time && ok) { have_mid = 1; last_pair_seq = seq; f->gpu_sum += gms; }
            if (in_time && gstart > 0 && gend >= gstart && cbt >= gend) { f->bd_enc += tenc; f->bd_queue += (gstart - tcommit) * 1000; f->bd_cb += (cbt - gend) * 1000; f->bd_n++; }   // 拆账只算预算内做完的（迟到的那次不等它，回调里的时刻这时还没写）
        }
        f->last_seq = seq;
    }
    if (seq > 0 && !allow) f->declined++;
    else if (seq > 0) { double ms = (now_ns() - t0) / 1e6; f->ms_sum += ms; if (ms > f->ms_max) f->ms_max = ms; if (have_mid) f->made++; else f->skipped++; }
    // 先上补出的帧，再隔半个游戏周期上真帧（游戏原图直接画进画布）。图层已归显示链（正在切过去）：两张都不取，只记票完成
    pthread_mutex_lock(&g_pq_mu); int mine = fi_may_take_drawable(); pthread_mutex_unlock(&g_pq_mu);
    if (!mine) { static _Atomic int said; if (!atomic_fetch_add(&said, 1)) MLOG("present frame interpolation: the display link owns the layer; this job takes no drawable (frame %llu dropped, no two presenters)", (unsigned long long)seq);
                 fi_ticket_done(ticket); fi_inflight_add(-1); return; }
    double half = period > 0 ? period / 2 : 1.0 / 60; int mid_shown = 0;
    // 补出帧的摆放比例要和真帧一致（#1165：自适应满屏补丁开着时真帧走 present_blit_m4 按 s2a_cpatch_present_aspect 拉满到屏幕画幅，补出帧按输入图 16:9 摆，
    //   两侧黑边隔一帧一有，看着闪）：有补丁画幅就按它，没有照旧按输入图比例
    double pa = s2a_cpatch_present_aspect();
    if (have_mid) { id<CAMetalDrawable> dm = [layer nextDrawable]; NSUInteger vh = (NSUInteger)f->h, vw = pa > 0 ? (NSUInteger)llround(f->h * pa) : (NSUInteger)f->w;
        if (dm && fi_commit(f, 1, dm, ^int(id cb) { return dup ? present_blit_m4(cb, src, dm.texture, crop, f->uv[2], f->tab[2], flip, 1) : fi_pass(cb, f->psoCopy, f->tab[2], f->uv[2], mid, nil, dm.texture, NULL, NO, vw, vh); }, nil)) { fi_count_on(dm, &g_fi_on_mid); [dm present]; mid_shown = 1; f->shown_mid++; } }
    id<CAMetalDrawable> dr = [layer nextDrawable];
    if (dr && fi_commit(f, 2, dr, ^int(id cb) { return present_blit_m4(cb, src, dr.texture, crop, f->uv[3], f->tab[3], flip, 1); }, ^(int ok) { (void)ok; fi_ticket_done(ticket); })) {
#if !TARGET_OS_SIMULATOR
        present_note(dr, ticket); fi_count_on(dr, &g_fi_on_real);
        if (mid_shown) [dr presentAfterMinimumDuration:half]; else [dr present];
#else
        [dr present];
#endif
    } else fi_ticket_done(ticket);
    if (++f->jobs % 300 == 0) { MLOG("present frame interpolation up to game frame %llu: interpolated %llu, skipped %llu (over %.1f ms or failed), not interpolated by the rule %llu (60 fps tier or frame late), shown %llu; job mean %.2f ms, max %.2f ms, MetalFX GPU mean %.2f ms; on screen (system reported) interpolated %llu, game frames %llu",
                                     (unsigned long long)f->jobs, (unsigned long long)f->made, (unsigned long long)f->skipped, g_fi_budget_ms, (unsigned long long)f->declined, (unsigned long long)f->shown_mid, f->ms_sum / 300, f->ms_max, f->made > f->made_win0 ? f->gpu_sum / (double)(f->made - f->made_win0) : 0,
                                     (unsigned long long)atomic_load(&g_fi_on_mid), (unsigned long long)atomic_load(&g_fi_on_real)); f->ms_sum = f->ms_max = f->gpu_sum = 0; f->made_win0 = f->made;
                                 if (f->bd_n) MLOG("present frame interpolation breakdown (%.0f jobs): start → commit %.2f ms, commit → GPU start %.2f ms (waiting behind other GPU work), GPU %s, GPU end → completion callback %.2f ms",
                                                   f->bd_n, f->bd_enc / f->bd_n, f->bd_queue / f->bd_n, "see MetalFX GPU mean above", f->bd_cb / f->bd_n);
                                 f->bd_enc = f->bd_queue = f->bd_cb = f->bd_n = 0; }
    fi_inflight_add(-1);   // 两张画布都交完（或没取到）：显示链可以挂了
} }
// 这张输入图此刻能不能写：迟到的插值（fi_job 预算内没做完、接着在 GPU 上跑）还在读它就不能。不等（审计 P1-189：原先出图线程在这里最多等 1 秒，
//   迟到一次就把出图线程挡住）——调用方这一帧不写输入、不补，只把真帧交给补帧队列按顺序上屏
API_AVAILABLE(macos(26.0), ios(26.0))
static int fi_input_free(NvPresentFI *f, int k) {
    pthread_mutex_lock(&g_pq_mu); int busy = f->in_busy[k]; pthread_mutex_unlock(&g_pq_mu);
    return !busy;
}
// 出图线程：游戏的一帧。返回 1 = 已接手（票由补帧队列记完成），-1 = 没接手（调用方照原样出图）
API_AVAILABLE(macos(26.0), ios(26.0))
static int fi_frame(id<MTLTexture> src, const int crop[4], CAMetalLayer *layer, double period, uint64_t ticket) {
    NSUInteger cw = crop && (crop[2] || crop[3]) ? (NSUInteger)crop[2] : src.width, ch = crop && (crop[2] || crop[3]) ? (NSUInteger)crop[3] : src.height;
    NvPresentFI *f = fi_get(layer, cw, ch); if (!f) return -1;
    uint64_t now = now_ns(); double gap = f->last_in_ns ? (now - f->last_in_ns) / 1e9 : 0; f->last_in_ns = now;
    int allow = dm_fi_should_interp(period, gap);   // 游戏声明的节拍（period，由交换间隔折成）+ 这一帧是否跑满；60 帧档一律不补
    uint64_t seq = f->n++; int k = (int)(seq % 3); BOOL flip = atomic_load_explicit(&g_origin_ll, memory_order_relaxed) != 0;
    fi_crop cr = {0}; if (crop) { cr.has = 1; memcpy(cr.c, crop, sizeof cr.c); }
    const int *cp = cr.has ? cr.c : NULL;   // 块里用值拷贝
    fi_inflight_add(1);   // 出图线程还在 g_classic_busy 里：显示链此刻挂不上，任务派出后它会等这一笔
    if (fi_dup()) { dispatch_async(f->q, ^{ fi_job(f, layer, src, cr, flip, k, seq, period, ticket, 1, allow); }); return 1; }   // 拆账：不写输入
    if (!fi_input_free(f, k)) {   // 输入图还被迟到的插值读着：这一帧不写不补（good = 0 只上真帧），任务照样进同一队列，和在途的补帧按顺序上屏、不两路交帧；
        //   这一帧不算进连续对（f->last_seq 不动），下一帧不会拿旧输入去插
        static _Atomic uint64_t skips; if (atomic_fetch_add(&skips, 1) % 300 == 0) MLOG("present frame interpolation: input %d still read by a late interpolation; this frame is shown without interpolating (no wait)", k);
        dispatch_async(f->q, ^{ fi_job(f, layer, src, cr, flip, k, seq, period, ticket, 0, allow); }); return 1;
    }
    if (!fi_commit(f, 0, nil, ^int(id cb) { fi_crop c2 = cr; const int *c = c2.has ? c2.c : NULL; (void)cp;
            return fi_pass(cb, f->psoCopy, f->tab[0], f->uv[0], src, nil, f->in_tex[k], c, flip, 0, 0); },
        ^(int ok) { dispatch_async(f->q, ^{ fi_job(f, layer, src, cr, flip, k, seq, period, ticket, ok, allow); }); })) { fi_inflight_add(-1); fi_off("cannot write the interpolation input"); return -1; }
    return 1;
}
