// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#include "save_transfer.h"
#include <cstdlib>
static int invoked, released, mode;
static char *run(const char *request) {
    ++invoked;
    if (mode == 3) return nullptr;
    size_t length = mode == 4 ? (8u << 20) + 1 : std::strlen(request);
    char *result = static_cast<char *>(std::malloc(length + 1));
    if (!result) return nullptr;
    if (mode == 4) std::memset(result, 'a', length);
    else std::memcpy(result, request, length);
    result[length] = 0;
    return result;
}
static void release(void *value) { ++released; std::free(value); }
extern "C" JNIEXPORT jbyteArray JNICALL Java_SaveTransferTest_transfer(JNIEnv *env, jclass, jbyteArray request, jint choice) {
    mode = choice;
    return s2a::save_transfer(env, request, choice == 1 ? nullptr : run, choice == 2 ? nullptr : release);
}
extern "C" JNIEXPORT jint JNICALL Java_SaveTransferTest_calls(JNIEnv *, jclass) { return invoked; }
extern "C" JNIEXPORT jint JNICALL Java_SaveTransferTest_frees(JNIEnv *, jclass) { return released; }
