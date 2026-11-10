# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
NATIVE_TEST_OWN += qladder
.PHONY: native-test-qladder
native-test-qladder:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -o $(BUILD)/tests/t_qladder runtime/tests/t_qladder.c runtime/src/qladder.c
	$(BUILD)/tests/t_qladder
TEST_TARGETS += native-test-qladder
# 起局：运行模式是梯子上限（#352）
NATIVE_TEST_OWN += qladder_host
.PHONY: native-test-qladder_host
native-test-qladder_host:
	@mkdir -p $(BUILD)/tests
	$(CC) $(CFLAGS) $(NATIVE_INC) -Iruntime/src -o $(BUILD)/tests/t_qladder_host runtime/tests/t_qladder_host.c runtime/src/qladder_host.c runtime/src/qladder.c
	$(BUILD)/tests/t_qladder_host
TEST_TARGETS += native-test-qladder_host
