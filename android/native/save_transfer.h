// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#pragma once
#include <jni.h>
#include <cstring>
#include <memory>
#include <new>

namespace s2a {
// Transport only: the shared service owns JSON validation and the Host.Boot gate.
// No dynamic discovery: run/free must come from the same linked service instance.
inline jbyteArray save_transfer(JNIEnv *env, jbyteArray request,
                               char *(*run)(const char *), void (*release)(void *)) {
    auto fail = [env](const char *kind, const char *message) -> jbyteArray {
        jclass type = env->FindClass(kind);
        if (type) env->ThrowNew(type, message);
        return nullptr;
    };
    if (!run || !release)
        return fail("java/lang/UnsupportedOperationException", "Save transfer service is not linked");
    if (!request)
        return fail("java/lang/IllegalArgumentException", "Save transfer request is null");
    constexpr jsize max_request = 8 << 20; // shared SaveTransferExports limit
    jsize length = env->GetArrayLength(request);
    if (length > max_request)
        return fail("java/lang/IllegalArgumentException", "Save transfer request exceeds 8 MiB");
    std::unique_ptr<char[]> input(new (std::nothrow) char[static_cast<size_t>(length) + 1]);
    if (!input) return fail("java/lang/OutOfMemoryError", "Save transfer request allocation failed");
    env->GetByteArrayRegion(request, 0, length, reinterpret_cast<jbyte *>(input.get()));
    if (env->ExceptionCheck()) return nullptr;
    if (std::memchr(input.get(), 0, static_cast<size_t>(length)))
        return fail("java/lang/IllegalArgumentException", "Save transfer request contains NUL");
    input[length] = 0;
    // The managed ABI catches its exceptions. Its UTF-8 response is owned until
    // copied, including when Java allocation/copy raises an exception.
    std::unique_ptr<char, void (*)(void *)> response(run(input.get()), release);
    if (!response) return fail("java/lang/OutOfMemoryError", "Save transfer response allocation failed");
    // Valid service responses are small JSON; fail closed on an oversized reply.
    size_t count = strnlen(response.get(), static_cast<size_t>(max_request) + 1);
    if (count > static_cast<size_t>(max_request))
        return fail("java/lang/IllegalStateException", "Save transfer response exceeds 8 MiB");
    jbyteArray result = env->NewByteArray(static_cast<jsize>(count));
    if (result) env->SetByteArrayRegion(result, 0, static_cast<jsize>(count),
                                      reinterpret_cast<const jbyte *>(response.get()));
    return result;
}
} // namespace s2a
