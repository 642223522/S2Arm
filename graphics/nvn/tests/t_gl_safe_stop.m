// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// GPU 安全停后 GL 提交（D-TMM9）：gl_commit 原先先 dispatch_group_enter + 挂完成回调、停了再手动 leave；
//   不交的命令缓冲释放时 Metal 照样调完成回调（本机实测：未提交的缓冲释放即回调，状态 0），同一次 enter 被 leave 两次
//   → dispatch_group_leave 陷阱（信号 5，玩家 iPhone 现场）。期望手写：安全停后提交照常返回、进程不陷阱；之后宿主按产品行为优雅收局（退出码 86），mk 把 0 / 86 都算过。
//   反证：换回旧 gl_commit，本测试在 dispatch_group_leave 处 Trace/BPT trap 退出。真 EGL / GL / Metal，无替身
#include "../gfx/gl/gl_int.h"
#include "../graphics_session.h"
static int checks, failures;
#define CHECK(c) do { checks++; if (!(c)) { failures++; fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #c); } } while (0)
void mtl_gpu_halt(const char *why); int mtl_gpu_halted(void);
int main(void) { @autoreleasepool {
    void *(*gpa)(const char *) = gl_entry("eglGetProcAddress"); CHECK(gpa); if (!gpa) return 1;
    EGLDisplay (*getdisp)(void *) = gpa("eglGetDisplay"); EGLBoolean (*init)(EGLDisplay, EGLint *, EGLint *) = gpa("eglInitialize");
    EGLBoolean (*bind)(EGLenum) = gpa("eglBindAPI"); EGLBoolean (*cfgs)(EGLDisplay, EGLConfig *, EGLint, EGLint *) = gpa("eglGetConfigs");
    EGLContext (*mkctx)(EGLDisplay, EGLConfig, EGLContext, const EGLint *) = gpa("eglCreateContext");
    EGLSurface (*mkpb)(EGLDisplay, EGLConfig, const EGLint *) = gpa("eglCreatePbufferSurface");
    EGLBoolean (*cur)(EGLDisplay, EGLSurface, EGLSurface, EGLContext) = gpa("eglMakeCurrent");
    void (*clearc)(GLfloat, GLfloat, GLfloat, GLfloat) = gpa("glClearColor"); void (*clear)(GLbitfield) = gpa("glClear");
    CHECK(s2a_graphics_native_begin_session() == 0);
    EGLDisplay d = getdisp(NULL); EGLint ma = 0, mi = 0; CHECK(init(d, &ma, &mi)); CHECK(bind(0x30A0));
    EGLConfig cfg = NULL; EGLint n = 0; CHECK(cfgs(d, &cfg, 1, &n) && n == 1);
    EGLint size[] = {0x3057, 16, 0x3056, 16, 0x3038};
    EGLContext c = mkctx(d, cfg, NULL, NULL); EGLSurface s = mkpb(d, cfg, size); CHECK(c && s && cur(d, s, s, c));
    clearc(0, 1, 0, 1); clear(0x4000); (void)gl_commit();   // 正控：安全停前照常交
    mtl_gpu_halt("t_gl_safe_stop：模拟驱动报挂死");
    CHECK(mtl_gpu_halted());
    for (int i = 0; i < 3; i++) { @autoreleasepool { clearc(1, 0, 0, 1); clear(0x4000); (void)gl_commit(); } }   // 安全停后：不交，缓冲随池释放
    fprintf(stderr, "[gl-safe-stop] 安全停后 3 次提交已返回、缓冲已释放\n");
    [NSThread sleepForTimeInterval:0.5];   // 让 Metal 有机会调已释放缓冲的完成回调（旧代码在这里陷阱）
    fprintf(stderr, "[gl-safe-stop] %d checks, %d failures（走到这里 = 安全停后提交没有重复 leave）\n", checks, failures);
    return failures ? 1 : 0;
}}
