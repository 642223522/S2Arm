// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 原创尺寸查询经过 Vulkan 后端，验证内部物理采样器和视图尺寸读回。
#include "nvn_backend.h"
#include "vk_device.h"
#include "nvn_plat_vk.h"
#include "rp_res.h"
#include "spirv_sampler_use.h"
#include "../sampler_use_fixtures.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static nvn_gpu_err err;
static unsigned validation_errors;
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s (%s)\n", __LINE__, #x, err.why); exit(1); } } while (0)
#define GPU(x) CHECK(nvn_gpu_ok(x))
const char *const *nvn_plat_vk_instance_exts(uint32_t *n) { static const char *ext[] = {VK_EXT_DEBUG_UTILS_EXTENSION_NAME}; *n = 1; return ext; }
VkResult nvn_plat_vk_surface_create(VkInstance i, void *w, VkSurfaceKHR *s) { (void)i; (void)w; *s = VK_NULL_HANDLE; return VK_ERROR_EXTENSION_NOT_PRESENT; }
int nvn_plat_window_size(void *w, uint32_t *x, uint32_t *y) { (void)w; (void)x; (void)y; return 0; }
void nvn_plat_safepoint(void) {}
int nvn_plat_flag(const char *name, int dflt) { (void)name; return dflt; }
void nvn_plat_log(int level, const char *cls, const char *s) { (void)level; fprintf(stderr, "[%s] %s\n", cls, s); }
static VKAPI_ATTR VkBool32 VKAPI_CALL validation(VkDebugUtilsMessageSeverityFlagBitsEXT severity,
    VkDebugUtilsMessageTypeFlagsEXT type, const VkDebugUtilsMessengerCallbackDataEXT *data, void *user) {
    (void)type; (void)user;
    if (severity & VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT) validation_errors++;
    fprintf(stderr, "VVL: %s\n", data->pMessage); return VK_FALSE;
}
static void done(void *user, const nvn_gpu_done *d) { (void)user; (void)d; }
static nvn_gpu_buf buffer(size_t n, const void *data) { nvn_gpu_buf b = NULL; GPU(nvn_gpu_buf_create(n, NVN_GPU_MEM_SHARED, data, &b, &err)); return b; }

int main(void) {
    char why[256] = "";
    uint32_t layer_count = 0; CHECK(vkEnumerateInstanceLayerProperties(&layer_count, NULL) == VK_SUCCESS);
    VkLayerProperties *layers = calloc(layer_count, sizeof *layers); CHECK(layers);
    CHECK(vkEnumerateInstanceLayerProperties(&layer_count, layers) == VK_SUCCESS); int has_validation = 0;
    for (uint32_t i = 0; i < layer_count; ++i) if (!strcmp(layers[i].layerName, "VK_LAYER_KHRONOS_validation")) has_validation = 1;
    free(layers); CHECK(has_validation);
    struct s2a_vk_device device; CHECK(!s2a_vk_device_create(&device, why, sizeof why));
    PFN_vkCreateDebugUtilsMessengerEXT create = (PFN_vkCreateDebugUtilsMessengerEXT)vkGetInstanceProcAddr(device.instance, "vkCreateDebugUtilsMessengerEXT");
    PFN_vkDestroyDebugUtilsMessengerEXT destroy = (PFN_vkDestroyDebugUtilsMessengerEXT)vkGetInstanceProcAddr(device.instance, "vkDestroyDebugUtilsMessengerEXT");
    CHECK(create && destroy); VkDebugUtilsMessengerEXT messenger;
    VkDebugUtilsMessengerCreateInfoEXT mi = {.sType = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
        .messageSeverity = VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT,
        .messageType = VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
        .pfnUserCallback = validation};
    CHECK(create(device.instance, &mi, NULL, &messenger) == VK_SUCCESS);
    nvn_gpu_open_desc od = {0}; od.host_device = &device; od.app_label = "compute-image-query"; GPU(nvn_gpu_open(&od, &err));
    const nvn_gpu_layout_ent ent[] = {
        {.set = 1, .binding = 0, .count = 1, .stages = 1u << NVN_GPU_SH_CS, .cls = NVN_GPU_RES_SSBO, .access = NVN_GPU_ACC_RW},
        {.set = 2, .binding = 0, .count = 1, .stages = 1u << NVN_GPU_SH_CS, .cls = NVN_GPU_RES_TEX_SAMP, .access = NVN_GPU_ACC_R},
    };
    nvn_gpu_layout layout = {.ent = ent, .nent = 2};
    nvn_gpu_shader_src ss = {.stage = NVN_GPU_SH_CS, .kind = NVN_GPU_BLOB_SPIRV, .blob = sampler_query_spv,
        .bytes = sizeof sampler_query_spv, .entry = "main", .layout = &layout};
    nvn_gpu_shader shader = NULL;
    GPU(nvn_gpu_shader_load(&ss, &shader, &err));
    nvn_gpu_stage_desc stage = {.sh = shader};
    nvn_gpu_pipe pipe = NULL;
    GPU(nvn_gpu_cpipe_get(&stage, NVN_GPU_PIPE_SYNC, &pipe, &err));
    CHECK(s2a_spirv_sampler_unused(sampler_query_spv, sizeof sampler_query_spv, 2, 0));
    nvn_gpu_samp samp = rp_sampler_for_query();
    CHECK(samp && samp == rp_sampler_for_query() && !rp_samp_by_id(0));
    for (unsigned round = 0; round < 2; ++round) {
        unsigned width = round ? 19 : 37; uint8_t sentinel[16]; memset(sentinel, 0xcc, sizeof sentinel);
        nvn_gpu_buf output = buffer(sizeof sentinel, sentinel);
        nvn_gpu_tex_desc td = {0};
        td.d.target = NVN_TEXTURE_TARGET_2D;
        td.d.format = NVN_FORMAT_RGBA8;
        td.d.width = getenv("S2A_IMAGE_QUERY_WRONG_VIEW") ? width + 1 : width;
        td.d.height = 11;
        td.d.depth = td.d.samples = td.d.levels = 1;
        td.usage = NVN_GPU_TEX_SAMPLED;
        nvn_gpu_tex tex = NULL;
        nvn_gpu_view view = NULL;
        GPU(nvn_gpu_tex_create(&td, &tex, &err));
        GPU(nvn_gpu_view_create(tex, NULL, &view, &err));
        const nvn_gpu_binding bindings[] = {
            {.ent = 0, .cls = NVN_GPU_RES_SSBO, .u.b = {.buf = output, .len = sizeof sentinel}},
            {.ent = 1, .cls = NVN_GPU_RES_TEX_SAMP, .u.ts = {.view = view, .samp = samp}},
        };
        nvn_gpu_cmd cmd = NULL;
        GPU(nvn_gpu_cmd_begin(NULL, &cmd, &err));
        nvn_gpu_set_pipe(cmd, pipe);
        nvn_gpu_bind(cmd, NVN_GPU_SH_CS, bindings, 2);
        nvn_gpu_dispatch(cmd, pipe, 1, 1, 1, NULL, 0);
        GPU(nvn_gpu_cmd_commit(cmd, round + 1, done, NULL, &err)); GPU(nvn_gpu_fence_wait(round + 1, 5000000000ull, &err));
        uint8_t *cpu = nvn_gpu_buf_cpu(output); CHECK(cpu); uint32_t actual; memcpy(&actual, cpu, 4);
        CHECK(actual == width); for (unsigned i = 4; i < sizeof sentinel; ++i) CHECK(cpu[i] == 0xcc);
        printf("TXQ width: expected %u -> actual %u; sentinel 12/12\n", width, actual);
        nvn_gpu_view_release(view); nvn_gpu_tex_release(tex); nvn_gpu_buf_release(output, NULL, NULL);
    }
    rp_res_reset();
    nvn_gpu_shader_release(shader); GPU(nvn_gpu_close(5000000000ull, &err));
    CHECK(!validation_errors); destroy(device.instance, messenger, NULL); CHECK(!s2a_vk_device_destroy(&device, 1));
    puts("PASS: synthetic shader, Vulkan readback, VVL errors 0");
    return 0;
}
