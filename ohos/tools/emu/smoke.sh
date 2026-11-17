#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# Build, sign and run the smoke HAP and collect its result.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=ohos/tools/emu/common.sh
source "${SCRIPT_DIR}/common.sh"
trap 'die "Smoke failed; inspect the error above and ${OHOS_EMU_HOME}/smoke-build/build.log, then retry smoke.sh."' ERR
no_net=0
keep=0
started=0
for arg in "$@"; do
    case "${arg}" in
        --no-net) no_net=1 ;;
        --keep) keep=1 ;;
        *) die "Unknown option ${arg}; use --no-net and/or --keep." ;;
    esac
done
[[ -d "${SDK_DIR}/ets" && -f "${HVIGOR_DIR}/node_modules/@ohos/hvigor/package.json" ]] || die 'run setup.sh first'
cleanup() {
    local status=$?
    trap - EXIT
    if [[ "${started}" == 1 && "${keep}" == 0 ]]; then
        bash "${SCRIPT_DIR}/stop.sh" || status=1
    fi
    exit "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
work="${OHOS_EMU_HOME}/smoke-build"
rm -rf "${work}"
mkdir -p "${work}"
cp -R "${SCRIPT_DIR}/smoke/hap" "${work}/hap"
python3 "${SCRIPT_DIR}/smoke/gen_resources.py" "${work}/hap"
ln -s "${HVIGOR_DIR}/node_modules" "${work}/hap/node_modules"
if [[ "${no_net}" == 0 ]]; then
    [[ -f "${SCRIPT_DIR}/smoke/netprobe/link.sh" ]] || die 'Provide smoke/netprobe/link.sh, or rerun with --no-net.'
    bash "${SCRIPT_DIR}/smoke/netprobe/link.sh" "${work}/hap/entry/libs/arm64-v8a" || die 'NativeAOT build failed; inspect its output and retry.'
fi
JAVA_HOME=$(java_home)
export JAVA_HOME
if ! (
    cd "${work}/hap"
    export OHOS_BASE_SDK_HOME="${SDK_ROOT}" PATH="${JAVA_HOME}/bin:${PATH}"
    node node_modules/@ohos/hvigor/bin/hvigor.js --mode module -p module=entry@default \
        -p product=default -p buildMode=debug assembleHap --no-daemon
) >"${work}/build.log" 2>&1; then
    awk '/ERROR|error:|FAILED/ { if (++n <= 40) print "[emu] " $0 }' "${work}/build.log" >&2
    die "Build failed; inspect ${work}/build.log and retry."
fi
unsigned="${work}/hap/entry/build/default/outputs/default/entry-default-unsigned.hap"
signed="${work}/smoke-signed.hap"
[[ -f "${SCRIPT_DIR}/sign.sh" ]] || die 'Provide ohos/tools/emu/sign.sh, then rerun smoke.sh.'
bash "${SCRIPT_DIR}/sign.sh" "${unsigned}" "${signed}" org.s2arm.emu.smoke || die 'Signing failed; inspect sign.sh output and retry.'
reachable=$(hdc_t shell echo ok 2>/dev/null | tr -d '\r[:space:]') || reachable=''
if [[ "${reachable}" != ok ]]; then
    pid=''
    [[ ! -f "${RUN_DIR}/qemu.pid" ]] || pid=$(cat "${RUN_DIR}/qemu.pid")
    if ! qemu_running "${pid}"; then
        started=1
    fi
    bash "${SCRIPT_DIR}/boot.sh" || die 'Boot failed; inspect emulator logs and rerun smoke.sh.'
fi
# Report only crash logs written by this run (older ones are left alone). Their names carry the
# device time (…-YYYYMMDDhhmmssSSS.log); listing before/after is not enough because faultlogger
# may file a previous boot's logs late.
since=$(hdc_t shell date +%Y%m%d%H%M%S | tr -d '\r[:space:]')000
install_output=$(hdc_t install -r "${signed}") || die 'Install failed; inspect hdc output and retry.'
printf '%s\n' "${install_output}" | sed 's/^/[emu] /'
[[ "${install_output}" == *'install bundle successfully'* ]] || die 'Install did not report success; inspect hdc output and retry.'
hdc_t shell aa force-stop org.s2arm.emu.smoke
# install -r keeps app data: drop the previous run's result so it cannot be read as this run's.
hdc_t shell rm -f /data/app/el2/100/base/org.s2arm.emu.smoke/haps/entry/files/smoke.txt
hdc_t shell aa start -a EntryAbility -b org.s2arm.emu.smoke
start=${SECONDS}
result=''
while (( SECONDS - start < 60 )); do
    contents=$(hdc_t shell cat /data/app/el2/100/base/org.s2arm.emu.smoke/haps/entry/files/smoke.txt 2>/dev/null | tr -d '\r') || contents=''
    result=$(printf '%s\n' "${contents}" | awk '/^RESULT / {print; exit}')
    [[ -z "${result}" ]] || break
    sleep 3
done
printf '%s\n' "${contents}" > "${OHOS_EMU_HOME}/smoke-result.txt"
[[ -z "${result}" ]] || log "${result}"
crashes=$(hdc_t shell ls /data/log/faultlog/faultlogger/ 2>/dev/null | tr -d '\r' |
    awk -v since="${since}" '/org\.s2arm\.emu\.smoke/ { n = split($0, f, "-"); t = f[n]; sub(/\.log$/, "", t); if ((t "") >= (since "")) print }') || crashes=''
if [[ -n "${crashes}" ]]; then
    while IFS= read -r crash; do
        log "Crash log: ${crash}"
        hdc_t shell cat "/data/log/faultlog/faultlogger/${crash}" | awk '/Reason:/ {print "[emu] " $0}' || true
    done <<< "${crashes}"
fi
pid=$(hdc_t shell pidof org.s2arm.emu.smoke 2>/dev/null | tr -d '\r' | sed 's/[[:space:]]*$//') || pid=''
alive=0
if [[ "${pid}" =~ ^[0-9]+([[:space:]][0-9]+)*$ ]]; then
    alive=1
    log "Smoke process is alive: ${pid}"
else
    log 'Smoke process is not alive.'
fi
[[ -n "${result}" ]] || die "No RESULT within 60 seconds; inspect ${OHOS_EMU_HOME}/smoke-result.txt and crash logs."
[[ "${no_net}" == 1 || "${result}" == *'net=ran'* ]] || die 'NativeAOT probe did not run (net=skipped); inspect smoke-result.txt.'
# Faults the runtime recovers from must not reach the crash collector (see smoke/netprobe/ohos_shim.c).
[[ -z "${crashes}" ]] || die 'Crash log written during the smoke run; see the Reason lines above.'
[[ "${result}" == 'RESULT pass'* && "${alive}" == 1 ]] || die 'Smoke failed; inspect smoke-result.txt and crash logs, then retry.'
