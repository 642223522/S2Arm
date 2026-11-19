// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
//
// FSR1 EASU local spike: synthetic 1280x720 -> 2133x1200, EASU compute vs CPU bilinear.
// Isolated on purpose: raw Vulkan only, no nvn_gpu backend, no present path.
// Run via: bash android/tests/vk/run.sh --fsr
//
// Metric definition (both images measured identically):
//   luma Y = (299R + 587G + 114B) / 1000, on the 0..255 byte scale.
//   MAG (mean absolute gradient) = mean of (|Y(x+1,y)-Y(x,y)| + |Y(x,y+1)-Y(x,y)|) / 2.
//   MAG_global: every interior output pixel.
//   MAG_edge:   only output pixels whose 2x2 neighbourhood is all flagged as edge by the
//               SOURCE image (source local gradient >= 24/255). Same mask for both
//               images, so the comparison is like-for-like. This is the gated metric.
//
// Bilinear reference convention (matches EASU's con0 mapping, i.e. pixel centres):
//   src = (dst + 0.5) * (srcSize / dstSize) - 0.5, clamped to the source edge.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <math.h>
#include <vulkan/vulkan.h>

#define SRC_W 1280
#define SRC_H 720
#define DST_W 2133
#define DST_H 1200
#define EDGE_THRESH 24.0f
#define RATIO_GATE 1.2

static void die(const char *what, VkResult r) {
    fprintf(stderr, "【红】%s failed: %d\n", what, (int)r);
    exit(1);
}
#define VKTRY(call) do { VkResult r_ = (call); if (r_ != VK_SUCCESS) die(#call, r_); } while (0)

// ---------------------------------------------------------------- validation counter
static uint32_t g_val_err, g_val_warn;
static VKAPI_ATTR VkBool32 VKAPI_CALL dbg_cb(VkDebugUtilsMessageSeverityFlagBitsEXT sev,
                                             VkDebugUtilsMessageTypeFlagsEXT types,
                                             const VkDebugUtilsMessengerCallbackDataEXT *data,
                                             void *user) {
    (void)types; (void)user;
    if (sev & VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT) g_val_err++;
    else if (sev & VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT) g_val_warn++;
    // Returning FALSE lets the layer's own stderr reporting still print the message.
    (void)data;
    return VK_FALSE;
}

// ---------------------------------------------------------------- device helpers
static uint32_t mem_type(VkPhysicalDevice pd, uint32_t bits, VkMemoryPropertyFlags want) {
    VkPhysicalDeviceMemoryProperties mp;
    vkGetPhysicalDeviceMemoryProperties(pd, &mp);
    for (uint32_t i = 0; i < mp.memoryTypeCount; i++)
        if ((bits & (1u << i)) && (mp.memoryTypes[i].propertyFlags & want) == want) return i;
    fprintf(stderr, "【红】no memory type for bits=%u props=%u\n", bits, want);
    exit(1);
}

typedef struct { VkBuffer buf; VkDeviceMemory mem; void *map; VkDeviceSize size; } Buf;
static Buf mk_buf(VkDevice d, VkPhysicalDevice pd, VkDeviceSize size, VkBufferUsageFlags use) {
    Buf b; b.size = size;
    VkBufferCreateInfo bi = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size,
                              .usage = use, .sharingMode = VK_SHARING_MODE_EXCLUSIVE };
    VKTRY(vkCreateBuffer(d, &bi, NULL, &b.buf));
    VkMemoryRequirements mr; vkGetBufferMemoryRequirements(d, b.buf, &mr);
    VkMemoryAllocateInfo ai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = mr.size,
        .memoryTypeIndex = mem_type(pd, mr.memoryTypeBits,
            VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) };
    VKTRY(vkAllocateMemory(d, &ai, NULL, &b.mem));
    VKTRY(vkBindBufferMemory(d, b.buf, b.mem, 0));
    VKTRY(vkMapMemory(d, b.mem, 0, size, 0, &b.map));
    return b;
}

typedef struct { VkImage img; VkDeviceMemory mem; VkImageView view; int w, h; VkFormat fmt; } Img;
static Img mk_img(VkDevice d, VkPhysicalDevice pd, int w, int h, VkFormat fmt,
                  VkImageUsageFlags use, VkImageAspectFlags aspect) {
    Img im; im.w = w; im.h = h; im.fmt = fmt;
    VkImageCreateInfo ii = { .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .imageType = VK_IMAGE_TYPE_2D, .format = fmt,
        .extent = { (uint32_t)w, (uint32_t)h, 1 }, .mipLevels = 1, .arrayLayers = 1,
        .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = use, .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED };
    VKTRY(vkCreateImage(d, &ii, NULL, &im.img));
    VkMemoryRequirements mr; vkGetImageMemoryRequirements(d, im.img, &mr);
    VkMemoryAllocateInfo ai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = mr.size,
        .memoryTypeIndex = mem_type(pd, mr.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) };
    VKTRY(vkAllocateMemory(d, &ai, NULL, &im.mem));
    VKTRY(vkBindImageMemory(d, im.img, im.mem, 0));
    VkImageViewCreateInfo vi = { .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = im.img, .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = fmt,
        .subresourceRange = { aspect, 0, 1, 0, 1 } };
    VKTRY(vkCreateImageView(d, &vi, NULL, &im.view));
    return im;
}

static void barrier(VkCommandBuffer c, VkImage img, VkImageLayout from, VkImageLayout to,
                    VkPipelineStageFlags src, VkPipelineStageFlags dst,
                    VkAccessFlags sa, VkAccessFlags da) {
    VkImageMemoryBarrier b = { .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = sa, .dstAccessMask = da,
        .oldLayout = from, .newLayout = to,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = img,
        .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 } };
    vkCmdPipelineBarrier(c, src, dst, 0, 0, NULL, 0, NULL, 1, &b);
}

// ---------------------------------------------------------------- synthetic source
// Bands (y down): A checkerboard, B diagonals at three slopes, C gradient + isolated
// vertical edge + solid patch, D text-like thin strokes. No random noise: FSR is not
// meant to sharpen noise, and noise would hide the edge behaviour under test.
#define PATCH_X0 900
#define PATCH_Y0 360
#define VEDGE_X 770
static void synth(uint8_t *px) {
    for (int y = 0; y < SRC_H; y++) {
        for (int x = 0; x < SRC_W; x++) {
            uint8_t r, g, b;
            if (y < 180) {
                uint8_t v = (((x / 16) + (y / 16)) & 1) ? 255 : 0;
                r = g = b = v;
            } else if (y < 360) {
                int yy = y - 180, sub = yy / 60;
                int t = (sub == 0) ? (x + yy) : (sub == 1) ? (x + 2 * yy) : (x + yy / 2);
                uint8_t v = ((t / 24) & 1) ? 240 : 15;
                r = g = b = v;
            } else if (y < 540) {
                if (x < 640) {
                    uint8_t v = (uint8_t)(x * 255 / 639);
                    r = g = b = v;
                } else if (x < PATCH_X0) {
                    uint8_t v = (x >= VEDGE_X) ? 230 : 20;
                    r = g = b = v;
                } else {
                    r = 200; g = 90; b = 40;
                }
            } else {
                int cx = x - 40, cy = y - 560;
                int on = 0;
                if (cx >= 0 && cy >= 0 && cx < 1200 && cy < 140) {
                    int gx = cx / 20, gy = cy / 28;
                    int lx = cx % 20, ly = cy % 28;
                    on = (((lx >= 2 && lx <= 3) || (lx >= 10 && lx <= 11)) && ly >= 2 && ly <= 25);
                    if (((ly >= 4 && ly <= 5) || (ly >= 14 && ly <= 15) || (ly >= 24 && ly <= 25))
                        && lx >= 2 && lx <= 15) on = 1;
                    if (((gx * 7 + gy * 13) % 5) == 0)
                        on = (lx >= 4 && lx <= 13 && ly >= 6 && ly <= 21);
                }
                uint8_t v = on ? 245 : 12;
                r = g = b = v;
            }
            uint8_t *p = px + ((size_t)y * SRC_W + x) * 4;
            p[0] = r; p[1] = g; p[2] = b; p[3] = 255;
        }
    }
}

// ---------------------------------------------------------------- EASU constants
// Port of ffxFsrPopulateEasuConstants (AMD MIT). Viewport == resource size here.
typedef struct { float con[4][4]; uint32_t out[2]; } EasuCon;
_Static_assert(sizeof(EasuCon) == 72, "push constant layout must match the shader");
static EasuCon easu_con(int inW, int inH, int outW, int outH) {
    EasuCon c;
    float iw = (float)inW, ih = (float)inH, ow = (float)outW, oh = (float)outH;
    c.con[0][0] = iw / ow;
    c.con[0][1] = ih / oh;
    c.con[0][2] = 0.5f * iw / ow - 0.5f;
    c.con[0][3] = 0.5f * ih / oh - 0.5f;
    c.con[1][0] = 1.0f / iw;
    c.con[1][1] = 1.0f / ih;
    c.con[1][2] = 1.0f / iw;
    c.con[1][3] = -1.0f / ih;
    c.con[2][0] = -1.0f / iw;
    c.con[2][1] = 2.0f / ih;
    c.con[2][2] = 1.0f / iw;
    c.con[2][3] = 2.0f / ih;
    c.con[3][0] = 0.0f;
    c.con[3][1] = 4.0f / ih;
    c.con[3][2] = 0.0f;
    c.con[3][3] = 0.0f;
    c.out[0] = (uint32_t)outW;
    c.out[1] = (uint32_t)outH;
    return c;
}

// ---------------------------------------------------------------- CPU bilinear reference
static int clampi(int v, int lo, int hi) { return v < lo ? lo : (v > hi ? hi : v); }
static float src_luma(const uint8_t *src, int x, int y) {
    x = clampi(x, 0, SRC_W - 1); y = clampi(y, 0, SRC_H - 1);
    const uint8_t *p = src + ((size_t)y * SRC_W + x) * 4;
    return (299.0f * p[0] + 587.0f * p[1] + 114.0f * p[2]) / 1000.0f;
}
static void bilinear(const uint8_t *src, uint8_t *dst) {
    const float sx = (float)SRC_W / (float)DST_W, sy = (float)SRC_H / (float)DST_H;
    for (int y = 0; y < DST_H; y++) {
        float fy = ((float)y + 0.5f) * sy - 0.5f;
        int y0 = (int)floorf(fy); float wy = fy - (float)y0;
        for (int x = 0; x < DST_W; x++) {
            float fx = ((float)x + 0.5f) * sx - 0.5f;
            int x0 = (int)floorf(fx); float wx = fx - (float)x0;
            uint8_t *o = dst + ((size_t)y * DST_W + x) * 4;
            for (int ch = 0; ch < 3; ch++) {
                float a = src[(((size_t)clampi(y0, 0, SRC_H - 1)) * SRC_W + clampi(x0, 0, SRC_W - 1)) * 4 + ch];
                float b = src[(((size_t)clampi(y0, 0, SRC_H - 1)) * SRC_W + clampi(x0 + 1, 0, SRC_W - 1)) * 4 + ch];
                float c = src[(((size_t)clampi(y0 + 1, 0, SRC_H - 1)) * SRC_W + clampi(x0, 0, SRC_W - 1)) * 4 + ch];
                float d = src[(((size_t)clampi(y0 + 1, 0, SRC_H - 1)) * SRC_W + clampi(x0 + 1, 0, SRC_W - 1)) * 4 + ch];
                float v = (a * (1 - wx) + b * wx) * (1 - wy) + (c * (1 - wx) + d * wx) * wy;
                o[ch] = (uint8_t)clampi((int)(v + 0.5f), 0, 255);
            }
            o[3] = 255;
        }
    }
}

// ---------------------------------------------------------------- metrics
static float luma_of(const uint8_t *img, int x, int y) {
    const uint8_t *p = img + ((size_t)y * DST_W + x) * 4;
    return (299.0f * p[0] + 587.0f * p[1] + 114.0f * p[2]) / 1000.0f;
}
// Sub-pixel x where the row first reaches thresh, searching [x_lo, x_hi).
static double crossing(const uint8_t *img, int y, float thresh, int x_lo, int x_hi) {
    for (int x = x_lo; x < x_hi; x++) {
        float a = luma_of(img, x, y), b = luma_of(img, x + 1, y);
        if (a < thresh && b >= thresh)
            return (double)x + (double)(thresh - a) / (double)(b - a);
    }
    return -1.0;
}
// Edge mask comes from the SOURCE, so FSR and bilinear are scored on the same pixels.
static void edge_mask(const uint8_t *src, uint8_t *mask) {
    const float sx = (float)SRC_W / (float)DST_W, sy = (float)SRC_H / (float)DST_H;
    for (int y = 0; y < DST_H; y++) {
        int j = clampi((int)floorf(((float)y + 0.5f) * sy - 0.5f), 0, SRC_H - 1);
        for (int x = 0; x < DST_W; x++) {
            int i = clampi((int)floorf(((float)x + 0.5f) * sx - 0.5f), 0, SRC_W - 1);
            float gx = fabsf(src_luma(src, i + 1, j) - src_luma(src, i, j));
            float gy = fabsf(src_luma(src, i, j + 1) - src_luma(src, i, j));
            mask[(size_t)y * DST_W + x] = (fmaxf(gx, gy) >= EDGE_THRESH) ? 1 : 0;
        }
    }
}
static double mag(const uint8_t *img, const uint8_t *mask, int use_mask) {
    double sum = 0.0; size_t n = 0;
    for (int y = 0; y < DST_H - 1; y++) {
        for (int x = 0; x < DST_W - 1; x++) {
            size_t k = (size_t)y * DST_W + x;
            if (use_mask && !(mask[k] && mask[k + 1] && mask[k + DST_W])) continue;
            float c = luma_of(img, x, y);
            sum += (fabsf(luma_of(img, x + 1, y) - c) + fabsf(luma_of(img, x, y + 1) - c)) * 0.5;
            n++;
        }
    }
    return n ? sum / (double)n : 0.0;
}

// ---------------------------------------------------------------- PNG writer
// Uncompressed deflate ("stored") blocks: a valid PNG with no zlib dependency.
static uint32_t crc_tab[256];
static void crc_init(void) {
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i;
        for (int k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
        crc_tab[i] = c;
    }
}
static uint32_t crc32_buf(const uint8_t *p, size_t n) {
    uint32_t c = 0xFFFFFFFFu;
    for (size_t i = 0; i < n; i++) c = crc_tab[(c ^ p[i]) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFFFFFFu;
}
static void be32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)(v >> 16); p[2] = (uint8_t)(v >> 8); p[3] = (uint8_t)v;
}
static void chunk(FILE *f, const char *type, const uint8_t *data, size_t n) {
    uint8_t hdr[8];
    be32(hdr, (uint32_t)n);
    memcpy(hdr + 4, type, 4);
    fwrite(hdr, 1, 8, f);
    if (n) fwrite(data, 1, n, f);
    uint8_t *tmp = malloc(n + 4);
    if (!tmp) { fprintf(stderr, "【红】PNG alloc\n"); exit(1); }
    memcpy(tmp, type, 4);
    if (n) memcpy(tmp + 4, data, n);
    be32(hdr, crc32_buf(tmp, n + 4));
    fwrite(hdr, 1, 4, f);
    free(tmp);
}
static void write_png(const char *path, const uint8_t *rgba, int w, int h) {
    size_t stride = (size_t)w * 3;
    size_t raw_n = (stride + 1) * (size_t)h;
    uint8_t *raw = malloc(raw_n);
    if (!raw) { fprintf(stderr, "【红】PNG alloc\n"); exit(1); }
    for (int y = 0; y < h; y++) {
        uint8_t *row = raw + (stride + 1) * (size_t)y;
        row[0] = 0;
        for (int x = 0; x < w; x++) {
            const uint8_t *s = rgba + ((size_t)y * w + x) * 4;
            row[1 + (size_t)x * 3 + 0] = s[0];
            row[1 + (size_t)x * 3 + 1] = s[1];
            row[1 + (size_t)x * 3 + 2] = s[2];
        }
    }
    size_t nblk = (raw_n + 65534) / 65535;
    if (nblk == 0) nblk = 1;
    size_t z_n = 2 + raw_n + nblk * 5 + 4;
    uint8_t *z = malloc(z_n);
    if (!z) { fprintf(stderr, "【红】PNG alloc\n"); exit(1); }
    size_t o = 0;
    z[o++] = 0x78; z[o++] = 0x01;
    size_t pos = 0;
    for (size_t b = 0; b < nblk; b++) {
        size_t len = raw_n - pos; if (len > 65535) len = 65535;
        z[o++] = (b == nblk - 1) ? 1 : 0;
        z[o++] = (uint8_t)(len & 0xFF); z[o++] = (uint8_t)(len >> 8);
        uint16_t nl = (uint16_t)~len;
        z[o++] = (uint8_t)(nl & 0xFF); z[o++] = (uint8_t)(nl >> 8);
        memcpy(z + o, raw + pos, len); o += len; pos += len;
    }
    uint32_t a = 1, bb = 0;
    for (size_t i = 0; i < raw_n; i++) { a = (a + raw[i]) % 65521u; bb = (bb + a) % 65521u; }
    be32(z + o, (bb << 16) | a); o += 4;

    FILE *f = fopen(path, "wb");
    if (!f) { fprintf(stderr, "【红】cannot open %s\n", path); exit(1); }
    static const uint8_t sig[8] = { 137, 80, 78, 71, 13, 10, 26, 10 };
    fwrite(sig, 1, 8, f);
    uint8_t ihdr[13];
    be32(ihdr, (uint32_t)w); be32(ihdr + 4, (uint32_t)h);
    ihdr[8] = 8; ihdr[9] = 2; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
    chunk(f, "IHDR", ihdr, 13);
    chunk(f, "IDAT", z, o);
    chunk(f, "IEND", NULL, 0);
    fclose(f);
    free(z); free(raw);
}

// ---------------------------------------------------------------- main
int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: %s <shader-dir> <out-dir>\n", argv[0]); return 64; }
    const char *shader_dir = argv[1], *out_dir = argv[2];
    crc_init();

    // ---- instance with validation explicitly enabled (not relying on env alone)
    uint32_t nlayer = 0;
    vkEnumerateInstanceLayerProperties(&nlayer, NULL);
    VkLayerProperties *layers = calloc(nlayer ? nlayer : 1, sizeof *layers);
    if (nlayer) vkEnumerateInstanceLayerProperties(&nlayer, layers);
    int have_val = 0;
    for (uint32_t i = 0; i < nlayer; i++)
        if (!strcmp(layers[i].layerName, "VK_LAYER_KHRONOS_validation")) have_val = 1;
    free(layers);
    if (!have_val) { fprintf(stderr, "【红】VK_LAYER_KHRONOS_validation 不可用，本用例要求 0 条校验报错\n"); return 2; }
    const char *ilayers[] = { "VK_LAYER_KHRONOS_validation" };
    const char *iexts[] = { VK_EXT_DEBUG_UTILS_EXTENSION_NAME };
    VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
                              .pApplicationName = "t_fsr_upscale", .apiVersion = VK_API_VERSION_1_1 };
    VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &app,
        .enabledLayerCount = 1, .ppEnabledLayerNames = ilayers,
        .enabledExtensionCount = 1, .ppEnabledExtensionNames = iexts };
    VkInstance inst; VKTRY(vkCreateInstance(&ici, NULL, &inst));
    printf("validation layer: VK_LAYER_KHRONOS_validation enabled\n");

    PFN_vkCreateDebugUtilsMessengerEXT mk_dbg =
        (PFN_vkCreateDebugUtilsMessengerEXT)vkGetInstanceProcAddr(inst, "vkCreateDebugUtilsMessengerEXT");
    VkDebugUtilsMessengerEXT dbg = VK_NULL_HANDLE;
    if (mk_dbg) {
        VkDebugUtilsMessengerCreateInfoEXT dci = { .sType = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
            .messageSeverity = VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
                               VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
            .messageType = VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
                           VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
                           VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
            .pfnUserCallback = dbg_cb };
        VKTRY(mk_dbg(inst, &dci, NULL, &dbg));
    }

    uint32_t npd = 0;
    VKTRY(vkEnumeratePhysicalDevices(inst, &npd, NULL));
    if (!npd) { fprintf(stderr, "【红】no Vulkan device\n"); return 2; }
    VkPhysicalDevice *pds = calloc(npd, sizeof *pds);
    VKTRY(vkEnumeratePhysicalDevices(inst, &npd, pds));
    VkPhysicalDevice pd = pds[0];
    VkPhysicalDeviceProperties props; vkGetPhysicalDeviceProperties(pd, &props);
    printf("device: %s\n", props.deviceName);
    free(pds);

    uint32_t nq = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(pd, &nq, NULL);
    VkQueueFamilyProperties *qs = calloc(nq, sizeof *qs);
    vkGetPhysicalDeviceQueueFamilyProperties(pd, &nq, qs);
    uint32_t qf = UINT32_MAX;
    for (uint32_t i = 0; i < nq; i++)
        if (qs[i].queueFlags & VK_QUEUE_COMPUTE_BIT) { qf = i; break; }
    free(qs);
    if (qf == UINT32_MAX) { fprintf(stderr, "【红】no compute queue\n"); return 2; }

    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                                    .queueFamilyIndex = qf, .queueCount = 1, .pQueuePriorities = &prio };
    VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
                               .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci };
    VkDevice dev; VKTRY(vkCreateDevice(pd, &dci, NULL, &dev));
    VkQueue queue; vkGetDeviceQueue(dev, qf, 0, &queue);

    // rgba32f storage support is required: it is the only way to see a NaN before quantization.
    VkFormatProperties fp32;
    vkGetPhysicalDeviceFormatProperties(pd, VK_FORMAT_R32G32B32A32_SFLOAT, &fp32);
    if (!(fp32.optimalTilingFeatures & VK_FORMAT_FEATURE_STORAGE_IMAGE_BIT)) {
        fprintf(stderr, "【红】设备不支持 rgba32f 存储图，无法审计 NaN/Inf\n"); return 2;
    }

    // ---- resources
    size_t src_bytes = (size_t)SRC_W * SRC_H * 4;
    size_t dst_bytes = (size_t)DST_W * DST_H * 4;
    size_t audit_bytes = (size_t)DST_W * DST_H * 16;
    uint8_t *src = malloc(src_bytes);
    uint8_t *out8 = malloc(dst_bytes);
    float *out32 = malloc(audit_bytes);
    uint8_t *ref = malloc(dst_bytes);
    uint8_t *mask = malloc((size_t)DST_W * DST_H);
    if (!src || !out8 || !out32 || !ref || !mask) { fprintf(stderr, "【红】host alloc\n"); return 1; }
    synth(src);
    bilinear(src, ref);
    edge_mask(src, mask);

    Buf up = mk_buf(dev, pd, src_bytes, VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
    memcpy(up.map, src, src_bytes);
    Buf rb8 = mk_buf(dev, pd, dst_bytes, VK_BUFFER_USAGE_TRANSFER_DST_BIT);
    Buf rb32 = mk_buf(dev, pd, audit_bytes, VK_BUFFER_USAGE_TRANSFER_DST_BIT);
    memset(rb8.map, 0, dst_bytes);
    memset(rb32.map, 0, audit_bytes);

    Img isrc = mk_img(dev, pd, SRC_W, SRC_H, VK_FORMAT_R8G8B8A8_UNORM,
                      VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT, VK_IMAGE_ASPECT_COLOR_BIT);
    Img idst = mk_img(dev, pd, DST_W, DST_H, VK_FORMAT_R8G8B8A8_UNORM,
                      VK_IMAGE_USAGE_STORAGE_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT, VK_IMAGE_ASPECT_COLOR_BIT);
    Img iaud = mk_img(dev, pd, DST_W, DST_H, VK_FORMAT_R32G32B32A32_SFLOAT,
                      VK_IMAGE_USAGE_STORAGE_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT, VK_IMAGE_ASPECT_COLOR_BIT);

    VkSamplerCreateInfo sci = { .sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .magFilter = VK_FILTER_NEAREST, .minFilter = VK_FILTER_NEAREST,
        .addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        .mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST,
        .minLod = 0.0f, .maxLod = 0.0f };
    VkSampler samp; VKTRY(vkCreateSampler(dev, &sci, NULL, &samp));

    // ---- descriptors
    VkDescriptorSetLayoutBinding binds[3] = {
        { .binding = 0, .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
          .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT },
        { .binding = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,
          .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT },
        { .binding = 2, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE,
          .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT },
    };
    VkDescriptorSetLayoutCreateInfo dslci = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
                                              .bindingCount = 3, .pBindings = binds };
    VkDescriptorSetLayout dsl; VKTRY(vkCreateDescriptorSetLayout(dev, &dslci, NULL, &dsl));
    VkPushConstantRange pcr = { .stageFlags = VK_SHADER_STAGE_COMPUTE_BIT, .offset = 0, .size = sizeof(EasuCon) };
    VkPipelineLayoutCreateInfo plci = { .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1, .pSetLayouts = &dsl, .pushConstantRangeCount = 1, .pPushConstantRanges = &pcr };
    VkPipelineLayout pl; VKTRY(vkCreatePipelineLayout(dev, &plci, NULL, &pl));

    VkDescriptorPoolSize psizes[2] = {
        { VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1 }, { VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, 2 } };
    VkDescriptorPoolCreateInfo dpci = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .maxSets = 1, .poolSizeCount = 2, .pPoolSizes = psizes };
    VkDescriptorPool pool; VKTRY(vkCreateDescriptorPool(dev, &dpci, NULL, &pool));
    VkDescriptorSetAllocateInfo dsai = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = pool, .descriptorSetCount = 1, .pSetLayouts = &dsl };
    VkDescriptorSet ds; VKTRY(vkAllocateDescriptorSets(dev, &dsai, &ds));
    VkDescriptorImageInfo di0 = { .sampler = samp, .imageView = isrc.view,
                                  .imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
    VkDescriptorImageInfo di1 = { .imageView = idst.view, .imageLayout = VK_IMAGE_LAYOUT_GENERAL };
    VkDescriptorImageInfo di2 = { .imageView = iaud.view, .imageLayout = VK_IMAGE_LAYOUT_GENERAL };
    VkWriteDescriptorSet writes[3] = {
        { .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = ds, .dstBinding = 0,
          .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .pImageInfo = &di0 },
        { .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = ds, .dstBinding = 1,
          .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .pImageInfo = &di1 },
        { .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = ds, .dstBinding = 2,
          .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .pImageInfo = &di2 },
    };
    vkUpdateDescriptorSets(dev, 3, writes, 0, NULL);

    // ---- pipeline
    char spv_path[1024];
    snprintf(spv_path, sizeof spv_path, "%s/fsr_easu.comp.spv", shader_dir);
    FILE *sf = fopen(spv_path, "rb");
    if (!sf) { fprintf(stderr, "【红】cannot open %s\n", spv_path); return 2; }
    fseek(sf, 0, SEEK_END); long spv_n = ftell(sf); fseek(sf, 0, SEEK_SET);
    if (spv_n <= 0 || spv_n % 4) { fprintf(stderr, "【红】bad SPIR-V size\n"); return 2; }
    uint32_t *spv = malloc((size_t)spv_n);
    if (fread(spv, 1, (size_t)spv_n, sf) != (size_t)spv_n) { fprintf(stderr, "【红】SPIR-V read\n"); return 2; }
    fclose(sf);
    VkShaderModuleCreateInfo smci = { .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
                                      .codeSize = (size_t)spv_n, .pCode = spv };
    VkShaderModule sm; VKTRY(vkCreateShaderModule(dev, &smci, NULL, &sm));
    free(spv);
    VkComputePipelineCreateInfo cpci = { .sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
        .stage = { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
                   .stage = VK_SHADER_STAGE_COMPUTE_BIT, .module = sm, .pName = "main" },
        .layout = pl };
    VkPipeline pipe; VKTRY(vkCreateComputePipelines(dev, VK_NULL_HANDLE, 1, &cpci, NULL, &pipe));

    // ---- command buffer
    VkCommandPoolCreateInfo cpci2 = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
                                      .queueFamilyIndex = qf };
    VkCommandPool cpool; VKTRY(vkCreateCommandPool(dev, &cpci2, NULL, &cpool));
    VkCommandBufferAllocateInfo cbai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = cpool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
    VkCommandBuffer cmd; VKTRY(vkAllocateCommandBuffers(dev, &cbai, &cmd));
    VkCommandBufferBeginInfo cbbi = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
                                      .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT };
    VKTRY(vkBeginCommandBuffer(cmd, &cbbi));

    barrier(cmd, isrc.img, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, VK_ACCESS_TRANSFER_WRITE_BIT);
    VkBufferImageCopy cp = { .bufferOffset = 0, .bufferRowLength = 0, .bufferImageHeight = 0,
        .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
        .imageOffset = { 0, 0, 0 }, .imageExtent = { SRC_W, SRC_H, 1 } };
    vkCmdCopyBufferToImage(cmd, up.buf, isrc.img, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &cp);
    barrier(cmd, isrc.img, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_SHADER_READ_BIT);
    barrier(cmd, idst.img, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_GENERAL,
            VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, VK_ACCESS_SHADER_WRITE_BIT);
    barrier(cmd, iaud.img, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_GENERAL,
            VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, VK_ACCESS_SHADER_WRITE_BIT);

    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, pipe);
    vkCmdBindDescriptorSets(cmd, VK_PIPELINE_BIND_POINT_COMPUTE, pl, 0, 1, &ds, 0, NULL);
    EasuCon con = easu_con(SRC_W, SRC_H, DST_W, DST_H);
    vkCmdPushConstants(cmd, pl, VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof con, &con);
    vkCmdDispatch(cmd, (DST_W + 7) / 8, (DST_H + 7) / 8, 1);

    barrier(cmd, idst.img, VK_IMAGE_LAYOUT_GENERAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
            VK_ACCESS_SHADER_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT);
    barrier(cmd, iaud.img, VK_IMAGE_LAYOUT_GENERAL, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
            VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
            VK_ACCESS_SHADER_WRITE_BIT, VK_ACCESS_TRANSFER_READ_BIT);
    VkBufferImageCopy dc = { .bufferOffset = 0, .bufferRowLength = 0, .bufferImageHeight = 0,
        .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 },
        .imageOffset = { 0, 0, 0 }, .imageExtent = { DST_W, DST_H, 1 } };
    vkCmdCopyImageToBuffer(cmd, idst.img, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, rb8.buf, 1, &dc);
    vkCmdCopyImageToBuffer(cmd, iaud.img, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, rb32.buf, 1, &dc);
    VKTRY(vkEndCommandBuffer(cmd));

    VkFenceCreateInfo fci = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    VkFence fence; VKTRY(vkCreateFence(dev, &fci, NULL, &fence));
    VkSubmitInfo si = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cmd };
    VKTRY(vkQueueSubmit(queue, 1, &si, fence));
    VKTRY(vkWaitForFences(dev, 1, &fence, VK_TRUE, 60ull * 1000000000ull));

    memcpy(out8, rb8.map, dst_bytes);
    memcpy(out32, rb32.map, audit_bytes);

    // ---- audit: NaN / Inf / range on the unquantized result
    size_t nonfinite = 0, outrange = 0, alpha_bad = 0, quant_mismatch = 0;
    for (size_t i = 0; i < (size_t)DST_W * DST_H; i++) {
        const float *f = out32 + i * 4;
        for (int ch = 0; ch < 4; ch++) if (!isfinite(f[ch])) nonfinite++;
        for (int ch = 0; ch < 3; ch++) if (f[ch] < -1e-6f || f[ch] > 1.0f + 1e-6f) outrange++;
        if (f[3] != 1.0f) alpha_bad++;
        for (int ch = 0; ch < 3; ch++) {
            float q = (float)out8[i * 4 + ch] / 255.0f;
            if (fabsf(q - f[ch]) > (1.0f / 255.0f) + 1e-5f) quant_mismatch++;
        }
    }

    // ---- audit: dering window. EASU clamps to min/max of the 4 nearest taps (f,g,j,k).
    // Recomputing that window on the CPU from the true source catches a wrong gather order,
    // which a sharpness-only check would happily pass.
    size_t window_bad = 0, border_window_bad = 0; double window_worst = 0.0;
    size_t flat_n = 0, flat_bad = 0;
    const float sx = (float)SRC_W / (float)DST_W, sy = (float)SRC_H / (float)DST_H;
    for (int y = 0; y < DST_H; y++) {
        int fy = (int)floorf(((float)y + 0.5f) * sy - 0.5f);
        for (int x = 0; x < DST_W; x++) {
            int fx = (int)floorf(((float)x + 0.5f) * sx - 0.5f);
            const uint8_t *t[4];
            t[0] = src + ((size_t)clampi(fy, 0, SRC_H - 1) * SRC_W + clampi(fx, 0, SRC_W - 1)) * 4;
            t[1] = src + ((size_t)clampi(fy, 0, SRC_H - 1) * SRC_W + clampi(fx + 1, 0, SRC_W - 1)) * 4;
            t[2] = src + ((size_t)clampi(fy + 1, 0, SRC_H - 1) * SRC_W + clampi(fx, 0, SRC_W - 1)) * 4;
            t[3] = src + ((size_t)clampi(fy + 1, 0, SRC_H - 1) * SRC_W + clampi(fx + 1, 0, SRC_W - 1)) * 4;
            const uint8_t *o = out8 + ((size_t)y * DST_W + x) * 4;
            int is_flat = 1;
            for (int ch = 0; ch < 3; ch++) {
                int lo = 255, hi = 0;
                for (int k = 0; k < 4; k++) {
                    if (t[k][ch] < lo) lo = t[k][ch];
                    if (t[k][ch] > hi) hi = t[k][ch];
                }
                if (lo != hi) is_flat = 0;
                int d = 0;
                if (o[ch] < lo) d = lo - o[ch];
                else if (o[ch] > hi) d = o[ch] - hi;
                if (d > 1) {
                    window_bad++;
                    if (d > window_worst) window_worst = d;
                    if (x < 2 || y < 2 || x >= DST_W - 2 || y >= DST_H - 2) border_window_bad++;
                }
            }
            // Solid-patch interior: the window collapses to one colour, so EASU must be exact.
            if (is_flat && fx >= PATCH_X0 + 20 && fx < SRC_W - 20 && fy >= PATCH_Y0 + 20 && fy < 540 - 20) {
                flat_n++;
                for (int ch = 0; ch < 3; ch++) if (abs((int)o[ch] - (int)t[0][ch]) > 1) { flat_bad++; break; }
            }
        }
    }

    // ---- audit: border fidelity vs bilinear (both clamp to edge, so they must agree closely)
    int border_worst = 0;
    for (int y = 0; y < DST_H; y++) {
        for (int x = 0; x < DST_W; x++) {
            if (x >= 2 && y >= 2 && x < DST_W - 2 && y < DST_H - 2) continue;
            const uint8_t *a = out8 + ((size_t)y * DST_W + x) * 4;
            const uint8_t *b = ref + ((size_t)y * DST_W + x) * 4;
            for (int ch = 0; ch < 3; ch++) {
                int d = abs((int)a[ch] - (int)b[ch]);
                if (d > border_worst) border_worst = d;
            }
        }
    }

    // ---- audit: geometry. The isolated vertical edge at source x=VEDGE_X must land where
    // the centre mapping says it does; a mirrored or shifted kernel would move it.
    const int probe_src_y = 450;   // band C, the only band carrying the isolated vertical edge
    int probe_y = (int)(((double)probe_src_y + 0.5) / (double)sy - 0.5);
    double expect = (double)VEDGE_X / (double)sx - 0.5;
    int x_lo = (int)((VEDGE_X - 40.0) / sx), x_hi = (int)((VEDGE_X + 40.0) / sx);
    if (x_lo < 1) x_lo = 1;
    if (x_hi > DST_W - 2) x_hi = DST_W - 2;
    double cross_fsr = crossing(out8, probe_y, 125.0f, x_lo, x_hi);
    double cross_ref = crossing(ref, probe_y, 125.0f, x_lo, x_hi);
    double err_fsr = cross_fsr < 0 ? 1e9 : fabs(cross_fsr - expect);
    double err_ref = cross_ref < 0 ? 1e9 : fabs(cross_ref - expect);
    // 10-90 rise width of the same 20->230 step. MAG alone cannot see edge width: the sum of
    // |diffs| across a monotonic ramp is conserved however wide the ramp is. This measures
    // steepness directly, so a MAG gain from ringing cannot masquerade as a sharper edge.
    double r10f = crossing(out8, probe_y, 41.0f, x_lo, x_hi);
    double r90f = crossing(out8, probe_y, 209.0f, x_lo, x_hi);
    double r10r = crossing(ref, probe_y, 41.0f, x_lo, x_hi);
    double r90r = crossing(ref, probe_y, 209.0f, x_lo, x_hi);
    double rise_fsr = (r10f < 0 || r90f < 0) ? -1.0 : r90f - r10f;
    double rise_ref = (r10r < 0 || r90r < 0) ? -1.0 : r90r - r10r;

    // ---- metrics
    double m_fsr_edge = mag(out8, mask, 1), m_ref_edge = mag(ref, mask, 1);
    double m_fsr_all = mag(out8, mask, 0), m_ref_all = mag(ref, mask, 0);
    double ratio_edge = m_ref_edge > 0 ? m_fsr_edge / m_ref_edge : 0.0;
    double ratio_all = m_ref_all > 0 ? m_fsr_all / m_ref_all : 0.0;

    // ---- images (local only, never uploaded)
    char p[1024];
    snprintf(p, sizeof p, "%s/source_1280x720.png", out_dir);   write_png(p, src, SRC_W, SRC_H);
    snprintf(p, sizeof p, "%s/bilinear_2133x1200.png", out_dir); write_png(p, ref, DST_W, DST_H);
    snprintf(p, sizeof p, "%s/fsr_2133x1200.png", out_dir);      write_png(p, out8, DST_W, DST_H);

    uint32_t validation = g_val_err + g_val_warn;
    printf("FSR_SPIKE: metric_fsr=%.6f metric_bilinear=%.6f ratio=%.6f validation=%u\n",
           m_fsr_edge, m_ref_edge, ratio_edge, validation);
    printf("FSR_SPIKE: metric_fsr_global=%.6f metric_bilinear_global=%.6f ratio_global=%.6f\n",
           m_fsr_all, m_ref_all, ratio_all);
    printf("FSR_SPIKE: validation_errors=%u validation_warnings=%u\n", g_val_err, g_val_warn);
    printf("FSR_SPIKE: nonfinite=%zu outrange=%zu alpha_bad=%zu quant_mismatch=%zu\n",
           nonfinite, outrange, alpha_bad, quant_mismatch);
    printf("FSR_SPIKE: window_violations=%zu window_worst=%d flat_checked=%zu flat_bad=%zu\n",
           window_bad, (int)window_worst, flat_n, flat_bad);
    printf("FSR_SPIKE: border_window_violations=%zu border_max_diff_vs_bilinear=%d\n",
           border_window_bad, border_worst);
    printf("FSR_SPIKE: edge_expect=%.2f edge_fsr=%.2f edge_bilinear=%.2f edge_err_fsr=%.2f edge_err_bilinear=%.2f\n",
           expect, cross_fsr, cross_ref, err_fsr, err_ref);
    printf("FSR_SPIKE: rise1090_fsr=%.3f rise1090_bilinear=%.3f rise_ratio_bilinear_over_fsr=%.3f\n",
           rise_fsr, rise_ref, (rise_fsr > 0 && rise_ref > 0) ? rise_ref / rise_fsr : 0.0);

    int fail = 0;
    if (!(ratio_edge >= RATIO_GATE)) { printf("FAIL: edge ratio %.4f < %.2f\n", ratio_edge, RATIO_GATE); fail = 1; }
    if (nonfinite || outrange || alpha_bad || quant_mismatch) { printf("FAIL: NaN/Inf/range/quantization\n"); fail = 1; }
    if (window_bad) { printf("FAIL: dering window violated\n"); fail = 1; }
    if (flat_bad) { printf("FAIL: solid patch not reproduced\n"); fail = 1; }
    if (border_window_bad) { printf("FAIL: border overflow/black edge, %zu px outside the source window\n", border_window_bad); fail = 1; }
    if (err_fsr > 1.5) { printf("FAIL: edge position off by %.2f px\n", err_fsr); fail = 1; }
    if (validation) { printf("FAIL: validation reported %u messages\n", validation); fail = 1; }

    vkDestroyFence(dev, fence, NULL);
    vkFreeCommandBuffers(dev, cpool, 1, &cmd);
    vkDestroyCommandPool(dev, cpool, NULL);
    vkDestroyPipeline(dev, pipe, NULL);
    vkDestroyShaderModule(dev, sm, NULL);
    vkDestroyDescriptorPool(dev, pool, NULL);
    vkDestroyPipelineLayout(dev, pl, NULL);
    vkDestroyDescriptorSetLayout(dev, dsl, NULL);
    vkDestroySampler(dev, samp, NULL);
    Img *ims[3] = { &isrc, &idst, &iaud };
    for (int i = 0; i < 3; i++) { vkDestroyImageView(dev, ims[i]->view, NULL); vkDestroyImage(dev, ims[i]->img, NULL); vkFreeMemory(dev, ims[i]->mem, NULL); }
    Buf *bs[3] = { &up, &rb8, &rb32 };
    for (int i = 0; i < 3; i++) { vkUnmapMemory(dev, bs[i]->mem); vkDestroyBuffer(dev, bs[i]->buf, NULL); vkFreeMemory(dev, bs[i]->mem, NULL); }
    vkDestroyDevice(dev, NULL);
    if (dbg) {
        PFN_vkDestroyDebugUtilsMessengerEXT rm =
            (PFN_vkDestroyDebugUtilsMessengerEXT)vkGetInstanceProcAddr(inst, "vkDestroyDebugUtilsMessengerEXT");
        if (rm) rm(inst, dbg, NULL);
    }
    vkDestroyInstance(inst, NULL);
    free(src); free(out8); free(out32); free(ref); free(mask);

    if (fail) { printf("FSR_SPIKE: FAIL\n"); return 1; }
    printf("FSR_SPIKE: PASS\n");
    return 0;
}