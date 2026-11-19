#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# Install a host HAP, import a resource pack and wait for its first frame.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=ohos/tools/emu/common.sh
source "${SCRIPT_DIR}/common.sh"
hap=''
pack=''
key=''
title=''
timeout=900
keep=0
started=0
tmp=''
usage='usage: bash host-smoke.sh --hap <unsigned.hap> --pack <resource.tar> --key <key> --title <16-hex id> [--timeout <seconds>] [--keep]'
while [[ $# -gt 0 ]]; do
    case "$1" in
        --hap|--pack|--key|--title|--timeout)
            [[ $# -ge 2 && -n "$2" ]] || die "${usage}"
            case "$1" in
                --hap) hap=$2 ;;
                --pack) pack=$2 ;;
                --key) key=$2 ;;
                --title) title=$2 ;;
                --timeout) timeout=$2 ;;
            esac
            shift 2 ;;
        --keep) keep=1; shift ;;
        *) die "${usage}" ;;
    esac
done
[[ -f "${hap}" && -f "${pack}" && -n "${key}" ]] || die "${usage}"
[[ "${title}" =~ ^[[:xdigit:]]{16}$ ]] || die 'Title must be a 16-hex program id.'
[[ "${timeout}" =~ ^[1-9][0-9]*$ ]] || die 'Timeout must be a positive integer.'
# Keys go into both JSON and device shell arguments; encode each independently.
need python3 'install Python 3'
key_json=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "${key}")
key_shell=$(printf '%s' "${key}" | sed "s/'/'\\\\''/g")
title=$(printf '%s' "${title}" | tr '[:lower:]' '[:upper:]')
for lib in libvulkan_lvp.so libssl.so.3 libcrypto.so.3; do
    [[ -f "${OHOS_EMU_HOME}/lavapipe/out/${lib}" ]] || die 'run bash ohos/tools/emu/lavapipe/build.sh'
done
need zip 'install zip'
need unzip 'install unzip'
cleanup() {
    local status=$?
    trap - EXIT
    [[ -z "${tmp}" ]] || rm -rf "${tmp}"
    if [[ "${started}" == 1 && "${keep}" == 0 ]]; then
        bash "${SCRIPT_DIR}/stop.sh" || status=1
    fi
    exit "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'die "Host smoke failed; inspect the error above and retry host-smoke.sh."' ERR
work="${OHOS_EMU_HOME}/host-smoke"
mkdir -p "${work}"
unsigned="${work}/host-unsigned.hap"
signed="${work}/host-signed.hap"
cp "${hap}" "${unsigned}"
tmp=$(mktemp -d "${work}/libs.XXXXXX")
mkdir -p "${tmp}/libs/arm64-v8a"
for lib in libvulkan_lvp.so libssl.so.3 libcrypto.so.3; do
    cp "${OHOS_EMU_HOME}/lavapipe/out/${lib}" "${tmp}/libs/arm64-v8a/"
done
cp "${unsigned}" "${tmp}/host.hap"
(cd "${tmp}" && zip -0 -r host.hap libs)
cp "${tmp}/host.hap" "${unsigned}"
bash "${SCRIPT_DIR}/sign.sh" "${unsigned}" "${signed}" io.s2arm.ohos.dev
reachable=$(hdc_t shell echo ok 2>/dev/null | tr -d '\r[:space:]') || reachable=''
if [[ "${reachable}" != ok ]]; then
    pid=''
    [[ ! -f "${RUN_DIR}/qemu.pid" ]] || pid=$(cat "${RUN_DIR}/qemu.pid")
    if ! qemu_running "${pid}"; then
        started=1
    fi
    bash "${SCRIPT_DIR}/boot.sh"
fi
bash "${SCRIPT_DIR}/device.sh"
output=$(hdc_t install -r "${signed}") || die 'Install failed; inspect hdc output.'
printf '%s\n' "${output}"
[[ "${output}" == *'install bundle successfully'* ]] || die 'Install did not report success.'
D=/data/app/el2/100/base/io.s2arm.ohos.dev/haps/entry/files
hdc_t shell aa start -a EntryAbility -b io.s2arm.ohos.dev
# hdc can return zero for failed shell commands; use explicit success markers.
wait_path() {
    local path="$1" limit="$2" start=${SECONDS} found
    while :; do
        found=$(hdc_t shell "test -e '${path}' && echo EXISTS" 2>/dev/null | tr -d '\r[:space:]') || found=''
        [[ "${found}" != EXISTS ]] || return 0
        (( SECONDS - start < limit )) || return 1
        sleep 3
    done
}
wait_path "${D}" 60 || die 'App data directory did not appear within 60 s.'
owner=$(hdc_t shell stat -c %u:%g "${D}" | tr -d '\r[:space:]')
[[ "${owner}" =~ ^[0-9]+:[0-9]+$ ]] || die 'Could not read app data owner uid:gid.'
id=hs$(date +%s)
import="${D}/games/.import-${id}"
archive="${D}/import-${id}.tar"
output=$(hdc_t file send "${pack}" "${archive}") || output=''
if [[ "${output}" != *'FileTransfer finish'* ]]; then
    hdc_t shell "rm -f ${archive}; rm -rf ${import}" || true
    die 'Pack transfer failed; inspect hdc output.'
fi
output=$(hdc_t shell "mkdir -p ${import} && tar -xmf ${archive} -C ${import} && rm -f ${archive} && echo IMPORT_OK") || output=''
if [[ "${output}" != *IMPORT_OK* ]]; then
    hdc_t shell "rm -f ${archive}; rm -rf ${import}" || true
    die 'Pack extraction failed; removed the partial import.'
fi
fonts="${OHOS_EMU_HOME}/openfonts"
if [[ ! -f "${fonts}/nintendo_udsg-r_std_003.bfttf" ]]; then
    repo=$(cd "${SCRIPT_DIR}/../../.." && pwd)
    if ! python3 "${repo}/pack/fonts/make_open_fonts.py" "${fonts}"; then
        log 'Warning: open font generation failed; continuing with available fonts.'
    fi
fi
hdc_t shell mkdir -p "${import}/game/systemdata/fonts"
for font in "${fonts}"/*.bfttf; do
    [[ -f "${font}" ]] || continue
    output=$(hdc_t file send "${font}" "${import}/game/systemdata/fonts/$(basename "${font}")") || output=''
    [[ "${output}" == *'FileTransfer finish'* ]] || die 'Font transfer failed; inspect hdc output.'
done
S="${D}/states/${title}"
pending="${D}/pending-import-${id}.json"
# JSON contains arbitrary key text; quote the whole document for the device shell.
payload=$(printf '{"key":%s,"directory":".import-%s"}' "${key_json}" "${id}" | sed "s/'/'\\\\''/g")
hdc_t shell "mkdir -p ${S} && printf 'DEBUG_S2A_AUDIO=dummy\nDEBUG_S2A_VA39=1\n' > ${S}/debug-env.txt && printf 'direct\n' > ${S}/graphics_mode && printf '%s' '${payload}' > ${pending} && chown -R ${owner} ${D}/games ${D}/states ${pending}"
hdc_t shell aa force-stop io.s2arm.ohos.dev
hdc_t shell aa start -a EntryAbility -b io.s2arm.ohos.dev
wait_path "${pending}.done" 120 || die 'Import did not finalize within 120 s.'
hdc_t shell aa force-stop io.s2arm.ohos.dev
# Do not count a previous session's first frame while the new log is being created.
previous=$(hdc_t shell "ls -t ${S}/host-*.log | head -1" 2>/dev/null | tr -d '\r' | sed 's/[[:space:]]*$//') || previous=''
hdc_t shell "aa start -a EntryAbility -b io.s2arm.ohos.dev --ps s2armLaunchId ${id} --ps s2armGameKey '${key_shell}'"
start=${SECONDS}
session=''
while :; do
    session=$(hdc_t shell "ls -t ${S}/host-*.log | head -1" 2>/dev/null | tr -d '\r' | sed 's/[[:space:]]*$//') || session=''
    case "${session}" in
        "${S}/host-"*.log)
            line=$(hdc_t shell "grep '首帧上屏' '${session}'" 2>/dev/null | tr -d '\r') || line=''
            if [[ "${session}" != "${previous}" && -n "${line}" ]]; then
                printf '%s\n' "${line}"
                hdc_t shell "grep '第 1 帧已交给呈现' '${session}' | head -1" || true
                log "first frame in $((SECONDS - start)) s"
                exit 0
            fi ;;
    esac
    (( SECONDS - start < timeout )) || break
    remaining=$((timeout - (SECONDS - start)))
    if (( remaining < 10 )); then sleep "${remaining}"; else sleep 10; fi
done
if [[ -n "${session}" ]]; then
    hdc_t shell "tail -n 40 '${session}' | grep -v '栈扫描'" || true
fi
hdc_t shell cat "${D}/launch-results/launch-result-${id}.json" || true
die "no first frame within ${timeout} s"
