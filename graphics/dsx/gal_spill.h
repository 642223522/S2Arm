// 计算着色器共享内存溢出改写（gal_spill.c）的声明：纯 C，不引 Metal 头；Linux / Windows 出包机单独编那份 .c 时也用（#783）。
//   gal_internal.h 在 Metal 4 可用性区之前包含本头，各块文件照旧经 gal_internal.h 看到这些声明；溢出缓冲的槽号 GAL_SPILL_SLOT 仍在 gal_internal.h。
#pragma once
#include <stdint.h>
#define GAL_TG_MEM_MAX 32768u   // 离线出库（不建设备）的目标设备 maxThreadgroupMemoryLength（iPhone A 系 / Apple 芯片 Mac 同为 32 KB）；运行时按 MTLDevice 当场查询
// 线程组内存上限由调用方给（gal_spill_msl 的 lim）：渲染器按 MTLDevice 查询（gal_prog.m gal_spill_limit），直连 nxgal_dmsh_spill 取 GAL_TG_MEM_MAX（11-08）
// 超限的 threadgroup 数组挪到槽 slot 的溢出缓冲：NULL = 没超限（原样）；(char *)-1 = 结构不认识（写 why）；否则新 MSL（malloc），*bytes = 每线程组溢出字节
char *gal_spill_msl(const char *src, uint32_t slot, uint32_t lim, uint32_t *bytes, char *why);
