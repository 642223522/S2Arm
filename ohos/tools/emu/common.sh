#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# Share emulator paths, defaults and helpers.
set -euo pipefail

: "${OHOS_EMU_HOME:=${HOME}/.cache/s2arm-ohos-emu}"
: "${OHOS_SDK_URL:=https://repo.huaweicloud.com/openharmony/os/7.0-Release/L2-SDK-MAC-M1-PUBLIC.tar.gz}"
: "${OHOS_SDK_SHA256:=df46e398b391d3406d1eb05e7322c5874f6bf6821e93b1211b36cfcf7a0bbf6f}"
: "${OHOS_SDK_API:=26.0.0}"
: "${OHOS_IMAGE_URL:=https://github.com/harmony-contrib/ohos-qemu/releases/download/v20261114/openharmony-qemu-arm64-arm64_virt-phone.tar.gz}"
: "${OHOS_IMAGE_SHA256:=5af7384040ae090f01e559d09564caeb4db2c292fcc286f256293ec9994ddab7}"
: "${HVIGOR_VERSION:=6.26.20}"
: "${HVIGOR_REGISTRY:=https://repo.harmonyos.com/npm/}"
: "${HDC_PORT:=5555}" "${EMU_MEM_MB:=6144}" "${EMU_SMP:=4}"
SDK_ROOT="${OHOS_EMU_HOME}/sdk"
SDK_DIR="${SDK_ROOT}/${OHOS_SDK_API}"
IMAGES="${OHOS_EMU_HOME}/image/openharmony-qemu-arm64-arm64_virt-phone/images"
HDC="${SDK_DIR}/toolchains/hdc"
HVIGOR_DIR="${OHOS_EMU_HOME}/hvigor"
RUN_DIR="${OHOS_EMU_HOME}/run"

die() { printf '[emu] %s\n' "$*" >&2; exit 1; }
log() { printf '[emu] %s\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing $1; $2"; }
sha256_of() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        die 'Install shasum or sha256sum, then retry.'
    fi
}
fetch() {
    local url="$1" sha="$2" out="$3"
    if [[ -f "${out}" ]] && [[ "$(sha256_of "${out}")" == "${sha}" ]]; then
        return
    fi
    mkdir -p "$(dirname "${out}")"
    log "Downloading ${url}"
    curl -fL --retry 3 -o "${out}.partial" "${url}" || die "Download failed; retry setup.sh (${url})."
    [[ "$(sha256_of "${out}.partial")" == "${sha}" ]] || die "Checksum mismatch for ${out}.partial; remove it and retry setup.sh."
    mv "${out}.partial" "${out}"
}
hdc_t() { "${HDC}" -t "127.0.0.1:${HDC_PORT}" "$@"; }
java_home() {
    local found
    if [[ -n "${JAVA_HOME:-}" && -x "${JAVA_HOME}/bin/java" ]]; then
        printf '%s\n' "${JAVA_HOME}"
    elif [[ -x /opt/homebrew/opt/openjdk@17/bin/java ]]; then
        printf '%s\n' /opt/homebrew/opt/openjdk@17
    elif [[ -x /usr/libexec/java_home ]] && found=$(/usr/libexec/java_home -v 17 2>/dev/null) && [[ -x "${found}/bin/java" ]]; then
        printf '%s\n' "${found}"
    else
        die 'install JDK 17, e.g. brew install openjdk@17'
    fi
}

# Check process identity as well as liveness before reusing or stopping a PID.
qemu_running() {
    local pid="${1:-}"
    case "${pid}" in ''|*[!0-9]*) return 1 ;; esac
    [[ "${pid}" -gt 1 ]] && kill -0 "${pid}" 2>/dev/null || return 1
    # No `ps | grep -q`: under pipefail grep's early exit makes ps die of SIGPIPE at random.
    local comm
    comm=$(ps -p "${pid}" -o comm= 2>/dev/null) || return 1
    [[ "${comm}" == *qemu-system-aarch64* ]]
}
