// 写跟踪「取范围」有序索引（#1133，nvn_dirty.c 的 find_span）单测：
//   ① 答案与线性扫（find_span_scan）逐位一致：含「没有」、边界差一字节、跨出范围、共用边界页（槽号小的优先）、大池里套小池、同起点、零长度与地址回绕；
//   ② 索引与槽位表一致：按 (起点, 槽号) 严格有序、每个子树根记的 sm 是子树里最大的 end、条目与现存范围一一对上；每次写者操作之后都查；
//   ③ 写者纪律：登记 / 注销 / 换底 / 重置会话收工时代际必须是偶数且比开工前大；
//   ④ 表一变答案跟着变（登记 / 注销 / 复用槽位 / 换底 / 重置会话）；代际为奇数时不信索引；
//      查询中途有写者插进来（编译期钩子，确定性）时丢掉已经算出来的索引答案，改走线性扫；
//   ⑤ 现存范围超过索引上限时索引停用、一律线性扫、答案仍对，重置会话后恢复；
//   ⑥ 随机增删 + 随机问（含贴着边界的问法），每步对照线性扫并查索引一致；
//   ⑦ 并发：一个线程不停增删范围（每次都把已有的条目整体挪一位、重算 sm），别的线程读：永远在的范围永远答对（挪动中途读到半改状态不能漏），
//      永远没有范围的地址永远是「没有」；改完之后读者读到的是改后的答案。
// 直接包含生产源码（要读 find_span / find_span_scan / 索引内部，并可换成变异副本跑负对照：dirty_span_memo_mutation_test.py）。
// 登记的范围多数落在一块只读不写的真映射里（换底要对它 mprotect，地址不存在会失败），测试自己从不写它；上限 / 压力用例的范围用不存在的地址（登记与注销都不碰那块内存）。
#ifndef NVN_DIRTY_SPAN_SOURCE
#define NVN_DIRTY_SPAN_SOURCE "../gfx/nvn/nvn_dirty.c"
#endif
#define NVN_DIRTY_SPAN_IDX_MAX 3072   // 3 块；上限用例只需登记 3073 个
static void (*g_after_query)(void);   // 钩子：find_span 读完索引、复查代际之前调一次
#define NVN_DIRTY_SPAN_AFTER_QUERY() do { if (g_after_query) g_after_query(); } while (0)
static int g_fail_alloc;              // 钩子：置 1 时索引分配新块失败
static void *test_span_calloc(void);
#define NVN_DIRTY_SPAN_CALLOC() test_span_calloc()
#include NVN_DIRTY_SPAN_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>

void dm_fault_hook_register(int (*fn)(void *addr, int is_write, void *uc)) { (void)fn; }
void dm_guest_write_prep_register(void (*fn)(void *addr, size_t len)) { (void)fn; }
void dm_log(const char *fmt, ...) { (void)fmt; }

static unsigned checks, failures;
#define CK(c, msg) do { checks++; if (!(c)) { failures++; fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, msg); } } while (0)

enum { ARENA_PAGES = 400 };
static uintptr_t PG, ARENA;
static uintptr_t fake(uintptr_t page, uintptr_t byte) { return ARENA + page * PG + byte; }
static uint64_t ep(void) { return atomic_load(&g_table_epoch); }
// 写者纪律：每个写者收工时代际必须是偶数、且比开工前大（读者靠它判「有人正在改表」和「表变过」）。
// 每次都查：一处少加代际，后面所有写者的奇偶会整体反过来、之后的检查跟着失效，所以第一次就要抓住。
static void ck_epoch_step(const char *who, uint64_t before) {
    uint64_t after = ep(); char msg[96]; snprintf(msg, sizeof msg, "写者「%s」收工后代际必须是偶数且比开工前大", who);
    CK(!(after & 1) && after > before, msg);
}
static void ck_index(const char *when);
static void add(uintptr_t page, uintptr_t byte, size_t size) { uint64_t e = ep(); nvn_dirty_add_range((const void *)fake(page, byte), size); ck_epoch_step("登记", e); ck_index("登记"); }
static void del(uintptr_t page, uintptr_t byte) { uint64_t e = ep(); nvn_dirty_remove_range((const void *)fake(page, byte)); ck_epoch_step("注销", e); ck_index("注销"); }
static int slot_of(const range_t *r) { int n = atomic_load(&g_nr); for (int i = 0; i < n; i++) if (rg(i) == r) return i; return -1; }
static uint64_t idx_hits(void) { uint64_t h, s, n; nvn_dirty_span_stats(&h, &s, &n); return h; }
static uint64_t scans(void) { uint64_t h, s, n; nvn_dirty_span_stats(&h, &s, &n); return s; }
static void reset_world(void) { uint64_t e = ep(); nvn_dirty_reset_session(); ck_epoch_step("重置会话", e); }
static uint32_t rnd_state = 12345;
static uint32_t rnd(void) { rnd_state = rnd_state * 1664525u + 1013904223u; return rnd_state >> 8; }

// ---------- ② 索引与槽位表一致 ----------
static uintptr_t chk_sm(int lo, int hi, unsigned *bad) {   // 独立重算每个子树的最大 end，与记下的 sm 对账
    if (lo >= hi) return 0;
    const int mid = (lo + hi) >> 1; const span_ent *e = span_at(mid);
    uintptr_t m = span_end(e);
    const uintptr_t l = chk_sm(lo, mid, bad), r = chk_sm(mid + 1, hi, bad);
    if (l > m) m = l;
    if (r > m) m = r;
    if (atomic_load(&e->sm) != m) (*bad)++;
    return m;
}
static int g_expect_off;   // 停用索引的用例置 1：此时索引不再维护，不对账；其余用例里索引绝不该停用
static void ck_index(const char *when) {
    if (atomic_load(&g_span_off)) { CK(g_expect_off, "索引意外停用（写者操作后条目对不上 / 分配失败 / 超上限）"); return; }
    const int n = atomic_load(&g_span_n), nr = atomic_load(&g_nr);
    int live = 0; for (int i = 0; i < nr; i++) live += live_at(i) != 0;
    unsigned bad_count = n != live, bad_order = 0, bad_entry = 0, bad_dup = 0, bad_sm = 0;
    unsigned char *seen = calloc((size_t)nr + 1, 1);
    if (!seen) { CK(0, "ck_index 分配失败"); return; }
    for (int i = 0; i < n; i++) {
        const span_ent *e = span_at(i); const uint32_t s = span_slot(e);
        if (i && !(span_base(span_at(i - 1)) < span_base(e) || (span_base(span_at(i - 1)) == span_base(e) && span_slot(span_at(i - 1)) < s))) bad_order++;
        if ((int)s >= nr || !live_at((int)s) || rg((int)s)->base != span_base(e) || rg((int)s)->end != span_end(e)) { bad_entry++; continue; }
        if (seen[s]++) bad_dup++;
    }
    free(seen);
    chk_sm(0, n, &bad_sm);
    char msg[160];
    snprintf(msg, sizeof msg, "%s之后索引与槽位表对不上：条数 %d（现存 %d）、乱序 %u、条目对不上 %u、槽重复 %u、sm 错 %u", when, n, live, bad_order, bad_entry, bad_dup, bad_sm);
    CK(!bad_count && !bad_order && !bad_entry && !bad_dup && !bad_sm, msg);
}

// ---------- ① 基本：答案与线性扫一致，边界差一字节 ----------
static void t_basic(void) {
    reset_world();
    add(0, 0, 4 * PG);     // 槽 0：页 [0,4)
    add(16, 0, 4 * PG);    // 槽 1：页 [16,20)
    range_t *r0 = find_span_scan(fake(0, 0), 1), *r1 = find_span_scan(fake(16, 0), 1);
    CK(slot_of(r0) == 0 && slot_of(r1) == 1, "前提：两个范围在槽 0 / 1");
    uint64_t h0 = idx_hits(), s0 = scans();
    CK(find_span(fake(1, 5), PG) == r0, "命中槽 0 的跨度");
    CK(idx_hits() == h0 + 1 && scans() == s0, "答案由索引给出，没有退回线性扫");
    CK(find_span(fake(1, 5), 8 * PG) == NULL, "同起点更长：装不下槽 0，答案是「没有」");
    CK(find_span(fake(8, 0), PG) == NULL, "空洞里没有范围");
    CK(find_span(fake(3, 0), 2 * PG) == NULL, "跨出槽 0 末尾的跨度没有范围装得下");
    CK(find_span(fake(16, 7), 3) == r1, "槽 1 内的小跨度");
    // 边界差一字节
    const uintptr_t b0 = fake(0, 0), e0 = fake(4, 0), bb = (uintptr_t)PG * 4;
    CK(find_span(b0, bb) == r0, "刚好装满：起点 = 范围起点、末尾 = 范围末尾");
    CK(find_span(b0, bb + 1) == NULL, "多出一字节装不下");
    CK(find_span(b0 - 1, 2) == NULL, "起点在范围前一字节：不算在内");
    CK(find_span(e0 - 1, 1) == r0, "最后一个字节在内");
    CK(find_span(e0, 1) == NULL, "末尾之后第一个字节不在内");
    CK(find_span(e0 - 8, 8) == r0 && find_span(e0 - 8, 9) == NULL, "末尾对齐的跨度：差一字节就装不下");
    // 相邻不共页的两个范围：跨过两者交界的跨度没有谁装得下
    add(4, 0, 4 * PG);     // 槽 2：页 [4,8)，与槽 0 首尾相接
    CK(find_span(fake(3, 0), 2 * PG) == NULL, "跨在两个相邻范围交界上的跨度：谁也装不下");
    CK(slot_of(find_span(fake(4, 0), PG)) == 2 && slot_of(find_span(fake(3, 0), PG)) == 0, "交界两侧各归各的");
    // 零长度与地址回绕：交给线性扫，答案与线性扫相同
    uint64_t s1 = scans();
    CK(find_span(fake(1, 0), 0) == find_span_scan(fake(1, 0), 0), "零长度：答案与线性扫一致");
    CK(find_span(fake(8, 0), 0) == find_span_scan(fake(8, 0), 0), "零长度（空洞里）：答案与线性扫一致");
    CK(find_span(fake(1, 0), SIZE_MAX) == find_span_scan(fake(1, 0), SIZE_MAX), "长度回绕：答案与线性扫一致");
    CK(scans() == s1 + 3, "零长度与回绕走线性扫");
    CK(nvn_dirty_tracked((const void *)fake(1, 0), PG) == 1 && nvn_dirty_tracked((const void *)fake(8, 0), PG) == 0, "nvn_dirty_tracked 随之");
    CK(nvn_dirty_span((const void *)fake(17, 0), PG) == r1 && nvn_dirty_span((const void *)fake(17, 0), 0) == NULL, "nvn_dirty_span 随之；零长度返回 NULL");
}

// ---------- ① 续：共用边界页、嵌套、同起点 ----------
static void t_overlap(void) {
    // 共用一页：先登记的（槽号小的）优先
    reset_world();
    add(64, 0, 2 * PG);                  // 槽 0：页 [64,66)
    add(65, 0, 2 * PG);                  // 槽 1：页 [65,67)，与槽 0 共用页 65
    range_t *a = find_span_scan(fake(64, 0), 1), *b = find_span_scan(fake(66, 0), 1);
    CK(slot_of(a) == 0 && slot_of(b) == 1, "前提：重叠的两个范围在槽 0 / 1");
    CK(find_span(fake(65, 8), 16) == a, "共用页里的小跨度：槽号小的优先");
    CK(find_span(fake(66, 0), PG) == b && find_span(fake(64, 0), PG) == a, "各自独有的页归各自");
    CK(find_span(fake(65, 0), 2 * PG) == b, "只有槽 1 装得下的跨度（越过槽 0 的末尾）");
    del(64, 0);
    CK(find_span(fake(65, 8), 16) == b, "槽 0 注销后，同一个跨度改由槽 1 回答");
    add(60, 0, 10 * PG);                 // 复用槽 0，盖住页 [60,70)
    CK(slot_of(find_span(fake(65, 8), 16)) == 0, "新范围复用槽 0 后，同一个跨度又由槽 0 回答（槽号小的优先，与起点先后无关）");

    // 大池里套小池：大池登记得最早（槽 0）
    reset_world();
    add(100, 0, 40 * PG);                // 槽 0：页 [100,140)
    for (int i = 0; i < 12; i++) add(104 + 3 * (uintptr_t)i, 0, 2 * PG);   // 槽 1..12：各占 2 页，都在大池里面
    CK(slot_of(find_span(fake(105, 0), PG)) == 0, "小池里的跨度：大池（槽 0）也装得下，槽号小的优先");
    CK(slot_of(find_span(fake(101, 0), 30 * PG)) == 0, "只有大池装得下的长跨度");
    CK(find_span(fake(99, 0), 2 * PG) == NULL && find_span(fake(139, 0), 2 * PG) == NULL, "越出大池两端的跨度没有范围装得下");
    del(100, 0);                         // 大池注销：小池各自回答
    CK(slot_of(find_span(fake(105, 0), PG)) == 1 && slot_of(find_span(fake(110, 0), PG)) == 3, "大池注销后，小池各自回答");
    CK(find_span(fake(101, 0), 30 * PG) == NULL, "大池注销后长跨度没有了");
    add(98, 0, 50 * PG);                 // 复用槽 0 的新大池，盖住 [98,148)
    CK(slot_of(find_span(fake(110, 0), PG)) == 0, "新大池复用槽 0，盖住所有小池");
    // 大池登记得最晚：小池（槽号小）优先回答它们装得下的跨度，装不下的交给大池
    reset_world();
    for (int i = 0; i < 12; i++) add(104 + 3 * (uintptr_t)i, 0, 2 * PG);   // 槽 0..11
    add(100, 0, 40 * PG);                // 槽 12
    CK(slot_of(find_span(fake(105, 0), PG)) == 0, "大池登记得晚：小池（槽号小）优先");
    CK(slot_of(find_span(fake(105, 0), 4 * PG)) == 12, "小池装不下的跨度由大池回答");

    // 同起点：同一块内存登记两次（两个池视图），先登记的优先；按起点注销时注销先匹配到的那个
    reset_world();
    add(80, 0, 2 * PG); add(80, 0, 2 * PG); add(80, 100, 3 * PG);   // 槽 0、1：相同；槽 2：起点相同、长一点
    CK(slot_of(find_span(fake(80, 8), 16)) == 0, "同起点：槽 0 优先");
    CK(slot_of(find_span(fake(80, 8), 3 * PG - 200)) == 2, "只有槽 2 装得下");
    del(80, 0);
    CK(slot_of(find_span(fake(80, 8), 16)) == 1, "注销按起点匹配到的第一个（槽 0）后，槽 1 回答");
    del(80, 0);
    CK(slot_of(find_span(fake(80, 8), 16)) == 2, "槽 1 也注销后，槽 2 回答");
}

// ---------- ④ 作废：登记 / 注销 / 槽位复用 / 换底 / 重置会话 ----------
static void t_invalidate(void) {
    reset_world();
    add(0, 0, 4 * PG);     // 槽 0
    add(16, 0, 4 * PG);    // 槽 1
    CK(find_span(fake(8, 0), PG) == NULL, "前提：页 8 没有范围");
    add(8, 0, 2 * PG);     // 槽 2 盖住页 8
    range_t *r2 = find_span_scan(fake(8, 0), PG);
    CK(slot_of(r2) == 2, "前提：新范围在槽 2");
    CK(find_span(fake(8, 0), PG) == r2, "登记之后，旧的「没有」不再成立，答案是新范围");

    range_t *r1 = find_span_scan(fake(16, 0), 1);
    CK(find_span(fake(17, 0), PG) == r1, "前提：槽 1 的答案");
    del(16, 0);
    CK(find_span(fake(17, 0), PG) == NULL, "注销之后答案是「没有」");
    add(32, 0, 2 * PG);    // 复用槽 1
    CK(slot_of(find_span_scan(fake(32, 0), 1)) == 1, "前提：槽 1 被别的池复用");
    CK(find_span(fake(17, 0), PG) == NULL, "槽位被别处复用后，旧地址仍然是「没有」，不能拿到复用后的槽");
    CK(slot_of(find_span(fake(32, 0), PG)) == 1, "复用后的新范围查得到");

    // 换底：原地换底改的是页状态，范围的位置不变；换成不同长度会走「删除 + 重新登记」
    reset_world();
    add(0, 0, 4 * PG);
    range_t *q = find_span_scan(fake(0, 0), 1);
    CK(find_span(fake(1, 0), PG) == q, "前提：已能查到");
    { uint64_t e = ep(); CK(nvn_dirty_replace_range((const void *)fake(0, 0), 4 * PG) == 1, "原地换底成功"); ck_epoch_step("原地换底", e); ck_index("原地换底"); }
    CK(find_span(fake(1, 0), PG) == q, "原地换底后答案不变");
    { uint64_t e = ep(); CK(nvn_dirty_replace_range((const void *)fake(0, 0), 2 * PG) == 1, "换成不同长度：走删除 + 重新登记"); ck_epoch_step("换成不同长度", e); ck_index("换成不同长度"); }
    CK(find_span(fake(3, 0), PG) == NULL && find_span(fake(1, 0), PG) != NULL, "新长度只盖前 2 页");

    // 重置会话：块被释放，索引清空
    reset_world();
    add(0, 0, 4 * PG);
    CK(find_span(fake(1, 0), PG) != NULL, "前提：已能查到");
    { uint64_t e = ep(); nvn_dirty_reset_session(); ck_epoch_step("重置会话", e); }
    CK(atomic_load(&g_span_n) == 0, "重置会话之后索引是空的");
    CK(find_span(fake(1, 0), PG) == NULL, "重置会话之后是「没有」");
    add(0, 0, 4 * PG);
    CK(find_span(fake(1, 0), PG) != NULL, "重置之后重新登记，查得到");
}

// ---------- ④ 续：代际为奇数（有写者正在改表）不信索引 ----------
static void t_odd_epoch(void) {
    reset_world();
    add(0, 0, 4 * PG);
    range_t *r = find_span_scan(fake(0, 0), 1);
    CK(find_span(fake(1, 0), PG) == r, "前提：索引能答");
    atomic_fetch_add(&g_table_epoch, 1);   // 模拟写者开始改表（奇数）
    uint64_t h0 = idx_hits(), s0 = scans();
    for (int i = 0; i < 8; i++) CK(find_span(fake(1, 0), PG) == r, "奇数代际里答案照线性扫");
    CK(idx_hits() == h0 && scans() == s0 + 8, "奇数代际：不用索引，每次都真扫");
    atomic_store_explicit(&r->live, 0, memory_order_release);   // 写者在同一个奇数代际里继续改：范围被注销（索引里还留着它）
    for (int i = 0; i < 4; i++) CK(find_span(fake(1, 0), PG) == NULL, "奇数代际里表一变答案马上跟着变（不能拿索引里残留的条目答）");
    atomic_store_explicit(&r->live, 1, memory_order_release);
    atomic_fetch_add(&g_table_epoch, 1);   // 写者收工（偶数）
    uint64_t h1 = idx_hits(), s1 = scans();
    CK(find_span(fake(1, 0), PG) == r && idx_hits() == h1 + 1 && scans() == s1, "偶数代际回来：索引又答");
}

// ---------- ④ 续：查询中途有写者插进来 ----------
static int g_hook_step;
static void hook_remove_hit(void) { g_after_query = NULL; nvn_dirty_remove_range((const void *)fake(0, 0)); }
static void hook_add_lower(void) { g_after_query = NULL; nvn_dirty_add_range((const void *)fake(0, 0), 4 * PG); }
static void hook_replace_state(void) { g_after_query = NULL; g_hook_step++; nvn_dirty_replace_range((const void *)fake(0, 0), 4 * PG); }
static void t_mid_query_writer(void) {
    // 索引先答出「槽 0」，钩子在复查前把槽 0 注销：复查发现代际变了，丢掉旧答案，线性扫给出「没有」
    reset_world();
    add(0, 0, 4 * PG);
    uint64_t h0 = idx_hits(), s0 = scans();
    g_after_query = hook_remove_hit;
    range_t *got = find_span(fake(1, 0), PG);
    CK(g_after_query == NULL, "前提：钩子执行过");
    CK(got == NULL, "查询中途范围被注销：不能返回已注销的范围（索引算出的旧答案要丢）");
    CK(idx_hits() == h0 && scans() == s0 + 1, "复查不一致：退回线性扫，不计索引命中");
    // 索引先答出「槽 1」，钩子在复查前登记一个槽号更小（复用槽 0）的范围：复查发现代际变了，线性扫给出槽 0
    reset_world();
    add(0, 0, 4 * PG); add(0, 0, 4 * PG); del(0, 0);   // 槽 0 空着，槽 1 是 [0,4)
    CK(slot_of(find_span(fake(1, 0), PG)) == 1, "前提：只有槽 1 在");
    g_after_query = hook_add_lower;
    got = find_span(fake(1, 0), PG);
    CK(g_after_query == NULL && slot_of(got) == 0, "查询中途登记了槽号更小的范围：返回新表上的答案（槽 0）");
    // 钩子做原地换底（只改页状态、范围位置不变）：代际变了照样退回线性扫，答案不变
    reset_world();
    add(0, 0, 4 * PG);
    range_t *r = find_span_scan(fake(0, 0), 1);
    uint64_t s1 = scans();
    g_after_query = hook_replace_state;
    CK(find_span(fake(1, 0), PG) == r && g_hook_step == 1, "查询中途原地换底：答案不变");
    CK(scans() == s1 + 1, "原地换底推进了代际：这一问退回线性扫");
    g_after_query = NULL;
}

// ---------- ⑤ 上限：索引停用，一律线性扫 ----------
static uintptr_t big(uintptr_t i) { return (uintptr_t)0x40000000u + i * 4 * PG; }
static void t_cap(void) {
    reset_world();
    for (int i = 0; i < SPAN_IDX_MAX; i++) nvn_dirty_add_range((const void *)big((uintptr_t)i), 2 * PG);
    CK(atomic_load(&g_span_off) == 0 && atomic_load(&g_span_n) == SPAN_IDX_MAX, "登记到上限为止：索引还在、条数 = 上限");
    ck_index("登记到上限");
    uint64_t h0 = idx_hits();
    CK(find_span(big(5) + 8, 16) == find_span_scan(big(5) + 8, 16) && find_span(big(5) + 8, 16) != NULL && idx_hits() == h0 + 2, "上限之内：索引答，对得上");
    nvn_dirty_add_range((const void *)big(SPAN_IDX_MAX), 2 * PG);   // 第 SPAN_IDX_MAX + 1 个
    CK(atomic_load(&g_span_off) == 1, "超过上限：索引停用（不能越界写块）");
    unsigned mism = 0, found = 0; uint64_t s0 = scans(), h1 = idx_hits();
    for (int i = 0; i < 3000; i++) {
        uintptr_t a = big(rnd() % (SPAN_IDX_MAX + 4)) + rnd() % (3 * PG); size_t len = 1 + rnd() % PG;
        range_t *want = find_span_scan(a, len);
        if (find_span(a, len) != want) mism++;
        found += want != NULL;
    }
    CK(mism == 0 && found > 1000, "停用之后答案仍与线性扫一致（且问到的有「有」有「没有」）");
    CK(idx_hits() == h1 && scans() >= s0 + 3000, "停用之后一律线性扫，不再用索引");
    // 注销、再登记：索引仍然停用（它不再维护，不能再信）；答案仍对
    nvn_dirty_remove_range((const void *)big(7));
    CK(find_span(big(7) + 8, 16) == NULL, "停用之后注销的范围查不到");
    nvn_dirty_add_range((const void *)big(7), 2 * PG);
    CK(atomic_load(&g_span_off) == 1 && find_span(big(7) + 8, 16) != NULL, "停用之后重新登记：仍对，索引仍停用");
    // 重置会话后恢复
    reset_world();
    CK(atomic_load(&g_span_off) == 0 && atomic_load(&g_span_n) == 0, "重置会话：索引恢复、清空");
    add(0, 0, 4 * PG);
    uint64_t h2 = idx_hits();
    CK(find_span(fake(1, 0), PG) != NULL && idx_hits() == h2 + 1, "重置之后索引又答");
}

// ---------- ⑤ 续：索引要新块时分配失败：停用、线性扫，不崩、不给错答案 ----------
static void *test_span_calloc(void) { return g_fail_alloc ? NULL : calloc(SPAN_BLK, sizeof(span_ent)); }
static void t_alloc_fail(void) {
    reset_world();
    g_fail_alloc = 1; g_expect_off = 1;
    add(0, 0, 4 * PG);                   // 索引要第一个块：分配失败
    CK(atomic_load(&g_span_off) == 1, "分配失败：索引停用");
    range_t *r = find_span_scan(fake(1, 0), 1);
    CK(r != NULL && find_span(fake(1, 0), PG) == r, "分配失败之后查得到（线性扫），答案对");
    CK(find_span(fake(8, 0), PG) == NULL, "分配失败之后「没有」仍是「没有」");
    g_fail_alloc = 0;
    add(16, 0, 4 * PG);
    CK(atomic_load(&g_span_off) == 1 && slot_of(find_span(fake(17, 0), PG)) == 1, "分配恢复之后索引仍停用（它不再维护），新登记的范围查得到");
    reset_world(); g_expect_off = 0;
    CK(atomic_load(&g_span_off) == 0, "重置会话：索引恢复");
    add(0, 0, 4 * PG);
    uint64_t h0 = idx_hits();
    CK(find_span(fake(1, 0), PG) != NULL && idx_hits() == h0 + 1, "重置之后索引又答");
}

// ---------- ⑥ 随机增删，每步对照线性扫 ----------
enum { LIVE_MAX = 48, PAGES = 160 };
typedef struct { uintptr_t page, byte; size_t size; int live; uintptr_t base, end; } pool_t;
static void geom(pool_t *p) {
    const uintptr_t m = fake(p->page, p->byte);
    p->base = m & ~(PG - 1); p->end = (m + p->size + PG - 1) & ~(PG - 1);
}
static size_t rand_size(void) {   // 大小分三档：多数很小，少数中等，偶有大池（让嵌套与长跨度出现）
    unsigned t = rnd() % 20;
    if (t < 12) return PG / 2 + rnd() % (2 * PG);
    if (t < 17) return 3 * PG + rnd() % (10 * PG);
    return 20 * PG + rnd() % (60 * PG);
}
static void rand_query(const pool_t *pools, uintptr_t *a, size_t *len) {
    unsigned t = rnd() % 10;
    if (t < 5) {   // 贴着某个现存池的边界
        int i = (int)(rnd() % LIVE_MAX), tries = 0;
        while (!pools[i].live && tries++ < LIVE_MAX) i = (i + 1) % LIVE_MAX;
        if (pools[i].live) {
            const uintptr_t b = pools[i].base, e = pools[i].end; const size_t L = 1 + rnd() % (size_t)(e - b);
            switch (rnd() % 6) {
            case 0: *a = b; *len = 1 + rnd() % PG; return;
            case 1: *a = b - 1; *len = 1 + rnd() % 8; return;
            case 2: *a = e - 1; *len = 1; return;
            case 3: *a = e; *len = 1; return;
            case 4: *a = e - L; *len = L; return;
            default: *a = e - L + 1; *len = L; return;
            }
        }
    }
    if (t == 5) { *a = fake(rnd() % (PAGES + 8), rnd() % PG); *len = 0; return; }
    if (t == 6) { *a = fake(rnd() % PAGES, 0); *len = SIZE_MAX - rnd() % 4; return; }
    *a = fake(rnd() % (PAGES + 8), rnd() % PG); *len = 1 + rnd() % (3 * PG);
}
static void t_random(void) {
    reset_world();
    pool_t pools[LIVE_MAX]; memset(pools, 0, sizeof pools);
    unsigned mism = 0, ops = 0, queries = 0, nonnull = 0, nulls = 0;
    for (int step = 0; step < 5000; step++) {
        unsigned op = rnd() % 16;
        int i = (int)(rnd() % LIVE_MAX);
        if (op < 7) {                                  // 登记（含与别的范围共用页、嵌套的位置；起点不与现存的重复，免得注销时对不上号）
            if (!pools[i].live) {
                pool_t p = {rnd() % PAGES, (rnd() % 2) * (PG / 2), rand_size(), 1, 0, 0}; geom(&p);
                int dup = 0; for (int k = 0; k < LIVE_MAX; k++) if (pools[k].live && fake(pools[k].page, pools[k].byte) == fake(p.page, p.byte)) dup = 1;
                if (!dup) { pools[i] = p; add(p.page, p.byte, p.size); ops++; }
            }
        } else if (op < 12) {                          // 注销
            if (pools[i].live) { del(pools[i].page, pools[i].byte); pools[i].live = 0; ops++; }
        } else if (op < 13) {                          // 原地换底（同位置同长度：只改页状态，范围不动）
            if (pools[i].live) { nvn_dirty_replace_range((const void *)fake(pools[i].page, pools[i].byte), pools[i].size); ck_index("原地换底"); ops++; }
        }
        for (int q = 0; q < 16; q++) {
            uintptr_t a; size_t len; rand_query(pools, &a, &len);
            range_t *want = find_span_scan(a, len), *got = find_span(a, len);
            if (got != want) mism++;
            queries++; if (want) nonnull++; else nulls++;
        }
    }
    char msg[140]; snprintf(msg, sizeof msg, "随机增删 %u 次、共 %u 问：答案与线性扫不一致 %u 次", ops, queries, mism);
    CK(mism == 0, msg);
    CK(ops > 1500, "前提：随机序列里真的有足够多的表变动");
    CK(nonnull > queries / 10 && nulls > queries / 10, "前提：问到的答案「有」「没有」都足够多（否则错了也看不出）");
}

// ---------- ⑦ 并发：写者增删，读者读 ----------
// K 个永远在的范围（槽 0..K-1）；写者在比它们的起点都低的位置反复登记 / 注销 F（槽 K）：每次都让索引里所有永远在的条目整体挪一位并重算 sm。
// 读者一直读：永远在的范围必须每次都答对（读到挪动中途的半改状态必须被复查丢掉，不能漏），N 这个地址永远没有范围，F 要么没有、要么是它自己的槽。
// 主线程在写者收工之后发「请回报」，每个读者线程回报这一刻读到的 F。
enum { C_K = 600, C_READERS = 3 };
static _Atomic int c_stop, c_ack_req;
static _Atomic unsigned c_bad;
static range_t *c_p[C_K], *c_f;
static uintptr_t c_f_addr, c_n_addr;
static range_t *c_report[C_READERS];
static _Atomic int c_acked[C_READERS];
static uintptr_t cbase(int k) { return (uintptr_t)0x80000000u + (uintptr_t)(k + 4) * 8 * PG; }
static uintptr_t cf_mem(void) { return (uintptr_t)0x80000000u; }   // F：比所有永远在的范围起点都低
static void *c_writer(void *arg) {
    (void)arg;
    for (int i = 0; i < 20000; i++) { nvn_dirty_add_range((const void *)cf_mem(), 2 * PG); nvn_dirty_remove_range((const void *)cf_mem()); }   // 不用带检查的助手：计数器不是原子的
    return NULL;
}
static void *c_reader(void *arg) {
    int id = (int)(uintptr_t)arg, last = 0; uint32_t st = 777u + (uint32_t)id * 7919u;
    while (!atomic_load(&c_stop)) {
        st = st * 1664525u + 1013904223u; const int k = (int)((st >> 8) % C_K);
        range_t *p = find_span(cbase(k) + 16, 64), *n = find_span(c_n_addr, PG), *f = find_span(c_f_addr, PG);
        if (p != c_p[k]) atomic_fetch_add(&c_bad, 1);                 // 永远在的范围：答案恒定
        if (n != NULL) atomic_fetch_add(&c_bad, 1);                   // 永远没有范围的地址
        if (f != NULL && f != c_f) atomic_fetch_add(&c_bad, 1);       // F 要么没有、要么是 F 自己的槽，不能是别的
        int req = atomic_load(&c_ack_req);
        if (req != last) { last = req; c_report[id] = find_span(c_f_addr, PG); atomic_store(&c_acked[id], req); }
    }
    return NULL;
}
static int wait_acks(int req) {   // 等全部读线程回执，兜底 30 秒（原 5 秒：负载高时读线程轮不上核就假红）；等不到返回 0，调用处判红
    for (int t = 0; t < 30000; t++) {
        int all = 1; for (int i = 0; i < C_READERS; i++) if (atomic_load(&c_acked[i]) != req) all = 0;
        if (all) return 1;
        usleep(1000);
    }
    return 0;
}
static void t_concurrent(void) {
    reset_world();
    for (int k = 0; k < C_K; k++) nvn_dirty_add_range((const void *)cbase(k), 4 * PG);
    for (int k = 0; k < C_K; k++) c_p[k] = find_span_scan(cbase(k) + 16, 64);
    int pre_ok = 1; for (int k = 0; k < C_K; k++) if (slot_of(c_p[k]) != k) pre_ok = 0;
    CK(pre_ok, "前提：永远在的范围依次在槽 0..K-1");
    ck_index("并发用例登记完永远在的范围");
    c_f_addr = cf_mem() + 8; c_n_addr = (uintptr_t)0x70000000u;
    nvn_dirty_add_range((const void *)cf_mem(), 2 * PG); c_f = find_span_scan(c_f_addr, 1); nvn_dirty_remove_range((const void *)cf_mem());
    CK(slot_of(c_f) == C_K, "前提：F 范围每次都落在槽 K");
    atomic_store(&c_stop, 0); atomic_store(&c_ack_req, 0); atomic_store(&c_bad, 0);
    for (int i = 0; i < C_READERS; i++) { atomic_store(&c_acked[i], 0); c_report[i] = (range_t *)1; }
    pthread_t w, rd[C_READERS];
    for (int i = 0; i < C_READERS; i++) pthread_create(&rd[i], NULL, c_reader, (void *)(uintptr_t)i);
    pthread_create(&w, NULL, c_writer, NULL);
    pthread_join(w, NULL);                             // 写者收工：F 已注销
    atomic_store(&c_ack_req, 1);
    CK(wait_acks(1), "读者线程回报（F 已注销）");
    for (int i = 0; i < C_READERS; i++) CK(c_report[i] == NULL, "F 注销之后每个读者线程读到的必须是「没有」");
    nvn_dirty_add_range((const void *)cf_mem(), 2 * PG);   // F 重新登记
    atomic_store(&c_ack_req, 2);
    CK(wait_acks(2), "读者线程回报（F 已重新登记）");
    for (int i = 0; i < C_READERS; i++) CK(c_report[i] == c_f, "F 重新登记之后每个读者线程读到的必须是 F");
    nvn_dirty_remove_range((const void *)cf_mem());    // 再注销，换一个别的范围复用槽 K
    nvn_dirty_add_range((const void *)cbase(C_K + 10), 2 * PG);
    atomic_store(&c_ack_req, 3);
    CK(wait_acks(3), "读者线程回报（槽 K 被别处复用）");
    for (int i = 0; i < C_READERS; i++) CK(c_report[i] == NULL, "槽 K 被别处复用之后，F 的地址仍然是「没有」，不能拿到复用后的槽");
    atomic_store(&c_stop, 1);
    for (int i = 0; i < C_READERS; i++) pthread_join(rd[i], NULL);
    CK(atomic_load(&c_bad) == 0, "增删进行中读者读到过不该有的答案");
    ck_index("并发用例收工");
}

// ---------- 读数（不判红绿）：SPAN_BENCH=1 时打印线性扫与索引的单次查询耗时，给 PR 描述用 ----------
static uint64_t bench_ns(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec; }
static void bench(int npools) {
    reset_world();
    for (int i = 0; i < npools; i++) nvn_dirty_add_range((const void *)big((uintptr_t)i), 3 * PG);
    enum { Q = 200000 };
    uintptr_t *qa = malloc(Q * sizeof *qa); size_t *ql = malloc(Q * sizeof *ql);
    for (int i = 0; i < Q; i++) { qa[i] = big(rnd() % (uint32_t)npools) + rnd() % (2 * PG); ql[i] = 1 + rnd() % PG; }
    volatile uintptr_t sink = 0; uint64_t t0 = bench_ns();
    for (int i = 0; i < Q; i++) sink += (uintptr_t)find_span_scan(qa[i], ql[i]);
    uint64_t t1 = bench_ns(), h0, s0, n0, h1, s1, n1; nvn_dirty_span_stats(&h0, &s0, &n0);
    for (int i = 0; i < Q; i++) sink += (uintptr_t)find_span(qa[i], ql[i]);
    uint64_t t2 = bench_ns(); nvn_dirty_span_stats(&h1, &s1, &n1);
    printf("读数：现存 %d 个池，每次查询 线性扫 %.0f ns → 索引 %.0f ns（索引答 %llu 次、退回线性扫 %llu 次、平均 %.1f 个节点）\n", npools,
           (double)(t1 - t0) / Q, (double)(t2 - t1) / Q, (unsigned long long)(h1 - h0), (unsigned long long)(s1 - s0), h1 > h0 ? (double)(n1 - n0) / (double)(h1 - h0) : 0.0);
    (void)sink; free(qa); free(ql);
}

// 写者读数：只计索引本身的增删（直接调 span_insert / span_remove，不含 add_range 里的 mprotect 与页状态数组）
static void bench_writer(int npools) {
    reset_world();
    uint32_t *perm = malloc((size_t)npools * sizeof *perm);
    for (int i = 0; i < npools; i++) perm[i] = (uint32_t)i;
    for (int i = npools - 1; i > 0; i--) { const int j = (int)(rnd() % (uint32_t)(i + 1)); const uint32_t x = perm[i]; perm[i] = perm[j]; perm[j] = x; }
    const uint64_t t0 = bench_ns();
    for (int i = 0; i < npools; i++) span_insert(big(perm[i]), big(perm[i]) + 3 * PG, (uint32_t)i);   // 随机地址顺序登记，平均每次挪 N/2 条
    const uint64_t t1 = bench_ns();
    enum { OPS = 2000 };
    for (int k = 0; k < OPS; k++) { const int i = (int)(rnd() % (uint32_t)npools); span_remove(big(perm[i]), (uint32_t)i); span_insert(big(perm[i]), big(perm[i]) + 3 * PG, (uint32_t)i); }
    const uint64_t t2 = bench_ns();
    printf("读数：写者 随机地址顺序登记 %d 个池共 %.2f ms（平均每次 %.1f µs）；表里已有 %d 个池时一次「注销 + 登记」%.1f µs（只算索引，不含 add_range 里的 mprotect）\n",
           npools, (double)(t1 - t0) / 1e6, (double)(t1 - t0) / 1e3 / npools, npools, (double)(t2 - t1) / 1e3 / OPS);
    free(perm);
}
int main(void) {
    PG = (uintptr_t)getpagesize();
    void *arena = mmap(NULL, (size_t)ARENA_PAGES * PG, PROT_READ | PROT_WRITE, MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
    if (arena == MAP_FAILED) { perror("mmap"); return 2; }
    ARENA = (uintptr_t)arena;
    t_basic();
    t_overlap();
    t_invalidate();
    t_odd_epoch();
    t_mid_query_writer();
    t_cap();
    t_alloc_fail();
    t_random();
    t_concurrent();
    if (getenv("SPAN_BENCH")) { bench(100); bench(1000); bench(3000); bench_writer(100); bench_writer(1000); bench_writer(3000); }
    printf("%s t_dirty_span_index: %u checks, %u failures\n", failures ? "✗" : "✓", checks, failures);
    return failures ? 1 : 0;
}
