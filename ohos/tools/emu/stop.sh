#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# Stop only the emulator recorded in the cache pidfile.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=ohos/tools/emu/common.sh
source "${SCRIPT_DIR}/common.sh"
trap 'die "Stop failed; inspect the error above and the pidfile in ${RUN_DIR}, then retry stop.sh."' ERR
[[ -f "${RUN_DIR}/qemu.pid" ]] || exit 0
pid=$(cat "${RUN_DIR}/qemu.pid")
if qemu_running "${pid}"; then
    kill -TERM "${pid}" 2>/dev/null || true
    start=${SECONDS}
    while qemu_running "${pid}" && (( SECONDS - start < 10 )); do
        sleep 1
    done
    if qemu_running "${pid}"; then
        kill -KILL "${pid}" 2>/dev/null || die 'Could not stop QEMU; check the pidfile and stop the process manually.'
    fi
fi
rm -f "${RUN_DIR}/qemu.pid"
