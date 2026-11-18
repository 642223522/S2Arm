// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// Emulator smoke probe, run inside a HAP process: exec memory, guest window reservation,
// shared alias, Vulkan clear + readback.
#define _GNU_SOURCE
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>
#include <vulkan/vulkan.h>
#ifndef MAP_FIXED_NOREPLACE
#define MAP_FIXED_NOREPLACE 0x100000
#endif

static int fails;
#define CHECK(c, ...) do { if (c) { printf("OK   "); } else { printf("FAIL "); fails++; } printf(__VA_ARGS__); printf("\n"); } while (0)

static void exec_probe(void) {
    uint32_t *pg = mmap(NULL, 0x4000, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (pg == MAP_FAILED) { CHECK(0, "exec: mmap errno %d", errno); return; }
    pg[0] = 0x52800540; // mov w0, #42
    pg[1] = 0xd65f03c0; // ret
    __builtin___clear_cache((char *)pg, (char *)pg + 8);
    if (mprotect(pg, 0x4000, PROT_READ | PROT_EXEC)) { CHECK(0, "exec: mprotect RX errno %d (%s)", errno, strerror(errno)); return; }
    int r = ((int (*)(void))pg)();
    CHECK(r == 42, "exec: anon RW->RX page ran, returned %d", r);
    // Re-write after exec (rewriter patching pattern): RX -> RW -> RX
    int w = mprotect(pg, 0x4000, PROT_READ | PROT_WRITE);
    CHECK(w == 0, "exec: RX->RW again %s", w ? strerror(errno) : "ok");
    if (!w) {
        pg[0] = 0x52800560; // mov w0,#43
        __builtin___clear_cache((char *)pg, (char *)pg + 8);
        int x = mprotect(pg, 0x4000, PROT_READ | PROT_EXEC);
        CHECK(x == 0 && ((int (*)(void))pg)() == 43, "exec: second RW->RX %s", x ? strerror(errno) : "ok");
    }
    // Shared file-backed RX alias (memfd), as a loader might map code
    int fd = (int)syscall(SYS_memfd_create, "s2a_code", 0);
    if (fd < 0) { CHECK(0, "exec: memfd_create errno %d", errno); return; }
    ftruncate(fd, 0x4000);
    uint32_t *w2 = mmap(NULL, 0x4000, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    uint32_t *x2 = mmap(NULL, 0x4000, PROT_READ | PROT_EXEC, MAP_SHARED, fd, 0);
    if (w2 == MAP_FAILED || x2 == MAP_FAILED) { CHECK(0, "exec: memfd dual map W %p X %p errno %d", (void *)w2, (void *)x2, errno); return; }
    w2[0] = 0x528005a0; w2[1] = 0xd65f03c0; // mov w0,#45; ret
    __builtin___clear_cache((char *)x2, (char *)x2 + 8);
    CHECK(((int (*)(void))x2)() == 45, "exec: memfd W/X dual mapping runs");
}

// The guest window needs 64 GiB below 2^39. App processes already have mappings there, so
// look for a gap in /proc/self/maps and reserve it with MAP_FIXED_NOREPLACE, as a host would.
static void mem_probe(void) {
    const uint64_t sz = 64ull << 30, top = 1ull << 39, align = 1ull << 32;
    uint64_t prev_end = align, best = 0;
    FILE *m = fopen("/proc/self/maps", "r");
    char line[512];
    while (m && !best && fgets(line, sizeof line, m)) {
        unsigned long long lo, hi;
        if (sscanf(line, "%llx-%llx", &lo, &hi) != 2) continue;
        uint64_t start = (prev_end + align - 1) & ~(align - 1);
        if (lo > start && lo - start >= sz && start + sz <= top) best = start;
        if (hi > prev_end) prev_end = hi;
    }
    if (m) fclose(m);
    if (!best && ((prev_end + align - 1) & ~(align - 1)) + sz <= top) best = (prev_end + align - 1) & ~(align - 1);
    CHECK(best != 0, "mem: 64 GiB gap below 2^39 in /proc/self/maps at %#llx", (unsigned long long)best);
    if (best) {
        void *p = mmap((void *)best, sz, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE | MAP_FIXED_NOREPLACE, -1, 0);
        CHECK(p == (void *)best, "mem: reserve 64 GiB there with MAP_FIXED_NOREPLACE -> %p %s", p, p == MAP_FAILED ? strerror(errno) : "");
        if (p != MAP_FAILED) munmap(p, sz);
    }
    int fd = (int)syscall(SYS_memfd_create, "s2a_alias", 0);
    char *a = MAP_FAILED, *b = MAP_FAILED;
    if (fd >= 0 && ftruncate(fd, 1 << 20) == 0) a = mmap(NULL, 1 << 20, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (a != MAP_FAILED) b = mremap(a, 0, 1 << 20, MREMAP_MAYMOVE);
    if (b != MAP_FAILED) a[123] = 7;
    CHECK(b != MAP_FAILED && b[123] == 7, "mem: shared alias via mremap(old_size=0) %s", b == MAP_FAILED ? strerror(errno) : "");
    printf("INFO page size %ld\n", sysconf(_SC_PAGESIZE));
}

static uint32_t find_mem(VkPhysicalDevice pd, uint32_t bits, VkMemoryPropertyFlags want) {
    VkPhysicalDeviceMemoryProperties mp; vkGetPhysicalDeviceMemoryProperties(pd, &mp);
    for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
        if ((bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want) return i;
    return UINT32_MAX;
}

static void vk_probe(void) {
    uint32_t ver = 0; vkEnumerateInstanceVersion(&ver);
    printf("INFO loader version %u.%u.%u\n", VK_VERSION_MAJOR(ver), VK_VERSION_MINOR(ver), VK_VERSION_PATCH(ver));
    uint32_t ne = 0; vkEnumerateInstanceExtensionProperties(NULL, &ne, NULL);
    VkExtensionProperties *ie = calloc(ne, sizeof *ie); vkEnumerateInstanceExtensionProperties(NULL, &ne, ie);
    printf("INFO instance extensions:");
    for (uint32_t i = 0; i < ne; i++) printf(" %s", ie[i].extensionName);
    printf("\n");
    VkApplicationInfo app = {.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "s2a-ohos-probe", .apiVersion = VK_API_VERSION_1_1};
    VkInstanceCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app};
    VkInstance inst; VkResult r = vkCreateInstance(&ici, NULL, &inst);
    CHECK(r == VK_SUCCESS, "vk: create instance (1.1) r=%d", r);
    if (r) return;
    uint32_t n = 0; vkEnumeratePhysicalDevices(inst, &n, NULL);
    CHECK(n > 0, "vk: %u physical device(s)", n);
    if (!n) return;
    VkPhysicalDevice pd; n = 1; vkEnumeratePhysicalDevices(inst, &n, &pd);
    VkPhysicalDeviceProperties pp; vkGetPhysicalDeviceProperties(pd, &pp);
    VkPhysicalDeviceFeatures pf; vkGetPhysicalDeviceFeatures(pd, &pf);
    printf("INFO device '%s' api %u.%u.%u vendor %#x\n", pp.deviceName, VK_VERSION_MAJOR(pp.apiVersion), VK_VERSION_MINOR(pp.apiVersion), VK_VERSION_PATCH(pp.apiVersion), pp.vendorID);
    printf("INFO features BC=%d geometryShader=%d tessellation=%d shaderFloat64=%d multiViewport=%d depthClamp=%d logicOp=%d\n",
           pf.textureCompressionBC, pf.geometryShader, pf.tessellationShader, pf.shaderFloat64, pf.multiViewport, pf.depthClamp, pf.logicOp);
    uint32_t nd = 0; vkEnumerateDeviceExtensionProperties(pd, NULL, &nd, NULL);
    VkExtensionProperties *de = calloc(nd, sizeof *de); vkEnumerateDeviceExtensionProperties(pd, NULL, &nd, de);
    printf("INFO %u device extensions:", nd);
    for (uint32_t i = 0; i < nd; i++) printf(" %s", de[i].extensionName);
    printf("\n");
    float prio = 1;
    VkDeviceQueueCreateInfo qci = {.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = 0, .queueCount = 1, .pQueuePriorities = &prio};
    VkDeviceCreateInfo dci = {.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci};
    VkDevice dev; r = vkCreateDevice(pd, &dci, NULL, &dev);
    CHECK(r == VK_SUCCESS, "vk: create device r=%d", r);
    if (r) return;
    VkQueue q; vkGetDeviceQueue(dev, 0, 0, &q);
    const uint32_t W = 64, H = 64;
    VkImageCreateInfo imci = {.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D, .format = VK_FORMAT_R8G8B8A8_UNORM,
        .extent = {W, H, 1}, .mipLevels = 1, .arrayLayers = 1, .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT, .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED};
    VkImage img; vkCreateImage(dev, &imci, NULL, &img);
    VkMemoryRequirements mr; vkGetImageMemoryRequirements(dev, img, &mr);
    VkMemoryAllocateInfo mai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = mr.size, .memoryTypeIndex = find_mem(pd, mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT)};
    VkDeviceMemory im; vkAllocateMemory(dev, &mai, NULL, &im); vkBindImageMemory(dev, img, im, 0);
    VkBufferCreateInfo bci = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = W * H * 4, .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT};
    VkBuffer buf; vkCreateBuffer(dev, &bci, NULL, &buf);
    vkGetBufferMemoryRequirements(dev, buf, &mr);
    mai.allocationSize = mr.size; mai.memoryTypeIndex = find_mem(pd, mr.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
    VkDeviceMemory bm; vkAllocateMemory(dev, &mai, NULL, &bm); vkBindBufferMemory(dev, buf, bm, 0);
    VkCommandPoolCreateInfo cpci = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = 0};
    VkCommandPool pool; vkCreateCommandPool(dev, &cpci, NULL, &pool);
    VkCommandBufferAllocateInfo cbai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1};
    VkCommandBuffer cb; vkAllocateCommandBuffers(dev, &cbai, &cb);
    VkCommandBufferBeginInfo cbbi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    vkBeginCommandBuffer(cb, &cbbi);
    VkImageSubresourceRange rng = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    VkImageMemoryBarrier b1 = {.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER, .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        .newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .image = img, .subresourceRange = rng};
    vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &b1);
    VkClearColorValue cc = {.float32 = {1.0f, 0.0f, 1.0f, 1.0f}};
    vkCmdClearColorImage(cb, img, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &cc, 1, &rng);
    VkImageMemoryBarrier b2 = b1; b2.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT; b2.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
    b2.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL; b2.newLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    vkCmdPipelineBarrier(cb, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &b2);
    VkBufferImageCopy cp = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .imageExtent = {W, H, 1}};
    vkCmdCopyImageToBuffer(cb, img, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, buf, 1, &cp);
    vkEndCommandBuffer(cb);
    VkFenceCreateInfo fci = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
    VkFence f; vkCreateFence(dev, &fci, NULL, &f);
    VkSubmitInfo si = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb};
    r = vkQueueSubmit(q, 1, &si, f);
    VkResult wr = vkWaitForFences(dev, 1, &f, VK_TRUE, 5000000000ull);
    uint32_t *px = NULL; vkMapMemory(dev, bm, 0, VK_WHOLE_SIZE, 0, (void **)&px);
    uint32_t good = 0;
    for (uint32_t i = 0; i < W * H; i++) good += px && px[i] == 0xffff00ffu;
    CHECK(r == 0 && wr == 0 && good == W * H, "vk: clear 64x64 magenta + readback (%u/%u px, first %#x)", good, W * H, px ? px[0] : 0);
    vkDeviceWaitIdle(dev);
    vkDestroyDevice(dev, NULL);
    vkDestroyInstance(inst, NULL);
}

int probe_native(void) {
    fails = 0;
    exec_probe();
    mem_probe();
    vk_probe();
    printf("NATIVE DONE fails=%d\n", fails);
    fflush(stdout);
    return fails;
}
