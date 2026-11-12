// Real Vulkan entry points and GPU readback, linked with the production host.
// Deliberately leave resources live: session retirement owns their destruction.
#define VK_NO_PROTOTYPES
#include <vulkan/vulkan_core.h>
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../../graphics_session.h"

void *dm_vk_lookup(const char *);

#define APIS(X) \
    X(vkCreateInstance) X(vkEnumeratePhysicalDevices) X(vkCreateDevice) X(vkGetDeviceQueue) \
    X(vkCreateBuffer) X(vkGetBufferMemoryRequirements) X(vkAllocateMemory) X(vkBindBufferMemory) X(vkMapMemory) \
    X(vkCreateImage) X(vkGetImageMemoryRequirements) X(vkBindImageMemory) \
    X(vkCreateCommandPool) X(vkAllocateCommandBuffers) X(vkBeginCommandBuffer) X(vkEndCommandBuffer) \
    X(vkCmdClearColorImage) X(vkCmdCopyImageToBuffer) X(vkQueueSubmit) X(vkQueueWaitIdle)
#define DECL(name) static PFN_##name name;
APIS(DECL)
#undef DECL
#define OK(call) assert((call) == VK_SUCCESS)

int s2a_test_vk_session_resources(unsigned rounds) {
    PFN_vkGetInstanceProcAddr get = (PFN_vkGetInstanceProcAddr)dm_vk_lookup("vkGetInstanceProcAddr");
    assert(get);
#define LOAD(name) name = (PFN_##name)get(VK_NULL_HANDLE, #name); assert(name);
    APIS(LOAD)
#undef LOAD
    for (unsigned round = 1; round <= rounds; round++) {
        assert(s2a_graphics_native_begin_session() == 0);
        VkInstance instance;
        VkInstanceCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
        OK(vkCreateInstance(&ici, NULL, &instance));
        uint32_t count = 1; VkPhysicalDevice physical;
        OK(vkEnumeratePhysicalDevices(instance, &count, &physical)); assert(count == 1);
        float priority = 1;
        VkDeviceQueueCreateInfo qci = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = 0, .queueCount = 1, .pQueuePriorities = &priority};
        VkDeviceCreateInfo dci = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci};
        VkDevice device; OK(vkCreateDevice(physical, &dci, NULL, &device));
        VkQueue queue; vkGetDeviceQueue(device, 0, 0, &queue); assert(queue);
        VkBufferCreateInfo bci = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = 32 * 32 * 4, .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT};
        VkBuffer buffer; OK(vkCreateBuffer(device, &bci, NULL, &buffer));
        VkMemoryRequirements req; vkGetBufferMemoryRequirements(device, buffer, &req);
        VkMemoryAllocateInfo mai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size, .memoryTypeIndex = 1};
        VkDeviceMemory bmem; OK(vkAllocateMemory(device, &mai, NULL, &bmem)); OK(vkBindBufferMemory(device, buffer, bmem, 0));
        uint8_t *pixels; OK(vkMapMemory(device, bmem, 0, 32 * 32 * 4, 0, (void **)&pixels));
        memset(pixels, 0xcd, 32 * 32 * 4);
        VkImageCreateInfo imci = {.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D,
            .format = VK_FORMAT_R8G8B8A8_UNORM, .extent = {32, 32, 1}, .mipLevels = 1, .arrayLayers = 1,
            .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
            .usage = VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT};
        VkImage image; OK(vkCreateImage(device, &imci, NULL, &image));
        vkGetImageMemoryRequirements(device, image, &req); mai.allocationSize = req.size; mai.memoryTypeIndex = 0;
        VkDeviceMemory imem; OK(vkAllocateMemory(device, &mai, NULL, &imem)); OK(vkBindImageMemory(device, image, imem, 0));
        VkCommandPoolCreateInfo pci = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = 0};
        VkCommandPool pool; OK(vkCreateCommandPool(device, &pci, NULL, &pool));
        VkCommandBufferAllocateInfo cai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool,
            .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1};
        VkCommandBuffer commands; OK(vkAllocateCommandBuffers(device, &cai, &commands));
        VkCommandBufferBeginInfo begin = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
        OK(vkBeginCommandBuffer(commands, &begin));
        int red = round & 1;
        VkClearColorValue clear = {.float32 = {red, 0, 1, 1}};
        VkImageSubresourceRange range = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
        vkCmdClearColorImage(commands, image, VK_IMAGE_LAYOUT_GENERAL, &clear, 1, &range);
        VkBufferImageCopy copy = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .imageExtent = {32, 32, 1}};
        vkCmdCopyImageToBuffer(commands, image, VK_IMAGE_LAYOUT_GENERAL, buffer, 1, &copy);
        OK(vkEndCommandBuffer(commands));
        VkSubmitInfo submit = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &commands};
        OK(vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE)); OK(vkQueueWaitIdle(queue));
        for (unsigned i = 0; i < 32 * 32 * 4; i += 4)
            assert(pixels[i] == red * 255 && !pixels[i + 1] && pixels[i + 2] == 255 && pixels[i + 3] == 255);
        assert(s2a_graphics_native_request_stop() == 0);
        assert(s2a_graphics_native_shutdown_session() == 0);
        fprintf(stderr, "[graphics-session] Vulkan %u/%u GPU clear/readback/retirement passed\n", round, rounds);
    }
    return 0;
}

// 块压缩贴图的上传（#542）：8×8 的 BC1，四个纯色块（红 绿 / 蓝 白），缓冲 → 图像 → 贴到 RGBA8 图 → 读回。
// 期望手算：BC1 纯色块 = 两个端点同色、索引全 0 → 整块就是端点色；565 的 31 / 63 展开成 255。
// 两种环境各跑一遍：DM_TEST_NO_BC=1（图像建成解压格式、上传时在 CPU 上解）做完整的上传 → 贴到 RGBA8 → 读回 → 对期望；
// 原生（显卡认 BC）只验上传照常执行——这一层没有把压缩图贴到普通图的实现，压缩图的像素读不回来。
static PFN_vkCmdCopyBufferToImage bc_CopyBufferToImage; static PFN_vkCmdBlitImage bc_BlitImage;
int s2a_test_vk_bc(void) {
    PFN_vkGetInstanceProcAddr get = (PFN_vkGetInstanceProcAddr)dm_vk_lookup("vkGetInstanceProcAddr");
    assert(get);
#define LOAD(name) name = (PFN_##name)get(VK_NULL_HANDLE, #name); assert(name);
    APIS(LOAD)
#undef LOAD
    bc_CopyBufferToImage = (PFN_vkCmdCopyBufferToImage)get(VK_NULL_HANDLE, "vkCmdCopyBufferToImage"); assert(bc_CopyBufferToImage);
    bc_BlitImage = (PFN_vkCmdBlitImage)get(VK_NULL_HANDLE, "vkCmdBlitImage"); assert(bc_BlitImage);
    assert(s2a_graphics_native_begin_session() == 0);
    VkInstance instance; VkInstanceCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
    OK(vkCreateInstance(&ici, NULL, &instance));
    uint32_t count = 1; VkPhysicalDevice physical; OK(vkEnumeratePhysicalDevices(instance, &count, &physical)); assert(count == 1);
    float priority = 1;
    VkDeviceQueueCreateInfo qci = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = 0, .queueCount = 1, .pQueuePriorities = &priority};
    VkDeviceCreateInfo dci = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci};
    VkDevice device; OK(vkCreateDevice(physical, &dci, NULL, &device));
    VkQueue queue; vkGetDeviceQueue(device, 0, 0, &queue); assert(queue);
    VkMemoryRequirements req; VkMemoryAllocateInfo mai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .memoryTypeIndex = 1};
    // 源缓冲：4 个 BC1 块，按块行排（每块行 2 块 × 8 字节）
    VkBufferCreateInfo bci = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = 32, .usage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT};
    VkBuffer src; OK(vkCreateBuffer(device, &bci, NULL, &src)); vkGetBufferMemoryRequirements(device, src, &req); mai.allocationSize = req.size;
    VkDeviceMemory smem; OK(vkAllocateMemory(device, &mai, NULL, &smem)); OK(vkBindBufferMemory(device, src, smem, 0));
    uint8_t *blocks; OK(vkMapMemory(device, smem, 0, 32, 0, (void **)&blocks));
    static const uint16_t end565[4] = {0xF800, 0x07E0, 0x001F, 0xFFFF};   // 红 绿 蓝 白
    for (int b = 0; b < 4; b++) { memcpy(blocks + b * 8, &end565[b], 2); memcpy(blocks + b * 8 + 2, &end565[b], 2); memset(blocks + b * 8 + 4, 0, 4); }
    // 读回缓冲
    bci.size = 8 * 8 * 4; bci.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT;
    VkBuffer dst; OK(vkCreateBuffer(device, &bci, NULL, &dst)); vkGetBufferMemoryRequirements(device, dst, &req); mai.allocationSize = req.size;
    VkDeviceMemory dmem; OK(vkAllocateMemory(device, &mai, NULL, &dmem)); OK(vkBindBufferMemory(device, dst, dmem, 0));
    uint8_t *px; OK(vkMapMemory(device, dmem, 0, 8 * 8 * 4, 0, (void **)&px)); memset(px, 0xcd, 8 * 8 * 4);
    VkImageCreateInfo imci = {.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D, .format = VK_FORMAT_BC1_RGBA_UNORM_BLOCK, .extent = {8, 8, 1},
        .mipLevels = 1, .arrayLayers = 1, .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT};
    VkImage bc; OK(vkCreateImage(device, &imci, NULL, &bc)); vkGetImageMemoryRequirements(device, bc, &req); mai.allocationSize = req.size; mai.memoryTypeIndex = 0;
    VkDeviceMemory m1; OK(vkAllocateMemory(device, &mai, NULL, &m1)); OK(vkBindImageMemory(device, bc, m1, 0));
    imci.format = VK_FORMAT_R8G8B8A8_UNORM; imci.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
    VkImage plain; OK(vkCreateImage(device, &imci, NULL, &plain)); vkGetImageMemoryRequirements(device, plain, &req); mai.allocationSize = req.size;
    VkDeviceMemory m2; OK(vkAllocateMemory(device, &mai, NULL, &m2)); OK(vkBindImageMemory(device, plain, m2, 0));
    VkCommandPoolCreateInfo pci = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = 0};
    VkCommandPool pool; OK(vkCreateCommandPool(device, &pci, NULL, &pool));
    VkCommandBufferAllocateInfo cai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1};
    VkCommandBuffer cb; OK(vkAllocateCommandBuffers(device, &cai, &cb));
    VkCommandBufferBeginInfo begin = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    OK(vkBeginCommandBuffer(cb, &begin));
    VkBufferImageCopy up = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .imageExtent = {8, 8, 1}};
    bc_CopyBufferToImage(cb, src, bc, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &up);
    const int nobc = getenv("DM_TEST_NO_BC") != NULL;
    if (nobc) {
    VkImageBlit bl = {.srcSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .srcOffsets = {{0, 0, 0}, {8, 8, 1}}, .dstSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .dstOffsets = {{0, 0, 0}, {8, 8, 1}}};
    bc_BlitImage(cb, bc, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, plain, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &bl, VK_FILTER_NEAREST);
    VkBufferImageCopy down = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .imageExtent = {8, 8, 1}};
    vkCmdCopyImageToBuffer(cb, plain, VK_IMAGE_LAYOUT_GENERAL, dst, 1, &down);
    }
    OK(vkEndCommandBuffer(cb));
    VkSubmitInfo submit = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb};
    OK(vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE)); OK(vkQueueWaitIdle(queue));
    static const uint8_t want[4][4] = {{255, 0, 0, 255}, {0, 255, 0, 255}, {0, 0, 255, 255}, {255, 255, 255, 255}};
    int bad = 0;
    for (int y = 0; nobc && y < 8; y++) for (int x = 0; x < 8; x++) { const uint8_t *p = px + (y * 8 + x) * 4, *w = want[(y / 4) * 2 + x / 4]; if (memcmp(p, w, 4)) { if (!bad++) fprintf(stderr, "[graphics-session] BC1 (%d,%d) = %u %u %u %u，期望 %u %u %u %u\n", x, y, p[0], p[1], p[2], p[3], w[0], w[1], w[2], w[3]); } }
    assert(s2a_graphics_native_request_stop() == 0);
    assert(s2a_graphics_native_shutdown_session() == 0);
    if (nobc) fprintf(stderr, "[graphics-session] Vulkan BC1 上传（DM_TEST_NO_BC：解压格式 + CPU 解码）%s：读回 64 个像素，不符 %d 个\n", bad ? "红" : "通过", bad);
    else fprintf(stderr, "[graphics-session] Vulkan BC1 上传（原生 BC）通过：上传命令执行完成（压缩图读不回像素，不比）\n");
    return bad ? 1 : 0;
}
