// 游戏音量单测（runtime/src/game_volume.c，#1186）。期望按规则手写：
//   ① 没设 S2A_AUDIO_VOLUME → 100；② 起局 30 → 30，之后再改环境变量不重读；③ 局中设 0 → 0（静音）、设 75 → 75；
//   ④ 越界：-5 → 0、250 → 100；⑤ 起局给 "abc" → 100（读不出数按没设，不把坏值当静音）
#include "../src/native.h"
#include <stdio.h>
#include <stdlib.h>
int s2a_audio_volume(void);
void S2A_AudioSetVolume(int percent);
static int bad;
#define CHECK(c, ...) do { if (!(c)) { printf("✗ "); printf(__VA_ARGS__); printf("\n"); bad++; } } while (0)
int main(int argc, char **argv) {
    if (argc > 1) {   // 子进程：每例要新的进程（起局值只读一次）
        int v = s2a_audio_volume(); printf("%d\n", v); return 0;
    }
    struct { const char *env; int want; const char *what; } cases[] = {{NULL, 100, "① 没设 → 100"}, {"30", 30, "② 起局 30"}, {"abc", 100, "⑤ 读不出数 → 100"}, {"250", 100, "④ 起局 250 截到 100"}};
    for (unsigned i = 0; i < sizeof cases / sizeof *cases; i++) {
        char cmd[512];
        if (cases[i].env) snprintf(cmd, sizeof cmd, "S2A_AUDIO_VOLUME=%s '%s' child", cases[i].env, argv[0]); else snprintf(cmd, sizeof cmd, "env -u S2A_AUDIO_VOLUME '%s' child", argv[0]);
        FILE *p = popen(cmd, "r"); int got = -1; if (p) { if (fscanf(p, "%d", &got) != 1) got = -1; pclose(p); }
        CHECK(got == cases[i].want, "%s：期望 %d，得 %d", cases[i].what, cases[i].want, got);
    }
    setenv("S2A_AUDIO_VOLUME", "30", 1);
    CHECK(s2a_audio_volume() == 30, "② 本进程起局 30");
    setenv("S2A_AUDIO_VOLUME", "80", 1);
    CHECK(s2a_audio_volume() == 30, "② 起局值只读一次：改环境变量后仍 30");
    S2A_AudioSetVolume(0); CHECK(s2a_audio_volume() == 0, "③ 局中设 0（静音）");
    S2A_AudioSetVolume(75); CHECK(s2a_audio_volume() == 75, "③ 局中设 75");
    S2A_AudioSetVolume(-5); CHECK(s2a_audio_volume() == 0, "④ -5 截到 0");
    S2A_AudioSetVolume(250); CHECK(s2a_audio_volume() == 100, "④ 250 截到 100");
    printf("%s t_game_volume：%d 处不符\n", bad ? "✗" : "✓", bad);
    return bad != 0;
}
