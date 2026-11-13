// iOS 宿主界面语言的取法（11-13 维护者）：第一次打开跟随系统；玩家在 App 设置里选过就记住、以后都按他选的，不再跟系统；选「跟随系统」恢复跟随。
//   规则：简中 → zh-Hans，繁中（zh-Hant 或只带台 / 港 / 澳地区）→ zh-Hant，其余语言 → en。与 Mac 启动器 AppLanguage.resolved 同一口径（启动器没有繁中界面）。
//   choice = App 设置里存的值（NULL / "" / "system" = 跟随系统；"zh-Hans" / "zh-Hant" / "en" = 玩家选的；别的值当跟随系统）；system = 系统首选语言第一项（BCP 47）。
//   纯函数，单测 runtime/tests/t_ui_lang.c；ios/s2a_l10n.h s2a_l10n_lang 与 ios/app.m 起进程时的语言覆盖都经它
#pragma once
#include <string.h>
#include <ctype.h>

static inline const char *s2a_ui_lang_of_tag(const char *tag) {
    char b[64]; size_t n = 0;
    if (!tag) return "en";
    for (; tag[n] && n < sizeof b - 2; n++) b[n] = (char)(tag[n] == '_' ? '-' : tolower((unsigned char)tag[n]));
    b[n] = '-'; b[n + 1] = 0;   // 末尾补 '-'，按「-子标签-」整段比
    if (strncmp(b, "zh-", 3)) return "en";
    if (strstr(b, "-hant-")) return "zh-Hant";
    if (strstr(b, "-hans-")) return "zh-Hans";
    return strstr(b, "-tw-") || strstr(b, "-hk-") || strstr(b, "-mo-") ? "zh-Hant" : "zh-Hans";
}
static inline const char *s2a_ui_lang_pick(const char *choice, const char *system) {
    if (choice && (!strcmp(choice, "zh-Hans") || !strcmp(choice, "zh-Hant") || !strcmp(choice, "en"))) return choice;
    return s2a_ui_lang_of_tag(system);
}
