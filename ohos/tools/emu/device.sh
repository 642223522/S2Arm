#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# Prepare a booted emulator for host sessions, or undo the device changes.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=ohos/tools/emu/common.sh
source "${SCRIPT_DIR}/common.sh"
undo=0
if [[ $# -gt 0 ]]; then
    [[ $# -eq 1 && "$1" == --undo ]] || die 'usage: bash device.sh [--undo]'
    undo=1
fi
reachable=$(hdc_t shell echo ok 2>/dev/null | tr -d '\r[:space:]') || reachable=''
[[ "${reachable}" == ok ]] || die 'boot it first: bash ohos/tools/emu/boot.sh'
trap 'die "Device preparation failed; inspect the error above and retry device.sh."' ERR
hdc_t shell mount -o remount,rw /
icd=/system/etc/vulkan/icd.d/lavapipe.json
mkdir -p "${RUN_DIR}"
if [[ "${undo}" == 1 ]]; then
    hdc_t shell rm -f "${icd}"
    if [[ -f "${RUN_DIR}/timezone.orig" ]]; then
        zone=$(cat "${RUN_DIR}/timezone.orig")
        # Quote the saved parameter for the device shell, including any apostrophes.
        zone=$(printf '%s' "${zone}" | sed "s/'/'\\\\''/g")
        hdc_t shell "param set persist.time.timezone '${zone}'"
        rm -f "${RUN_DIR}/timezone.orig"
    fi
    log 'Removed lavapipe ICD and restored the saved time zone, if present.'
else
    hdc_t shell "mkdir -p /system/etc/vulkan/icd.d && printf '%s' '{\"file_format_version\":\"1.0.1\",\"ICD\":{\"library_path\":\"/data/storage/el1/bundle/libs/arm64/libvulkan_lvp.so\",\"api_version\":\"1.3.0\",\"library_arch\":\"64\"}}' > ${icd}"
    if [[ ! -f "${RUN_DIR}/timezone.orig" ]]; then
        zone=$(hdc_t shell param get persist.time.timezone | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        printf '%s\n' "${zone}" > "${RUN_DIR}/timezone.orig"
    fi
    hdc_t shell param set persist.time.timezone UTC
    log 'Installed app-sandbox lavapipe ICD (SwiftShader retained); saved time zone and set UTC.'
fi
