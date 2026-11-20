// 窄 shim 的入口表：选了自定义驱动时由 direct_session.c 填入 adrenotools 私有 loader 的五个
// 实例创建入口；全空 = 系统驱动直通——每个 __wrap_* 都原样调 __real_*，默认路径行为不变。
// 拆成独立编译单元，是为了让宿主用例（android/tests/vk/t_loader_shim_wrap.c）能带 -Wl,--wrap 真跑一遍。
#pragma once
#include <vulkan/vulkan_core.h>   // 仓内 vendored 头只有 vulkan_core.h（vulkan.h 的同一份内容）

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    PFN_vkEnumerateInstanceVersion version;
    PFN_vkEnumerateInstanceExtensionProperties ext;
    PFN_vkEnumerateInstanceLayerProperties layer;
    PFN_vkCreateInstance create;
    PFN_vkGetInstanceProcAddr gipa;
} s2a_vk_loader_shim;

// 零初始化 = 直通系统 loader；只在 S2A_ANDROID_VK_LOADER_SHIM 构建里被 __wrap_* 读取。
extern s2a_vk_loader_shim g_s2a_vk_shim;

#ifdef __cplusplus
}
#endif
