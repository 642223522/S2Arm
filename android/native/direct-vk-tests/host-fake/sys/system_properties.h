// 宿主夹具：direct_session.c 在安卓外编（run_ns2_lookup.py）时代替 bionic 的 <sys/system_properties.h>；属性一律读成空串。
#pragma once
#define PROP_NAME_MAX 32
#define PROP_VALUE_MAX 92
static inline int __system_property_get(const char *name, char *value) { (void)name; value[0] = 0; return 0; }
