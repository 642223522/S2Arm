// 补帧与显示链互斥（11-15 #ee56e7 / #1155：补帧开着时出图切到显示链模式，补帧任务照样 nextDrawable → CAMetalLayerInvalidOperation 整个 App 退出；
//   切换前后新旧两路同时交帧 = 频闪）。含生产 nvn_mtl.m 源码（同 t_link_restart.m 写法），假图层只数 nextDrawable 调了几次。期望按语义手写：
//   ① 图层已归显示链（g_link_owns_layer = 1，显示链正在挂）时跑一个补帧任务：nextDrawable 0 次、这一帧的票记完成、在途数回 0。旧实现照取画布 → 1 次以上（红）
//   ② 图层没归显示链：照常取画布（≥ 1 次，假图层返回 nil 就不上屏），在途数回 0——修复没把正常补帧关掉
//   ③ 显示链等的条件：经典出图空闲但还有 1 笔在途补帧 → 还不能挂（1）；在途归零 → 能挂（0）。旧实现只看经典出图 → 在途时也判能挂（红）
#ifndef FI_LINK_SOURCE
#define FI_LINK_SOURCE "../gfx/nvn/nvn_mtl.m"
#endif
#include FI_LINK_SOURCE

static unsigned checks, failures;
#define CHECK(c, ...) do { checks++; int ok=!!(c); failures+=!ok; printf("%s ",ok?"PASS":"FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while(0)

@interface FakeLayer : CAMetalLayer
@property (atomic) int takes;
@end
@implementation FakeLayer
- (id<CAMetalDrawable>)nextDrawable { self.takes++; return nil; }
@end

int main(void) { @autoreleasepool {
    setenv("DM_PSO_MANIFEST","off",1); setenv("DM_PSO_ARCHIVE","0",1);
    mtl_init();
    if (@available(macOS 26.0, iOS 26.0, *)) {
        for (int owns = 1; owns >= 0; owns--) {
            FakeLayer *l = [FakeLayer new]; NvPresentFI *f = [NvPresentFI new];
            pthread_mutex_lock(&g_pq_mu); g_link_owns_layer = owns; g_pq_done = 0; pthread_mutex_unlock(&g_pq_mu);
            fi_inflight_add(1);   // 同 fi_frame：派任务前记一笔在途
            fi_crop cr = {0};
            fi_job(f, l, nil, cr, NO, 0, 1, 1.0 / 30, 7, 0, 1);   // good = 0：不补中间帧，直接走上真帧那段
            pthread_mutex_lock(&g_pq_mu); int inflight = g_fi_inflight; uint64_t done = g_pq_done; pthread_mutex_unlock(&g_pq_mu);
            if (owns) CHECK(l.takes == 0 && done >= 7 && inflight == 0, "① 图层已归显示链：补帧任务不取画布（nextDrawable %d 次）、票记完成（%llu）、在途回 0（%d）", l.takes, (unsigned long long)done, inflight);
            else CHECK(l.takes >= 1 && inflight == 0, "② 图层没归显示链：照常取画布（nextDrawable %d 次）、在途回 0（%d）", l.takes, inflight);
        }
    }
    pthread_mutex_lock(&g_pq_mu); g_link_owns_layer = 0; g_classic_busy = 0; g_fi_inflight = 1; int b1 = link_layer_busy(); g_fi_inflight = 0; int b0 = link_layer_busy(); pthread_mutex_unlock(&g_pq_mu);
    CHECK(b1 == 1 && b0 == 0, "③ 显示链等：经典出图空闲、在途补帧 1 笔 → 不能挂（%d）；在途归零 → 能挂（%d）", b1, b0);
    // ④ 显示链跟补帧开关（审计 P1-188）。期望手写：补帧开（g_fi_state 1）、玩家局中关 → 这一帧不补、显示链回到不补帧时的方式（g_link_base 1）；
    //   再开 → 0；整段回退 fi_off → 1；补丁要的 120 Hz 链（2）不动。旧实现关补帧 / 回退后显示链仍是 0（红）
    {
        g_fi_state = 1; g_link_base = 1; g_dm_present_link = 0;
        s2a_fi_set_live(0); int r0 = fi_wanted(); int l0 = g_dm_present_link;
        s2a_fi_set_live(1); int r1 = fi_wanted(); int l1 = g_dm_present_link;
        fi_off("测试：整段回退"); int l2 = g_dm_present_link;
        g_fi_state = 1; g_dm_present_link = 2; s2a_fi_set_live(0); (void)fi_wanted(); int l3 = g_dm_present_link; s2a_fi_set_live(1); g_fi_state = 0; g_dm_present_link = 0;
        CHECK(r0 == 0 && l0 == 1 && r1 == 1 && l1 == 0 && l2 == 1 && l3 == 2, "④ 显示链跟补帧：局中关 → 不补、链 %d（期望 1）；再开 → 补、链 %d（期望 0）；回退 → 链 %d（期望 1）；120 Hz 链不动 → %d（期望 2）", l0, l1, l2, l3);
    }
    // ⑤ 补帧超时不等（审计 P1-189）：迟到的插值读着的输入图由 in_busy 护着，出图线程见到被占就这一帧不写不补，不等。期望手写：
    //   没人读 → 能写（1）；有 1 个读者 → 不能写（0），且立即返回（< 5 ms）。旧实现（fi_in_wait）在有读者时等到读完、最多 1 秒
    if (@available(macOS 26.0, iOS 26.0, *)) {
        NvPresentFI *f = [NvPresentFI new];
        int idle = fi_input_free(f, 1);
        pthread_mutex_lock(&g_pq_mu); f->in_busy[1] = 1; pthread_mutex_unlock(&g_pq_mu);
        double t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6; int busy = fi_input_free(f, 1); double ms = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6 - t0;
        CHECK(idle == 1 && busy == 0 && ms < 5, "⑤ 写输入图前：没人读 → %d（期望 1）；迟到的插值读着 → %d（期望 0）、用时 %.2f ms（期望 < 5，不等）", idle, busy, ms);
    }
    printf("%s t_fi_link：%u 项，%u 项不符\n", failures ? "✗" : "✓", checks, failures);
    return failures != 0;
} }
