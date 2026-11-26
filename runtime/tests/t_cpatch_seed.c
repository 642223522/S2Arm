// 随包金手指要不要放进文档根 cheats/（runtime/src/cpatch.c s2a_cheat_seed_action，#1517「删不掉」）。期望按规则手写：
//   ① 新的（.packed / .deleted 都没有，文件不在）→ 0 放；② 上次随包放过、文件还在 → 0 放（内容变了才换新）；
//   ③ 文件在、不是随包放的（玩家自己的同名文件）→ 1 不放；④ 上次随包放过、现在文件不在 = 玩家在「文件」里删了 → 3 不放并记下；
//   ⑤ 记在 .deleted 里的 → 2 不放（不管文件在不在）；⑥ 名字只按整行比（a.txt 不误中 aa.txt）
#include <stdio.h>
int s2a_cheat_seed_action(const char *packed, const char *deleted, const char *name, int exists);
static int fails;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("✗ "); printf(__VA_ARGS__); printf("\n"); } } while (0)
int main(void) {
    CHECK(s2a_cheat_seed_action("", "", "a.txt", 0) == 0, "① 新的应放");
    CHECK(s2a_cheat_seed_action("a.txt\n", "", "a.txt", 1) == 0, "② 上次随包放过、还在应放（换新）");
    CHECK(s2a_cheat_seed_action("", "", "a.txt", 1) == 1, "③ 玩家自己的同名文件不碰");
    CHECK(s2a_cheat_seed_action("a.txt\nb.txt\n", "", "b.txt", 0) == 3, "④ 随包放过、现在没了 = 玩家删了");
    CHECK(s2a_cheat_seed_action("", "b.txt\n", "b.txt", 0) == 2 && s2a_cheat_seed_action("b.txt\n", "b.txt\n", "b.txt", 1) == 2, "⑤ 删过的不再放");
    CHECK(s2a_cheat_seed_action("aa.txt\n", "aa.txt\n", "a.txt", 0) == 0, "⑥ 按整行比，a.txt 不误中 aa.txt");
    printf("%s t_cpatch_seed：%d 处不符\n", fails ? "✗" : "✓", fails);
    return fails != 0;
}
