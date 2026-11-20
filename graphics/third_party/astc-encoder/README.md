# Arm ASTC Encoder（只含库源码）

来源：[ARM-software/astc-encoder](https://github.com/ARM-software/astc-encoder) 标签 5.7.0 的 `Source/` 下库源码与头文件（`astcenc_*.cpp` / `astcenc*.h`），原样未改；命令行程序与图片读写（`astcenccli_*`）没带。许可 Apache-2.0，全文见 `LICENSE.txt`。

用途：出包时把 BC 贴图预转成 ASTC 4x4（Apple TV 不支持 BC 压缩贴图）。`pack/astc_pack.py` 连同 `graphics/tools/astc/bc2astc.c` 一起编成出包用的动态库（只在出包机上，不进 App / IPA）；运行时只读预转好的包（`graphics/metal/gal_astc.m`），不链这份源码。
