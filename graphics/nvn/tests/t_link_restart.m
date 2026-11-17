// 进程内重启（设置页「立刻重启」，切 60 帧走这条路）后的逐局状态复位（满屏补丁线 11-04；含生产 nvn_mtl.m 源码，同 t_nvn_shader_flight.m 写法）。
// 期望按语义手推，不跑被测实现推：
//   ① 上一局显示链接走到第 5124 拍、上一帧在第 5124 拍开工；重启后拍号从 0 重数、走到第 1 拍 → 已过 1 拍（step 1），等拍立即返回 1（< 5 ms）。
//      负对照：旧代码「上一帧开工拍号」留着 5124，要等到第 5125 拍 → 等满 50 ms 超时返回 0（重启后每帧都这样 = 锁 30 帧）
//   ② 深度约定计数：上一局建过 19 个顶点着色器、深度模式 1；重启后两者都回 0（NVN 缺省），新局设 0 不翻转、游戏设 1 时计数 0 → 不报「depth mode changed after」红行
#ifndef LINK_RESTART_SOURCE
#define LINK_RESTART_SOURCE "../gfx/nvn/nvn_mtl.m"
#endif
#include LINK_RESTART_SOURCE

static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr,"SETUP FAIL %s:%d %s\n",__FILE__,__LINE__,#c); exit(2); } } while(0)
#define CHECK(c, ...) do { checks++; int ok=!!(c); failures+=!ok; printf("%s ",ok?"PASS":"FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while(0)
static double ms_now(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6; }

int main(void) { @autoreleasepool {
    setenv("DM_PSO_MANIFEST","off",1); setenv("DM_PSO_ARCHIVE","0",1);
    mtl_init();
    // 显示链接对象本身不碰（等拍函数只读拍号与锁）：放一个占位对象让 link_on() 为真
    g_dm_present_link = 1; g_link = (CAMetalDisplayLink *)[NSObject new]; g_link_mode = 1;
    pthread_mutex_lock(&g_link_mu); g_link_tick_n = 5124; pthread_mutex_unlock(&g_link_mu);
    REQUIRE(nvn_be_link_wait_tick(1, 50000000ull) == 1);   // 上一局：这一帧在第 5124 拍开工
    atomic_store(&g_vs_loaded, 19); atomic_store(&g_depth_zero, 1);
    REQUIRE(!nvn_be_request_stop()); REQUIRE(!nvn_be_shutdown_session()); nvn_be_begin_session();
    pthread_mutex_lock(&g_link_mu); CHECK(g_link_tick_n == 0, "重启后显示链接拍号从 0 起（实为 %llu）", (unsigned long long)g_link_tick_n); g_link_tick_n = 1; pthread_mutex_unlock(&g_link_mu);
    double t0 = ms_now(); int r = nvn_be_link_wait_tick(1, 50000000ull); double dt = ms_now() - t0;
    CHECK(r == 1 && dt < 5, "① 重启后已过 1 拍：等拍立即返回（返回 %d、等 %.1f ms；旧代码等满 50 ms 返回 0 = 锁 30 帧）", r, dt);
    CHECK(atomic_load(&g_vs_loaded) == 0 && atomic_load(&g_depth_zero) == 0, "② 重启后深度约定计数清零（顶点着色器 %d、深度模式 %d）", atomic_load(&g_vs_loaded), atomic_load(&g_depth_zero));
    g_link = nil; g_dm_present_link = 0;
    // ③ 每局开头的出图方式（11-15 #ee56e7 / #1155 另一条入口）：期望手写——补帧开、没给 DM_PRESENT_LINK → 0（出图线程自己取画布，不起显示链）；
    //   补帧开、DM_PRESENT_LINK=2（120 档帧率补丁）→ 2；补帧关 → 1（缺省 60 Hz 显示链）。旧实现每局开头只看 DM_PRESENT_LINK：第一项得 1（红）
    //   ③b 走 Metal 3 的机器（g_m3）补帧开 → 1：Metal 3 不补帧，显示链照建（审计 P1-188；旧实现不看后端得 0，那一局既没补帧也没显示链，红）
    { struct { const char *fi, *link; int want, m3; } c[] = {{"1", NULL, 0, 0}, {"1", "2", 2, 0}, {NULL, NULL, 1, 0}, {"1", NULL, 1, 1}};
      int m3_was = g_m3;
      for (int i = 0; i < 4; i++) {
          g_m3 = c[i].m3;
          if (c[i].fi) setenv("DM_PRESENT_FI", c[i].fi, 1); else unsetenv("DM_PRESENT_FI");
          if (c[i].link) setenv("DM_PRESENT_LINK", c[i].link, 1); else unsetenv("DM_PRESENT_LINK");
          nvn_be_request_stop(); nvn_be_shutdown_session(); nvn_be_begin_session();
          CHECK(g_dm_present_link == c[i].want, "③ 每局开头（Metal %d）：DM_PRESENT_FI=%s、DM_PRESENT_LINK=%s → 出图方式 %d（期望 %d）", c[i].m3 ? 3 : 4, c[i].fi ? c[i].fi : "未设", c[i].link ? c[i].link : "未设", g_dm_present_link, c[i].want);
      }
      g_m3 = m3_was; unsetenv("DM_PRESENT_FI"); unsetenv("DM_PRESENT_LINK"); }
    printf("%s t_link_restart：%u 项，不过 %u\n", failures ? "✗" : "✓", checks, failures);
    return failures ? 1 : 0;
}}
