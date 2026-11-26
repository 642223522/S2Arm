// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// N-API entry of the emulator smoke HAP: runs the native probe, then the optional NativeAOT
// probe (libnetprobe.so, loaded with dlopen so the HAP also builds without it), into one file.
#include <dlfcn.h>
#include <hilog/log.h>
#include <napi/native_api.h>
#include <stdio.h>
#include <string.h>

int probe_native(void);

static napi_value Run(napi_env env, napi_callback_info info) {
    size_t argc = 1, n = 0;
    napi_value argv[1];
    char path[512] = {0}, msg[256];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    napi_get_value_string_utf8(env, argv[0], path, sizeof path, &n);
    fflush(stdout);
    if (!freopen(path, "w", stdout)) {
        snprintf(msg, sizeof msg, "RESULT fail: cannot write %s", path);
    } else {
        setvbuf(stdout, NULL, _IONBF, 0);
        int fails = probe_native();
        void *h = dlopen("libnetprobe.so", RTLD_NOW);
        const char *(*net)(void) = h ? (const char *(*)(void))dlsym(h, "s2a_dotnet_probe") : NULL;
        if (net) {
            const char *r = net();
            fputs(r, stdout);
            for (const char *p = r; (p = strstr(p, "FAIL ")); p++) fails++;
            printf("NET DONE\n");
        } else {
            printf("NET SKIP %s\n", h ? "no s2a_dotnet_probe" : dlerror());
        }
        snprintf(msg, sizeof msg, "RESULT %s fails=%d net=%s", fails ? "fail" : "pass", fails, net ? "ran" : "skipped");
        printf("%s\n", msg);
        fflush(stdout);
    }
    OH_LOG_Print(LOG_APP, LOG_INFO, 0x5A2A, "S2A", "smoke: %{public}s", msg);
    napi_value r;
    napi_create_string_utf8(env, msg, NAPI_AUTO_LENGTH, &r);
    return r;
}

static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor d[] = {{"run", NULL, Run, NULL, NULL, NULL, napi_default, NULL}};
    napi_define_properties(env, exports, 1, d);
    return exports;
}

static napi_module mod = {.nm_version = 1, .nm_register_func = Init, .nm_modname = "probe"};
__attribute__((constructor)) static void reg(void) { napi_module_register(&mod); }
