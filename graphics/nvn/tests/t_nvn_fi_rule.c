// 出图补帧逐帧判定（graphics/nvn/gfx/nvn/nvn_fi_rule.h）。期望按规则手写（维护者 11-13：只给按 30 帧档或更低档推进、并且跑满的帧补；60 帧档一律不补）：
#include <stdio.h>
#include "../gfx/nvn/nvn_fi_rule.h"
int main(void) {
    static const struct { const char *name; double period, gap; int want; } c[] = {
        {"30 帧档跑满（间隔 33.3 ms）→ 补", 1.0 / 30, 1.0 / 30, 1},
        {"30 帧档略有抖动（36 ms，在 1.25 倍内）→ 补", 1.0 / 30, 0.036, 1},
        {"30 帧档跑不满（50 ms）→ 不补", 1.0 / 30, 0.050, 0},
        {"20 帧档跑满（50 ms）→ 补", 1.0 / 20, 0.050, 1},
        {"60 帧档跑不满（实际 33 ms，掉到 30 帧）→ 不补", 1.0 / 60, 1.0 / 30, 0},
        {"60 帧档跑不满（实际 25 ms，40 帧）→ 不补", 1.0 / 60, 0.025, 0},
        {"60 帧档跑满（16.7 ms）→ 不补", 1.0 / 60, 1.0 / 60, 0},
        {"第一帧（没有上一帧）→ 不补", 1.0 / 30, 0, 0},
    };
    int bad = 0, n = (int)(sizeof c / sizeof *c);
    for (int i = 0; i < n; i++) {
        int got = dm_fi_should_interp(c[i].period, c[i].gap);
        printf("%s %s：期望 %d → 真结果 %d\n", got == c[i].want ? "PASS" : "FAIL", c[i].name, c[i].want, got); bad += got != c[i].want;
    }
    if (bad) { printf("✗ t_nvn_fi_rule：%d 项里 %d 项不符\n", n, bad); return 1; }
    printf("✓ t_nvn_fi_rule：%d 项全过\n", n); return 0;
}
