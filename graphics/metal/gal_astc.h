// BC → ASTC 预转包（Apple TV 等不支持 BC 压缩贴图的设备）：只读包读取 + 平面键。机制与包形态参考 brad-n/TVPort（MIT）的 astc-ro.pack，
//   代码按本仓库图形层重写（TVPort 的引擎不是这套）。纯 C，不碰 Metal 贴图：gal_tex.m 用它查包，单测 tests/t_astc.c 直接测。
//
// 平面：一张贴图的某级某层（GAL 线性布局里的一段：BC 块按行紧排，行 = ceil(宽/4) 块）。出包工具 pack/astc_pack.py 从游戏资源（BNTX）
//   离线解出同样的平面，用 astc-encoder 编成 ASTC 4x4，按键存进包；运行时上传 BC 数据时按同一口径算键查包，命中直接传 ASTC。
// 键 = SHA-256( "s2a-bc-astc-v1"（14 字节，不含结尾 0）‖ u32le 族 ‖ u32le 宽 ‖ u32le 高 ‖ 平面 BC 字节 )；族见 GAL_ASTC_FAM_*（sRGB 与否不进键：块字节相同、ASTC 也相同）。
// 包（小端）：
//   头 64 字节：魔数 "S2ABCAST" | u32 版本 1 | u32 索引项字节 48 | u64 项数 | u64 索引偏移 | u64 文件总长 | u8 块宽 4 | u8 块高 4 | 2 字节 0 | u32 0 | 16 字节工具指纹（只记录）
//   负载：各平面的 ASTC 块（按行紧排），16 字节对齐，偏移 ≥ 64；同一负载可被多个键指向
//   索引（文件末尾，索引偏移 + 项数 × 48 = 文件总长）：项数 × {32 字节键, u64 负载偏移, u64 负载字节}，按键（memcmp）严格升序
// 包不完整 / 自相矛盾（魔数、版本、长度、越界、未排序、块不是 4x4）一律整包不用：gal_astc_open 返回 NULL，调用方当没有包（行为同没设环境变量）。
#pragma once
#include <stdint.h>
#include <stddef.h>

enum { GAL_ASTC_FAM_NONE = 0, GAL_ASTC_FAM_BC1 = 1, GAL_ASTC_FAM_BC2 = 2, GAL_ASTC_FAM_BC3 = 3, GAL_ASTC_FAM_BC5U = 5, GAL_ASTC_FAM_BC7 = 7 };
#define GAL_ASTC_HEAD 64u
#define GAL_ASTC_ENT 48u

typedef struct gal_astc_pack gal_astc_pack;
// 打开并整包校验；不可用返回 NULL，why（可空）写原因
gal_astc_pack *gal_astc_open(const char *path, char *why, size_t why_len);
void gal_astc_close(gal_astc_pack *p);
uint64_t gal_astc_count(const gal_astc_pack *p);
// 平面键
void gal_astc_key(uint32_t family, uint32_t width, uint32_t height, const void *bc, size_t len, uint8_t key[32]);
// 查键：命中返回 1 并给出负载字节数，没有返回 0
int gal_astc_find(const gal_astc_pack *p, const uint8_t key[32], uint64_t *size);
// 按键读负载进 dst（want = 期望字节数，与包里记的不等算没命中）：1 读到，0 没有 / 长度不符 / 读失败
int gal_astc_read(const gal_astc_pack *p, const uint8_t key[32], void *dst, uint64_t want);
// GAL 格式 → 能存进 ASTC 包的族（0 = 不进包：BC4、带符号 BC5、BC6H 与非 BC 格式）。
//   BC4 不进包：ASTC 4x4 每 texel 1 字节，与 BC4 解压后的 R8 一样大，进包不省内存、只多包体积与一次有损；带符号与 BC6H 是 ASTC LDR 存不了的值域
int gal_astc_family(int32_t gal_format);
// 一个平面（宽 × 高 texel）的 ASTC 4x4 负载字节数
static inline uint64_t gal_astc_plane_bytes(uint32_t w, uint32_t h) { return (uint64_t)((w + 3) / 4) * ((h + 3) / 4) * 16; }
