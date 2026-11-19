/* SPDX-License-Identifier: MIT */
/* Copyright 2026 S2Arm contributors */
/* OHOS musl has no thread cancellation. Only Mesa's KMS display WSI uses it (unused here). */
#pragma once
#include <pthread.h>
#include <errno.h>
#ifndef PTHREAD_CANCEL_ASYNCHRONOUS
#define PTHREAD_CANCEL_ASYNCHRONOUS 1
#define PTHREAD_CANCEL_DEFERRED 0
#endif
static inline int ohos_no_pthread_setcanceltype(int t, int *o) { (void)t; if (o) *o = 0; return 0; }
static inline int ohos_no_pthread_cancel(pthread_t t) { (void)t; return ENOSYS; }
#define pthread_setcanceltype ohos_no_pthread_setcanceltype
#define pthread_cancel ohos_no_pthread_cancel
