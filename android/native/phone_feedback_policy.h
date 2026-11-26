#pragma once
// 安卓手机当掌机的六轴 / 震动（#528 第 10 项）里不碰设备的那部分：纯函数，宿主单测 android/tests/phone_feedback_test.c。
//   设备侧（ASensor / Vibrator）在 phone_feedback.c，换算规矩与 iOS ios/phone_motion.m 同一套，坐标换算本身复用 runtime/src/phone_axes.c。
#include <stdint.h>
#include "s2a_pad.h"
#include "motion_pick.h"

// Display.getRotation()（ROTATION_0..270，画面相对自然方向顺时针转了几个 90°，即机身逆时针转了几个 90°）
//   → 屏幕「右」「上」在传感器坐标（x 自然方向右、y 自然方向上、z 出屏，同 CoreMotion 机身坐标）里的方向，交给 s2a_phone_axes_basis。
//   安卓传感器坐标始终对齐自然方向（横向自然方向的平板也一样），所以不需要 iOS 的面板补转（s2a_phone_panel_fix）。
//   ROTATION_90 = 机身逆时针转 90°（顶端朝左）：右 = −y、上 = x，与 iOS 横屏右的写死换算相同。
static inline void s2a_android_rotation_basis(int rotation, int right[2], int up[2]) {
    static const int r[4][2] = {{1, 0}, {0, -1}, {-1, 0}, {0, 1}}, u[4][2] = {{0, 1}, {1, 0}, {0, -1}, {-1, 0}};
    int i = rotation & 3;
    right[0] = r[i][0]; right[1] = r[i][1]; up[0] = u[i][0]; up[1] = u[i][1];
}

// 安卓加速度计：m/s²、报支撑反力（静止平放屏幕朝上 z = +9.81）；CoreMotion 报重力方向、单位 g（平放 z = −1）。
//   s2a_phone_axes_basis 按 CoreMotion 口径取反，所以这里先换成 CoreMotion 口径：acc_dev = −a / g。角速度两边都是右手系 rad/s，原样。
#define S2A_ANDROID_STANDARD_GRAVITY 9.80665
static inline void s2a_android_accel_to_coremotion(const float a[3], double out[3]) {
    for (int i = 0; i < 3; i++) out[i] = -(double)a[i] / S2A_ANDROID_STANDARD_GRAVITY;
}

// 一次左右合成的震动 → 安卓 VibrationEffect 振幅（1..255；0 = 停）。同 iOS hp_apply：四路振幅取最大，≤ 0.01 当停。
//   频率在安卓上没有通用的控制口（Vibrator 频率档 API 34 起才有、多数机型不给），只按振幅震。
static inline int s2a_android_rumble_level(const s2a_pad_vibration v[2]) {
    float amp = 0;
    for (int i = 0; i < 2; i++) {
        if (v[i].low_amp > amp) amp = v[i].low_amp;
        if (v[i].high_amp > amp) amp = v[i].high_amp;
    }
    if (!(amp > 0.01f)) return 0;   // 也挡 NaN
    if (amp > 1) amp = 1;
    int level = (int)(amp * 255 + 0.5f);
    return level < 1 ? 1 : level;
}

// 马达节奏：每次下发是一段 S2A_ANDROID_RUMBLE_LEASE_MS 的单次震动（租约，进程卡住 / 漏了停止也最多震这么久，不会一直震下去）。
//   服务层（ControllerFeedback）震着时每 250 ms 续一次，这里离上次下发满 RENEW 才重发，振幅变了才提前重发（20 ms 节流，同 iOS）。
enum { S2A_ANDROID_RUMBLE_LEASE_MS = 1000, S2A_ANDROID_RUMBLE_RENEW_MS = 500, S2A_ANDROID_RUMBLE_THROTTLE_MS = 20 };
typedef struct { int level; uint64_t issued_ns; } s2a_android_rumble_state;   // level 0 = 没在震
// 返回这一次要下发的振幅：-1 = 什么都不做；0 = 取消；1..255 = 下发一段租约。state 随之更新
static inline int s2a_android_rumble_step(s2a_android_rumble_state *s, int level, uint64_t now_ns) {
    if (level <= 0) {
        if (!s->level) return -1;
        s->level = 0; s->issued_ns = 0;
        return 0;
    }
    uint64_t age = now_ns - s->issued_ns;
    if (s->level) {
        if (level == s->level && age < (uint64_t)S2A_ANDROID_RUMBLE_RENEW_MS * 1000000u) return -1;
        if (level != s->level && age < (uint64_t)S2A_ANDROID_RUMBLE_THROTTLE_MS * 1000000u) return -1;
    }
    s->level = level; s->issued_ns = now_ns;
    return level;
}

// ---------- 外接手柄自己的马达 / 六轴（#528 第 10 项第二块）----------
// 手柄两路马达（安卓 InputDevice 的 VibratorManager：id 0 = 左 / 强马达、id 1 = 右 / 弱马达，EventHub 的 FF_RUMBLE strong / weak）：
//   同 iOS 系统手柄分左右（ios/controller.m LeftHandle / RightHandle）：左侧 low / high 取大给左马达，右侧给右马达。≤ 0.01 当停
static inline int s2a_android_side_level(const s2a_pad_vibration *v) {
    float amp = v->low_amp > v->high_amp ? v->low_amp : v->high_amp;
    if (!(amp > 0.01f)) return 0;   // 也挡 NaN（任一路 NaN 时比较取到 NaN 那路或另一路，NaN 一样落进这里）
    if (amp > 1) amp = 1;
    int level = (int)(amp * 255 + 0.5f);
    return level < 1 ? 1 : level;
}
// 左右两路合成一个节奏键交给 s2a_android_rumble_step（左 << 8 | 右；两路都停才是 0）：任一侧变了都算振幅变了，节流 / 续租规矩同手机
static inline int s2a_android_pad_rumble_key(const s2a_pad_vibration v[2]) {
    return s2a_android_side_level(&v[0]) << 8 | s2a_android_side_level(&v[1]);
}

// 手柄六轴的坐标系：安卓（InputDevice.getSensorManager，API 31）只把 Linux 驱动的读数换成 m/s²、rad/s，不统一轴向，
//   轴向由驱动定（对照 Linux drivers/hid 与 SDL src/joystick/hidapi，两边同一套）：
//   PlayStation（hid-playstation / hid-sony，DS4、DualSense）：x 右、y 正面法线（平拿朝天）、z 朝玩家（下沿）；
//   任天堂（hid-nintendo，Pro、Joy-Con，右 Joy-Con 驱动已翻成同向）：x 上沿（扳机方向）、y 左、z 正面法线。
//   都是右手系，加速度报支撑反力（平放静止法线方向 +9.8）。认不出的厂商不猜轴向：当没有手柄六轴，回落手机陀螺仪。
enum { S2A_ANDROID_PAD_FRAME_NONE = 0, S2A_ANDROID_PAD_FRAME_PLAYSTATION, S2A_ANDROID_PAD_FRAME_NINTENDO };
static inline int s2a_android_pad_frame(int vendor_id) {
    if (vendor_id == 0x054c) return S2A_ANDROID_PAD_FRAME_PLAYSTATION;   // Sony
    if (vendor_id == 0x057e) return S2A_ANDROID_PAD_FRAME_NINTENDO;      // Nintendo
    return S2A_ANDROID_PAD_FRAME_NONE;
}
// 手柄读数（加速度 m/s² 支撑反力、角速度 rad/s，驱动坐标）→ NS2 原始坐标（x 右、y 上沿、z 正面法线；g、度/秒，
//   同 runtime/include/phone_axes.h s2a_gc_motion_axes 的口径）。返回 0 = 坐标系认不出，out 不动
static inline int s2a_android_pad_axes(int frame, const float a[3], const float w[3], float acc[3], float gyr[3]) {
    int src[3], sign[3];   // NS2 第 i 轴 = sign[i] × 驱动第 src[i] 轴
    if (frame == S2A_ANDROID_PAD_FRAME_PLAYSTATION) {          // 右 = x、上沿 = −z（z 朝玩家）、法线 = y
        src[0] = 0; sign[0] = 1; src[1] = 2; sign[1] = -1; src[2] = 1; sign[2] = 1;
    } else if (frame == S2A_ANDROID_PAD_FRAME_NINTENDO) {      // 右 = −y（y 朝左）、上沿 = x、法线 = z
        src[0] = 1; sign[0] = -1; src[1] = 0; sign[1] = 1; src[2] = 2; sign[2] = 1;
    } else return 0;
    for (int i = 0; i < 3; i++) {
        acc[i] = (float)(sign[i] * (double)a[src[i]] / S2A_ANDROID_STANDARD_GRAVITY);
        gyr[i] = (float)(sign[i] * (double)w[src[i]] * 57.29577951308232);
    }
    return 1;
}

// 玩家 1 的六轴走哪一路（宿主每帧调；挑法本身是共用的 runtime/src/motion_pick.c：有样本的手柄优先，手柄给不出才用手机）。
//   这里只管宿主那半：换源丢一帧（返回 drop = 1，服务层见 known = 0 清姿态，不跨两台刚体积分，同 iOS），
//   手柄稳定供样本满 S2A_ANDROID_PHONE_GRACE_MS 后让手机传感器歇着（yield_phone = 1；手柄断了样本立刻要回来）
enum { S2A_ANDROID_PHONE_GRACE_MS = 2000 };
typedef struct { int src; uint64_t pad_since_ns; } s2a_android_motion_route;   // src：S2A_MOTION_*，零值 = 还没选过
typedef struct { int src, drop, yield_phone; } s2a_android_motion_pick;
static inline s2a_android_motion_pick s2a_android_motion_step(s2a_android_motion_route *r, int gamepad, int pad_known, int phone_known, uint64_t now_ns) {
    s2a_android_motion_pick out = {0, 0, 0};
    out.src = s2a_motion_pick(gamepad ? S2A_PAD_SYSTEM : S2A_PAD_TOUCH, 0, pad_known, phone_known);
    if (out.src != r->src) {
        out.drop = r->src != 0 && out.src != 0;
        r->src = out.src;
        r->pad_since_ns = out.src == S2A_MOTION_GC ? now_ns : 0;
    }
    out.yield_phone = out.src == S2A_MOTION_GC && now_ns - r->pad_since_ns >= (uint64_t)S2A_ANDROID_PHONE_GRACE_MS * 1000000u;
    return out;
}
