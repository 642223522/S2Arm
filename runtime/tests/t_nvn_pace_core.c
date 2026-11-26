// D7 第七片：nvn_pace.h 的上屏节拍器是纯函数（只依赖 stdint），能在 Linux 上单独编译验证。
// 期望值按「按 vsync 排槽」语义手算：period=0 不等；首帧取当前时间；早到等到槽；晚到不足一拍
// 立即出图并保留原相位；晚到 ≥ 一拍从当前时间重新起拍，不补发。
#include "nvn_pace.h"
#include <stdio.h>

static int fails, checks;

static void eq_u64(const char *what, uint64_t got, uint64_t want) {
    checks++;
    if (got != want) { fails++; printf("FAIL %s：实为 %llu，期望 %llu\n", what, (unsigned long long)got, (unsigned long long)want); }
}

static void eq_pacer(const char *what, const nvn_pacer *p, uint64_t want) {
    eq_u64(what, p->target, want);
}

int main(void) {
    const uint64_t P = 100;

    // period = 0：不等，槽跟当前时间
    nvn_pacer z = {0};
    eq_u64("period 0 不等", nvn_pace(&z, 1000, 0), 0);
    eq_pacer("period 0 槽", &z, 1000);

    // 首帧：没有相位，立即出图并记下当前时间
    nvn_pacer p = {0};
    eq_u64("首帧不等", nvn_pace(&p, 1000, P), 0);
    eq_pacer("首帧槽", &p, 1000);

    // 下一帧早到 90ns：等到槽（1100），相位保留
    eq_u64("早到等待", nvn_pace(&p, 1010, P), 90);
    eq_pacer("早到槽", &p, 1100);

    // 正好踩槽：不等
    eq_u64("正点不等", nvn_pace(&p, 1100, P), 100);

    // 槽已推进到 1200；1250 早到下一槽 1300 的前 50
    eq_u64("再早到", nvn_pace(&p, 1250, P), 50);
    eq_pacer("再早到槽", &p, 1300);

    // 晚到 50（1450 vs 槽 1400，不足一拍）→ 立即出图、保留相位 1400
    eq_u64("晚到不足一拍", nvn_pace(&p, 1450, P), 0);
    eq_pacer("晚到不足一拍槽", &p, 1400);

    // 晚到 ≥ 一拍（1600 vs 槽 1500）：从当前时间重新起拍
    eq_u64("晚到一拍不等", nvn_pace(&p, 1600, P), 0);
    eq_pacer("晚到一拍槽", &p, 1600);

    // 重新起拍后早到 40：等到 1700
    eq_u64("重启后早到", nvn_pace(&p, 1660, P), 40);
    eq_pacer("重启后槽", &p, 1700);

    // ---- 取图 / 上屏循环重放（hle_nvn.c）：取图等到这张图的槽时间 avail[i]（节拍器控节奏时），这一帧干 work，上屏排槽
    //   （nvn_pace，或显示链路控了节奏的帧 nvn_pace_follow），这张图在槽后一个周期再可取。期望手算：周期 PP = 1/60 s
    const uint64_t PP = 16666667ull, MS = 1000000ull;
    // ① 真等节拍器的调用方、每帧 1 ms 活：交换链 2 / 3 / 4 张图都是 60 帧（三四张时槽领先上屏两三个周期，不能截断）
    for (int ntex = 2; ntex <= 4; ntex++) {
        nvn_pacer q = {0}; uint64_t avail[4] = {0}, t = 1000 * MS, t100 = 0;
        for (int k = 0; k < 1100; k++) { if (k == 100) t100 = t; if (avail[k % ntex] > t) t = avail[k % ntex]; t += MS; avail[k % ntex] = t + nvn_pace(&q, t, PP) + PP; }
        double fps = 1000.0 / ((t - t100) / 1e9); checks++;
        if (!(fps > 59.9 && fps < 60.1)) { fails++; printf("FAIL %d 张图、节拍器控节奏：%.2f fps，期望 60\n", ntex, fps); }
    }
    // ② 显示链路控 18,000 帧（12.5 ms 一帧，120 Hz 可变刷新率链路）后沉默、节拍器接手：第一次等待 ≤ 一个周期，之后 16.667 ms 一帧
    //   （每帧照旧走一个周期时，槽领先真实时间 75 s，兜底一次睡完）
    for (int ntex = 2; ntex <= 3; ntex++) {
        nvn_pacer q = {0}; uint64_t avail[4] = {0}, t = 5000 * MS, worst = 0, t0 = 0; int k;
        for (k = 0; k < 18000; k++) { t += 12500000ull; nvn_pace_follow(&q, t); avail[k % ntex] = t + PP; }
        for (; k < 18000 + 600; k++) {
            uint64_t w = avail[k % ntex] > t ? avail[k % ntex] - t : 0; if (w > worst) worst = w;
            t += w + MS; if (k == 18100) t0 = t;
            avail[k % ntex] = t + nvn_pace(&q, t, PP) + PP;
        }
        double per = (t - t0) / 499.0 / 1e6; checks++;
        if (!(worst <= PP && per > 16.66 && per < 16.67)) { fails++; printf("FAIL %d 张图、链路控 18000 帧后沉默：最长等待 %.3f ms（期望 ≤ %.3f），之后 %.3f ms 一帧（期望 16.667）\n", ntex, worst / 1e6, PP / 1e6, per); }
    }
    // ③ 链路控 / 沉默来回三次（三张图）：每次等待都 ≤ 一个周期
    { nvn_pacer q = {0}; uint64_t avail[3] = {0}, t = 5000 * MS, worst = 0; int k = 0;
      for (int phase = 0; phase < 6; phase++)
          for (int j = 0; j < 300; j++, k++) {
              if (phase % 2 == 0) { t += 12500000ull; nvn_pace_follow(&q, t); avail[k % 3] = t + PP; continue; }
              uint64_t w = avail[k % 3] > t ? avail[k % 3] - t : 0; if (w > worst) worst = w;
              t += w + 4 * MS; avail[k % 3] = t + nvn_pace(&q, t, PP) + PP;
          }
      checks++;
      if (!(worst <= PP)) { fails++; printf("FAIL 链路控 / 沉默来回三次：最长等待 %.3f ms，期望 ≤ %.3f\n", worst / 1e6, PP / 1e6); } }

    if (fails) printf("✗ t_nvn_pace_core：%d / %d 项不符\n", fails, checks);
    else printf("✓ t_nvn_pace_core：上屏节拍 %d 项全过（0 处不符）\n", checks);
    return fails ? 1 : 0;
}
