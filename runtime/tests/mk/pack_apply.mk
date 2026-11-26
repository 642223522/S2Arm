# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# nftw needs feature-test declarations on glibc; no Apple SDK is needed by this test.
NATIVE_TEST_OWN += pack_apply
PACK_APPLY_TEST_CPPFLAGS := -DS2A_ZCHUNK=65536   # 压缩传输块大小编成 64 KB（正式 1 GiB，两端同值由 tests/push_pack_test.py 核）：单测夹具几百 KB 就能切成多块
ifeq ($(S2A_UNAME),Linux)
PACK_APPLY_TEST_CPPFLAGS += -D_GNU_SOURCE
endif
.PHONY: native-test-pack_apply
native-test-pack_apply:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) $(PACK_APPLY_TEST_CPPFLAGS) -DS2A_UNIT_TEST -o $(BUILD)/tests/t_pack_apply runtime/tests/t_pack_apply.c runtime/src/pack_apply.c $(S2A_HOST_WEAK)
	$(BUILD)/tests/t_pack_apply
TEST_TARGETS += native-test-pack_apply
