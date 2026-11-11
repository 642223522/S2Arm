// GPU 挂死安全停（11-07 Switch2 线 84）：直接包含生产 nvn_mtl.m。
//   判据（期望值手写，不跑被测实现算）：
//   ① 判定：照 11-07 测试设备2 金刚 host_mid.log 第 731–749 行的错误结构造假错误（Metal 4 顶层 code 1、无描述，真实原因在 NSMultipleUnderlyingErrorsKey /
//      NSUnderlyingErrorKey 里）—— Hang 判挂死；InnocentVictim / SubmissionsIgnored 不判；Metal 3 旧队列 Timeout(2) / PageFault(3) 判、带牵连原因名的不判。
//      负对照：旧判法（只在 localizedDescription 里找 Hang / Timeout，host_adapt.m 原 s2a_gpu_timeout_check）对同一个 Hang 错误不命中 —— 这就是那局照常提交的原因。
//   ② 流程：先喂牵连错误 → 不停；放行的真提交计数 +1（负对照：证明计数在动）；再喂 Hang → 安全停一次、通知一次、通知里有提交序号与原文；再喂 Hang 不重复通知。
//   ③ 停后：旧队列真命令缓冲 cb_put / cb_run 都不交（状态仍 NotEnqueued、计数不涨、不阻塞）；m3_commit 不交；Metal 4 直交 rec_commit_upload 不交；
//      上屏 present_now 返回 0 且上屏计数不涨、present_enqueue 回票号 0；nvn_be_drain（进后台排空）立即返回、不交不等
//   ⓪ 帧 GPU 时间 1 秒门（gpu_tag_done）：照 11-09 M1 Pro 时之笛 S2 切回前台那一局，结束时间在现在之后的跨度（算出 6147890790964 ms）不判挂死、不计时间；
//      负对照：同一帧真实的 1.5 秒跨度（结束在现在）照判安全停，证明门没被关掉
//   ⓪b #647（Mac mini M4 / macOS 27.2.1 Metal 4，23 局假安全停）：每帧 16 ms 提交一次、真跑 10 ms，回报的 GPU 开始时间却停在第 0 帧之前 0.1 秒不动
//      → 100 帧后旧算法的跨度 = 第 99 帧结束 − 停住的开始 ≈ 0.1 + 99×0.016 + 0.01 = 1.694 秒 > 1 秒（会停）；新判据按提交时刻截 → 每帧 10 ms、不停，
//      「开始早于提交」计数 = 100（期望按构造手算）
//   ⓪c 一帧 10 段同队列排队、回报的开始都是第一段开始那一刻（跨度层层包含）：跨度和 3.3 秒、独占 600 ms → 不停；
//      真挂死形态：两段首尾相接各 0.6 秒 → 独占 1.2 秒 → 停（真挂死不变弱）
#include "../gfx/nvn/nvn_mtl.m"
#include "s2a_t_result.h"

static int bad, checks;
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) bad++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)

static int g_notified; static char g_note[2048];
static void rec_notify(const char *why) { g_notified++; snprintf(g_note, sizeof g_note, "%s", why ? why : ""); }

// 照真机日志的错误结构：MTL4CommandQueueErrorDomain(code) → [NSMultipleUnderlyingErrorsKey: (MTL4 err with reason), NSUnderlyingErrorKey: same] → IOGPUCommandQueueErrorDomain(io)
static NSError *mtl4_err(long code, NSString *reason, long io) {
    NSError *iog = [NSError errorWithDomain:@"IOGPUCommandQueueErrorDomain" code:io userInfo:nil];
    NSError *inner = [NSError errorWithDomain:@"MTL4CommandQueueErrorDomain" code:code userInfo:@{NSLocalizedDescriptionKey: reason, NSUnderlyingErrorKey: iog}];
    return [NSError errorWithDomain:@"MTL4CommandQueueErrorDomain" code:1 userInfo:@{@"NSMultipleUnderlyingErrorsKey": @[inner], NSUnderlyingErrorKey: inner}];
}
static int legacy_judge(NSError *e) {   // 原 s2a_gpu_timeout_check 的判法：只看 localizedDescription
    const char *d = e.localizedDescription.UTF8String;
    return d && (strstr(d, "kIOGPUCommandBufferCallbackErrorTimeout") || strstr(d, "kIOGPUCommandBufferCallbackErrorHang"));
}

int main(void) {
    @autoreleasepool {
        char map[] = "/tmp/t_gpu_halt_map_XXXXXX"; int fd = mkstemp(map); if (fd < 0) return 2; close(fd); setenv("DM_NVN_SHMAP", map, 1);
        mtl_init();
        g_gpu_halt_notify = rec_notify;
        NSError *hang = mtl4_err(1, @"Caused GPU Hang Error (00000003:kIOGPUCommandBufferCallbackErrorHang)", 3);
        NSError *victim = mtl4_err(1, @"Discarded (victim of GPU error/recovery) (00000005:kIOGPUCommandBufferCallbackErrorInnocentVictim)", 5);
        NSError *ignored = mtl4_err(5, @"Ignored (for causing prior/excessive GPU errors) (00000004:kIOGPUCommandBufferCallbackErrorSubmissionsIgnored)", 4);
        NSError *m3_to = [NSError errorWithDomain:MTLCommandBufferErrorDomain code:MTLCommandBufferErrorTimeout userInfo:nil];
        NSError *m3_pf = [NSError errorWithDomain:MTLCommandBufferErrorDomain code:MTLCommandBufferErrorPageFault userInfo:nil];
        NSError *m3_victim = [NSError errorWithDomain:MTLCommandBufferErrorDomain code:MTLCommandBufferErrorTimeout userInfo:@{NSUnderlyingErrorKey:
            [NSError errorWithDomain:@"IOGPUCommandQueueErrorDomain" code:5 userInfo:@{NSLocalizedDescriptionKey: @"Discarded (victim of GPU error/recovery) (00000005:kIOGPUCommandBufferCallbackErrorInnocentVictim)"}]}];

        // ⓪ 帧 GPU 时间 1 秒门：不可能的时间戳不判，真跨度照判
        double now = CACurrentMediaTime();
        gpu_tag_begin(23924); gpu_tag_done(23924, 0, now - 0.05, now - 0.04, now - 0.04 + 6147890790.964);
        VERIFY(!mtl_gpu_halted() && !g_notified && atomic_load(&g_gpu[23924 % GRING].ns) == 0, "结束在现在之后的跨度（6147890790964 ms）不判挂死、不计进本帧 GPU 时间");
        gpu_tag_begin(23925); now = CACurrentMediaTime(); gpu_tag_done(23925, 0, now - 1.6, now - 1.5, now);
        VERIFY(mtl_gpu_halted() && g_notified == 1 && strstr(g_note, "frame 23925 kept the GPU busy"), "负对照：真实 1.5 秒跨度照判安全停（%s）", g_note);
        atomic_store(&g_gpu_halt, 0); g_notified = 0; g_note[0] = 0;   // 复位

        // ⓪b #647 形态：开始时间停在过去，跨度一路拉长——不停；计数 100
        atomic_store(&g_gpu_qend[0], 0);   // 各用例自造时间线：先清本队列的最晚结束（真实运行时间单调向前）
        double base = CACurrentMediaTime() - 3.0, stale = base - 0.1; uint64_t e0 = mtl_gpu_start_early();
        for (int i = 0; i < 100; i++) { uint64_t fr = 30000 + i; double sub = base + i * 0.016; gpu_tag_begin(fr); gpu_tag_done(fr, 0, sub, stale, sub + 0.010); }
        VERIFY((base + 99 * 0.016 + 0.010) - stale > 1.0, "构造核对：旧算法第 99 帧跨度 %.3f 秒 > 1 秒（会误停）", (base + 99 * 0.016 + 0.010) - stale);
        VERIFY(!mtl_gpu_halted() && !g_notified, "#647 形态（开始停在过去、每帧真跑 10 ms）不判挂死");
        VERIFY(mtl_gpu_start_early() - e0 == 100, "「GPU 开始早于提交」计数 +100（实 %llu）", (unsigned long long)(mtl_gpu_start_early() - e0));
        VERIFY(atomic_load(&g_gpu[(30000 + 99) % GRING].ns) == 10000000ull, "第 99 帧记 10 ms（实 %.3f ms）", atomic_load(&g_gpu[(30000 + 99) % GRING].ns) / 1e6);
        // ⓪c 一帧切成 10 段、同一队列按序执行各 60 ms，回报的开始都是第一段开始那一刻（跨度层层包含：0.06、0.12 … 0.6）：
        //    旧算法跨度和 = 0.06 × (1 + … + 10) = 3.3 秒（会误停）；独占时间 = 10 × 60 ms = 600 ms，不停
        atomic_store(&g_gpu_qend[0], 0); now = CACurrentMediaTime(); double t = now - 0.65;
        for (int i = 0; i < 10; i++) gpu_tag_begin(31000);
        for (int i = 0; i < 10; i++) gpu_tag_done(31000, 0, t - 0.001, t, t + 0.06 * (i + 1));
        VERIFY(!mtl_gpu_halted() && !g_notified && atomic_load(&g_gpu[31000 % GRING].ns) == 600000000ull, "一帧 10 段同队列排队（跨度和 3.3 秒、独占 %.0f ms）不判挂死", atomic_load(&g_gpu[31000 % GRING].ns) / 1e6);
        // 真挂死形态（10-31 那种：一帧的活真跑了 1.2 秒）：两段首尾相接各 0.6 秒 → 独占 1.2 秒 → 照停
        atomic_store(&g_gpu_qend[0], 0); now = CACurrentMediaTime(); gpu_tag_begin(31001); gpu_tag_begin(31001);
        gpu_tag_done(31001, 0, now - 1.25, now - 1.2, now - 0.6); gpu_tag_done(31001, 0, now - 1.25, now - 0.6, now);
        VERIFY(mtl_gpu_halted() && g_notified == 1 && strstr(g_note, "frame 31001 kept the GPU busy 1200 ms"), "真跑满 1.2 秒照判安全停（%s）", g_note);
        atomic_store(&g_gpu_halt, 0); g_notified = 0; g_note[0] = 0;   // 复位，下面的流程从没停过的状态开始

        // ① 判定
        VERIFY(!legacy_judge(hang), "负对照：旧判法（只看 localizedDescription「%s」）对真机结构的 Hang 错误不命中", hang.localizedDescription.UTF8String);
        VERIFY(mtl_gpu_err_fatal(hang) == 1, "Metal 4 Hang（原因在 underlying 里）判本进程挂死");
        VERIFY(mtl_gpu_err_fatal(victim) == 0, "InnocentVictim 不判（被别人牵连）");
        VERIFY(mtl_gpu_err_fatal(ignored) == 0, "SubmissionsIgnored 不判（连带错误）");
        VERIFY(mtl_gpu_err_fatal(m3_to) == 1 && mtl_gpu_err_fatal(m3_pf) == 1, "Metal 3 旧队列 Timeout / PageFault 判挂死");
        VERIFY(mtl_gpu_err_fatal(m3_victim) == 0, "Metal 3 Timeout 但原因是 InnocentVictim：不判");

        // ② 流程：牵连错误不停、计数在动
        uint64_t c0 = atomic_load(&g_gpu_commits);
        id<MTLCommandBuffer> ok = [g_q commandBuffer]; VERIFY(cb_put(ok) == 1, "安全停前 cb_put 放行");
        [ok waitUntilCompleted];
        VERIFY(atomic_load(&g_gpu_commits) == c0 + 1, "负对照：安全停前放行计数 +1（%llu → %llu）", (unsigned long long)c0, (unsigned long long)atomic_load(&g_gpu_commits));
        VERIFY(mtl_gpu_cb_error(victim, "main replay", 6703) == 0 && mtl_gpu_cb_error(ignored, "segment", 6716) == 0 && !mtl_gpu_halted() && !g_notified, "InnocentVictim / SubmissionsIgnored 不触发全停");
        VERIFY(mtl_gpu_cb_error(hang, "main replay", 6701) == 1 && mtl_gpu_halted(), "Hang → 安全停置位");
        VERIFY(g_notified == 1 && strstr(g_note, "6701") && strstr(g_note, "kIOGPUCommandBufferCallbackErrorHang") && strstr(g_note, "main replay"), "宿主侧通知一次，带提交序号、队列与第一条错误原文");
        VERIFY(mtl_gpu_cb_error(hang, "main replay", 6709) == 1 && g_notified == 1, "再来 Hang 不重复通知");

        // ③ 停后一切提交入口不交
        uint64_t c1 = atomic_load(&g_gpu_commits), r1 = atomic_load(&g_gpu_refused);
        id<MTLCommandBuffer> a = [g_q commandBuffer]; int pa = cb_put(a);
        id<MTLCommandBuffer> b = [g_q commandBuffer]; uint64_t t0 = now_ns(); int rb = cb_run(b); double ms = (now_ns() - t0) / 1e6;
        VERIFY(!pa && a.status == MTLCommandBufferStatusNotEnqueued, "cb_put 不交（状态 %ld，0 = 未入队）", (long)a.status);
        VERIFY(!rb && b.status == MTLCommandBufferStatusNotEnqueued && ms < 50, "cb_run 不交也不等（%.2f ms）", ms);
        id<MTLCommandBuffer> c = [g_q3 ?: g_q commandBuffer]; m3_commit(c, nil, nil, 0);
        VERIFY(c.status == MTLCommandBufferStatusNotEnqueued, "m3_commit 不交");
        if (!g_m3 && g_q4) { id cb4 = [g_dev newCommandBuffer]; rec_commit_upload(cb4, nil); VERIFY(1, "Metal 4 rec_commit_upload 安全停后返回（没交未开始的命令缓冲，交了会抛异常）"); }
        uint64_t pn = g_present_n;
        VERIFY(present_now(NULL, 1 / 60.0, 1, 1, NULL, nil, 0) == 0 && g_present_n == pn, "上屏 present_now 不交（上屏计数 %llu 不涨）", (unsigned long long)g_present_n);
        tex_t tx; memset(&tx, 0, sizeof tx);
        VERIFY(present_enqueue(&tx, 1 / 60.0, NULL, 0) == 0, "present_enqueue 回票号 0（游戏不等这一帧）");
        t0 = now_ns(); nvn_be_drain(); ms = (now_ns() - t0) / 1e6;
        VERIFY(ms < 50, "进后台排空 nvn_be_drain 立即返回（%.2f ms），不交不等", ms);
        VERIFY(atomic_load(&g_gpu_commits) == c1 && atomic_load(&g_gpu_refused) > r1, "安全停后放行计数不涨（%llu），拒交 %llu 次", (unsigned long long)atomic_load(&g_gpu_commits), (unsigned long long)(atomic_load(&g_gpu_refused) - r1));
        unlink(map);
    }
    return S2A_T_RESULT("t_nvn_gpu_halt", bad);
}
