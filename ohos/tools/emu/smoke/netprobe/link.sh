#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# Build the NativeAOT probe for linux-musl-arm64 and link it with the OHOS clang into libnetprobe.so.
# Usage: bash link.sh <output-dir>   (negative controls: NETPROBE_NO_MEMPOLICY_SHIM=1, NETPROBE_NO_FAULT_FORWARD=1)
#
# ILC runs on the host and emits an ELF object; the host's own archiver/linker cannot package it for
# OHOS, so only the object is taken and linked here against the runtime pack's static libraries.
# Two OHOS app-process gaps are filled inside this library (ohos_shim.c): pthread_setcancelstate and
# the seccomp-killed get_mempolicy that the GC's NUMA probe issues (via).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=../../common.sh
source "${here}/../../common.sh"
[ $# -eq 1 ] || die "usage: link.sh <output-dir>"
mkdir -p "$1"; outdir=$(cd "$1" && pwd)
dotnet=${DOTNET:-$(command -v dotnet || echo "${HOME}/.dotnet/dotnet")}
[ -x "${dotnet}" ] || die "dotnet SDK not found; set DOTNET or install the version in compat/tree/global.json"
work=${OHOS_EMU_HOME}/netprobe-build
rm -rf "${work}"; mkdir -p "${work}"
cp "${here}/NetProbe.csproj" "${here}/Probe.cs" "${work}/"
# The SDK (and with it the runtime version) is the one the repository pins.
cp "${here}/../../../../../compat/tree/global.json" "${work}/global.json"
DOTNET_CLI_TELEMETRY_OPTOUT=1 "${dotnet}" publish "${work}/NetProbe.csproj" -c Release -r linux-musl-arm64 \
    -p:StripSymbols=false -o "${work}/out" -nologo > "${work}/publish.log" 2>&1 \
    || { tail -20 "${work}/publish.log" >&2; die "dotnet publish failed"; }
obj=${work}/obj/Release/net10.0/linux-musl-arm64/native/NetProbe.o
[ -f "${obj}" ] || die "ILC object not found: ${obj}"
ver=$(python3 -c 'import json, sys
libs = json.load(open(sys.argv[1]))["libraries"]
print(next(k.split("/")[1] for k in libs if k.startswith("Microsoft.DotNet.ILCompiler/")))' "${work}/obj/project.assets.json") \
    || die "cannot read the restored ILCompiler version"
rt=${NUGET_PACKAGES:-${HOME}/.nuget/packages}/microsoft.netcore.app.runtime.nativeaot.linux-musl-arm64/${ver}/runtimes/linux-musl-arm64/native
[ -d "${rt}" ] || die "NativeAOT runtime pack for linux-musl-arm64 not restored"
cc=("${SDK_DIR}/native/llvm/bin/clang" --target=aarch64-linux-ohos "--sysroot=${SDK_DIR}/native/sysroot")
# NETPROBE_NO_MEMPOLICY_SHIM=1 builds the negative control: the GC's NUMA probe reaches seccomp.
wrap=(-Wl,--wrap=syscall); shim_def=()
if [ "${NETPROBE_NO_MEMPOLICY_SHIM:-0}" = 1 ]; then wrap=(); shim_def=(-DS2A_NO_MEMPOLICY_SHIM); log "negative control: no get_mempolicy shim"; fi
# NETPROBE_NO_FAULT_FORWARD=1 builds the other negative control: handled faults reach the crash collector.
if [ "${NETPROBE_NO_FAULT_FORWARD:-0}" = 1 ]; then shim_def+=(-DS2A_NO_FAULT_FORWARD); log "negative control: no fault forwarding"; fi
"${cc[@]}" -O2 -fPIC ${shim_def[@]+"${shim_def[@]}"} -c "${here}/ohos_shim.c" -o "${work}/ohos_shim.o"
"${cc[@]}" -shared -fuse-ld=lld -o "${outdir}/libnetprobe.so" "${obj}" "${work}/ohos_shim.o" "${rt}/libbootstrapperdll.o" \
    -Wl,--whole-archive "${rt}/libRuntime.WorkstationGC.a" -Wl,--no-whole-archive \
    "${rt}/libeventpipe-disabled.a" "${rt}/libstandalonegc-disabled.a" "${rt}/libaotminipal.a" \
    "${rt}/libSystem.Native.a" "${rt}/libstdc++compat.a" -lc++abi -lm -ldl -lpthread \
    -Wl,-z,noexecstack -Wl,--gc-sections -Wl,-z,nostart-stop-gc ${wrap[@]+"${wrap[@]}"} -Wl,-u,s2a_dotnet_probe
log "linked ${outdir}/libnetprobe.so (NativeAOT ${ver})"
