// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Isolate the production sampler path from unrelated device/queue requirements.
#include S2A_SAMPLER_BACKEND

static unsigned messages, calls;
static float effective;
static VkBool32 enabled;

void nvn_plat_log(int level, const char *cls, const char *text) {
    (void)level;
    fprintf(stderr, "%s: %s\n", cls, text);
}

static VKAPI_ATTR VkBool32 VKAPI_CALL validation(VkDebugUtilsMessageSeverityFlagBitsEXT severity,
        VkDebugUtilsMessageTypeFlagsEXT type, const VkDebugUtilsMessengerCallbackDataEXT *data, void *user) {
    (void)severity; (void)type; (void)user;
    messages++;
    fprintf(stderr, "validation: %s\n", data->pMessage);
    return VK_FALSE;
}

VKAPI_ATTR VkResult VKAPI_CALL __real_vkCreateSampler(VkDevice device, const VkSamplerCreateInfo *ci,
        const VkAllocationCallbacks *alloc, VkSampler *sampler);
VKAPI_ATTR VkResult VKAPI_CALL __wrap_vkCreateSampler(VkDevice device, const VkSamplerCreateInfo *ci,
        const VkAllocationCallbacks *alloc, VkSampler *sampler) {
    if (calls++ == 0) { effective = ci->maxAnisotropy; enabled = ci->anisotropyEnable; }
    return __real_vkCreateSampler(device, ci, alloc, sampler);
}

#define REQUIRE(ok) do { if (!(ok)) { fprintf(stderr, "fixture failure: %s\n", #ok); return 2; } } while (0)

int main(void) {
    struct s2a_vk_device dev = {0};
    const char *layer = "VK_LAYER_KHRONOS_validation", *ext = VK_EXT_DEBUG_UTILS_EXTENSION_NAME;
    VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_1};
    VkDebugUtilsMessengerCreateInfoEXT debug = {
        .sType = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
        .messageSeverity = VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
        .messageType = VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
                       VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
        .pfnUserCallback = validation,
    };
    VkInstanceCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pNext = &debug,
        .pApplicationInfo = &app, .enabledLayerCount = 1, .ppEnabledLayerNames = &layer,
        .enabledExtensionCount = 1, .ppEnabledExtensionNames = &ext};
    REQUIRE(vkCreateInstance(&ici, NULL, &dev.instance) == VK_SUCCESS);
    PFN_vkCreateDebugUtilsMessengerEXT create_debug = (PFN_vkCreateDebugUtilsMessengerEXT)
        vkGetInstanceProcAddr(dev.instance, "vkCreateDebugUtilsMessengerEXT");
    PFN_vkDestroyDebugUtilsMessengerEXT destroy_debug = (PFN_vkDestroyDebugUtilsMessengerEXT)
        vkGetInstanceProcAddr(dev.instance, "vkDestroyDebugUtilsMessengerEXT");
    REQUIRE(create_debug && destroy_debug);
    VkDebugUtilsMessengerEXT messenger;
    REQUIRE(create_debug(dev.instance, &debug, NULL, &messenger) == VK_SUCCESS);
    uint32_t n = 1;
    REQUIRE(vkEnumeratePhysicalDevices(dev.instance, &n, &dev.physical) == VK_SUCCESS && n == 1);
    vkGetPhysicalDeviceProperties(dev.physical, &dev.properties);
    vkGetPhysicalDeviceFeatures(dev.physical, &dev.core_features);
    REQUIRE(dev.core_features.samplerAnisotropy);
    float priority = 1;
    VkDeviceQueueCreateInfo queue = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = 0, .queueCount = 1, .pQueuePriorities = &priority};
    VkPhysicalDeviceFeatures features = {.samplerAnisotropy = VK_TRUE};
    VkDeviceCreateInfo dci = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &queue, .pEnabledFeatures = &features};
    REQUIRE(vkCreateDevice(dev.physical, &dci, NULL, &dev.device) == VK_SUCCESS);
    g.dev = &dev; g.d = dev.device; g_open = 1;
    const float limit = dev.properties.limits.maxSamplerAnisotropy;
    REQUIRE(limit >= 2);
    printf("device=%s maxSamplerAnisotropy=%g\n", dev.properties.deviceName, limit);
    // Vulkan VUID-VkSamplerCreateInfo-anisotropyEnable-01071: [1, device limit].
    const float requests[] = {0, 1, 2, limit, limit * 2};
    const float expected[] = {1, 1, 2, limit, limit};
    unsigned bad = 0, cases = 0;
    for (unsigned i = 0; i < sizeof requests / sizeof requests[0]; i++) {
        samp_par p = {0}; p.aniso = requests[i];
        nvn_gpu_samp sampler = NULL;
        nvn_gpu_err err = {0};
        calls = 0; effective = -1; enabled = VK_FALSE;
        nvn_gpu_rc result = nvn_gpu_samp_create(&p, &sampler, &err);
        int ok = result.code == NVN_GPU_OK && sampler && calls == 2 && effective == expected[i] &&
                 enabled == (requests[i] > 1);
        printf("aniso request=%g expected=%g effective=%g calls=%u %s\n",
               requests[i], expected[i], effective, calls, ok ? "PASS" : "FAIL");
        bad += !ok;
        cases++;
        nvn_gpu_samp_release(sampler);
    }
    samp_par p = {0}; p.aniso = limit * 2;
    nvn_gpu_samp sampler = NULL;
    nvn_gpu_err err = {0};
    calls = 0;
    dev.core_features.samplerAnisotropy = VK_FALSE;
    int errors_ok = nvn_gpu_samp_create(&p, &sampler, &err).code == NVN_GPU_E_UNSUPPORTED && !sampler;
    errors_ok &= nvn_gpu_samp_create(NULL, &sampler, &err).code == NVN_GPU_E_ARG && !sampler;
    errors_ok &= nvn_gpu_samp_create(&p, NULL, &err).code == NVN_GPU_E_ARG;
    cases += 3;
    errors_ok &= calls == 0;
    bad += !errors_ok;
    printf("aniso unsupported/null-params/null-out calls=%u %s\n", calls, errors_ok ? "PASS" : "FAIL");
    g_open = 0;
    vkDestroyDevice(dev.device, NULL);
    destroy_debug(dev.instance, messenger, NULL);
    vkDestroyInstance(dev.instance, NULL);
    printf("aniso-clamp cases=%u failures=%u validation-messages=%u\n", cases, bad, messages);
    return bad || messages ? 1 : 0;
}
