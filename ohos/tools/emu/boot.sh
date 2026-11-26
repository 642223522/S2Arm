#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# Start QEMU and wait over hdc until OHOS has booted and the launcher is ready.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=ohos/tools/emu/common.sh
source "${SCRIPT_DIR}/common.sh"
trap 'die "Boot failed; inspect the error above and the logs in ${RUN_DIR}, then retry boot.sh."' ERR
: "${BOOT_TIMEOUT:=180}"
[[ -x "${HDC}" ]] || die 'Missing hdc; run setup.sh first.'
mkdir -p "${RUN_DIR}"
pid=''
[[ ! -f "${RUN_DIR}/qemu.pid" ]] || pid=$(cat "${RUN_DIR}/qemu.pid")
if qemu_running "${pid}"; then
    log 'already running'
else
    need qemu-system-aarch64 'brew install qemu, then run setup.sh'
    for image in Image ramdisk.img updater.img system.img vendor.img sys_prod.img chip_prod.img userdata.img; do
        [[ -f "${IMAGES}/${image}" ]] || die "Missing ${image}; run setup.sh first."
    done
    accel=tcg
    case "$(uname -s)" in
        Darwin) accel=hvf ;;
        Linux) [[ ! -w /dev/kvm ]] || accel=kvm ;;
    esac
    cpu=host
    if [[ "${accel}" == tcg ]]; then
        cpu=cortex-a57
        log 'Warning: TCG is very slow.'
    fi
    nohup qemu-system-aarch64 -accel "${accel}" -M virt -cpu "${cpu}" -smp "${EMU_SMP}" -m "${EMU_MEM_MB}" \
        -kernel "${IMAGES}/Image" -initrd "${IMAGES}/ramdisk.img" \
        -device virtio-gpu-pci,xres=800,yres=500 -display none -monitor none -serial "file:${RUN_DIR}/serial.log" \
        -device virtio-tablet-pci -device virtio-keyboard-pci -device virtio-rng-pci \
        -rtc base=utc,clock=host \
        -netdev "user,id=net0,hostfwd=tcp:127.0.0.1:${HDC_PORT}-:5555" -device virtio-net-device,netdev=net0,mac=52:54:00:12:34:56 \
        -drive "if=none,file=${IMAGES}/updater.img,format=raw,id=updater,file.locking=off" -device virtio-blk-device,drive=updater,serial=updater \
        -drive "if=none,file=${IMAGES}/system.img,format=raw,id=system,file.locking=off" -device virtio-blk-device,drive=system,serial=system \
        -drive "if=none,file=${IMAGES}/vendor.img,format=raw,id=vendor,file.locking=off" -device virtio-blk-device,drive=vendor,serial=vendor \
        -drive "if=none,file=${IMAGES}/sys_prod.img,format=raw,id=sys_prod" -device virtio-blk-device,drive=sys_prod,serial=sys_prod \
        -drive "if=none,file=${IMAGES}/chip_prod.img,format=raw,id=chip_prod" -device virtio-blk-device,drive=chip_prod,serial=chip_prod \
        -drive "if=none,file=${IMAGES}/userdata.img,format=raw,id=userdata" -device virtio-blk-device,drive=userdata,serial=userdata \
        -append 'oemmode=rd buildvariant=eng developer_mode=1 default_boot_device=a003e00.virtio_mmio sn=s2a-emu-0001 ip=dhcp loglevel=4 console=ttyAMA0,115200 init=/bin/init ohos.boot.hardware=virt root=/dev/ram0 rw ohos.required_mount.system=/dev/block/vde@/usr@ext4@ro,barrier=1@wait,required ohos.required_mount.vendor=/dev/block/vdd@/vendor@ext4@ro,barrier=1@wait,required ohos.required_mount.sys_prod=/dev/block/vdc@/sys_prod@ext4@rw,barrier=1@wait,required ohos.required_mount.chip_prod=/dev/block/vdb@/chip_prod@ext4@rw,barrier=1@wait,required ohos.required_mount.data=/dev/block/vda@/data@f2fs@nosuid,nodev,noatime,usrquota,grpquota,prjquota@wait,required,reservedsize=104857600' \
        >"${RUN_DIR}/qemu.out" 2>&1 < /dev/null &
    pid=$!
    printf '%s\n' "${pid}" > "${RUN_DIR}/qemu.pid"
fi
start=${SECONDS}
while :; do
    # Liveness only: right after the fork the child is still `nohup`/`bash`, not qemu yet.
    if ! kill -0 "${pid}" 2>/dev/null; then
        tail -n 20 "${RUN_DIR}/qemu.out" 2>/dev/null | sed 's/^/[emu] /' >&2 || true
        die "QEMU exited; inspect ${RUN_DIR}/qemu.out and rerun boot.sh."
    fi
    "${HDC}" tconn "127.0.0.1:${HDC_PORT}" >/dev/null 2>&1 || true
    # boot.completed alone is too early: until the launcher votes ready it still terminates the
    # apps it finds running (an app started in between is killed with "app exit").
    completed=$(hdc_t shell param get bootevent.boot.completed 2>/dev/null | tr -d '\r[:space:]') || completed=''
    launcher=$(hdc_t shell param get bootevent.launcher.ready 2>/dev/null | tr -d '\r[:space:]') || launcher=''
    if [[ "${completed}" == true && "${launcher}" == true ]]; then
        log "Boot completed in $((SECONDS - start)) seconds."
        break
    fi
    if (( SECONDS - start >= BOOT_TIMEOUT )); then
        tail -n 20 "${RUN_DIR}/serial.log" 2>/dev/null | sed 's/^/[emu] /' >&2 || true
        die "Boot timed out; inspect ${RUN_DIR}/serial.log. The emulator is still running; stop with bash ${SCRIPT_DIR}/stop.sh."
    fi
    sleep 3
done
