// 手机六轴 / 震动的纯换算（android/native/phone_feedback_policy.h + 共用 runtime/src/phone_axes.c）。
// 期望值按物理姿态手算，不跑被测实现：NS2 原始坐标 = （屏幕右、屏幕上、出屏），加速度报支撑反力，单位 g、度/秒。
#include "phone_feedback_policy.h"
#include "phone_axes.h"
#include <math.h>
#include <stdio.h>

static int failures;
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, #c); failures++; } } while (0)
static int near(float a, float b) { return fabsf(a - b) < 1e-3f; }

// 安卓原始读数（加速度 m/s² 支撑反力、角速度 rad/s，传感器坐标对齐自然方向）→ NS2 原始坐标
static void convert(int rotation, const float acc[3], const float gyr[3], float a[3], float g[3]) {
    double acc_dev[3], gyr_dev[3] = {gyr[0], gyr[1], gyr[2]};
    int right[2], up[2];
    s2a_android_accel_to_coremotion(acc, acc_dev);
    s2a_android_rotation_basis(rotation, right, up);
    s2a_phone_axes_basis(right, up, acc_dev, gyr_dev, a, g);
}

static void axes(void) {
    const float g0 = 9.80665f, none[3] = {0, 0, 0};
    float a[3], g[3];
    // 平放屏幕朝上：不论哪个方向，NS2 平放读 z = +1 g（真报文 report05 ≈ (−0.02, 0.14, 1.01)）
    for (int r = 0; r < 4; r++) {
        const float flat[3] = {0, 0, g0};
        convert(r, flat, none, a, g);
        CHECK(near(a[0], 0) && near(a[1], 0) && near(a[2], 1));
    }
    // ROTATION_90（机身逆时针转 90°、顶端朝左，横着竖起来屏幕对人）：机身 x 朝上，支撑反力 = +x；NS2 上沿朝上读 y = +1
    { const float up_x[3] = {g0, 0, 0}; convert(1, up_x, none, a, g); CHECK(near(a[0], 0) && near(a[1], 1) && near(a[2], 0)); }
    // ROTATION_270（顶端朝右）：机身 −x 朝上
    { const float up_nx[3] = {-g0, 0, 0}; convert(3, up_nx, none, a, g); CHECK(near(a[0], 0) && near(a[1], 1) && near(a[2], 0)); }
    // ROTATION_0（竖着拿）：机身 y 朝上
    { const float up_y[3] = {0, g0, 0}; convert(0, up_y, none, a, g); CHECK(near(a[0], 0) && near(a[1], 1) && near(a[2], 0)); }
    // ROTATION_180（倒着竖拿）：机身 −y 朝上
    { const float up_ny[3] = {0, -g0, 0}; convert(2, up_ny, none, a, g); CHECK(near(a[0], 0) && near(a[1], 1) && near(a[2], 0)); }
    // 绕出屏轴逆时针转 1 rad/s：不论方向 NS2 z 都是 +57.3°/s（出屏轴不随屏幕方向变）
    for (int r = 0; r < 4; r++) {
        const float spin_z[3] = {0, 0, 1};
        convert(r, none, spin_z, a, g);
        CHECK(near(g[0], 0) && near(g[1], 0) && near(g[2], 57.29578f));
    }
    // ROTATION_90：屏幕上 = 机身 +x，绕机身 x 转 = 绕 NS2 y 转；屏幕右 = 机身 −y，绕机身 y 转 = 绕 NS2 −x 转
    { const float spin_x[3] = {1, 0, 0}; convert(1, none, spin_x, a, g); CHECK(near(g[0], 0) && near(g[1], 57.29578f) && near(g[2], 0)); }
    { const float spin_y[3] = {0, 1, 0}; convert(1, none, spin_y, a, g); CHECK(near(g[0], -57.29578f) && near(g[1], 0) && near(g[2], 0)); }
    // ROTATION_270：屏幕右 = 机身 +y
    { const float spin_y[3] = {0, 1, 0}; convert(3, none, spin_y, a, g); CHECK(near(g[0], 57.29578f) && near(g[1], 0) && near(g[2], 0)); }
    // 越界的方向值按低两位取，不读出表外
    { int r2[2], u2[2]; s2a_android_rotation_basis(5, r2, u2); CHECK(r2[0] == 0 && r2[1] == -1 && u2[0] == 1 && u2[1] == 0); }
}

static void level(void) {
    s2a_pad_vibration v[2] = {{0}};
    CHECK(s2a_android_rumble_level(v) == 0);
    v[1].high_amp = 0.005f; CHECK(s2a_android_rumble_level(v) == 0);         // ≤ 0.01 当停（同 iOS）
    v[1].high_amp = 0.5f; v[0].low_amp = 0.2f; CHECK(s2a_android_rumble_level(v) == 128);   // 四路取最大：0.5 × 255 四舍五入
    v[0].low_amp = 3; CHECK(s2a_android_rumble_level(v) == 255);              // 超过 1 封顶
    v[0].low_amp = NAN; v[1].high_amp = 0; CHECK(s2a_android_rumble_level(v) == 0);   // NaN 不震
    v[0].low_amp = 0.011f; CHECK(s2a_android_rumble_level(v) == 3);
}

static void step(void) {
    const uint64_t ms = 1000000;
    s2a_android_rumble_state s = {0};
    CHECK(s2a_android_rumble_step(&s, 0, 1000 * ms) == -1);    // 没在震时停：不下发
    CHECK(s2a_android_rumble_step(&s, 100, 1000 * ms) == 100); // 起震：下发一段租约
    CHECK(s2a_android_rumble_step(&s, 100, 1250 * ms) == -1);  // 服务层 250 ms 续：没到 500 ms 不重发
    CHECK(s2a_android_rumble_step(&s, 100, 1500 * ms) == 100); // 满 500 ms：重发，租约（1000 ms）不断
    CHECK(s2a_android_rumble_step(&s, 200, 1510 * ms) == -1);  // 20 ms 内变振幅：节流
    CHECK(s2a_android_rumble_step(&s, 200, 1520 * ms) == 200); // 过了 20 ms：按新振幅下发
    CHECK(s2a_android_rumble_step(&s, 0, 1521 * ms) == 0);     // 停：立刻取消，不受节流
    CHECK(s2a_android_rumble_step(&s, 0, 1600 * ms) == -1);    // 再停：不重复取消
    CHECK(s2a_android_rumble_step(&s, 50, 1601 * ms) == 50);   // 停后紧接着再起：不受节流
    CHECK(S2A_ANDROID_RUMBLE_RENEW_MS + 250 < S2A_ANDROID_RUMBLE_LEASE_MS);   // 服务层 250 ms 一续时，下一次重发一定落在租约到期前
}

// 外接手柄六轴（第二块）：期望值按物理姿态手算（驱动坐标系见 phone_feedback_policy.h）
static void pad_axes(void) {
    const float g0 = 9.80665f, none[3] = {0, 0, 0};
    float a[3], g[3];
    CHECK(s2a_android_pad_frame(0x054c) == S2A_ANDROID_PAD_FRAME_PLAYSTATION);
    CHECK(s2a_android_pad_frame(0x057e) == S2A_ANDROID_PAD_FRAME_NINTENDO);
    CHECK(s2a_android_pad_frame(0x045e) == S2A_ANDROID_PAD_FRAME_NONE);   // Xbox：系统不给六轴，也不猜
    // 平放正面朝上：NS2 z = +1 g。PS 的法线是 y，任天堂的是 z
    { const float ps[3] = {0, g0, 0}; CHECK(s2a_android_pad_axes(S2A_ANDROID_PAD_FRAME_PLAYSTATION, ps, none, a, g)); CHECK(near(a[0], 0) && near(a[1], 0) && near(a[2], 1)); }
    { const float ns[3] = {0, 0, g0}; CHECK(s2a_android_pad_axes(S2A_ANDROID_PAD_FRAME_NINTENDO, ns, none, a, g)); CHECK(near(a[0], 0) && near(a[1], 0) && near(a[2], 1)); }
    // 上沿朝天竖起来：NS2 y = +1。PS 上沿 = −z（z 朝玩家），任天堂上沿 = x
    { const float ps[3] = {0, 0, -g0}; s2a_android_pad_axes(S2A_ANDROID_PAD_FRAME_PLAYSTATION, ps, none, a, g); CHECK(near(a[0], 0) && near(a[1], 1) && near(a[2], 0)); }
    { const float ns[3] = {g0, 0, 0}; s2a_android_pad_axes(S2A_ANDROID_PAD_FRAME_NINTENDO, ns, none, a, g); CHECK(near(a[0], 0) && near(a[1], 1) && near(a[2], 0)); }
    // 右侧朝天：NS2 x = +1。PS 右 = x，任天堂右 = −y（y 朝左）
    { const float ps[3] = {g0, 0, 0}; s2a_android_pad_axes(S2A_ANDROID_PAD_FRAME_PLAYSTATION, ps, none, a, g); CHECK(near(a[0], 1) && near(a[1], 0) && near(a[2], 0)); }
    { const float ns[3] = {0, -g0, 0}; s2a_android_pad_axes(S2A_ANDROID_PAD_FRAME_NINTENDO, ns, none, a, g); CHECK(near(a[0], 1) && near(a[1], 0) && near(a[2], 0)); }
    // 平放绕法线逆时针转 1 rad/s（俯视）：NS2 z = +57.3°/s
    { const float ps[3] = {0, 1, 0}; s2a_android_pad_axes(S2A_ANDROID_PAD_FRAME_PLAYSTATION, none, ps, a, g); CHECK(near(g[0], 0) && near(g[1], 0) && near(g[2], 57.29578f)); }
    { const float ns[3] = {0, 0, 1}; s2a_android_pad_axes(S2A_ANDROID_PAD_FRAME_NINTENDO, none, ns, a, g); CHECK(near(g[0], 0) && near(g[1], 0) && near(g[2], 57.29578f)); }
    // 绕上沿轴转（右手）：NS2 y = +57.3°/s。PS 绕 −z，任天堂绕 x
    { const float ps[3] = {0, 0, -1}; s2a_android_pad_axes(S2A_ANDROID_PAD_FRAME_PLAYSTATION, none, ps, a, g); CHECK(near(g[0], 0) && near(g[1], 57.29578f) && near(g[2], 0)); }
    { const float ns[3] = {1, 0, 0}; s2a_android_pad_axes(S2A_ANDROID_PAD_FRAME_NINTENDO, none, ns, a, g); CHECK(near(g[0], 0) && near(g[1], 57.29578f) && near(g[2], 0)); }
    // 交叉核对：SDL（src/joystick/hidapi/SDL_hidapi_switch.c SendSensorUpdate）把任天堂读数排成 PS 口径 P = (−N.y, N.z, −N.x)；
    //   同一个姿态从两套坐标换过来必须一样（任意非对称向量）
    {
        const float n[3] = {0.3f, -1.7f, 2.9f}, p[3] = {-n[1], n[2], -n[0]};
        float a2[3], g2[3];
        s2a_android_pad_axes(S2A_ANDROID_PAD_FRAME_NINTENDO, n, n, a, g);
        s2a_android_pad_axes(S2A_ANDROID_PAD_FRAME_PLAYSTATION, p, p, a2, g2);
        for (int i = 0; i < 3; i++) CHECK(near(a[i], a2[i]) && near(g[i], g2[i]));
    }
    // 反向对照 1：认不出的坐标系不写输出、回 0（回落手机陀螺仪）
    { const float flat[3] = {0, 0, g0}; float keep[3] = {7, 7, 7}, kg[3] = {7, 7, 7};
      CHECK(!s2a_android_pad_axes(S2A_ANDROID_PAD_FRAME_NONE, flat, flat, keep, kg)); CHECK(keep[0] == 7 && kg[2] == 7); }
    // 反向对照 2：坐标系用错（任天堂平放读数当 PS 换）读不出平放 —— 上面的期望值确实能区分两套坐标
    { const float ns[3] = {0, 0, g0}; s2a_android_pad_axes(S2A_ANDROID_PAD_FRAME_PLAYSTATION, ns, none, a, g); CHECK(!near(a[2], 1)); }
}

static void pad_rumble(void) {
    s2a_pad_vibration v[2] = {{0}};
    CHECK(s2a_android_pad_rumble_key(v) == 0);
    v[0].low_amp = 0.5f; v[0].high_amp = 0.2f;                       // 左侧两路取大
    CHECK(s2a_android_side_level(&v[0]) == 128 && s2a_android_side_level(&v[1]) == 0);
    CHECK(s2a_android_pad_rumble_key(v) == 128 << 8);               // 只左马达
    v[1].high_amp = 2;                                               // 右侧封顶
    CHECK(s2a_android_pad_rumble_key(v) == (128 << 8 | 255));
    v[0].low_amp = NAN; v[0].high_amp = 0;                           // NaN 不震
    CHECK(s2a_android_pad_rumble_key(v) == 255);
    v[1].high_amp = 0.01f; CHECK(s2a_android_pad_rumble_key(v) == 0);   // ≤ 0.01 当停
    // 只变一侧也算振幅变了：节流后照发，不会卡在旧的左右比例上
    const uint64_t ms = 1000000;
    s2a_android_rumble_state s = {0};
    CHECK(s2a_android_rumble_step(&s, 128 << 8, 1000 * ms) == 128 << 8);
    CHECK(s2a_android_rumble_step(&s, 128 << 8 | 1, 1030 * ms) == (128 << 8 | 1));
    CHECK(s2a_android_rumble_step(&s, 0, 1031 * ms) == 0);
}

static void route(void) {
    const uint64_t ms = 1000000;
    s2a_android_motion_route r = {0};
    // 接着有体感的手柄：手柄优先；从「还没选」到第一个来源不丢帧
    s2a_android_motion_pick p = s2a_android_motion_step(&r, 1, 1, 1, 1000 * ms);
    CHECK(p.src == S2A_MOTION_GC && !p.drop && !p.yield_phone);
    p = s2a_android_motion_step(&r, 1, 1, 1, 2999 * ms); CHECK(p.src == S2A_MOTION_GC && !p.yield_phone);   // 不满 2 秒手机照开
    p = s2a_android_motion_step(&r, 1, 1, 0, 3000 * ms); CHECK(p.src == S2A_MOTION_GC && p.yield_phone);    // 满 2 秒让手机歇着
    // 手柄样本断了（拔了 / 驱动不给了）：回手机，换源丢一帧、手机马上要回来
    p = s2a_android_motion_step(&r, 1, 0, 1, 3010 * ms); CHECK(p.src == S2A_MOTION_PHONE && p.drop && !p.yield_phone);
    p = s2a_android_motion_step(&r, 1, 0, 1, 3015 * ms); CHECK(p.src == S2A_MOTION_PHONE && !p.drop);
    // 手柄回来：再换一次、再丢一帧，2 秒计时重新起
    p = s2a_android_motion_step(&r, 1, 1, 1, 4000 * ms); CHECK(p.src == S2A_MOTION_GC && p.drop && !p.yield_phone);
    p = s2a_android_motion_step(&r, 1, 1, 1, 5999 * ms); CHECK(!p.yield_phone);
    // 两路都没有：没有来源，不报丢帧（不是两台刚体之间换）
    p = s2a_android_motion_step(&r, 0, 0, 0, 6000 * ms); CHECK(p.src == S2A_MOTION_NONE && !p.drop && !p.yield_phone);
    p = s2a_android_motion_step(&r, 0, 0, 1, 6001 * ms); CHECK(p.src == S2A_MOTION_PHONE && !p.drop);
    // 反向对照：只有手机时永远不让手机歇着
    p = s2a_android_motion_step(&r, 0, 0, 1, 60000 * ms); CHECK(p.src == S2A_MOTION_PHONE && !p.yield_phone);
}

int main(void) {
    axes();
    level();
    step();
    pad_axes();
    pad_rumble();
    route();
    if (failures) { fprintf(stderr, "phone_feedback_test: %d failed\n", failures); return 1; }
    puts("phone_feedback_test: ok");
    return 0;
}
