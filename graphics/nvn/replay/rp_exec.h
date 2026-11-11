// 回放核心内部接口（核心各文件之间用；前端只认 nvn_mtl.h / nvn_obj.h 里的 nvn_be_*）。
#pragma once
#include <stdint.h>
#include "nvn_obj.h"
#include "nvn_backend.h"

const char *rp_op_name(uint32_t op);   // 录制命令名（"OP_DRAW" …）；范围外返回 "OP_?"
int rp_pool_count(void);                // 已登记的内存池个数
int rp_tex_live_n(void);                // 活贴图对象个数（只是登记数，不等于已建图的个数）
int rp_depth_zero(void);                // NVN 深度模式：1 = 近平面为 0
int rp_origin_lower_left(void);         // NVN 窗口原点：1 = 左下
uint64_t rp_frame(void);                // 前端给的当前帧号

// ---------- 内存池镜像（rp_buf.c）----------
// 取 [addr, addr+len) 在后端的缓冲与偏移；自上次同步后写过的页在 c 这一段的 GPU 顺序里重传。0 = 地址不在任何池里（已记账）。线程：[提交]。
int rp_buf_resolve(nvn_gpu_cmd c, uint64_t addr, uint64_t len, nvn_gpu_buf *buf, uint64_t *off);
void rp_buf_stats(uint64_t *bytes, uint64_t *runs);   // 累计同步字节数 / 段数
int rp_buf_mirrors(void);                             // 现有镜像个数
// 缓冲类命令（rec = 命令记录地址，只进未接日志）
void rp_op_update_ub(const void *a, const void *rec);
void rp_op_copy_b2b(const void *a, const void *rec);
void rp_op_clear_buf(const p_clear_buf *cb, const void *rec);
void rp_op_copy_b2t(nvn_gpu_cmd c, const p_copy_b2t *o, const void *rec);

// 会话四件套（前端按名字调，上沿头文件里没有声明）
void nvn_be_begin_session(void);
int nvn_be_request_stop(void);
int nvn_be_drain_session(void);
int nvn_be_shutdown_session(void);   // 放掉全部后端对象、状态回到 NVN 默认值
