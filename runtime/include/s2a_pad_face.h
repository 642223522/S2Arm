// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#ifndef S2A_PAD_FACE_H
#define S2A_PAD_FACE_H
#include <stdint.h>

// Four 2-bit source indices, in target A/B/X/Y order. Sources are the system's
// A/B/X/Y (PlayStation Cross/Circle/Square/Triangle), or Nintendo A/B/X/Y.
// A permutation keeps every physical button usable; rebinding swaps two targets.
enum { S2A_FACE_IDENTITY = 0xe4, S2A_FACE_SWITCH_POSITION = 0xb1 };
static inline int s2a_face_source(int map, int target) { return (map >> (target * 2)) & 3; }
static inline int s2a_face_valid(int map) {
    if (map < 0 || map > 255) return 0;
    unsigned seen = 0;
    for (int i = 0; i < 4; i++) seen |= 1u << s2a_face_source(map, i);
    return seen == 15;
}
static inline uint64_t s2a_face_apply(uint64_t buttons, int map) {
    uint64_t result = buttons & ~UINT64_C(15);
    if (!s2a_face_valid(map)) map = S2A_FACE_IDENTITY;
    for (int i = 0; i < 4; i++) result |= ((buttons >> s2a_face_source(map, i)) & 1) << i;
    return result;
}

typedef struct { uint64_t since; int down, latched, visible; } s2a_face_overlay_hold;
// One toggle per one-second chord. Disconnect and focus loss clear the overlay;
// a chord already held on focus gain must be released before it can toggle.
static inline int s2a_face_overlay_step(s2a_face_overlay_hold *s, uint64_t now, int chord, int available) {
    if (!available) { s->visible = 0; s->down = 0; s->latched = chord; return 0; }
    if (!chord) { s->down = 0; s->latched = 0; }
    else if (!s->latched) {
        if (!s->down) { s->down = 1; s->since = now; }
        else if (now - s->since >= UINT64_C(1000000000)) { s->visible = !s->visible; s->latched = 1; }
    }
    return s->visible;
}
#endif
