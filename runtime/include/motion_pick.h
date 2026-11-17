#ifndef S2A_MOTION_PICK_H
#define S2A_MOTION_PICK_H
// 玩家 1 的六轴来源仲裁（纯函数，单测 runtime/tests/t_motion_pick.c）
//   输入来源（runtime/src/pad.c 的 s2a_pad_source）+ 三路各自有没有样本 → 这一帧该读哪一路。
//   规矩（11-15 维护者改）：有体感样本的手柄优先，不看触屏在不在操作；两只手柄都在时按谁在驱动输入分先后；
//   手柄都给不出样本（没接 / 系统不给体感）才用手机陀螺仪。
//   两台刚体的角速度绝不混合：换源由宿主丢一帧（known = 0）让服务层重建姿态。
enum { S2A_MOTION_NONE = 0, S2A_MOTION_PHONE, S2A_MOTION_GC, S2A_MOTION_NS2 };
//   input_source 用 s2a_pad_source 的原值：0 = 触屏（S2A_PAD_TOUCH）、1 = NS2 Pro BLE、2 = 系统手柄。
//   三个 known 非 0 表示那一路这一帧有可用样本。返回 S2A_MOTION_*。
int s2a_motion_pick(int input_source, int ns2_known, int gc_known, int phone_known);
#endif
