// Metal 稀疏贴图（nvn_sparse_tex.inc）的页假设：NVN 稀疏贴图按页铺的级里，每个 64 KB 页 = 块线性一段连续存储，
//   页起点 = 层起点 + 级起点 + (页行 × 每行页数 + 页列) × 64 KB；用「宽高 = 页像素、块高 = 本级块高、1 级」的合成描述去混排这一页，
//   等于整级去混排里对应的子区域。期望手写：4 组规格（BC6H / ASTC 8x8 / 带不满边缘页的 ASTC / X1 GOB 顺序的 RGBA8）逐页逐字节一致；
//   反证：页序改成按列（px * 每列页数 + py）时 150 处不符（11-16 本机）。纯 C，不链 Metal
#include "nvn_tex.h"
#include "../tex/nvn_deswizzle.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define MIN(a,b) ((a)<(b)?(a):(b))
static int bad;
static void run(int fmt, uint32_t W, uint32_t H, uint32_t layers, uint32_t levels, int sw2) {
    nvn_gob_switch2 = sw2;
    nvn_texdesc d = {0}; d.target = 4; d.format = fmt; d.flags = 0x20; d.width = W; d.height = H; d.depth = layers; d.levels = levels;
    nvn_texlayout L; nvn_tex_layout(&d, &L); uint32_t tl[4]; nvn_tex_sparse_layout(&d, tl);
    int bw, bh, bpb = nvn_fmt_bpb(fmt, &bw, &bh);
    printf("fmt %#x %ux%ux%u L%u: size %llu layer %llu bpb %d blk %dx%d tiled levels %u page %ux%u px\n", fmt, W, H, layers, levels, (unsigned long long)L.size, (unsigned long long)L.layer_size, bpb, bw, bh, tl[0], tl[1], tl[2]);
    uint8_t *store = calloc(1, L.size);
    // fill each level/layer linear with random then swizzle in
    for (unsigned l = 0; l < levels; l++) { uint32_t w = W >> l, h = H >> l; size_t pitch = (size_t)((w + bw - 1) / bw) * bpb, rows = (h + bh - 1) / bh;
        uint8_t *lin = malloc(pitch * rows); for (size_t i = 0; i < pitch * rows; i++) lin[i] = (uint8_t)rand();
        for (unsigned y = 0; y < layers; y++) { for (size_t i = 0; i < pitch * rows; i++) lin[i] = (uint8_t)(rand() ^ y ^ l); nvn_swizzle(&d, l, y, lin, pitch, store); }
        free(lin); }
    unsigned pages_checked = 0;
    for (unsigned l = 0; l < tl[0]; l++) {
        uint32_t w = W >> l, h = H >> l; size_t pitch = (size_t)((w + bw - 1) / bw) * bpb, rows = (h + bh - 1) / bh;
        unsigned tH, tD; nvn_tex_level_tiles(&d, l, &tH, &tD);
        uint32_t gobs = nvn_tex_level_gobs(&d, l); uint64_t loff = nvn_tex_level_offset(&d, l);
        uint32_t ppr = (w + tl[1] - 1) / tl[1], ppc = (h + tl[2] - 1) / tl[2];
        nvn_texdesc pd = {0}; pd.target = 1; pd.format = fmt; pd.flags = 0; pd.width = tl[1]; pd.height = tl[2]; pd.depth = 1; pd.levels = 1; pd.pkg_layout = (int)(tH | (tD << 4)) + 1;
        nvn_texlayout PL; nvn_tex_layout(&pd, &PL);
        size_t ppitch = (size_t)(tl[1] / bw) * bpb, prows = tl[2] / bh;
        uint8_t *full = malloc(pitch * rows), *pg = malloc(ppitch * prows);
        for (unsigned y = 0; y < layers; y++) {
            nvn_deswizzle(&d, l, y, store, full, pitch);
            for (uint32_t py = 0; py < ppc; py++) for (uint32_t px = 0; px < ppr; px++) {
                uint64_t off = (uint64_t)y * L.layer_size + loff + ((uint64_t)py * ppr + px) * 0x10000;
                if (gobs * 64 != ppr * ppitch) { printf("  ✗ L%u row bytes %u != pages*pagepitch %zu\n", l, gobs * 64, ppr * ppitch); bad++; }
                if (nvn_deswizzle(&pd, 0, 0, store + off, pg, ppitch)) { printf("  ✗ page deswizzle failed\n"); bad++; continue; }
                // compare clipped
                uint32_t bx0 = px * (tl[1] / bw), by0 = py * (tl[2] / bh); size_t cw = MIN(ppitch, pitch - bx0 * bpb); size_t cr = MIN(prows, rows - by0);
                for (size_t r = 0; r < cr; r++) if (memcmp(full + (by0 + r) * pitch + bx0 * bpb, pg + r * ppitch, cw)) { bad++; if (bad < 5) printf("  ✗ L%u y%u page (%u,%u) row %zu mismatch\n", l, y, px, py, r); break; }
                pages_checked++;
            }
        }
        if (PL.size != 0x10000) { printf("  ✗ synthetic page layout size %llu (want 65536)\n", (unsigned long long)PL.size); bad++; }
        printf("  L%u tileH %u gobs %u pages %ux%u off %#llx, page desc size %llu\n", l, tH, gobs, ppr, ppc, (unsigned long long)loff, (unsigned long long)PL.size);
        free(full); free(pg);
    }
    printf("  pages checked %u\n", pages_checked);
    free(store);
}

int main(void) {
    run(0x50, 1024, 1024, 2, 6, 1);   // BC6H (Switch 2 GOB order)
    run(0x8e, 2048, 1024, 3, 6, 1);   // ASTC 8x8
    run(0x8e, 2048 + 512, 1024 + 256, 2, 5, 1);   // edge pages
    run(0x25, 1024, 512, 2, 4, 0);   // RGBA8, X1 order
    printf("%s t_nvn_sparse_page: %d bad\n", bad ? "✗" : "✓", bad); return bad != 0;
}
