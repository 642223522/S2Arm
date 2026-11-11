// 回放核心内部接口（核心各文件之间用；前端只认 nvn_mtl.h / nvn_obj.h 里的 nvn_be_*）。
#pragma once
#include <stdint.h>

const char *rp_op_name(uint32_t op);   // 录制命令名（"OP_DRAW" …）；范围外返回 "OP_?"
int rp_pool_count(void);                // 已登记的内存池个数
int rp_tex_live_n(void);                // 活贴图对象个数（只是登记数，不等于已建图的个数）
int rp_depth_zero(void);                // NVN 深度模式：1 = 近平面为 0
int rp_origin_lower_left(void);         // NVN 窗口原点：1 = 左下
uint64_t rp_frame(void);                // 前端给的当前帧号
