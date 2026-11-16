// 放不下标准布局时窗口下方留给宿主多少（vawin.c s2a_window_host_below，#783）与学到的跨度记录（s2a_window_span_seen）。
// 背景：iPad Pro M2 iPadOS 27.2.1，2^39 以下最大一块 64 GB 放不下这款 76 GB 标准布局，原先固定只给宿主 3 GiB，宿主低区开局 3.4 GB，
//   命令录制等宿主映射涨满后 mmap ENOMEM 闪退；那款整局只碰到 16395 MB 的跨度。
// 期望按规则手写（窗口 = 学到的跨度 × 1.25 + 2 GiB、1 GiB 向上取整；宿主 = 空洞 − 窗口、1 GiB 向下取整，至少 3 GiB；没学到 = 3 GiB）：
//   ① 没学到：3 GiB    ② 学到 16395 MB、空洞 64 GiB：窗口 ⌈22541.75 MB⌉ = 23 GiB → 宿主 41 GiB，且宿主 + 学到的跨度 ≤ 空洞
//   ③ 学到的比空洞还大：3 GiB    ④ 学到 100 MB：窗口 ⌈2173 MB⌉ = 3 GiB → 宿主 61 GiB    ⑤ 记录文件：有 → 读出、没有 / 读不出 → 0
//   ⑨ 低区碰底死的局（#1143，11-15 iPhone 读数：最大空洞 6 MB、本局跨度 13649 MB、原记录没有 / 2138 MB）：最大空洞 < 64 MB 才记、比原记录大才写；
//      记下 13649 MB 后空洞 64 GiB：窗口 ⌈13649 × 1.25 + 2048 = 19109.25 MB⌉ = 19 GiB → 宿主 45 GiB
#include "../src/native.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
__attribute__((constructor(100))) static void need(void) { setenv("S2A_VAWIN_NORESERVE", "1", 1); }   // 先于 vawin.c 的构造函数（101）：不占窗口
static int bad;
#define CHECK(c, ...) do { if (c) { printf("✓ "); } else { printf("✗ "); bad++; } printf(__VA_ARGS__); putchar('\n'); } while (0)
#define MB (1ull << 20)
#define GB (1ull << 30)
static uint64_t g_test_span;
__attribute__((used, visibility("default"))) uint64_t s2a_mem_span_now(void) { return g_test_span; }   // vawin.c 按名字取（dlsym），这里冒充 svc_mem.c
int main(void) {
    CHECK(s2a_window_host_below(64 * GB, 0) == 3 * GB, "① 没学到跨度：宿主照旧 3 GiB");
    uint64_t h = s2a_window_host_below(64 * GB, 16395 * MB);
    CHECK(h == 41 * GB && h + 16395 * MB <= 64 * GB, "② 学到 16395 MB、空洞 64 GiB：宿主 41 GiB（实得 %llu MB），宿主 + 跨度不超空洞", (unsigned long long)(h / MB));
    CHECK(s2a_window_host_below(64 * GB, 70 * GB) == 3 * GB, "③ 学到的跨度比空洞还大：宿主至少 3 GiB");
    CHECK(s2a_window_host_below(64 * GB, 100 * MB) == 61 * GB, "④ 学到 100 MB：窗口 3 GiB、宿主 61 GiB");
    char p[] = "/tmp/s2a_span_peak_XXXXXX"; int fd = mkstemp(p); dprintf(fd, "17191403520\n"); close(fd);
    setenv("S2A_WIN_SPAN_PEAK", p, 1);
    CHECK(s2a_window_span_seen(0x0400486024DEC000ull) == 17191403520ull, "⑤ 记录文件有值：读出 17191403520");
    FILE *f = fopen(p, "w"); fputs("坏\n", f); fclose(f);
    CHECK(s2a_window_span_seen(0x0400486024DEC000ull) == 0, "⑤ 记录读不出：0（照旧 3 GiB）");
    unlink(p);
    CHECK(s2a_window_span_seen(0x0400486024DEC000ull) == 0, "⑤ 没有记录：0");
    // ⑥ 只记真跑起来的局（11-12 iPhone 实机：一局刚开就死只碰到 2.26 GB，记下后下一局窗口缩到 5 GB 起不来、且锁死）：出图满 300 次才记
    extern int s2a_window_span_worth(uint64_t presents);
    CHECK(!s2a_window_span_worth(0) && !s2a_window_span_worth(299) && s2a_window_span_worth(300), "⑥ 出图 0 / 299 次不记、300 次起记");
    // ⑦ 自愈：没按学到的跨度收窄（本进程 g_span_learned = 0）时调 forget 不动别人的记录
    { extern void s2a_window_span_forget(void); char q[] = "/tmp/s2a_span_keep_XXXXXX"; int qd = mkstemp(q); dprintf(qd, "123\n"); close(qd);
      setenv("S2A_WIN_SPAN_PEAK", q, 1); s2a_window_span_forget(); CHECK(access(q, F_OK) == 0, "⑦ 没收窄过：forget 不删记录"); unlink(q); }
    // ⑧ 当场放宽的新起点（s2a_window_widen_lo，手算）：留宿主底 0x70_0000_0000、窗口底 0x7B_0000_0000（下方留了 44 GiB）
    //   下方没别人：0x70_C000_0000（底 + 3 GiB）；已占到 0x75_0000_1000：向上取整 0x75_4000_0000；已占到窗口底：0（放不宽）
    { extern uint64_t s2a_window_widen_lo(uint64_t, uint64_t, uint64_t); const uint64_t K = 0x7000000000ull, B = 0x7B00000000ull;
      CHECK(s2a_window_widen_lo(K, B, K) == 0x70C0000000ull, "⑧ 下方空着：新起点 = 留宿主底 + 3 GiB");
      CHECK(s2a_window_widen_lo(K, B, 0x7500001000ull) == 0x7540000000ull, "⑧ 下方已占到 0x7500001000：新起点取整到 0x7540000000、不盖");
      CHECK(s2a_window_widen_lo(K, B, B) == 0, "⑧ 下方占满到窗口底：放不宽（0）"); }
    {   // ⑨ 低区碰底死的局记跨度（s2a_window_span_arm / s2a_window_span_crash）
        extern int s2a_window_span_crash_worth(uint64_t); extern void s2a_window_span_arm(void); extern uint64_t s2a_window_span_crash(uint64_t);
        CHECK(s2a_window_span_crash_worth(6 * MB) && s2a_window_span_crash_worth(64 * MB - 1) && !s2a_window_span_crash_worth(64 * MB) && !s2a_window_span_crash_worth(512 * MB),
              "⑨ 最大空洞 6 MB / 64 MB−1 字节算碰底，64 MB / 512 MB 不算");
        char q[] = "/tmp/s2a_span_crash_XXXXXX"; int qd = mkstemp(q); close(qd); unlink(q);   // 先没有记录
        setenv("S2A_WIN_SPAN_PEAK", q, 1);
        g_test_span = 13649 * MB;
        CHECK(s2a_window_span_crash(6 * MB) == 0, "⑨ 没备好（C# 初始化前崩）：不记");
        s2a_window_span_arm();
        CHECK(s2a_window_span_crash(512 * MB) == 0 && access(q, F_OK) != 0, "⑨ 低区没碰底（最大空洞 512 MB）：不记、不建文件");
        CHECK(s2a_window_span_crash(6 * MB) == 13649 * MB && s2a_window_span_seen(1) == 13649 * MB, "⑨ 没有记录、碰底：记下 13649 MB 并读得回");
        FILE *f = fopen(q, "w"); fprintf(f, "%llu\n", (unsigned long long)(2138 * MB)); fclose(f);
        CHECK(s2a_window_span_crash(6 * MB) == 13649 * MB && s2a_window_span_seen(1) == 13649 * MB, "⑨ 原记录 2138 MB 更小：改写成 13649 MB");
        g_test_span = 2138 * MB;
        CHECK(s2a_window_span_crash(6 * MB) == 0 && s2a_window_span_seen(1) == 13649 * MB, "⑨ 本局 2138 MB 不比记录大：不动");
        CHECK(s2a_window_host_below(64 * GB, s2a_window_span_seen(1)) == 45 * GB, "⑨ 下一局空洞 64 GiB：宿主 45 GiB（原先 3 GiB）");
        unlink(q); char t[64]; snprintf(t, sizeof t, "%s.tmp", q); CHECK(access(t, F_OK) != 0, "⑨ 不留临时文件"); }
    {   // ⑩ 旧记录不小于空洞（旧版把窗口外远端映射算进跨度，某机记成 73086 MB、空洞 49152 MB）：当作没有、允许覆盖；空洞未知（0）不判
        extern int s2a_window_span_rec_ok(uint64_t, uint64_t);
        CHECK(!s2a_window_span_rec_ok(73086 * MB, 49152 * MB) && !s2a_window_span_rec_ok(76030 * MB, 65536 * MB), "⑩ 记录 ≥ 空洞：不算数");
        CHECK(s2a_window_span_rec_ok(16408 * MB, 49152 * MB) && !s2a_window_span_rec_ok(0, 49152 * MB) && s2a_window_span_rec_ok(73086 * MB, 0), "⑩ 空洞内的算数、0 不算、空洞未知不判"); }
    printf("%s t_vawin_learned：%d 处不符\n", bad ? "✗" : "✓", bad);
    return bad ? 1 : 0;
}
