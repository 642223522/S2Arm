// 平台接口里与 Vulkan 有关的部分：只有 Vulkan 后端 include。回放核心不许 include 本头。
#pragma once
#include <vulkan/vulkan.h>

#ifdef __cplusplus
extern "C" {
#endif

// 建实例时要加的表面扩展名（安卓：VK_KHR_surface + VK_KHR_android_surface；鸿蒙：VK_KHR_surface + VK_OHOS_surface）。
// 返回静态数组，*n 是个数。
const char *const *nvn_plat_vk_instance_exts(uint32_t *n);
// 从平台窗口句柄建表面。native：安卓 ANativeWindow*，鸿蒙 OHNativeWindow*。失败返回对应 VkResult，*out 置空。
VkResult nvn_plat_vk_surface_create(VkInstance instance, void *native, VkSurfaceKHR *out);
// 窗口当前像素尺寸（表面能力里 currentExtent 无效时用）。拿不到返回 0。
int nvn_plat_window_size(void *native, uint32_t *w, uint32_t *h);

#ifdef __cplusplus
}
#endif
