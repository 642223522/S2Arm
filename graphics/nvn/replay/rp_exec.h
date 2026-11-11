// 回放核心内部接口（核心各文件之间用；前端只认 nvn_mtl.h / nvn_obj.h 里的 nvn_be_*）。
#pragma once
#include <stdint.h>

const char *rp_op_name(uint32_t op);   // 录制命令名（"OP_DRAW" …）；范围外返回 "OP_?"
