// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#include "LauncherPadBridge.h"
#include "../../../../../runtime/include/s2a_pad_face.h"

int s2a_launcher_face_valid(int map) { return s2a_face_valid(map); }
int s2a_launcher_face_source(int map, int target) { return s2a_face_source(map, target); }
uint64_t s2a_launcher_face_apply(uint64_t buttons, int map) { return s2a_face_apply(buttons, map); }
