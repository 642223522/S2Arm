// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
//
// Metal pixel-format view compatibility for the direct backend.
// -[MTLTexture newTextureViewWithPixelFormat:] does NOT return nil for an incompatible pair: Metal's
// validation calls MTLReportFailure → abort() (signal 6), taking down the whole app. Measured on Apple M4
// (macOS 27): a view is accepted iff both formats are uncompressed colour formats with the SAME BYTES PER
// PIXEL (channel count / signedness do not matter — R32Float → RGBA8Unorm is accepted); compressed and depth
// formats only allow an identity view. 4 B/px → 16 B/px aborts, and so does 4 B/px → 8 B/px.
//
// 11-09 a racing title (title id 0100152000022000) on iPhone 14 Pro Max (A16, no BC support): a BC3 texture is stored decoded as
// RGBA8Unorm, and the game attaches it through an RGBA32Uint "one texel = one 16-byte BC block" view.
// rt_view_fmt used to accept that pair (the decoded texture has the format-view usage flag, so the old
// usage check let it through) and attach() handed it to Metal, which aborted at pass 3426 / frame 1677.
// Gate every format-changing view on mtl_pfv_compatible before calling Metal: an unsupported view degrades
// to the base format with a red line instead of killing the process.
#ifndef S2A_NVN_PFVIEW_H
#define S2A_NVN_PFVIEW_H
#import <Metal/Metal.h>
#include <stddef.h>

// Bytes per pixel of the uncompressed colour formats; 0 for depth / stencil / block-compressed / unknown.
// (Moved out of nvn_mtl.m so the compatibility rule can be unit-tested on its own.)
static inline size_t mtl_pf_bytes(MTLPixelFormat pf) {
    switch ((int)pf) {
        case 10: case 11: case 12: case 13: case 14: return 1;                                   // R8
        case 20: case 22: case 23: case 24: case 25: case 30: case 31: case 32: case 33: case 34: return 2;   // R16 / RG8
        case 40: case 41: case 42: case 43: return 2;                                            // packed 16-bit colour
        case 53: case 54: case 55: case 60: case 62: case 63: case 64: case 65:
        case 70: case 71: case 72: case 73: case 74: case 80: case 81:
        case 90: case 91: case 92: case 93: case 94: return 4;                                   // R32 / RG16 / RGBA8 / BGRA8 / 10-10-10-2 / 11-11-10 / 9-9-9-5
        case 103: case 104: case 105: case 110: case 112: case 113: case 114: case 115: return 8;   // RG32 / RGBA16
        case 123: case 124: case 125: return 16;                                                 // RGBA32
    }
    return 0;
}

// 1 = Metal accepts a view of `view` over a texture of `base` (or no view is needed at all).
static inline int mtl_pfv_compatible(MTLPixelFormat base, MTLPixelFormat view) {
    if ((uint32_t)base == (uint32_t)view) return 1;
    size_t a = mtl_pf_bytes(base), b = mtl_pf_bytes(view);
    return a && b && a == b;
}
#endif
