// t_nvn_tensor_widen：张量核网络顶替在满屏放宽下挑不出输入时，几时退回原生 16:9（tensor_widen.h，#726）。期望按规则手写：
//   ① 没放宽（16:9）：挑不出多少次都不退；② 放宽：同一帧挑不出 100 次只算 1 帧，不退；③ 放宽：第 8 个不同的帧回 1，之后不再回（一局一次）；
//   ④ 第 0 帧也算一帧（frame = 0 时不漏数）
#include "../gfx/nvn/tensor_widen.h"
#include <stdio.h>
static int bad;
static void ck(int ok, const char *m) { printf("%s %s\n", ok ? "✓" : "✗", m); if (!ok) bad++; }
int main(void) {
    s2a_tensor_widen_t s = {0}; int any = 0;
    for (uint64_t f = 0; f < 50; f++) any |= s2a_tensor_widen_revert_due(&s, f, 0);
    ck(!any && !s.frames, "① 没放宽：50 帧都挑不出也不退回、不计数");
    s = (s2a_tensor_widen_t){0}; any = 0;
    for (int i = 0; i < 100; i++) any |= s2a_tensor_widen_revert_due(&s, 7, 1);
    ck(!any && s.frames == 1, "② 放宽：同一帧挑不出 100 次只算 1 帧，不退回");
    s = (s2a_tensor_widen_t){0}; int at = -1, again = 0;
    for (uint64_t f = 0; f < 20; f++) { int r = s2a_tensor_widen_revert_due(&s, f, 1); if (r && at < 0) at = (int)f; else if (r) again = 1; }
    ck(at == 7, "③ 放宽：第 8 个不同的帧（帧 0–7）回 1");
    ck(!again, "③ 回过一次之后不再回（一局只退一次）");
    s = (s2a_tensor_widen_t){0}; s2a_tensor_widen_revert_due(&s, 0, 1);
    ck(s.frames == 1, "④ 帧号 0 也计一帧");
    printf("%s t_nvn_tensor_widen：%d 处不符\n", bad ? "✗" : "✓", bad);
    return bad != 0;
}
