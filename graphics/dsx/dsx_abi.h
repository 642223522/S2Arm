// 直连着色器翻译库 libdsx（graphics/dsx）的导出 ABI：直连出库 / 设备首遇现编与渲染器共用的翻译段，纯 C、不引 Metal（11-08 从 gal_abi.h 拆出）。
//   gal_abi.h 包含本头（渲染器 ABI 指纹照旧按 gal_abi.h 的内容算，tools/abi_hash.py）；C# 端 S2A.Dsh 经 DllImport("dsx") 调（11-08 起只有 libdsx 导出这些名字，libnxgal 隐藏链入）
#pragma once
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
#define NXGAL_API __attribute__((visibility("default")))
// 参照后端（galplay --ref）用：只给 SPIR-V 加循环上限（与我方同口径，不加越界钳位、不接计数收尾）；返回 malloc 的新码（nxgal_spv_free 放），无循环或失败返回 NULL
NXGAL_API uint32_t *nxgal_spv_loop_guard(const uint32_t *in, uint32_t nw, uint32_t *onw);
NXGAL_API uint32_t *nxgal_spv_harden(const uint32_t *in, uint32_t nw, uint32_t *onw);   // 直连三条链的越界保护（读钳位、越界写 / 原子不落；同一份 gal_spvx.m，#1204 T1）；不加循环上限；常量缓冲界长表按 NVN 槽（gal_ubo_len，见 gal_spvx.m 文件头 ①）
#define NXGAL_DIRECT_UBOLEN_N 14   // 直连常量缓冲界长表 gal_ubo_len 的长度：uint[NVN 统一缓冲槽 0..13] = 绑定的 vec4 个数（nvn_mtl.m 填）
NXGAL_API void nxgal_spv_free(void *p);
// 直连 XC（dsx_xc.c）：一支 SPIR-V → MSL（glsl = 0）/ GLSL 450（glsl = 1），*out 用 nxgal_dmsh_xc_free 释放
NXGAL_API int32_t nxgal_dmsh_xc(const void *spv, uint64_t len, int32_t glsl, char **out, char *err, uint64_t errlen);
NXGAL_API void nxgal_dmsh_xc_free(char *p);
NXGAL_API int32_t nxgal_dmsh_xc_tess(const void *spv, uint64_t len, int32_t vt, uint32_t base, char **out, uint32_t *flags, uint32_t *ocp, char *err, uint64_t errlen);   // gal_tessxc.c
NXGAL_API int32_t nxgal_dmsh_color_round(const char *msl, const char *entry, char **out, char *err, uint64_t errlen);   // gal_colorround.c
NXGAL_API int32_t nxgal_dmsh_spill(const char *src, uint32_t slot, char **out, uint32_t *bytes, char *err, uint64_t errlen);   // gal_spill.c
#ifdef __cplusplus
}
#endif
