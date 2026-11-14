// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
//
// 两级回放队列（android/native/nvn/nvn_vk_dq.inc）的宿主用例：直接包含该文件，用真队列 + 真录制线程，
// 驱动的 vkCmd* 换成「记录桩」（只记下收到的调用序列的滚动哈希与条数），其余 Vulkan 入口换成空桩。
// 期望都不靠被测实现算：每个生产者线程按固定种子的伪随机序列发调用，同时自己累计「发出的序列」的哈希；
// 录制线程（或开关关着时的直调）的桩累计「收到的序列」的哈希；清空队列之后两边必须逐 cb 相等（条数、次序、每个参数、数组内容）。
//
//   C1 多生产者序列：4 个生产者各占一个 cb，混合五种调用（含大小不一的数组，以及带不认识的 pNext、必须直调的屏障），
//      总量超过队列容量 2 倍（环回绕），同时另一条线程不停地清空（vkEndCommandBuffer）。
//   C2 跨线程清空：线程 P 发 K 条调用后用 release 通知线程 W，W 在 acquire 到通知后清空队列；
//      清空返回时 P 通知之前发的每一条都必须已被录制线程做完。
//   C3 背压：录制线程每条慢 1.5 微秒，单生产者发的总量超过队列容量，生产者必须等环里有地方；全部按序做完、不死锁。
//   C5 两条线程同时清空：用两条慢记录定次序，先到的先走之后，后到的必须仍被叫醒（不能等满 1 秒的超时）。
//   C4 运行时开关：生产者在跑的时候来回切 nvk_dq（经提交处的开关读取，开 → 关 → 开），每个 cb 的序列仍然一致。
// 任何一处卡住由看门狗在 TEST_TIMEOUT_S 秒后以退出码 3 收场（队列死锁不会让 CI 挂着）。
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <vulkan/vulkan.h>
#include "nvn_plat.h"

#ifndef TEST_TIMEOUT_S
#define TEST_TIMEOUT_S 240
#endif

// ---- 平台桩 ----
static _Atomic int g_flag_dq = 1;
static _Atomic int g_red_logs, g_red_expected, g_red_ok;   // g_red_ok：这一段里「清空等了超过 1 秒」的自报红是预期的（背压段收尾时环里积压着 1 秒以上的活）
int nvn_plat_flag(const char *name, int dflt) {
    if (!strcmp(name, "nvk_dq")) return atomic_load(&g_flag_dq);
    return dflt;
}
void nvn_plat_log(int level, const char *cls, const char *text) {
    (void)cls;
    if (level == NVN_PLAT_LOG_RED || strstr(text, "RED") || strstr(text, "【红】")) {
        if (atomic_load(&g_red_ok) && strstr(text, "a drain waits over 1 s")) { atomic_fetch_add(&g_red_expected, 1); return; }
        atomic_fetch_add(&g_red_logs, 1); fprintf(stderr, "队列自报红：%s\n", text);
    }
}

// ---- 不经队列的 Vulkan 入口：空桩（队列的同步包装会调到它们）----
VKAPI_ATTR VkResult VKAPI_CALL vkBeginCommandBuffer(VkCommandBuffer cb, const VkCommandBufferBeginInfo *bi) { (void)cb; (void)bi; return VK_SUCCESS; }
VKAPI_ATTR VkResult VKAPI_CALL vkEndCommandBuffer(VkCommandBuffer cb) { (void)cb; return VK_SUCCESS; }
VKAPI_ATTR VkResult VKAPI_CALL vkAllocateCommandBuffers(VkDevice d, const VkCommandBufferAllocateInfo *ai, VkCommandBuffer *cb) { (void)d; (void)ai; (void)cb; return VK_SUCCESS; }
VKAPI_ATTR VkResult VKAPI_CALL vkResetCommandPool(VkDevice d, VkCommandPool p, VkCommandPoolResetFlags f) { (void)d; (void)p; (void)f; return VK_SUCCESS; }
VKAPI_ATTR VkResult VKAPI_CALL vkQueueSubmit(VkQueue q, uint32_t n, const VkSubmitInfo *si, VkFence f) { (void)q; (void)n; (void)si; (void)f; return VK_SUCCESS; }
VKAPI_ATTR VkResult VKAPI_CALL vkQueuePresentKHR(VkQueue q, const VkPresentInfoKHR *pi) { (void)q; (void)pi; return VK_SUCCESS; }
VKAPI_ATTR VkResult VKAPI_CALL vkQueueWaitIdle(VkQueue q) { (void)q; return VK_SUCCESS; }
VKAPI_ATTR VkResult VKAPI_CALL vkDeviceWaitIdle(VkDevice d) { (void)d; return VK_SUCCESS; }
VKAPI_ATTR void VKAPI_CALL vkDestroyCommandPool(VkDevice d, VkCommandPool p, const VkAllocationCallbacks *a) { (void)d; (void)p; (void)a; }
VKAPI_ATTR void VKAPI_CALL vkFreeCommandBuffers(VkDevice d, VkCommandPool p, uint32_t n, const VkCommandBuffer *cb) { (void)d; (void)p; (void)n; (void)cb; }
VKAPI_ATTR VkResult VKAPI_CALL vkResetCommandBuffer(VkCommandBuffer cb, VkCommandBufferResetFlags f) { (void)cb; (void)f; return VK_SUCCESS; }
VKAPI_ATTR VkResult VKAPI_CALL vkFreeDescriptorSets(VkDevice d, VkDescriptorPool p, uint32_t n, const VkDescriptorSet *s) { (void)d; (void)p; (void)n; (void)s; return VK_SUCCESS; }
VKAPI_ATTR VkResult VKAPI_CALL vkResetDescriptorPool(VkDevice d, VkDescriptorPool p, VkDescriptorPoolResetFlags f) { (void)d; (void)p; (void)f; return VK_SUCCESS; }
#define STUB_DESTROY(f, T) VKAPI_ATTR void VKAPI_CALL f(VkDevice d, T o, const VkAllocationCallbacks *a) { (void)d; (void)o; (void)a; }
STUB_DESTROY(vkDestroyBuffer, VkBuffer)
STUB_DESTROY(vkDestroyImage, VkImage)
STUB_DESTROY(vkDestroyImageView, VkImageView)
STUB_DESTROY(vkDestroyBufferView, VkBufferView)
STUB_DESTROY(vkDestroyFramebuffer, VkFramebuffer)
STUB_DESTROY(vkDestroyRenderPass, VkRenderPass)
STUB_DESTROY(vkDestroyPipeline, VkPipeline)
STUB_DESTROY(vkDestroyPipelineLayout, VkPipelineLayout)
STUB_DESTROY(vkDestroyDescriptorPool, VkDescriptorPool)
STUB_DESTROY(vkDestroyQueryPool, VkQueryPool)
STUB_DESTROY(vkDestroySampler, VkSampler)
STUB_DESTROY(vkFreeMemory, VkDeviceMemory)
STUB_DESTROY(vkDestroySemaphore, VkSemaphore)
STUB_DESTROY(vkDestroyFence, VkFence)
STUB_DESTROY(vkDestroyDescriptorSetLayout, VkDescriptorSetLayout)
STUB_DESTROY(vkDestroyShaderModule, VkShaderModule)

// ---- 录制这一侧：记录桩（队列开着时在录制线程上跑，关着时在生产者线程上跑）----
enum { MAXCB = 8, CB_BASE = 0x1000 };
static uint64_t g_hash[MAXCB], g_cnt[MAXCB];   // 同一个 cb 同一时刻只有一侧在写（直调前先清空）；主线程在清空之后读（清空返回对录制线程的 release 写有 acquire）
static _Atomic uint64_t g_executed[MAXCB];      // 每做完一条加一（release）
static _Atomic int g_unexpected;                // 桩被调到没登记的调用
static int g_slow_ns;                           // 录制每条额外耗时（制造背压）；改它只在队列清空之后

static uint64_t mix(uint64_t h, uint64_t v) { h ^= v + 0x9e3779b97f4a7c15ull + (h << 6) + (h >> 2); h *= 0xff51afd7ed558ccdull; return h ^ (h >> 29); }
static uint64_t fold(uint64_t h, uint64_t op, uint64_t a, uint64_t b, uint64_t c, uint64_t d) { return mix(mix(mix(mix(mix(h, op), a), b), c), d); }
static uint64_t hash_bytes(const void *p, size_t n) { const uint8_t *s = p; uint64_t h = 1469598103934665603ull; for (size_t i = 0; i < n; i++) { h ^= s[i]; h *= 1099511628211ull; } return h; }
static unsigned cb_index(VkCommandBuffer cb) { return (unsigned)((uintptr_t)cb - CB_BASE); }
static VkCommandBuffer cb_of(unsigned i) { return (VkCommandBuffer)(uintptr_t)(CB_BASE + i); }
static void spin_ns(int ns) { struct timespec a, b; clock_gettime(CLOCK_MONOTONIC, &a); do { clock_gettime(CLOCK_MONOTONIC, &b); } while ((b.tv_sec - a.tv_sec) * 1000000000ll + (b.tv_nsec - a.tv_nsec) < ns); }

static void rec_note(VkCommandBuffer cb, uint64_t op, uint64_t a, uint64_t b, uint64_t c, uint64_t d) {
    unsigned i = cb_index(cb);
    if (i >= MAXCB) { atomic_store(&g_unexpected, 1); return; }
    if (g_slow_ns) spin_ns(g_slow_ns);   // 先慢后记：清空若在这一条做完之前就返回，调用方立刻读到的条数 / 已做完数就差一条
    g_hash[i] = fold(g_hash[i], op, a, b, c, d); g_cnt[i]++;
    atomic_fetch_add_explicit(&g_executed[i], 1, memory_order_release);
}
static VKAPI_ATTR void VKAPI_CALL rec_draw(VkCommandBuffer cb, uint32_t vc, uint32_t ic, uint32_t fv, uint32_t fi) { rec_note(cb, 1, vc, ic, fv, fi); }
static VKAPI_ATTR void VKAPI_CALL rec_bindpipe(VkCommandBuffer cb, VkPipelineBindPoint bp, VkPipeline p) { rec_note(cb, 2, (uint64_t)bp, (uint64_t)(uintptr_t)p, 0, 0); }
static VKAPI_ATTR void VKAPI_CALL rec_viewport(VkCommandBuffer cb, uint32_t first, uint32_t n, const VkViewport *vp) { rec_note(cb, 3, first, n, hash_bytes(vp, n * sizeof *vp), 0); }
static VKAPI_ATTR void VKAPI_CALL rec_barrier(VkCommandBuffer cb, VkPipelineStageFlags src, VkPipelineStageFlags dst, VkDependencyFlags dep, uint32_t nm, const VkMemoryBarrier *m,
                                              uint32_t nb, const VkBufferMemoryBarrier *b, uint32_t ni, const VkImageMemoryBarrier *im) {
    (void)b;
    rec_note(cb, 4, ((uint64_t)src << 32) | dst, ((uint64_t)nm << 40) | ((uint64_t)nb << 20) | ni, hash_bytes(im, ni * sizeof *im), dep ^ (nm ? hash_bytes(m, nm * sizeof *m) : 0));
}
static VKAPI_ATTR void VKAPI_CALL rec_dispatch(VkCommandBuffer cb, uint32_t x, uint32_t y, uint32_t z) {
    if (z == 0x5101u) spin_ns(100 * 1000 * 1000);   // C5 的两条「慢记录」：z 取不到别处发的 dispatch 会用的值（那些 z ≤ 15）
    else if (z == 0x5102u) spin_ns(40 * 1000 * 1000);
    rec_note(cb, 5, x, y, z, 0);
}
static void rec_nop(void) { atomic_store(&g_unexpected, 1); }
VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetDeviceProcAddr(VkDevice d, const char *name) {
    (void)d;
    if (!strcmp(name, "vkCmdDraw")) return (PFN_vkVoidFunction)rec_draw;
    if (!strcmp(name, "vkCmdBindPipeline")) return (PFN_vkVoidFunction)rec_bindpipe;
    if (!strcmp(name, "vkCmdSetViewport")) return (PFN_vkVoidFunction)rec_viewport;
    if (!strcmp(name, "vkCmdPipelineBarrier")) return (PFN_vkVoidFunction)rec_barrier;
    if (!strcmp(name, "vkCmdDispatch")) return (PFN_vkVoidFunction)rec_dispatch;
    return (PFN_vkVoidFunction)rec_nop;
}

// ---- 被测：队列本体（包含之后，vkCmd* / vkEndCommandBuffer 等名字走它的包装）----
#include "nvn_vk_dq.inc"

// ---- 检查计数 ----
static int g_checks, g_bad;
#define CHECK(c, ...) do { g_checks++; if (!(c)) { g_bad++; fprintf(stderr, "【红】" __VA_ARGS__); fputc('\n', stderr); fflush(stderr); } } while (0)

// ---- 生产者：按固定种子发混合调用，同时累计「发出的序列」的哈希 ----
typedef struct { unsigned cb; uint64_t seed, n, hash; int only_dispatch; } prod_t;
static uint64_t rnd(uint64_t *s) { uint64_t x = *s; x ^= x >> 12; x ^= x << 25; x ^= x >> 27; *s = x; return x * 0x2545F4914F6CDD1Dull; }
static void issue_one(prod_t *p) {
    VkCommandBuffer cb = cb_of(p->cb);
    uint64_t r = rnd(&p->seed); unsigned k = p->only_dispatch ? 99 : (unsigned)(r % 100);
    if (k < 45) {
        uint32_t vc = (uint32_t)(r >> 8), ic = (uint32_t)(r >> 40) & 0xff, fv = (uint32_t)(r >> 16) & 0xffff, fi = (uint32_t)(r >> 3) & 0xfff;
        vkCmdDraw(cb, vc, ic, fv, fi);
        p->hash = fold(p->hash, 1, vc, ic, fv, fi);
    } else if (k < 65) {
        VkPipelineBindPoint bp = (VkPipelineBindPoint)(r & 1); VkPipeline pl = (VkPipeline)(uintptr_t)(rnd(&p->seed) | 1);
        vkCmdBindPipeline(cb, bp, pl);
        p->hash = fold(p->hash, 2, (uint64_t)bp, (uint64_t)(uintptr_t)pl, 0, 0);
    } else if (k < 80) {
        uint32_t n = 1 + (uint32_t)(r >> 7) % 8, first = (uint32_t)(r >> 20) & 7; VkViewport vp[8];
        for (uint32_t i = 0; i < n; i++) { vp[i].x = (float)(int32_t)rnd(&p->seed); vp[i].y = (float)(r & 0xfff); vp[i].width = (float)(i + 1); vp[i].height = (float)(r >> 50); vp[i].minDepth = 0.f; vp[i].maxDepth = 1.f; }
        vkCmdSetViewport(cb, first, n, vp);
        p->hash = fold(p->hash, 3, first, n, hash_bytes(vp, n * sizeof *vp), 0);
    } else if (k < 90) {
        uint32_t ni = (uint32_t)(r >> 9) % 41; VkImageMemoryBarrier im[40];
        memset(im, 0, sizeof im);
        for (uint32_t i = 0; i < ni; i++) { im[i].sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER; im[i].srcAccessMask = (VkAccessFlags)rnd(&p->seed); im[i].dstAccessMask = (VkAccessFlags)(r >> 5); im[i].oldLayout = (VkImageLayout)(i & 7);
            im[i].newLayout = (VkImageLayout)((r >> 13) & 7); im[i].image = (VkImage)(uintptr_t)(rnd(&p->seed) | 1); im[i].subresourceRange.levelCount = i + 1; }
        VkPipelineStageFlags src = (VkPipelineStageFlags)(r >> 11) & 0xffff, dst = (VkPipelineStageFlags)(r >> 29) & 0xffff; VkDependencyFlags dep = (VkDependencyFlags)(r & 3);
        uint32_t nm = 0; VkMemoryBarrier mb; memset(&mb, 0, sizeof mb);
        if (((r >> 17) & 7) == 0) {   // 八分之一的屏障带不认识的 pNext：队列不拷这种调用，得等队列清空后直调——次序不能乱
            static const int dummy_next = 0; mb.sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER; mb.pNext = &dummy_next; mb.srcAccessMask = (VkAccessFlags)(r >> 3); mb.dstAccessMask = (VkAccessFlags)(r >> 21); nm = 1;
        }
        vkCmdPipelineBarrier(cb, src, dst, dep, nm, nm ? &mb : NULL, 0, NULL, ni, ni ? im : NULL);
        p->hash = fold(p->hash, 4, ((uint64_t)src << 32) | dst, ((uint64_t)nm << 40) | ni, hash_bytes(im, ni * sizeof *im), dep ^ (nm ? hash_bytes(&mb, sizeof mb) : 0));
    } else {
        uint32_t x = (uint32_t)(r >> 8) & 0xffff, y = (uint32_t)(r >> 24) & 0xff, z = (uint32_t)(r >> 40) & 0xf;
        vkCmdDispatch(cb, x, y, z);
        p->hash = fold(p->hash, 5, x, y, z, 0);
    }
    p->n++;
}
static void *producer_main(void *arg) { prod_t *p = arg; uint64_t target = p->n; p->n = 0; for (uint64_t i = 0; i < target; i++) issue_one(p); return NULL; }   // 进来时 n = 目标条数，出去时 n = 实际发出的条数

// ---- 看门狗 ----
static void *watchdog_main(void *arg) { (void)arg; sleep(TEST_TIMEOUT_S); fprintf(stderr, "【红】超时：用例 %d 秒内没跑完（队列卡住 / 死锁？）\n", TEST_TIMEOUT_S); fflush(stderr); _exit(3); }

// ---- 公用：切开关（经提交处读取：每 64 次提交读一次，64 次里必有一次），并确认切到了 ----
static void set_dq(int on) {
    atomic_store(&g_flag_dq, on);
    for (int i = 0; i < 64; i++) vkQueueSubmit(NULL, 0, NULL, VK_NULL_HANDLE);
    CHECK((g_dq_on != 0) == (on != 0), "两级回放开关没切过去：期望 %d → %d", on, g_dq_on);
}
static void reset_sinks(void) { vkDeviceWaitIdle(NULL); memset(g_hash, 0, sizeof g_hash); memset(g_cnt, 0, sizeof g_cnt); for (int i = 0; i < MAXCB; i++) atomic_store(&g_executed[i], 0); }
static void phase(const char *name) { printf("阶段开始：%s\n", name); fflush(stdout); }   // 崩溃 / 超时时，日志里最后一行告诉你卡在哪个阶段

// ---- C1 / C4：多生产者序列 ----
static _Atomic int g_noise_run;
static void *noise_main(void *arg) {   // 另一条线程不停地清空：清空与生产者的写入互相穿插
    (void)arg; unsigned k = 0;
    while (atomic_load(&g_noise_run)) { vkEndCommandBuffer(cb_of(MAXCB - 1)); if (!(++k & 7)) sched_yield(); }
    return NULL;
}
static _Atomic int g_toggle_run;
static void *toggler_main(void *arg) {   // C4：生产者在跑，来回切开关
    (void)arg; unsigned k = 0;
    while (atomic_load(&g_toggle_run)) { set_dq(k++ & 1 ? 1 : 0); usleep(300); }
    return NULL;
}
static void run_seq_phase(const char *name, int nprod, uint64_t per_prod, int noise, int toggle) {
    phase(name);
    set_dq(1); reset_sinks();
    uint64_t w0 = g_dq_w, recs0 = nvn_vk_dbg_dq_recs();
    prod_t pr[MAXCB - 1]; pthread_t th[MAXCB - 1], nz = 0, tg = 0;
    for (int i = 0; i < nprod; i++) { pr[i] = (prod_t){ .cb = (unsigned)i, .seed = 0x1234567ull * (uint64_t)(i + 1) + 99, .n = per_prod, .hash = 0, .only_dispatch = 0 }; }
    if (noise) { atomic_store(&g_noise_run, 1); pthread_create(&nz, NULL, noise_main, NULL); }
    if (toggle) { atomic_store(&g_toggle_run, 1); pthread_create(&tg, NULL, toggler_main, NULL); }
    for (int i = 0; i < nprod; i++) pthread_create(&th[i], NULL, producer_main, &pr[i]);
    for (int i = 0; i < nprod; i++) pthread_join(th[i], NULL);
    if (noise) { atomic_store(&g_noise_run, 0); pthread_join(nz, NULL); }
    if (toggle) { atomic_store(&g_toggle_run, 0); pthread_join(tg, NULL); }
    vkQueueWaitIdle(NULL);   // 清空
    for (int i = 0; i < nprod; i++) {
        CHECK(g_cnt[i] == pr[i].n, "%s：cb %d 条数不符：发 %llu → 收 %llu", name, i, (unsigned long long)pr[i].n, (unsigned long long)g_cnt[i]);
        CHECK(g_hash[i] == pr[i].hash, "%s：cb %d 序列哈希不符（次序 / 参数 / 数组内容有出入）", name, i);
    }
    CHECK(!atomic_load(&g_unexpected), "%s：录制做了没登记的调用", name);
    CHECK(nvn_vk_dbg_dq_recs() > recs0, "%s：没有一条调用经过队列", name);
    double mb = (double)(g_dq_w - w0) / 1048576.0;
    printf("  %-38s %d 个生产者共 %llu 条，写入 %.1f MB%s\n", name, nprod, (unsigned long long)(per_prod * (uint64_t)nprod), mb, mb > 2.0 * (double)dq_RING / 1048576.0 ? "（环已回绕 2 次以上）" : "");
}

// ---- C2：跨线程清空 ----
static _Atomic uint64_t g_issued0;
static _Atomic int g_round_flag, g_round_ack;
static int g_rounds;
static void *p_main(void *arg) {
    (void)arg; prod_t p = { .cb = 0, .seed = 0xabcdef12345ull, .n = 0, .hash = 0, .only_dispatch = 0 }; uint64_t total = 0, s = 0x777ull;
    for (int r = 1; r <= g_rounds; r++) {
        uint32_t k = 1 + (uint32_t)(rnd(&s) % ((r & 1) ? 12 : 300));   // 奇数轮条数少，偶数轮条数多
        for (uint32_t i = 0; i < k; i++) issue_one(&p);
        total += k;
        atomic_store_explicit(&g_issued0, total, memory_order_release);
        atomic_store_explicit(&g_round_flag, r, memory_order_release);
        while (atomic_load_explicit(&g_round_ack, memory_order_acquire) != r) sched_yield();
    }
    return NULL;
}
static void run_drain_phase(int rounds) {
    phase("C2 跨线程清空");
    set_dq(1); reset_sinks(); g_slow_ns = 2000; g_rounds = rounds; atomic_store(&g_round_flag, 0); atomic_store(&g_round_ack, 0); atomic_store(&g_issued0, 0);
    pthread_t t; pthread_create(&t, NULL, p_main, NULL);
    int viol = 0;
    for (int r = 1; r <= rounds; r++) {
        while (atomic_load_explicit(&g_round_flag, memory_order_acquire) != r) sched_yield();
        uint64_t issued = atomic_load_explicit(&g_issued0, memory_order_acquire);
        vkEndCommandBuffer(cb_of(1));   // 别的线程清空：P 通知之前发的调用都得做完
        uint64_t ex = atomic_load_explicit(&g_executed[0], memory_order_acquire);
        if (ex < issued) viol++;
        atomic_store_explicit(&g_round_ack, r, memory_order_release);
    }
    pthread_join(t, NULL);
    vkQueueWaitIdle(NULL); g_slow_ns = 0;
    CHECK(viol == 0, "C2：%d / %d 轮清空返回时仍有通知之前发的调用没做完", viol, rounds);
    printf("  %-38s %d 轮，清空后欠账的轮数 %d\n", "C2 跨线程清空", rounds, viol);
}

// ---- C5：两条线程同时清空，先到的先走 ----
// 回归：清空线程的「在等」标记曾是个标志位——先走的那条把它抹掉，后到的还在等，录制线程做完最后一条见标记是 0，不再叫醒它，它只能等满 1 秒的超时。
// 做法（全靠两条慢记录定次序，不靠碰运气）：R1 让录制线程耗 100 毫秒；A 在 R1 之后清空，开始等；R2（40 毫秒）排在 R1 后面；B 在 R2 之后清空。
// R1 做完叫醒 A、B：A 走（把标记抹掉），B 的位置还没到，继续等；R2 做完时标记若已被抹掉就没有人叫 B。B 应在约 120 毫秒后返回，不是 1 秒。
static uint64_t now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec; }
static void *c5_a_main(void *arg) { (void)arg; vkEndCommandBuffer(cb_of(1)); return NULL; }
static void run_two_drainers_phase(void) {
    phase("C5 两条线程同时清空");
    set_dq(1); reset_sinks();
    vkCmdDispatch(cb_of(0), 1, 1, 0x5101);   // R1
    pthread_t ta; pthread_create(&ta, NULL, c5_a_main, NULL);   // A：快照在 R1 之后
    usleep(20 * 1000);   // A 已经在等（R1 还要做 80 毫秒）
    vkCmdDispatch(cb_of(0), 2, 2, 0x5102);   // R2，排在 R1 后面
    uint64_t t0 = now_ns();
    vkEndCommandBuffer(cb_of(1));   // B：快照在 R2 之后
    double b_ms = (double)(now_ns() - t0) / 1e6;
    pthread_join(ta, NULL);
    CHECK(b_ms < 600.0, "C5：后到的清空等了 %.0f 毫秒（应约 120 毫秒；等满 1 秒的超时 = 先走的那条把「在等」标记抹掉了，没人叫醒它）", b_ms);
    CHECK(g_cnt[0] == 2, "C5：条数不符：发 2 → 收 %llu", (unsigned long long)g_cnt[0]);
    printf("  %-38s 后到的清空等了 %.0f 毫秒\n", "C5 两条线程同时清空", b_ms);
}

// ---- C3：背压 ----
static void run_pressure_phase(uint64_t n) {
    phase("C3 背压");
    set_dq(1); reset_sinks();
    g_slow_ns = 1500;
    prod_t p = { .cb = 0, .seed = 0x5eed5eedull, .n = n, .hash = 0, .only_dispatch = 1 };
    uint64_t w0 = g_dq_w;
    producer_main(&p);   // 本线程当生产者：队列满了它就得等
    atomic_store(&g_red_ok, 1);
    vkQueueWaitIdle(NULL);   // 环里还积压着一大截：这一次清空会等很久
    atomic_store(&g_red_ok, 0);
    g_slow_ns = 0;
    CHECK(g_cnt[0] == p.n, "C3：条数不符：发 %llu → 收 %llu", (unsigned long long)p.n, (unsigned long long)g_cnt[0]);
    CHECK(g_hash[0] == p.hash, "C3：序列哈希不符");
    double mb = (double)(g_dq_w - w0) / 1048576.0;
    CHECK(mb > 1.5 * (double)dq_RING / 1048576.0, "C3：写入量 %.1f MB 没超过队列容量，没有真正压到背压", mb);
    printf("  %-38s %llu 条，写入 %.1f MB（队列 %d MB）\n", "C3 背压（录制每条慢 1.5 微秒）", (unsigned long long)n, mb, dq_RING >> 20);
}

int main(void) {
    pthread_t wd; pthread_create(&wd, NULL, watchdog_main, NULL); pthread_detach(wd);
    vk_dq_init((VkDevice)(uintptr_t)0x1);
    CHECK(g_dq_ring != NULL && g_dq_on, "队列没起来（环内存 / 录制线程）");
    if (!g_dq_ring) { printf("dq_queue_test：队列没起来\n"); return 1; }
    printf("两级回放队列宿主用例（真队列 + 真录制线程 + 记录桩）\n");
    run_seq_phase("C1 多生产者序列（另有线程不停清空）", 4, 160000, 1, 0);
    run_drain_phase(3000);
    run_two_drainers_phase();
    run_pressure_phase(1200000);
    run_seq_phase("C4 运行时来回切 nvk_dq", 3, 200000, 0, 1);
    CHECK(atomic_load(&g_red_logs) == 0, "队列自己报过 %d 次红", atomic_load(&g_red_logs));
    printf("dq_queue_test：%d 项检查，%d 项红（交给录制线程 %llu 条，直调 %llu 次）\n", g_checks, g_bad, (unsigned long long)nvn_vk_dbg_dq_recs(), (unsigned long long)g_dq_direct);
    return g_bad ? 1 : 0;
}
