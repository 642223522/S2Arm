// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
//
// Metal 贴图视图格式兼容性（graphics/nvn/gfx/nvn/nvn_pfview.h）。
// 对照 macOS 27 / Apple M4 上逐例实测的 -newTextureViewWithPixelFormat: 结果：不兼容的一对不是返回 nil，
// 而是 MTLReportFailure → abort()（信号 6）。这条单测把「同字节数才允许」的判据钉住，防止以后又把
// 无 BC 设备上解码成 RGBA8Unorm 的 BC 贴图配上 RGBA32Uint 块视图（11-09，程序号 0100152000022000，14 Pro Max）。
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <assert.h>
#include <stdio.h>
#include "../gfx/nvn/nvn_pfview.h"

typedef struct { MTLPixelFormat base, view; int want; const char *name; } Case;

int main(void) {
    static const Case cases[] = {
        {MTLPixelFormatRGBA8Unorm,     MTLPixelFormatRGBA32Uint,      0, "崩溃现场：RGBA8Unorm → RGBA32Uint（4 B/px → 16 B/px）"},
        {MTLPixelFormatRGBA8Unorm,     MTLPixelFormatRGBA8Unorm_sRGB, 1, "SMBW 交换链 sRGB 视图"},
        {MTLPixelFormatRGBA8Unorm,     MTLPixelFormatRGBA8Uint,       1, "同族整数视图"},
        {MTLPixelFormatRGBA8Unorm,     MTLPixelFormatBGRA8Unorm,      1, "通道序不同、字节数相同"},
        {MTLPixelFormatBGRA8Unorm,     MTLPixelFormatBGRA8Unorm_sRGB, 1, "BGRA sRGB 视图"},
        {MTLPixelFormatRGBA32Float,    MTLPixelFormatRGBA32Uint,      1, "16 B/px 同族"},
        {MTLPixelFormatR32Float,       MTLPixelFormatRGBA8Unorm,      1, "4 B/px：1 通道 ↔ 4 通道也允许"},
        {MTLPixelFormatR32Uint,        MTLPixelFormatR32Float,        1, "4 B/px 同族"},
        {MTLPixelFormatRG8Unorm,       MTLPixelFormatR16Float,        1, "2 B/px：2 通道 ↔ 1 通道也允许"},
        {MTLPixelFormatRGB10A2Unorm,   MTLPixelFormatRGB10A2Uint,     1, "10-10-10-2 同族"},
        {MTLPixelFormatRGBA8Unorm,     MTLPixelFormatRGBA16Float,     0, "4 B/px → 8 B/px"},
        {MTLPixelFormatR8Unorm,        MTLPixelFormatR16Unorm,        0, "1 B/px → 2 B/px"},
        {MTLPixelFormatBC3_RGBA,       MTLPixelFormatRGBA32Uint,      0, "压缩贴图不当作普通贴图视图"},
        {MTLPixelFormatDepth32Float,   MTLPixelFormatR32Float,        0, "深度贴图不当作颜色视图"},
        {MTLPixelFormatBC3_RGBA,       MTLPixelFormatBC3_RGBA,        1, "压缩贴图同格式视图"},
        {MTLPixelFormatDepth32Float,   MTLPixelFormatDepth32Float,    1, "深度贴图同格式视图"},
    };
    for (size_t i = 0; i < sizeof cases / sizeof *cases; i++) {
        int got = mtl_pfv_compatible(cases[i].base, cases[i].view);
        if (got != cases[i].want) { printf("✗ t_nvn_pfview：失配 %s（期望 %d，得到 %d）\n", cases[i].name, cases[i].want, got); return 1; }
    }
    assert(mtl_pf_bytes(MTLPixelFormatRGBA8Unorm) == 4);
    assert(mtl_pf_bytes(MTLPixelFormatRGBA32Uint) == 16);
    assert(mtl_pf_bytes(MTLPixelFormatBC3_RGBA) == 0);
    assert(mtl_pf_bytes(MTLPixelFormatDepth32Float) == 0);
    printf("✓ t_nvn_pfview：%zu 组格式对与字节数表全部通过\n", sizeof cases / sizeof *cases);
    return 0;
}
