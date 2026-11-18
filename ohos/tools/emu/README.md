<!-- SPDX-License-Identifier: Apache-2.0 -->
<!-- Copyright 2026 S2Arm contributors -->
# OHOS emulator smoke

Boot an OpenHarmony 7.0 phone emulator headless, build and sign a HAP with the public SDK
(no Huawei account), install it and read back a pass/fail line. For contributors without a
HarmonyOS device and for automated checks. The emulator renders with SwiftShader: it checks
function, not performance. This is a manual tool: it is not part of the merge gate or the
merge train, so hosts without QEMU are unaffected.

```sh
bash ohos/tools/emu/setup.sh     # once: SDK, image, hvigor into ~/.cache/s2arm-ohos-emu
bash ohos/tools/emu/smoke.sh     # build + sign + install + run; boots and stops the emulator
bash ohos/tools/emu/boot.sh      # or keep one running: hdc -t 127.0.0.1:5555 ...
bash ohos/tools/emu/stop.sh
```

`smoke.sh --keep` leaves an emulator it started running; one that was already running is never
stopped. `--no-net` skips the NativeAOT library.

Needs Apple silicon (HVF) or Linux aarch64 with KVM; other hosts fall back to TCG and are very
slow. Host tools: qemu, node, ninja, JDK 17, Python 3, curl; the NativeAOT step also needs the
.NET 10 SDK (`compat/tree/global.json`). All downloads and generated files, including the
regenerated signing certificates, live in `OHOS_EMU_HOME` (default `~/.cache/s2arm-ohos-emu`);
nothing is written into the repository. QEMU writes to the image directory (`userdata.img`):
to reset the device, stop it, delete `${OHOS_EMU_HOME}/image` and rerun `setup.sh`.

## External inputs

Downloaded, verified against the SHA-256 in `common.sh`, never redistributed:

| Input | Version | Source |
|---|---|---|
| OpenHarmony public SDK | API 26.0.0.38 (7.0-Release, macOS arm64) | repo.huaweicloud.com/openharmony/os/7.0-Release/L2-SDK-MAC-M1-PUBLIC.tar.gz |
| Emulator image | OpenHarmony 7.0.0.39, arm64 virt phone, release v20261114 | github.com/harmony-contrib/ohos-qemu |
| hvigor, hvigor-ohos-plugin | 6.26.20 | repo.harmonyos.com/npm |
| NativeAOT runtime pack linux-musl-arm64 | follows the SDK pinned in `compat/tree/global.json` (10.0.403 → 10.0.14 today) | nuget.org (restored by `dotnet publish`) |

## What the smoke HAP checks

Inside the app process (SELinux domain `normal_hap`), written to the app's `files/smoke.txt`:

- exec memory: anonymous RW→RX, RX→RW→RX re-patch, memfd W/X double mapping;
- guest window: a 64 GiB gap below 2^39 found in `/proc/self/maps` and reserved with
  `MAP_FIXED_NOREPLACE` (fixed addresses are not free: the app already has mappings there);
- shared alias through `mremap(old_size=0)`;
- Vulkan: instance with `VK_OHOS_surface`, device, clear + readback;
- .NET NativeAOT (`smoke/netprobe`): runtime start, GC, managed exceptions, a hardware fault
  (null reference on a worker thread) recovered by the runtime, thread pool, async.

The last line is `RESULT pass fails=0 net=ran`. `smoke.sh` also requires the process to be
alive afterwards and no new crash log from the run. Negative controls (each must fail):
`NETPROBE_NO_MEMPOLICY_SHIM=1` (process killed by SIGSYS) and `NETPROBE_NO_FAULT_FORWARD=1`
(crash log for a fault the runtime handled).

## OHOS specifics found here

- hvigor needs `<OHOS_BASE_SDK_HOME>/26.0.0/{ets,js,native,previewer,toolchains}`; without
  previewer it reports the license as not accepted. API 26 versions are strings (`"26.0.0"`),
  `deviceTypes` must be `["default"]`.
- The SDK's bundled ninja is x86_64 only; `setup.sh` links the host ninja in its place.
- The certificates in the SDK's `OpenHarmony.p12` do not chain; `sign.sh` regenerates
  root → sub CA → app certificates from the same keys and subjects.
- The app seccomp filter kills the process on `get_mempolicy`, which the .NET GC issues at
  start; `ohos_shim.c` returns ENOSYS through `-Wl,--wrap=syscall`. OHOS musl has no
  `pthread_setcancelstate`; the shim provides a no-op.
- OHOS musl's sigchain runs "special" handlers (ArkTS runtime, then the crash collector DFX)
  before the handler installed with `sigaction`. DFX writes a cppcrash for every SIGSEGV, also
  ones the .NET runtime then recovers from. `ohos_shim.c` registers a special handler that hands
  faults with a PC in the library's code to the runtime's handler and stops the chain. A fault
  on the ArkTS (UI) thread still gets the app terminated by the ArkTS runtime's handler, which
  runs first: keep fault-prone code off that thread.
- The emulator image runs SELinux permissive; sandbox results need a real device to confirm.
  No geometry or tessellation shaders in SwiftShader.

Details and readings: `docs/坑记录.md` (entries dated 11-16).
