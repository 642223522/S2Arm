// t_loader_shim_wrap 的「系统 loader 真实符号」桩。--wrap 把窄 shim 里的 __real_* 还原成这些裸名符号。
// 必须与调用方分处不同编译单元：同一 TU 里的调用会被编译器直接绑定，绕过 -Wl,--wrap。
#pragma once
#include <vulkan/vulkan_core.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int version, ext, layer, create, gipa;
    int bad_args;   // 桩收到的参数不符合用例预期（只记数，判红在用例里）
} vkfake_driver_counts;

extern vkfake_driver_counts g_vkfake;

#ifdef __cplusplus
}
#endif
