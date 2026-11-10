// iOS 存档页状态（ios/save_gate.h）单测：期望按审计 P0-1 的要求手推，不跑被测实现得出
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "save_gate.h"
static int fails;
#define CK(c, what) do { if (c) printf("过 %s\n", what); else { printf("红 %s\n", what); fails++; } } while (0)
// 截出 save_transfer.m 里某个确认动作的处理块（从动作文案键到下一个 addAction / 函数尾），看里面写不写「下次先进存档管理」开关
static char *block(const char *src, const char *key) {
    const char *a = strstr(src, key); if (!a) return NULL;
    const char *b = strstr(a + 1, "addAction:"), *e = strstr(a + 1, "presentViewController:alert");
    if (!b || (e && e < b)) b = e; if (!b) return NULL;
    size_t n = (size_t)(b - a); char *out = malloc(n + 1); memcpy(out, a, n); out[n] = 0; return out;
}
static int main_gate(void);
int main(int argc, char **argv) {
    int rc = main_gate();
    // ⑥ 游戏内「存档管理」退出确认：「退出游戏」只退出、不置开关；「退出并管理存档」才置，且只记这一款（多款容器按游戏号）。
    //   旧确认框只有「已保存，退出游戏」且必置 App 级开关：玩家拿它当退出，之后每次打开都先进存档页（11-10 玩家反馈）
    if (argc > 1) {
        FILE *f = fopen(argv[1], "rb"); char *src = NULL; long len = 0;
        if (f && !fseek(f, 0, SEEK_END) && (len = ftell(f)) > 0 && !fseek(f, 0, SEEK_SET) && (src = malloc((size_t)len + 1)) && fread(src, 1, (size_t)len, f) == (size_t)len) src[len] = 0; else { free(src); src = NULL; }
        if (f) fclose(f);
        CK(src != NULL, "读到 ios/save_transfer.m");
        if (src) {
            char *only = block(src, "S2AL(@\"save.quit.only\")"), *manage = block(src, "S2AL(@\"save.quit.manage\")");
            CK(only && strstr(only, "s2a_host_shutdown") && !strstr(only, "setBool:YES"), "「退出游戏」只收尾退出，不置下次进存档管理");
            CK(manage && strstr(manage, "setBool:YES forKey:game_manage_key()"), "「退出并管理存档」置这一款的开关");
            CK(!strstr(src, "setBool:YES forKey:ManageKey"), "游戏内不再置 App 级开关（那是 iOS 设置 / 主屏快捷操作的）");
            CK(strstr(src, "boolForKey:game_manage_key()") && strstr(src, "setBool:NO forKey:game_manage_key()"), "开局判定读这一款的开关、开始游戏后复位");
            free(only); free(manage); free(src);
        }
        if (fails) rc = 1;
    }
    return rc;
}
static int main_gate(void) {
    struct s2a_save_buttons b; enum s2a_save_phase p;
    // ① 无事务：打开即可开始、导入；有存档才可导出；没有「仍要开始」
    p = s2a_save_next(S2A_SAVE_CHECKING, S2A_SAVE_EV_OPEN_NO_TX); b = s2a_save_buttons(p, 0, 1, 1, 0);
    CK(b.start && b.import && b.export_ && !b.override, "无事务：开始 / 导入 / 导出可点，无仍要开始");
    b = s2a_save_buttons(p, 0, 1, 0, 0); CK(b.start && !b.export_, "无事务无存档：可开始、不可导出");
    b = s2a_save_buttons(p, 0, 1, 1, 1); CK(!b.start && !b.import, "处理中：全灰");
    // ② 有事务、恢复成功：恢复中全灰，成功后放开
    p = s2a_save_next(S2A_SAVE_CHECKING, S2A_SAVE_EV_OPEN_TX); b = s2a_save_buttons(p, 0, 1, 1, 0);
    CK(!b.start && !b.import && !b.override, "恢复中：开始 / 导入灰，无仍要开始");
    p = s2a_save_next(p, S2A_SAVE_EV_RECOVER_OK); b = s2a_save_buttons(p, 0, 1, 1, 0);
    CK(b.start && b.export_ && !b.override, "恢复成功：开始 / 导出可点");
    // ③ 有事务、恢复失败：不能直接开始，但给「仍要开始」；确认后开始可点（旧逻辑停在恢复中，这两条红）
    p = s2a_save_next(s2a_save_next(S2A_SAVE_CHECKING, S2A_SAVE_EV_OPEN_TX), S2A_SAVE_EV_RECOVER_FAIL); b = s2a_save_buttons(p, 0, 1, 1, 0);
    CK(!b.start && b.override, "恢复失败：开始灰、出现仍要开始");
    b = s2a_save_buttons(p, 1, 1, 1, 0); CK(b.start && b.export_ && !b.override, "恢复失败后确认仍要开始：开始 / 导出可点");
    // ④ 缺存档服务：有事务 → 同恢复失败；没事务 → 照常开始、不能导入导出
    p = s2a_save_next(s2a_save_next(S2A_SAVE_CHECKING, S2A_SAVE_EV_OPEN_TX), S2A_SAVE_EV_NO_SERVICE); b = s2a_save_buttons(p, 0, 0, 1, 0);
    CK(!b.start && b.override, "缺服务有事务：开始灰、出现仍要开始");
    b = s2a_save_buttons(p, 1, 0, 1, 0); CK(b.start && !b.import && !b.export_, "缺服务有事务确认后：可开始、不可导入导出");
    p = s2a_save_next(s2a_save_next(S2A_SAVE_CHECKING, S2A_SAVE_EV_OPEN_NO_TX), S2A_SAVE_EV_NO_SERVICE); b = s2a_save_buttons(p, 0, 0, 1, 0);
    CK(b.start && !b.import && !b.override, "缺服务无事务：可开始、不可导入、无仍要开始");
    // 还原失败留下事务 = 恢复失败；还原成功放开；读不到存档位置与恢复失败同一个确认（审计 18:00 P2-14）
    p = s2a_save_next(S2A_SAVE_READY, S2A_SAVE_EV_RESTORE_FAIL_TX); b = s2a_save_buttons(p, 0, 1, 1, 0);
    CK(!b.start && b.override, "还原失败留事务：开始灰、出现仍要开始");
    p = s2a_save_next(p, S2A_SAVE_EV_RESTORE_OK); CK(s2a_save_buttons(p, 0, 1, 1, 0).start, "还原成功：可开始");
    p = s2a_save_next(S2A_SAVE_CHECKING, S2A_SAVE_EV_NO_ROOT); b = s2a_save_buttons(p, 0, 1, 1, 0);
    CK(!b.start && b.override && !b.import && !b.export_, "读不到存档位置：开始灰、出现仍要开始、不能导入导出");
    b = s2a_save_buttons(p, 1, 1, 1, 0);
    CK(b.start && !b.override && !b.import && !b.export_, "读不到存档位置、确认后：可开始，仍不能导入导出");
    printf("%s：%d 条红\n", fails ? "红" : "绿", fails);
    return fails != 0;
}
