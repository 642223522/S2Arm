// t_loader_shim_wrap 的真实符号桩：记录调用并回可辨认的哨兵值。
// 与用例分处不同编译单元，-Wl,--wrap 才能把用例里的 vk* 调用改写到 __wrap_*、把 shim 的 __real_* 还原到这里。
#define _POSIX_C_SOURCE 200809L
#include <string.h>

#include "vkfake_driver_stub.h"

vkfake_driver_counts g_vkfake;

VKAPI_ATTR VkResult VKAPI_CALL vkEnumerateInstanceVersion(uint32_t *api) {
    g_vkfake.version++;
    if (api) *api = 0x00401000u;
    return VK_SUCCESS;
}
VKAPI_ATTR VkResult VKAPI_CALL vkEnumerateInstanceExtensionProperties(const char *layer, uint32_t *count, VkExtensionProperties *props) {
    g_vkfake.ext++;
    if (!layer || strcmp(layer, "real-layer")) g_vkfake.bad_args++;
    if (count) *count = 7;
    if (props && count && *count) props[0].specVersion = 11;
    return VK_INCOMPLETE;   // 非 SUCCESS 的返回值也要原样传回
}
VKAPI_ATTR VkResult VKAPI_CALL vkEnumerateInstanceLayerProperties(uint32_t *count, VkLayerProperties *props) {
    (void)props;
    g_vkfake.layer++;
    if (count) *count = 3;
    return VK_SUCCESS;
}
VKAPI_ATTR VkResult VKAPI_CALL vkCreateInstance(const VkInstanceCreateInfo *ci, const VkAllocationCallbacks *alloc, VkInstance *out) {
    (void)alloc;
    g_vkfake.create++;
    if (!ci || ci->sType != VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO) g_vkfake.bad_args++;
    if (out) *out = (VkInstance)(uintptr_t)0x1234;
    return VK_SUCCESS;
}
VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL vkGetInstanceProcAddr(VkInstance instance, const char *name) {
    (void)instance;
    g_vkfake.gipa++;
    if (!name || strcmp(name, "real-proc")) g_vkfake.bad_args++;
    return (PFN_vkVoidFunction)(uintptr_t)0x5678;
}
