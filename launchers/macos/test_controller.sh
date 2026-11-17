#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# Asset-free controller input, rendered sheets, clipping and shortcut regression tests.
set -euo pipefail
R=$(cd "$(dirname "$0")/../.." && pwd)
cd "$R"
source "$R/tools/toolchain.sh"
export CLANG_MODULE_CACHE_PATH="$R/build/macos/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$R/build/macos/swift-cache"
mkdir -p build/controller-qa
export S2A_SETTINGS_SHOTS="$R/build/controller-qa"
swift test --disable-sandbox --package-path launchers/macos/frontend --scratch-path build/macos/frontend-ui \
    --filter 'ControllerFaceMappingTests|ControllerInteractionTests|ControllerPopoverLayoutTests|HeadingLayoutTests|PadControlsTests|SettingsLayoutTests/testHomeSearch|SettingsLayoutTests/testHomeShoulders|SettingsLayoutTests/testHomeRightTrigger|SettingsLayoutTests/testOnScreenKeyboard|SettingsLayoutTests/testControllerSettings|SettingsLayoutTests/testAllUtilitySheets|SettingsLayoutTests/testExportName|SettingsLayoutTests/testExportCheckbox|SettingsLayoutTests/testExportActions|SettingsLayoutTests/testExportContent|SettingsLayoutTests/testExportSubmit|SettingsLayoutTests/testImportFooter|SettingsLayoutTests/testPlayResult|SettingsLayoutTests/testPlayFooter|SettingsLayoutTests/testStorageMode|SettingsLayoutTests/testInlineTitlebar'
