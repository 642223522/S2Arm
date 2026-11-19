// 宿主夹具：direct_session.c 在安卓外编（run_ns2_lookup.py）时代替 NDK 的 <android/log.h>；日志照 stderr 打，不走系统日志。
#pragma once
#include <stdarg.h>
#include <stdio.h>
enum { ANDROID_LOG_UNKNOWN, ANDROID_LOG_DEFAULT, ANDROID_LOG_VERBOSE, ANDROID_LOG_DEBUG, ANDROID_LOG_INFO,
       ANDROID_LOG_WARN, ANDROID_LOG_ERROR, ANDROID_LOG_FATAL, ANDROID_LOG_SILENT };
static inline int __android_log_print(int prio, const char *tag, const char *fmt, ...) {
    (void)prio; va_list ap; fprintf(stderr, "[%s] ", tag);
    va_start(ap, fmt); vfprintf(stderr, fmt, ap); va_end(ap); fputc('\n', stderr); return 0;
}
static inline int __android_log_write(int prio, const char *tag, const char *text) {
    (void)prio; fprintf(stderr, "[%s] %s\n", tag, text); return 0;
}
