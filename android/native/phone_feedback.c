// 玩家 1 的六轴与震动（#528 第 10 项），接口与规矩见 phone_feedback.h；换算的纯函数在 phone_feedback_policy.h。
//   第一块（手机当掌机）对齐 iOS ios/phone_motion.m：没有外接手柄六轴时手机陀螺仪 / 加速度当 Switch 掌机六轴，HD Rumble 走手机马达。
//   第二块（外接手柄自己的）对齐 iOS ios/controller.m：接着有马达的手柄就震手柄（左右两路），有六轴的手柄优先供六轴；
//   安卓 NDK 没有手柄的马达 / 传感器接口（InputDevice.getVibratorManager / getSensorManager 只在 Java），由 PadFeedback.java 收发。
//   服务层（ControllerFeedback → Ryujinx MotionInput / UpdateSixAxis）不变。
// 设置：游戏内四指菜单「手机陀螺仪」「手机震动」（PhoneFeedback.java）、「手柄震动」（PadFeedback.java），SharedPreferences，缺省开，同 iOS 缺省。
#include "phone_feedback.h"
#include "phone_feedback_policy.h"
#include "phone_axes.h"
#include "phone_rumble_mailbox.h"
#include "motion_pick.h"
#include "s2a_pad.h"
#include <android/log.h>
#include <android/looper.h>
#include <android/sensor.h>
#include <jni.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>
#include <time.h>

#define EXPORT __attribute__((visibility("default"), used))
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "S2Arm", __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "S2Arm", __VA_ARGS__)
#define S2A_PHONE_SESSION_BASE 0x5048000000000000ull   // 手机马达的震动会话号（同 iOS，与 NS2 的小整数会话号不相交）
#define S2A_PAD_SESSION_BASE 0x5044000000000000ull     // 外接手柄马达的震动会话号（高 16 位区分，低位是这一代的序号）
#define S2A_SESSION_KIND(s) ((s) & 0xffff000000000000ull)
// 只给体感的会话（同 iOS controller.m MOTION_ONLY_SESSION 的用法）：在前台但没有能震的马达（设置关了 / 没马达 / 接着手柄）时报它，
//   服务层的反馈对象照留（InputPump.RefreshFeedback 见 0 会拆掉整个对象，六轴也跟着没了）；拿它提交的震动一律丢
#define S2A_MOTION_ONLY_SESSION 0x4d4f000000000001ull
enum { SENSOR_PERIOD_US = 5000 };   // 200 Hz，同 iOS；安卓 12+ 不申请 HIGH_SAMPLING_RATE_SENSORS 时的上限正好是 200 Hz

// ---------- 设置与前后台（主线程写，HID / 反馈线程读）----------
static _Atomic int g_gyro_pref = 1, g_rumble_pref = 1, g_has_vibrator, g_gamepad, g_foreground = 1, g_rotation = 1;
static _Atomic uint64_t g_session = S2A_PHONE_SESSION_BASE + 1;   // 手机马达这一代的会话号：退后台、改设置、接拔手柄换号
// 外接手柄（PadFeedback.java 报）：能不能震（有马达且「手柄震动」开）、六轴坐标系（S2A_ANDROID_PAD_FRAME_*，NONE = 不给六轴）
static _Atomic int g_pad_rumble, g_pad_frame;
static _Atomic uint64_t g_pad_session = S2A_PAD_SESSION_BASE + 1;   // 手柄马达这一代：换手柄、改设置、退后台换号

// ---------- 六轴 ----------
// 传感器线程只在第一次要六轴时起，之后常驻（ALooper 绑在它身上）；开关只调 enable / disable，不拆线程
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static ASensorManager *g_manager;
static ASensorEventQueue *g_queue;
static const ASensor *g_accel, *g_gyro;
static char g_package[256];
static int g_want_motion, g_sensors_on, g_thread_state;   // 0 = 没起、1 = 起好、-1 = 起不来（已报红）
static int g_phone_yield;   // 手柄稳定供六轴时手机传感器歇着（s2a_pad_read_motion 定，sensors_apply_locked 看）
static pthread_cond_t g_thread_cv = PTHREAD_COND_INITIALIZER;
static float g_acc[3], g_gyr[3];
static int64_t g_acc_ns, g_gyr_ns;

static int on_sensor(int fd, int events, void *data) {
    (void)fd; (void)events; (void)data;
    ASensorEvent ev[16];
    ssize_t n;
    while ((n = ASensorEventQueue_getEvents(g_queue, ev, 16)) > 0) {
        pthread_mutex_lock(&g_mu);
        for (ssize_t i = 0; i < n; i++) {
            if (ev[i].type == ASENSOR_TYPE_ACCELEROMETER) { memcpy(g_acc, ev[i].acceleration.v, sizeof g_acc); g_acc_ns = ev[i].timestamp; }
            else if (ev[i].type == ASENSOR_TYPE_GYROSCOPE) { memcpy(g_gyr, ev[i].vector.v, sizeof g_gyr); g_gyr_ns = ev[i].timestamp; }
        }
        pthread_mutex_unlock(&g_mu);
    }
    return 1;
}

static void *sensor_thread(void *arg) {
    (void)arg;
    ALooper *looper = ALooper_prepare(0);
    pthread_mutex_lock(&g_mu);
    g_manager = ASensorManager_getInstanceForPackage(g_package[0] ? g_package : NULL);
    g_accel = g_manager ? ASensorManager_getDefaultSensor(g_manager, ASENSOR_TYPE_ACCELEROMETER) : NULL;
    g_gyro = g_manager ? ASensorManager_getDefaultSensor(g_manager, ASENSOR_TYPE_GYROSCOPE) : NULL;
    g_queue = g_accel && g_gyro ? ASensorManager_createEventQueue(g_manager, looper, 1, on_sensor, NULL) : NULL;
    if (!g_queue)
        LOGE("【红】手机六轴：本机%s，游戏的六轴读不到手机（陀螺仪瞄准等不可用）",
             !g_manager ? "拿不到传感器服务" : !g_gyro ? "没有陀螺仪" : !g_accel ? "没有加速度计" : "建不出传感器队列");
    g_thread_state = g_queue ? 1 : -1;
    pthread_cond_broadcast(&g_thread_cv);
    pthread_mutex_unlock(&g_mu);
    if (!g_queue) return NULL;
    for (;;) ALooper_pollOnce(-1, NULL, NULL, NULL);
}

// 持 g_mu。游戏要六轴、设置开着、在前台才开传感器；其余一律关（省电，同 iOS 游戏启用 SixAxis 才开）
static void sensors_apply_locked(void) {
    int on = g_want_motion && atomic_load(&g_gyro_pref) && atomic_load(&g_foreground) && !g_phone_yield;
    if (on && !g_thread_state) {
        pthread_t t;
        if (pthread_create(&t, NULL, sensor_thread, NULL) != 0) { LOGE("【红】手机六轴：传感器线程起不来"); g_thread_state = -1; return; }
        pthread_detach(t);
        while (!g_thread_state) pthread_cond_wait(&g_thread_cv, &g_mu);
    }
    if (g_thread_state != 1 || on == g_sensors_on) return;
    if (on) {
        int a = ASensorEventQueue_registerSensor(g_queue, g_accel, SENSOR_PERIOD_US, 0);
        int g = ASensorEventQueue_registerSensor(g_queue, g_gyro, SENSOR_PERIOD_US, 0);
        if (a < 0 || g < 0) {
            LOGE("【红】手机六轴：开传感器失败（加速度计 %d、陀螺仪 %d）", a, g);
            if (!a) ASensorEventQueue_disableSensor(g_queue, g_accel);
            if (!g) ASensorEventQueue_disableSensor(g_queue, g_gyro);
            return;
        }
        LOGI("手机六轴：开（加速度计 %s、陀螺仪 %s，%d Hz，没有外接手柄六轴时当掌机六轴）",
             ASensor_getName(g_accel), ASensor_getName(g_gyro), 1000000 / SENSOR_PERIOD_US);
    } else {
        ASensorEventQueue_disableSensor(g_queue, g_accel);
        ASensorEventQueue_disableSensor(g_queue, g_gyro);
        g_acc_ns = g_gyr_ns = 0;   // 关过就不再把旧样本当新的（再开后两路都到齐才报有样本）
        LOGI("手机六轴：关");
    }
    g_sensors_on = on;
}

static void pad_motion_wanted(int wanted);
static void pad_motion_clear(void);

EXPORT void s2a_pad_set_motion_enabled(int enabled) {
    enabled = enabled != 0;
    pthread_mutex_lock(&g_mu);
    int changed = g_want_motion != enabled;
    g_want_motion = enabled;
    if (!enabled) g_phone_yield = 0;   // 下次要六轴时手机先开着，等手柄真供上样本再让
    sensors_apply_locked();
    pthread_mutex_unlock(&g_mu);
    if (!changed) return;
    if (!enabled) pad_motion_clear();
    pad_motion_wanted(enabled);   // 手柄传感器只在游戏要六轴时开（手柄电池），开关在 Java（PadFeedback）
}

// ---------- 外接手柄六轴（PadFeedback.java 的传感器线程经 NativeBridge.padSensor 送来）----------
//   样本时间取到达时刻（CLOCK_MONOTONIC，同 iOS slot_feedback.m 用回调时刻）：手柄传感器的事件时间基各驱动不一，到达时刻同一时间轴、也用来判断样本断了
enum { PAD_SAMPLE_STALE_MS = 100 };   // 200 Hz 的样本 100 ms 没来 = 手柄拔了 / 驱动停了：当没有手柄六轴，回落手机
static pthread_mutex_t g_pad_mu = PTHREAD_MUTEX_INITIALIZER;
static float g_pad_acc[3], g_pad_gyr[3];
static uint64_t g_pad_acc_ns, g_pad_gyr_ns;
static s2a_android_motion_route g_route;   // 只由 HID 线程（s2a_pad_read_motion）读写
static uint64_t now_ns(void);

static void pad_motion_clear(void) {
    pthread_mutex_lock(&g_pad_mu);
    g_pad_acc_ns = g_pad_gyr_ns = 0;
    pthread_mutex_unlock(&g_pad_mu);
}
// 读手柄这一帧：有新鲜的两路样本才算有，换成 NS2 坐标
static int pad_motion_read(uint64_t now, s2a_pad_motion *out) {
    int frame = atomic_load(&g_pad_frame);
    float a[3], w[3];
    pthread_mutex_lock(&g_pad_mu);
    uint64_t ts = g_pad_gyr_ns;
    int fresh = g_pad_acc_ns && ts && now - ts < (uint64_t)PAD_SAMPLE_STALE_MS * 1000000u && now - g_pad_acc_ns < (uint64_t)PAD_SAMPLE_STALE_MS * 1000000u;
    memcpy(a, g_pad_acc, sizeof a);
    memcpy(w, g_pad_gyr, sizeof w);
    pthread_mutex_unlock(&g_pad_mu);
    float acc[3], gyr[3];
    if (!fresh || !s2a_android_pad_axes(frame, a, w, acc, gyr)) return 0;
    *out = (s2a_pad_motion){ ts / 1000u, acc[0], acc[1], acc[2], gyr[0], gyr[1], gyr[2] };
    return 1;
}

static const char *motion_src_name(int src) { return src == S2A_MOTION_GC ? "手柄" : src == S2A_MOTION_PHONE ? "手机" : "无"; }

EXPORT int s2a_pad_read_motion(s2a_pad_motion *out) {
    if (!out) return 0;
    uint64_t now = now_ns();
    s2a_pad_motion pad;
    int pad_known = atomic_load(&g_foreground) && pad_motion_read(now, &pad);
    pthread_mutex_lock(&g_mu);
    int known = g_sensors_on && g_acc_ns && g_gyr_ns;
    float acc[3], gyr[3];
    int64_t ts = g_gyr_ns;   // 以陀螺仪的时间为样本时间：服务层按它判新样本、积分姿态
    memcpy(acc, g_acc, sizeof acc);
    memcpy(gyr, g_gyr, sizeof gyr);
    pthread_mutex_unlock(&g_mu);
    // 玩家 1 的六轴来源仲裁（共用规则 motion_pick.c）：有样本的手柄优先，手柄给不出才用手机；换源丢一帧，手柄供满 2 秒手机传感器歇着
    int previous = g_route.src;
    s2a_android_motion_pick pick = s2a_android_motion_step(&g_route, atomic_load(&g_gamepad), pad_known, known, now);
    if (pick.src != previous) LOGI("六轴：来源 %s → %s", motion_src_name(previous), motion_src_name(pick.src));
    pthread_mutex_lock(&g_mu);
    if (g_phone_yield != pick.yield_phone) { g_phone_yield = pick.yield_phone; sensors_apply_locked(); }
    pthread_mutex_unlock(&g_mu);
    if (pick.drop) return 0;   // 服务层见 known = 0 清姿态：不跨两台刚体积分
    if (pick.src == S2A_MOTION_GC) { *out = pad; return 1; }
    if (pick.src != S2A_MOTION_PHONE) return 0;
    double acc_dev[3], gyr_dev[3] = {gyr[0], gyr[1], gyr[2]};
    s2a_android_accel_to_coremotion(acc, acc_dev);
    int right[2], up[2];
    s2a_android_rotation_basis(atomic_load(&g_rotation), right, up);
    float a[3], g[3];
    s2a_phone_axes_basis(right, up, acc_dev, gyr_dev, a, g);
    *out = (s2a_pad_motion){ (uint64_t)ts / 1000u, a[0], a[1], a[2], g[0], g[1], g[2] };
    return 1;
}

// ---------- 震动 ----------
// 提交侧（服务层在 HID 的 _rumbleLock 内同步调）只写 mailbox 就返回；Binder 调 Vibrator 一律在反馈线程上（同 iOS 的理由，phone_rumble_mailbox.h）
static JavaVM *g_vm;
static jclass g_feedback_class;
static jmethodID g_vibrate;
static _Atomic int g_mb_ready;
static s2a_android_rumble_state g_rumble;   // 只由反馈线程读写
static pthread_mutex_t g_pair_mu = PTHREAD_MUTEX_INITIALIZER;
static s2a_pad_vibration g_pair[2];   // s2a_pad_set_rumble 单侧提交时补另一侧

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000u + (uint64_t)ts.tv_nsec;
}

static void java_vibrate(int amplitude) {
    static JNIEnv *env;   // 反馈线程常驻：挂一次 JVM，不再摘
    if (!g_vm || !g_vibrate) return;
    if (!env && (*g_vm)->AttachCurrentThread(g_vm, &env, NULL) != JNI_OK) {
        env = NULL;
        static int said; if (!said++) LOGE("【红】手机震动：反馈线程挂不上 JVM");
        return;
    }
    (*env)->CallStaticVoidMethod(env, g_feedback_class, g_vibrate, (jint)amplitude, (jint)S2A_ANDROID_RUMBLE_LEASE_MS);
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionDescribe(env); (*env)->ExceptionClear(env); }
}

// 外接手柄这一路的 Java 入口（PadFeedback：vibrate 在反馈线程上调，motionWanted 在调 s2a_pad_set_motion_enabled 的线程上调）
static jclass g_pad_class;
static jmethodID g_pad_vibrate, g_pad_motion_wanted;
static s2a_android_rumble_state g_pad_rumble_state;   // 只由反馈线程读写
static _Atomic int g_rumble_target;                   // 最近一次提交给谁：0 = 手机、1 = 手柄（反馈线程按它下发）
static int g_applied_target;                          // 只由反馈线程读写：上一次下发到的那一路

static void java_pad_vibrate(int key) {
    static JNIEnv *env;   // 反馈线程常驻（同 java_vibrate）
    if (!g_vm || !g_pad_vibrate) return;
    if (!env && (*g_vm)->AttachCurrentThread(g_vm, &env, NULL) != JNI_OK) { env = NULL; return; }
    (*env)->CallStaticVoidMethod(env, g_pad_class, g_pad_vibrate, (jint)(key >> 8 & 255), (jint)(key & 255), (jint)S2A_ANDROID_RUMBLE_LEASE_MS);
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionDescribe(env); (*env)->ExceptionClear(env); }
}

// 任意线程：已挂 JVM 的线程直接用，没挂的临时挂上、用完摘掉（服务层线程不常驻在 JVM 上）
static void pad_motion_wanted(int wanted) {
    if (!g_vm || !g_pad_motion_wanted) return;
    JNIEnv *env;
    int attached = 0;
    if ((*g_vm)->GetEnv(g_vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK) {
        if ((*g_vm)->AttachCurrentThread(g_vm, &env, NULL) != JNI_OK) { LOGE("【红】手柄六轴：挂不上 JVM，开关没送到"); return; }
        attached = 1;
    }
    (*env)->CallStaticVoidMethod(env, g_pad_class, g_pad_motion_wanted, (jboolean)(wanted != 0));
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionDescribe(env); (*env)->ExceptionClear(env); }
    if (attached) (*g_vm)->DetachCurrentThread(g_vm);
}

// 反馈线程：马达的唯一入口。两路（手机 / 手柄）各自一套租约节奏；换路先把上一路停掉
static void rumble_apply(const s2a_pad_vibration v[2], int kind) {
    if (kind == S2A_PHONE_RUMBLE_WARM) return;
    uint64_t now = now_ns();
    if (kind == S2A_PHONE_RUMBLE_STOP || !v) {   // 停：两路都停（没在震的那路 step 回 -1，不下发）
        if (s2a_android_rumble_step(&g_rumble, 0, now) == 0) java_vibrate(0);
        if (s2a_android_rumble_step(&g_pad_rumble_state, 0, now) == 0) java_pad_vibrate(0);
        return;
    }
    int target = atomic_load(&g_rumble_target);
    if (target != g_applied_target) {
        if (g_applied_target) { if (s2a_android_rumble_step(&g_pad_rumble_state, 0, now) == 0) java_pad_vibrate(0); }
        else if (s2a_android_rumble_step(&g_rumble, 0, now) == 0) java_vibrate(0);
        g_applied_target = target;
    }
    if (target) {
        int send = s2a_android_rumble_step(&g_pad_rumble_state, s2a_android_pad_rumble_key(v), now);
        if (send < 0) return;
        java_pad_vibrate(send);
        static int said; if (send > 0 && !said++) LOGI("手柄震动：首次 左 %d/255、右 %d/255", send >> 8, send & 255);
        return;
    }
    int send = s2a_android_rumble_step(&g_rumble, s2a_android_rumble_level(v), now);
    if (send < 0) return;
    java_vibrate(send);
    static int said; if (send > 0 && !said++) LOGI("手机震动：首次 振幅 %d/255", send);
}

// 接着有马达的手柄（且「手柄震动」开着）就震手柄；手机马达只在没接手柄时震（同 iOS：接着外接手柄时手机多半放在一边）
EXPORT uint64_t s2a_pad_rumble_session(void) {
    if (!atomic_load(&g_foreground)) return 0;
    if (atomic_load(&g_gamepad) && atomic_load(&g_pad_rumble)) return atomic_load(&g_pad_session);
    if (!atomic_load(&g_rumble_pref) || !atomic_load(&g_has_vibrator) || atomic_load(&g_gamepad)) return S2A_MOTION_ONLY_SESSION;
    return atomic_load(&g_session);
}

static int owns(uint64_t session) {
    uint64_t now = s2a_pad_rumble_session();
    return session && session == now && now != S2A_MOTION_ONLY_SESSION;
}

static void rumble_stop(void) {
    if (atomic_load(&g_mb_ready)) s2a_phone_rumble_mailbox_submit_stop();   // STOP 在信箱里压过 PLAY
}

EXPORT void s2a_pad_set_rumble_pair(uint64_t session, const s2a_pad_vibration values[2]) {
    if (!values) return;
    pthread_mutex_lock(&g_pair_mu);
    memcpy(g_pair, values, sizeof g_pair);
    pthread_mutex_unlock(&g_pair_mu);
    if (!owns(session)) return;   // 旧会话（退过后台 / 关了设置 / 换了手柄）的迟到提交不再震
    atomic_store(&g_rumble_target, S2A_SESSION_KIND(session) == S2A_PAD_SESSION_BASE);
    if (!atomic_load(&g_mb_ready)) {
        if (!s2a_phone_rumble_mailbox_start(rumble_apply)) { static int said; if (!said++) LOGE("【红】手机震动：反馈线程起不来"); return; }
        atomic_store(&g_mb_ready, 1);
    }
    s2a_phone_rumble_mailbox_submit(values);
}

EXPORT void s2a_pad_set_rumble(uint64_t session, unsigned side, float low_amp, float low_hz, float high_amp, float high_hz) {
    if (side > 1) return;
    s2a_pad_vibration pair[2];
    pthread_mutex_lock(&g_pair_mu);
    g_pair[side] = (s2a_pad_vibration){ low_amp, low_hz, high_amp, high_hz };
    memcpy(pair, g_pair, sizeof pair);
    pthread_mutex_unlock(&g_pair_mu);
    s2a_pad_set_rumble_pair(session, pair);
}

EXPORT void s2a_pad_stop_rumble(uint64_t session) {
    (void)session;   // 停止不看会话：任何一方要停都停（多停一次无害）
    rumble_stop();
}

// ---------- 前后台 / 设置 / 屏幕方向 ----------
void s2a_android_phone_feedback_foreground(int foreground) {
    foreground = foreground != 0;
    if (atomic_exchange(&g_foreground, foreground) == foreground) return;
    if (!foreground) { atomic_fetch_add(&g_session, 1); atomic_fetch_add(&g_pad_session, 1); rumble_stop(); }   // 会话换号：服务层见到变化就清本地震动状态（ControllerFeedback.ObserveSession）
    pthread_mutex_lock(&g_mu);
    sensors_apply_locked();
    pthread_mutex_unlock(&g_mu);
}

// 服务层登记（android/core-runtime/AndroidGameRuntime.cs → InputPump.Feedback，字段次序同 InputPump.HostFeedback）：
//   本库以 RTLD_LOCAL 载入，服务层按名查主程序导出查不到上面这几个函数，改由平台装配把地址交过去
typedef struct { void *rumble_session, *set_rumble_pair, *stop_rumble, *set_motion_enabled, *read_motion; } s2a_android_pad_feedback_hooks;
EXPORT void s2a_android_pad_feedback(s2a_android_pad_feedback_hooks *out) {
    if (!out) return;
    out->rumble_session = (void *)s2a_pad_rumble_session;
    out->set_rumble_pair = (void *)s2a_pad_set_rumble_pair;
    out->stop_rumble = (void *)s2a_pad_stop_rumble;
    out->set_motion_enabled = (void *)s2a_pad_set_motion_enabled;
    out->read_motion = (void *)s2a_pad_read_motion;
}

JNIEXPORT void JNICALL
Java_org_s2arm_android_NativeBridge_configurePhoneFeedback(JNIEnv *env, jclass bridge, jstring package, jboolean gyro, jboolean rumble,
                                                           jboolean has_vibrator, jboolean gamepad) {
    (void)bridge;
    if (!g_vm) (*env)->GetJavaVM(env, &g_vm);
    if (!g_feedback_class) {
        jclass local = (*env)->FindClass(env, "org/s2arm/android/PhoneFeedback");   // 主线程查（反馈线程的类加载器找不到应用类）
        if (local) {
            g_vibrate = (*env)->GetStaticMethodID(env, local, "vibrate", "(II)V");
            g_feedback_class = (*env)->NewGlobalRef(env, local);
            (*env)->DeleteLocalRef(env, local);
        }
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
        if (!g_vibrate) LOGE("【红】手机震动：PhoneFeedback.vibrate 找不到");
    }
    pthread_mutex_lock(&g_mu);
    if (package && !g_package[0]) {
        const char *p = (*env)->GetStringUTFChars(env, package, NULL);
        if (p) { strncpy(g_package, p, sizeof g_package - 1); (*env)->ReleaseStringUTFChars(env, package, p); }
    }
    pthread_mutex_unlock(&g_mu);
    // 能不能震变了就换会话号：服务层见到变化清掉本地震动状态（ControllerFeedback.ObserveSession），旧会话的迟到提交不再震
    uint64_t before = s2a_pad_rumble_session();
    atomic_store(&g_rumble_pref, rumble != JNI_FALSE);
    atomic_store(&g_has_vibrator, has_vibrator != JNI_FALSE && g_vibrate != NULL);
    atomic_store(&g_gamepad, gamepad != JNI_FALSE);
    if (s2a_pad_rumble_session() != before) {
        if (before != S2A_MOTION_ONLY_SESSION) rumble_stop();
        atomic_fetch_add(&g_session, 1);
    }
    atomic_store(&g_gyro_pref, gyro != JNI_FALSE);
    pthread_mutex_lock(&g_mu);
    sensors_apply_locked();
    pthread_mutex_unlock(&g_mu);
}

JNIEXPORT void JNICALL
Java_org_s2arm_android_NativeBridge_setDisplayRotation(JNIEnv *env, jclass bridge, jint rotation) {
    (void)env; (void)bridge;
    int was = atomic_exchange(&g_rotation, rotation & 3);
    if (was != (rotation & 3)) LOGI("手机六轴：屏幕方向 ROTATION_%d", (rotation & 3) * 90);
}

// PadFeedback.publish（主线程）：玩家 1 的手柄能不能震、六轴坐标系（S2A_ANDROID_PAD_FRAME_*，厂商号由 Java 换）。
//   changed = 换了一只手柄：手柄会话换号、旧样本作废（两只手柄是两台刚体）
JNIEXPORT void JNICALL
Java_org_s2arm_android_NativeBridge_configurePadFeedback(JNIEnv *env, jclass bridge, jboolean rumble, jint vendor_id, jboolean motion,
                                                         jboolean changed) {
    (void)bridge;
    if (!g_vm) (*env)->GetJavaVM(env, &g_vm);
    if (!g_pad_class) {
        jclass local = (*env)->FindClass(env, "org/s2arm/android/PadFeedback");   // 主线程查（反馈线程的类加载器找不到应用类）
        if (local) {
            g_pad_vibrate = (*env)->GetStaticMethodID(env, local, "vibrate", "(III)V");
            g_pad_motion_wanted = (*env)->GetStaticMethodID(env, local, "motionWanted", "(Z)V");
            g_pad_class = (*env)->NewGlobalRef(env, local);
            (*env)->DeleteLocalRef(env, local);
        }
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
        if (!g_pad_vibrate || !g_pad_motion_wanted) LOGE("【红】手柄震动 / 六轴：PadFeedback 的回调找不到");
    }
    int can_rumble = rumble != JNI_FALSE && g_pad_vibrate != NULL;
    int frame = motion != JNI_FALSE ? s2a_android_pad_frame(vendor_id) : S2A_ANDROID_PAD_FRAME_NONE;
    if (motion != JNI_FALSE && !frame) {
        static int said; if (!said++) LOGI("手柄六轴：厂商 %04x 的坐标系认不出，不用它的六轴（体感走手机陀螺仪）", vendor_id & 0xffff);
    }
    int was_rumble = atomic_exchange(&g_pad_rumble, can_rumble);
    int was_frame = atomic_exchange(&g_pad_frame, frame);
    if (changed != JNI_FALSE || was_rumble != can_rumble) {
        if (was_rumble) rumble_stop();
        atomic_fetch_add(&g_pad_session, 1);
    }
    if (changed != JNI_FALSE || was_frame != frame) pad_motion_clear();
    if (changed != JNI_FALSE || was_rumble != can_rumble || was_frame != frame)
        LOGI("手柄：震动 %s，六轴 %s", can_rumble ? "接手柄马达" : "不接", frame == S2A_ANDROID_PAD_FRAME_PLAYSTATION ? "PlayStation 坐标" :
             frame == S2A_ANDROID_PAD_FRAME_NINTENDO ? "任天堂坐标" : "不接");
    // 游戏已经要了六轴、这时才接上手柄：把开关补给 Java（它按「要不要 + 手柄有没有传感器」开）
    pthread_mutex_lock(&g_mu);
    int want = g_want_motion;
    pthread_mutex_unlock(&g_mu);
    if (want && frame && g_pad_motion_wanted) {
        (*env)->CallStaticVoidMethod(env, g_pad_class, g_pad_motion_wanted, JNI_TRUE);
        if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionDescribe(env); (*env)->ExceptionClear(env); }
    }
}

// PadFeedback 的传感器线程：一路一次（gyro = 陀螺仪 rad/s，否则加速度计 m/s²），驱动坐标原样，换算在读的时候做
JNIEXPORT void JNICALL
Java_org_s2arm_android_NativeBridge_padSensor(JNIEnv *env, jclass bridge, jboolean gyro, jfloat x, jfloat y, jfloat z) {
    (void)env; (void)bridge;
    uint64_t now = now_ns();
    pthread_mutex_lock(&g_pad_mu);
    float *v = gyro != JNI_FALSE ? g_pad_gyr : g_pad_acc;
    v[0] = x; v[1] = y; v[2] = z;
    if (gyro != JNI_FALSE) g_pad_gyr_ns = now; else g_pad_acc_ns = now;
    pthread_mutex_unlock(&g_pad_mu);
}
