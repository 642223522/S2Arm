// nvn_plat.h 的安卓实现：日志进 logcat，开关读 debug.s2a.<名字>（只在调试入口打开时认），目录由会话给。
#include <stdatomic.h>
#include <pthread.h>
#include "nvn_plat.h"
#include <android/log.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/system_properties.h>
#include "debug_gate.h"

const char *nvk_session_cache_dir(void);

void nvn_plat_log(int level, const char *cls, const char *text) {
    int prio = level == NVN_PLAT_LOG_RED ? ANDROID_LOG_ERROR : level == NVN_PLAT_LOG_WARN ? ANDROID_LOG_WARN : ANDROID_LOG_INFO;
    __android_log_print(prio, "S2Arm", "%snvk %s: %s", level == NVN_PLAT_LOG_RED ? "【红】" : "", cls ? cls : "", text ? text : "");
}

int nvn_plat_flag(const char *name, int dflt) {
    if (!name || !s2a_debug_entries_open()) return dflt;
    char key[PROP_NAME_MAX + 32], v[PROP_VALUE_MAX] = {0};
    snprintf(key, sizeof key, "debug.s2a.%s", name);
    if (__system_property_get(key, v) <= 0 || !v[0]) return dflt;
    return atoi(v);
}

const char *nvn_plat_dir(int which) {
    if (which == NVN_PLAT_DIR_CACHE) return nvk_session_cache_dir();
    if (which == NVN_PLAT_DIR_DIAG) return getenv("S2A_DIRECT_DIAG_DIR");
    return NULL;
}

// 前端还直接按名字要的两个宿主入口（hle_nvn.c / nvn2.c）
const char *nvn_diag_path(const char *p, char *buf, size_t n) { (void)buf; (void)n; return p; }   // 诊断输出路径：原样返回，同非 iOS 的苹果宿主
int dm_opmode(void) { const char *d = getenv("S2A_DOCKED"); return d && d[0] == '1' && !d[1]; }   // 主机 / 掌机档：S2A_DOCKED=1 主机，其余掌机

// ---------- 每款参数 ----------
// 共用前端按 DM_GAME_* 读每款参数（graphics/nvn/host/game_profile.h）。没有随包档 / 没写的键按 Switch 真实语义的缺省
// （game_tsv.h s2a_game_tsv_defaults：条件渲染照实求值、CPU 写进池的贴图要上传、动态句柄着色器、段内 GPU 时间戳都开）。
// 这里是强定义；vk_engine_host_shim.c 的弱桩是全 0，等于把这些全关掉——贴图在首次使用之后才被游戏填进内容的那些永远传不上来
// （块压缩贴图停在全 0：ASTC 解成错误色洋红，DXT 解成全透明）。随包 game.tsv 的读取等资源包带上它时再接。
#include "../../../graphics/nvn/host/game_profile.h"
const s2a_nvn_profile *s2a_nvn_prof(void) {
    static s2a_nvn_profile p; static _Atomic int ready;
    if (!atomic_load_explicit(&ready, memory_order_acquire)) {
        static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
        pthread_mutex_lock(&mu);
        if (!atomic_load_explicit(&ready, memory_order_relaxed)) { s2a_game_tsv_defaults(&p.t); atomic_store_explicit(&ready, 1, memory_order_release); }
        pthread_mutex_unlock(&mu);
    }
    return &p;
}
