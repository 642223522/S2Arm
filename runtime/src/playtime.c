// 游玩时间：口径与文件格式见 runtime/include/s2a_playtime.h
#include "native.h"
#include "s2a_docs.h"
#include "s2a_playtime.h"
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static _Atomic uint64_t g_last;   // 上一次上屏的单调纳秒
static _Atomic int g_seen;        // 本局上屏过（不拿 g_last == 0 当「没上屏过」：时刻 0 也是合法读数）
static _Atomic uint64_t g_acc;    // 攒着、还没落盘的游玩纳秒
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;

void s2a_playtime_frame(uint64_t now, int focused) {
    uint64_t prev = atomic_exchange_explicit(&g_last, now, memory_order_relaxed);
    if (!atomic_exchange_explicit(&g_seen, 1, memory_order_relaxed)) return;   // 首帧：从这里开始计
    if (focused && now > prev && now - prev <= S2A_PLAYTIME_GAP_NS) atomic_fetch_add_explicit(&g_acc, now - prev, memory_order_relaxed);
}

static void file_path(char *out, size_t n) {
    const char *e = getenv("S2A_PLAYTIME");
    if (e && *e) snprintf(out, n, "%s", e); else s2a_docs_path(out, n, "playtime.json");
}

// 只认本模块自己写的一行格式；字段缺 / 坏按 0（不因一个坏文件丢以后的计时）
static uint64_t field(const char *s, const char *key) {
    const char *p = strstr(s, key); if (!p) return 0;
    p += strlen(key); while (*p == ' ' || *p == ':') p++;
    char *end; unsigned long long v = strtoull(p, &end, 10); return end == p ? 0 : (uint64_t)v;
}

int s2a_playtime_read(const char *path, uint64_t *seconds, int64_t *last) {
    *seconds = 0; *last = 0;
    FILE *f = fopen(path, "r"); if (!f) return -1;
    char buf[256]; size_t k = fread(buf, 1, sizeof buf - 1, f); fclose(f); buf[k] = 0;
    *seconds = field(buf, "\"seconds\""); *last = (int64_t)field(buf, "\"lastPlayed\""); return 0;
}

int s2a_playtime_flush_at(int64_t now_wall) {
    uint64_t take = atomic_load_explicit(&g_acc, memory_order_relaxed) / 1000000000ull;
    if (!take) return 0;
    pthread_mutex_lock(&g_mu);
    char p[1200], t[1300]; file_path(p, sizeof p); snprintf(t, sizeof t, "%s.tmp", p);
    uint64_t sec; int64_t last; s2a_playtime_read(p, &sec, &last);
    int rc = -1; FILE *f = fopen(t, "w");
    if (f) {
        int w = fprintf(f, "{\"schema\":1,\"seconds\":%llu,\"lastPlayed\":%lld}\n", (unsigned long long)(sec + take), (long long)now_wall);
        rc = (fclose(f) || w < 0 || rename(t, p)) ? -1 : 0;
    }
    if (!rc) atomic_fetch_sub_explicit(&g_acc, take * 1000000000ull, memory_order_relaxed);   // 写成了才扣；写不成留着下次再试
    else { LOG("【红】游玩时间：写 %s 失败（errno %d），攒着下次再写", p, errno); unlink(t); }
    pthread_mutex_unlock(&g_mu);
    return rc;
}

int s2a_playtime_flush(void) { return s2a_playtime_flush_at((int64_t)time(NULL)); }
