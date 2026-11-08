// 直连 XC（11-08 从 gal_prog.m 原样搬来，拆苹果端通用渲染器第一步：直连翻译段独立成 libdsx）：只用 SPIRV-Cross C 接口与 libc，不引 Metal / ObjC。
//   NXGAL_NO_XC 可整体关掉（同 gal_tessxc.c）
#include "dsx_abi.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#if !defined(NXGAL_NO_XC)
#include "spirv_cross_c.h"
static void xc_err_cb(void *ud, const char *msg) { snprintf((char *)ud, 512, "%s", msg); }   // 同 gal_prog.m / gal_tessxc.c 的静态副本
#endif

// 直连兜底现编（graphics/tools/direct/dsh，S2A.Dsh 的设备后端）：一支 SPIR-V 照直连离线链 dmsh_build.py 的 XC 出 MSL——
//   spirv-cross --msl --msl-version 30100 --msl-argument-buffers --msl-texture-buffer-native --msl-pad-fragment-output，其余全取 SPIRV-Cross 缺省（平台 macOS：离线链的 iOS 库也是这份 MSL 编的）；
//   glsl = 1 出 GLSL 450（spirv-cross <spv> --version 450，gs_slice 只拿它认几何着色器形状）。不加固、不改名、不改绑定，与本文件 xc_shader1 的渲染器口径无关。
// 线程安全（每次自建上下文，不碰全局）。返回 0 成功、*out 为 malloc 的文本（调用方 free，或 nxgal_dmsh_xc_free）；非 0 失败、err 写原因（截到 errlen）
NXGAL_API int32_t nxgal_dmsh_xc(const void *spv, uint64_t len, int32_t glsl, char **out, char *err, uint64_t errlen) {
    *out = NULL; if (errlen) err[0] = 0;
#if !defined(NXGAL_NO_XC)
    if (len < 20 || (len & 3) || *(const uint32_t *)spv != 0x07230203) { snprintf(err, errlen, "不是 SPIR-V（长 %llu）", (unsigned long long)len); return 1; }
    spvc_context ctx = NULL; char cberr[512] = ""; int rc = 1;
    if (spvc_context_create(&ctx) != SPVC_SUCCESS) { snprintf(err, errlen, "SPIRV-Cross 上下文建不出"); return 1; }
    spvc_context_set_error_callback(ctx, xc_err_cb, cberr);
    spvc_parsed_ir ir = NULL; spvc_compiler c = NULL; spvc_compiler_options o = NULL; const char *src = NULL;
    if (spvc_context_parse_spirv(ctx, (const SpvId *)spv, (size_t)(len / 4), &ir) != SPVC_SUCCESS) { snprintf(err, errlen, "SPIRV-Cross 解析失败：%s", cberr); goto out; }
    if (spvc_context_create_compiler(ctx, glsl ? SPVC_BACKEND_GLSL : SPVC_BACKEND_MSL, ir, SPVC_CAPTURE_MODE_TAKE_OWNERSHIP, &c) != SPVC_SUCCESS) { snprintf(err, errlen, "SPIRV-Cross 建编译器失败：%s", cberr); goto out; }
    spvc_compiler_create_compiler_options(c, &o);
    if (glsl) {
        spvc_compiler_options_set_uint(o, SPVC_COMPILER_OPTION_GLSL_VERSION, 450);
        spvc_compiler_options_set_bool(o, SPVC_COMPILER_OPTION_GLSL_ES, SPVC_FALSE);
    } else {
        spvc_compiler_options_set_uint(o, SPVC_COMPILER_OPTION_MSL_PLATFORM, SPVC_MSL_PLATFORM_MACOS);
        spvc_compiler_options_set_uint(o, SPVC_COMPILER_OPTION_MSL_VERSION, 30100);
        spvc_compiler_options_set_bool(o, SPVC_COMPILER_OPTION_MSL_ARGUMENT_BUFFERS, SPVC_TRUE);
        spvc_compiler_options_set_bool(o, SPVC_COMPILER_OPTION_MSL_TEXTURE_BUFFER_NATIVE, SPVC_TRUE);
        spvc_compiler_options_set_bool(o, SPVC_COMPILER_OPTION_MSL_PAD_FRAGMENT_OUTPUT_COMPONENTS, SPVC_TRUE);
    }
    spvc_compiler_install_compiler_options(c, o);
    if (spvc_compiler_compile(c, &src) != SPVC_SUCCESS || !src) { snprintf(err, errlen, "SPIRV-Cross 编译失败：%s", cberr); goto out; }
    *out = strdup(src); rc = *out ? 0 : 1;
    if (rc) snprintf(err, errlen, "内存不足");
out:
    spvc_context_destroy(ctx);
    return rc;
#else
    (void)spv; (void)len; (void)glsl; snprintf(err, errlen, "本构建没有 SPIRV-Cross（NXGAL_NO_XC）"); return 1;
#endif
}
NXGAL_API void nxgal_dmsh_xc_free(char *p) { free(p); }
