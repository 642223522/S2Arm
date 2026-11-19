// 门禁用例（android/tests/vk/run.sh 顶部无条件跑）：窄 shim 的 wrap 直通与私有路由。
// 不设驱动（g_s2a_vk_shim 全空）时，5 个 vk* 入口必须原样落到系统 loader 的真实符号，返回值与参数一致；
// 设了私有入口时只走私有、不碰真实符号。真实符号由同目录 vkfake_driver_stub.c 提供（不链 libvulkan / lavapipe）。
// 链接参数由 run.sh 给：-Wl,--wrap=… 五个符号。
#define _POSIX_C_SOURCE 200809L
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "vk_loader_shim.h"
#include "vkfake_driver_stub.h"

static int failures;
#define CHECK(cond) do { if (!(cond)) { printf("【红】%s:%d %s\n", __FILE__, __LINE__, #cond); failures++; } } while (0)

#define INST_SENTINEL ((VkInstance)(uintptr_t)0x1234)
#define GIPA_SENTINEL ((PFN_vkVoidFunction)(uintptr_t)0x5678)

static int priv_version, priv_ext, priv_layer, priv_create, priv_gipa;

// ---- 私有入口假实现：设了驱动时只许走这里 ----
static VkResult VKAPI_CALL priv_version_fn(uint32_t *api) { priv_version++; if (api) *api = 0x00402000u; return VK_SUCCESS; }
static VkResult VKAPI_CALL priv_ext_fn(const char *layer, uint32_t *count, VkExtensionProperties *props) {
    (void)props;
    priv_ext++;
    CHECK(layer && !strcmp(layer, "priv-layer"));
    if (count) *count = 5;
    return VK_SUCCESS;
}
static VkResult VKAPI_CALL priv_layer_fn(uint32_t *count, VkLayerProperties *props) {
    (void)props;
    priv_layer++;
    if (count) *count = 1;
    return VK_SUCCESS;
}
static VkResult VKAPI_CALL priv_create_fn(const VkInstanceCreateInfo *ci, const VkAllocationCallbacks *alloc, VkInstance *out) {
    (void)ci; (void)alloc;
    priv_create++;
    if (out) *out = (VkInstance)(uintptr_t)0x9999;
    return VK_ERROR_INITIALIZATION_FAILED;
}
static PFN_vkVoidFunction VKAPI_CALL priv_gipa_fn(VkInstance instance, const char *name) {
    (void)instance; (void)name;
    priv_gipa++;
    return (PFN_vkVoidFunction)(uintptr_t)0x8888;
}

int main(void) {
    memset(&g_s2a_vk_shim, 0, sizeof g_s2a_vk_shim);
    memset(&g_vkfake, 0, sizeof g_vkfake);

    // === 不设驱动：5 个入口逐条落真实符号 ===
    uint32_t api = 0;
    CHECK(vkEnumerateInstanceVersion(&api) == VK_SUCCESS);
    CHECK(api == 0x00401000u);
    uint32_t ext_count = 0;
    VkExtensionProperties ext_props[7];
    memset(ext_props, 0, sizeof ext_props);
    CHECK(vkEnumerateInstanceExtensionProperties("real-layer", &ext_count, ext_props) == VK_INCOMPLETE);
    CHECK(ext_count == 7 && ext_props[0].specVersion == 11);
    uint32_t layer_count = 0;
    CHECK(vkEnumerateInstanceLayerProperties(&layer_count, NULL) == VK_SUCCESS);
    CHECK(layer_count == 3);
    VkInstanceCreateInfo ci;
    memset(&ci, 0, sizeof ci);
    ci.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    VkInstance inst = VK_NULL_HANDLE;
    CHECK(vkCreateInstance(&ci, NULL, &inst) == VK_SUCCESS);
    CHECK(inst == INST_SENTINEL);
    CHECK(vkGetInstanceProcAddr(VK_NULL_HANDLE, "real-proc") == GIPA_SENTINEL);
    CHECK(g_vkfake.version == 1 && g_vkfake.ext == 1 && g_vkfake.layer == 1 && g_vkfake.create == 1 && g_vkfake.gipa == 1);
    CHECK(g_vkfake.bad_args == 0);
    CHECK(priv_version == 0 && priv_ext == 0 && priv_layer == 0 && priv_create == 0 && priv_gipa == 0);

    // === 设了私有入口：只走私有，真实符号一次都不再碰 ===
    g_s2a_vk_shim.version = priv_version_fn;
    g_s2a_vk_shim.ext = priv_ext_fn;
    g_s2a_vk_shim.layer = priv_layer_fn;
    g_s2a_vk_shim.create = priv_create_fn;
    g_s2a_vk_shim.gipa = priv_gipa_fn;
    api = 0;
    CHECK(vkEnumerateInstanceVersion(&api) == VK_SUCCESS && api == 0x00402000u);
    ext_count = 0;
    CHECK(vkEnumerateInstanceExtensionProperties("priv-layer", &ext_count, NULL) == VK_SUCCESS && ext_count == 5);
    layer_count = 0;
    CHECK(vkEnumerateInstanceLayerProperties(&layer_count, NULL) == VK_SUCCESS && layer_count == 1);
    inst = VK_NULL_HANDLE;
    CHECK(vkCreateInstance(&ci, NULL, &inst) == VK_ERROR_INITIALIZATION_FAILED);
    CHECK(inst == (VkInstance)(uintptr_t)0x9999);
    CHECK(vkGetInstanceProcAddr(VK_NULL_HANDLE, "any") == (PFN_vkVoidFunction)(uintptr_t)0x8888);
    CHECK(g_vkfake.version == 1 && g_vkfake.ext == 1 && g_vkfake.layer == 1 && g_vkfake.create == 1 && g_vkfake.gipa == 1);
    CHECK(priv_version == 1 && priv_ext == 1 && priv_layer == 1 && priv_create == 1 && priv_gipa == 1);

    if (failures) { printf("RESULT: FAIL（%d 处）\n", failures); return 1; }
    printf("RESULT: PASS（不设驱动：5 个入口都落真实符号；设驱动：5 个入口只走私有入口）\n");
    return 0;
}
