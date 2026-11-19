// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#include "guest_window_abi.h"
#include "s2a_native.h"
#include <stdlib.h>
#include <errno.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>

#define CHECK(c) do { if (!(c)) { fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#c);exit(1); } } while (0)

struct rect { int32_t left, top, right, bottom; };
struct window { struct s2a_guest_window_prefix abi; uintptr_t tail[4]; };
static struct window windows[6];
static int readonly, original_calls, original_error, crop_calls, last_crop[4];
static uint64_t last_words[4];
static struct rect crop = {13,29,654,388};
int s2a_mem_readable(uint64_t a,uint64_t n) {
    uintptr_t w=(uintptr_t)windows,r=(uintptr_t)&crop;
    return (a>=w && a-w<=sizeof windows && n<=sizeof windows-(a-w)) ||
           (a>=r && a-r<=sizeof crop && n<=sizeof crop-(a-r));
}
int s2a_mem_query(uint64_t a,s2a_meminfo *out) {
    memset(out,0,sizeof *out);out->base=(uintptr_t)windows;out->size=sizeof windows;
    out->perm=s2a_mem_readable(a,8) ? (readonly ? 1 : 3) : 0;return 0;
}
void s2a_host_write_hook(uint64_t a,uint64_t n) { CHECK(s2a_mem_readable(a,n)); }
void *sw_xstack_wrap(const char *name,void *fn) { CHECK(name && fn);return fn; }
typedef int (*perform_fn)(void *,int,...);
uint64_t s2a_android_vk_guest_callback(void *fn,const uint64_t a[6]) {
    return (uint32_t)((perform_fn)fn)((void *)(uintptr_t)a[0],(int)a[1],a[2],a[3],a[4],a[5]);
}
int32_t h_vi_set_layer_crop(void *layer,int32_t x,int32_t y,int32_t w,int32_t h) {
    CHECK(layer);crop_calls++;last_crop[0]=x;last_crop[1]=y;last_crop[2]=w;last_crop[3]=h;return 0;
}
void nvn_plat_log(int level,const char *cls,const char *text) { (void)level;(void)cls;(void)text; }
// 主分支尚无观察者时仍执行原来的窗口回调，裁剪断言必须红，不能以缺文件代替行为红。
__attribute__((weak,noinline)) void nvn_plat_guest_window_watch(void *w) { (void)w; }
extern uintptr_t s2a_guest_window_original(void *) __attribute__((weak));
extern int32_t s2a_guest_window_crop_perform(void *,int,uint64_t,uint64_t,uint64_t,uint64_t) __attribute__((weak));
#if !defined(__aarch64__) || defined(S2A_WINDOW_CROP_HOST_TEST)
// 宿主只测 C 状态/返回值；真实 A64 转发另用同一夹具链接生产 .S 在手机执行。
int s2a_guest_window_dispatch(void *w,int op,...) {
    va_list ap;va_start(ap,op);uint64_t a[4];for (int i=0;i<4;i++)a[i]=va_arg(ap,uint64_t);va_end(ap);
    if (op==3 || op==5 || op==8 || op==15) return s2a_guest_window_crop_perform(w,op,a[0],a[1],a[2],a[3]);
    return ((perform_fn)s2a_guest_window_original(w))(w,op,a[0],a[1],a[2],a[3]);
}
#endif
static int original(void *w,int op,...) {
    CHECK(w);original_calls++;va_list ap;va_start(ap,op);
    if (op==97) {
        for (int i=0;i<4;i++)last_words[i]=va_arg(ap,uint64_t);
    } else if (op==98) {
        for (int i=0;i<10;i++)CHECK(va_arg(ap,uint64_t)==(uint64_t)(0x100+i));
        for (int i=0;i<10;i++)CHECK(va_arg(ap,double)==i+.125);
    }
    va_end(ap);return original_error;
}
static void init(struct window *w) {
    memset(w,0,sizeof *w);w->abi.magic=0x5f776e64u;w->abi.version=sizeof *w;w->abi.perform=(uintptr_t)original;
}
static int perform(struct window *w,int op,uint64_t a,uint64_t b,uint64_t c) {
    return ((perform_fn)w->abi.perform)(w,op,a,b,c,(uint64_t)0);
}
int main(void) {
    struct window *w=&windows[0];init(w);nvn_plat_guest_window_watch(w);
    CHECK(!perform(w,3,(uintptr_t)&crop,0,0));
    if (crop_calls!=1 || memcmp(last_crop,(int[]){13,29,641,359},sizeof last_crop)) {
        fputs("FAIL: native crop did not reach present state\n",stderr);return 1;
    }
    uintptr_t wrapped=w->abi.perform;nvn_plat_guest_window_watch(w);CHECK(w->abi.perform==wrapped);
    original_error=-EIO;int before=crop_calls;
    CHECK(perform(w,3,(uintptr_t)&crop,0,0)==-EIO && crop_calls==before);
    original_error=0;CHECK(!perform(w,3,0,0,0));CHECK(!memcmp(last_crop,(int[]){0,0,0,0},sizeof last_crop));
    for (int op=5;op<=15;op++) if (op==5 || op==8 || op==15) {
        CHECK(!perform(w,3,(uintptr_t)&crop,0,0));before=crop_calls;
        CHECK(!perform(w,op,1280,720,1) && crop_calls==before+1);
        CHECK(!memcmp(last_crop,(int[]){0,0,0,0},sizeof last_crop));
    }
    original_error=-37;before=crop_calls;
    CHECK(perform(w,97,0x11,0x22,0x33)==-37 && crop_calls==before);
    CHECK(last_words[0]==0x11 && last_words[1]==0x22 && last_words[2]==0x33 && last_words[3]==0);
#if defined(__aarch64__) && !defined(S2A_WINDOW_CROP_HOST_TEST)
    CHECK(((perform_fn)w->abi.perform)(w,98,
        (uint64_t)0x100,(uint64_t)0x101,(uint64_t)0x102,(uint64_t)0x103,(uint64_t)0x104,
        (uint64_t)0x105,(uint64_t)0x106,(uint64_t)0x107,(uint64_t)0x108,(uint64_t)0x109,
        .125,1.125,2.125,3.125,4.125,5.125,6.125,7.125,8.125,9.125)==-37);
#endif
    for (int bad=1;bad<=3;bad++) {
        struct window *x=&windows[bad];init(x);
        if (bad==1)x->abi.magic=0;
        if (bad==2)x->abi.version=8;
        readonly=bad==3;nvn_plat_guest_window_watch(x);CHECK(x->abi.perform==(uintptr_t)original);
    }
    readonly=0;original_error=0;
    w->abi.perform=(uintptr_t)original;nvn_plat_guest_window_watch(w);CHECK(!perform(w,3,(uintptr_t)&crop,0,0));
    printf("PASS: native crop, clear, failure, reset, idempotence and original return; calls=%d\n",original_calls);
    return 0;
}
