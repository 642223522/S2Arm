// 游戏音量（#1186，按游戏存的 S2AGameVolume 0–100）：只压游戏自己的声音，不动系统音量、不影响别的 App（开了「与其他 App 混音」时边听歌边玩）。
//   起局：ios/settings.m 把 S2AGameVolume 落成 S2A_AUDIO_VOLUME（100 / 没设过不设）；局中：齿轮菜单「声音」调 S2A_AudioSetVolume，下一个音频缓冲生效。
//   C# 输出层每个缓冲取 s2a_audio_volume()（compat/tree/src/Ryujinx.Audio.Backends.Apple/AppleHardwareDeviceSession.cs ApplyVolume），
//   100 时那里照旧整段跳过、不逐样本乘
#include "native.h"
#include <stdatomic.h>
#include <stdlib.h>

static _Atomic int g_vol = -1;   // -1 = 还没读起局环境变量
static int clamp_pct(long v) { return v < 0 ? 0 : v > 100 ? 100 : (int)v; }

int s2a_audio_volume(void) {
    int v = atomic_load_explicit(&g_vol, memory_order_relaxed);
    if (v >= 0) return v;
    const char *e = getenv("S2A_AUDIO_VOLUME");
    char *end = NULL; long n = e && *e ? strtol(e, &end, 10) : 100; int want = e && *e && end != e ? clamp_pct(n) : 100, unset = -1;   // 读不出数 = 没设
    if (atomic_compare_exchange_strong(&g_vol, &unset, want) && want != 100) LOG("游戏音量：%d%%（起局设置 S2A_AUDIO_VOLUME）", want);
    return atomic_load_explicit(&g_vol, memory_order_relaxed);
}

// 局中改音量（iOS 齿轮菜单弱链接调；0 = 静音）：超范围按 0 / 100 截
void S2A_AudioSetVolume(int percent) {
    int v = clamp_pct(percent);
    atomic_store_explicit(&g_vol, v, memory_order_relaxed);
    LOG("游戏音量：%d%%（局中设置）", v);
}
