#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Source wiring checks only; not a JVM or Android UI acceptance test."""
from pathlib import Path
import sys
import xml.etree.ElementTree as ET
root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2]
java = root / 'android/app/src/main/java/org/s2arm/android'
view = (java / 'TouchPadView.java').read_text()
model = (java / 'TouchLayout.java').read_text()
activity = (java / 'MainActivity.java').read_text()
assert 'withButtonScale(double factor)' in model, 'button resizing is absent'
assert 'pad.editedLayout(TouchLayoutStore.MINE, "My layout").withButtonScale(factor)' in view
assert 'if (editing) return color' in view
assert 'appearanceColor(c.pressed ? 0xAAFFFFFF : 0x55FFFFFF)' in view
assert 'ring.setColor(appearanceColor(0x99FFFFFF))' in view
assert 'text.setColor(appearanceColor(0xCCFFFFFF))' in view
assert 'putInt("touch_opacity_percent", slider.getProgress())' in activity
assert 'getInt("touch_opacity_percent", 100)' in activity
assert '.setOnCancelListener(dialog -> touchPad.setOpacityPercent(original))' in activity
assert 'opacity' not in model.lower(), 'opacity must remain outside F01'
for locale in ('values', 'values-zh'):
    strings = ET.parse(root / 'android/app/src/main/res' / locale / 'strings.xml')
    for key in ('opacity', 'smaller', 'larger'):
        assert len(strings.findall(f"string[@name='touch_appearance_{key}']")) == 1
print('PASS: 16 source/resource assertions (not JVM/device execution)')
