// 校验没过、照常继续（11-17 维护者：凡「校验不过就整个拒绝」的都撤掉，改黄字提示照常继续，之后出问题时报错里带上「之前这里校验不过」）。
//   s2a_check_waived 打一行【黄】并记下；FATAL（native.h s2a_native_fatal）与崩溃现场（crash.c）按 s2a_waived_note 补一行，定因时一眼看到是带着哪项没过的校验跑的
#include "native.h"
#include <pthread.h>
static char g_note[1024]; static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
// 调用方按 dlsym 取（只链自己那份源文件的单测里没有本文件，取不到就自己打那行【黄】）
void s2a_check_waived(const char *one) {
    LOG("【黄】校验没过，照常继续：%s", one);
    pthread_mutex_lock(&g_mu);
    size_t n = strlen(g_note);
    if (n + 4 < sizeof g_note) snprintf(g_note + n, sizeof g_note - n, "%s%s", n ? "；" : "", one);
    pthread_mutex_unlock(&g_mu);
}
const char *s2a_waived_note(void) { return g_note; }   // 崩溃路径里读：只读不加锁（写只在起局早期、行尾以 0 收）
