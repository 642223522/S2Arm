/* SPDX-License-Identifier: MIT (same as Mesa, which this file is compiled into) */
/* Copyright 2026 S2Arm contributors */
/*
 * VK_OHOS_surface + VK_KHR_swapchain for lavapipe on the OpenHarmony emulator.
 *
 * The emulator image has no system swapchain layer: its ICD (SwiftShader) implements VK_OHOS_surface
 * itself. lavapipe renders into host memory, so this is a CPU-copy WSI: swapchain images are ordinary
 * lavapipe images, and vkQueuePresentKHR waits for the frame, then copies it into a buffer requested
 * from the OHNativeWindow and flushes it.
 *
 * Mesa's registry does not know VK_OHOS_surface, so these entry points are interposed in front of the
 * generated dispatch, and the extension name is added to / removed from the lists the common code
 * validates. The surface handle uses the VkIcdSurfaceAndroid-like layout {VkIcdSurfaceBase; window}
 * so a loader-created OHOS surface reads the same.
 */
#include "lvp_private.h"
#include "vk_common_entrypoints.h"
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <poll.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <native_window/external_window.h>
#include <native_buffer/buffer_common.h>
#include <native_buffer/native_buffer.h>

#define S_SURFACE_CREATE_INFO_OHOS 1000685000
#define SURFACE_EXT "VK_OHOS_surface"
#define OHOS_PLATFORM 0x4F48 /* private VkIcdWsiPlatform value; only this ICD reads it */

struct ohos_surface { VkIcdSurfaceBase base; OHNativeWindow *window; };
struct ohos_surface_create_info { VkStructureType sType; const void *pNext; VkFlags flags; OHNativeWindow *window; };

struct ohos_swapchain {
   VkDevice device;
   OHNativeWindow *window;
   VkExtent2D extent;
   VkFormat format;
   uint32_t count, next;
   VkImage images[8];
   VkDeviceMemory memory[8];
};

PFN_vkVoidFunction lvp_ohos_proc(const char *name);

/* DEBUG_S2A_VA39=1 (emulator diagnostic): the OpenHarmony QEMU kernel has a 48-bit user address space,
 * HarmonyOS phones a 39-bit one. Guest-visible host memory (Horizon heaps, NVN objects) must sit below
 * 2^39, but with free space above it the kernel's top-down mmap hands out 0xffff... addresses. lavapipe
 * is loaded by the host before those allocations, so on load every gap above 2^39 is reserved
 * PROT_NONE/NORESERVE and later unhinted mappings land below. Kernels that do not know
 * MAP_FIXED_NOREPLACE treat the address as a hint: a mapping placed elsewhere is unmapped again. */
static void reserve_above_va39(void)
{
   const char *e = getenv("DEBUG_S2A_VA39");
   if (!e || strcmp(e, "1")) return;
   FILE *m = fopen("/proc/self/maps", "r");
   if (!m) return;
   static uint64_t lo[4096], hi[4096];
   unsigned n = 0;
   char line[512];
   while (n < 4096 && fgets(line, sizeof line, m)) {
      unsigned long long a, b;
      if (sscanf(line, "%llx-%llx", &a, &b) == 2) { lo[n] = a; hi[n] = b; n++; }
   }
   fclose(m);
   const uint64_t floor = 1ull << 39, ceil = 1ull << 48;
   uint64_t prev = floor, reserved = 0, foreign = 0;
   unsigned gaps = 0;
   for (unsigned i = 0; i <= n; i++) {
      uint64_t start = i < n ? lo[i] : ceil, end = i < n ? hi[i] : ceil;
      if (start > prev && start > floor) {
         uint64_t a = prev < floor ? floor : prev, len = start - a;
         if (len >= 4096) {
            void *p = mmap((void *)(uintptr_t)a, len, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE | 0x100000 /* MAP_FIXED_NOREPLACE */, -1, 0);
            if (p == (void *)(uintptr_t)a) { reserved += len; gaps++; }
            else if (p != MAP_FAILED) { munmap(p, len); foreign++; }
         }
      }
      if (end > prev) prev = end;
   }
   fprintf(stderr, "[lvp-ohos] DEBUG_S2A_VA39: reserved %u gaps above 2^39 (%llu GiB), %llu placed elsewhere and released\n",
           gaps, (unsigned long long)(reserved >> 30), (unsigned long long)foreign);
}
__attribute__((constructor)) static void lvp_ohos_init(void) { reserve_above_va39(); }

static void ohos_log(const char *what, int value)
{
   fprintf(stderr, "[lvp-ohos] %s %d\n", what, value);
}

/* ---- instance level ---- */

static VKAPI_ATTR VkResult VKAPI_CALL
ohos_EnumerateInstanceExtensionProperties(const char *layer, uint32_t *count, VkExtensionProperties *props)
{
   if (layer) return lvp_EnumerateInstanceExtensionProperties(layer, count, props);
   uint32_t n = 0;
   VkResult r = lvp_EnumerateInstanceExtensionProperties(NULL, &n, NULL);
   if (r != VK_SUCCESS) return r;
   if (!props) { *count = n + 1; return VK_SUCCESS; }
   uint32_t cap = *count, got = cap < n ? cap : n;
   r = lvp_EnumerateInstanceExtensionProperties(NULL, &got, props);
   if (r != VK_SUCCESS && r != VK_INCOMPLETE) return r;
   if (got < cap) {
      memset(&props[got], 0, sizeof props[got]);
      strcpy(props[got].extensionName, SURFACE_EXT);
      props[got].specVersion = 1;
      *count = got + 1;
      return VK_SUCCESS;
   }
   *count = got;
   return VK_INCOMPLETE;
}

static VKAPI_ATTR VkResult VKAPI_CALL
ohos_CreateInstance(const VkInstanceCreateInfo *info, const VkAllocationCallbacks *alloc, VkInstance *instance)
{
   const char *names[256];
   uint32_t n = 0;
   for (uint32_t i = 0; i < info->enabledExtensionCount && n < 256; i++)
      if (strcmp(info->ppEnabledExtensionNames[i], SURFACE_EXT)) names[n++] = info->ppEnabledExtensionNames[i];
   VkInstanceCreateInfo copy = *info;
   copy.enabledExtensionCount = n;
   copy.ppEnabledExtensionNames = names;
   return lvp_CreateInstance(&copy, alloc, instance);
}

static VKAPI_ATTR VkResult VKAPI_CALL
ohos_CreateSurfaceOHOS(VkInstance instance, const struct ohos_surface_create_info *info,
                       const VkAllocationCallbacks *alloc, VkSurfaceKHR *surface)
{
   (void)instance; (void)alloc;
   if (!info || !info->window) return VK_ERROR_INITIALIZATION_FAILED;
   struct ohos_surface *s = calloc(1, sizeof *s);
   if (!s) return VK_ERROR_OUT_OF_HOST_MEMORY;
   s->base.platform = (VkIcdWsiPlatform)OHOS_PLATFORM;
   s->window = info->window;
   *surface = (VkSurfaceKHR)(uintptr_t)s;
   return VK_SUCCESS;
}

static VKAPI_ATTR void VKAPI_CALL
ohos_DestroySurfaceKHR(VkInstance instance, VkSurfaceKHR surface, const VkAllocationCallbacks *alloc)
{
   (void)instance; (void)alloc;
   free((void *)(uintptr_t)surface);
}

static OHNativeWindow *surface_window(VkSurfaceKHR surface)
{
   struct ohos_surface *s = (struct ohos_surface *)(uintptr_t)surface;
   return s ? s->window : NULL;
}

static void window_size(OHNativeWindow *w, uint32_t *width, uint32_t *height)
{
   int32_t h = 0, wd = 0;
   if (OH_NativeWindow_NativeWindowHandleOpt(w, GET_BUFFER_GEOMETRY, &h, &wd) || wd <= 0 || h <= 0) { wd = 1280; h = 720; }
   *width = (uint32_t)wd; *height = (uint32_t)h;
}

static VKAPI_ATTR VkResult VKAPI_CALL
ohos_GetPhysicalDeviceSurfaceSupportKHR(VkPhysicalDevice pd, uint32_t family, VkSurfaceKHR surface, VkBool32 *supported)
{
   (void)pd; (void)family; (void)surface;
   *supported = VK_TRUE;
   return VK_SUCCESS;
}

static void fill_caps(VkSurfaceKHR surface, VkSurfaceCapabilitiesKHR *c)
{
   uint32_t w, h;
   window_size(surface_window(surface), &w, &h);
   memset(c, 0, sizeof *c);
   c->minImageCount = 2;
   c->maxImageCount = 8;
   c->currentExtent = (VkExtent2D){ w, h };
   c->minImageExtent = (VkExtent2D){ 1, 1 };
   c->maxImageExtent = (VkExtent2D){ 16384, 16384 };
   c->maxImageArrayLayers = 1;
   c->supportedTransforms = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;
   c->currentTransform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;
   c->supportedCompositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR | VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR;
   c->supportedUsageFlags = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT |
                            VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_STORAGE_BIT;
}

static VKAPI_ATTR VkResult VKAPI_CALL
ohos_GetPhysicalDeviceSurfaceCapabilitiesKHR(VkPhysicalDevice pd, VkSurfaceKHR surface, VkSurfaceCapabilitiesKHR *caps)
{
   (void)pd;
   fill_caps(surface, caps);
   return VK_SUCCESS;
}

static VKAPI_ATTR VkResult VKAPI_CALL
ohos_GetPhysicalDeviceSurfaceCapabilities2KHR(VkPhysicalDevice pd, const VkPhysicalDeviceSurfaceInfo2KHR *info,
                                              VkSurfaceCapabilities2KHR *caps)
{
   (void)pd;
   fill_caps(info->surface, &caps->surfaceCapabilities);
   return VK_SUCCESS;
}

static const VkSurfaceFormatKHR ohos_formats[] = {
   { VK_FORMAT_R8G8B8A8_UNORM, VK_COLOR_SPACE_SRGB_NONLINEAR_KHR },
   { VK_FORMAT_R8G8B8A8_SRGB, VK_COLOR_SPACE_SRGB_NONLINEAR_KHR },
};

static VKAPI_ATTR VkResult VKAPI_CALL
ohos_GetPhysicalDeviceSurfaceFormatsKHR(VkPhysicalDevice pd, VkSurfaceKHR surface, uint32_t *count, VkSurfaceFormatKHR *formats)
{
   (void)pd; (void)surface;
   const uint32_t n = sizeof ohos_formats / sizeof *ohos_formats;
   if (!formats) { *count = n; return VK_SUCCESS; }
   uint32_t k = *count < n ? *count : n;
   memcpy(formats, ohos_formats, k * sizeof *formats);
   *count = k;
   return k < n ? VK_INCOMPLETE : VK_SUCCESS;
}

static VKAPI_ATTR VkResult VKAPI_CALL
ohos_GetPhysicalDeviceSurfaceFormats2KHR(VkPhysicalDevice pd, const VkPhysicalDeviceSurfaceInfo2KHR *info, uint32_t *count,
                                         VkSurfaceFormat2KHR *formats)
{
   (void)pd; (void)info;
   const uint32_t n = sizeof ohos_formats / sizeof *ohos_formats;
   if (!formats) { *count = n; return VK_SUCCESS; }
   uint32_t k = *count < n ? *count : n;
   for (uint32_t i = 0; i < k; i++) formats[i].surfaceFormat = ohos_formats[i];
   *count = k;
   return k < n ? VK_INCOMPLETE : VK_SUCCESS;
}

static VKAPI_ATTR VkResult VKAPI_CALL
ohos_GetPhysicalDeviceSurfacePresentModesKHR(VkPhysicalDevice pd, VkSurfaceKHR surface, uint32_t *count, VkPresentModeKHR *modes)
{
   (void)pd; (void)surface;
   static const VkPresentModeKHR m[] = { VK_PRESENT_MODE_FIFO_KHR, VK_PRESENT_MODE_MAILBOX_KHR, VK_PRESENT_MODE_IMMEDIATE_KHR };
   const uint32_t n = 3;
   if (!modes) { *count = n; return VK_SUCCESS; }
   uint32_t k = *count < n ? *count : n;
   memcpy(modes, m, k * sizeof *modes);
   *count = k;
   return k < n ? VK_INCOMPLETE : VK_SUCCESS;
}


/* Built without Mesa WSI platforms, lavapipe advertises neither VK_KHR_swapchain nor knows it in its
 * device extension table: list it here (the loader only routes vkCreateSwapchainKHR to drivers that
 * report it) and keep it away from the common create-device validation. */
static VKAPI_ATTR VkResult VKAPI_CALL
ohos_EnumerateDeviceExtensionProperties(VkPhysicalDevice pd, const char *layer, uint32_t *count, VkExtensionProperties *props)
{
   if (layer) return vk_common_EnumerateDeviceExtensionProperties(pd, layer, count, props);
   uint32_t n = 0;
   VkResult r = vk_common_EnumerateDeviceExtensionProperties(pd, NULL, &n, NULL);
   if (r != VK_SUCCESS) return r;
   VkExtensionProperties *all = calloc(n + 1, sizeof *all);
   if (!all) return VK_ERROR_OUT_OF_HOST_MEMORY;
   r = vk_common_EnumerateDeviceExtensionProperties(pd, NULL, &n, all);
   int have = 0;
   for (uint32_t i = 0; i < n; i++) if (!strcmp(all[i].extensionName, VK_KHR_SWAPCHAIN_EXTENSION_NAME)) have = 1;
   if (!have) { strcpy(all[n].extensionName, VK_KHR_SWAPCHAIN_EXTENSION_NAME); all[n].specVersion = 70; n++; }
   if (!props) { *count = n; free(all); return VK_SUCCESS; }
   uint32_t k = *count < n ? *count : n;
   memcpy(props, all, k * sizeof *props);
   *count = k;
   free(all);
   return k < n ? VK_INCOMPLETE : VK_SUCCESS;
}

static VKAPI_ATTR VkResult VKAPI_CALL
ohos_CreateDevice(VkPhysicalDevice pd, const VkDeviceCreateInfo *info, const VkAllocationCallbacks *alloc, VkDevice *device)
{
   const char *names[256];
   uint32_t n = 0;
   for (uint32_t i = 0; i < info->enabledExtensionCount && n < 256; i++)
      if (strcmp(info->ppEnabledExtensionNames[i], VK_KHR_SWAPCHAIN_EXTENSION_NAME)) names[n++] = info->ppEnabledExtensionNames[i];
   VkDeviceCreateInfo copy = *info;
   copy.enabledExtensionCount = n;
   copy.ppEnabledExtensionNames = names;
   return lvp_CreateDevice(pd, &copy, alloc, device);
}

/* ---- device level ---- */

static VkResult submit_and_wait(VkDevice device, uint32_t wait_count, const VkSemaphore *waits,
                                VkSemaphore signal, VkFence fence, int wait_idle)
{
   VkQueue queue;
   vk_common_GetDeviceQueue(device, 0, 0, &queue);
   VkPipelineStageFlags stages[64];
   for (uint32_t i = 0; i < wait_count && i < 64; i++) stages[i] = VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
   VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .waitSemaphoreCount = wait_count, .pWaitSemaphores = waits,
                       .pWaitDstStageMask = stages, .signalSemaphoreCount = signal ? 1 : 0, .pSignalSemaphores = &signal };
   VkResult r = vk_common_QueueSubmit(queue, 1, &si, fence);
   if (r == VK_SUCCESS && wait_idle) r = vk_common_QueueWaitIdle(queue);
   return r;
}

static VKAPI_ATTR VkResult VKAPI_CALL
ohos_CreateSwapchainKHR(VkDevice device, const VkSwapchainCreateInfoKHR *info, const VkAllocationCallbacks *alloc, VkSwapchainKHR *out)
{
   struct ohos_swapchain *sc = calloc(1, sizeof *sc);
   if (!sc) return VK_ERROR_OUT_OF_HOST_MEMORY;
   sc->device = device;
   sc->window = surface_window(info->surface);
   sc->extent = info->imageExtent;
   sc->format = info->imageFormat;
   sc->count = info->minImageCount < 2 ? 2 : info->minImageCount > 8 ? 8 : info->minImageCount;
   OH_NativeWindow_NativeWindowHandleOpt(sc->window, SET_BUFFER_GEOMETRY, (int32_t)sc->extent.width, (int32_t)sc->extent.height);
   OH_NativeWindow_NativeWindowHandleOpt(sc->window, SET_FORMAT, (int32_t)NATIVEBUFFER_PIXEL_FMT_RGBA_8888);
   OH_NativeWindow_NativeWindowHandleOpt(sc->window, SET_USAGE,
      (uint64_t)(NATIVEBUFFER_USAGE_CPU_READ | NATIVEBUFFER_USAGE_CPU_WRITE | NATIVEBUFFER_USAGE_MEM_DMA));
   for (uint32_t i = 0; i < sc->count; i++) {
      VkImageCreateInfo ici = {
         .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .flags = info->flags & VK_SWAPCHAIN_CREATE_MUTABLE_FORMAT_BIT_KHR ? VK_IMAGE_CREATE_MUTABLE_FORMAT_BIT : 0,
         .imageType = VK_IMAGE_TYPE_2D, .format = info->imageFormat,
         .extent = { info->imageExtent.width, info->imageExtent.height, 1 }, .mipLevels = 1, .arrayLayers = 1,
         .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_LINEAR,
         .usage = info->imageUsage | VK_IMAGE_USAGE_TRANSFER_SRC_BIT, .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
         .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
      };
      VkResult r = lvp_CreateImage(device, &ici, alloc, &sc->images[i]);
      VkMemoryRequirements req;
      if (r == VK_SUCCESS) {
         lvp_GetImageMemoryRequirements(device, sc->images[i], &req);
         VkMemoryAllocateInfo ai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size, .memoryTypeIndex = 0 };
         r = lvp_AllocateMemory(device, &ai, alloc, &sc->memory[i]);
      }
      if (r == VK_SUCCESS) {
         VkBindImageMemoryInfo bi = { .sType = VK_STRUCTURE_TYPE_BIND_IMAGE_MEMORY_INFO, .image = sc->images[i], .memory = sc->memory[i] };
         r = lvp_BindImageMemory2(device, 1, &bi);
      }
      if (r != VK_SUCCESS) { ohos_log("swapchain image create failed", r); return r; }
   }
   ohos_log("swapchain images", (int)sc->count);
   *out = (VkSwapchainKHR)(uintptr_t)sc;
   return VK_SUCCESS;
}

static VKAPI_ATTR void VKAPI_CALL
ohos_DestroySwapchainKHR(VkDevice device, VkSwapchainKHR swapchain, const VkAllocationCallbacks *alloc)
{
   struct ohos_swapchain *sc = (struct ohos_swapchain *)(uintptr_t)swapchain;
   if (!sc) return;
   vk_common_DeviceWaitIdle(device);
   for (uint32_t i = 0; i < sc->count; i++) {
      if (sc->images[i]) lvp_DestroyImage(device, sc->images[i], alloc);
      if (sc->memory[i]) lvp_FreeMemory(device, sc->memory[i], alloc);
   }
   free(sc);
}

static VKAPI_ATTR VkResult VKAPI_CALL
ohos_GetSwapchainImagesKHR(VkDevice device, VkSwapchainKHR swapchain, uint32_t *count, VkImage *images)
{
   (void)device;
   struct ohos_swapchain *sc = (struct ohos_swapchain *)(uintptr_t)swapchain;
   if (!images) { *count = sc->count; return VK_SUCCESS; }
   uint32_t k = *count < sc->count ? *count : sc->count;
   memcpy(images, sc->images, k * sizeof *images);
   *count = k;
   return k < sc->count ? VK_INCOMPLETE : VK_SUCCESS;
}

static VkResult acquire(VkDevice device, VkSwapchainKHR swapchain, VkSemaphore semaphore, VkFence fence, uint32_t *index)
{
   struct ohos_swapchain *sc = (struct ohos_swapchain *)(uintptr_t)swapchain;
   *index = sc->next;
   sc->next = (sc->next + 1) % sc->count;
   if (!semaphore && !fence) return VK_SUCCESS;
   return submit_and_wait(device, 0, NULL, semaphore, fence, 0);
}

static VKAPI_ATTR VkResult VKAPI_CALL
ohos_AcquireNextImageKHR(VkDevice device, VkSwapchainKHR swapchain, uint64_t timeout, VkSemaphore semaphore, VkFence fence, uint32_t *index)
{
   (void)timeout;
   return acquire(device, swapchain, semaphore, fence, index);
}

static VKAPI_ATTR VkResult VKAPI_CALL
ohos_AcquireNextImage2KHR(VkDevice device, const VkAcquireNextImageInfoKHR *info, uint32_t *index)
{
   return acquire(device, info->swapchain, info->semaphore, info->fence, index);
}

static void wait_fd(int fd)
{
   if (fd < 0) return;
   struct pollfd p = { .fd = fd, .events = POLLIN };
   while (poll(&p, 1, 3000) < 0 && errno == EINTR) {}
   close(fd);
}

static int present_image(struct ohos_swapchain *sc, uint32_t index)
{
   VkDevice device = sc->device;
   OHNativeWindowBuffer *buffer = NULL;
   int fence = -1;
   int32_t rc = OH_NativeWindow_NativeWindowRequestBuffer(sc->window, &buffer, &fence);
   if (rc || !buffer) return rc ? rc : -1;
   wait_fd(fence);
   BufferHandle *h = OH_NativeWindow_GetBufferHandleFromNative(buffer);
   void *dst = h ? h->virAddr : NULL, *mapped = NULL;
   if (h && !dst && h->fd >= 0 && h->size > 0) {
      mapped = mmap(NULL, (size_t)h->size, PROT_READ | PROT_WRITE, MAP_SHARED, h->fd, 0);
      dst = mapped == MAP_FAILED ? NULL : mapped;
   }
   void *src = NULL;
   if (dst && vk_common_MapMemory(device, sc->memory[index], 0, VK_WHOLE_SIZE, 0, &src) == VK_SUCCESS) {
      VkImageSubresource sub = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0 };
      VkSubresourceLayout layout;
      lvp_GetImageSubresourceLayout(device, sc->images[index], &sub, &layout);
      uint32_t rows = (uint32_t)h->height < sc->extent.height ? (uint32_t)h->height : sc->extent.height;
      size_t bytes = (size_t)(h->width < (int32_t)sc->extent.width ? h->width : (int32_t)sc->extent.width) * 4;
      for (uint32_t y = 0; y < rows; y++)
         memcpy((uint8_t *)dst + (size_t)y * (size_t)h->stride, (uint8_t *)src + layout.offset + (size_t)y * layout.rowPitch, bytes);
      vk_common_UnmapMemory(device, sc->memory[index]);
   }
   if (mapped && mapped != MAP_FAILED) munmap(mapped, (size_t)h->size);
   Region region = { .rects = NULL, .rectNumber = 0 };
   return OH_NativeWindow_NativeWindowFlushBuffer(sc->window, buffer, -1, region);
}

static VKAPI_ATTR VkResult VKAPI_CALL
ohos_QueuePresentKHR(VkQueue queue, const VkPresentInfoKHR *info)
{
   LVP_FROM_HANDLE(lvp_queue, q, queue);
   VkDevice device = lvp_device_to_handle(q->device);
   VkResult r = submit_and_wait(device, info->waitSemaphoreCount, info->pWaitSemaphores, VK_NULL_HANDLE, VK_NULL_HANDLE, 1);
   static int presented;
   for (uint32_t i = 0; i < info->swapchainCount; i++) {
      struct ohos_swapchain *sc = (struct ohos_swapchain *)(uintptr_t)info->pSwapchains[i];
      int rc = r == VK_SUCCESS ? present_image(sc, info->pImageIndices[i]) : -1;
      if (rc) ohos_log("present failed", rc);
      else if (++presented <= 3 || presented % 300 == 0) ohos_log("presented frames", presented);
      if (info->pResults) info->pResults[i] = rc ? VK_ERROR_SURFACE_LOST_KHR : r;
   }
   return r;
}

static PFN_vkVoidFunction ohos_device_proc(const char *name)
{
#define E(n) if (!strcmp(name, "vk" #n)) return (PFN_vkVoidFunction)ohos_##n
   E(CreateSwapchainKHR); E(DestroySwapchainKHR); E(GetSwapchainImagesKHR);
   E(AcquireNextImageKHR); E(AcquireNextImage2KHR); E(QueuePresentKHR);
#undef E
   return NULL;
}

static VKAPI_ATTR PFN_vkVoidFunction VKAPI_CALL ohos_GetDeviceProcAddr(VkDevice device, const char *name)
{
   PFN_vkVoidFunction f = ohos_device_proc(name);
   return f ? f : vk_common_GetDeviceProcAddr(device, name);
}

PFN_vkVoidFunction lvp_ohos_proc(const char *name)
{
   if (!name) return NULL;
#define E(n) if (!strcmp(name, "vk" #n)) return (PFN_vkVoidFunction)ohos_##n
   E(EnumerateInstanceExtensionProperties); E(CreateInstance); E(CreateSurfaceOHOS); E(DestroySurfaceKHR);
   E(GetPhysicalDeviceSurfaceSupportKHR); E(GetPhysicalDeviceSurfaceCapabilitiesKHR); E(GetPhysicalDeviceSurfaceCapabilities2KHR);
   E(GetPhysicalDeviceSurfaceFormatsKHR); E(GetPhysicalDeviceSurfaceFormats2KHR); E(GetPhysicalDeviceSurfacePresentModesKHR);
   E(GetDeviceProcAddr); E(EnumerateDeviceExtensionProperties); E(CreateDevice);
#undef E
   return ohos_device_proc(name);
}
