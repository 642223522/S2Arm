# AMD FidelityFX FSR1 (EASU)

- Upstream: https://github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK
- File ported: `Kits/FidelityFX/upscalers/fsr3/include/gpu/fsr1/ffx_fsr1.h`
- Git blob SHA: `2ae12de1074188695a51f55123bede2c301fdd8b`
- File sha256: `328ee880b26f400f7d8e59ffcdf55b83ae71d6de759e72f106a3c8cfc0d4cc8e` (67011 bytes)
- Retrieved: 2026-11-15 via the GitHub contents API
- Routines ported: `ffxFsrPopulateEasuConstants`, `ffxFsrEasuFloat`, `fsrEasuTapFloat`,
  `fsrEasuSetFloat` (FP32 path). The fragment port lives in
  `android/native/nvn/blit_shaders/easu.frag`; `LICENSE.txt` here is the upstream text, verbatim.
- Not ported: RCAS, the packed FP16 path. No code from BananaNative (GPL) or SGSR1.
