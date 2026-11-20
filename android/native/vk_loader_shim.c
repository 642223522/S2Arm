// 窄 shim 的 __wrap_* 实现：只在 S2A_ANDROID_VK_LOADER_SHIM（-Ps2arm.nativeMode=game）构建里参与
// 链接；--wrap 由 android/CMakeLists.txt 的 target_link_options 打开。私有入口为空时逐条落 __real_*。
#include "vk_loader_shim.h"

s2a_vk_loader_shim g_s2a_vk_shim;

#ifdef S2A_ANDROID_VK_LOADER_SHIM
extern VKAPI_ATTR VkResult VKAPI_CALL __real_vkEnumerateInstanceVersion(uint32_t *);
extern VKAPI_ATTR VkResult VKAPI_CALL __real_vkEnumerateInstanceExtensionProperties(const char *, uint32_t *, VkExtensionProperties *);
extern VKAPI_ATTR VkResult VKAPI_CALL __real_vkEnumerateInstanceLayerProperties(uint32_t *, VkLayerProperties *);
extern VKAPI_ATTR VkResult VKAPI_CALL __real_vkCreateInstance(const VkInstanceCreateInfo *, const VkAllocationCallbacks *, VkInstance *);
extern VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL __real_vkGetInstanceProcAddr(VkInstance, const char *);

VKAPI_ATTR VkResult VKAPI_CALL __wrap_vkEnumerateInstanceVersion(uint32_t *api) {
    if (g_s2a_vk_shim.version) return g_s2a_vk_shim.version(api);
    return __real_vkEnumerateInstanceVersion(api);
}
VKAPI_ATTR VkResult VKAPI_CALL __wrap_vkEnumerateInstanceExtensionProperties(const char *layer, uint32_t *count, VkExtensionProperties *props) {
    if (g_s2a_vk_shim.ext) return g_s2a_vk_shim.ext(layer, count, props);
    return __real_vkEnumerateInstanceExtensionProperties(layer, count, props);
}
VKAPI_ATTR VkResult VKAPI_CALL __wrap_vkEnumerateInstanceLayerProperties(uint32_t *count, VkLayerProperties *props) {
    if (g_s2a_vk_shim.layer) return g_s2a_vk_shim.layer(count, props);
    return __real_vkEnumerateInstanceLayerProperties(count, props);
}
VKAPI_ATTR VkResult VKAPI_CALL __wrap_vkCreateInstance(const VkInstanceCreateInfo *ci, const VkAllocationCallbacks *alloc, VkInstance *out) {
    if (g_s2a_vk_shim.create) return g_s2a_vk_shim.create(ci, alloc, out);
    return __real_vkCreateInstance(ci, alloc, out);
}
VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL __wrap_vkGetInstanceProcAddr(VkInstance instance, const char *name) {
    if (g_s2a_vk_shim.gipa) return g_s2a_vk_shim.gipa(instance, name);
    return __real_vkGetInstanceProcAddr(instance, name);
}
#endif
