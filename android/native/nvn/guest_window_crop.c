// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 观察 NVN 原生窗口公开 perform 回调，不按游戏 SDK 的函数名/地址接管入口。
#include "guest_window_abi.h"
#include "nvn_plat.h"
#include "s2a_native.h"
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern int s2a_guest_window_dispatch(void *,int,...);
__attribute__((visibility("hidden"))) _Atomic uintptr_t s2a_guest_window_crop_entry_wrapped;

#if defined(S2A_ANDROID_GAME_RUNTIME) || defined(S2A_WINDOW_CROP_TEST)
extern void *sw_xstack_wrap(const char *,void *);
extern uint64_t s2a_android_vk_guest_callback(void *,const uint64_t[6]);
extern void s2a_host_write_hook(uint64_t,uint64_t);
extern int32_t h_vi_set_layer_crop(void *,int32_t,int32_t,int32_t,int32_t);
struct window_entry {
    void *window;
    _Atomic uintptr_t original;
    struct window_entry *next;
};
static _Atomic(struct window_entry *) entries;
static pthread_mutex_t install_mu=PTHREAD_MUTEX_INITIALIZER;

// 叶子查表：未知操作从 A64 桩恢复全部参数后尾调用原回调，栈上参数也原样保留。
uintptr_t s2a_guest_window_original(void *window) {
    for (struct window_entry *e=atomic_load_explicit(&entries,memory_order_acquire);e;e=e->next)
        if (e->window==window) return atomic_load_explicit(&e->original,memory_order_acquire);
    return 0;
}

int32_t s2a_guest_window_crop_perform(void *window,int op,uint64_t a,uint64_t b,uint64_t c,uint64_t d) {
    uintptr_t original=s2a_guest_window_original(window);
    if (!original) return -ENODEV;
    struct { int32_t left,top,right,bottom; } rect={0};
    int readable=op!=3 || !a || s2a_mem_readable(a,sizeof rect);
    if (op==3 && a && readable) memcpy(&rect,(const void *)(uintptr_t)a,sizeof rect);
    uint64_t args[6]={(uintptr_t)window,(uint64_t)(uint32_t)op,a,b,c,d};
    int32_t rc=(int32_t)s2a_android_vk_guest_callback((void *)original,args);
    if (rc) return rc; // SDK 拒绝的裁剪不能写进上屏状态。
    if (op==3 && a) {
        int64_t width=(int64_t)rect.right-rect.left,height=(int64_t)rect.bottom-rect.top;
        if (!readable || rect.left<0 || rect.top<0 || width<=0 || height<=0 || width>INT32_MAX || height>INT32_MAX) {
            nvn_plat_log(NVN_PLAT_LOG_WARN,"window","原生窗口接受了无法表示的裁剪，上屏保留先前区域");return rc;
        }
        h_vi_set_layer_crop(window,rect.left,rect.top,(int32_t)width,(int32_t)height);
    } else {
        // SET_CROP(NULL)，以及成功的 SET_BUFFERS_GEOMETRY / DIMENSIONS / USER_DIMENSIONS 都清空裁剪。
        h_vi_set_layer_crop(window,0,0,0,0);
    }
    return rc;
}

void nvn_plat_guest_window_watch(void *window) {
    struct s2a_guest_window_prefix prefix;
    uintptr_t base=(uintptr_t)window;
    if (!window || (base&7) || !s2a_mem_readable(base,sizeof prefix)) return;
    memcpy(&prefix,window,sizeof prefix);
    if (prefix.magic!=0x5f776e64u || prefix.version<sizeof prefix || !prefix.perform) return;
    uintptr_t *field=(uintptr_t *)(base+offsetof(struct s2a_guest_window_prefix,perform));
    s2a_meminfo memory;
    if (s2a_mem_query((uintptr_t)field,&memory) || !(memory.perm&2) || memory.base>(uintptr_t)field ||
        (uintptr_t)field-memory.base>memory.size || sizeof *field>memory.size-((uintptr_t)field-memory.base)) return;
    pthread_mutex_lock(&install_mu);
    if (prefix.perform==(uintptr_t)s2a_guest_window_dispatch) { pthread_mutex_unlock(&install_mu);return; }
    struct window_entry *entry=atomic_load_explicit(&entries,memory_order_acquire);
    while (entry && entry->window!=window) entry=entry->next;
    if (!entry) {
        entry=calloc(1,sizeof *entry);
        if (!entry) { pthread_mutex_unlock(&install_mu);nvn_plat_log(NVN_PLAT_LOG_WARN,"window","无法分配裁剪观察状态，原生窗口回调保持原样");return; }
        entry->window=window;entry->next=atomic_load_explicit(&entries,memory_order_relaxed);
        atomic_init(&entry->original,prefix.perform);atomic_store_explicit(&entries,entry,memory_order_release);
    } else atomic_store_explicit(&entry->original,prefix.perform,memory_order_release);
    if (!atomic_load_explicit(&s2a_guest_window_crop_entry_wrapped,memory_order_acquire))
        atomic_store_explicit(&s2a_guest_window_crop_entry_wrapped,
            (uintptr_t)sw_xstack_wrap("NVN native window crop",(void *)s2a_guest_window_crop_perform),memory_order_release);
    s2a_host_write_hook((uintptr_t)field,sizeof *field);
    uintptr_t expected=prefix.perform;
    int installed=__atomic_compare_exchange_n(field,&expected,(uintptr_t)s2a_guest_window_dispatch,0,__ATOMIC_RELEASE,__ATOMIC_ACQUIRE);
    pthread_mutex_unlock(&install_mu);
    if (installed) nvn_plat_log(NVN_PLAT_LOG_INFO,"window","已接原生窗口标准裁剪回调");
    // 条目保留到进程退出：窗口销毁前已经进入的回调仍须能找到原函数；同地址重建时更新原函数。
}
#else
void nvn_plat_guest_window_watch(void *window) { (void)window; }
uintptr_t s2a_guest_window_original(void *window) { (void)window;return 0; }
int32_t s2a_guest_window_crop_perform(void *w,int op,uint64_t a,uint64_t b,uint64_t c,uint64_t d) {
    (void)w;(void)op;(void)a;(void)b;(void)c;(void)d;return -ENOTSUP;
}
#endif
