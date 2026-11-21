/* SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 S2Arm contributors
 *
 * BC → ASTC 预转的出包端 C 库（pack/astc_pack.py 用 ctypes 载入；它负责编出本库）。参考 brad-n/TVPort（MIT）dm/gfx/tools/astc_prebuild.m：
 *   出包时在电脑上把游戏贴图的 BC 平面解压再用 Arm astc-encoder（Apache-2.0，graphics/third_party/astc-encoder）编成 ASTC 4x4。
 *   本文件按本仓库重写：块线性 → 线性照 Ryujinx（compat/tree/src/Ryujinx.Graphics.Texture 的 SizeCalculator / BlockLinearLayout /
 *   LayoutConverter.ConvertBlockLinearToLinear）——运行时 Gpu 层交给渲染器的正是它解出的线性数据，平面键（graphics/metal/gal_astc.h）按它算；
 *   BC 解压用仓库里已有的 bcdec（graphics/nvn/third_party/bcdec，MIT / 公有领域）。不依赖 Metal，Linux 出包机也能编。
 *
 * 只管 2D / 2D 数组 / 立方体（深度 1、GobBlocksInZ 1、GobBlocksInTileX 1：BNTX 里 BC 贴图都是这种）。
 */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#define BCDEC_IMPLEMENTATION
#include "../../nvn/third_party/bcdec/bcdec.h"
#include "../../third_party/astc-encoder/astcenc.h"

#define GOB_STRIDE 64u
#define GOB_HEIGHT 8u
#define GOB_SIZE 512u

int b2a_version(void) { return 1; }

static uint32_t div_up(uint32_t a, uint32_t b) { return (a + b - 1) / b; }
static uint32_t align_up(uint32_t a, uint32_t b) { return div_up(a, b) * b; }
static uint32_t mipsz(uint32_t v, uint32_t l) { v >>= l; return v ? v : 1; }
static uint32_t ctz(uint32_t v) { uint32_t n = 0; while (v > 1) { v >>= 1; n++; } return n; }

/* 一级的几何（SizeCalculator.GetBlockLinearTextureSize 的 2D 情形）：wb / hb 块数、本级 GobBlocksInY、本级字节数 */
typedef struct { uint32_t wb, hb, gy; uint64_t size; } lvl;
static lvl level_at(uint32_t bpp, uint32_t w, uint32_t h, uint32_t gy0, uint32_t level, uint64_t *offset) {
    lvl r = {0, 0, gy0, 0}; uint64_t off = 0;
    for (uint32_t l = 0; l <= level; l++) {
        r.wb = div_up(mipsz(w, l), 4); r.hb = div_up(mipsz(h, l), 4);
        while (r.hb <= (r.gy >> 1) * GOB_HEIGHT && r.gy != 1) r.gy >>= 1;
        uint32_t width_in_gobs = div_up(r.wb * bpp, GOB_STRIDE);
        uint64_t rob = (uint64_t)width_in_gobs * r.gy * GOB_SIZE;
        r.size = (uint64_t)div_up(div_up(r.hb, GOB_HEIGHT), r.gy) * rob;
        if (l < level) off += r.size;
    }
    if (offset) *offset = off;
    return r;
}
/* 一层内第 level 级的起点（字节） */
uint64_t b2a_level_offset(uint32_t bpp, uint32_t w, uint32_t h, uint32_t gob_y_log2, uint32_t level) {
    uint64_t off; level_at(bpp, w, h, 1u << gob_y_log2, level, &off); return off;
}
/* 层跨度（SizeCalculator：各级之和，多层时按 AlignLayerSize 对齐到「块的 GOB 组」） */
uint64_t b2a_layer_size(uint32_t bpp, uint32_t w, uint32_t h, uint32_t levels, uint32_t layers, uint32_t gob_y_log2) {
    uint64_t off; lvl last = level_at(bpp, w, h, 1u << gob_y_log2, levels - 1, &off);
    uint64_t size = off + last.size;
    if (layers > 1) {
        uint32_t gy = 1u << gob_y_log2, hb = div_up(h, 4);
        while (hb <= (gy >> 1) * GOB_HEIGHT && gy != 1) gy >>= 1;
        uint64_t bog = (uint64_t)gy * GOB_SIZE;
        size = (size + bog - 1) / bog * bog;
    }
    return size;
}
/* 块线性 → 线性：取一个平面（第 layer 层第 level 级）写进 dst（按行紧排，行 = wb × bpp，bpp 8 / 16 时不用补齐）。
 * 地址照 BlockLinearLayout.GetOffsetWithLineOffset（z = 0）、宽按 64 / bpp 块对齐。越界返回 -1 */
int b2a_deswizzle(const uint8_t *src, uint64_t src_len, uint32_t bpp, uint32_t w, uint32_t h, uint32_t gob_y_log2,
                  uint64_t layer_stride, uint32_t layer, uint32_t level, uint8_t *dst, uint64_t dst_len) {
    if (bpp != 8 && bpp != 16) return -1;
    uint64_t moff; lvl g = level_at(bpp, w, h, 1u << gob_y_log2, level, &moff);
    if ((uint64_t)g.wb * g.hb * bpp > dst_len) return -1;
    uint64_t base = (uint64_t)layer * layer_stride + moff;
    uint32_t w_al = align_up(g.wb, GOB_STRIDE / bpp);
    uint64_t rob = (uint64_t)GOB_SIZE * g.gy * div_up(w_al * bpp, GOB_STRIDE);
    uint32_t bh_shift = ctz(g.gy), bh_mask = g.gy - 1, x_shift = ctz(GOB_SIZE * g.gy);
    for (uint32_t y = 0; y < g.hb; y++) {
        uint32_t yh = y / GOB_HEIGHT;
        uint64_t yo = (uint64_t)(yh >> bh_shift) * rob + (uint64_t)(yh & bh_mask) * GOB_SIZE + (((y & 7u) >> 1) << 6) + ((y & 1u) << 4);
        for (uint32_t x = 0; x < g.wb; x++) {
            uint32_t xb = x * bpp;
            uint64_t o = base + yo + ((uint64_t)(xb / GOB_STRIDE) << x_shift) + (((xb & 0x3fu) >> 5) << 8) + (((xb & 0x1fu) >> 4) << 5) + (xb & 0xfu);
            if (o + bpp > src_len) return -1;
            memcpy(dst + ((uint64_t)y * g.wb + x) * bpp, src + o, bpp);
        }
    }
    return 0;
}

/* ASTC 4x4 编码上下文（LDR、单线程；Python 每个工作线程一份） */
typedef struct { struct astcenc_context *ctx; } b2a_ctx;
void *b2a_ctx_new(float quality) {
    struct astcenc_config cfg;
    if (astcenc_config_init(ASTCENC_PRF_LDR, 4, 4, 1, quality, 0, &cfg) != ASTCENC_SUCCESS) return NULL;
    b2a_ctx *c = calloc(1, sizeof *c);
    if (!c || astcenc_context_alloc(&cfg, 1, &c->ctx, NULL) != ASTCENC_SUCCESS) { free(c); return NULL; }
    return c;
}
void b2a_ctx_free(void *p) { b2a_ctx *c = p; if (!c) return; astcenc_context_free(c->ctx); free(c); }

/* 族（gal_astc.h GAL_ASTC_FAM_*）的每块字节 */
static int fam_bpp(uint32_t f) { return f == 1 ? 8 : f == 2 || f == 3 || f == 5 || f == 7 ? 16 : 0; }
/* 一个平面：BC（w × h texel，块按行紧排）→ 解压成 RGBA8（宽高补到 4 的倍数：补出的 texel 就是边上那些 BC 块自己的内容）→ ASTC 4x4。
 * BC5 解成 (R,G,0,1)：与运行时它替代的 RG8 采样结果一致。成功返回 0 */
int b2a_encode(void *p, uint32_t fam, uint32_t w, uint32_t h, const uint8_t *bc, uint64_t bc_len, uint8_t *astc, uint64_t astc_len) {
    b2a_ctx *c = p; int bpp = fam_bpp(fam);
    if (!c || !bpp || !w || !h) return -1;
    uint32_t wb = div_up(w, 4), hb = div_up(h, 4), pw = wb * 4, ph = hb * 4;
    if (bc_len < (uint64_t)wb * hb * bpp || astc_len < (uint64_t)wb * hb * 16) return -1;
    uint8_t *rgba = malloc((size_t)pw * ph * 4), *tmp = malloc(64);
    if (!rgba || !tmp) { free(rgba); free(tmp); return -1; }
    for (uint32_t by = 0; by < hb; by++)
        for (uint32_t bx = 0; bx < wb; bx++) {
            const uint8_t *blk = bc + ((uint64_t)by * wb + bx) * bpp;
            uint8_t *d = rgba + ((uint64_t)by * 4 * pw + bx * 4) * 4;
            switch (fam) {
            case 1: bcdec_bc1(blk, d, (int)pw * 4); break;
            case 2: bcdec_bc2(blk, d, (int)pw * 4); break;
            case 3: bcdec_bc3(blk, d, (int)pw * 4); break;
            case 7: bcdec_bc7(blk, d, (int)pw * 4); break;
            case 5: bcdec_bc5(blk, tmp, 8);
                for (int y = 0; y < 4; y++) for (int x = 0; x < 4; x++) { uint8_t *o = d + ((uint64_t)y * pw + x) * 4; o[0] = tmp[y * 8 + x * 2]; o[1] = tmp[y * 8 + x * 2 + 1]; o[2] = 0; o[3] = 255; }
                break;
            }
        }
    free(tmp);
    void *slices[1] = {rgba};
    struct astcenc_image img = {pw, ph, 1, ASTCENC_TYPE_U8, slices};
    struct astcenc_swizzle swz = {ASTCENC_SWZ_R, ASTCENC_SWZ_G, ASTCENC_SWZ_B, ASTCENC_SWZ_A};
    enum astcenc_error e = astcenc_compress_image(c->ctx, &img, &swz, astc, (size_t)wb * hb * 16, 0);
    astcenc_compress_reset(c->ctx);
    free(rgba);
    return e == ASTCENC_SUCCESS ? 0 : -2;
}
