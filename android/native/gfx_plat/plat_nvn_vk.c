// nvn_plat_vk.h 的安卓实现：ANativeWindow → VkSurfaceKHR。
#include "nvn_plat_vk.h"
#include <android/native_window.h>
#include <vulkan/vulkan_android.h>
#include <string.h>

const char *const *nvn_plat_vk_instance_exts(uint32_t *n) {
    static const char *const exts[] = {"VK_KHR_surface", "VK_KHR_android_surface"};
    if (n) *n = 2;
    return exts;
}

VkResult nvn_plat_vk_surface_create(VkInstance instance, void *native, VkSurfaceKHR *out) {
    if (out) *out = VK_NULL_HANDLE;
    if (!instance || !native || !out) return VK_ERROR_INITIALIZATION_FAILED;
    VkAndroidSurfaceCreateInfoKHR ci; memset(&ci, 0, sizeof ci);
    ci.sType = VK_STRUCTURE_TYPE_ANDROID_SURFACE_CREATE_INFO_KHR;
    ci.window = (ANativeWindow *)native;
    return vkCreateAndroidSurfaceKHR(instance, &ci, NULL, out);
}

int nvn_plat_window_size(void *native, uint32_t *w, uint32_t *h) {
    if (!native) return 0;
    int32_t ww = ANativeWindow_getWidth((ANativeWindow *)native), hh = ANativeWindow_getHeight((ANativeWindow *)native);
    if (ww <= 0 || hh <= 0) return 0;
    if (w) *w = (uint32_t)ww;
    if (h) *h = (uint32_t)hh;
    return 1;
}
