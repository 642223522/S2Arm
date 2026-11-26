// Switch 2 SDK 接管：安卓 s2a_direct_lookup（真 direct_session.c + 真选择事务 direct/selection.c）。
// 用法：ns2_lookup_test <选择状态> <switch2|switch1>
//   选择状态：none = 没发布；generic = 发布 mode 0；direct = 发布 mode 1（NVN 直连在重定位前冻结）。
//   switch2 / switch1：夹具里的两个入口（nvn2_vi_entry / s2a_nv_entry）按 Switch 2 回函数，或按 Switch 1 一律回 NULL（真表在 graphics/nvn/gfx/nvn/nvn2.c，
//   那边有自己的单测 t_nvn2；这里只验安卓这一层的接线）。
// 期望（手写，不跑被测实现）：
//   direct + switch2：游戏导入的 nv::InitializeGraphics / nv::InitCheck、nn::vi::*、streamplay、Nv* 被接管：交出去的是切栈桩包过的那个入口（夹具的桩把入口 +1，
//     证明返回的是桩）；nn::vi 先问 vi 入口，vi 回 NULL 才问 nv 入口；非 nn::vi 的名字不问 vi 入口。
//   其余组合（没发布 / generic / switch1）：_Z 与 Nv 名一律 0（走原路径）；没发布与 generic 时两个入口都不被问。
//   任何组合：vk*、libc 名、没有 _Z / Nv 前缀的名字，不问两个入口，回 0。
#include "direct_session.h"
#include "direct/selection.h"
#include "s2a_hostapi.h"
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int s2a_gfx_mode(void);
uint64_t s2a_direct_lookup(const char *);

// 链接 direct_session.c 要的外部符号（夹具不跑客体，走到就是夹具自己的错），与 session_test.c 同一组
int s2a_svc_stopping(void) { return 0; }
const s2a_host_api_v1 *s2a_host_get(void) { return NULL; }
uint64_t s2a_android_vk_guest_callback(void *fn, const uint64_t args[6]) { (void)fn; (void)args; abort(); }
void s2a_core_block_begin(void) { abort(); }
void s2a_core_block_end(void) { abort(); }
void s2a_android_guest_park_forever(void) { abort(); }
int s2a_mem_readable(uint64_t a, uint64_t s) { (void)a; (void)s; abort(); }

// 切栈桩：记下谁被包过，交出的指针 = 入口 + 1（与原入口不同，证明 s2a_direct_lookup 返回的是桩）
static const void *g_wrapped;
static int g_wrap_calls;
void *sw_xstack_wrap(const char *name, void *fn) { (void)name; g_wrapped = fn; g_wrap_calls++; return (char *)fn + 1; }

static int g_sw2, g_vi_calls, g_nv_calls;
static void vi_fn(void) {}
static void nv_fn(void) {}
// nn::vi 入口：Switch 2 只认 nn::vi 名；OnlyNvSide 这个名字它不认（回 NULL），留给 nv 入口
void *nvn2_vi_entry(const char *name) {
    g_vi_calls++;
    int vi = !strncmp(name, "_ZN2nn2vi", 9) || !strncmp(name, "_ZNK2nn2vi", 10);
    return g_sw2 && vi && strcmp(name, "_ZN2nn2vi11OnlyNvSideEv") ? (void *)vi_fn : NULL;
}
// nv 入口：nv::、streamplay、Nv*，以及 OnlyNvSide
void *s2a_nv_entry(const char *name) {
    g_nv_calls++;
    int mine = !strncmp(name, "_ZN2nv", 6) || !strncmp(name, "_ZN2nn10streamplay", 18) || !strncmp(name, "Nv", 2) || !strcmp(name, "_ZN2nn2vi11OnlyNvSideEv");
    return g_sw2 && mine ? (void *)nv_fn : NULL;
}

struct row { const char *name; void *fn; int vi_asked; int nv_asked; };   // 接管时期望的入口，以及两个入口各被问几次（只看这一次查找）

int main(int argc, char **argv) {
    assert(argc == 3);
    const char *state = argv[1];
    g_sw2 = !strcmp(argv[2], "switch2");
    assert(g_sw2 || !strcmp(argv[2], "switch1"));
    int published = strcmp(state, "none") != 0, direct = !strcmp(state, "direct");
    if (published) {
        assert(direct || !strcmp(state, "generic"));
        struct s2a_direct_selection selection;
        memset(&selection, 0, sizeof selection);
        selection.decision = direct ? S2A_DIRECT_DECISION_DIRECT : S2A_DIRECT_DECISION_GENERIC;
        selection.mode = direct ? 1 : 0;
        assert(s2a_direct_selection_publish(&selection) == 0);
    }
    assert(s2a_gfx_mode() == 0);   // vk-direct 实验开关没开：下面的 vk* 一律走不到 s2a_vk_entry
    int take = direct && g_sw2;

    const struct row rows[] = {
        {"_ZN2nv18InitializeGraphicsEPvm", (void *)nv_fn, 0, 1},
        {"_ZN2nv9InitCheckEv", (void *)nv_fn, 0, 1},
        {"_ZN2nn2vi10InitializeEv", (void *)vi_fn, 1, 0},                       // vi 入口答了，nv 入口不再问
        {"_ZNK2nn2vi5Layer3FooEv", (void *)vi_fn, 1, 0},                        // _ZNK 前缀同样先问 vi
        {"_ZN2nn2vi11OnlyNvSideEv", (void *)nv_fn, 1, 1},                       // vi 回 NULL → 再问 nv
        {"_ZN2nn10streamplay24CreateIndividualDisplaysEi", (void *)nv_fn, 0, 1},   // 非 nn::vi 名不问 vi 入口
        {"NvRmChannelOpen", (void *)nv_fn, 0, 1},                               // NVIDIA 驱动的 C 名（Nv 前缀）
        {"_ZN3foo3barEv", NULL, 0, 1},                                          // 游戏自己的 C++ 名：问了 nv 入口，没人认 → 0
    };
    for (size_t i = 0; i < sizeof rows / sizeof rows[0]; i++) {
        const struct row *r = &rows[i];
        int vi0 = g_vi_calls, nv0 = g_nv_calls, w0 = g_wrap_calls;
        g_wrapped = NULL;
        uint64_t got = s2a_direct_lookup(r->name);
        int vi = g_vi_calls - vi0, nv = g_nv_calls - nv0;
        if (take && r->fn) {
            if (got != (uint64_t)(uintptr_t)((char *)r->fn + 1) || g_wrapped != r->fn || g_wrap_calls != w0 + 1 || vi != r->vi_asked || nv != r->nv_asked) {
                fprintf(stderr, "FAIL %s %s %s：期望接管（入口 %p 的桩，问 vi %d 次 / nv %d 次）→ 实 %#llx，被包 %p（%d 次），问 vi %d 次 / nv %d 次\n",
                    state, argv[2], r->name, r->fn, r->vi_asked, r->nv_asked, (unsigned long long)got, g_wrapped, g_wrap_calls - w0, vi, nv);
                return 1;
            }
        } else {
            int asks_ok = direct ? 1 : (vi == 0 && nv == 0);   // 没发布 / generic：两个入口都不该被问
            if (got != 0 || g_wrap_calls != w0 || !asks_ok) {
                fprintf(stderr, "FAIL %s %s %s：期望 0（原路径）、不接管 → 实 %#llx，被包 %d 次，问 vi %d 次 / nv %d 次\n",
                    state, argv[2], r->name, (unsigned long long)got, g_wrap_calls - w0, vi, nv);
                return 1;
            }
        }
    }
    // 与选择状态、Switch 几无关：这些名字不问两个入口
    static const char *const never[] = {"vkCreateInstance", "vkGetInstanceProcAddr", "malloc", "memcpy", "nnosInitialize", "_init_libc0"};
    for (size_t i = 0; i < sizeof never / sizeof never[0]; i++) {
        int vi0 = g_vi_calls, nv0 = g_nv_calls, w0 = g_wrap_calls;
        uint64_t got = s2a_direct_lookup(never[i]);
        if (got != 0 || g_vi_calls != vi0 || g_nv_calls != nv0 || g_wrap_calls != w0) {
            fprintf(stderr, "FAIL %s %s %s：期望 0、不问入口 → 实 %#llx，问 vi %d / nv %d 次\n", state, argv[2], never[i],
                (unsigned long long)got, g_vi_calls - vi0, g_nv_calls - nv0);
            return 1;
        }
    }
    printf("PASS ns2 lookup %s %s（%s）\n", state, argv[2], take ? "接管" : "不接管");
    return 0;
}
